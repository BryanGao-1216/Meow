import Foundation

/// 保守处理中文生日声明，以及紧接主人自己生日话题的日期回答。
/// 不使用宠物生成的台词判断“这是谁的生日”。
enum BirthdayMemory {
    private static let number = "[0-9零〇一二三四五六七八九十廿卅正冬腊]{1,4}"
    private static let calendar = "(?:农历|阴历|公历|阳历)"
    private static let date = "(?:\(calendar)\\s*)?(?:\(number)\\s*(?:年|[-/.])\\s*)?\(number)\\s*(?:月|[-/.])\\s*初?\(number)\\s*(?:日|号)?"
    private static let lead = "(?:(?:其实|对了|请记住|你记住|记住|告诉你)\\s*)?"
    private static let tail = "[哦噢喔呀啊呢啦哟哈的喵～~\\s]{0,6}"

    static func isOwnerTopic(_ text: String) -> Bool {
        text.range(of: "我(?:的)?(?:农历|阴历|公历|阳历)?(?:生日|生辰)", options: .regularExpression) != nil
    }

    static func extract(in original: String, previousUserMessage: String?) -> String? {
        let text = original.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? original
        let patterns = [
            "^\(lead)我(?:的)?(?:\(calendar))?(?:生日|生辰)\\s*(?:就是|是在|是|在|为|:|：)?\\s*(\(date))\(tail)$",
            "^\(lead)我(?:是|在)\\s*(\(date))\\s*(?:过生日|生日|出生的|出生)\(tail)$",
            "^\(lead)我(?:出生于|出生在)\\s*(\(date))\(tail)$",
            "^\(lead)(\(date))\\s*(?:是|就是)我(?:的)?(?:生日|生辰)\(tail)$",
        ]
        for pattern in patterns {
            if let raw = capture(pattern, text: text, group: 1) {
                return normalizedDate(raw, lunar: text.contains("农历") || text.contains("阴历"))
            }
        }
        guard let previousUserMessage, isOwnerTopic(previousUserMessage),
              let raw = capture("^(?:就是|是|在)?\\s*(\(date))\(tail)$", text: text, group: 1) else { return nil }
        let explicitSolar = raw.contains("公历") || raw.contains("阳历")
        let lunar = raw.contains("农历") || raw.contains("阴历")
            || (!explicitSolar && (previousUserMessage.contains("农历") || previousUserMessage.contains("阴历")))
        return normalizedDate(raw, lunar: lunar)
    }

    private static func normalizedDate(_ text: String, lunar: Bool) -> String? {
        let pattern = "^(?:\(calendar)\\s*)?(?:(\(number))\\s*(?:年|[-/.])\\s*)?(\(number))\\s*(?:月|[-/.])\\s*初?(\(number))\\s*(?:日|号)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func part(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        guard let rawMonth = part(2), let month = integer(rawMonth), (1...12).contains(month),
              let rawDay = part(3), let day = integer(rawDay), day >= 1 else { return nil }
        var year: Int?
        if let rawYear = part(1) {
            // 两位年份不猜世纪。
            guard rawYear.count == 4, let parsed = integer(rawYear), (1...9999).contains(parsed) else { return nil }
            year = parsed
        }
        var maxDays = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        if lunar { maxDays = 30 }
        else if month == 2, let year, !(year % 400 == 0 || (year % 4 == 0 && year % 100 != 0)) { maxDays = 28 }
        guard day <= maxDays else { return nil }
        return (lunar ? "农历" : "") + (year.map { "\($0)年" } ?? "") + "\(month)月\(day)日"
    }

    private static func integer(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        if text == "正" { return 1 }
        if text == "冬" { return 11 }
        if text == "腊" { return 12 }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let expanded = text.replacingOccurrences(of: "廿", with: "二十").replacingOccurrences(of: "卅", with: "三十")
        if let ten = expanded.firstIndex(of: "十") {
            let left = String(expanded[..<ten])
            let right = String(expanded[expanded.index(after: ten)...])
            guard left.count <= 1, right.count <= 1 else { return nil }
            let tens = left.isEmpty ? 1 : left.first.flatMap { digits[$0] }
            let units = right.isEmpty ? 0 : right.first.flatMap { digits[$0] }
            guard let tens, let units else { return nil }
            return tens * 10 + units
        }
        var result = 0
        for char in expanded {
            guard let digit = digits[char] else { return nil }
            result = result * 10 + digit
        }
        return expanded.isEmpty ? nil : result
    }

    private static func capture(_ pattern: String, text: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
