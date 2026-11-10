import AppKit
import SwiftUI
import MeowMemory

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var fromPet: Bool
    var text: String
    var streaming = false
    var sourceURL: URL? = nil
}

@MainActor
final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input = ""
    @Published var busy = false

    func reset() { messages.removeAll(); input = ""; busy = false }

    func loadHistory(_ history: [Brain.Message]) {
        messages = history.suffix(30).map {
            ChatMessage(fromPet: $0.role == "assistant", text: $0.text, sourceURL: $0.sourceURL)
        }
    }

    func beginStream() {
        messages.append(ChatMessage(fromPet: true, text: "…", streaming: true))
        busy = true
    }

    func appendNews(_ text: String, sourceURL: URL) {
        messages.append(ChatMessage(fromPet: true, text: text, sourceURL: sourceURL))
    }

    func appendProactive(_ text: String) { messages.append(ChatMessage(fromPet: true, text: text)) }

    func updateStream(_ text: String, done: Bool) {
        guard let idx = messages.lastIndex(where: { $0.streaming }) else {
            if !done, !text.isEmpty {
                messages.append(ChatMessage(fromPet: true, text: text, streaming: true))
                busy = true
            }
            return
        }
        if done {
            if text.isEmpty {
                messages.remove(at: idx)
            } else {
                messages[idx].text = text
                messages[idx].streaming = false
            }
            busy = false
        } else if !text.isEmpty {
            messages[idx].text = text
        }
    }
}

