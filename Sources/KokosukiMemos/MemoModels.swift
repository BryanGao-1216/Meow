import Foundation

public enum MemoStatus: String, Codable, CaseIterable { case pending, completed, cancelled }
public enum MemoNoticeKind: String, Codable { case due, early }

public struct MemoItem: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var dueAt: Date
    public var status: MemoStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var dueNotifiedAt: Date?
    public var lastEarlyAt: Date?
    public var earlyCount: Int
    public init(id: UUID = UUID(), title: String, dueAt: Date, now: Date = Date()) {
        self.id = id; self.title = title; self.dueAt = dueAt; status = .pending
        createdAt = now; updatedAt = now; earlyCount = 0
    }
}

public struct MemoNotice: Codable, Identifiable, Equatable {
    public var id: UUID
    public var kind: MemoNoticeKind
    public var itemIDs: [UUID]
    public var text: String
    public var createdAt: Date
    public var version: Int
    public init(kind: MemoNoticeKind, itemIDs: [UUID], text: String, createdAt: Date, version: Int) {
        id = UUID(); self.kind = kind; self.itemIDs = itemIDs; self.text = text
        self.createdAt = createdAt; self.version = version
    }
}

public enum MemoError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}

public struct MemoBook: Codable, Equatable {
    public var schema = 1
    public var version = 0
    public var items: [MemoItem] = []
    public var pending: MemoNotice?
    public var notices: [MemoNotice] = []
    public var lastReviewAt: Date?
    public var nextAttemptAt: Date?
    public var nextAttemptKind: MemoNoticeKind?
    public var earlyEnabled = true
    public init() {}
    public var active: [MemoItem] { items.filter { $0.status == .pending }.sorted { $0.dueAt < $1.dueAt } }

    public static func read(from url: URL) throws -> MemoBook {
        guard FileManager.default.fileExists(atPath: url.path) else { return MemoBook() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(MemoBook.self, from: Data(contentsOf: url))
        guard result.schema == 1, Set(result.items.map(\.id)).count == result.items.count,
              result.items.count <= 2000, result.items.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.title.count <= 200 }) else {
            throw MemoError.invalid("备忘录格式不受支持，请先保留原文件再修复。")
        }
        return result
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public mutating func saveItem(id: UUID? = nil, title: String, dueAt: Date, now: Date) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else { throw MemoError.invalid("任务需要填写，最多 200 字。") }
        guard dueAt > now, dueAt.timeIntervalSince(now) < 10 * 366 * 86400 else { throw MemoError.invalid("请选择未来十年内的明确时间。") }
        if let id {
            guard let i = items.firstIndex(where: { $0.id == id && $0.status == .pending }) else { throw MemoError.invalid("这条待办已经被修改或结束，请重新查看备忘录。") }
            items[i].title = title; items[i].dueAt = dueAt; items[i].updatedAt = now
            items[i].dueNotifiedAt = nil; items[i].lastEarlyAt = nil; items[i].earlyCount = 0
        } else {
            guard active.count < 100 else { throw MemoError.invalid("待办已满 100 条，请先完成或取消一些任务。") }
            if items.contains(where: { $0.status == .pending && $0.title == title && abs($0.dueAt.timeIntervalSince(dueAt)) < 1 }) { return }
            items.append(MemoItem(title: title, dueAt: dueAt, now: now))
        }
        invalidate()
    }

    public mutating func setStatus(_ status: MemoStatus, id: UUID, now: Date) throws {
        guard let i = items.firstIndex(where: { $0.id == id }) else { throw MemoError.invalid("没有找到这条备忘录。") }
        items[i].status = status; items[i].updatedAt = now
        if status == .pending { items[i].dueNotifiedAt = nil; items[i].lastEarlyAt = nil; items[i].earlyCount = 0 }
        invalidate()
    }

    public mutating func remove(id: UUID) { items.removeAll { $0.id == id }; invalidate() }
    private mutating func invalidate() {
        version += 1; pending = nil; nextAttemptAt = nil; nextAttemptKind = nil
        // 已完成记录保留最近 500 条，不影响任何未完成任务。
        let old = Set(items.filter { $0.status != .pending }.sorted { $0.updatedAt > $1.updatedAt }.dropFirst(500).map(\.id))
        items.removeAll { old.contains($0.id) }
    }
}

public enum MemoPolicy {
    public static let reviewInterval: TimeInterval = 1800
    public static func due(in book: MemoBook, now: Date) -> [MemoItem] {
        Array(book.active.filter { $0.dueAt <= now && $0.dueNotifiedAt == nil }.prefix(8))
    }
    public static func earlyCandidates(in book: MemoBook, now: Date) -> [MemoItem] {
        book.active.filter {
            $0.dueAt > now && $0.earlyCount < 3
                && ($0.lastEarlyAt.map { now.timeIntervalSince($0) >= 3600 } ?? true)
        }
    }
    public static func reviewDue(in book: MemoBook, now: Date) -> Bool {
        book.earlyEnabled && !book.active.isEmpty && (book.lastReviewAt.map { now.timeIntervalSince($0) >= reviewInterval } ?? true)
    }
    public static func valid(_ notice: MemoNotice, in book: MemoBook, now: Date) -> Bool {
        guard notice.version == book.version, !notice.itemIDs.isEmpty,
              notice.itemIDs.allSatisfy({ id in book.active.contains { $0.id == id } }) else { return false }
        if notice.kind == .due {
            return notice.itemIDs.allSatisfy { id in book.active.contains { $0.id == id && $0.dueAt <= now && $0.dueNotifiedAt == nil } }
        }
        return book.earlyEnabled && now.timeIntervalSince(notice.createdAt) < 600
            && notice.itemIDs.allSatisfy { id in earlyCandidates(in: book, now: now).contains { $0.id == id } }
    }
}
