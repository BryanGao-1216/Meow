import Foundation

public enum WeiboCookie {
    /// 接受完整请求头的值或 `Cookie: ...`，不接受 cURL、Set-Cookie 或单独的密钥值。
    public static func normalized(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "" }
        guard value.utf8.count <= 16000, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NewsError.invalidCookie("Cookie 必须是一行完整的请求头值，长度不超过 16000 字节。")
        }
        if value.lowercased().hasPrefix("cookie:") { value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        var pairs: [String] = [], hasLogin = false
        for raw in value.split(separator: ";", omittingEmptySubsequences: true) {
            let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil else {
                throw NewsError.invalidCookie("请复制请求头中的完整 Cookie（名称=值; 名称=值），不要填写 cURL、Set-Cookie 或单独的值。")
            }
            if parts[0] == "SUB", !parts[1].isEmpty { hasLogin = true }
            pairs.append(String(parts[0]) + "=" + String(parts[1]))
        }
        guard hasLogin else { throw NewsError.invalidCookie("Cookie 中缺少登录凭据 SUB。请登录 weibo.com 后，从网页请求头重新复制完整 Cookie。") }
        return pairs.joined(separator: "; ")
    }
}
