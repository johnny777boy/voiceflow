import Foundation
import Security

/// Keychain-backed secret storage for the optional LLM cleanup API key.
/// Conforms to `SecureStoring` so callers depend on the protocol, not Keychain.
public final class KeychainStore: SecureStoring, @unchecked Sendable {
    private let service: String

    public init(service: String = VoiceFlowInfo.bundleIdentifier) {
        self.service = service
    }

    public func setSecret(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        // Delete any existing item first so we can cleanly add.
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VoiceFlowError.keychainFailure("add failed (\(status))")
        }
    }

    public func secret(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw VoiceFlowError.keychainFailure("read failed (\(status))")
        }
        return String(data: data, encoding: .utf8)
    }

    public func deleteSecret(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VoiceFlowError.keychainFailure("delete failed (\(status))")
        }
    }
}
