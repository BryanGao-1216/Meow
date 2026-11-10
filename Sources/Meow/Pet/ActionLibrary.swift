import Foundation

/// 动作的单一目录：中文说法、模型协议、动画时长、主动执行权限集中维护。
enum ActionLibrary {
    struct Entry {
        let action: PetAction
        let name: String
        let example: String
        let phrases: [String]
        var aliases: [String] = []
        var pose: Activity? = nil
        var duration: TimeInterval = 0
        var maySuggest = false
        var leavesWall = false
        var cooldown: TimeInterval = 12
        var idleWeight: Double = 0
        var minimumEnergy: Double = 15
        var minimumHappiness: Double = 0
        var maximumHappiness: Double = 100
        var ownerNearbyOnly = false
    }

    static let entries: [Entry] = [
        Entry(action: .dance, name: "跳舞", example: "跳个舞给我看", phrases: ["跳舞", "跳支舞", "跳个舞", "跳一支舞"],
              pose: .dance, duration: 4.2, maySuggest: true, leavesWall: true, idleWeight: 0.5, minimumEnergy: 50, minimumHappiness: 80),
        Entry(action: .spin, name: "转圈", example: "转个圈看看", phrases: ["转圈", "转个圈", "转一圈", "转个身"],
              pose: .spinPose, duration: 1.4, maySuggest: true, leavesWall: true, idleWeight: 0.5, minimumEnergy: 40, minimumHappiness: 75),
        Entry(action: .roll, name: "打滚", example: "Meow，打个滚", phrases: ["打滚", "打个滚", "打一个滚", "滚一圈", "翻个滚", "翻滚", "翻肚皮", "翻一下肚皮", "翻个肚皮", "露出小肚皮"],
              pose: .rollPose, duration: 2.6, maySuggest: true, leavesWall: true, idleWeight: 1.6, minimumEnergy: 45, minimumHappiness: 70),
        Entry(action: .wave, name: "招手", example: "挥挥爪子打个招呼", phrases: ["招手", "挥手", "挥挥手", "挥爪", "挥挥爪", "挥一下爪", "挥个爪"],
              pose: .wave, duration: 2.4, maySuggest: true, leavesWall: true, idleWeight: 0.5, minimumEnergy: 25, minimumHappiness: 60, ownerNearbyOnly: true),
        Entry(action: .nod, name: "点头", example: "点点头", phrases: ["点头", "点点头", "点个头"],
              pose: .nod, duration: 1.8, maySuggest: true, leavesWall: true, idleWeight: 0.2, minimumEnergy: 20, minimumHappiness: 45, ownerNearbyOnly: true),
        Entry(action: .shakeHead, name: "摇头", example: "摇摇头看看", phrases: ["摇头", "摇摇头", "摇个头"],
              pose: .shakeHead, duration: 1.8, maySuggest: true, leavesWall: true, idleWeight: 0.35, maximumHappiness: 35, ownerNearbyOnly: true),
        Entry(action: .jump, name: "跳跃", example: "跳一下试试", phrases: ["跳一下", "跳一跳", "跳起来", "跳个高", "跳高", "蹦一", "跳跃"],
              aliases: ["跳"], maySuggest: true, leavesWall: true, idleWeight: 0.4, minimumEnergy: 50, minimumHappiness: 75),
        Entry(action: .stretch, name: "伸懒腰", example: "伸个懒腰吧", phrases: ["伸懒腰", "伸个懒腰", "伸伸懒腰", "拉伸"],
              pose: .stretchPose, duration: 2.2, maySuggest: true, leavesWall: true, idleWeight: 1.8, minimumEnergy: 0),
        Entry(action: .come, name: "过来", example: "快过来这边", phrases: ["过来", "来这", "来我这", "到这来"], leavesWall: true),
        Entry(action: .walk, name: "散步", example: "去散散步吧", phrases: ["散步", "散个步", "散散步", "走走", "溜达"], leavesWall: true),
        Entry(action: .climb, name: "跳上窗口", example: "跳到窗口上去", phrases: ["跳上窗", "跳到窗", "爬上窗", "上窗口", "窗口上", "跳上去", "爬上去", "上去"],
              aliases: ["爬窗", "上窗"], leavesWall: true),
        Entry(action: .down, name: "回到地面", example: "下来陪我", phrases: ["下来", "下去", "跳下", "回地面", "回地上"], aliases: ["下来"], leavesWall: true),
        Entry(action: .play, name: "玩毛线球", example: "陪我玩一会", phrases: ["玩毛线", "玩球", "玩会", "玩一会", "陪我玩", "一起玩"],
              aliases: ["玩"], duration: 6.5, leavesWall: true),
        Entry(action: .eat, name: "吃小鱼干", example: "吃点小鱼干吧", phrases: ["吃鱼", "吃小鱼", "吃点小鱼", "吃点东西", "吃饭", "吃零食", "开饭"], aliases: ["吃"], duration: 3.2),
        Entry(action: .sleep, name: "睡觉", example: "去睡觉吧", phrases: ["睡觉", "去睡", "睡吧", "午睡", "睡一会", "小睡"]),
        Entry(action: .wake, name: "起床", example: "别睡了，起床啦", phrases: ["别睡", "不要睡了", "醒醒", "醒一醒", "起床", "快醒", "睡够", "醒来"], aliases: ["醒来"]),
        Entry(action: .stop, name: "停下", example: "停下来，别动", phrases: ["停下", "停止", "站住", "别动", "别闹", "别跳", "别转"], aliases: ["停"]),
    ]

