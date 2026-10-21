import SwiftUI

struct SessionsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    @State private var path: [ChatSession] = []
    @State private var edit: SessionEdit?
    @State private var label = ""
    @State private var deleting: ChatSession?
    @State private var working = false
    @State private var localError: String?

    private var filtered: [ChatSession] {
        func matches(_ chat: ChatSession) -> Bool { search.isEmpty || chat.title.localizedCaseInsensitiveContains(search) || chat.preview.localizedCaseInsensitiveContains(search) }
        return store.sessions.filter { matches($0) || $0.children.contains(where: matches) }
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if UpdateController.shared.available {
                    Section { NavigationLink { UpdateSettingsView() } label: { Label("发现新版本 \(UpdateController.shared.manifest?.version ?? "")", systemImage: "arrow.down.circle") } }
                }
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) { BrandMark(); VStack(alignment: .leading, spacing: 4) {
                            Text(store.preview ? "探索 xbot" : "你的工作空间").font(.headline)
                            Text(store.preview ? "界面预览 · 连接后开始真实对话" : (URL(string: store.server)?.host ?? store.server)).font(.caption).foregroundStyle(.secondary)
                        }; Spacer() }
                        Text("每个想法，都值得继续。").font(.title2.bold())
                        HStack(spacing: 16) {
                            Label("\(store.sessions.count) 个会话", systemImage: "square.stack")
                            if store.sessions.contains(where: \.running) { Label("任务进行中", systemImage: "circle.dotted").foregroundStyle(Theme.accent) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 10)
                }.listRowBackground(Theme.card)
                if let error = localError ?? store.error {
                    Section { ErrorBanner(text: error) { localError = nil; store.error = nil } }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    if store.loading && store.sessions.isEmpty { ProgressView("加载会话…").frame(maxWidth: .infinity).padding() }
                    else if filtered.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "从一段对话开始" : "没有找到会话", systemImage: "bubble.left.and.text.bubble.right", description: Text(search.isEmpty ? "点右上角 +，开始你的第一个任务。" : "试试其他关键词。"))
                    }
                    ForEach(filtered) { chat in
                        sessionRow(chat)
                        ForEach(chat.children) { child in sessionRow(child, nested: true) }
                    }
                } header: { Text("最近会话") }
            }
            .listStyle(.insetGrouped).navigationTitle("会话")
            .searchable(text: $search, prompt: "搜索会话")
            .refreshable { await store.refresh() }
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { label = ""; edit = .create } label: { Image(systemName: "plus") }.accessibilityLabel("新建会话").disabled(store.preview || working)
            } }
            .navigationDestination(for: ChatSession.self) { chat in ChatView(chat: chat, api: store.api, preview: store.preview) }
            .onChange(of: store.notifiedSession) { _, chat in
                if let chat { path = [chat]; store.notifiedSession = nil }
            }
            .alert(edit?.title ?? "会话", isPresented: Binding(get: { edit != nil }, set: { if !$0 { edit = nil } })) {
                TextField("会话名称", text: $label)
                Button("取消", role: .cancel) { edit = nil }
                Button("保存") { let action = edit; edit = nil; Task { await save(action) } }
            }
            .confirmationDialog("删除“\(deleting?.title ?? "")”？此操作无法撤销。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除会话", role: .destructive) {
                    if let chat = deleting { Task { do { try await store.delete(chat) } catch { localError = error.localizedDescription } } }; deleting = nil
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await store.refresh()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    await store.refresh()
                }
            }
        }
    }
    private func sessionRow(_ chat: ChatSession, nested: Bool = false) -> some View {
        HStack {
        NavigationLink(value: chat) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: nested ? "arrow.turn.down.right" : "bubble.left")
                    .font(.system(size: 16)).foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36).background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(chat.title).font(.headline).lineLimit(1); if chat.running { Circle().fill(Theme.accent).frame(width: 7, height: 7) } else if chat.status == "error" { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).accessibilityLabel("会话执行失败") } }
                    Text(chat.preview.nonEmpty ?? "随时继续这段对话").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    HStack {
                        if chat.channel != "web" { Text(chat.channel).font(.caption2.monospaced()) }
                        if !chat.lastActive.isEmpty { Text(relativeTime(chat.lastActive)).font(.caption2) }
                    }.foregroundStyle(.tertiary)
                }
            }.padding(.vertical, 9)
        }
        .accessibilityIdentifier("session-\(chat.chatID)")
        .contextMenu { sessionActions(chat) }
        if !store.preview {
            Menu { sessionActions(chat) } label: { Image(systemName: "ellipsis").frame(width: 30, height: 40) }.accessibilityLabel("更多会话操作")
        }
        }
    }
    @ViewBuilder private func sessionActions(_ chat: ChatSession) -> some View {
        if !store.preview {
            Button("重命名", systemImage: "pencil") { label = chat.title; edit = .rename(chat) }
            Button("创建分支", systemImage: "arrow.triangle.branch") { label = chat.title + " · 分支"; edit = .fork(chat) }
            Button("删除会话", systemImage: "trash", role: .destructive) { deleting = chat }
        }
    }
    private func relativeTime(_ raw: String) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = format.date(from: raw)
        if date == nil { format.formatOptions = [.withInternetDateTime]; date = format.date(from: raw) }
        guard let date else { return String(raw.prefix(16)).replacingOccurrences(of: "T", with: " ") }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        if seconds < 7 * 86400 { return "\(seconds / 86400) 天前" }
        return String(raw.prefix(10))
    }
    private func save(_ action: SessionEdit?) async {
        let title = label.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "新会话"
        working = true; defer { working = false }
        do {
            switch action {
            case .create: path.append(try await store.create(title))
            case .fork(let chat): path.append(try await store.create(title, source: chat))
            case .rename(let chat): try await store.rename(chat, label: title)
            case nil: break
            }
        } catch { localError = error.localizedDescription }
    }
}

private enum SessionEdit {
    case create, rename(ChatSession), fork(ChatSession)
    var title: String { switch self { case .create: "新建会话"; case .rename: "重命名会话"; case .fork: "创建会话分支" } }
}
