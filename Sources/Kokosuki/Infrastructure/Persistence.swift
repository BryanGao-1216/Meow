import Foundation

enum Persistence {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Kokosuki", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var statsURL: URL { supportDir.appendingPathComponent("pet-state.json") }

    static func loadStats() -> PetStats? {
        guard let data = try? Data(contentsOf: statsURL) else { return nil }
        return try? JSONDecoder().decode(PetStats.self, from: data)
    }

    static func saveStats(_ stats: PetStats) {
        var s = stats
        s.lastSaved = .now
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: statsURL, options: .atomic)
        }
    }

    /// Apply offline decay for the time the app wasn't running (gentle: capped at 8h).
    static func applyOfflineDecay(_ stats: inout PetStats) {
        let away = min(Date().timeIntervalSince(stats.lastSaved), 8 * 3600)
        guard away > 60 else { return }
        let minutes = away / 60
        stats.fullness -= minutes * 0.10
        stats.energy += minutes * 0.20      // it napped while you were gone
        stats.happiness -= minutes * 0.02
        stats.clamp()
    }
}
