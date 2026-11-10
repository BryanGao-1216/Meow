import Foundation

public enum MailError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
public enum MailDirection: String, Codable, Sendable { case incoming, outgoing }
public enum MailDelivery: String, Codable, Sendable { case queued, delivered, cancelled }

public struct MailLetter: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var senderID: String
    public var recipientID: String
    public var body: String
    public var createdAt: Date
    public init(id: UUID = UUID(), senderID: String, recipientID: String, body: String, createdAt: Date) {
        self.id = id; self.senderID = senderID; self.recipientID = recipientID; self.body = body; self.createdAt = createdAt
    }
    public func validate() throws {
        guard MailDeviceCode.validID(senderID), MailDeviceCode.validID(recipientID), senderID != recipientID,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.count <= 5000, body.utf8.count <= 16384 else {
            throw MailError.invalid("信件内容或设备身份无效；正文最多 5000 字，请缩短过长的文本。")
        }
    }
}
public struct MailReceipt: Codable, Equatable, Sendable {
    public var letterID: UUID
    public var senderID: String
    public var recipientID: String
    public var receivedAt: Date
    public init(letter: MailLetter, receivedAt: Date) {
        letterID = letter.id; senderID = letter.senderID; recipientID = letter.recipientID; self.receivedAt = receivedAt
    }
    public func matches(_ letter: MailLetter) -> Bool {
        letterID == letter.id && senderID == letter.senderID && recipientID == letter.recipientID
    }
}
public struct MailEntry: Codable, Identifiable, Equatable, Sendable {
    public var letter: MailLetter
    public var direction: MailDirection
    public var delivery: MailDelivery
    public var receivedAt: Date?
    public var readAt: Date?
    public var deliveredAt: Date?
    public var attempts = 0
    public var lastAttemptAt: Date?
    public var lastError: String?
    public var id: UUID { letter.id }
    public var unread: Bool { direction == .incoming && readAt == nil }
    public init(letter: MailLetter, direction: MailDirection, receivedAt: Date? = nil) {
        self.letter = letter; self.direction = direction; self.receivedAt = receivedAt
        delivery = direction == .incoming ? .delivered : .queued
    }
}
public struct MailPeer: Codable, Equatable, Sendable {
    public var deviceID: String
    public var ticket: String
    public var name: String
    public init(deviceID: String, ticket: String, name: String = "另一台 Mac 的 Meow") {
        self.deviceID = deviceID; self.ticket = ticket; self.name = name
    }
}
public struct MailDeviceCode: Codable, Equatable, Sendable {
    public var version = 1
    public var deviceID: String
    public var ticket: String
    public init(deviceID: String, ticket: String) { self.deviceID = deviceID; self.ticket = ticket }
    public static func validID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public func encoded() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return "meow1:" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func decode(_ value: String) throws -> MailDeviceCode {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("meow1:"), value.utf8.count <= 14000 else { throw MailError.invalid("请粘贴对方完整的 Meow 设备码（以 meow1: 开头）。") }
        var base = String(value.dropFirst(6)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard let data = Data(base64Encoded: base), let code = try? JSONDecoder().decode(MailDeviceCode.self, from: data),
              code.version == 1, validID(code.deviceID), code.ticket.hasPrefix("endpoint"), code.ticket.utf8.count <= 8192 else {
            throw MailError.invalid("设备码不完整或版本不兼容，请重新复制。")
        }
        return code
    }
}

/// 输入草稿与实际绑定分开保存；草稿不会自动改变可信对端。
public struct MailBindingDraft: Codable, Equatable, Sendable {
    public var localName: String
    public var peerName: String
    public var peerCode: String
    public init(localName: String = "这台 Mac 的 Meow", peerName: String = "另一台 Mac 的 Meow", peerCode: String = "") {
        self.localName = localName; self.peerName = peerName; self.peerCode = peerCode
    }
    public func validate() throws {
        guard localName.count <= 40, peerName.count <= 40, peerCode.utf8.count <= 14000,
              !localName.contains("\n"), !peerName.contains("\n") else {
            throw MailError.invalid("设备名称最多 40 字，设备码最多 14000 字节，请检查输入。")
        }
    }
}

public struct MailBook: Codable, Equatable {
    public var schema = 1
    public var enabled = false
    public var localDeviceID: String?
    public var localPairingCode: String?
    public var bindingDraft: MailBindingDraft?
    public var peer: MailPeer?
    public var entries: [MailEntry] = []
    /// 即使主人删除了信，丢失回执后的重试也不应使它再次出现在收信箱。
    public var receipts: [String: MailReceipt] = [:]
    public init() {}
    public var unreadCount: Int { entries.filter(\.unread).count }
    public var firstUnread: MailEntry? { entries.filter(\.unread).min { ($0.receivedAt ?? $0.letter.createdAt) < ($1.receivedAt ?? $1.letter.createdAt) } }
    public static func read(from url: URL) throws -> MailBook {
        guard FileManager.default.fileExists(atPath: url.path) else { return MailBook() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let book = try decoder.decode(MailBook.self, from: Data(contentsOf: url))
        guard book.schema == 1, book.entries.count <= 10000, book.receipts.count <= 50000,
              Set(book.entries.map(\.id)).count == book.entries.count,
              book.entries.allSatisfy({ (0...1_000_000).contains($0.attempts) }),
              book.localDeviceID.map(MailDeviceCode.validID) ?? true,
              book.peer.map({ MailDeviceCode.validID($0.deviceID) && $0.ticket.count <= 8192 }) ?? true else {
            throw MailError.invalid("信箱格式不受支持，已保留原文件。")
        }
        for entry in book.entries { try entry.letter.validate() }
        try book.bindingDraft?.validate()
        if let code = book.localPairingCode {
            guard try MailDeviceCode.decode(code).deviceID == book.localDeviceID else {
                throw MailError.invalid("保存的本机设备码与设备身份不一致，已保留原文件。")
            }
        }
        return book
    }
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public mutating func queue(body: String, now: Date) throws -> MailLetter {
        guard let local = localDeviceID, let peer else { throw MailError.invalid("请先启用信箱，并在两台 Mac 上互换设备码完成绑定。") }
        guard entries.count < 10000 else { throw MailError.invalid("信箱已满，请先删除一些不需要的信。") }
        let letter = MailLetter(senderID: local, recipientID: peer.deviceID, body: body.trimmingCharacters(in: .whitespacesAndNewlines), createdAt: now)
        try letter.validate()
        entries.append(MailEntry(letter: letter, direction: .outgoing))
        return letter
    }
    public mutating func receive(_ letter: MailLetter, authenticatedID: String, now: Date) throws -> MailReceipt {
        try letter.validate()
        guard enabled, let localDeviceID, let peer, authenticatedID == peer.deviceID,
              letter.senderID == authenticatedID, letter.recipientID == localDeviceID else {
            throw MailError.invalid("只接收已绑定设备寄给本机的信。")
        }
        if let receipt = receipts[letter.id.uuidString] {
            guard receipt.matches(letter), !entries.contains(where: { $0.id == letter.id && $0.letter != letter }) else {
                throw MailError.invalid("信件编号与原信不一致，未接收。")
            }
            return receipt
        }
        guard !entries.contains(where: { $0.id == letter.id }) else { throw MailError.invalid("信件编号已被使用，未接收。") }
        guard entries.count < 10000, receipts.count < 50000 else { throw MailError.invalid("对方信箱已满，暂时无法接收。") }
        let receipt = MailReceipt(letter: letter, receivedAt: now)
        entries.append(MailEntry(letter: letter, direction: .incoming, receivedAt: now))
        receipts[letter.id.uuidString] = receipt
        return receipt
    }
    public mutating func unbind() {
        peer = nil
        for i in entries.indices where entries[i].direction == .outgoing && entries[i].delivery == .queued { entries[i].delivery = .cancelled }
    }
    public func nextQueued(at now: Date) -> MailEntry? {
        entries.filter { entry in
            entry.direction == .outgoing && entry.delivery == .queued && entry.letter.recipientID == peer?.deviceID
                && (entry.lastAttemptAt.map { now.timeIntervalSince($0) >= min(120, pow(2, Double(min(6, entry.attempts)))) } ?? true)
        }.min { $0.letter.createdAt < $1.letter.createdAt }
    }
}
