import Foundation

public enum CredentialStoreError: LocalizedError {
    case invalidFile
    case cannotCreateFile

    public var errorDescription: String? {
        switch self {
        case .invalidFile:
            "临时凭据文件格式无效。"
        case .cannotCreateFile:
            "无法创建临时凭据文件。"
        }
    }
}

/// Facade kept deliberately small so the temporary plaintext backend can later
/// be replaced by a password-manager adapter without changing SSH/SFTP callers.
public enum CredentialStore {
    private static let backend = PlaintextCredentialStore.default

    public static func save(_ secret: String, account: String) throws {
        try backend.save(secret, account: account)
    }

    public static func readData(account: String) throws -> Data? {
        if let secret = try backend.read(account: account) {
            return Data(secret.utf8)
        }

        // One-time compatibility path for profiles created before the temporary
        // plaintext backend. A successful legacy read is immediately migrated;
        // subsequent terminal and SFTP connections no longer access Keychain.
        if let legacy = try KeychainStore.read(account: account) {
            try backend.save(legacy, account: account)
            return Data(legacy.utf8)
        }
        return nil
    }

    public static func delete(account: String) throws {
        try backend.delete(account: account)
    }
}

final class PlaintextCredentialStore: @unchecked Sendable {
    static let `default` = PlaintextCredentialStore(fileURL: defaultFileURL)

    let fileURL: URL
    private let lock = NSLock()
    private let manager: FileManager

    init(fileURL: URL, manager: FileManager = .default) {
        self.fileURL = fileURL
        self.manager = manager
    }

    func save(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var credentials = try loadUnlocked()
        credentials[account] = secret
        try persistUnlocked(credentials)
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
        guard let credentials = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw CredentialStoreError.invalidFile
        }
        return credentials
    }

    private func persistUnlocked(_ credentials: [String: String]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(credentials)
        let temporaryURL = directory.appendingPathComponent(".credentials-\(UUID().uuidString).tmp")
        guard manager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CredentialStoreError.cannotCreateFile
        }

        do {
            if manager.fileExists(atPath: fileURL.path) {
                _ = try manager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try manager.moveItem(at: temporaryURL, to: fileURL)
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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
