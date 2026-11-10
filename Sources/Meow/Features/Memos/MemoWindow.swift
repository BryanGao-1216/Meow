import AppKit
import SwiftUI
import MeowMemos

struct MemoView: View {
    @ObservedObject var memos: MemoController
    @State private var title = ""
    @State private var dueAt = Date().addingTimeInterval(3600)
    @State private var editing: UUID?
    @State private var showFinished = false
    @State private var error = ""
    @State private var deleting: MemoItem?
    private let cocoa = Color(red: 0.36, green: 0.27, blue: 0.21)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("喵喵备忘录").font(.title3.bold())
                Spacer()
                if memos.isBusy || memos.isPlanning { ProgressView().controlSize(.small) }
                Text("\(memos.book.active.count) 条待办").font(.callout).foregroundStyle(.secondary)
            }
            Text("记下时间和要做的事，Meow 到点会提醒，也会每半小时想一想要不要提前叫你准备。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Toggle("让 Meow 主动提前提醒", isOn: Binding(get: { memos.book.earlyEnabled }, set: { value in
                perform { try memos.setEarlyEnabled(value) }
            })).font(.callout)
            if let date = memos.nextReview {
                Text("下次巡看：\(MemoPrompts.display(date))").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(editing == nil ? "新增备忘" : "编辑备忘").font(.subheadline.bold())
                TextField("要做的事，例如：和朋友聚会", text: $title).textFieldStyle(.roundedBorder)
                HStack {
                    DatePicker("提醒时间", selection: $dueAt, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field).environment(\.locale, Locale(identifier: "zh_CN"))
                    Spacer()
                    if editing != nil { Button("取消编辑") { resetEditor() } }
                    Button(editing == nil ? "添加" : "保存修改") {
                        perform { try memos.saveItem(id: editing, title: title, dueAt: dueAt); resetEditor(); memos.checkSchedule() }
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || memos.storageError != nil)
                }.controlSize(.small)
            }.padding(12).background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            if let storageError = memos.storageError {
                HStack(alignment: .top) {
                    Text(storageError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button("重试读取") { memos.reloadStorage(); memos.checkSchedule() }.controlSize(.small)
                }
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text(memos.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
            HStack {
                Text("时间 · 任务").font(.subheadline.bold())
                Spacer()
                Toggle("显示已完成和已取消", isOn: $showFinished).font(.caption)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if selected.isEmpty {
                        Text("还没有备忘。也可以在聊天里说：‘明天晚上七点提醒我参加聚会’。")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 28)
                    }
                    ForEach(selected) { item in row(item) }
                }.padding(.vertical, 4)
            }
            Divider()
            Text("时间按电脑当前时区显示。到点提醒和提前判断使用当前云端模型；需保持 Meow 运行、电脑唤醒并联网。错过的到点提醒会在恢复后补上；不填完整时间时，Meow 会先问清楚。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("备忘录保存在本机，与小本本分开管理").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("打开存储位置") { NSWorkspace.shared.selectFile(memos.fileURL.path, inFileViewerRootedAtPath: memos.fileURL.deletingLastPathComponent().path) }
                    .controlSize(.small)
            }
        }
        .padding(20).padding(.top, 18).frame(width: 600, height: 700)
        .foregroundStyle(cocoa).background(Color(red: 1, green: 0.975, blue: 0.94))
        .alert("删除这条备忘？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let item = deleting { perform { try memos.remove(id: item.id); if editing == item.id { resetEditor() } } }
                deleting = nil
            }
        } message: { Text(deleting?.title ?? "") }
    }
    private var selected: [MemoItem] {
        memos.book.items.filter { showFinished || $0.status == .pending }.sorted {
            if ($0.status == .pending) != ($1.status == .pending) { return $0.status == .pending }
            return $0.dueAt < $1.dueAt
        }
    }
    private func row(_ item: MemoItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                Text(item.title).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
                Spacer()
                Text(item.status == .completed ? "已完成" : item.status == .cancelled ? "已取消" : item.dueNotifiedAt != nil ? "已到点提醒" : "待提醒")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(MemoPrompts.display(item.dueAt)).font(.callout).foregroundStyle(item.dueAt < Date() && item.status == .pending ? .red : cocoa)
            HStack {
                if item.status == .pending {
                    Button("完成") { perform { try memos.setStatus(.completed, id: item.id) } }
                    Button("编辑") { editing = item.id; title = item.title; dueAt = item.dueAt; error = "" }
                    Button("稍后十分钟") { perform { try memos.saveItem(id: item.id, title: item.title, dueAt: Date().addingTimeInterval(600)) } }
                    Button("取消提醒") { perform { try memos.setStatus(.cancelled, id: item.id) } }
                } else {
                    Button("恢复待办") { perform { try memos.setStatus(.pending, id: item.id) } }
                }
                Spacer()
                Button("删除", role: .destructive) { deleting = item }
            }.controlSize(.small).disabled(memos.storageError != nil)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(item.status == .pending ? 0.85 : 0.45), in: RoundedRectangle(cornerRadius: 10))
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); error = "" } catch { self.error = error.localizedDescription }
    }
    private func resetEditor() { editing = nil; title = ""; dueAt = Date().addingTimeInterval(3600) }
}

@MainActor
final class MemoWindowController {
    let panel: NSPanel
    init(memos: MemoController) {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 600, height: 700),
                        styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "喵喵备忘录"; panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .aqua); panel.level = .floating; panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MemoView(memos: memos)); host.sizingOptions = []
        panel.contentView = host
    }
    func show(activate: Bool = true) {
        panel.center()
        if activate { NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFront(nil) }
    }
}
