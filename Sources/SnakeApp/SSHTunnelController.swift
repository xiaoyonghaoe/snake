import Foundation
import SnakeCoreBindings

public enum SSHTunnelError: LocalizedError, Equatable {
    case profileRequired
    case invalidLocalPort
    case invalidRemotePort
    case remoteHostRequired
    case duplicateLocalPort(Int)

    public var errorDescription: String? {
        switch self {
        case .profileRequired: L10n.text("请选择隧道使用的 SSH 会话。")
        case .invalidLocalPort: L10n.text("本地端口须在 1 到 65535 之间。")
        case .invalidRemotePort: L10n.text("远端端口须在 1 到 65535 之间。")
        case .remoteHostRequired: L10n.text("请填写远端主机，转发到服务器自己时填 127.0.0.1。")
        case .duplicateLocalPort(let port): L10n.format("本地端口 %@ 已被另一条隧道使用。", String(port))
        }
    }
}

/// Bridges the core's close notification back to the main actor.
private final class TunnelObserver: CoreTunnelObserver, @unchecked Sendable {
    private let closed: @Sendable (String?) -> Void

    init(closed: @escaping @Sendable (String?) -> Void) {
        self.closed = closed
    }

    func onClosed(message: String?) {
        closed(message)
    }
}

/// Owns the saved tunnels and their live forwards. A dropped connection is
/// shown as disconnected and is only restarted when the user asks.
@MainActor
public final class SSHTunnelController: ObservableObject {
    typealias Starter = @Sendable (SSHProfile, SSHTunnel, CoreTunnelObserver) throws -> CoreTunnelHandle

    @Published public private(set) var tunnels: [SSHTunnel] = []
    @Published public private(set) var states: [UUID: TunnelState] = [:]

    private let persistence: CorePersistence?
    private let starter: Starter
    /// Resolves a tunnel's session; set by the store once it is initialized.
    var profile: (UUID) -> SSHProfile? = { _ in nil }
    private var handles: [UUID: CoreTunnelHandle] = [:]
    /// Bumped on every start and stop so late results from an older attempt are dropped.
    private var generations: [UUID: Int] = [:]
    private var pollTask: Task<Void, Never>?

    init(persistence: CorePersistence?, starter: Starter? = nil) {
        self.persistence = persistence
        self.starter = starter ?? { profile, tunnel, observer in
            try Self.startOverSSH(profile: profile, tunnel: tunnel, observer: observer)
        }
        tunnels = (try? persistence?.loadTunnels()) ?? []
    }

    public func state(of id: UUID) -> TunnelState {
        states[id] ?? .stopped
    }

    // MARK: Editing

    /// Validates and stores a tunnel. A running tunnel whose endpoint changed restarts.
    func save(_ tunnel: SSHTunnel) throws {
        var tunnel = tunnel
        tunnel.remoteHost = tunnel.remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
        tunnel.note = tunnel.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profileID = tunnel.profileID, profile(profileID) != nil else { throw SSHTunnelError.profileRequired }
        guard (1...65535).contains(tunnel.localPort) else { throw SSHTunnelError.invalidLocalPort }
        guard (1...65535).contains(tunnel.remotePort) else { throw SSHTunnelError.invalidRemotePort }
        guard !tunnel.remoteHost.isEmpty else { throw SSHTunnelError.remoteHostRequired }
        if tunnels.contains(where: { $0.id != tunnel.id && $0.localPort == tunnel.localPort }) {
            throw SSHTunnelError.duplicateLocalPort(tunnel.localPort)
        }
        let previous = tunnels.first { $0.id == tunnel.id }
        if previous == nil { tunnel.sortOrder = (tunnels.map(\.sortOrder).max() ?? -1) + 1 }
        try store(tunnel)
        if let previous, !previous.sameEndpoint(as: tunnel), state(of: tunnel.id).isActive {
            stop(tunnel.id)
            start(tunnel.id)
        }
    }

    func setAutoStart(_ enabled: Bool, for id: UUID) throws {
        guard var tunnel = tunnels.first(where: { $0.id == id }), tunnel.autoStart != enabled else { return }
        tunnel.autoStart = enabled
        try store(tunnel)
    }

    func delete(_ id: UUID) throws {
        stop(id)
        try persistence?.deleteTunnel(id: id)
        tunnels.removeAll { $0.id == id }
        states[id] = nil
        generations[id] = nil
    }

    /// The database already unbound these tunnels; stop them and show them as unbound.
    func profileRemoved(_ profileID: UUID) {
        for tunnel in tunnels where tunnel.profileID == profileID { stop(tunnel.id) }
        if let persistence, let reloaded = try? persistence.loadTunnels() {
            tunnels = reloaded
        } else {
            tunnels = tunnels.map { tunnel in
                var unbound = tunnel
                if unbound.profileID == profileID { unbound.profileID = nil }
                return unbound
            }
        }
    }

