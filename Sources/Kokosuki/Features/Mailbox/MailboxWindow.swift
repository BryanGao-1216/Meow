import AppKit
import SwiftUI
import KokosukiMailbox

private func mailDate(_ date: Date) -> String {
    let df = DateFormatter(); df.locale = Locale(identifier: "zh_CN"); df.dateFormat = "M月d日 HH:mm"
    return df.string(from: date)
}

struct MailboxView: View {
    @ObservedObject var mailbox: MailboxController
    @State private var tab = 0
    @State private var binding = false
    @State private var writing = false
    @State private var error = ""
    @State private var deleting: UUID?
    private let cocoa = Color(red: 0.36, green: 0.27, blue: 0.21)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("💌 喵喵信箱").font(.title3.bold())
                Spacer()
                if mailbox.isStarting || mailbox.isSending { ProgressView().controlSize(.small) }
                Text("\(mailbox.book.unreadCount) 封未读").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Toggle("启用通信", isOn: Binding(get: { mailbox.book.enabled }, set: { value in perform { try mailbox.setEnabled(value) } }))
                Spacer()
                Text(mailbox.book.peer?.name ?? "尚未绑定设备").font(.callout).lineLimit(1)
                Button("设备绑定") { binding = true }
            }.font(.callout)
            HStack(alignment: .top) {
                Text(mailbox.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                Spacer()
                if mailbox.book.enabled && !mailbox.isRunning && !mailbox.isStarting {
                    Button("重新连接") { mailbox.reconnect() }.controlSize(.small)
                }
            }
            if let storageError = mailbox.storageError {
                HStack {
                    Text(storageError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Button("重试读取") { mailbox.reloadStorage(); mailbox.checkSchedule() }.controlSize(.small)
                }
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Picker("信件", selection: $tab) {
                    Text("收到的信").tag(0)
                    Text("寄出的信").tag(1)
                }.pickerStyle(.segmented)
                Button("写一封信") { writing = true }.disabled(mailbox.book.peer == nil || mailbox.storageError != nil)
            }
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        if letters.isEmpty { Text(tab == 0 ? "还没有来信，等另一只小喵送来问候。" : "还没有寄出的信。写几句话给对方吧。")
                            .font(.callout).foregroundStyle(.secondary).padding(12) }
                        ForEach(letters) { entry in
                            Button { mailbox.select(entry.id) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(entry.unread ? "💌 未读" : entry.direction == .incoming ? "已读" : deliveryTitle(entry))
                                            .font(.caption.bold()).foregroundStyle(entry.unread ? Color.pink : cocoa)
                                        Spacer()
                                    }
                                    Text(entry.letter.body).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                                    Text(mailDate(entry.receivedAt ?? entry.letter.createdAt)).font(.caption2).foregroundStyle(.secondary)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(mailbox.selectedLetterID == entry.id ? Color.pink.opacity(0.12) : .white.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain)
                        }
                    }.padding(4)
                }.frame(minWidth: 190, idealWidth: 210, maxWidth: 240)
                VStack(alignment: .leading, spacing: 12) {
                    if let entry = mailbox.selected {
                        HStack(alignment: .top) {
                            Text(entry.direction == .incoming ? "寄给主人的一封信 💌" : "寄给另一只小喵的信").font(.headline)
                            Spacer()
                            Button("删除") { deleting = entry.id }.controlSize(.small)
                        }
                        Text("\(entry.direction == .incoming ? "收到于" : "写于") \(mailDate(entry.receivedAt ?? entry.letter.createdAt))")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            Text(entry.letter.body).font(.system(size: 15)).lineSpacing(7).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        }
                        if entry.direction == .outgoing {
                            Text(deliveryTitle(entry)).font(.caption).foregroundStyle(.secondary)
                            if let detail = entry.lastError, entry.delivery == .queued { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                            if entry.delivery == .queued {
                                HStack {
                                    Button("现在重试") { perform { try mailbox.retry(entry.id) } }.disabled(mailbox.isSending)
                                    Button("停止重试") { perform { try mailbox.stopRetrying(entry.id) } }
                                }.controlSize(.small)
                            }
                        }
                    } else {
                        Spacer()
                        Text("💌").font(.system(size: 48)).frame(maxWidth: .infinity)
                        Text("点开一封信，就能在这里读到内容。")
                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        Spacer()
                    }
                }.padding(16).frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            }
            Divider()
            Text("两台 Mac 都需运行 Meow 并启用信箱。对方离线时，信保留在待寄箱并自动重试；显示‘已送达’表示对方已保存。打开后的信会继续保留在本机信箱里。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).padding(.top, 18).frame(width: 700, height: 680)
            .foregroundStyle(cocoa).background(Color(red: 1, green: 0.975, blue: 0.94))
            .sheet(isPresented: $binding) { MailBindingView(mailbox: mailbox) }
            .sheet(isPresented: $writing) { MailComposeView(mailbox: mailbox) }
            .onChange(of: mailbox.selectedLetterID) { _, _ in
                if let selected = mailbox.selected { tab = selected.direction == .incoming ? 0 : 1 }
            }
            .alert("删除这封信？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("取消", role: .cancel) { deleting = nil }
                Button("删除", role: .destructive) { if let id = deleting { perform { try mailbox.remove(id) } }; deleting = nil }
            } message: { Text("只删除本机保存的内容，已经寄出的信无法从对方信箱撤回。") }
    }
    private var letters: [MailEntry] {
        mailbox.book.entries.filter { $0.direction == (tab == 0 ? .incoming : .outgoing) }
            .sorted { ($0.receivedAt ?? $0.letter.createdAt) > ($1.receivedAt ?? $1.letter.createdAt) }
    }
    private func deliveryTitle(_ entry: MailEntry) -> String {
        entry.delivery == .delivered ? "已送达" : entry.delivery == .cancelled ? "已停止重试" : "待寄 · 等待对方回执"
    }
    private func perform(_ operation: () throws -> Void) {
        do { try operation(); error = "" } catch { self.error = error.localizedDescription }
    }
}

