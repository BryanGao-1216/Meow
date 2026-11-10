import Foundation

public struct NewsSlot: Equatable, Sendable {
    public var id: String
    public var date: Date
}

/// 固定北京时间；只有最近一小时的一期可以补抓，避免唤醒后连续讲三期旧新闻。
public enum NewsSchedule {
    public static let hours = [11, 16, 19]
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private static func slots(on day: Date) -> [NewsSlot] {
        let calendar = self.calendar
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return hours.compactMap { hour in
            var value = parts; value.hour = hour; value.minute = 0; value.second = 0
            guard let date = calendar.date(from: value) else { return nil }
            let id = String(format: "%04d-%02d-%02d-%02d", parts.year!, parts.month!, parts.day!, hour)
            return NewsSlot(id: id, date: date)
        }
    }

    public static func due(at now: Date, runs: [NewsRun]) -> NewsSlot? {
        guard let slot = slots(on: now).last(where: { $0.date <= now }), now.timeIntervalSince(slot.date) < 3600 else { return nil }
        if let run = runs.last(where: { $0.slotID == slot.id }) {
            guard !run.completed, run.attempts < 3, now.timeIntervalSince(run.lastAttempt) >= 300 else { return nil }
        }
        return slot
    }

    public static func next(at now: Date) -> Date {
        if let next = slots(on: now).first(where: { $0.date > now }) { return next.date }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        return slots(on: tomorrow)[0].date
    }

    public static func display(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MM月dd日 HH:mm"
        return formatter.string(from: date)
    }
}
