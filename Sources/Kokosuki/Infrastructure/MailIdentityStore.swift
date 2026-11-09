import Foundation
import Security
import KokosukiMailbox

/// 与云端 API Key 分开的设备身份；不写入信箱 JSON，也不随日志输出。
enum MailIdentityStore {
    static func loadOrCreate() throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.kokosuki.pet.iroh.identity", kSecAttrAccount as String: "ed25519-v1"]
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data, data.count == 32 else { throw MailError.invalid("信箱设备身份无法读取；不会自动覆盖原身份。") }
            return data
        }
        guard status == errSecItemNotFound else { throw APIKeyStore.Failure(status: status) }
        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard randomStatus == errSecSuccess else { throw APIKeyStore.Failure(status: randomStatus) }
        let key = Data(bytes)
        var creation = query
        creation[kSecValueData as String] = key
        creation[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let saved = SecItemAdd(creation as CFDictionary, nil)
        if saved == errSecDuplicateItem { return try loadOrCreate() }
        guard saved == errSecSuccess else { throw APIKeyStore.Failure(status: saved) }
        return key
    }
}