struct MailBindingView: View {
    @ObservedObject var mailbox: MailboxController
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = "另一台 Mac 的小喵"
    @State private var error = ""
    @State private var busy = false
    @State private var unbinding = false
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("绑定另一台 Meow").font(.title3.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("1. 两台 Mac 都启用信箱。\n2. 复制各自的设备码，发给对方。\n3. 两边各粘贴一次对方的设备码并绑定。")
                .font(.callout).lineSpacing(5)
            HStack {
                Text("本机设备：\(mailbox.book.localDeviceID.map { String($0.prefix(12)) } ?? "等待启用")").font(.callout.monospaced())
                Spacer()
                Button(copied ? "已复制" : "复制本机设备码") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(mailbox.deviceCode, forType: .string); copied = true
                }.disabled(mailbox.deviceCode.isEmpty)
            }
            if let peer = mailbox.book.peer {
                Text("已绑定：\(peer.name) · \(String(peer.deviceID.prefix(12)))").font(.callout).textSelection(.enabled)
            }
            TextField("对方的名字（仅本机备注）", text: $name).textFieldStyle(.roundedBorder)
            Text("粘贴对方完整的设备码").font(.subheadline.bold())
            TextEditor(text: $code).font(.system(size: 11, design: .monospaced)).frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.25)))
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if mailbox.book.peer != nil { Button("解除绑定", role: .destructive) { unbinding = true } }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(mailbox.book.peer == nil ? "绑定这台设备" : "更新同一设备的地址") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await mailbox.bind(code: code, name: name); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(busy || code.isEmpty || !mailbox.isRunning)
            }
            Text("当前只绑定一台设备。设备码包含公开连接信息，只有两边都绑定后才能互相收信；解除绑定后仍保留历史信件。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).frame(width: 560)
            .onAppear { if let peer = mailbox.book.peer { name = peer.name } }
            .alert("解除设备绑定？", isPresented: $unbinding) {
                Button("取消", role: .cancel) {}
                Button("解除绑定", role: .destructive) {
                    Task { do { try await mailbox.unbind(); code = "" } catch { self.error = error.localizedDescription } }
                }
            } message: { Text("保留历史信件，停止向旧设备重试；已经传出的信可能已被对方保存。") }
    }
}

struct MailComposeView: View {
    @ObservedObject var mailbox: MailboxController
    @Environment(\.dismiss) private var dismiss
    @State private var bodyText = ""
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("写一封信 💌").font(.title3.bold())
            Text("收信小喵：\(mailbox.book.peer?.name ?? "尚未绑定")").font(.callout)
            TextEditor(text: $bodyText).font(.system(size: 15)).frame(height: 240)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.gray.opacity(0.25)))
            HStack {
                Text("\(bodyText.count) / 5000 字").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("寄出") {
                    do { let id = try mailbox.compose(bodyText); mailbox.select(id); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyText.count > 5000 || mailbox.book.peer == nil)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
            Text("对方不在线时，信会先保存在本机待寄箱。正文不会提交给大模型。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 540)
    }
}

@MainActor
final class MailboxWindowController {
    let panel: NSPanel
    private let mailbox: MailboxController
    init(mailbox: MailboxController) {
        self.mailbox = mailbox
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 700, height: 680),
                        styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "喵喵信箱"; panel.titlebarAppearsTransparent = true; panel.appearance = NSAppearance(named: .aqua)
        panel.level = .floating; panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MailboxView(mailbox: mailbox)); host.sizingOptions = []
        panel.contentView = host
    }
    func show(openUnread: Bool = false, activate: Bool = true) {
        if openUnread { mailbox.selectFirstUnread() }
        panel.center()
        if activate { NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFront(nil) }
    }
}
