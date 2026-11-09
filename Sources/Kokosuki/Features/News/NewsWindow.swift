import AppKit
import SwiftUI
import KokosukiNews

struct NewsView: View {
    @ObservedObject var news: HotNewsController
    @ObservedObject var settings: AppSettings
    var loadsCredentials = true
    @State private var cookie = ""
    @State private var credentialStatus = ""
    private let cocoa = Color(red: 0.36, green: 0.27, blue: 0.21)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(AppIdentity.name)的热点小报").font(.title3.bold())
                Spacer()
                if news.isBusy { ProgressView().controlSize(.small) }
                Button("现在找一条") { news.fetchNow() }
                    .disabled(news.isBusy || news.hasPending || !settings.newsEnabled || news.storageError != nil)
            }
            Toggle("定时分享热点", isOn: $settings.newsEnabled)
            Text("北京时间 11:00 · 16:00 · 19:00，每次最多一条。下次：\(NewsSchedule.display(news.nextDate))")
                .font(.caption).foregroundStyle(.secondary)
            Text(news.status).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let error = news.storageError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("重试读取") { news.reloadStorage(); news.checkSchedule() }
                }
            }
            DisclosureGroup("微博登录凭据（可选）") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("默认直接读取公开热榜。若微博要求登录，可粘贴你已登录微博的完整 Cookie；仅保存到本机钥匙串，供微博请求使用。")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("完整 Cookie 字符串", text: $cookie).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("保存登录凭据") {
                            do { try WeiboCookieStore.save(cookie); credentialStatus = cookie.isEmpty ? "已移除登录凭据" : "已保存，可点击‘现在找一条’验证" }
                            catch { credentialStatus = error.localizedDescription }
                        }
                        Link("打开微博登录", destination: URL(string: "https://weibo.com/")!)
                    }.controlSize(.small)
                    if !credentialStatus.isEmpty { Text(credentialStatus).font(.caption).textSelection(.enabled) }
                }.padding(.top, 6)
            }.font(.callout)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let pending = news.state.pending {
                        bulletin(pending, waiting: true)
                    }
                    if news.state.bulletins.isEmpty, news.state.pending == nil {
                        Text("还没有热点小报。你可以先告诉小喵‘我关注人工智能’、‘我不喜欢娱乐八卦’，再找一条试试。")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 28)
                    }
                    ForEach(news.state.bulletins.reversed()) { item in bulletin(item, waiting: false) }
                }.padding(.vertical, 4)
            }
            Divider()
            Text("需保持小喵运行和网络连接。休眠恢复只补一小时内最近一期；忙碌或睡觉时等空闲再讲，过时就跳过。云端选题与写稿复用当前模型，每轮最多两次额外请求；没有详情时只分享热搜题目。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).padding(.top, 18).frame(width: 560, height: 700)
        .foregroundStyle(cocoa).background(Color(red: 1, green: 0.975, blue: 0.94))
        .onAppear {
            guard loadsCredentials else { return }
            do { cookie = try WeiboCookieStore.load() }
            catch { credentialStatus = error.localizedDescription }
        }
    }

    private func bulletin(_ item: NewsBulletin, waiting: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(item.topic.title).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                Spacer()
                Link("微博 ↗", destination: item.topic.sourceURL).font(.caption)
            }
            Text("\(waiting ? "等待分享 · " : "")\(item.topic.category.isEmpty ? "热搜话题" : item.topic.category) · 抓取于 \(NewsSchedule.display(item.topic.fetchedAt))（北京时间）")
                .font(.caption).foregroundStyle(.secondary)
            Text(item.line).font(.callout).textSelection(.enabled)
            if !item.excerpts.isEmpty {
                DisclosureGroup("查看微博摘录与来源") {
                    ForEach(Array(item.excerpts.enumerated()), id: \.offset) { _, excerpt in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(excerpt.text).font(.caption).textSelection(.enabled)
                            Link("查看这条微博 ↗", destination: excerpt.sourceURL).font(.caption)
                        }.padding(.vertical, 5)
                    }
                }.font(.caption)
            }
            if let note = item.detailNote, !note.isEmpty {
                Text(note).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
final class NewsWindowController {
    private let panel: NSPanel
    init(news: HotNewsController, loadsCredentials: Bool = true) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                        styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: false)
        panel.title = "\(AppIdentity.name)的热点小报"
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .aqua)
        panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: NewsView(news: news, settings: .shared, loadsCredentials: loadsCredentials))
    }
    func show(activate: Bool = true) {
        panel.center()
        if activate { NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFront(nil) }
    }
}
