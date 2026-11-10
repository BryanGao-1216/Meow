import Foundation

/// 注入模拟读写，只验证授权流程；不访问真实钥匙串、密码或网络。
@MainActor
enum CredentialSelfTest {
    private enum Simulated: Error { case denied, writeFailed }

    static func run() -> Int {
        var checks = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("credential FAIL: \(label)") }
        }
        var stored = "fake-test-key", reads = 0, writes = 0, failWrite = false
        let session = CredentialSession<String>(read: { reads += 1; return stored }, write: {
            writes += 1
            if failWrite { throw Simulated.writeFailed }
            stored = $0
        })
        check((try? session.load()) == stored && (try? session.load()) == stored && reads == 1, "启动和设置共享一次读取")
        try? session.save(stored)
        check(writes == 0, "未改动密钥时不重复写入或授权")
        try? session.save("replacement-test-key")
        check((try? session.load()) == "replacement-test-key" && reads == 1 && writes == 1, "保存后重载模型直接使用会话中的新密钥")
        failWrite = true
        do { try session.save("should-not-save"); check(false, "保存失败必须返回错误") }
        catch { check((try? session.load()) == "replacement-test-key" && stored == "replacement-test-key", "保存失败不替换已生效的密钥") }
        failWrite = false; stored = "changed-outside-test"
        check((try? session.load(retry: true)) == stored && reads == 2, "仅明确重试时重新读取")
        try? session.save("")
        check((try? session.load()) == "" && stored.isEmpty && reads == 2, "清除后不恢复会话中的旧密钥")

        var denied = true, attempts = 0
        let blocked = CredentialSession<String>(read: {
            attempts += 1; if denied { throw Simulated.denied }; return "authorized-test-key"
        }, write: { _ in })
        for _ in 0..<4 { _ = try? blocked.load() }
        check(attempts == 1, "取消或拒绝后不会因启动重载和打开设置反复弹窗")
        denied = false
        check((try? blocked.load(retry: true)) == "authorized-test-key" && attempts == 2, "手动重新授权可以恢复读取")
        check((try? blocked.load()) == "authorized-test-key" && attempts == 2, "恢复后的读取继续复用结果")

        var reentrant: CredentialSession<String>!
        var nestedFailed = false
        reentrant = CredentialSession<String>(read: {
            do { _ = try reentrant.load() } catch { nestedFailed = true }
            return "outer-test-key"
        }, write: { _ in })
        check((try? reentrant.load()) == "outer-test-key" && nestedFailed, "等待系统授权期间不重入读取")

        let date = Date(timeIntervalSince1970: 100)
        check(AppInstance.leader(in: [.init(pid: 10, launchedAt: date), .init(pid: 20, launchedAt: date.addingTimeInterval(1))]) == 10, "安装盘和应用程序两份实例选择先启动的一份")
        check(AppInstance.leader(in: [.init(pid: 20, launchedAt: date), .init(pid: 10, launchedAt: date)]) == 10, "同时启动时所有实例作出一致选择")
        check(AppInstance.leader(in: []) == nil, "没有旧实例时正常启动")
        print("credential+instance: \(checks - failures)/\(checks) OK（模拟凭据，不访问真实钥匙串）")
        return failures
    }
}