    static func entry(_ action: PetAction) -> Entry {
        // 每个枚举值都必须注册；自检覆盖完整性，遗漏会在开发时直接暴露。
        entries.first { $0.action == action }!
    }

    static func fromTag(_ raw: String) -> PetAction? {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.first { $0.action.rawValue.lowercased() == tag || $0.name == tag || $0.aliases.contains(tag) }?.action
    }

    struct Intent {
        var requested: PetAction?
        var suppressSuggestion = false
    }

    /// 只执行当前对 Meow 的要求。故事、引用、假设、知识问题和主人自己的动作不当成命令。
    static func interpret(_ text: String) -> Intent {
        let cleaned = text.replacingOccurrences(of: "[“「『\"].*?[”」』\"]", with: "", options: .regularExpression)
        let clauses = cleaned.components(separatedBy: CharacterSet(charactersIn: "，。！？,!?；;\n"))
        var requested: PetAction?
        var suppressed = cleaned != text
        var negative = false
        var deferredContext = false
        for raw in clauses {
            let clause = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clause.isEmpty else { continue }
            let deferred = ["如果", "假如", "要是", "等会", "待会", "以后", "明天", "下次", "等我", "等到"]
            if deferred.contains(where: clause.contains) {
                deferredContext = true
                suppressed = true
                continue
            }
            if deferredContext {
                guard ["现在", "立刻", "就现在"].contains(where: clause.contains) else { continue }
                deferredContext = false
            }
            let report = ["为什么", "怎么", "如何", "什么意思", "是什么", "故事", "小说", "视频", "看到", "看见", "梦见", "我今天", "我刚", "我的猫", "那只猫", "它在", "他在", "她在", "我去", "我要去", "我想去", "我喜欢", "我不喜欢", "你喜欢", "你爱", "喜不喜欢", "爱不爱", "正在", "刚才", "刚刚", "昨天", "平时", "通常"]
            if report.contains(where: clause.contains) {
                suppressed = true
                continue
            }
            var matches: [(action: PetAction, range: Range<String.Index>)] = []
            for entry in entries {
                for phrase in entry.phrases {
                    if let range = clause.range(of: phrase) { matches.append((entry.action, range)) }
                }
            }
            // 同一位置优先更具体的说法，例如“跳个舞”先于“跳个”。
            matches.sort {
                $0.range.lowerBound == $1.range.lowerBound
                    ? clause.distance(from: $0.range.lowerBound, to: $0.range.upperBound) > clause.distance(from: $1.range.lowerBound, to: $1.range.upperBound)
                    : $0.range.lowerBound < $1.range.lowerBound
            }
            guard let match = matches.first else { continue }
            let prefix = String(clause[..<match.range.lowerBound])
            let requestMarkers = ["你", "给我", "请", "让我看", "表演", "来个", "来一", "快", "去", "先", "再", "Meow", "喵喵", "能不能", "可以", "帮我", "麻烦", "试着", "现在"]
            if ["我", "他", "她", "它", "猫", "小狗"].contains(where: prefix.hasPrefix),
               !["你", "给我", "让我看"].contains(where: prefix.contains) {
                suppressed = true
                continue
            }
            let negations = ["不要", "别", "不许", "不用", "不准", "不能", "先不", "暂时不", "不需要", "不想", "别再"]
            let negativePrefix = prefix.replacingOccurrences(of: "能不能", with: "").replacingOccurrences(of: "可不可以", with: "")
            let isNegative = negations.contains(where: negativePrefix.contains)
            if !prefix.isEmpty, !isNegative, !requestMarkers.contains(where: { prefix.localizedCaseInsensitiveContains($0) }) {
                suppressed = true
                continue
            }
            // “不要打滚”里的否定前缀本身也是一种明确要求。
            if isNegative {
                negative = true
                suppressed = true
                continue
            }
            // 禁止当前动作的短句只作为停止意图，不盖过后面的正向指令。
            if match.action == .stop, ["别动", "别闹", "别跳", "别转"].contains(where: clause.hasPrefix) {
                negative = true
                suppressed = true
                continue
            }
            if requested == nil { requested = match.action }
        }
        // 直接禁止一个动作时，先让当前动作停下；允许同句另一个正向指令。
        return Intent(requested: requested ?? (negative ? .stop : nil), suppressSuggestion: suppressed)
    }

