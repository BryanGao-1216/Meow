import Foundation

// MARK: - Emotion (drives face + effects; fed by LLM tags and events)

enum Emotion: String, Codable, CaseIterable {
    case neutral, happy, excited, love, shy, sad, sleepy, curious, surprised, angry, hungry, proud, playful, calm

    /// 解析模型协议标签，同时接受中文情绪别名。
    static func fromTag(_ raw: String) -> Emotion? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let e = Emotion(rawValue: s) { return e }
        let synonyms: [String: Emotion] = [
            "开心": .happy,
            "高兴": .happy,
            "兴奋": .excited,
            "激动": .excited,
            "爱心": .love,
            "喜欢": .love,
            "害羞": .shy,
            "难过": .sad,
            "伤心": .sad,
            "困": .sleepy,
            "想睡": .sleepy,
            "好奇": .curious,
            "惊讶": .surprised,
            "吃惊": .surprised,
            "生气": .angry,
            "饿": .hungry,
            "饿了": .hungry,
            "得意": .proud,
            "调皮": .playful,
            "淘气": .playful,
            "平静": .calm,
        ]
        return synonyms[s]
    }
}

// MARK: - Action tags the LLM may emit to trigger behaviors

enum PetAction: String, CaseIterable {
    case dance, spin, roll, wave, nod, shakeHead, jump, stretch, sleep
    case wake, come, walk, climb, down, play, eat, stop

    static func fromTag(_ raw: String) -> PetAction? {
        ActionLibrary.fromTag(raw)
    }
}

// MARK: - Activity (whole-body state machine)

enum Activity: Equatable {
    case idle
    case walk
    case sleep
    case eat(food: String)      // emoji shown while munching
    case drag                   // held by cursor
    case fall                   // airborne after release
    case land                   // squash frames right after touchdown
    case think                  // LLM generating
    case talk                   // bubble streaming/showing
    case stretchPose
    case dance
    case spinPose
    case rollPose
    case wave
    case nod
    case shakeHead
    case jumpPose
    case play                   // yarn ball
    case sulk

    var isBusy: Bool {          // states the autonomy loop must not interrupt
        switch self {
        case .idle, .walk, .sulk: return false
        default: return true
        }
    }
}

// MARK: - Stats

struct PetStats: Codable {
    var fullness: Double = 78    // 0 starving … 100 stuffed
    var energy: Double = 90      // 0 exhausted … 100 fresh
    var happiness: Double = 72   // 0 miserable … 100 blissful
    var lastSaved: Date = .now

    mutating func clamp() {
        fullness = min(100, max(0, fullness))
        energy = min(100, max(0, energy))
        happiness = min(100, max(0, happiness))
    }

    var moodWord: String {       // coarse mood for LLM context
        if happiness >= 75 { return "心情超好" }
        if happiness >= 45 { return "心情不错" }
        if happiness >= 25 { return "有点闹脾气" }
        return "情绪低落"
    }
}

// MARK: - Particles (hearts, zzz, notes, sparkles…)

struct Particle: Identifiable {
    enum Kind { case heart, zzz, note, sparkle, crumb, star, sweat, question, exclamation }
    let id = UUID()
    var kind: Kind
    var x: Double      // canvas-space (200x200 design units), relative to pet center
    var y: Double
    var vx: Double
    var vy: Double
    var age: Double = 0
    var lifetime: Double
    var scale: Double = 1
}

// MARK: - Recent-event memory (feeds the LLM's state awareness)

enum PetEvent {
    case petted, fedFish, fedCookie, hardFall, climbedWindow, wokenByOwner
    case pokedALot, playedYarn, fellAsleep, wokeUp, cameWhenCalled

    /// Pronoun-free renderings: the 1B model sometimes recites context verbatim,
    /// and "你摔了一跤" coming out of the pet's own mouth reads broken — these read
    /// fine in first person even when leaked.
    func render() -> String {
        let descriptions: [PetEvent: String] = [
            .petted: "被主人摸了头", .fedFish: "吃到了主人给的小鱼干", .fedCookie: "吃到了主人给的小饼干",
            .hardFall: "重重摔了一跤", .climbedWindow: "跳上了一个窗口顶",
            .wokenByOwner: "被主人叫醒", .pokedALot: "被主人戳了好多下",
            .playedYarn: "玩了毛线球", .fellAsleep: "睡着了", .wokeUp: "醒来了",
            .cameWhenCalled: "跑到了主人身边",
        ]
        return descriptions[self] ?? ""
    }
}

// MARK: - Context snapshot handed to the LLM

struct PetContext {
    var stats: PetStats
    var activityHint: String     // 当前行为的中文描述
    var timeOfDay: String        // 早上、白天、晚上、深夜
    var clockString: String      // "22:41"
    var recentEvents: [String] = []   // rendered with relative time, newest last
    var companionMinutes: Int = 0     // how long the app has been running this session
}
