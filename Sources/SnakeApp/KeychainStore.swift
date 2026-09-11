import Foundation
import Security

public enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "无法访问系统钥匙串（状态码 \(status)）。"
        case .invalidData:
            "钥匙串中的凭据格式无效。"
        }
    }
}

public enum KeychainStore {
    public static let service = "com.snake.ssh.credentials"
#if DEBUG
    private static let debugCache = DebugCredentialCache()
#endif

    public static func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
#if DEBUG
            debugCache.store(data, for: account)
#endif
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        guard insertStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(insertStatus)
        }
#if DEBUG
        debugCache.store(data, for: account)
#endif
    }

    public static func read(account: String) throws -> String? {
        guard let data = try readData(account: account) else { return nil }
        guard let secret = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return secret
    }

    public static func readData(account: String) throws -> Data? {
#if DEBUG
        if let cached = debugCache.value(for: account) { return cached }
#endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainStoreError.invalidData
        }
#if DEBUG
        debugCache.store(data, for: account)
#endif
        return data
    }

    public static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
#if DEBUG
        debugCache.removeValue(for: account)
#endif
    }
}

#if DEBUG
/// Ad-hoc debug signatures change after every rebuild and macOS therefore asks
/// for Keychain approval again. Cache only inside the current debug process so
/// terminal and SFTP connections share the one approved lookup. Release builds
/// never compile this cache and continue to read directly from Keychain.
private final class DebugCredentialCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func value(for account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func store(_ value: Data, for account: String) {
        lock.lock()
        values[account] = value
        lock.unlock()
    }

    func removeValue(for account: String) {
        lock.lock()
        values.removeValue(forKey: account)
        lock.unlock()
    }
}
#endif
