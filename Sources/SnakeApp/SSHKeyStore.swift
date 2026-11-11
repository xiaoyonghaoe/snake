import Foundation
import SnakeCoreBindings

/// One key in Snake's key library.
public struct SSHKeyRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var algorithm: String
    public var fingerprint: String
    /// One `authorized_keys` line.
    public var publicKey: String
    public var hasPassphrase: Bool
    public var createdAt: Date
    /// Renaming counts as a change. Older indexes lack it and fall back to `createdAt`.
    public var updatedAt: Date

    var passphraseAccount: String { Self.passphraseAccount(for: id) }

    static func passphraseAccount(for id: UUID) -> String { "ssh-key/\(id.uuidString)/passphrase" }

    /// `ssh-ed25519` reads as `Ed25519`, `ssh-rsa` as `RSA`.
    var algorithmLabel: String {
        switch algorithm {
        case "ssh-ed25519": "Ed25519"
        case "ssh-rsa": "RSA"
        case let value where value.hasPrefix("ecdsa-"): "ECDSA"
        default: algorithm
        }
    }
}

extension SSHKeyRecord {
    private enum CodingKeys: String, CodingKey {
        case id, name, algorithm, fingerprint, publicKey, hasPassphrase, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        algorithm = try container.decode(String.self, forKey: .algorithm)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        publicKey = try container.decode(String.self, forKey: .publicKey)
        hasPassphrase = try container.decode(Bool.self, forKey: .hasPassphrase)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

public enum SSHKeyError: LocalizedError, Equatable {
    case nameRequired
    case unreadable
    case unrecognized
    case passphraseRequired
    case passphraseIncorrect
    case duplicate(String)
    case inUse([String])
    case generationFailed

    public var errorDescription: String? {
        switch self {
        case .nameRequired: L10n.text("请填写密钥名称。")
        case .unreadable: L10n.text("无法读取所选的私钥文件。")
        case .unrecognized: L10n.text("无法识别为私钥。请选择 OpenSSH、PEM 或 PuTTY 格式的私钥文件（不是 .pub 公钥）。")
        case .passphraseRequired: L10n.text("这把私钥已加密，请填写口令。")
        case .passphraseIncorrect: L10n.text("私钥口令不正确。")
        case .duplicate(let name): L10n.format("密钥管理中已有同一把密钥「%@」。", name)
        case .inUse(let names): L10n.format("以下会话正在使用这把密钥，请先为它们换用其他私钥：%@", names.joined(separator: "、"))
        case .generationFailed: L10n.text("生成密钥失败，请重试。")
        }
    }

    /// Maps the stable codes `snake_core` uses for key problems.
    init(_ error: Error) {
        guard case let CoreError.InvalidInput(message) = error else {
            self = .unrecognized
            return
        }
        switch message {
        case "passphrase_required": self = .passphraseRequired
        case "passphrase_incorrect": self = .passphraseIncorrect
        case "generation_failed": self = .generationFailed
        default: self = .unrecognized
        }
    }
}

/// Keys live as `<id>` files (owner-only, like `~/.ssh`) beside an `index.json`
/// in Application Support/Snake/Keys. Sessions reference a key by a bookmark
/// to its file, so terminals, SFTP, MCP and SSHFS all use the same path.
struct SSHKeyStore: Sendable {
    let root: URL
    /// Writes (or with `nil` deletes) a passphrase; production uses the
    /// encrypted credential file shared with session passwords.
    let storePassphrase: @Sendable (String?, String) throws -> Void

    static let `default` = SSHKeyStore(
        root: (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            .map { $0.appendingPathComponent("Snake/Keys", isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Snake/Keys", isDirectory: true),
        storePassphrase: { secret, account in
            if let secret { try CredentialStore.save(secret, account: account) }
            else { try CredentialStore.delete(account: account) }
        }
    )

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    func fileURL(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: false)
    }

    func load() -> [SSHKeyRecord] {
        guard let data = try? Data(contentsOf: indexURL),
              let records = try? JSONDecoder().decode([SSHKeyRecord].self, from: data) else { return [] }
        // An entry whose file vanished cannot be used by any session.
        return records.filter { FileManager.default.fileExists(atPath: fileURL(for: $0.id).path) }
    }

    func add(name: String, key: CoreSshKey, passphrase: String?) throws -> SSHKeyRecord {
        try prepare()
        let record = SSHKeyRecord(
            id: UUID(),
            name: name,
            algorithm: key.algorithm,
            fingerprint: key.fingerprint,
            publicKey: key.publicKey,
            hasPassphrase: key.encrypted,
            createdAt: .now,
            updatedAt: .now
        )
        let file = fileURL(for: record.id)
        guard FileManager.default.createFile(atPath: file.path, contents: Data(key.privateKey.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        do {
            if key.encrypted, let passphrase { try storePassphrase(passphrase, record.passphraseAccount) }
            try write(load() + [record])
        } catch {
            try? FileManager.default.removeItem(at: file)
            try? storePassphrase(nil, record.passphraseAccount)
            throw error
        }
        return record
    }

    func rename(id: UUID, to name: String) throws {
        try write(load().map { record in
            var renamed = record
            if record.id == id, record.name != name {
                renamed.name = name
                renamed.updatedAt = .now
            }
            return renamed
        })
    }

    func delete(id: UUID) throws {
        let remaining = load().filter { $0.id != id }
        try write(remaining)
        try? FileManager.default.removeItem(at: fileURL(for: id))
        try? storePassphrase(nil, SSHKeyRecord.passphraseAccount(for: id))
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func write(_ records: [SSHKeyRecord]) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: indexURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }
}
