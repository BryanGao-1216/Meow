import Foundation
import Security

@MainActor
enum APIKeyStore {
    private static let service = AppIdentity.bundleIdentifier + ".volcengine"
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
        guard let data = try KeychainStore.load(service: service, account: "api-key") else { return "" }
        guard let key = String(data: data, encoding: .utf8) else { throw Failure(status: errSecDecode) }
        return key
    }

    private static func writeToKeychain(_ value: String) throws {
        try KeychainStore.save(Data(value.utf8), service: service, account: "api-key")
    }
}
