import AppKit
import SwiftUI
import MeowMemory

struct MemoryView: View {
    @ObservedObject var memory: PetMemory
    @ObservedObject var settings: AppSettings
    @State private var search = ""
    @State private var tab = 0
    @State private var showOld = false
    @State private var confirmingClear = false
    private let cocoa = Color(red: 0.36, green: 0.27, blue: 0.21)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(AppIdentity.name)的小本本").font(.title3.bold())
                Spacer()
                Button("清空全部", role: .destructive) { confirmingClear = true }
                    .disabled(memory.hasUnreadableFile)
            }
            Text("相伴 \(memory.journal.companionDays.count) 天 · \(memory.journal.activeFacts().count) 条当前记忆 · \(memory.journal.experiences.count) 组共同经历")
                .font(.subheadline)
            Text(memory.journal.tendencies().bondDescription).font(.callout)
            if !settings.memoryEnabled {
                Text("记忆已暂停：保留小本本，但不继续学习、检索或影响行为。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = memory.storageError {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button(memory.hasUnreadableFile ? "重试读取" : "重试保存") {
                        if memory.hasUnreadableFile { memory.reload() } else { memory.flush() }
                    }
                }
            }
            if let error = memory.forgetError {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Spacer()
                    Button("重试清除聊天") { memory.retryForgettingContext() }
                }
            }
            Text(memory.learningStatus).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            TextField("搜索小本本", text: $search).textFieldStyle(.roundedBorder)
            Picker("内容", selection: $tab) {
                Text("主人资料与喜好").tag(0)
                Text("共同经历").tag(1)
            }.pickerStyle(.segmented)
            if tab == 0 {
                Toggle("显示旧版本和已过期的记忆", isOn: $showOld).font(.caption)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if tab == 0 {
                        if selectedFacts.isEmpty { empty("还没有这些记忆。你可以告诉我：‘叫我珺大王’、‘我喜欢茉莉花茶’。") }
                        ForEach(selectedFacts) { fact in factRow(fact) }
                    } else {
                        if selectedExperiences.isEmpty { empty("还没有这些共同经历。摸摸头、喂食或陪我玩，都会慢慢写进来。") }
                        ForEach(selectedExperiences) { event in experienceRow(event) }
                    }
                }.padding(.vertical, 4)
            }
            Divider()
            Text("记错了？在聊天里重新告诉我。删除会一并移除该主题的旧版本，并清空短期聊天，防止从旧对话重新想起。清空聊天本身会保留小本本。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("记忆保存在这台电脑上").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("打开存储位置") {
                    NSWorkspace.shared.selectFile(Persistence.supportDir.appendingPathComponent("pet-memory.json").path,
                                                  inFileViewerRootedAtPath: Persistence.supportDir.path)
                }.controlSize(.small)
            }
        }
        .padding(20).padding(.top, 18)
        .frame(width: 540, height: 660)
        .foregroundStyle(cocoa)
        .background(Color(red: 1, green: 0.975, blue: 0.94))
        .alert("清空所有记忆？", isPresented: $confirmingClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { memory.forgetAll() }
        } message: {
            Text("主人资料、喜好、共同经历、相处熟悉度和聊天记录都会被清除。性格设定和当前饱食度等状态会保留。")
        }
    }

    private var selectedFacts: [MemoryFact] {
        memory.journal.facts.filter {
            (showOld || $0.isActive(at: .now)) && (search.isEmpty || ($0.text + $0.evidence).localizedCaseInsensitiveContains(search))
        }.sorted { $0.lastConfirmedAt > $1.lastConfirmedAt }
    }

    private var selectedExperiences: [PetExperience] {
        memory.journal.experiences.filter {
            search.isEmpty || ($0.kind.description + $0.day).localizedCaseInsensitiveContains(search)
        }.sorted { $0.lastAt > $1.lastAt }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.vertical, 24)
    }

    private func factRow(_ fact: MemoryFact) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Text(fact.text).font(.system(size: 13, weight: .medium)).textSelection(.enabled)
                Spacer()
                Button("忘掉") { memory.forget(fact) }.controlSize(.small).disabled(memory.hasUnreadableFile)
            }
            Text("\(fact.kind.title) · \(fact.lastConfirmedAt.formatted(date: .abbreviated, time: .shortened)) · 确认\(fact.confirmations)次\(fact.isActive(at: .now) ? "" : fact.supersededAt != nil ? " · 已被更新" : " · 已过期")")
                .font(.caption2).foregroundStyle(.secondary)
            Text("\(fact.origin.title)：\(fact.evidence)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(fact.isActive(at: .now) ? 0.85 : 0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func experienceRow(_ event: PetExperience) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(event.kind.description).font(.system(size: 13, weight: .medium))
                Text("\(event.day) · 当天\(event.count)次 · 来自实际互动")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("忘掉") { memory.forget(event) }.controlSize(.small).disabled(memory.hasUnreadableFile)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
final class MemoryWindowController {
    private let panel: NSPanel

    init(memory: PetMemory) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 660),
                        styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
                        backing: .buffered, defer: false)
        panel.title = "\(AppIdentity.name)的小本本"
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .aqua)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: MemoryView(memory: memory, settings: .shared))
    }

    func show(activate: Bool = true) {
        panel.center()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }
    }
}
