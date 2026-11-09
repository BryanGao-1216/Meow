import Foundation

/// 仅请求微博官方域名。登录凭据不进入日志、缓存文件或模型提示词。
public struct WeiboClient: Sendable {
    private let session: URLSession?
    public init(session: URLSession? = nil) { self.session = session }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            // 访客验证跳转交给用户正常登录，不将 Cookie 跟随到其他地址。
            completionHandler(nil)
        }
    }

    public func fetchTopics(cookie: String = "", at date: Date = .now) async throws -> [WeiboTopic] {
        do {
            let data = try await get(URL(string: "https://weibo.com/ajax/statuses/hot_band")!, cookie: cookie)
            return try Self.parseTopics(data, at: date)
        } catch {
            try Task.checkCancellation()
            let data = try await get(URL(string: "https://weibo.com/ajax/side/hotSearch")!, cookie: cookie)
            return try Self.parseTopics(data, at: date)
        }
    }

    public func fetchExcerpts(for topic: WeiboTopic, cookie: String = "") async throws -> [NewsExcerpt] {
        var url = URLComponents(string: "https://m.weibo.cn/api/container/getIndex")!
        url.queryItems = [URLQueryItem(name: "containerid", value: "100103type=1&q=\(topic.title)"),
                          URLQueryItem(name: "page_type", value: "searchall")]
        let data = try await get(url.url!, cookie: cookie)
        return try Self.parseExcerpts(data, fallbackURL: topic.sourceURL)
    }

    private func get(_ url: URL, cookie: String) async throws -> Data {
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        let connection = session ?? URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { if session == nil { connection.invalidateAndCancel() } }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue(url.host == "m.weibo.cn" ? "https://m.weibo.cn/" : "https://weibo.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !cookie.isEmpty, !cookie.contains("\n"), !cookie.contains("\r") { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (bytes, response) = try await connection.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw NewsError.invalidResponse }
        if [301, 302, 303, 307, 308, 401, 403].contains(http.statusCode) { throw NewsError.loginRequired }
        guard (200..<300).contains(http.statusCode) else { throw NewsError.http(http.statusCode) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            if data.count > 1_000_000 { throw NewsError.responseTooLarge }
        }
        return data
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let prefix = String(decoding: data.prefix(500), as: UTF8.self).lowercased()
            if prefix.contains("html") || prefix.contains("visitor") || prefix.contains("passport") { throw NewsError.loginRequired }
            throw NewsError.invalidResponse
        }
        if let ok = root["ok"] as? Int, ok != 1 { throw NewsError.loginRequired }
        return root
    }

    public static func parseTopics(_ data: Data, at date: Date = .now) throws -> [WeiboTopic] {
        let root = try object(data)
        guard let payload = root["data"] as? [String: Any],
              let list = (payload["band_list"] ?? payload["realtime"]) as? [[String: Any]] else { throw NewsError.invalidResponse }
        var result: [WeiboTopic] = []
        var seen = Set<String>()
        for item in list.prefix(100) {
            let rank = (item["realpos"] as? Int) ?? (item["rank"] as? Int).map { $0 + 1 } ?? 0
            let ad = (item["is_ad"] as? NSNumber)?.boolValue == true || item["label_name"] as? String == "广告"
            guard rank > 0, !ad, let raw = (item["word"] ?? item["note"] ?? item["word_scheme"]) as? String else { continue }
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#＃"))
            guard (2...100).contains(title.count), !WeiboTopic.identity(title).isEmpty else { continue }
            let topic = WeiboTopic(title: title, category: String(((item["category"] ?? item["field_tag"]) as? String ?? "").prefix(40)),
                                   rank: rank, heat: (item["raw_hot"] ?? item["num"]) as? Int ?? 0, fetchedAt: date)
            if seen.insert(topic.id).inserted { result.append(topic) }
        }
        guard !result.isEmpty else { throw NewsError.emptyList }
        return result.sorted { $0.rank < $1.rank }
    }

    public static func parseExcerpts(_ data: Data, fallbackURL: URL) throws -> [NewsExcerpt] {
        let root = try object(data)
        guard let payload = root["data"] as? [String: Any], let cards = payload["cards"] as? [[String: Any]] else { throw NewsError.invalidResponse }
        var flattened: [[String: Any]] = []
        for card in cards.prefix(30) {
            flattened.append(card)
            if let group = card["card_group"] as? [[String: Any]] { flattened.append(contentsOf: group.prefix(20)) }
        }
        var result: [NewsExcerpt] = []
        var seen = Set<String>()
        for card in flattened {
            guard card["card_type"] as? Int == 9, let blog = card["mblog"] as? [String: Any],
                  let html = blog["text"] as? String else { continue }
            let text = plainText(html)
            guard text.count >= 8, seen.insert(text).inserted else { continue }
            let id = blog["idstr"] as? String ?? (blog["id"] as? NSNumber)?.stringValue ?? ""
            let source = !id.isEmpty && id.allSatisfy(\.isNumber) ? URL(string: "https://m.weibo.cn/detail/\(id)")! : fallbackURL
            result.append(NewsExcerpt(text: String(text.prefix(600)), sourceURL: source))
            if result.count == 3 { break }
        }
        return result
    }

    private static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(?:script|style)\\b[^>]*>.*?</(?:script|style)>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (entity, replacement) in [("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
