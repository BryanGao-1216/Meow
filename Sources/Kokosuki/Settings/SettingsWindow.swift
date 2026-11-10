import AppKit
import SwiftUI
import KokosukiCloud

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var onResetStats: () -> Void
    var onApplyBrainSettings: () -> Void
    var onOpenMemory: () -> Void
    var onOpenNews: () -> Void
    @State private var confirmingReset = false
    @State private var provider: BrainProvider
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKey = ""
    @State private var connectionStatus = ""
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var credentialReadFailed = false

    init(settings: AppSettings, onResetStats: @escaping () -> Void,
         onApplyBrainSettings: @escaping () -> Void, onOpenMemory: @escaping () -> Void = {},
         onOpenNews: @escaping () -> Void = {}) {
        self.settings = settings
        self.onResetStats = onResetStats
        self.onApplyBrainSettings = onApplyBrainSettings
        self.onOpenMemory = onOpenMemory
        self.onOpenNews = onOpenNews
        _provider = State(initialValue: settings.brainProvider)
        _baseURL = State(initialValue: settings.cloudBaseURL)
        _model = State(initialValue: settings.cloudModel)
    }

    private let cocoa = Color(red: 0.36, green: 0.27, blue: 0.21)

    /// One symmetric row: label on the left, control right-aligned.
    private func settingRow<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .foregroundStyle(cocoa)
                .font(.system(size: 12.5))
                .lineLimit(2)
            Spacer(minLength: 12)
            control()
        }
        .frame(minHeight: 34)
    }

    var body: some View {
        ScrollView { settingsContent }
            .frame(width: 410, height: 660)
            .onAppear { loadCredential() }
            .onDisappear { testTask?.cancel() }
    }

    // ImageRenderer cannot capture AppKit-backed scroll views; expose the
    // content for the existing offscreen settings snapshot utility.
    var settingsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t("settings.title"))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(cocoa)
                .padding(.bottom, 14)

            brainSettings
            Divider().padding(.vertical, 10)

            settingRow("记住主人与共同经历") {
                Toggle("", isOn: $settings.memoryEnabled).labelsHidden()
                    .toggleStyle(.switch).controlSize(.small)
            }
            settingRow("云端整理记忆") {
                Toggle("", isOn: $settings.memoryAIEnabled).labelsHidden()
                    .toggleStyle(.switch).controlSize(.small).disabled(!settings.memoryEnabled)
            }
            Text("基础记忆在本机完成。开启云端整理后，有记忆价值的聊天会在回复后额外调用一次当前云端模型，消耗套餐额度，并发送这轮原话和少量已有记忆。关闭后仍能记住明确的称呼、喜好和互动。")
                .font(.system(size: 10.5)).foregroundStyle(cocoa.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 5)
            Button("打开小本本…", action: onOpenMemory).controlSize(.small)
            Divider().padding(.vertical, 10)

            settingRow("定时分享热点") {
                Toggle("", isOn: $settings.newsEnabled).labelsHidden()
                    .toggleStyle(.switch).controlSize(.small)
            }
            Text("北京时间每天 11:00、16:00、19:00，按记忆中的偏好挑一条，等空闲时讲给你听。需保持小喵运行；云端选题和写稿会额外消耗模型额度。")
                .font(.system(size: 10.5)).foregroundStyle(cocoa.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 5)
            Button("打开热点小报…", action: onOpenNews).controlSize(.small)
            Divider().padding(.vertical, 10)

            settingRow(L10n.t("settings.size")) {
                Picker("", selection: $settings.petScale) {
                    Text(L10n.t("settings.size.mini")).tag(0.5)
                    Text(L10n.t("settings.size.small")).tag(0.8)
                    Text(L10n.t("settings.size.medium")).tag(1.0)
                    Text(L10n.t("settings.size.large")).tag(1.3)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 230)
            }
            Text("拖到屏幕左右边缘后松手，小喵会贴墙，只露出耳朵和眼睛上半张脸。鼠标移开后再靠近，它会弹出身子打招呼，移开后缩回。拖回桌面或点‘过来这边’即可恢复活动。")
                .font(.system(size: 10.5)).foregroundStyle(cocoa.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 5)
            settingRow(L10n.t("settings.chatter")) {
                Toggle("", isOn: $settings.chatterEnabled).labelsHidden()
                    .toggleStyle(.switch).controlSize(.small)
            }
            if settings.chatterEnabled {
                settingRow(L10n.t("settings.chatterFreq")) {
                    Picker("", selection: $settings.chatterFreq) {
                        Text(L10n.t("settings.freq.low")).tag(12.0)
                        Text(L10n.t("settings.freq.mid")).tag(6.0)
                        Text(L10n.t("settings.freq.high")).tag(3.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }
            }
            settingRow(L10n.t("settings.autoSleep")) {
                Toggle("", isOn: $settings.autoSleep).labelsHidden()
                    .toggleStyle(.switch).controlSize(.small)
            }
            settingRow(L10n.t("settings.parkour")) {
                Toggle("", isOn: $settings.windowParkour).labelsHidden()
                    .toggleStyle(.switch).controlSize(.small)
            }
            settingRow(L10n.t("settings.thinking")) {
                Toggle("", isOn: $settings.thinkingEnabled).labelsHidden()
                    .toggleStyle(.switch).controlSize(.small)
            }

            Divider().padding(.vertical, 10)

            HStack {
                if confirmingReset {
                    Button(role: .destructive) {
                        onResetStats()
                        confirmingReset = false
                    } label: {
                        Text(L10n.t("settings.resetStats") + " ✓")
                    }
                    .controlSize(.small)
                } else {
                    Button { confirmingReset = true } label: {
                        Text(L10n.t("settings.resetStats"))
                    }
                    .controlSize(.small)
                }
                Spacer()
            }

            Text(L10n.t("settings.about"))
                .font(.system(size: 10.5))
                .foregroundStyle(cocoa.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .padding(.top, 30)      // clear the overlaid titlebar close button
        .frame(width: 410)
        .background(Color(red: 1.0, green: 0.975, blue: 0.94))
    }

    private var brainSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingRow(L10n.t("settings.brainProvider")) {
                Picker("", selection: $provider) {
                    #if canImport(MLXLLM)
                    Text(L10n.t("settings.localModel")).tag(BrainProvider.local)
                    #endif
                    Text(L10n.t("settings.volcengine")).tag(BrainProvider.volcengine)
                }
                .labelsHidden().frame(width: 215)
            }
            .disabled(testing)
            if provider == .volcengine {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Base URL").font(.system(size: 11))
                    TextField(ArkConfiguration.agentPlanBaseURL, text: $baseURL)
                    Text(L10n.t("settings.modelName")).font(.system(size: 11))
                    TextField(ArkConfiguration.defaultModel, text: $model)
                    Text("API Key").font(.system(size: 11))
                    SecureField(L10n.t("settings.keyPlaceholder"), text: $apiKey)
                }
                .textFieldStyle(.roundedBorder)
                .disabled(testing)
                HStack {
                    Link(L10n.t("settings.agentPlanConsole"), destination: URL(string:
                        "https://console.volcengine.com/ark/region:cn-beijing/subscription/agent-plan")!)
                    Spacer()
                    Button(L10n.t("settings.testConnection")) { testConnection() }
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                }
                .font(.system(size: 11))
                Text(L10n.t("settings.cloudNotice"))
                    .font(.system(size: 10.5)).foregroundStyle(cocoa.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(L10n.t("settings.applyBrain")) { applyBrainSettings() }
                .disabled(testing)
            if !connectionStatus.isEmpty {
                Text(connectionStatus).font(.system(size: 11))
                    .foregroundStyle(cocoa).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if credentialReadFailed {
                Button("重新授权钥匙串") { loadCredential(retry: true) }
                    .controlSize(.small).disabled(testing)
                Text("取消后不会自动重试。授权窗口中输入 Mac 登录密码并选择‘始终允许’，可让当前版本记住授权；也可重新填写密钥后保存。")
                    .font(.system(size: 10.5)).foregroundStyle(cocoa.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func loadCredential(retry: Bool = false) {
        do {
            apiKey = try APIKeyStore.load(retry: retry)
            credentialReadFailed = false
            if retry { connectionStatus = "已读取密钥，请测试连接并保存模型设置。" }
        } catch {
            credentialReadFailed = true
            connectionStatus = error.localizedDescription
        }
    }

    private func configuration() -> ArkConfiguration {
        ArkConfiguration(baseURL: baseURL, model: model, apiKey: apiKey)
    }

    private func applyBrainSettings() {
        do {
            if provider == .volcengine {
                _ = try configuration().endpoint()
                try APIKeyStore.save(apiKey)
                credentialReadFailed = false
            }
            settings.cloudBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.cloudModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.brainProvider = provider
            onApplyBrainSettings()
            connectionStatus = L10n.t("settings.brainSaved")
        } catch {
            connectionStatus = error.localizedDescription
        }
    }

    private func testConnection() {
        let config = configuration()
        testing = true
        connectionStatus = L10n.t("settings.testingConnection")
        testTask = Task { @MainActor in
            defer { testing = false }
            do {
                _ = try await ArkClient(configuration: config).generate(
                    messages: [ArkMessage(role: "user", content: "请只回复：你好。")],
                    thinking: false, maxTokens: 64, onText: { _ in })
                try Task.checkCancellation()
                connectionStatus = L10n.t("settings.connectionOK")
            } catch {
                if !Task.isCancelled { connectionStatus = error.localizedDescription }
            }
        }
    }
}

@MainActor
final class SettingsWindowController {
    let panel: NSPanel
    private var hosting: NSHostingView<SettingsView>?
    private let onResetStats: () -> Void
    private let onApplyBrainSettings: () -> Void
    private let onOpenMemory: () -> Void
    private let onOpenNews: () -> Void

    init(onResetStats: @escaping () -> Void, onApplyBrainSettings: @escaping () -> Void,
         onOpenMemory: @escaping () -> Void = {}, onOpenNews: @escaping () -> Void = {}) {
        self.onResetStats = onResetStats
        self.onApplyBrainSettings = onApplyBrainSettings
        self.onOpenMemory = onOpenMemory
        self.onOpenNews = onOpenNews
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 340),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .aqua)  // light-designed UI
        panel.title = "\(AppIdentity.appName) · 设置"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.975, blue: 0.94, alpha: 1)
        rebuild()
    }

    func rebuild() {
        let view = SettingsView(settings: AppSettings.shared, onResetStats: onResetStats,
                                onApplyBrainSettings: onApplyBrainSettings, onOpenMemory: onOpenMemory, onOpenNews: onOpenNews)
        if let hosting {
            hosting.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            panel.contentView = host
            hosting = host
        }
        panel.setContentSize(hosting!.fittingSize)
    }

    func show() {
        rebuild()
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}
