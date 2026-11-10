import Foundation
import MeowNews

/// 固定网页与 URLProtocol 回环，不读取真实 Cookie，不访问微博或模型。
@MainActor
enum WeiboClientSelfTest {
    private static let page = """
    <html><body>
    <div class="card-wrap" mid="1001">
      <p class="txt" node-type="feed_list_content">这是被截断的简短正文。</p>
      <p node-type="feed_list_content_full" class="txt">研究团队公布人工智能进展<br>附数据 &amp; 资料。<a href="https://weibo.com/999/Other">相关链接</a><a>收起全文</a></p>
      <p class="from"><a href="//weibo.com/123/AbCd?refer_flag=test">今天</a></p>
    </div>
    <div mid='1002' class='card-wrap other'>
      <p node-type='feed_list_content'>第二条真实微博正文，内容和上一条不同。</p>
      <p class='from'><a href='https://example.com/private'>非微博地址</a></p>
    </div>
    <div class="card-wrap" mid="1003" ad-data="advertisement"><p node-type="feed_list_content">广告内容不应成为新闻摘录。</p></div>
    <div class="card-wrap"><p node-type="feed_list_content">没有帖子编号的推荐文字不应成为正文。</p></div>
    </body></html>
    """

    static func run() async -> Int {
        var checks = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("weibo client FAIL: \(label)") }
        }
        let topic = WeiboTopic(title: "人工智能进展", rank: 1)
        do {
            check(try WeiboCookie.normalized(" Cookie: SUB=fake-test;SUBP=test==; ") == "SUB=fake-test; SUBP=test==", "接受请求头前缀并保留值中的等号")
            check(try WeiboCookie.normalized("   ").isEmpty, "允许清空凭据")
            for value in ["private-test-value", "SUBP=private-test-value", "SUB=", "SUB=private-test-value\r\nX-Extra: invalid", "curl -H 'Cookie: SUB=private-test-value'"] {
                do { _ = try WeiboCookie.normalized(value); check(false, "拒绝不完整 Cookie 或请求头注入") }
                catch { check(!error.localizedDescription.contains("private-test-value"), "错误提示不泄露输入值") }
            }
            let excerpts = try WeiboClient.parseSearchHTML(Data(page.utf8), fallbackURL: topic.sourceURL)
            check(excerpts.count == 2, "只提取真实帖子，忽略广告和页面推荐")
            check(excerpts.first?.text.contains("附数据 & 资料") == true && excerpts.first?.text.contains("被截断") == false,
                  "优先完整正文并清除标记")
            check(excerpts.first?.text.contains("收起全文") == false && excerpts.first?.text.contains("<") == false,
                  "去除界面动作与 HTML")
            check(excerpts.first?.sourceURL.absoluteString == "https://weibo.com/123/AbCd", "来源取自帖子时间链接，而非正文引用链接")
            check(excerpts.last?.sourceURL == topic.sourceURL, "不接受外站来源地址")
            check(try WeiboClient.parseSearchHTML(Data("<div class='card-no-result'>没有找到相关微博</div>".utf8), fallbackURL: topic.sourceURL).isEmpty,
                  "没有搜索结果不误报 Cookie 失效")
            for (body, login) in [("<html>Sina Visitor System</html>", true), ("<html>未知页面结构</html>", false)] {
                do { _ = try WeiboClient.parseSearchHTML(Data(body.utf8), fallbackURL: topic.sourceURL); check(false, "无正文页面明确失败") }
                catch NewsError.loginRequired { check(login, "只有登录页面报告登录验证") }
                catch NewsError.invalidResponse { check(!login, "页面结构变化报告解析问题") }
                catch { check(false, "网页错误分类") }
            }
            do { _ = try WeiboClient.parseTopics(Data("{\"ok\":0,\"msg\":\"系统繁忙\"}".utf8)); check(false, "接口拒绝须报错") }
            catch NewsError.requestRejected { check(true, "非登录错误不会要求用户重新登录") }
            catch { check(false, "JSON 错误分类") }
        } catch { check(false, "解析检查：\(error.localizedDescription)") }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeiboDiagnosticProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = WeiboClient(session: session)
        do {
            WeiboDiagnosticProtocol.prepare([.init(status: 200, body: page)])
            let excerpts = try await client.fetchExcerpts(for: topic, cookie: "Cookie: SUB=fake-test; SUBP=test")
            let request = WeiboDiagnosticProtocol.recorded().first
            check(excerpts.count == 2 && request?.url?.host == "s.weibo.com", "网页版 Cookie 读取同站点正文")
            check(request?.value(forHTTPHeaderField: "Cookie") == "SUB=fake-test; SUBP=test", "实际请求携带规范化的 Cookie")
            check(request?.value(forHTTPHeaderField: "Referer") == "https://s.weibo.com/"
                  && request?.value(forHTTPHeaderField: "Accept")?.contains("text/html") == true, "网页版请求使用对应 Referer 和内容类型")
            check(request?.httpShouldHandleCookies == false, "不从共享 Cookie 容器覆盖显式凭据")
            WeiboDiagnosticProtocol.prepare([.init(status: 200, body: page)])
            check(try await client.validateCookie("SUB=fake-test") == 2, "验证必须实际读到正文，不调用模型")
            WeiboDiagnosticProtocol.prepare([.init(status: 302, body: "", headers: ["Location": "https://passport.weibo.com/login"])])
            do { _ = try await client.validateCookie("SUB=fake-test"); check(false, "拒绝登录跳转") }
            catch NewsError.loginRequired { check(WeiboDiagnosticProtocol.recorded().count == 1, "登录跳转明确提示且不跟随转发 Cookie") }
            WeiboDiagnosticProtocol.prepare([.init(status: 302, body: "", headers: ["Location": "https://example.com/other"])])
            do { _ = try await client.validateCookie("SUB=fake-test"); check(false, "拒绝其他跳转") }
            catch NewsError.unexpectedRedirect { check(WeiboDiagnosticProtocol.recorded().count == 1, "非登录跳转不伪装成 Cookie 过期") }
            WeiboDiagnosticProtocol.prepare([.init(status: 403, body: "Forbidden")])
            do { _ = try await client.validateCookie("SUB=fake-test"); check(false, "访问限制须报错") }
            catch NewsError.http(let code) { check(code == 403, "HTTP 403 保留访问限制原因，不断言登录失效") }
            WeiboDiagnosticProtocol.prepare([.init(status: 200, body: "<div class='card-no-result'></div>")])
            do { _ = try await client.validateCookie("SUB=fake-test"); check(false, "没有正文不算验证成功") }
            catch NewsError.noExcerpts { check(true, "空搜索结果与登录失败分开") }
            WeiboDiagnosticProtocol.prepare([.init(status: 200, body: "{\"ok\":1,\"data\":{\"band_list\":[]}}"),
                                             .init(status: 200, body: "{\"ok\":1,\"data\":{\"realtime\":[{\"word\":\"人工智能新进展\",\"realpos\":1}]}}")])
            check(try await client.fetchTopics().count == 1, "保留公开热榜备用接口")
            check(WeiboDiagnosticProtocol.recorded().allSatisfy { $0.url?.host == "weibo.com" && $0.value(forHTTPHeaderField: "Cookie") == nil }, "未填写 Cookie 时热榜仍匿名请求")
        } catch { check(false, "模拟 HTTP：\(error.localizedDescription)") }
        print("weibo client: \(checks - failures)/\(checks) OK（模拟 HTTP、网页和凭据，无真实 Cookie 或网络）")
        return failures
    }
}

private final class WeiboDiagnosticProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status: Int; var body: String; var headers: [String: String] = [:] }
    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var requests: [URLRequest] = []
    static func prepare(_ values: [Reply]) { lock.lock(); defer { lock.unlock() }; replies = values; requests = [] }
    static func recorded() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let reply = Self.replies.isEmpty ? Reply(status: 500, body: "") : Self.replies.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