    static func select(intent: Intent, proposed: PetAction?, suppressAll: Bool = false) -> PetAction? {
        guard !suppressAll else { return nil }
        if let action = intent.requested { return action }
        guard !intent.suppressSuggestion, let proposed, entry(proposed).maySuggest else { return nil }
        return proposed
    }

    static func hint(for action: PetAction) -> String {
        "(主人要求你\(entry(action).name)。应用会执行这个动作，用一句中文自然回应，不要再要求主人输入标签。)"
    }

    static func canHandleOffline(_ text: String) -> Bool {
        Persona.detectGoodnight(text) || (Persona.detectCreative(text) == nil && interpret(text).requested != nil)
    }

    struct IdleState {
        var stats: PetStats
        var ownerNearby: Bool
        var prefersQuiet: Bool
        var onPlatform = false
        var wallAttached = false
        var sleeping = false
        var busy = false
    }

    /// 空闲活动无需调用模型。用状态筛选后按权重选择，开心时打滚，累时多伸懒腰。
    static func autonomousCandidates(_ state: IdleState) -> [(action: PetAction, weight: Double)] {
        guard !state.wallAttached, !state.sleeping, !state.busy else { return [] }
        return entries.compactMap { entry in
            guard entry.idleWeight > 0, state.stats.energy >= entry.minimumEnergy,
                  state.stats.happiness >= entry.minimumHappiness, state.stats.happiness <= entry.maximumHappiness,
                  !entry.ownerNearbyOnly || state.ownerNearby,
                  !(state.stats.fullness < 22 && entry.minimumEnergy >= 40),
                  !(state.onPlatform && [.roll, .spin, .jump].contains(entry.action)) else { return nil }
            var weight = entry.idleWeight
            if state.prefersQuiet && entry.action != .stretch { weight *= 0.15 }
            if state.stats.energy < 35 && entry.action == .stretch { weight *= 2 }
            return (entry.action, weight)
        }
    }

    static func chooseAutonomous(_ state: IdleState, unitRoll: Double) -> PetAction? {
        let candidates = autonomousCandidates(state)
        let total = candidates.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var cursor = min(max(0, unitRoll), 0.999999) * total
        for candidate in candidates {
            cursor -= candidate.weight
            if cursor < 0 { return candidate.action }
        }
        return candidates.last?.action
    }

    static var modelInstructions: String {
        let catalog = entries.map { "[\($0.action.rawValue)] \($0.name)" }.joined(separator: "；")
        let optional = entries.filter(\.maySuggest).map { "[\($0.action.rawValue)]" }.joined(separator: " ")
        return """
        动作库：\(catalog)。每次回复最多选一个动作，在中文回复句尾附上对应标签，也可以不选；不要在正文展示或解释标签，不要编造库外动作。
        明确指令优先。否定、引用、故事、假设或知识问题不要触发动作。一般聊天可以按心情、精力和语境自然地选一个小动作（\(optional)），例如打招呼时挥爪、赞同时点头、撒娇时打滚，累时做轻动作，不必每轮都动。
        吃东西、睡觉、醒来、走动和跳窗只在主人明确要求时使用。正在贴墙时不主动离墙；拖拽、空中、其他动作未结束时先等待。
        """
    }
}
