import AppKit
import SwiftUI
import MeowNews

/// Offscreen rendering for visual QA and icon generation (no window needed).
/// `meow --snapshot <dir>` dumps PNGs of key states; `--icon <dir>` renders icon art.
@MainActor
enum Snapshot {

    static func newsPreview() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meow-news-preview-" + UUID().uuidString)
        let url = directory.appendingPathComponent("news.json")
        let topic = WeiboTopic(title: "【界面预览】人工智能话题示例", category: "科技", rank: 1)
        var item = NewsBulletin(topic: topic, line: "刷到一个人工智能话题，想起你关注科技，一起看看喵。",
            excerpts: [NewsExcerpt(text: "这是界面预览用的虚构摘录，用于检查中文排版与来源链接，不是真实新闻。", sourceURL: topic.sourceURL)],
            detailNote: "虚构示例；此预览不会读取登录凭据或调用网络。", slotID: nil, expiresAt: Date().addingTimeInterval(3600))
        item.deliveredAt = Date()
        var state = NewsState(); state.bulletins = [item]
        state.recentTopics = [NewsStamp(title: topic.title, date: Date())]
        try? state.write(to: url)
        let dependencies = NewsDependencies(fetchTopics: { _, _ in [topic] }, fetchExcerpts: { _, _ in [] },
            complete: { _, _ in nil }, cookie: { "" }, taste: { NewsTaste(statements: ["主人关注人工智能"]) },
            deliver: { _ in false }, persona: { "你是 Meow。" })
        let news = HotNewsController(storageURL: url, respectsSettings: false, dependencies: dependencies)
        let controller = NewsWindowController(news: news, loadsCredentials: false)
        controller.show(activate: false)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            news.shutdown()
            try? FileManager.default.removeItem(at: directory)
            app.terminate(nil)
        }
        withExtendedLifetime(controller) { app.run() }
    }

    /// 隔离的真实窗口预览：无模型、无 Keychain、无真实聊天或记忆读写。
    static func memoryPreview() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meow-memory-preview-" + UUID().uuidString)
        let memory = PetMemory(storageURL: directory.appendingPathComponent("memory.json"), respectsSettings: false)
        memory.observe("我叫小夏。叫我夏夏吧。我喜欢茉莉花茶。我希望安静一些")
        memory.record(.petted)
        memory.record(.fedFish)
        memory.record(.playedYarn)
        let controller = MemoryWindowController(memory: memory)
        controller.show(activate: false)
        // 预览自动结束，不留下常驻宠物或后台模型请求。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            memory.cancelLearning()
            memory.flush()
            try? FileManager.default.removeItem(at: directory)
            app.terminate(nil)
        }
        withExtendedLifetime(controller) { app.run() }
    }

    struct FixedPetView: View {
        var state: PetRenderState
        var t: Double
        var body: some View {
            Canvas { ctx, size in
                var painter = PetPainter(s: state, t: t)
                painter.draw(in: &ctx, size: size)
            }
            .frame(width: PetLayout.renderSize(scale: 1, wallSide: state.wallSide, wallReveal: state.wallReveal).width,
                   height: PetLayout.renderSize(scale: 1, wallSide: state.wallSide, wallReveal: state.wallReveal).height)
            .background(Color(red: 0.55, green: 0.65, blue: 0.75))  // neutral backdrop for QA
        }
    }

    static func run(outDir: String) {
        let dir = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var cases: [(String, (PetCore) -> Void)] = [
            ("idle-neutral", { _ in }),
            ("happy", { $0.emotion = .happy }),
            ("love", { $0.emotion = .love; $0.spawn(.heart, count: 3, near: CGPoint(x: 0, y: 40)) }),
            ("sad", { $0.emotion = .sad }),
            ("angry", { $0.emotion = .angry }),
            ("surprised", { $0.emotion = .surprised }),
            ("sleepy", { $0.emotion = .sleepy }),
            ("hungry", { $0.emotion = .hungry }),
            ("shy", { $0.emotion = .shy }),
            ("curious", { $0.emotion = .curious }),
            ("sleeping", { $0.isSleeping = true; $0.activity = .sleep; $0.spawn(.zzz, count: 2, near: CGPoint(x: 26, y: 40)) }),
            ("walking", { $0.activity = .walk; $0.walkPhase = 1.2 }),
            ("dragged", { $0.activity = .drag; $0.pickupWiggle = 1; $0.emotion = .surprised }),
            ("eating", { $0.activity = .eat(food: "🐟"); $0.emotion = .happy }),
            ("dancing", { $0.activity = .dance; $0.emotion = .excited }),
            ("rolling-start", { $0.activity = .rollPose; $0.actionPhase = 0.25; $0.emotion = .playful }),
            ("rolling-side", { $0.activity = .rollPose; $0.actionPhase = 0.98; $0.emotion = .playful }),
            ("rolling-back", { $0.activity = .rollPose; $0.actionPhase = 1.3; $0.emotion = .playful }),
            ("rolling-return", { $0.activity = .rollPose; $0.actionPhase = 2.05; $0.emotion = .playful }),
            ("waving", { $0.activity = .wave; $0.actionPhase = 0.9; $0.emotion = .happy }),
            ("nodding", { $0.activity = .nod; $0.actionPhase = 0.56 }),
            ("shaking-head", { $0.activity = .shakeHead; $0.actionPhase = 0.56 }),
            ("thinking", { $0.activity = .think; $0.emotion = .curious }),
            ("talking", { $0.activity = .talk; $0.talkLevel = 0.8; $0.emotion = .happy }),
            ("stretching", { $0.activity = .stretchPose; $0.actionPhase = 1.1 }),
            ("playing", { $0.activity = .play; $0.emotion = .playful }),
            ("sulking", { $0.activity = .sulk; $0.emotion = .sad; $0.lookAway = 1 }),
            ("wall-left", { $0.wallSide = .left }),
            ("wall-right", { $0.wallSide = .right }),
            ("wall-left-hello", { $0.wallSide = .left; $0.wallReveal = 1; $0.emotion = .happy }),
            ("wall-right-hello", { $0.wallSide = .right; $0.wallReveal = 1; $0.emotion = .happy }),
            ("wall-mid-peek", { $0.wallSide = .left; $0.wallReveal = 0.5 }),
            ("wall-sleeping", { $0.wallSide = .left; $0.isSleeping = true; $0.activity = .sleep }),
            ("wall-blinking", { $0.wallSide = .right; $0.blink = 1 }),
            ("wall-happy", { $0.wallSide = .left; $0.emotion = .happy }),
            ("holding-letter", { $0.unreadLetters = 1; $0.emotion = .happy }),
            ("holding-many-letters", { $0.unreadLetters = 12 }),
            ("wall-left-letter", { $0.wallSide = .left; $0.wallReveal = 1; $0.unreadLetters = 1; $0.emotion = .happy }),
            ("wall-right-letter", { $0.wallSide = .right; $0.wallReveal = 1; $0.unreadLetters = 2; $0.emotion = .happy }),
        ]
        cases.append(("dizzy", { c in c.dizzy = 1; c.emotion = .surprised }))

        for (name, setup) in cases {
            let core = PetCore()
            setup(core)
            let view = FixedPetView(state: core.snapshot(), t: 0.9)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage, let png = pngData(img) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
                print("wrote \(name).png")
            } else {
                print("FAILED \(name)")
            }
        }
    }

    /// Icon: the cat on a soft rounded-square pastel background.
    struct IconView: View {
        var state: PetRenderState
        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 180, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.87, blue: 0.77),
                                Color(red: 1.0, green: 0.76, blue: 0.72),
                            ],
                            startPoint: .top, endPoint: .bottom))
                    .frame(width: 830, height: 830)
                Canvas { ctx, size in
                    var painter = PetPainter(s: state, t: 0.9)
                    painter.draw(in: &ctx, size: size)
                }
                .frame(width: 780, height: 780)
                .offset(y: 8)
            }
            .frame(width: 1024, height: 1024)
        }
    }

    static func icon(outDir: String) {
        let dir = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let core = PetCore()
        core.emotion = .happy
        let renderer = ImageRenderer(content: IconView(state: core.snapshot()))
        renderer.scale = 1
        if let img = renderer.nsImage, let png = pngData(img) {
            try? png.write(to: dir.appendingPathComponent("icon-1024.png"))
            print("wrote icon-1024.png")
        } else {
            print("FAILED icon")
        }

        // menu-bar template icon preview (rendered dark-on-light at 4x for inspection)
        let bar = StatusIcon.make()
        let preview = NSImage(size: NSSize(width: 72, height: 72), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            bar.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72))
            return true
        }
        if let png = pngData(preview) {
            try? png.write(to: dir.appendingPathComponent("statusicon.png"))
            print("wrote statusicon.png")
        }

        // settings UI symmetry check
        let settingsView = SettingsView(settings: AppSettings.shared, onResetStats: {}, onApplyBrainSettings: {})
        let sr = ImageRenderer(content: settingsView.settingsContent)
        sr.scale = 2
        if let img = sr.nsImage, let png = pngData(img) {
            try? png.write(to: dir.appendingPathComponent("settings.png"))
            print("wrote settings.png")
        }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
