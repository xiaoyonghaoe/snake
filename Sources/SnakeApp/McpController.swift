import Combine
import Foundation
import Security
import SnakeCoreBindings

/// A token as shown in Settings. The secret itself stays in the encrypted
/// credential store and is only read back after device-owner authentication.
struct McpTokenInfo: Identifiable, Equatable {
    enum State { case active, revoked, expired }

    let id: UUID
    var name: String
    var prefix: String
    var createdAt: Date
    var expiresAt: Date?
    var lastUsedAt: Date?
    var revokedAt: Date?
    var profileIDs: [UUID]

    func state(at date: Date = .now) -> State {
        if revokedAt != nil { return .revoked }
        if let expiresAt, expiresAt <= date { return .expired }
        return .active
    }

    static func credentialAccount(for id: UUID) -> String { "mcp-token-\(id.uuidString.lowercased())" }
}

enum McpControllerError: LocalizedError {
    case storageUnavailable
    case tokenMissing

    var errorDescription: String? {
        switch self {
        case .storageUnavailable: L10n.text("Snake 数据库不可用，无法保存 MCP 设置。")
        case .tokenMissing: L10n.text("找不到该 Token 的加密副本，请删除后重新创建。")
        }
    }
}

/// Owns the MCP server lifecycle, its tokens and the audit trail.
@MainActor
final class McpController: ObservableObject, McpBackend {
    static let defaultPort = 47821
    static let defaultRetentionDays = 30
    static let defaultMaxRecords = 10_000
    /// Rolling deletion also runs after this many new records.
    static let pruneEveryInserts = 100

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            applyServerState()
        }
    }
    @Published var port: Int {
        didSet {
            let value = min(max(port, 1_024), 65_535)
            if value != port { port = value; return }
            defaults.set(value, forKey: Keys.port)
            if isEnabled { applyServerState() }
        }
    }
    @Published var retentionDays: Int {
        didSet {
            let value = min(max(retentionDays, 0), 3_650)
            if value != retentionDays { retentionDays = value; return }
            defaults.set(value, forKey: Keys.retentionDays)
            pruneAudit()
        }
    }
    @Published var maxRecords: Int {
        didSet {
            let value = min(max(maxRecords, 0), 1_000_000)
            if value != maxRecords { maxRecords = value; return }
            defaults.set(value, forKey: Keys.maxRecords)
            pruneAudit()
        }
    }
    @Published private(set) var serverState: McpHTTPServer.State = .stopped
    @Published private(set) var tokens: [McpTokenInfo] = []
    /// Changes whenever the audit table changes so views can reload.
    @Published private(set) var auditRevision = 0

    private let persistence: CorePersistence?
    private let defaults: UserDefaults
    private let profileSource: @MainActor () -> [SSHProfile]
    private let groupSource: @MainActor (UUID) -> String?
    private var server: McpHTTPServer?
    private var insertsSincePrune = 0
    private var pruneTimer: AnyCancellable?
    private var lastTouched: [String: Date] = [:]
    /// Injected by tests; the default opens a real SSH connection.
    var commandRunner: @Sendable (McpCommandRequest) async throws -> CoreCommandOutput = McpController.runOverSSH

    private enum Keys {
        static let enabled = "com.snake.mcp.enabled"
        static let port = "com.snake.mcp.port"
        static let retentionDays = "com.snake.mcp.audit.retention-days"
        static let maxRecords = "com.snake.mcp.audit.max-records"
    }

    init(
        persistence: CorePersistence?,
        defaults: UserDefaults,
        profiles: @escaping @MainActor () -> [SSHProfile],
        groupName: @escaping @MainActor (UUID) -> String?
    ) {
        self.persistence = persistence
        self.defaults = defaults
        self.profileSource = profiles
        self.groupSource = groupName
        isEnabled = defaults.bool(forKey: Keys.enabled)
        let savedPort = defaults.integer(forKey: Keys.port)
        port = savedPort == 0 ? Self.defaultPort : min(max(savedPort, 1_024), 65_535)
        retentionDays = defaults.object(forKey: Keys.retentionDays) == nil
            ? Self.defaultRetentionDays : min(max(defaults.integer(forKey: Keys.retentionDays), 0), 3_650)
        maxRecords = defaults.object(forKey: Keys.maxRecords) == nil
            ? Self.defaultMaxRecords : min(max(defaults.integer(forKey: Keys.maxRecords), 0), 1_000_000)
        reloadTokens()
    }

    /// Called once at app launch. Tests never open a listening socket implicitly.
    func activate() {
        pruneAudit()
        pruneTimer = Timer.publish(every: 3_600, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.pruneAudit() }
        }
        applyServerState()
    }

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    func configurationSnippet(token: String = "<TOKEN>") -> String {
        """
        {
          "mcpServers": {
            "snake": {
              "type": "http",
              "url": "\(endpoint)",
              "headers": { "Authorization": "Bearer \(token)" }
            }
          }
        }
        """
    }

    private func applyServerState() {
        server?.stop()
        server = nil
        guard isEnabled, pruneTimer != nil else {
            serverState = .stopped
            return
        }
        let server = McpHTTPServer(handler: McpRequestHandler(backend: self, port: port))
        server.onStateChange = { [weak self] state in self?.serverState = state }
        self.server = server
        server.start()
    }

    func restartServer() { applyServerState() }

    // MARK: Tokens

    func reloadTokens() {
        let records = (try? persistence?.mcpTokens()) ?? []
        tokens = records.compactMap { record in
            guard let id = UUID(uuidString: record.id) else { return nil }
            return McpTokenInfo(
                id: id, name: record.name, prefix: record.tokenPrefix,
                createdAt: Self.date(record.createdAt), expiresAt: record.expiresAt.map(Self.date),
                lastUsedAt: record.lastUsedAt.map(Self.date), revokedAt: record.revokedAt.map(Self.date),
                profileIDs: record.profileIds.compactMap(UUID.init(uuidString:))
            )
        }
    }

    /// Returns the new secret so the caller can show it right away.
    func createToken(name: String, profileIDs: [UUID], expiresAt: Date?) throws -> String {
        guard let persistence else { throw McpControllerError.storageUnavailable }
        let id = UUID()
        let secret = try Self.generateSecret()
        let account = McpTokenInfo.credentialAccount(for: id)
        try CredentialStore.save(secret, account: account)
        do {
            try persistence.createMcpToken(CoreMcpToken(
                id: id.uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                tokenPrefix: String(secret.prefix(12)), createdAt: Self.milliseconds(.now),
                expiresAt: expiresAt.map(Self.milliseconds), lastUsedAt: nil, revokedAt: nil,
                profileIds: profileIDs.map(\.uuidString)
            ), hash: McpRequestHandler.hash(token: secret))
        } catch {
            try? CredentialStore.delete(account: account)
            throw error
        }
        reloadTokens()
        return secret
    }

    func updateToken(id: UUID, name: String, profileIDs: [UUID], expiresAt: Date?) throws {
        guard let persistence else { throw McpControllerError.storageUnavailable }
        try persistence.updateMcpToken(
            id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            expiresAt: expiresAt.map(Self.milliseconds), profileIDs: profileIDs
        )
        reloadTokens()
    }

    func setRevoked(_ revoked: Bool, tokenID: UUID) throws {
        guard let persistence else { throw McpControllerError.storageUnavailable }
        try persistence.setMcpToken(id: tokenID, revokedAt: revoked ? Self.milliseconds(.now) : nil)
        reloadTokens()
    }

    func deleteToken(id: UUID) throws {
        guard let persistence else { throw McpControllerError.storageUnavailable }
        try persistence.deleteMcpToken(id: id)
        try? CredentialStore.delete(account: McpTokenInfo.credentialAccount(for: id))
        reloadTokens()
    }

    /// Reads the stored secret. Callers authenticate the device owner first.
    func storedSecret(for id: UUID) async throws -> String {
        let account = McpTokenInfo.credentialAccount(for: id)
        let data = try await Task.detached(priority: .userInitiated) { try CredentialStore.readData(account: account) }.value
        guard let data, let secret = String(data: data, encoding: .utf8) else { throw McpControllerError.tokenMissing }
        return secret
    }

    static func generateSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "snk_" + encoded
    }

    // MARK: Audit

    func auditRecords(filter: CoreMcpAuditFilter, limit: Int, offset: Int = 0) -> [CoreMcpAuditRecord] {
        (try? persistence?.mcpAudit(filter: filter, limit: limit, offset: offset)) ?? []
    }

    func auditCount(filter: CoreMcpAuditFilter) -> Int {
        (try? persistence?.mcpAuditCount(filter: filter)) ?? 0
    }

    @discardableResult
    func deleteAudit(filter: CoreMcpAuditFilter) throws -> Int {
        guard let persistence else { throw McpControllerError.storageUnavailable }
        let removed = try persistence.deleteMcpAudit(filter: filter)
        auditRevision &+= 1
        return removed
    }

    func pruneAudit(now: Date = .now) {
        insertsSincePrune = 0
        guard let removed = try? persistence?.pruneMcpAudit(
            nowMilliseconds: Self.milliseconds(now), retentionDays: retentionDays, maxRecords: maxRecords
        ), removed > 0 else { return }
        auditRevision &+= 1
    }

    // MARK: McpBackend

    func grant(tokenHash: String) -> McpGrant? {
        guard let record = try? persistence?.mcpToken(hash: tokenHash), record.revokedAt == nil else { return nil }
        let now = Date.now
        if let expiresAt = record.expiresAt, Self.date(expiresAt) <= now { return nil }
        // Throttle writes: one agent session can make many calls per minute.
        if lastTouched[record.id].map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            lastTouched[record.id] = now
            try? persistence?.touchMcpToken(id: record.id, usedAt: Self.milliseconds(now))
        }
        return McpGrant(
            tokenID: record.id, tokenName: record.name,
            profileIDs: Set(record.profileIds.compactMap(UUID.init(uuidString:)))
        )
    }

    func profiles() -> [SSHProfile] { profileSource() }

    func groupName(for profile: SSHProfile) -> String? { profile.groupID.flatMap(groupSource) }

    func run(_ request: McpCommandRequest) async throws -> CoreCommandOutput {
        try await commandRunner(request)
    }

    func recordAudit(_ record: CoreMcpAuditRecord) {
        try? persistence?.insertMcpAudit(record)
        auditRevision &+= 1
        insertsSincePrune += 1
        if insertsSincePrune >= Self.pruneEveryInserts { pruneAudit() }
    }

    func finishAudit(id: String, result: CoreMcpAuditResult) {
        try? persistence?.finishMcpAudit(id: id, result: result)
        auditRevision &+= 1
    }

    nonisolated static func runOverSSH(_ request: McpCommandRequest) async throws -> CoreCommandOutput {
        try await Task.detached(priority: .userInitiated) {
            let profile = request.profile
            let authentication = try TerminalRuntime.authentication(for: profile)
            defer {
                if case let .privateKey(_, _, scopedURL) = authentication {
                    scopedURL.stopAccessingSecurityScopedResource()
                }
            }
            let timeout = UInt64(request.timeoutSeconds) * 1_000
            let limit = UInt64(McpRequestHandler.maxOutputBytes)
            switch authentication {
            case .password(let password):
                return try runCommandPassword(
                    host: profile.host, port: UInt16(clamping: profile.port), username: profile.username,
                    password: password, knownHostsPath: TerminalRuntime.knownHostsPath,
                    command: request.command, cwd: request.cwd, timeoutMs: timeout, maxOutputBytes: limit
                )
            case .privateKey(let path, let passphrase, _):
                return try runCommandPrivateKey(
                    host: profile.host, port: UInt16(clamping: profile.port), username: profile.username,
                    privateKeyPath: path, passphrase: passphrase, knownHostsPath: TerminalRuntime.knownHostsPath,
                    command: request.command, cwd: request.cwd, timeoutMs: timeout, maxOutputBytes: limit
                )
            }
        }.value
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000).rounded()) }
    static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1_000) }
}

extension CoreMcpAuditFilter {
    static func matching(
        tokenID: String? = nil, profileID: String? = nil, status: String? = nil,
        since: Int64? = nil, until: Int64? = nil, ids: [String]? = nil
    ) -> CoreMcpAuditFilter {
        CoreMcpAuditFilter(tokenId: tokenID, profileId: profileID, status: status, since: since, until: until, ids: ids)
    }
}
