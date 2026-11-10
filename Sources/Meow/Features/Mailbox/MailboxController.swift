import Foundation
import Combine
import MeowMailbox

@MainActor
final class MailboxController: ObservableObject {
    @Published private(set) var book = MailBook()
    @Published private(set) var status = "启用喵喵信箱后，在两台 Mac 上互换设备码即可绑定。"
    @Published private(set) var storageError: String?
    @Published private(set) var deviceCode = ""
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var isSending = false
    @Published private(set) var selectedLetterID: UUID?
    @Published private(set) var bindingDraft = MailBindingDraft()
    @Published private(set) var bindingError: String?
    var onUnreadChange: ((Int) -> Void)?
    /// 仅在新信成功保存后触发；恢复历史、标记已读和重复投递都不算新信。
    var onNewLetter: (() -> Void)?
    private let transport: any MailTransport
    private let url: URL
    private let key: () throws -> Data
    private let now: () -> Date
    private var unreadable = false
    private var timer: Timer?
    private var startup: Task<Void, Never>?
    private var sending: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var sendToken: UUID?
    private var generation = 0
    private var nextStart = Date.distantPast
    private var draftSave: Task<Void, Never>?
    private var draftDirty = false

    init(storageURL: URL? = nil, transport: any MailTransport, key: @escaping () throws -> Data = MailIdentityStore.loadOrCreate,
         now: @escaping () -> Date = Date.init) {
        url = storageURL ?? Persistence.supportDir.appendingPathComponent("meow-mailbox.json")
        self.transport = transport; self.key = key; self.now = now
        reloadStorage()
    }
    var selected: MailEntry? { book.entries.first { $0.id == selectedLetterID } }
    var fileURL: URL { url }
    var localDeviceName: String {
        let value = bindingDraft.localName.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "这台 Mac 的 Meow" : value
    }
    func start() {
        onUnreadChange?(book.unreadCount)
        timer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSchedule() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        checkSchedule()
    }
    func configurationChanged() { /* 云端模型的配置不影响点对点信箱。 */ }
    func shutdown() {
        persistBindingDraft()
        generation += 1; timer?.invalidate(); timer = nil
        startup?.cancel(); startup = nil; sending?.cancel(); sending = nil; sendToken = nil
        isStarting = false; isSending = false; isRunning = false
        let previous = closing, transport = self.transport
        closing = Task { if let previous { await previous.value }; await transport.stop() }
    }
    func reloadStorage() {
        draftSave?.cancel(); draftSave = nil
        do {
            book = try MailBook.read(from: url); unreadable = false; storageError = nil
            if let name = book.peer?.name { book.peer?.name = LegacyMigration.deviceLabel(name) }
            bindingDraft = book.bindingDraft ?? MailBindingDraft(peerName: book.peer?.name ?? "另一台 Mac 的 Meow",
                peerCode: book.peer.flatMap { try? MailDeviceCode(deviceID: $0.deviceID, ticket: $0.ticket).encoded() } ?? "")
            bindingDraft.localName = LegacyMigration.deviceLabel(bindingDraft.localName)
            bindingDraft.peerName = LegacyMigration.deviceLabel(bindingDraft.peerName)
            book.bindingDraft = bindingDraft
            draftDirty = false; bindingError = nil; deviceCode = book.localPairingCode ?? ""
            onUnreadChange?(book.unreadCount)
        }
        catch { unreadable = true; storageError = "信箱未能读取：\(error.localizedDescription)" }
    }
    func updateBindingDraft(localName: String? = nil, peerName: String? = nil, peerCode: String? = nil) {
        var draft = bindingDraft
        if let localName { draft.localName = localName }
        if let peerName { draft.peerName = peerName }
        if let peerCode { draft.peerCode = peerCode }
        guard draft != bindingDraft else { return }
        bindingDraft = draft; draftDirty = true; bindingError = nil
        draftSave?.cancel()
        draftSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.persistBindingDraft()
        }
    }
    func flushBindingDraft() throws {
        draftSave?.cancel(); draftSave = nil
        guard draftDirty else { return }
        do {
            try bindingDraft.validate()
            var changed = book; changed.bindingDraft = bindingDraft
            try commit(changed); draftDirty = false; bindingError = nil
        } catch { bindingError = "绑定资料未保存：\(error.localizedDescription)"; throw error }
    }
    func persistBindingDraft() { do { try flushBindingDraft() } catch { /* 窗口和主信箱展示保存错误，保留草稿供重试。 */ } }
    private func commit(_ changed: MailBook) throws {
        guard !unreadable else { throw MailError.invalid("原信箱无法读取，未覆盖文件，请先重试读取。") }
        do { try changed.write(to: url); book = changed; storageError = nil; onUnreadChange?(book.unreadCount) }
        catch { storageError = "信箱未能保存：\(error.localizedDescription)"; throw error }
    }
    func setEnabled(_ enabled: Bool) throws {
        if !enabled { shutdown() }
        var changed = book; changed.enabled = enabled
        do { try commit(changed) }
        catch {
            if !enabled { book.enabled = false; status = "通信已停止，但开关状态未能保存，请先修复信箱存储。" }
            throw error
        }
        if enabled { nextStart = .distantPast; start() }
        else { status = "通信已关闭，本机信件仍保留；重新启用后继续收发。" }
    }
    func reconnect() { nextStart = .distantPast; checkSchedule() }
    func checkSchedule() {
        guard book.enabled, !unreadable, storageError == nil else { return }
        if !isRunning {
            if startup == nil, now() >= nextStart { startTransport() }
            return
        }
        if sending == nil { sendNext() }
    }
    private func startTransport() {
        let revision = generation
        isStarting = true; status = "正在启动喵喵信箱…"
        startup = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == revision { self.startup = nil; self.isStarting = false } }
            do {
                if let closing = self.closing { await closing.value }
                guard !Task.isCancelled, self.generation == revision else { return }
                self.closing = nil
                let card = try await self.transport.start(secretKey: self.key()) { [weak self] letter, authenticatedID in
                    guard let self else { throw MailError.invalid("接收方信箱已关闭。") }
                    return try await self.receive(letter, authenticatedID: authenticatedID)
                }
                guard !Task.isCancelled, self.generation == revision, self.book.enabled else { return }
                guard self.book.localDeviceID == nil || self.book.localDeviceID == card.deviceID || self.book.peer == nil else {
                    throw MailError.invalid("本机设备身份已改变。请先解除旧绑定，再重新启用并互换设备码。")
                }
                let code = try card.encoded()
                var changed = self.book; changed.localDeviceID = card.deviceID; changed.localPairingCode = code
                try self.commit(changed)
                await self.transport.setPeer(self.book.peer)
                guard !Task.isCancelled, self.generation == revision else { return }
                self.deviceCode = code; self.isRunning = true
                self.status = self.book.peer == nil ? "信箱已启用，请在两台 Mac 上互换设备码。" : "信箱已开启，等待来信；待寄信件会自动投递。"
                self.sendNext()
            } catch {
                guard self.generation == revision, !Task.isCancelled else { return }
                self.status = "信箱未能启动：\(error.localizedDescription)"
                self.nextStart = self.now().addingTimeInterval(30)
                await self.transport.stop()
            }
        }
    }
    func bind(code: String, name: String) async throws {
        guard isRunning, book.enabled else { throw MailError.invalid("请先启用信箱，等本机设备码出现后再绑定。") }
        let revision = generation
        var peer = try await transport.validatePeerCode(code)
        guard revision == generation, book.enabled else { throw CancellationError() }
        guard book.peer == nil || book.peer?.deviceID == peer.deviceID else { throw MailError.invalid("当前只绑定一台设备，请先解除现有绑定。") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        peer.name = name.isEmpty ? "另一台 Mac 的 Meow" : String(name.prefix(40))
        var draft = bindingDraft; draft.peerCode = code.trimmingCharacters(in: .whitespacesAndNewlines); draft.peerName = peer.name
        try draft.validate()
        var changed = book; changed.peer = peer; changed.bindingDraft = draft; try commit(changed)
        draftSave?.cancel(); draftSave = nil; bindingDraft = draft; draftDirty = false; bindingError = nil
        await transport.setPeer(peer)
        status = "已绑定\(peer.name)。请在对方信箱也粘贴本机设备码，双方完成后才能收信。"
        sendNext()
    }
    func unbind() async throws {
        var draft = bindingDraft; draft.peerCode = ""; draft.peerName = "另一台 Mac 的 Meow"
        try draft.validate()
        var changed = book; changed.unbind(); changed.bindingDraft = draft; try commit(changed)
        draftSave?.cancel(); draftSave = nil; bindingDraft = draft; draftDirty = false; bindingError = nil
        sending?.cancel(); sending = nil; sendToken = nil; isSending = false
        await transport.setPeer(nil)
        status = "已解除绑定，保留历史信件并停止向旧设备重试。"
    }
    @discardableResult func compose(_ body: String) throws -> UUID {
        var changed = book; let letter = try changed.queue(body: body, now: now()); try commit(changed)
        status = "信已放进待寄箱；收到对方保存回执后才会显示已送达。"
        sendNext(); return letter.id
    }
    private func sendNext() {
        guard isRunning, book.enabled, storageError == nil, sending == nil, let entry = book.nextQueued(at: now()),
              let index = book.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        var changed = book; changed.entries[index].attempts = min(1_000_000, changed.entries[index].attempts + 1); changed.entries[index].lastAttemptAt = now()
        do { try commit(changed) } catch { return }
        let token = UUID(); sendToken = token; isSending = true
        sending = Task { [weak self] in
            guard let self else { return }
            defer { if self.sendToken == token { self.sending = nil; self.sendToken = nil; self.isSending = false } }
            do {
                let receipt = try await self.transport.send(entry.letter)
                guard !Task.isCancelled, self.sendToken == token, self.book.peer?.deviceID == entry.letter.recipientID,
                      let i = self.book.entries.firstIndex(where: { $0.id == entry.id && $0.delivery == .queued }), receipt.matches(entry.letter) else { return }
                var delivered = self.book; delivered.entries[i].delivery = .delivered
                delivered.entries[i].deliveredAt = receipt.receivedAt; delivered.entries[i].lastError = nil
                try self.commit(delivered); self.status = "信已送达，对方已保存进喵喵信箱 💌"
            } catch {
                guard !Task.isCancelled, self.sendToken == token,
                      let i = self.book.entries.firstIndex(where: { $0.id == entry.id && $0.delivery == .queued }) else { return }
                var failed = self.book; failed.entries[i].lastError = String(error.localizedDescription.prefix(300))
                try? self.commit(failed)
                self.status = "暂未送达，信仍保留在待寄箱；请确认对方已运行 Meow、启用信箱并完成双向绑定。"
            }
        }
    }
    private func receive(_ letter: MailLetter, authenticatedID: String) throws -> MailReceipt {
        guard storageError == nil else { throw MailError.invalid("接收方暂时无法保存信件。") }
        let previous = book.unreadCount
        var changed = book
        let receipt = try changed.receive(letter, authenticatedID: authenticatedID, now: now())
        try commit(changed)
        if book.unreadCount > previous {
            status = "收到一封信，点击 Meow 举着的 💌 查看。"
            onNewLetter?()
        }
        return receipt
    }
    func select(_ id: UUID) {
        selectedLetterID = id
        guard let index = book.entries.firstIndex(where: { $0.id == id && $0.unread }) else { return }
        var changed = book; changed.entries[index].readAt = now()
        do { try commit(changed) } catch { status = "信已展开，但已读状态未能保存。" }
    }
    func selectFirstUnread() {
        if let entry = book.firstUnread ?? book.entries.filter({ $0.direction == .incoming }).last { select(entry.id) }
    }
    func retry(_ id: UUID) throws {
        guard let i = book.entries.firstIndex(where: { $0.id == id && $0.direction == .outgoing && $0.delivery == .queued }) else { return }
        var changed = book; changed.entries[i].lastAttemptAt = nil; changed.entries[i].lastError = nil
        try commit(changed); sendNext()
    }
    func stopRetrying(_ id: UUID) throws {
        guard let i = book.entries.firstIndex(where: { $0.id == id && $0.direction == .outgoing && $0.delivery == .queued }) else { return }
        var changed = book; changed.entries[i].delivery = .cancelled; try commit(changed)
        status = "已停止重试；已经传出的信件无法撤回。"
    }
    func remove(_ id: UUID) throws {
        var changed = book; changed.entries.removeAll { $0.id == id }; try commit(changed)
        if selectedLetterID == id { selectedLetterID = nil }
    }
}
