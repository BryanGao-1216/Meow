import Foundation
import Combine
import KokosukiCloud

enum BrainProvider: String, CaseIterable, Identifiable {
    case local, volcengine
    var id: String { rawValue }

    static var defaultProvider: BrainProvider {
        #if canImport(MLXLLM)
        return .local
        #else
        return .volcengine
        #endif
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var brainProvider: BrainProvider {
        didSet { UserDefaults.standard.set(brainProvider.rawValue, forKey: "brainProvider") }
    }
    @Published var cloudBaseURL: String {
        didSet { UserDefaults.standard.set(cloudBaseURL, forKey: "cloudBaseURL") }
    }
    @Published var cloudModel: String {
        didSet { UserDefaults.standard.set(cloudModel, forKey: "cloudModel") }
    }

    @Published var petScale: Double {   // 0.5 mini, 0.8 small, 1.0 medium, 1.3 large
        didSet { UserDefaults.standard.set(petScale, forKey: "petScale") }
    }
    @Published var chatterEnabled: Bool {
        didSet { UserDefaults.standard.set(chatterEnabled, forKey: "chatterEnabled") }
    }
    @Published var chatterFreq: Double {  // mean minutes between spontaneous lines
        didSet { UserDefaults.standard.set(chatterFreq, forKey: "chatterFreq") }
    }
    @Published var autoSleep: Bool {
        didSet { UserDefaults.standard.set(autoSleep, forKey: "autoSleep") }
    }
    @Published var windowParkour: Bool {
        didSet { UserDefaults.standard.set(windowParkour, forKey: "windowParkour") }
    }
    @Published var thinkingEnabled: Bool {
        didSet { UserDefaults.standard.set(thinkingEnabled, forKey: "thinkingEnabled") }
    }
    @Published var memoryEnabled: Bool {
        didSet { UserDefaults.standard.set(memoryEnabled, forKey: "memoryEnabled") }
    }
    @Published var memoryAIEnabled: Bool {
        didSet { UserDefaults.standard.set(memoryAIEnabled, forKey: "memoryAIEnabled") }
    }
    @Published var newsEnabled: Bool {
        didSet { UserDefaults.standard.set(newsEnabled, forKey: "newsEnabled") }
    }

    private init() {
        let d = UserDefaults.standard
        brainProvider = d.string(forKey: "brainProvider").flatMap(BrainProvider.init(rawValue:)) ?? .defaultProvider
        #if !canImport(MLXLLM)
        brainProvider = .volcengine
        #endif
        cloudBaseURL = d.string(forKey: "cloudBaseURL") ?? ArkConfiguration.agentPlanBaseURL
        cloudModel = d.string(forKey: "cloudModel") ?? ArkConfiguration.defaultModel
        petScale = d.object(forKey: "petScale") as? Double ?? 1.0
        chatterEnabled = d.object(forKey: "chatterEnabled") as? Bool ?? true
        chatterFreq = d.object(forKey: "chatterFreq") as? Double ?? 6
        autoSleep = d.object(forKey: "autoSleep") as? Bool ?? true
        windowParkour = d.object(forKey: "windowParkour") as? Bool ?? true
        thinkingEnabled = d.object(forKey: "thinkingEnabled") as? Bool ?? false
        memoryEnabled = d.object(forKey: "memoryEnabled") as? Bool ?? true
        memoryAIEnabled = d.object(forKey: "memoryAIEnabled") as? Bool ?? true
        newsEnabled = d.object(forKey: "newsEnabled") as? Bool ?? true
    }
}
