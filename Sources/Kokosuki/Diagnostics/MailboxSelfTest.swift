import AppKit
import KokosukiMailbox
import KokosukiIroh

/// 假传输用于故障场景；真实收发测试另外使用两个 iroh 本机端点。
actor OfflineMailTransport: MailTransport {
    private let card: MailDeviceCode
    private(set) var sends = 0
    init(id: String = String(repeating: "a", count: 64)) { card = MailDeviceCode(deviceID: id, ticket: "endpoint-preview") }
    func start(secretKey: Data, receiver: @escaping @Sendable (MailLetter, String) async throws -> MailReceipt) -> MailDeviceCode { card }
    func localCode() -> MailDeviceCode { card }
    func validatePeerCode(_ code: String) throws -> MailPeer {
        let code = try MailDeviceCode.decode(code)
        return MailPeer(deviceID: code.deviceID, ticket: code.ticket)
    }
    func setPeer(_ peer: MailPeer?) {}
    func send(_ letter: MailLetter) throws -> MailReceipt { sends += 1; throw MailError.invalid("测试：对方离线") }
    func stop() {}
}

@MainActor
enum MailboxSelfTest {
    static func waitUntil(_ predicate: () -> Bool, rounds: Int = 400) async -> Bool {
        for _ in 0..<rounds {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
    static func run() async -> Int {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures += 1; print("mailbox FAIL: \(label)") } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meow-mail-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let aID = String(repeating: "a", count: 64), bID = String(repeating: "b", count: 64)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            var book = MailBook(); book.enabled = true; book.localDeviceID = bID
            book.peer = MailPeer(deviceID: aID, ticket: "endpoint-test")
            let letter = MailLetter(senderID: aID, recipientID: bID, body: "你好呀！\n今天也有好好吃饭喵 💌", createdAt: now)
            let receipt = try book.receive(letter, authenticatedID: aID, now: now)
            check(book.unreadCount == 1 && book.entries.count == 1 && receipt.matches(letter), "接收后保存原始中文、换行和 emoji，产生未读及回执")
            _ = try book.receive(letter, authenticatedID: aID, now: now.addingTimeInterval(10))
            check(book.entries.count == 1 && book.unreadCount == 1, "丢回执后的同编号重传不会重复来信")
            book.entries[0].readAt = now
            _ = try book.receive(letter, authenticatedID: aID, now: now)
            check(book.unreadCount == 0, "重传不会把已读信再次标成未读")
            book.entries.removeAll()
            _ = try book.receive(letter, authenticatedID: aID, now: now)
            check(book.entries.isEmpty, "删除信件后，重传也不会使其重新出现")
            do { _ = try book.receive(letter, authenticatedID: bID, now: now); check(false, "拒收未绑定设备") } catch { check(true, "拒收未绑定设备") }
            var spoofed = letter; spoofed.id = UUID(); spoofed.recipientID = aID
            do { _ = try book.receive(spoofed, authenticatedID: aID, now: now); check(false, "拒收伪造收件人") } catch { check(true, "拒收伪造收件人") }
            var huge = letter; huge.body = String(repeating: "喵", count: 6000)
            do { try huge.validate(); check(false, "拒绝超长正文") } catch { check(true, "拒绝超长正文") }
            var blank = letter; blank.body = " \n "
            do { try blank.validate(); check(false, "拒绝空白正文") } catch { check(true, "拒绝空白正文") }
            let packet = try MailPacket.decode(MailPacket(kind: .letter, letter: letter).encoded())
            check(packet.letter == letter, "信件协议编解码保留原文")
            do { _ = try MailPacket.decode(Data(repeating: 65, count: 32769)); check(false, "限制报文大小") } catch { check(true, "限制报文大小") }
            let card = MailDeviceCode(deviceID: aID, ticket: "endpoint-test")
            check(try MailDeviceCode.decode(card.encoded()) == card, "设备码可复制粘贴往返")
            do { _ = try MailDeviceCode.decode("https://example.com"); check(false, "拒绝错误设备码") } catch { check(true, "拒绝错误设备码") }
            let queued = try book.queue(body: "一封待寄的信", now: now)
            book.entries[0].attempts = 4; book.entries[0].lastAttemptAt = now
            check(book.nextQueued(at: now.addingTimeInterval(15)) == nil && book.nextQueued(at: now.addingTimeInterval(16))?.id == queued.id, "离线重试退避，不无限高频发送")
            let saved = root.appendingPathComponent("domain.json"); try book.write(to: saved)
            check(try MailBook.read(from: saved) == book, "信件、绑定、回执和重试状态可跨重启恢复")
            book.unbind()
            check(book.peer == nil && book.entries[0].delivery == .cancelled, "解绑保留历史并停止对旧设备重试")
        } catch { check(false, "信箱内核：\(error.localizedDescription)") }

        let offlineTransport = OfflineMailTransport()
        let offline = MailboxController(storageURL: root.appendingPathComponent("offline.json"), transport: offlineTransport,
            key: { Data(repeating: 1, count: 32) }, now: { now })
        do {
            try offline.setEnabled(true)
            check(await waitUntil { offline.isRunning }, "假传输启动不读取真实钥匙串")
            let other = try MailDeviceCode(deviceID: bID, ticket: "endpoint-preview").encoded()
            try await offline.bind(code: other, name: "离线测试小喵")
            offline.updateBindingDraft(localName: "书房的小喵", peerName: "尚未提交的备注", peerCode: "输入到一半的设备码")
            check(await waitUntil { (try? MailBook.read(from: offline.fileURL).bindingDraft?.localName) == "书房的小喵" }, "本机名称和输入草稿自动保存")
            let reopened = MailboxController(storageURL: offline.fileURL, transport: OfflineMailTransport(), key: { Data(repeating: 1, count: 32) })
            check(reopened.bindingDraft == offline.bindingDraft && reopened.deviceCode == offline.deviceCode,
                  "关闭绑定窗口或重启后恢复本机名、对方备注、输入码和自己的设备码")
            check(reopened.book.peer?.deviceID == bID && reopened.book.peer?.name == "离线测试小喵", "修改草稿不会更改实际可信对端")
            reopened.shutdown()
            offline.updateBindingDraft(peerName: "离线测试小喵", peerCode: other)
            try offline.flushBindingDraft()
            let id = try offline.compose("对方不在线也先保存这封信")
            _ = await waitUntil { !offline.isSending }
            check(offline.book.entries.first?.delivery == .queued && offline.book.entries.first?.lastError != nil, "离线发送不谎报送达，信留在待寄箱")
            let attempts = await offlineTransport.sends
            offline.checkSchedule(); _ = await waitUntil { !offline.isSending }
            check(await offlineTransport.sends == attempts, "同一退避时段不重复投递")
            let restored = try MailBook.read(from: offline.fileURL)
            check(restored.entries.first?.id == id && restored.entries.first?.delivery == .queued, "尚未送达的原文保存到磁盘")
            try offline.stopRetrying(id)
            check(offline.book.entries.first?.delivery == .cancelled, "可停止重试，不声称撤回对方信件")
            try offline.setEnabled(false)
            try offline.setEnabled(true)
            check(await waitUntil { offline.isRunning }, "关闭再启用恢复监听和调度")
            offline.updateBindingDraft(localName: "关窗后的小喵")
            offline.shutdown()
            check((try MailBook.read(from: offline.fileURL)).bindingDraft?.localName == "关窗后的小喵", "退出时立即保存尚在防抖等待中的输入")
            try FileManager.default.removeItem(at: offline.fileURL)
            try FileManager.default.createDirectory(at: offline.fileURL, withIntermediateDirectories: false)
            do { try offline.setEnabled(false); check(false, "存储故障时也能停止通信") }
            catch { check(!offline.isRunning && !offline.book.enabled, "存储故障时仍立即停止通信，不受保存失败阻挡") }
        } catch { check(false, "离线流程：\(error.localizedDescription)") }
        offline.shutdown(); await offlineTransport.stop()

        // 两个真实的 iroh-ffi QUIC 端点，仅监听 127.0.0.1，不调用公网中继或发现服务。
        let aTransport = IrohMailTransport(localOnly: true), bTransport = IrohMailTransport(localOnly: true)
        let a = MailboxController(storageURL: root.appendingPathComponent("a.json"), transport: aTransport, key: { Data(repeating: 7, count: 32) }, now: { now })
        let b = MailboxController(storageURL: root.appendingPathComponent("b.json"), transport: bTransport, key: { Data(repeating: 8, count: 32) }, now: { now })
        var shownUnread = 0, arrivals = 0
        b.onUnreadChange = { shownUnread = $0 }
        b.onNewLetter = { arrivals += 1 }
        do {
            try a.setEnabled(true); try b.setEnabled(true)
            guard await waitUntil({ a.isRunning && b.isRunning }) else { throw MailError.invalid("本机 QUIC 端点未能启动") }
            check(true, "两个真实 iroh-ffi 端点成功启动，未使用真实设备身份")
            do { try await a.bind(code: a.deviceCode, name: "自己"); check(false, "不绑定本机") } catch { check(true, "不绑定本机") }
            try await a.bind(code: b.deviceCode, name: "测试乙")
            try await b.bind(code: a.deviceCode, name: "测试甲")
            check(a.book.peer?.deviceID == b.book.localDeviceID && b.book.peer?.deviceID == a.book.localDeviceID, "设备码验证真实公钥并完成双向固定绑定")
            let fixedCode = try IrohMailTransport.pairingCode(deviceID: a.book.localDeviceID!).encoded()
            check(try IrohMailTransport.pairingCode(deviceID: a.book.localDeviceID!).encoded() == fixedCode, "公开配对码仅由固定身份生成，不包含临时端口")
            let fixedPeer = try await bTransport.validatePeerCode(fixedCode)
            check(fixedPeer.deviceID == a.book.localDeviceID, "固定配对码仍可被原版本票据格式解析和认证")
            let body = "给另一只小喵：\n这是一封真实通过 QUIC 传输的文本信 💌"
            let id = try a.compose(body)
            check(await waitUntil { a.book.entries.first(where: { $0.id == id })?.delivery == .delivered && b.book.unreadCount == 1 }, "真实 QUIC 信件收到保存回执才标记送达")
            check(b.book.entries.first?.letter.body == body && shownUnread == 1, "收信原文保存，并同步小猫的未读提示")
            check((try MailBook.read(from: b.fileURL)).entries.count == 1, "回执发出时来信已经落盘")
            check(arrivals == 1, "新信保存后只发出一次报信事件")
            b.selectFirstUnread()
            check(b.selected?.letter.body == body && b.book.unreadCount == 0 && shownUnread == 0 && b.book.entries.count == 1,
                  "点击展开后消除未读，原文继续保留")
            if let original = a.book.entries.first?.letter {
                let duplicate = try await aTransport.send(original)
                check(duplicate.matches(original) && b.book.entries.count == 1 && b.book.unreadCount == 0, "真实 QUIC 重传获得相同回执，信箱无重复信")
            }
            b.updateBindingDraft(localName: "收件测试小喵"); try b.flushBindingDraft()
            b.reloadStorage()
            check(arrivals == 1, "重复投递、读信、编辑名称和恢复历史都不重复报信")

            // 将测试文件替换成目录，模拟收件方写入失败；不能回假成功的 ACK。
            let snapshot = b.book
            try FileManager.default.removeItem(at: b.fileURL)
            try FileManager.default.createDirectory(at: b.fileURL, withIntermediateDirectories: false)
            let second = try a.compose("保存失败时不要声称已经送达")
            _ = await waitUntil { !a.isSending }
            check(a.book.entries.first(where: { $0.id == second })?.delivery == .queued && b.book.entries.count == 1,
                  "真实接收落盘失败时拒发成功回执，发送方保留待寄")
            check(arrivals == 1, "保存失败不报假来信")
            try FileManager.default.removeItem(at: b.fileURL); try snapshot.write(to: b.fileURL); b.reloadStorage()
            try a.retry(second)
            check(await waitUntil { a.book.entries.first(where: { $0.id == second })?.delivery == .delivered && b.book.entries.count == 2 },
                  "接收存储恢复后，原编号重试并成功送达一次")
            check(arrivals == 2, "保存恢复后同编号重试成功，才补报一次新信")

            let stranger = IrohMailTransport(localOnly: true)
            let strangerCode = try await stranger.start(secretKey: Data(repeating: 9, count: 32)) { letter, _ in MailReceipt(letter: letter, receivedAt: now) }
            let target = try await stranger.validatePeerCode(b.deviceCode); await stranger.setPeer(target)
            let unauthorized = MailLetter(senderID: strangerCode.deviceID, recipientID: target.deviceID, body: "这台设备没有被绑定", createdAt: now)
            do { _ = try await stranger.send(unauthorized); check(false, "拒收真实第三端点") } catch { check(b.book.entries.count == 2, "拒收真实第三端点，不能伪装成已绑定小喵") }
            await stranger.stop()
            try await a.unbind()
            check(a.book.peer == nil && a.book.entries.count == 2, "真实端点解绑保留信件历史")
        } catch { check(false, "真实 QUIC 收发：\(error.localizedDescription)") }
        a.shutdown(); b.shutdown(); await aTransport.stop(); await bTransport.stop()

        let legacyURL = root.appendingPathComponent("legacy.json")
        do {
            var legacy = MailBook(); legacy.localDeviceID = aID; legacy.peer = MailPeer(deviceID: bID, ticket: "endpoint-old", name: "旧备注")
            try legacy.write(to: legacyURL)
            let restored = MailboxController(storageURL: legacyURL, transport: OfflineMailTransport(), key: { Data(repeating: 1, count: 32) })
            check(try restored.bindingDraft.peerName == "旧备注" && MailDeviceCode.decode(restored.bindingDraft.peerCode).deviceID == bID,
                  "旧版信箱自动回显已有备注和设备码，不要求重新绑定")
            restored.shutdown()
        } catch { check(false, "兼容旧信箱：\(error.localizedDescription)") }

        let corrupt = root.appendingPathComponent("corrupt.json")
        try? Data("broken".utf8).write(to: corrupt)
        let protected = MailboxController(storageURL: corrupt, transport: OfflineMailTransport(), key: { fatalError("损坏文件不得读取钥匙串") })
        do { try protected.setEnabled(true); check(false, "保护损坏文件") } catch { check((try? String(contentsOf: corrupt)) == "broken", "损坏信箱不覆盖、不启动网络或身份读取") }
        protected.shutdown()

        let core = PetCore(), brain = Brain(loadPersistedHistory: false)
        let screen = WallScreen(id: "mail", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let attached = WallAttachment(side: .left, screenID: screen.id, heightFraction: 0.5)
        let engine = PetEngine(core: core, brain: brain, wallAttachment: attached, screens: { [screen] }, mouseLocation: { CGPoint(x: 700, y: 450) })
        engine.rescaled(); core.unreadLetters = 1
        let clock = Date()
        for step in 1...90 { engine.tick(at: clock.addingTimeInterval(Double(step) / 60)) }
        check(core.wallReveal > 0.99 && engine.wallAttachment == attached, "贴墙收到未读信时探身抱信，保持固定")
        core.unreadLetters = 0
        for step in 91...180 { engine.tick(at: clock.addingTimeInterval(Double(step) / 60)) }
        check(core.wallReveal < 0.001 && engine.wallAttachment == attached, "读完信且鼠标已离开后平滑缩回")
        print("mailbox: \(checks - failures)/\(checks) OK（临时数据、真实本机 iroh QUIC、无公网与 LLM 请求）")
        return failures + MailPresentationSelfTest.run()
    }
}
