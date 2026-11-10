import Foundation
import Security
import MeowNews

/// 微博登录凭据独立存放于钥匙串；不写入偏好文件或热点缓存。
enum WeiboCookieStore {
    private static let service = AppIdentity.bundleIdentifier + ".weibo"

    static func load() throws -> String {
        guard let data = try KeychainStore.load(service: service, account: "cookie") else { return "" }
        guard let value = String(data: data, encoding: .utf8) else {
            throw APIKeyStore.Failure(status: errSecDecode)
        }
        return try WeiboCookie.normalized(value)
    }

    static func save(_ cookie: String) throws {
        let value = try WeiboCookie.normalized(cookie)
        try KeychainStore.save(Data(value.utf8), service: service, account: "cookie")
    }
}