struct ChatView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var core: PetCore
    @ObservedObject var settings: AppSettings
    var onSend: (String) -> Void
    var onQuickAction: (QuickAction) -> Void
    @FocusState private var inputFocused: Bool

    enum QuickAction { case feedFish, feedCookie, play, sleep, settings, clearHistory }

    private let panelBG = Color(red: 1.0, green: 0.975, blue: 0.94)
    private let accent = Color(red: 0.98, green: 0.55, blue: 0.63)
    private let cocoa = Color(red: 0.36, green: 0.27, blue: 0.21)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            messageList
            Divider().opacity(0.4)
            quickActions
            inputBar
        }
        .background(panelBG)
        .frame(width: 320, height: 420)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L10n.t("chat.title"))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(cocoa)
                    brainDot
                }
                statBars
            }
            Spacer()
            Button { onQuickAction(.clearHistory) } label: {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(cocoa.opacity(0.5))
            .help(L10n.t("chat.clear"))
            Button { onQuickAction(.settings) } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 13))
            }
            .buttonStyle(.plain).foregroundStyle(cocoa.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.top, 24)      // clear the overlaid titlebar close button
        .padding(.bottom, 8)
    }

    private var brainDot: some View {
        Group {
            switch core.brainState {
            case .ready: Circle().fill(.green).frame(width: 7, height: 7)
            case .generating: Circle().fill(.orange).frame(width: 7, height: 7)
            case .loading:
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            case .failed: Circle().fill(.red).frame(width: 7, height: 7)
            }
        }
        .help(brainHelp)
    }

    private var brainHelp: String {
        switch core.brainState {
        case .loading: return L10n.t("menu.brainLoading")
        case .failed(let message): return L10n.t("menu.brainFailed") + ": " + message
        default: return L10n.t("menu.brainReady")
        }
    }

    private var statBars: some View {
        HStack(spacing: 8) {
            statBar(value: core.stats.fullness, icon: "🐟", label: L10n.t("stats.hunger"))
            statBar(value: core.stats.energy, icon: "⚡️", label: L10n.t("stats.energy"))
            statBar(value: core.stats.happiness, icon: "💗", label: L10n.t("stats.happiness"))
        }
    }

    private func statBar(value: Double, icon: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(icon).font(.system(size: 9))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(cocoa.opacity(0.12))
                    Capsule().fill(barColor(value))
                        .frame(width: max(3, geo.size.width * value / 100))
                }
            }
            .frame(width: 36, height: 6)
        }
        .help("\(label): \(Int(value))/100")
    }

    private func barColor(_ v: Double) -> Color {
        v < 25 ? Color(red: 0.95, green: 0.45, blue: 0.4)
            : v < 55 ? Color(red: 0.98, green: 0.75, blue: 0.35)
            : Color(red: 0.55, green: 0.82, blue: 0.5)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.messages) { msg in
                        messageBubble(msg)
                            .id(msg.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.messages) { _, msgs in
                if let last = msgs.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onAppear {
                if let last = model.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func messageBubble(_ msg: ChatMessage) -> some View {
        HStack {
            if !msg.fromPet { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 6) {
                Text(msg.text.isEmpty ? "…" : msg.text)
                if let sourceURL = msg.sourceURL {
                    Link("打开微博来源 ↗", destination: sourceURL)
                        .font(.system(size: 11)).tint(cocoa)
                }
            }
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(msg.fromPet ? cocoa : .white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(msg.fromPet ? Color.white : accent)
                        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                )
            if msg.fromPet { Spacer(minLength: 44) }
        }
    }

    private var quickActions: some View {
        HStack(spacing: 6) {
            quickButton("🐟", L10n.t("menu.feedFish")) { onQuickAction(.feedFish) }
            quickButton("🍪", L10n.t("menu.feedCookie")) { onQuickAction(.feedCookie) }
            quickButton("🧶", L10n.t("menu.play")) { onQuickAction(.play) }
            quickButton("💤", core.isSleeping ? L10n.t("menu.wake") : L10n.t("menu.sleep")) { onQuickAction(.sleep) }
            Spacer()
            if case .loading = core.brainState {
                Text(L10n.t("chat.thinking").replacingOccurrences(of: "…", with: ""))
                    .font(.system(size: 10)).foregroundStyle(cocoa.opacity(0.4))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func quickButton(_ emoji: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(emoji).font(.system(size: 16))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.7)))
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(
                core.brainState == .ready ? L10n.t("chat.placeholder") : "可以先说‘打个滚’这类动作指令…",
                text: $model.input, axis: .vertical
            )
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(cocoa)
                .tint(accent)
                .lineLimit(1...3)
                .focused($inputFocused)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white)
                        .shadow(color: .black.opacity(0.05), radius: 2, y: 1))
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(canSend ? accent : accent.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear { inputFocused = true }
    }

    private var canSend: Bool {
        !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.busy && (core.brainState == .ready || MemoryLearning.command(in: model.input) != nil
                              || ActionLibrary.canHandleOffline(model.input))
    }

    private func send() {
        guard canSend else { return }
        let text = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        model.input = ""
        model.messages.append(ChatMessage(fromPet: false, text: text))
        model.beginStream()
        onSend(text)
    }
}

@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    let model = ChatModel()
    private var hosting: NSHostingView<ChatView>?

    var onVisibilityChange: ((Bool) -> Void)?

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange?(false)
    }

    init(core: PetCore, engine: PetEngine, brain: Brain, openSettings: @escaping () -> Void) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered, defer: false)
        super.init()
        panel.delegate = self
        // the chat UI is designed light-on-cream; force light so dark mode doesn't
        // render white text into the light background
        panel.appearance = NSAppearance(named: .aqua)
        panel.title = "\(AppIdentity.name) · 聊天"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.975, blue: 0.94, alpha: 1)

        let view = ChatView(
            model: model, core: core, settings: AppSettings.shared,
            onSend: { [weak engine] text in engine?.userSays(text) },
            onQuickAction: { [weak engine, weak self] action in
                switch action {
                case .feedFish: engine?.feed(fish: true)
                case .feedCookie: engine?.feed(fish: false)
                case .play: engine?.play()
                case .sleep:
                    if let engine {
                        engine.core.isSleeping ? engine.wake(grumpy: false) : engine.fallAsleep(commanded: true)
                    }
                case .settings: openSettings()
                case .clearHistory:
                    brain.clearHistory()
                    self?.model.messages.removeAll()
                }
            })
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        hosting = host
    }

    func refreshView(core: PetCore, engine: PetEngine, brain: Brain, openSettings: @escaping () -> Void) {
        // rebuild to pick up language changes
        let view = ChatView(
            model: model, core: core, settings: AppSettings.shared,
            onSend: { [weak engine] text in engine?.userSays(text) },
            onQuickAction: { [weak engine, weak self] action in
                switch action {
                case .feedFish: engine?.feed(fish: true)
                case .feedCookie: engine?.feed(fish: false)
                case .play: engine?.play()
                case .sleep:
                    if let engine {
                        engine.core.isSleeping ? engine.wake(grumpy: false) : engine.fallAsleep(commanded: true)
                    }
                case .settings: openSettings()
                case .clearHistory:
                    brain.clearHistory()
                    self?.model.messages.removeAll()
                }
            })
        hosting?.rootView = view
    }

    func toggle(near petCenter: CGPoint, history: [Brain.Message]) {
        if panel.isVisible {
            panel.orderOut(nil)
            onVisibilityChange?(false)
        } else {
            model.loadHistory(history)
            position(near: petCenter)
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            onVisibilityChange?(true)
        }
    }

    private func position(near petCenter: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(petCenter) }) ?? NSScreen.main
        else { return }
        let f = screen.visibleFrame
        let w: CGFloat = 320
        let h: CGFloat = 420
        var x = petCenter.x + 130
        if x + w > f.maxX - 8 { x = petCenter.x - 130 - w }
        x = min(max(x, f.minX + 8), f.maxX - w - 8)
        let y = min(max(petCenter.y - 60, f.minY + 8), f.maxY - h - 8)
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }
}
