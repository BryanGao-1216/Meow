import Foundation
import Security

/// 微博登录凭据独立存放于钥匙串；不写入偏好文件或热点缓存。
enum WeiboCookieStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.kokosuki.pet.weibo",
        kSecAttrAccount as String: "cookie",
    ]

    static func load() throws -> String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw APIKeyStore.Failure(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw APIKeyStore.Failure(status: errSecDecode)
        }
        return value
    }

    static func save(_ cookie: String) throws {
        let value = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("\n"), !value.contains("\r"), value.count <= 16000 else {
            throw NSError(domain: "高小喵", code: 1, userInfo: [NSLocalizedDescriptionKey: "请填写单行微博 Cookie，长度不超过 16000 字符。"])
        }
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw APIKeyStore.Failure(status: status) }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw APIKeyStore.Failure(status: added) }
        } else if status != errSecSuccess { throw APIKeyStore.Failure(status: status) }
    }
}
