import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    let core = PetCore()
    let brain = Brain()
    private(set) var engine: PetEngine!

    private var petPanel: PetPanel!
    private var containerView: PetContainerView!
    private var bubbleController: BubbleWindowController!
    private var chatController: ChatWindowController!
    private var settingsController: SettingsWindowController!
    private var memoryController: MemoryWindowController!
    private var features: CompanionFeatures!
    private var statusItem: NSStatusItem!
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if DebugLog.enabled {
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { ev in
                DebugLog.write("local monitor: type=\(ev.type.rawValue) win=\(ev.window.map { String(describing: type(of: $0)) } ?? "nil") loc=\(ev.locationInWindow)")
                return ev
            }
        }

        if var saved = Persistence.loadStats() {
            Persistence.applyOfflineDecay(&saved)
            core.stats = saved
        }

        let wallAttachment = UserDefaults.standard.data(forKey: "wallAttachment")
            .flatMap { try? JSONDecoder().decode(WallAttachment.self, from: $0) }
        engine = PetEngine(core: core, brain: brain, wallAttachment: wallAttachment)
        engine.onWallAttachmentChange = { attachment in
            if let attachment, let data = try? JSONEncoder().encode(attachment) {
                UserDefaults.standard.set(data, forKey: "wallAttachment")
            } else {
                UserDefaults.standard.removeObject(forKey: "wallAttachment")
            }
        }
        bubbleController = BubbleWindowController()
        engine.bubble = bubbleController

        // pet window
        let side = PetLayout.windowSize(scale: AppSettings.shared.petScale)
        petPanel = PetPanel(size: side)
        containerView = PetContainerView(core: core)
        containerView.engine = engine
        containerView.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        containerView.openChat = { [weak self] in self?.toggleChat() }
        petPanel.contentView = containerView

        engine.moveWindow = { [weak self] center in
            guard let self else { return }
            self.petPanel.place(at: center, core: self.core, scale: AppSettings.shared.petScale,
                                container: self.containerView)
        }

        // chat + settings
        memoryController = MemoryWindowController(memory: brain.memory)
        features = CompanionFeatures(brain: brain, engine: engine)
        containerView.openMail = { [weak self] in self?.features.showMailbox(openUnread: true) }
        settingsController = SettingsWindowController(onResetStats: { [weak self] in
            guard let self else { return }
            self.core.stats = PetStats()
            Persistence.saveStats(self.core.stats)
        }, onApplyBrainSettings: { [weak self] in
            self?.brain.memory.cancelLearning()
            self?.engine.reloadBrain()
            self?.features.configurationChanged()
        }, onOpenMemory: { [weak self] in
            self?.memoryController.show()
        }, onOpenNews: { [weak self] in
            self?.features.showNews()
        })
        chatController = ChatWindowController(
            core: core, engine: engine, brain: brain,
            openSettings: { [weak self] in self?.settingsController.show() })
        chatController.onVisibilityChange = { [weak self] visible in
            visible == true ? self?.engine.chatOpened() : self?.engine.chatClosed()
        }
        engine.chatMirror = { [weak self] text, done in
            self?.chatController.model.updateStream(text, done: done)
        }
        engine.proactiveMirror = { [weak self] text in
            self?.chatController.model.appendProactive(text)
        }
        engine.newsMirror = { [weak self] text, source in
            self?.chatController.model.appendNews(text, sourceURL: source)
        }
        brain.onHistoryReset = { [weak self] in
            self?.chatController.model.reset()
            self?.engine.resetConversationContext()
        }
        Publishers.CombineLatest(AppSettings.shared.$memoryEnabled, AppSettings.shared.$memoryAIEnabled)
            .dropFirst()
            .sink { [weak self] _, _ in
                self?.brain.memory.cancelLearning()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.brain.memory.migrate(self.brain.history)
                    self.brain.memory.presence()
                }
            }.store(in: &cancellables)
        AppSettings.shared.$newsEnabled.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.features.configurationChanged() }
        }.store(in: &cancellables)
        AppSettings.shared.$memoryEnabled.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.features.configurationChanged() }
        }.store(in: &cancellables)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.features.resume() }
            .store(in: &cancellables)

        // status bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = StatusIcon.make()
            button.toolTip = AppIdentity.appName
            button.setAccessibilityLabel(AppIdentity.appName)
        }
        let menu = NSMenu(title: AppIdentity.appName)
        menu.delegate = self
        statusItem.menu = menu

        // brain
        brain.onStateChange = { [weak self] state in
            self?.core.brainState = state
        }
        core.brainState = .loading
        brain.load()

        // start behavior
        let savedX = UserDefaults.standard.object(forKey: "petX") as? Double
        let start: CGPoint? = savedX.map { CGPoint(x: $0, y: 0) }
        petPanel.orderFrontRegardless()
        engine.start(at: start.map { p in
            let f = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let x = min(max(p.x, f.minX + 60), f.maxX - 60)
            return CGPoint(x: x, y: f.minY + PetLayout.feetDrop(scale: AppSettings.shared.petScale))
        })
        features.start()

        // settings reactions. @Published emits on willSet — the stored property still
        // holds the OLD value at that instant — so hop the runloop before applying.
        AppSettings.shared.$petScale
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.applyScale() }
            }
            .store(in: &cancellables)
        // A cloud-only first launch has no key yet. Make the setup fields easy
        // to find instead of leaving a silent, unavailable chat window.
        if AppSettings.shared.brainProvider == .volcengine, !brain.isReady {
            settingsController.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        features.shutdown()
        UserDefaults.standard.set(engine.petCenter.x, forKey: "petX")
        engine.shutdown()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu: menu)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: AppIdentity.appName)
        populate(menu: menu)
        return menu
    }

    private func populate(menu: NSMenu) {
        func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.target = self
            return it
        }

        menu.addItem(item(L10n.t("menu.chat"), #selector(menuChat)))
        if core.wallSide != nil {
            let hint = NSMenuItem(title: "贴墙中 · 拖回桌面可恢复活动", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        menu.addItem(.separator())
        menu.addItem(item(L10n.t("menu.feedFish"), #selector(menuFeedFish)))
        menu.addItem(item(L10n.t("menu.feedCookie"), #selector(menuFeedCookie)))
        menu.addItem(item(L10n.t("menu.play"), #selector(menuPlay)))
        menu.addItem(item(
            core.isSleeping ? L10n.t("menu.wake") : L10n.t("menu.sleep"),
            #selector(menuSleep)))
        menu.addItem(item(L10n.t("menu.callOver"), #selector(menuCallOver)))
        menu.addItem(.separator())

        let stats = NSMenuItem(
            title: "🐟 \(Int(core.stats.fullness))   ⚡️ \(Int(core.stats.energy))   💗 \(Int(core.stats.happiness))",
            action: nil, keyEquivalent: "")
        stats.isEnabled = false
        menu.addItem(stats)

        let brainTitle: String
        switch core.brainState {
        case .loading: brainTitle = L10n.t("menu.brainLoading")
        case .ready, .generating: brainTitle = L10n.t("menu.brainReady")
        case .failed: brainTitle = L10n.t("menu.brainFailed")
        }
        let brainItem = NSMenuItem(title: brainTitle, action: nil, keyEquivalent: "")
        brainItem.isEnabled = false
        menu.addItem(brainItem)
        menu.addItem(.separator())

        menu.addItem(item(L10n.t("menu.settings"), #selector(menuSettings)))
        menu.addItem(item("小本本…", #selector(menuMemory)))
        menu.addItem(item("热点小报…", #selector(menuNews)))
        menu.addItem(item("喵喵备忘录…", #selector(menuMemos)))
        let unread = features.mailbox.book.unreadCount
        menu.addItem(item(unread > 0 ? "喵喵信箱 · \(unread) 封未读…" : "喵喵信箱…", #selector(menuMailbox)))
        menu.addItem(item(L10n.t("menu.quit"), #selector(menuQuit), key: "q"))
    }

    @objc private func menuChat() { toggleChat() }
    @objc private func menuFeedFish() { engine.feed(fish: true) }
    @objc private func menuFeedCookie() { engine.feed(fish: false) }
    @objc private func menuPlay() { engine.play() }
    @objc private func menuSleep() {
        core.isSleeping ? engine.wake(grumpy: false) : engine.fallAsleep(commanded: true)
    }
    @objc private func menuCallOver() { engine.callOver() }
    @objc private func menuSettings() { settingsController.show() }
    @objc private func menuMemory() { memoryController.show() }
    @objc private func menuNews() { features.showNews() }
    @objc private func menuMemos() { features.showMemos() }
    @objc private func menuMailbox() { features.showMailbox() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    private func toggleChat() {
        chatController.refreshView(
            core: core, engine: engine, brain: brain,
            openSettings: { [weak self] in self?.settingsController.show() })
        chatController.toggle(near: engine.petCenter, history: brain.history)
    }

    // MARK: - Settings reactions

    private func applyScale() {
        engine.rescaled()
    }

}
