import XCTest
@testable import KokosukiNews

final class NewsTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private let sample = """
    {"ok":1,"data":{"band_list":[
      {"word":"人工智能新模型发布","category":"科技","realpos":2,"num":12345},
      {"word":"#人工智能新模型发布#","realpos":3},
      {"word":"广告商品","realpos":1,"is_ad":1},
      {"word":"置顶词条","realpos":0},
      {"word":"小猫获救后找到新家","category":"萌宠","realpos":5}
    ]}}
    """

    func testThreeDailyTimesUseBeijingClock() {
        XCTAssertNil(NewsSchedule.due(at: date("2026-11-09T10:59:59+08:00"), runs: []))
        for hour in [11, 16, 19] {
            let now = date("2026-11-09T\(hour):00:00+08:00")
            XCTAssertEqual(NewsSchedule.due(at: now, runs: [])?.date, now)
        }
        XCTAssertEqual(NewsSchedule.due(at: date("2026-11-09T08:00:00Z"), runs: [])?.id, "2026-11-09-16")
    }

    func testWakeOnlyCatchesUpWithinOneHour() {
        XCTAssertEqual(NewsSchedule.due(at: date("2026-11-09T16:45:00+08:00"), runs: [])?.id, "2026-11-09-16")
        XCTAssertNil(NewsSchedule.due(at: date("2026-11-09T17:00:00+08:00"), runs: []))
        XCTAssertNil(NewsSchedule.due(at: date("2026-11-09T10:00:00+08:00"), runs: []))
        XCTAssertNil(NewsSchedule.due(at: date("2026-11-09T23:00:00+08:00"), runs: []))
    }

    func testCompletedSlotsAreNotRepeated() {
        let now = date("2026-11-09T16:00:00+08:00")
        let done = NewsRun(slotID: "2026-11-09-16", attempts: 1, lastAttempt: now, completed: true)
        XCTAssertNil(NewsSchedule.due(at: now.addingTimeInterval(600), runs: [done]))
    }

    func testFailedSlotsBackOffAndHaveBoundedAttempts() {
        let now = date("2026-11-09T16:00:00+08:00")
        let first = NewsRun(slotID: "2026-11-09-16", attempts: 1, lastAttempt: now)
        XCTAssertNil(NewsSchedule.due(at: now.addingTimeInterval(299), runs: [first]))
        XCTAssertEqual(NewsSchedule.due(at: now.addingTimeInterval(300), runs: [first])?.id, first.slotID)
        let exhausted = NewsRun(slotID: first.slotID, attempts: 3, lastAttempt: now)
        XCTAssertNil(NewsSchedule.due(at: now.addingTimeInterval(600), runs: [exhausted]))
    }

    func testNextScheduleCrossesMidnight() {
        XCTAssertEqual(NewsSchedule.next(at: date("2026-11-09T19:00:00+08:00")), date("2026-11-10T11:00:00+08:00"))
        XCTAssertEqual(NewsSchedule.next(at: date("2026-11-09T11:00:00+08:00")), date("2026-11-09T16:00:00+08:00"))
    }

    func testHotBandParserSkipsAdsPinnedRowsAndDuplicates() throws {
        let now = date("2026-11-09T11:00:00+08:00")
        let topics = try WeiboClient.parseTopics(Data(sample.utf8), at: now)
        XCTAssertEqual(topics.count, 2)
        XCTAssertEqual(topics[0].title, "人工智能新模型发布")
        XCTAssertEqual(topics[0].rank, 2)
        XCTAssertEqual(topics[0].heat, 12345)
        XCTAssertEqual(topics[0].fetchedAt, now)
        XCTAssertEqual(topics[0].sourceURL.host, "s.weibo.com")
        XCTAssertTrue(topics[0].sourceURL.absoluteString.contains("q="))
    }

    func testAlternateHotSearchResponse() throws {
        let data = Data("{\"ok\":1,\"data\":{\"realtime\":[{\"word\":\"航天新进展\",\"realpos\":1}]}}".utf8)
        XCTAssertEqual(try WeiboClient.parseTopics(data).first?.title, "航天新进展")
    }

    func testBlockedMalformedAndEmptyResponsesFailExplicitly() {
        for raw in ["<html>Sina Visitor System</html>", "{\"ok\":-100}", "not-json", "{\"ok\":1,\"data\":{\"band_list\":[]}}"] {
            XCTAssertThrowsError(try WeiboClient.parseTopics(Data(raw.utf8)))
        }
    }

    func testExcerptsCleanMarkupAndKeepIndividualSources() throws {
        let data = Data("""
        {"ok":1,"data":{"cards":[{"card_type":11,"card_group":[
          {"card_type":9,"mblog":{"idstr":"123456789","text":"<script>不应留下</script><p>研究团队公布了新进展<br>附原始数据 &amp; 资料。</p>"}},
          {"card_type":9,"mblog":{"idstr":"123456789","text":"研究团队公布了新进展<br>附原始数据 &amp; 资料。"}}
        ]}]}}
        """.utf8)
        let result = try WeiboClient.parseExcerpts(data, fallbackURL: URL(string: "https://s.weibo.com/weibo")!)
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].text.contains("<"))
        XCTAssertFalse(result[0].text.contains("不应留下"))
        XCTAssertTrue(result[0].text.contains("& 资料"))
        XCTAssertEqual(result[0].sourceURL.absoluteString, "https://m.weibo.cn/detail/123456789")
    }

    func testTastePrioritizesInterestsAndHonorsDislikes() throws {
        let taste = NewsTaste(statements: ["主人关注人工智能", "主人不喜欢娱乐八卦"])
        let topics = [
            WeiboTopic(title: "明星用AI公开新恋情", category: "娱乐", rank: 1),
            WeiboTopic(title: "新一代大模型发布", category: "科技", rank: 20),
            WeiboTopic(title: "当地公交线路调整", category: "社会", rank: 2),
        ]
        let ranked = taste.ranked(topics, recent: [], at: .now)
        XCTAssertEqual(ranked.first?.title, "新一代大模型发布")
        XCTAssertFalse(ranked.contains { $0.category == "娱乐" })
        XCTAssertEqual(taste.localChoice(from: ranked)?.title, "新一代大模型发布")
    }

    func testLocalFallbackSkipsUnrelatedTopicsWhenTasteIsKnown() {
        let taste = NewsTaste(statements: ["主人关注人工智能"])
        XCTAssertNil(taste.localChoice(from: [WeiboTopic(title: "某歌手发布新歌", category: "音乐", rank: 1)]))
        XCTAssertTrue(NewsTaste(statements: []).localChoice(from: [WeiboTopic(title: "公交新路线开通", rank: 1)]) != nil)
    }

    func testThreeDayExactAndNearDuplicateSuppression() {
        let now = date("2026-11-09T16:00:00+08:00")
        let topic = WeiboTopic(title: "新一代人工智能模型正式发布", rank: 1)
        XCTAssertTrue(NewsTaste.wasShared(topic, recent: [NewsStamp(title: "#新一代人工智能模型正式发布#", date: now)], at: now))
        XCTAssertTrue(NewsTaste.wasShared(topic, recent: [NewsStamp(title: "新一代人工智能模型正式发布了", date: now)], at: now))
        XCTAssertFalse(NewsTaste.wasShared(topic, recent: [NewsStamp(title: topic.title, date: now.addingTimeInterval(-4 * 86400))], at: now))
    }

    func testModelCanOnlySelectExistingIndexOrSkip() {
        XCTAssertEqual(NewsPrompts.selectionIndex("{\"index\":1}", count: 3), 1)
        XCTAssertEqual(NewsPrompts.selectionIndex("```json\n{\"index\":0}\n```", count: 3), 0)
        for raw in ["{\"index\":4}", "{\"index\":-1}", "{\"index\":true}", "{\"index\":\"1\"}", "听我的", "{\"title\":\"虚构新闻\"}"] {
            XCTAssertNil(NewsPrompts.selectionIndex(raw, count: 3))
        }
    }

    func testDraftPromptLimitsClaimsToRealProvidedMaterial() {
        let topic = WeiboTopic(title: "某公司回应", rank: 1)
        let prompt = NewsPrompts.draftInput(topic: topic, excerpts: [], taste: NewsTaste(statements: ["主人关注科技"]))
        XCTAssertTrue(prompt.contains("没有摘录时只能说"))
        XCTAssertTrue(prompt.contains(topic.sourceURL.absoluteString))
        XCTAssertTrue(prompt.contains("主人关注科技"))
        XCTAssertTrue(NewsPrompts.fallbackLine(topic).contains(topic.title))
    }

    func testStatePersistsPendingAndCompletedSlotsWithoutCredentials() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        var state = NewsState()
        state.runs = [NewsRun(slotID: "test", attempts: 1, lastAttempt: now, completed: true)]
        state.pending = NewsBulletin(topic: WeiboTopic(title: "人工智能新进展", rank: 1), line: "一起看看喵", excerpts: [], detailNote: nil, slotID: "test", expiresAt: now.addingTimeInterval(60))
        try state.write(to: url)
        let restored = try NewsState.read(from: url)
        XCTAssertEqual(restored.pending, state.pending)
        XCTAssertEqual(restored.runs, state.runs)
        let text = try String(contentsOf: url)
        XCTAssertFalse(text.lowercased().contains("cookie"))
        XCTAssertFalse(text.contains("apiKey"))
    }

    func testCorruptOrFutureStateIsNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for raw in ["broken", "{\"version\":99}"] {
            try Data(raw.utf8).write(to: url)
            XCTAssertThrowsError(try NewsState.read(from: url))
            XCTAssertEqual(try String(contentsOf: url), raw)
        }
    }

    func testPruningExpiresPendingAndBoundsArchive() {
        let now = Date()
        var state = NewsState()
        state.pending = NewsBulletin(topic: WeiboTopic(title: "过时热点", rank: 1), line: "喵", excerpts: [], detailNote: nil, slotID: nil, expiresAt: now.addingTimeInterval(-1))
        state.recentTopics = [NewsStamp(title: "过时热点", date: now.addingTimeInterval(-4 * 86400))]
        state.prune(at: now)
        XCTAssertNil(state.pending)
        XCTAssertTrue(state.recentTopics.isEmpty)
    }

    func testHTTPHeadersAndFallbackEndpointWithMocks() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WeiboStub.self]
        let client = WeiboClient(session: URLSession(configuration: config))
        WeiboStub.prepare(first: "{\"ok\":1,\"data\":{\"band_list\":[]}}", second: sample)
        let topics = try await client.fetchTopics(cookie: "SUB=fake-test-only")
        XCTAssertEqual(topics.count, 2)
        let requests = WeiboStub.recorded()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Referer"), "https://weibo.com/")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Cookie"), "SUB=fake-test-only")
        XCTAssertEqual(requests.last?.url?.path, "/ajax/side/hotSearch")
    }
}

private final class WeiboStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var replies: [String] = []
    private static var requests: [URLRequest] = []
    static func prepare(first: String, second: String) {
        lock.lock(); defer { lock.unlock() }; replies = [first, second]; requests = []
    }
    static func recorded() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let body = Self.replies.isEmpty ? "{}" : Self.replies.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
