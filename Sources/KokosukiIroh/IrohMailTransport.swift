import Foundation
import IrohLib
import KokosukiMailbox

/// iroh-ffi 的 Swift 适配。QUIC 远端公钥就是认证身份；信件正文不参与身份判断。
public actor IrohMailTransport: MailTransport {
    private static let alpn = Data("meow/mail/1".utf8)
    private let localOnly: Bool
    private var endpoint: Endpoint?
    private var peer: MailPeer?
    private var generation = 0
    private var acceptTask: Task<Void, Never>?
    private var handlers: [UUID: Task<Void, Never>] = [:]
    private var connections: [UUID: Connection] = [:]
    private var outgoing: Connection?
    private var receiver: (@Sendable (MailLetter, String) async throws -> MailReceipt)?

    /// localOnly 供真实本机端到端测试使用，不接触公开中继或设备发现服务。
    public init(localOnly: Bool = false) { self.localOnly = localOnly }

    public func start(secretKey: Data, receiver: @escaping @Sendable (MailLetter, String) async throws -> MailReceipt) async throws -> MailDeviceCode {
        await stop()
        guard secretKey.count == 32 else { throw MailError.invalid("本机通信身份无效，请检查钥匙串。") }
        let revision = generation
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: localOnly ? presetMinimal() : presetN0(), bindAddr: localOnly ? "127.0.0.1:0" : nil,
            secretKey: secretKey, alpns: [Self.alpn]))
        guard revision == generation else { try? await endpoint.close(); throw CancellationError() }
        self.endpoint = endpoint; self.receiver = receiver
        acceptTask = Task { [weak self] in
            while let incoming = await endpoint.acceptNext() {
                guard !Task.isCancelled, let self else { try? await incoming.refuse(); break }
                await self.accept(incoming, revision: revision)
            }
        }
        return try localCode()
    }

    public func localCode() throws -> MailDeviceCode {
        guard let endpoint else { throw MailError.invalid("请先启用信箱。") }
        return MailDeviceCode(deviceID: endpoint.id().description, ticket: try EndpointTicket.fromAddr(addr: endpoint.addr()).description)
    }
    public func validatePeerCode(_ code: String) throws -> MailPeer {
        let card = try MailDeviceCode.decode(code)
        let address = try EndpointTicket.fromString(str: card.ticket).endpointAddr()
        guard address.id().description == card.deviceID, card.deviceID != endpoint?.id().description else {
            throw MailError.invalid("设备码身份不匹配，或粘贴的是这台 Mac 自己的设备码。")
        }
        return MailPeer(deviceID: card.deviceID, ticket: card.ticket)
    }
    public func setPeer(_ peer: MailPeer?) {
        if self.peer?.deviceID != peer?.deviceID {
            try? outgoing?.close(errorCode: 1, reason: Data("binding_changed".utf8)); outgoing = nil
            for conn in connections.values { try? conn.close(errorCode: 1, reason: Data("binding_changed".utf8)) }
        }
        self.peer = peer
    }

    public func send(_ letter: MailLetter) async throws -> MailReceipt {
        try letter.validate()
        guard let endpoint, let peer, peer.deviceID == letter.recipientID, endpoint.id().description == letter.senderID else {
            throw MailError.invalid("发送对象与当前绑定不一致，未寄出。")
        }
        let revision = generation
        let address = try EndpointTicket.fromString(str: peer.ticket).endpointAddr()
        guard address.id().description == peer.deviceID else { throw MailError.invalid("对方设备码身份不一致。") }
        let connection = try await endpoint.connect(addr: address, alpn: Self.alpn)
        guard revision == generation, self.peer?.deviceID == peer.deviceID, !Task.isCancelled else {
            try? connection.close(errorCode: 1, reason: Data("cancelled".utf8)); throw CancellationError()
        }
        guard connection.remoteId().description == peer.deviceID else {
            try? connection.close(errorCode: 1, reason: Data("untrusted_peer".utf8)); throw MailError.invalid("连接的设备不是已绑定的小喵。")
        }
        outgoing = connection
        let timeout = Task {
            try? await Task.sleep(for: .seconds(25))
            if !Task.isCancelled { try? connection.close(errorCode: 2, reason: Data("mail_timeout".utf8)) }
        }
        defer { timeout.cancel(); try? connection.close(errorCode: 0, reason: Data()); if outgoing === connection { outgoing = nil } }
        return try await withTaskCancellationHandler {
            let stream = try await connection.openBi()
            let request = MailPacket(kind: .letter, letter: letter, senderTicket: try localCode().ticket)
            try await stream.send().writeAll(buf: request.encoded())
            try await stream.send().finish()
            let response = try MailPacket.decode(await stream.recv().readToEnd(sizeLimit: 32768))
            guard revision == generation, self.peer?.deviceID == peer.deviceID, !Task.isCancelled else { throw CancellationError() }
            guard response.kind == .receipt, let receipt = response.receipt, receipt.matches(letter) else {
                throw MailError.invalid(response.kind == .rejected ? "对方暂时无法保存来信，请稍后重试。" : "没有收到有效的保存回执，信件会留在待寄箱。")
            }
            updatePeerTicket(response.senderTicket, authenticatedID: peer.deviceID)
            return receipt
        } onCancel: { try? connection.close(errorCode: 1, reason: Data("cancelled".utf8)) }
    }

    private func accept(_ incoming: Incoming, revision: Int) async {
        guard revision == generation, peer != nil, handlers.count < 4 else { try? await incoming.refuse(); return }
        let id = UUID()
        handlers[id] = Task { [weak self] in await self?.handle(incoming, id: id, revision: revision) }
    }
    private func handle(_ incoming: Incoming, id: UUID, revision: Int) async {
        defer { handlers.removeValue(forKey: id); connections.removeValue(forKey: id) }
        do {
            let connection = try await incoming.accept().connect()
            guard revision == generation, connection.alpn() == Self.alpn,
                  let peer, connection.remoteId().description == peer.deviceID else {
                try? connection.close(errorCode: 1, reason: Data("untrusted_peer".utf8)); return
            }
            connections[id] = connection
            let timeout = Task {
                try? await Task.sleep(for: .seconds(25))
                if !Task.isCancelled { try? connection.close(errorCode: 2, reason: Data("mail_timeout".utf8)) }
            }
            defer { timeout.cancel(); try? connection.close(errorCode: 0, reason: Data()) }
            let stream = try await connection.acceptBi()
            do {
                let request = try MailPacket.decode(await stream.recv().readToEnd(sizeLimit: 32768))
                guard revision == generation, self.peer?.deviceID == peer.deviceID, request.kind == .letter,
                      let letter = request.letter, letter.senderID == peer.deviceID, letter.recipientID == endpoint?.id().description,
                      let receiver else { throw MailError.invalid("无效或未授权的来信。") }
                let receipt = try await receiver(letter, peer.deviceID)
                guard receipt.matches(letter), revision == generation else { throw CancellationError() }
                updatePeerTicket(request.senderTicket, authenticatedID: peer.deviceID)
                let reply = MailPacket(kind: .receipt, receipt: receipt, senderTicket: try localCode().ticket)
                try await stream.send().writeAll(buf: reply.encoded())
                try await stream.send().finish()
            } catch {
                let rejected = MailPacket(kind: .rejected, error: "信件未保存，请稍后重试。")
                if let data = try? rejected.encoded() { try? await stream.send().writeAll(buf: data); try? await stream.send().finish() }
            }
            // 等发送方读到回执再关闭，避免 finish 后立刻 close 导致回执丢失。
            _ = await connection.closed()
        } catch { /* 单次坏连接不影响持续监听或其他已保存的信。 */ }
    }
    private func updatePeerTicket(_ ticket: String?, authenticatedID: String) {
        guard let ticket, ticket.utf8.count <= 8192, peer?.deviceID == authenticatedID,
              let address = try? EndpointTicket.fromString(str: ticket).endpointAddr(), address.id().description == authenticatedID else { return }
        peer?.ticket = ticket
    }
    public func stop() async {
        generation += 1
        acceptTask?.cancel(); acceptTask = nil
        for task in handlers.values { task.cancel() }; handlers.removeAll()
        for connection in connections.values { try? connection.close(errorCode: 1, reason: Data("shutdown".utf8)) }; connections.removeAll()
        try? outgoing?.close(errorCode: 1, reason: Data("shutdown".utf8)); outgoing = nil
        let old = endpoint; endpoint = nil; receiver = nil
        try? await old?.close()
    }
}
