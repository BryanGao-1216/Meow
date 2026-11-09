import AppKit
import KokosukiMemos

/// 临时样例与实窗截图，不读取真实备忘录、模型或凭据。
@MainActor
enum MemoPreview {
    static func render(outDir: String) async -> Int {
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meow-memo-preview-" + UUID().uuidString)
        let url = directory.appendingPathComponent("memos.json")
        let date = Date()
        var book = MemoBook()
        book.items = [MemoItem(title: "今晚和朋友聚会，记得提前准备", dueAt: date.addingTimeInterval(2 * 3600), now: date),
                      MemoItem(title: "给小喵买猫粮", dueAt: date.addingTimeInterval(86400), now: date),
                      MemoItem(title: "检查明天要带的资料", dueAt: date.addingTimeInterval(-120), now: date)]
        do { try book.write(to: url) } catch { print(error.localizedDescription); return 1 }
        let memos = MemoController(storageURL: url, dependencies: MemoDependencies(complete: { _, _ in nil },
            canEvaluate: { _ in false }, deliver: { _ in false }, persona: { "你是高小喵。" }, preferences: { [] }))
        let window = MemoWindowController(memos: memos)
        defer { window.panel.close(); memos.shutdown(); try? FileManager.default.removeItem(at: directory) }
        window.show(activate: false)
        try? await Task.sleep(for: .milliseconds(400))
        guard let view = window.panel.contentView else { return 1 }
        view.layoutSubtreeIfNeeded(); window.panel.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        do {
            let output = URL(fileURLWithPath: outDir)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
            try png.write(to: output.appendingPathComponent("memo-window.png"))
            print("memo window: \(Int(view.bounds.width))×\(Int(view.bounds.height))，已输出实窗截图（独立样例、无网络）")
            return view.bounds.width >= 600 && view.bounds.height >= 700 ? 0 : 1
        } catch { print(error.localizedDescription); return 1 }
    }
}
