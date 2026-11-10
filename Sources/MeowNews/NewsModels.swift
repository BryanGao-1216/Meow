import Foundation

public struct WeiboTopic: Codable, Identifiable, Equatable, Sendable {
    public var title: String
    public var category: String
    public var rank: Int
    public var heat: Int
    public var fetchedAt: Date
    public var id: String { Self.identity(title) }
    public var sourceURL: URL {
        var url = URLComponents(string: "https://s.weibo.com/weibo")!
        url.queryItems = [URLQueryItem(name: "q", value: "#\(title)#")]
        return url.url!
    }

    public init(title: String, category: String = "", rank: Int, heat: Int = 0, fetchedAt: Date = .now) {
        self.title = title; self.category = category; self.rank = rank
        self.heat = heat; self.fetchedAt = fetchedAt
    }

    public static func identity(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

public struct NewsExcerpt: Codable, Equatable, Sendable {
    public var text: String
    public var sourceURL: URL
    public init(text: String, sourceURL: URL) { self.text = text; self.sourceURL = sourceURL }
}

public struct NewsBulletin: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var topic: WeiboTopic
    public var line: String
    public var excerpts: [NewsExcerpt]
    public var detailNote: String?
    public var slotID: String?
    public var expiresAt: Date
    public var deliveredAt: Date?

    public init(topic: WeiboTopic, line: String, excerpts: [NewsExcerpt], detailNote: String?, slotID: String?, expiresAt: Date) {
        self.topic = topic; self.line = line; self.excerpts = excerpts
        self.detailNote = detailNote; self.slotID = slotID; self.expiresAt = expiresAt
    }
}

public struct NewsRun: Codable, Equatable, Sendable {
    public var slotID: String
    public var attempts: Int
    public var lastAttempt: Date
    public var completed: Bool

    public init(slotID: String, attempts: Int, lastAttempt: Date, completed: Bool = false) {
        self.slotID = slotID; self.attempts = attempts; self.lastAttempt = lastAttempt; self.completed = completed
    }
}

public struct NewsStamp: Codable, Equatable, Sendable {
    public var title: String
    public var date: Date
    public init(title: String, date: Date) { self.title = title; self.date = date }
}

public struct NewsState: Codable, Sendable {
    public var version = 1
    public var runs: [NewsRun] = []
    public var bulletins: [NewsBulletin] = []
    public var recentTopics: [NewsStamp] = []
    public var pending: NewsBulletin?
    public init() {}

    public static func read(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let data = try Data(contentsOf: url)
        guard let state = try? JSONDecoder().decode(Self.self, from: data), state.version == 1,
              state.runs.count <= 100, state.bulletins.count <= 60, state.recentTopics.count <= 300 else {
            throw NewsError.storage
        }
        return state
    }

    public mutating func prune(at now: Date) {
        runs.removeAll { now.timeIntervalSince($0.lastAttempt) > 7 * 86400 }
        recentTopics.removeAll { now.timeIntervalSince($0.date) > 3 * 86400 }
        bulletins.removeAll { now.timeIntervalSince($0.topic.fetchedAt) > 30 * 86400 }
        runs = Array(runs.suffix(100)); recentTopics = Array(recentTopics.suffix(300))
        bulletins = Array(bulletins.suffix(60))
        if let pending, pending.expiresAt <= now { self.pending = nil }
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum NewsError: LocalizedError {
    case http(Int), loginRequired, invalidResponse, emptyList, storage, responseTooLarge
    case invalidCookie(String), noExcerpts, requestRejected, unexpectedRedirect
    public var errorDescription: String? {
        switch self {
        case .http(let code): return "微博接口返回 HTTP \(code)，稍后再试。"
        case .loginRequired: return "微博返回了登录或验证页面。请在网页版完成登录或验证，再复制最新 Cookie。"
        case .invalidCookie(let message): return message
        case .noExcerpts: return "微博搜索没有返回可读取的正文；这不代表 Cookie 已失效，可换个话题稍后再试。"
        case .requestRejected: return "微博暂未接受本次请求，可能是接口限制；暂时无法判断登录是否有效。"
        case .unexpectedRedirect: return "微博接口发生了非预期跳转，已停止请求；这不代表 Cookie 已失效。"
        case .invalidResponse: return "微博返回了无法识别的数据。"
        case .emptyList: return "微博本次没有返回可用热榜。"
        case .storage: return "热点记录无法读取或版本不兼容，原文件未被覆盖。"
        case .responseTooLarge: return "微博返回的数据过大，已停止读取。"
        }
    }
}
