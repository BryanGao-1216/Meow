import Foundation
import Security
import MeowMailbox

/// 与云端 API Key 分开的设备身份；不写入信箱 JSON，也不随日志输出。
enum MailIdentityStore {
    static func loadOrCreate() throws -> Data {
        let service = AppIdentity.bundleIdentifier + ".iroh.identity"
        let query = KeychainStore.query(service: service, account: "ed25519-v1")
        if let data = try KeychainStore.load(service: service, account: "ed25519-v1") {
            guard data.count == 32 else { throw MailError.invalid("信箱设备身份无法读取；不会自动覆盖原身份。") }
            return data
        }
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
