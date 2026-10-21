import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm: ChatStore
    @State private var pickingFile = false
    @State private var photo: PhotosPickerItem?
    @State private var pickingModel = false
    @State private var rewindTurn: ChatTurn?
    @State private var showAsk = false
    @State private var showRewind = false
    @State private var followTail = true
    @State private var tailVisible = true
    @State private var userScrolling = false
    @FocusState private var composerFocused: Bool

    init(chat: ChatSession, api: XbotAPI?, preview: Bool) {
        _vm = State(initialValue: ChatStore(chat: chat, api: api, preview: preview))
    }
    var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            if vm.preview {
                Text("界面预览 · 登录服务器后可发送消息").font(.caption).foregroundStyle(Theme.accent)
                    .padding(10).frame(maxWidth: .infinity).background(Theme.accent.opacity(0.07))
            }
            if let error = vm.error { ErrorBanner(text: error) { vm.error = nil }.padding(.horizontal).padding(.top, 8) }
            conversation
            if let prompt = vm.state.ask {
                Button { showAsk = true } label: {
                    HStack { Image(systemName: "hand.raised"); Text("Agent 需要你的回答").fontWeight(.medium); Spacer(); Image(systemName: "chevron.right") }
                        .font(.subheadline).padding(14).background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                }.padding(.horizontal).padding(.bottom, 8)
                    .accessibilityIdentifier("ask-user-button")
                    .onAppear { if !prompt.questions.isEmpty { showAsk = true } }
            }
            if !vm.state.queue.isEmpty {
                DisclosureGroup("\(vm.state.queue.count) 条消息排队中") {
                    ForEach(Array(vm.state.queue.enumerated()), id: \.offset) { _, text in Text(text).font(.caption).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }
                }.font(.caption).padding(.horizontal, 20).padding(.bottom, 8)
            }
            composer
        }
        .background(Color(.systemBackground))
        .navigationTitle(vm.chat.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 3) {
                    Text(vm.chat.title).font(.headline).lineLimit(1)
                    HStack(spacing: 4) { Circle().fill(vm.connection == "已连接" ? Theme.accent : .secondary).frame(width: 5, height: 5); Text(vm.connection).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("重新同步", systemImage: "arrow.clockwise") { Task { vm.stop(); await vm.start() } }.disabled(vm.preview || vm.loading)
                    Button("回退历史", systemImage: "clock.arrow.circlepath") { showRewind = true }.disabled(vm.preview || vm.state.busy)
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("会话操作")
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .task(id: scenePhase) { if scenePhase == .active { await vm.start() } else { vm.stop() } }
        .onAppear { if scenePhase == .active { Task { await vm.start() } } }
        .onDisappear { vm.stop() }
        .onChange(of: vm.state.ask?.id) { _, value in if value != nil { showAsk = true } else { showAsk = false } }
        .sheet(isPresented: $showAsk) {
            if let prompt = vm.state.ask { AskUserView(prompt: prompt, vm: vm).id(prompt.id) }
        }
        .sheet(isPresented: $pickingModel) { modelPicker }
        .sheet(isPresented: $showRewind) { RewindPicker(vm: vm) }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.item]) { result in
            Task {
                do {
                    let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                    let data = try await Task.detached { try Data(contentsOf: url) }.value
                    await vm.upload(data: data, name: url.lastPathComponent, mime: values.contentType?.preferredMIMEType ?? "application/octet-stream")
                } catch { vm.error = error.localizedDescription }
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw ServerError("无法读取照片") }
                    let type = item.supportedContentTypes.first ?? .jpeg
                    await vm.upload(data: data, name: "photo.\(type.preferredFilenameExtension ?? "jpg")", mime: type.preferredMIMEType ?? "image/jpeg")
                } catch { vm.error = error.localizedDescription }
                photo = nil
            }
        }
        .confirmationDialog("回退到这条消息？此后的历史将被移除。", isPresented: Binding(get: { rewindTurn != nil }, set: { if !$0 { rewindTurn = nil } }), titleVisibility: .visible) {
            Button("回退历史", role: .destructive) { if let turn = rewindTurn { Task { await vm.rewind(turn) } }; rewindTurn = nil }
        }
    }

    private var conversation: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    Color.clear.frame(height: 1).id("head")
                    if vm.state.hasMore { Button("加载更早的消息") { Task { await vm.reload(older: true) } }.font(.caption).frame(maxWidth: .infinity).disabled(vm.loading) }
                    if vm.loading && vm.state.turns.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(30) }
                    if vm.state.turns.isEmpty && !vm.loading {
                        VStack(spacing: 16) {
                            BrandMark(size: 52)
                            Text("今天，一起完成什么？").font(.title2.bold())
                            Text("提出问题，或交给我一个任务。\n我会在这里展示思考、工具调用和结果。")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
                        }.frame(maxWidth: .infinity).padding(.vertical, 70)
                    }
                    ForEach(vm.state.turns) { turn in turnView(turn) }
                    if vm.sending { Label("正在发送…", systemImage: "arrow.up.circle").font(.caption).foregroundStyle(.secondary) }
                    if vm.state.busy {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在处理").font(.subheadline).foregroundStyle(.secondary); Spacer(); Button("停止") { Task { await vm.cancel() } }.font(.subheadline) }
                    }
                    Color.clear.frame(height: 1).id("tail")
                        .onAppear { tailVisible = true; followTail = true }
                        .onDisappear { tailVisible = false; if userScrolling { followTail = false } }
                }.padding(20).frame(maxWidth: 840).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .simultaneousGesture(DragGesture().onChanged { _ in userScrolling = true; followTail = false }.onEnded { _ in userScrolling = false; followTail = tailVisible })
            .onChange(of: vm.state) { _, _ in if followTail { reader.scrollTo("tail", anchor: .bottom) } }
            .onChange(of: vm.sending) { _, sending in if sending { followTail = true; reader.scrollTo("tail", anchor: .bottom) } }
            .overlay(alignment: .bottomTrailing) {
                if !vm.state.turns.isEmpty {
                    VStack(spacing: 10) {
                        Button { followTail = false; withAnimation { reader.scrollTo("head", anchor: .top) } } label: { Image(systemName: "arrow.up.to.line").frame(width: 34, height: 34) }.accessibilityLabel("跳到顶部").accessibilityIdentifier("chat-top")
                        if !followTail { Button { followTail = true; withAnimation { reader.scrollTo("tail", anchor: .bottom) } } label: { Image(systemName: "arrow.down.to.line").frame(width: 34, height: 34) }.accessibilityLabel("跳到最新消息").accessibilityIdentifier("chat-bottom") }
                    }.buttonStyle(.bordered).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(12)
                }
            }
        }
    }
    private func turnView(_ turn: ChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if !turn.user.isEmpty {
                HStack { Spacer(minLength: 32); Text(turn.user).textSelection(.enabled).padding(15)
                    .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 20)) }
            }
            VStack(alignment: .leading, spacing: 16) {
                if !turn.final.isEmpty || !turn.iterations.isEmpty {
                    HStack(spacing: 7) { BrandMark(size: 22); Text("xbot").font(.caption.bold()).foregroundStyle(.secondary) }
                }
                ForEach(turn.iterations) { iteration in
                    if !iteration.reasoning.isEmpty {
                        DisclosureGroup {
                            MarkdownText(text: iteration.reasoning, api: vm.api).font(.subheadline).foregroundStyle(.secondary).padding(.top, 8)
                        } label: { Label("思考过程", systemImage: "sparkle").font(.caption).foregroundStyle(Color.secondary) }
                    }
                    ForEach(iteration.tools) { tool in ToolCard(tool: tool, api: vm.api) }
                    if !iteration.content.isEmpty { MarkdownText(text: iteration.content, api: vm.api) }
                }
                if !turn.final.isEmpty && turn.final != turn.iterations.last?.content { MarkdownText(text: turn.final, api: vm.api) }
                if turn.cancelled { Label("已停止", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .contextMenu {
            Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = turn.final.nonEmpty ?? turn.iterations.map(\.content).joined(separator: "\n\n") }
            if !vm.preview && turn.historyID > 0 && !vm.state.busy { Button("回退到这里", systemImage: "clock.arrow.circlepath", role: .destructive) { rewindTurn = turn } }
        }
    }

    private var composer: some View {
        @Bindable var vm = vm
        return VStack(alignment: .leading, spacing: 12) {
            if !vm.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(vm.attachments) { attachment in
                            HStack(spacing: 6) { Image(systemName: "doc"); Text(attachment.name).lineLimit(1); Button { vm.attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("移除附件 \(attachment.name)") }
                                .font(.caption).padding(9).background(Theme.canvas, in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                Menu {
                    Button("选择文件", systemImage: "doc") { pickingFile = true }
                    PhotosPicker(selection: $photo, matching: .images) { Label("选择照片", systemImage: "photo") }
                } label: {
                    if vm.uploading { ProgressView().frame(width: 30, height: 36) }
                    else { Image(systemName: "plus").font(.title3).frame(width: 30, height: 36) }
                }.disabled(vm.preview || vm.uploading || vm.sending).accessibilityLabel("添加附件")
                TextField(vm.preview ? "连接服务器后开始对话" : "发送消息…", text: $vm.draft, axis: .vertical)
                    .lineLimit(1...7).padding(.vertical, 8).focused($composerFocused).disabled(vm.preview)
                    .accessibilityIdentifier("message-field")
                Button { composerFocused = false; Task { await vm.send() } } label: {
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 38, height: 38).background(Theme.accent, in: Circle())
                }.disabled(vm.preview || vm.sending || vm.uploading || (vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && vm.attachments.isEmpty))
                    .opacity(vm.draft.isEmpty && vm.attachments.isEmpty ? 0.4 : 1)
                    .accessibilityLabel(vm.state.busy ? "加入队列" : "发送消息").accessibilityIdentifier("send-button")
            }
            HStack {
                Button { pickingModel = true } label: { HStack(spacing: 5) { Image(systemName: "cpu"); Text(vm.model).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 8)) } }
                    .disabled(vm.preview)
                Spacer()
                Text(vm.state.busy ? "发送后加入队列" : "由你的 xbot 服务器处理").foregroundStyle(.tertiary)
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .padding(15).background(Theme.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(.separator).opacity(0.3), lineWidth: 0.5))
        .padding(.horizontal, 14).padding(.bottom, 8)
    }

    private var modelPicker: some View {
        NavigationStack {
            List {
                if vm.models.isEmpty { ContentUnavailableView("暂无模型", systemImage: "cpu", description: Text("请先在服务端配置模型订阅。")) }
                ForEach(Array(vm.models.enumerated()), id: \.offset) { _, entry in
                    Button { Task { await vm.selectModel(entry); pickingModel = false } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) { Text(entry["model"].string).foregroundStyle(.primary); Text(entry["sub_name"].string + (entry["vision"].bool ? " · 视觉" : "")).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if vm.selectedModel == entry["sub_id"].string + ":" + entry["model"].string { Image(systemName: "checkmark") }
                        }
                    }.disabled(entry["status"].string == "disabled")
                }
            }.navigationTitle("选择模型").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { pickingModel = false } } }
                .task { await vm.loadModels() }
        }.presentationDetents([.medium, .large])
    }
}