    private func store(_ tunnel: SSHTunnel) throws {
        if let persistence {
            try persistence.save(tunnel)
            tunnels = try persistence.loadTunnels()
        } else if let index = tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            tunnels[index] = tunnel
        } else {
            tunnels.append(tunnel)
        }
    }

    // MARK: Running

    func start(_ id: UUID) {
        guard let tunnel = tunnels.first(where: { $0.id == id }), !state(of: id).isActive else { return }
        guard let profileID = tunnel.profileID, let profile = profile(profileID) else {
            states[id] = .failed(L10n.text("原 SSH 会话已删除，请编辑隧道重新选择会话。"))
            return
        }
        let generation = (generations[id] ?? 0) + 1
        generations[id] = generation
        states[id] = .starting
        let observer = TunnelObserver { [weak self] message in
            Task { @MainActor in self?.connectionLost(id, generation: generation, message: message) }
        }
        let starter = starter
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try starter(profile, tunnel, observer) }
            }.value
            guard generations[id] == generation else {
                if case let .success(handle) = result { handle.stop() }
                return
            }
            switch result {
            case let .success(handle):
                handles[id] = handle
                states[id] = .running(connections: 0)
                startPolling()
            case let .failure(error):
                states[id] = .failed(Self.message(for: error))
            }
        }
    }

    func stop(_ id: UUID) {
        generations[id, default: 0] += 1
        handles.removeValue(forKey: id)?.stop()
        if states[id] != nil { states[id] = .stopped }
    }

    func reconnect(_ id: UUID) {
        stop(id)
        start(id)
    }

    func startAutomatic() {
        for tunnel in tunnels where tunnel.autoStart && tunnel.profileID != nil { start(tunnel.id) }
    }

    func stopAll() {
        for id in Array(handles.keys) { stop(id) }
        pollTask?.cancel()
        pollTask = nil
    }

    private func connectionLost(_ id: UUID, generation: Int, message: String?) {
        guard generations[id] == generation else { return }
        handles[id] = nil
        let detail = message.map { L10n.format("SSH 连接已断开：%@", $0) } ?? L10n.text("SSH 连接已断开")
        states[id] = .disconnected(detail)
    }

    /// Keeps the connection counts current while any tunnel is up.
    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.handles.isEmpty {
                    self.pollTask = nil
                    return
                }
                for (id, handle) in self.handles where !handle.isClosed() {
                    let next = TunnelState.running(connections: Int(handle.activeConnections()))
                    if self.states[id] != next { self.states[id] = next }
                }
            }
        }
    }

    // MARK: Core

    nonisolated static func startOverSSH(profile: SSHProfile, tunnel: SSHTunnel, observer: CoreTunnelObserver) throws -> CoreTunnelHandle {
        let authentication = try TerminalRuntime.authentication(for: profile)
        // The key file is only read while connecting.
        defer {
            if case let .privateKey(_, _, scopedURL) = authentication {
                scopedURL.stopAccessingSecurityScopedResource()
            }
        }
        let host = profile.host
        let port = UInt16(clamping: profile.port)
        let localPort = UInt16(clamping: tunnel.localPort)
        let remotePort = UInt16(clamping: tunnel.remotePort)
        switch authentication {
        case .password(let password):
            return try startLocalForwardPassword(
                host: host, port: port, username: profile.username, password: password,
                knownHostsPath: TerminalRuntime.knownHostsPath, acceptFingerprint: nil,
                localPort: localPort, remoteHost: tunnel.remoteHost, remotePort: remotePort, observer: observer
            )
        case .privateKey(let path, let passphrase, _):
            return try startLocalForwardPrivateKey(
                host: host, port: port, username: profile.username, privateKeyPath: path, passphrase: passphrase,
                knownHostsPath: TerminalRuntime.knownHostsPath, acceptFingerprint: nil,
                localPort: localPort, remoteHost: tunnel.remoteHost, remotePort: remotePort, observer: observer
            )
        }
    }

    nonisolated static func message(for error: Error) -> String {
        switch error {
        case CoreError.HostKeyUnknown:
            L10n.text("还没有信任这台服务器的主机指纹，请先从 Snake 打开一次它的终端并确认指纹。")
        case CoreError.HostKeyMismatch:
            L10n.text("服务器的主机指纹已变化，请先打开它的终端确认。")
        case let CoreError.Connection(message, stage):
            CoreErrorText.text(message, stage: stage, fallback: "隧道连接失败：%@")
        case let CoreError.Authentication(message, stage):
            CoreErrorText.text(message, stage: stage, fallback: "隧道认证失败：%@")
        case let CoreError.InvalidInput(message):
            L10n.format("隧道参数无效：%@", message)
        default:
            (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}
