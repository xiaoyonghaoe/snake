import CryptoKit
import Foundation
import Security

/// Separate from legacy per-profile Keychain entries. No biometric ACL: the
/// approved app needs this key for unattended connections and transfers.
final class CredentialEncryptionKeyStore: CredentialEncryptionKeyProviding {
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.snake.credentials.encryption",
            kSecAttrAccount as String: "master-key-v1",
            kSecAttrSynchronizable as String: false
        ]
    }

    func loadKey() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
        guard let data = result as? Data, data.count == 32 else { throw CredentialStoreError.invalidKey }
        return data
    }

    func createKey() throws -> Data {
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var request = query
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        request[kSecAttrLabel as String] = "Snake 凭据加密密钥"
        let status = SecItemAdd(request as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard let existing = try loadKey() else { throw CredentialStoreError.missingKey }
            return existing
        }
        guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
        return data
    }
}
