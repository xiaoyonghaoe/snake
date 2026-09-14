import CryptoKit
import Foundation

public enum CredentialStoreError: LocalizedError {
    case invalidFile
    case cannotCreateFile
    case missingKey
    case invalidKey
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidFile:
            L10n.text("凭据文件格式无效或版本不受支持，原文件未被覆盖。")
        case .cannotCreateFile:
            L10n.text("无法安全保存加密凭据文件。")
        case .missingKey:
            L10n.text("找不到凭据加密密钥，无法解密。请恢复原钥匙串；原凭据文件不会被覆盖。")
        case .invalidKey:
            L10n.text("钥匙串中的凭据加密密钥格式无效。")
        case .authenticationFailed:
            L10n.text("凭据解密验证失败，文件可能损坏或密钥不匹配。原文件未被覆盖。")
        }
    }
}

/// Connection callers do not require a UI authentication challenge. Only the
/// explicit reveal UI adds local device-owner authentication.
public enum CredentialStore {
    private static let backend = EncryptedCredentialStore.default

    static func prepare() throws { try backend.prepare() }

    public static func save(_ secret: String, account: String) throws {
        try backend.save(secret, account: account)
    }

    public static func readData(account: String) throws -> Data? {
        if let secret = try backend.read(account: account) {
            return Data(secret.utf8)
        }

        // Legacy credential entries remain readable, but never migrate back to
        // plaintext. Storage errors above must not fall through to this path.
        if let legacy = try KeychainStore.read(account: account) {
            try backend.save(legacy, account: account)
            return Data(legacy.utf8)
        }
        return nil
    }

    public static func delete(account: String) throws {
        try backend.delete(account: account)
        // Otherwise a subsequent compatibility read could resurrect a secret.
        try KeychainStore.delete(account: account)
    }
}

protocol CredentialEncryptionKeyProviding: Sendable {
    func loadKey() throws -> Data?
    func createKey() throws -> Data
}

final class EncryptedCredentialStore: @unchecked Sendable {
    static let `default` = EncryptedCredentialStore(fileURL: defaultFileURL, keys: CredentialEncryptionKeyStore())

    private struct Envelope: Codable {
        let version: Int
        let sealedBox: Data
    }
    private static let authenticatedHeader = Data("com.snake.credentials:v1:AES-256-GCM".utf8)

    let fileURL: URL
    private let lock = NSLock()
    private let manager: FileManager
    private let keys: any CredentialEncryptionKeyProviding
    private let replace: (URL, URL) throws -> Void

    init(
        fileURL: URL,
        keys: any CredentialEncryptionKeyProviding,
        manager: FileManager = .default,
        replace: @escaping (URL, URL) throws -> Void = { temporary, destination in
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        }
    ) {
        self.fileURL = fileURL
        self.manager = manager
        self.keys = keys
        self.replace = replace
    }

    func save(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var credentials = try loadUnlocked()
        credentials[account] = secret
        try persistUnlocked(credentials)
    }

    func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try loadUnlocked()
    }

    func read(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()[account]
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var credentials = try loadUnlocked()
        guard credentials.removeValue(forKey: account) != nil else { return }
        try persistUnlocked(credentials)
    }

    private func loadUnlocked() throws -> [String: String] {
        guard manager.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            guard envelope.version == 1 else { throw CredentialStoreError.invalidFile }
            guard let keyData = try keys.loadKey() else { throw CredentialStoreError.missingKey }
            return try decrypt(envelope, key: validatedKey(keyData))
        }
        guard let credentials = try? JSONDecoder().decode([String: String].self, from: data),
              credentials["version"] == nil, credentials["sealedBox"] == nil else {
            throw CredentialStoreError.invalidFile
        }
        // Migrate the whole legacy dictionary, including accounts other than
        // the one requested. No plaintext backup or temporary file is created.
        try persistUnlocked(credentials)
        return credentials
    }

    private func validatedKey(_ data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw CredentialStoreError.invalidKey }
        return SymmetricKey(data: data)
    }

    private func decrypt(_ envelope: Envelope, key: SymmetricKey) throws -> [String: String] {
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealedBox)
            let plaintext = try AES.GCM.open(box, using: key, authenticating: Self.authenticatedHeader)
            return try JSONDecoder().decode([String: String].self, from: plaintext)
        } catch {
            throw CredentialStoreError.authenticationFailed
        }
    }

    private func persistUnlocked(_ credentials: [String: String]) throws {
        let keyData: Data
        if let existing = try keys.loadKey() {
            keyData = existing
        } else {
            // The key could have been removed after loadUnlocked decrypted the
            // file. Never silently rotate it while updating an existing vault.
            if manager.fileExists(atPath: fileURL.path),
               (try? JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))) != nil {
                throw CredentialStoreError.missingKey
            }
            keyData = try keys.createKey()
        }
        let key = try validatedKey(keyData)
        let plaintext = try JSONEncoder().encode(credentials)
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: Self.authenticatedHeader)
        guard let combined = box.combined else { throw CredentialStoreError.cannotCreateFile }
        let envelope = Envelope(version: 1, sealedBox: combined)
        let data = try JSONEncoder().encode(envelope)
        guard try decrypt(envelope, key: key) == credentials else { throw CredentialStoreError.authenticationFailed }
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let temporaryURL = directory.appendingPathComponent(".credentials-\(UUID().uuidString).tmp")
        guard manager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CredentialStoreError.cannotCreateFile
        }

        do {
            let written = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: temporaryURL))
            guard try decrypt(written, key: key) == credentials else { throw CredentialStoreError.authenticationFailed }
            try replace(temporaryURL, fileURL)
        } catch {
            try? manager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static var defaultFileURL: URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Snake/credentials.json")
    }
}
