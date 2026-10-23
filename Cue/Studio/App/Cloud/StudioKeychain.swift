import Foundation
import Security

/// Secrets this app keeps — today only Google Drive's refresh token — in the login
/// keychain rather than in defaults, where any process that can read a plist could take
/// one and act as the user's Drive.
nonisolated enum StudioKeychain {
    private static let service = "com.stackrover.cue.studio"

    static func get(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`, or removes the item when it is nil.
    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        SecItemDelete(base(account) as CFDictionary)
        guard let value else { return true }
        var item = base(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
