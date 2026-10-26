import Foundation
import Security

/// A ``SecretStore`` backed by the macOS login keychain (generic passwords,
/// legacy file-based keychain; see DECISIONS.md #5).
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = "com.jeremyhaber.Querywell.secrets"

    public let service: String

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    public func read(_ key: SecretKey) throws -> String? {
        var query = baseQuery(account: key.account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String, for key: SecretKey) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: key.account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Querywell: \(key.account)"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    public func delete(_ key: SecretKey) throws {
        try deleteAccount(key.account)
    }

    public func deleteAll(ownerID: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        query[kSecUseDataProtectionKeychain as String] = false
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        try check(status)
        let prefix = "\(ownerID)."
        for item in (result as? [[String: Any]]) ?? [] {
            if let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) {
                try deleteAccount(account)
            }
        }
    }

    private func deleteAccount(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        throw SecretStoreError.keychain(status: status, message: message)
    }
}
