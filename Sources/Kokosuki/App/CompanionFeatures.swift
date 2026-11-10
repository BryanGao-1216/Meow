import Foundation
import KokosukiNews
import KokosukiMemos
import KokosukiMailbox
import KokosukiIroh

/// 有后台生命周期的功能统一接入这里，AppDelegate 不再逐个实现调度和依赖。
@MainActor
protocol CompanionFeature: AnyObject {
    func start()
    func checkSchedule()
    func configurationChanged()
    func shutdown()
}
extension HotNewsController: CompanionFeature {
    func configurationChanged() { settingsChanged() }
}
extension MemoController: CompanionFeature {}
extension MailboxController: CompanionFeature {}

@MainActor
final class CompanionFeatures {
    let news: HotNewsController
    let memos: MemoController
    let mailbox: MailboxController
    private var services: [any CompanionFeature] { [mailbox, memos, news] }
    private lazy var newsWindow = NewsWindowController(news: news)
    private lazy var memoWindow = MemoWindowController(memos: memos)
    private lazy var mailboxWindow = MailboxWindowController(mailbox: mailbox)

    init(brain: Brain, engine: PetEngine) {
        news = HotNewsController(dependencies: NewsDependencies(
            fetchTopics: { cookie, date in try await WeiboClient().fetchTopics(cookie: cookie, at: date) },
            fetchExcerpts: { topic, cookie in try await WeiboClient().fetchExcerpts(for: topic, cookie: cookie) },
            complete: { [weak brain] system, input in try await brain?.newsCompletion(system: system, input: input) },
            cookie: { try WeiboCookieStore.load() },
            taste: { [weak brain] in NewsTaste(statements: brain?.memory.newsPreferenceStatements ?? []) },
            deliver: { [weak engine] item in engine?.shareNews(item) ?? false },
            persona: { [weak engine] in
                guard let engine else { return "你是高小喵，用简短中文和主人分享微博话题。" }
                return Persona.system(engine.currentContext()) + "\n本次有工具提供的微博资料，可以据此分享；仍需区分热搜讨论与已核实的事实。"
            }))
        memos = MemoController(dependencies: MemoDependencies(
            complete: { [weak brain] system, input in try await brain?.featureCompletion(system: system, input: input) },
            canEvaluate: { [weak brain, weak engine] kind in
                brain?.isReady == true && engine?.canReceiveProactive(wakeForAlarm: kind == .due) == true
            },
            deliver: { [weak engine] notice in engine?.speakProactively(notice.text, wakeForAlarm: notice.kind == .due) ?? false },
            persona: { [weak engine] in engine.map { Persona.system($0.currentContext()) } ?? "你是高小喵，用中文提醒主人。" },
            preferences: { [weak brain] in brain?.memory.newsPreferenceStatements ?? [] }))
        mailbox = MailboxController(transport: IrohMailTransport())
        mailbox.onUnreadChange = { [weak engine] count in engine?.updateUnreadLetters(count) }
        mailbox.onNewLetter = { [weak engine] in engine?.receivedLetter() }
        engine.conversationTools = ConversationToolRouter([memos])
        engine.hasPriorityNotice = { [weak memos] in memos?.hasDue == true }
        brain.newsContext = { [weak news] query in news?.followupContext(for: query) ?? "" }
        brain.toolContext = { [weak memos] query in
            guard let memos else { return "" }
            if memos.accepts(query) { return memos.context() }
            return "只有本轮提供已验证的备忘录工具结果时，才能承诺已设置、修改或取消提醒；不能只凭聊天声称已设置。可引导主人说‘明天晚上七点提醒我参加聚会’，或通过菜单‘喵喵备忘录’编辑。"
        }
        brain.memory.onPersonalDataForgotten = { [weak self] in
            self?.news.discardPersonalizedContent()
            self?.memos.discardPersonalizedDrafts()
        }
    }
    func start() { services.forEach { $0.start() } }
    func resume() { services.forEach { $0.checkSchedule() } }
    func configurationChanged() { services.forEach { $0.configurationChanged() } }
    func shutdown() { services.forEach { $0.shutdown() } }
    func showNews() { newsWindow.show() }
    func showMemos() { memoWindow.show() }
    func showMailbox(openUnread: Bool = false) { mailboxWindow.show(openUnread: openUnread) }
}
