import AppKit

/// 安装磁盘和应用程序中的两份应用共用同一个运行实例。
@MainActor
enum AppInstance {
    struct Candidate {
        let pid: Int32
        let launchedAt: Date?
    }

    static func leader(in candidates: [Candidate]) -> Int32? {
        candidates.min {
            let first = $0.launchedAt ?? .distantPast, second = $1.launchedAt ?? .distantPast
            return first == second ? $0.pid < $1.pid : first < second
        }?.pid
    }

    static func activateExistingIfNeeded() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.kokosuki.pet"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        guard let pid = leader(in: running.map { Candidate(pid: $0.processIdentifier, launchedAt: $0.launchDate) }),
              pid != ProcessInfo.processInfo.processIdentifier,
              let existing = running.first(where: { $0.processIdentifier == pid }) else { return false }
        existing.activate(options: [.activateAllWindows])
        return true
    }
}
