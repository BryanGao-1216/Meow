import XCTest
import KokosukiMailbox

final class MailboxTests: XCTestCase {
    private let sender = String(repeating: "a", count: 64)
    private let recipient = String(repeating: "b", count: 64)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func receiver() -> MailBook {
        var book = MailBook(); book.enabled = true; book.localDeviceID = recipient
        book.peer = MailPeer(deviceID: sender, ticket: "endpoint-test")
        return book
    }
    func testAuthenticatedIdentityMustMatchBindingAndEnvelope() throws {
        var book = receiver()
        let letter = MailLetter(senderID: sender, recipientID: recipient, body: "你好 💌", createdAt: now)
        XCTAssertThrowsError(try book.receive(letter, authenticatedID: recipient, now: now))
        XCTAssertTrue(book.entries.isEmpty)
        XCTAssertTrue(book.receipts.isEmpty)
        _ = try book.receive(letter, authenticatedID: sender, now: now)
        XCTAssertEqual(book.entries.count, 1)
    }
    func testRetransmissionAfterReadingOrDeletionDoesNotReopenLetter() throws {
        var book = receiver()
        let letter = MailLetter(senderID: sender, recipientID: recipient, body: "一封信", createdAt: now)
        let receipt = try book.receive(letter, authenticatedID: sender, now: now)
        book.entries[0].readAt = now
        XCTAssertEqual(try book.receive(letter, authenticatedID: sender, now: now), receipt)
        XCTAssertEqual(book.unreadCount, 0)
        book.entries.removeAll()
        XCTAssertEqual(try book.receive(letter, authenticatedID: sender, now: now), receipt)
        XCTAssertTrue(book.entries.isEmpty)
    }
    func testMessageIDCannotOverwriteAnotherLetter() throws {
        var book = receiver()
        var letter = MailLetter(senderID: sender, recipientID: recipient, body: "原文", createdAt: now)
        _ = try book.receive(letter, authenticatedID: sender, now: now)
        letter.body = "伪造的新正文"
        XCTAssertThrowsError(try book.receive(letter, authenticatedID: sender, now: now))
        XCTAssertEqual(book.entries[0].letter.body, "原文")
    }
    func testUnbindingKeepsHistoryAndStopsAutomaticRetry() throws {
        var book = receiver()
        _ = try book.queue(body: "尚未送达", now: now)
        book.unbind()
        XCTAssertEqual(book.entries.count, 1)
        XCTAssertEqual(book.entries[0].delivery, .cancelled)
        XCTAssertNil(book.nextQueued(at: now.addingTimeInterval(86400)))
    }
    func testOversizedAndFutureProtocolVersionsAreRejected() throws {
        XCTAssertThrowsError(try MailPacket.decode(Data(repeating: 0, count: 32769)))
        var packet = MailPacket(kind: .rejected, error: "测试")
        packet.version = 2
        XCTAssertThrowsError(try MailPacket.decode(packet.encoded()))
    }
}
