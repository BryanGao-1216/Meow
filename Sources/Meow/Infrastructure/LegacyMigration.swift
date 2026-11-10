import Foundation

/// 旧标识只用于升级导入；新数据全部使用 Meow 标识，保留原目录作为备份。
enum LegacyMigration {
    static let bundleIdentifier = "com.kokosuki.pet"
    static let supportDirectoryName = "Kokosuki"
    private static let markerName = ".meow-name-migration-v1"
    private static let preferencesMarker = "meowNameMigrationV1"

    static func deviceLabel(_ value: String) -> String {
        switch value {
        case "这台 Mac 的小喵": return "这台 Mac 的 Meow"
        case "另一台 Mac 的小喵": return "另一台 Mac 的 Meow"
        default: return value
        }
    }

    static func keychainService(for service: String) -> String? {
        let prefix = AppIdentity.bundleIdentifier + "."
        guard service.hasPrefix(prefix) else { return nil }
        return bundleIdentifier + "." + service.dropFirst(prefix.count)
    }

    static func prepare() throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        _ = try migrateSupportDirectory(at: base)
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        guard current[preferencesMarker] as? Bool != true else { return }
        let previous = defaults.persistentDomain(forName: bundleIdentifier)
            ?? defaults.persistentDomain(forName: supportDirectoryName) ?? [:]
        defaults.setPersistentDomain(mergedPreferences(previous: previous, current: current), forName: domain)
    }

    static func mergedPreferences(previous: [String: Any], current: [String: Any]) -> [String: Any] {
        guard current[preferencesMarker] as? Bool != true else { return current }
        var merged = previous.merging(current) { _, current in current }
        merged[preferencesMarker] = true
        return merged
    }

    @discardableResult
    static func migrateSupportDirectory(at base: URL) throws -> URL {
        let files = FileManager.default
        let current = base.appendingPathComponent(AppIdentity.appName, isDirectory: true)
        let previous = base.appendingPathComponent(supportDirectoryName, isDirectory: true)
        let marker = current.appendingPathComponent(markerName)
        try files.createDirectory(at: current, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard !files.fileExists(atPath: marker.path) else { return current }
        if files.fileExists(atPath: previous.path) { try copyMissing(from: previous, to: current) }
        try Data("Meow migration complete\n".utf8).write(to: marker, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        return current
    }

    private static func copyMissing(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        for item in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if !files.fileExists(atPath: target.path) {
                let staging = destination.appendingPathComponent(".meow-import-" + UUID().uuidString)
                do {
                    try files.copyItem(at: item, to: staging)
                    try files.moveItem(at: staging, to: target)
                } catch {
                    try? files.removeItem(at: staging)
                    throw error
                }
            } else {
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let targetValues = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true,
                   targetValues.isDirectory == true, targetValues.isSymbolicLink != true {
                    try copyMissing(from: item, to: target)
                }
            }
        }
    }
}

/// 新项目项优先；成功写入后才使用旧项，失败时不伪装成空凭据或生成新设备身份。
struct MigratingCredential {
    let service: String
    let previousService: String?
    let read: (String) throws -> Data?
    let write: (String, Data) throws -> Void

    func load() throws -> Data? {
        if let value = try read(service) { return value }
        guard let previousService, let value = try read(previousService) else { return nil }
        try write(service, value)
        return value
    }

    /// 空数据保留为已清除标记，避免下次启动又从旧项导入已删除的密钥。
    func save(_ value: Data) throws { try write(service, value) }
}
