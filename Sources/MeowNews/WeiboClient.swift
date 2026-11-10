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
        // 与用户在 weibo.com 获取的 Cookie 使用同一站点；不将网页版凭据复用于 m.weibo.cn。
        let data = try await get(topic.sourceURL, cookie: cookie, html: true)
        return try Self.parseSearchHTML(data, fallbackURL: topic.sourceURL)
    }

    /// 实际读取正文才算通过，不以公开热榜或钥匙串写入成功代替验证；不调用模型。
    public func validateCookie(_ cookie: String) async throws -> Int {
        let value = try WeiboCookie.normalized(cookie)
        guard !value.isEmpty else { throw NewsError.invalidCookie("请先填写网页版微博的完整 Cookie。") }
        let excerpts = try await fetchExcerpts(for: WeiboTopic(title: "微博", rank: 1), cookie: value)
        guard !excerpts.isEmpty else { throw NewsError.noExcerpts }
        return excerpts.count
    }

    private func get(_ url: URL, cookie: String, html: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        let value = try WeiboCookie.normalized(cookie)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        let connection = session ?? URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { if session == nil { connection.invalidateAndCancel() } }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        request.setValue(url.host == "s.weibo.com" ? "https://s.weibo.com/" : "https://weibo.com/", forHTTPHeaderField: "Referer")
        request.setValue(html ? "text/html,application/xhtml+xml" : "application/json", forHTTPHeaderField: "Accept")
        if !value.isEmpty { request.setValue(value, forHTTPHeaderField: "Cookie") }
        let (bytes, response) = try await connection.bytes(for: request, delegate: NoRedirect())
        guard let http = response as? HTTPURLResponse else { throw NewsError.invalidResponse }
        if (300..<400).contains(http.statusCode) {
            let location = http.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
            let host = location?.host?.lowercased() ?? ""
            if ["passport.weibo.com", "login.sina.com.cn", "visitor.passport.weibo.cn"].contains(host)
                || location?.path.lowercased().contains("login") == true { throw NewsError.loginRequired }
            throw NewsError.unexpectedRedirect
        }
        if http.statusCode == 401 { throw NewsError.loginRequired }
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
            if loginPage(prefix) { throw NewsError.loginRequired }
            throw NewsError.invalidResponse
        }
        if let ok = root["ok"] as? Int, ok != 1 {
            let message = root["msg"] as? String ?? root["message"] as? String ?? ""
            if ok == -100 || ["登录", "登陆", "验证"].contains(where: message.contains) { throw NewsError.loginRequired }
            throw NewsError.requestRejected
        }
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

    /// 只提取带帖子编号的微博卡片正文，不将页面导航、推荐词或登录说明当作新闻。
    public static func parseSearchHTML(_ data: Data, fallbackURL: URL) throws -> [NewsExcerpt] {
        guard let html = String(data: data, encoding: .utf8) else { throw NewsError.invalidResponse }
        let cards = matches("<div\\b[^>]*\\bclass\\s*=\\s*[\"'][^\"']*\\bcard-wrap\\b[^\"']*[\"'][^>]*>", in: html)
        var excerpts: [NewsExcerpt] = [], seen = Set<String>()
        let source = html as NSString
        for (index, card) in cards.prefix(100).enumerated() {
            let tag = source.substring(with: card.range)
            guard let mid = attribute("mid", in: tag), !mid.isEmpty, mid.allSatisfy(\.isNumber),
                  attribute("ad-data", in: tag) == nil, attribute("data-ad", in: tag) == nil else { continue }
            let end = index + 1 < cards.count ? cards[index + 1].range.location : source.length
            let block = source.substring(with: NSRange(location: NSMaxRange(card.range), length: end - NSMaxRange(card.range)))
            let paragraphs = matches("<p\\b[^>]*\\bnode-type\\s*=\\s*[\"']feed_list_content(?:_full)?[\"'][^>]*>(.*?)</p\\s*>", in: block)
            let full = paragraphs.first { attribute("node-type", in: (block as NSString).substring(with: $0.range)) == "feed_list_content_full" }
            guard let paragraph = full ?? paragraphs.first else { continue }
            var text = plainText((block as NSString).substring(with: paragraph.range(at: 1)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in ["收起全文", "展开全文"] where text.hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard text.count >= 8, seen.insert(text).inserted else { continue }
            var url = fallbackURL
            let metadata = matches("<p\\b[^>]*\\bclass\\s*=\\s*[\"'][^\"']*\\bfrom\\b[^\"']*[\"'][^>]*>(.*?)</p\\s*>", in: block)
                .first.map { (block as NSString).substring(with: $0.range(at: 1)) } ?? ""
            for link in matches("<a\\b[^>]*>", in: metadata) {
                guard let href = attribute("href", in: (metadata as NSString).substring(with: link.range)),
                      let candidate = URL(string: href.hasPrefix("//") ? "https:" + href : href),
                      ["weibo.com", "www.weibo.com"].contains(candidate.host?.lowercased() ?? ""),
                      candidate.path.range(of: "^/[0-9]+/[0-9A-Za-z]+$", options: .regularExpression) != nil else { continue }
                var parts = URLComponents(url: candidate, resolvingAgainstBaseURL: false)
                parts?.scheme = "https"; parts?.query = nil; parts?.fragment = nil
                if let cleanURL = parts?.url { url = cleanURL; break }
            }
            excerpts.append(NewsExcerpt(text: String(text.prefix(600)), sourceURL: url))
            if excerpts.count == 3 { return excerpts }
        }
        if !excerpts.isEmpty { return excerpts }
        if loginPage(html) { throw NewsError.loginRequired }
        if html.contains("card-no-result") || html.contains("没有找到相关微博") { return [] }
        throw NewsError.invalidResponse
    }

    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let opening = String(tag.prefix { $0 != ">" })
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let match = matches(pattern, in: opening).first else { return nil }
        return (opening as NSString).substring(with: match.range(at: 1))
    }

    private static func loginPage(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["sina visitor system", "visitor.passport.weibo", "passport.weibo.com/visitor", "请先登录后再访问", "登录后查看搜索结果"]
            .contains(where: lower.contains)
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
