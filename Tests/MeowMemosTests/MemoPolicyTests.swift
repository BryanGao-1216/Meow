import XCTest
import MeowMemos

final class MemoPolicyTests: XCTestCase {
    private let now = MemoPrompts.parseDate("2026-11-09T16:00:00+08:00")!

    func testEarlyCooldownAndCapDoNotSuppressDueAlarm() throws {
        var book = MemoBook()
        try book.saveItem(title: "聚会", dueAt: now.addingTimeInterval(10800), now: now)
        book.items[0].lastEarlyAt = now
        XCTAssertTrue(MemoPolicy.earlyCandidates(in: book, now: now.addingTimeInterval(3599)).isEmpty)
        XCTAssertEqual(MemoPolicy.earlyCandidates(in: book, now: now.addingTimeInterval(3600)).count, 1)
        book.items[0].earlyCount = 3
        XCTAssertTrue(MemoPolicy.earlyCandidates(in: book, now: now.addingTimeInterval(3600)).isEmpty)
        XCTAssertEqual(MemoPolicy.due(in: book, now: now.addingTimeInterval(10800)).count, 1)
    }
    func testEarlyDraftExpiresAndCannotBecomePastDueReminder() throws {
        var book = MemoBook()
        try book.saveItem(title: "聚会", dueAt: now.addingTimeInterval(900), now: now)
        let draft = MemoNotice(kind: .early, itemIDs: [book.items[0].id], text: "主人，记得准备聚会喵。", createdAt: now, version: book.version)
        XCTAssertTrue(MemoPolicy.valid(draft, in: book, now: now.addingTimeInterval(599)))
        XCTAssertFalse(MemoPolicy.valid(draft, in: book, now: now.addingTimeInterval(600)))
        XCTAssertFalse(MemoPolicy.valid(draft, in: book, now: now.addingTimeInterval(901)))
    }
    func testEditingTaskInvalidatesOldDraft() throws {
        var book = MemoBook()
        try book.saveItem(title: "聚会", dueAt: now.addingTimeInterval(900), now: now)
        let id = book.items[0].id
        let draft = MemoNotice(kind: .early, itemIDs: [id], text: "主人，记得准备聚会喵。", createdAt: now, version: book.version)
        try book.saveItem(id: id, title: "改天聚会", dueAt: now.addingTimeInterval(86400), now: now)
        XCTAssertFalse(MemoPolicy.valid(draft, in: book, now: now))
    }
    func testTimezoneAndFractionalSecondsParseWithoutGuessing() {
        XCTAssertEqual(MemoPrompts.parseDate("2026-11-09T16:00:00+08:00"), MemoPrompts.parseDate("2026-11-09T08:00:00Z"))
        XCTAssertEqual(MemoPrompts.parseDate("2026-11-09T08:00:00.000Z"), now)
        XCTAssertNil(MemoPrompts.parseDate("2026-11-09T16:00:00"))
    }
    func testHalfHourStateSurvivesStorageRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("memos.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var book = MemoBook()
        try book.saveItem(title: "聚会", dueAt: now.addingTimeInterval(10800), now: now)
        book.lastReviewAt = now
        try book.write(to: url)
        let restored = try MemoBook.read(from: url)
        XCTAssertFalse(MemoPolicy.reviewDue(in: restored, now: now.addingTimeInterval(1799)))
        XCTAssertTrue(MemoPolicy.reviewDue(in: restored, now: now.addingTimeInterval(1800)))
        XCTAssertEqual(restored.items, book.items)
    }
}
