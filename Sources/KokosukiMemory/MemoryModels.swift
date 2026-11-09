import Foundation

public enum MemoryKind: String, Codable, CaseIterable, Sendable {
    case profile, preference, habit, plan, concern

    public var title: String {
        switch self {
        case .profile: return "主人资料"
        case .preference: return "喜好"
        case .habit: return "相处习惯"
        case .plan: return "牵挂的事"
        case .concern: return "最近的心情"
        }
    }
}

public enum MemoryOrigin: String, Codable, Sendable {
    case ownerStatement, previousChat, initialPersona
    public var title: String {
        switch self {
        case .ownerStatement: return "主人原话"
        case .previousChat: return "历史聊天中的主人原话"
        case .initialPersona: return "原有人设中的主人资料"
        }
    }
}

public struct MemoryFact: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var key: String
    public var kind: MemoryKind
    public var text: String
    public var evidence: String
    public var origin: MemoryOrigin
    public var observedAt: Date
    public var lastConfirmedAt: Date
    public var confirmations: Int
    public var importance: Double
    public var expiresAt: Date?
    public var supersedes: UUID?
    public var supersededAt: Date?

    public func isActive(at date: Date) -> Bool {
        supersededAt == nil && (expiresAt == nil || expiresAt! > date)
    }
}

public enum PetInteraction: String, Codable, CaseIterable, Sendable {
    case petted, fedFish, fedCookie, hardFall, climbedWindow, wokenByOwner
    case pokedALot, playedYarn, fellAsleep, wokeUp, cameWhenCalled, conversation

    public var description: String {
        switch self {
        case .petted: return "主人温柔地摸了我的头"
        case .fedFish: return "主人给我喂了小鱼干"
        case .fedCookie: return "主人给我喂了小饼干"
        case .hardFall: return "我摔了一个大跟头"
        case .climbedWindow: return "我成功跳上了应用窗口"
        case .wokenByOwner: return "主人把我叫醒了"
        case .pokedALot: return "主人连续戳了我好多下"
        case .playedYarn: return "我和主人玩了毛线球"
        case .fellAsleep: return "我安心地睡着了"
        case .wokeUp: return "我睡醒了"
        case .cameWhenCalled: return "主人叫我，我跑到了身边"
        case .conversation: return "我和主人聊了一会儿天"
        }
    }

    public var isCare: Bool { [.petted, .fedFish, .fedCookie, .playedYarn, .conversation].contains(self) }
    public var emotionalWeight: Double {
        switch self {
        case .hardFall: return 0.85
        case .petted, .fedFish, .playedYarn: return 0.8
        case .fedCookie, .cameWhenCalled: return 0.65
        default: return 0.4
        }
    }
}

public struct PetExperience: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: PetInteraction
    public var day: String
    public var firstAt: Date
    public var lastAt: Date
    public var count: Int
}

public struct MemoryTendencies: Equatable, Sendable {
    public var familiarity: Double
    public var companionDays: Int
    public var prefersQuiet: Bool
    public var avoidsWindows: Bool
    public var cautiousWhenHeld: Bool

    public static let neutral = MemoryTendencies(
        familiarity: 0, companionDays: 0, prefersQuiet: false, avoidsWindows: false, cautiousWhenHeld: false)

    public var bondDescription: String {
        switch familiarity {
        case ..<0.2: return "还在慢慢熟悉主人，好奇又有一点点害羞"
        case ..<0.5: return "已经熟悉主人的照顾，在主人身边很安心"
        default: return "和主人很亲近，愿意主动靠近、撒娇，但也会自己玩耍"
        }
    }
}

/// 摘录必须能在主人本轮原话中逐字找到；宠物自己的话不能成为主人的事实。
public struct MemoryCandidate: Codable, Equatable, Sendable {
    public var kind: MemoryKind
    public var key: String
    public var text: String
    public var evidence: String

    public init(kind: MemoryKind, key: String, text: String, evidence: String) {
        self.kind = kind; self.key = key; self.text = text; self.evidence = evidence
    }
}

public enum MemoryCommand: Equatable {
    case forgetAll, forget(String)
}

public enum MemoryStoreError: LocalizedError {
    case unsupportedVersion, invalidData
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "记忆文件来自更新版本，暂时没有覆盖它。"
        case .invalidData: return "记忆文件无法读取，原文件仍保留。请先备份或在小本本中重试读取。"
        }
    }
}
