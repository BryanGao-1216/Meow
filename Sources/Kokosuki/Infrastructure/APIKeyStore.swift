import Foundation
import Security

@MainActor
enum APIKeyStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.kokosuki.pet.volcengine",
        kSecAttrAccount as String: "api-key",
    ]
    private static let session = CredentialSession<String>(read: readFromKeychain, write: writeToKeychain)

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            if [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed].contains(status) {
                return "钥匙串未授权或尚未解锁，请确认登录钥匙串的访问权限。"
            }
            return "钥匙串：\(SecCopyErrorMessageString(status, nil) as String? ?? String(status))"
        }
    }

    static func load(retry: Bool = false) throws -> String { try session.load(retry: retry) }

    static func save(_ key: String) throws {
        try session.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func readFromKeychain() throws -> String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw Failure(status: errSecDecode)
        }
        return key
    }

    private static func writeToKeychain(_ value: String) throws {
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }
}
