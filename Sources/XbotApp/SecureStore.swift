import Foundation
import Security

enum SecureStore {
    static func read(_ account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func write(_ data: Data, account: String) throws {
        let query = base(account)
        let updates: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if result == errSecItemNotFound {
            let status = SecItemAdd(query.merging(updates) { _, new in new } as CFDictionary, nil)
            guard status == errSecSuccess else { throw ServerError("无法安全保存登录信息（\(status)）") }
        } else if result != errSecSuccess { throw ServerError("无法安全保存登录信息（\(result)）") }
    }
    static func delete(_ account: String) { SecItemDelete(base(account) as CFDictionary) }
    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.xbot.ios", kSecAttrAccount as String: account]
    }
}

struct SavedCredentials: Codable {
    var username: String
    var password: String
}
