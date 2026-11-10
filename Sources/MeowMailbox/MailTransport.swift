import Foundation

/// 传输与信箱存储之间的边界；接收回调只有保存成功才返回回执。
public protocol MailTransport: Sendable {
    func start(secretKey: Data, receiver: @escaping @Sendable (MailLetter, String) async throws -> MailReceipt) async throws -> MailDeviceCode
    func localCode() async throws -> MailDeviceCode
    func validatePeerCode(_ code: String) async throws -> MailPeer
    func setPeer(_ peer: MailPeer?) async
    func send(_ letter: MailLetter) async throws -> MailReceipt
    func stop() async
}

public struct MailPacket: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case letter, receipt, rejected }
    public var version = 1
    public var kind: Kind
    public var letter: MailLetter?
    public var receipt: MailReceipt?
    public var error: String?
    public var senderTicket: String?
    public init(kind: Kind, letter: MailLetter? = nil, receipt: MailReceipt? = nil, error: String? = nil, senderTicket: String? = nil) {
        self.kind = kind; self.letter = letter; self.receipt = receipt; self.error = error; self.senderTicket = senderTicket
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        guard data.count <= 32768 else { throw MailError.invalid("信件过长，请缩短后再寄。") }
        return data
    }
    public static func decode(_ data: Data) throws -> MailPacket {
        guard data.count <= 32768 else { throw MailError.invalid("收到的信件超过大小限制。") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let packet = try decoder.decode(MailPacket.self, from: data)
        guard packet.version == 1 else { throw MailError.invalid("两台 Meow 的信箱协议版本不一致。") }
        return packet
    }
}
