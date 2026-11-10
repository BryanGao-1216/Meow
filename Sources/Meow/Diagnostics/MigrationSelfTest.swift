import Foundation

/// 只操作临时目录和模拟钥匙串，不读取或迁移主人的真实记录。
@MainActor
enum MigrationSelfTest {
    private enum Simulated: Error { case denied, writeFailed }

    static func run() -> Int {
        var checks = 0, failures = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("migration FAIL: \(label)") }
        }
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("meow-migration-test-" + UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        do {
            let previous = root.appendingPathComponent(LegacyMigration.supportDirectoryName)
            let current = root.appendingPathComponent(AppIdentity.appName)
            try files.createDirectory(at: previous.appendingPathComponent("backups"), withIntermediateDirectories: true)
            try files.createDirectory(at: current.appendingPathComponent("backups"), withIntermediateDirectories: true)
            let names = ["pet-state.json", "pet-memory.json", "chat-history.json", "meow-memos.json", "meow-mailbox.json", "weibo-news.json", "backups/saved.json"]
            for name in names { try Data(("original:" + name).utf8).write(to: previous.appendingPathComponent(name)) }
            try Data("new-state".utf8).write(to: current.appendingPathComponent("pet-state.json"))
            let result = try LegacyMigration.migrateSupportDirectory(at: root)
            check(result.path == current.path, "升级后使用 Meow 数据目录")
            for name in names {
                let expected = Data((name == "pet-state.json" ? "new-state" : "original:" + name).utf8)
                check(try Data(contentsOf: current.appendingPathComponent(name)) == expected, "导入缺失数据且保留新目录已有值：\(name)")
                check(try Data(contentsOf: previous.appendingPathComponent(name)) == Data(("original:" + name).utf8), "原目录备份保持原样：\(name)")
            }
            try files.removeItem(at: current.appendingPathComponent("pet-memory.json"))
            _ = try LegacyMigration.migrateSupportDirectory(at: root)
            check(!files.fileExists(atPath: current.appendingPathComponent("pet-memory.json").path), "重复启动不恢复升级后已删除的记忆")

            let broken = root.appendingPathComponent("retry")
            try files.createDirectory(at: broken, withIntermediateDirectories: true)
            let oldPath = broken.appendingPathComponent(LegacyMigration.supportDirectoryName)
            try Data("unreadable-directory".utf8).write(to: oldPath)
            do { _ = try LegacyMigration.migrateSupportDirectory(at: broken); check(false, "升级失败不能当作完成") }
            catch { check(true, "升级失败明确返回错误") }
            try files.removeItem(at: oldPath)
            try files.createDirectory(at: oldPath, withIntermediateDirectories: true)
            try Data("retry-mail".utf8).write(to: oldPath.appendingPathComponent("meow-mailbox.json"))
            let retried = try LegacyMigration.migrateSupportDirectory(at: broken)
            check(try Data(contentsOf: retried.appendingPathComponent("meow-mailbox.json")) == Data("retry-mail".utf8), "失败后再次启动可以继续导入")
        } catch { check(false, "临时目录升级：\(error)") }

        let preferences = LegacyMigration.mergedPreferences(
            previous: ["petScale": 0.5, "newsEnabled": true, "cloudModel": "saved-model", "wallAttachment": Data([1, 2])],
            current: ["newsEnabled": false])
        check(preferences["petScale"] as? Double == 0.5 && preferences["cloudModel"] as? String == "saved-model", "保留原尺寸和模型设置")
        check(preferences["newsEnabled"] as? Bool == false, "新偏好优先，包括显式关闭的开关")
        check(preferences["wallAttachment"] as? Data == Data([1, 2]), "保留贴墙位置数据")
        var changed = preferences; changed.removeValue(forKey: "cloudModel")
        check(LegacyMigration.mergedPreferences(previous: ["cloudModel": "old"], current: changed)["cloudModel"] == nil,
              "重复启动不恢复已清除的偏好")

        var stored: [String: Data] = ["previous": Data(repeating: 42, count: 32)]
        var reads: [String] = [], writes = 0, deny = false, failWrite = false
        let credential = MigratingCredential(service: "current", previousService: "previous", read: {
            reads.append($0)
            if deny && $0 == "previous" { throw Simulated.denied }
            return stored[$0]
        }, write: {
            if failWrite { throw Simulated.writeFailed }
            writes += 1; stored[$0] = $1
        })
        do {
            let identity = try credential.load()
            check(identity == Data(repeating: 42, count: 32) && stored["current"] == identity && writes == 1,
                  "设备私钥逐字节迁移，设备码和原配对身份保持有效")
            reads.removeAll()
            check(try credential.load() == identity && reads == ["current"] && writes == 1, "新钥匙串项存在时不再访问旧项")
            try credential.save(Data())
            check(try credential.load() == Data() && stored["previous"] == identity, "清除凭据后不重新导入，旧项保留作备份")
            stored.removeValue(forKey: "current"); deny = true
            do { _ = try credential.load(); check(false, "拒绝授权不能当作没有私钥") }
            catch { check(stored["current"] == nil, "拒绝授权不创建或替换设备身份") }
            deny = false; failWrite = true
            do { _ = try credential.load(); check(false, "迁移写入失败不能返回成功") }
            catch { check(stored["current"] == nil && stored["previous"] == identity, "迁移失败保留原密钥，允许重试") }
            failWrite = false
            check(try credential.load() == identity, "迁移重试恢复同一设备身份")
        } catch { check(false, "模拟钥匙串升级：\(error)") }
        for suffix in ["volcengine", "weibo", "iroh.identity"] {
            check(LegacyMigration.keychainService(for: AppIdentity.bundleIdentifier + "." + suffix)
                  == LegacyMigration.bundleIdentifier + "." + suffix, "独立迁移凭据：\(suffix)")
        }
        print("name migration: \(checks - failures)/\(checks) OK（临时数据与模拟钥匙串）")
        return failures
    }
}
