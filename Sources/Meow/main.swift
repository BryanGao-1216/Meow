// Meow：支持本地模型与云端对话的桌面小猫。
import AppKit

MainActor.assumeIsolated {
    let cliArgs = CommandLine.arguments
    if cliArgs.contains("--credentials-check") {
        exit(CredentialSelfTest.run() == 0 ? 0 : 1)
    }
    if cliArgs.contains("--mailbox-check") {
        Task { exit(await MailboxSelfTest.run() == 0 ? 0 : 1) }
        RunLoop.main.run()
    }
    if let i = cliArgs.firstIndex(of: "--mailbox-render-check"), i + 1 < cliArgs.count {
        let app = NSApplication.shared
        Task { exit(await MailboxPreview.render(outDir: cliArgs[i + 1]) == 0 ? 0 : 1) }
        app.run()
        exit(0)
    }
    if let i = cliArgs.firstIndex(of: "--memo-render-check"), i + 1 < cliArgs.count {
        let app = NSApplication.shared
        Task { exit(await MemoPreview.render(outDir: cliArgs[i + 1]) == 0 ? 0 : 1) }
        app.run()
        exit(0)
    }
    if let i = cliArgs.firstIndex(of: "--wall-render-check"), i + 1 < cliArgs.count {
        let app = NSApplication.shared
        Task { exit(await WallRenderSelfTest.run(outDir: cliArgs[i + 1]) == 0 ? 0 : 1) }
        app.run()
        exit(0)
    }
    if cliArgs.contains("--news-preview") {
        Snapshot.newsPreview()
        exit(0)
    }
    if cliArgs.contains("--news-check") {
        Task { await NewsSelfTest.probe() }
        RunLoop.main.run()
    }
    if cliArgs.contains("--memory-preview") {
        Snapshot.memoryPreview()
        exit(0)
    }
    if let i = cliArgs.firstIndex(of: "--snapshot"), i + 1 < cliArgs.count {
        Snapshot.run(outDir: cliArgs[i + 1])
        exit(0)
    }
    if let i = cliArgs.firstIndex(of: "--icon"), i + 1 < cliArgs.count {
        Snapshot.icon(outDir: cliArgs[i + 1])
        exit(0)
    }
    if cliArgs.contains("--selftest") {
        SelfTest.run()
        // SelfTest drives the runloop and exits itself
        RunLoop.main.run()
    }
    if let i = cliArgs.firstIndex(of: "--scenarios") {
        let rounds = cliArgs.indices.contains(i + 1) ? Int(cliArgs[i + 1]) ?? 1 : 1
        SelfTest.runScenarios(rounds: rounds)
        RunLoop.main.run()
    }
    if cliArgs.contains("--platforms") {
        let tracker = PlatformTracker()
        tracker.refresh()
        for p in tracker.platforms {
            print("platform id=\(p.id) topY(cocoa)=\(Int(p.y)) x=\(Int(p.minX))..\(Int(p.maxX))")
        }
        print("\(tracker.platforms.count) platforms")
        exit(0)
    }

    if AppInstance.activateExistingIfNeeded() { exit(0) }
    do { try LegacyMigration.prepare() }
    catch {
        NSApplication.shared.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = "Meow 数据升级未完成"
        alert.informativeText = "原有数据已保留。请确认本机存储空间及目录权限后重新打开。\n\(error.localizedDescription)"
        alert.addButton(withTitle: "退出")
        alert.runModal()
        exit(1)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
