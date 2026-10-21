import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var loggingOut = false
    @State private var confirmLogout = false
    @AppStorage("mediaBaseURL") private var mediaBase = ""
    @State private var mediaError: String?
    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) { BrandMark(size: 50); VStack(alignment: .leading, spacing: 5) {
                        Text(store.preview ? "预览工作空间" : store.username).font(.headline)
                        Text(store.preview ? "连接服务器，开始真实对话" : store.server).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } }.padding(.vertical, 10)
                }
                Section("工作空间") {
                    NavigationLink { ModelSettingsView() } label: { Label("模型与订阅", systemImage: "cpu") }.disabled(store.preview)
                    NavigationLink { AgentSettingsView() } label: { Label("思考与上下文", systemImage: "brain") }.disabled(store.preview)
                    NavigationLink { ToolsSettingsView() } label: { Label("工具管理", systemImage: "wrench.and.screwdriver") }.disabled(store.preview)
                }
                Section("偏好") {
                    Picker(selection: $store.appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") } label: { Label("外观", systemImage: "circle.lefthalf.filled") }
                }
                Section {
                    TextField("https://对象存储域名", text: $mediaBase).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("media-base-field")
                    if let mediaError { Text(mediaError).font(.caption).foregroundStyle(.red) }
                } header: { Text("媒体 / 对象存储地址") } footer: { Text("将消息中的 localhost / 127.0.0.1 图片链接重写到这里。留空时不请求这些本机链接。") }
                .onChange(of: mediaBase) { _, value in mediaError = value.isEmpty || (try? ProtocolCodec.baseURL(value)) != nil ? nil : "公网地址须使用 HTTPS；HTTP 仅限局域网" }
                NavigationLink { NotificationSettingsView() } label: { Label("会话通知", systemImage: "bell") }.disabled(store.preview)
                NavigationLink { UpdateSettingsView() } label: { Label("版本更新", systemImage: "arrow.down.circle") }
                NavigationLink { PrivacySettingsView() } label: { Label("隐私与数据", systemImage: "hand.raised") }.accessibilityIdentifier("privacy-settings-link")
                Section("关于") {
                    LabeledContent("版本", value: UpdateController.shared.installedVersion + " · iOS")
                    Link(destination: URL(string: "https://github.com/ai-pivot/xbot-android")!) { Label("参考项目 · xbot-android", systemImage: "arrow.up.right.square") }
                    Text("原生 Markdown、表格、代码、图片和工具结果；Mermaid 使用随 App 打包的离线渲染器。GenUI 与 Android 一样显示文本。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button(store.preview ? "连接我的服务器" : "退出登录", role: store.preview ? nil : .destructive) {
                        if store.preview { Task { await store.logout() } } else { confirmLogout = true }
                    }.disabled(loggingOut).frame(maxWidth: .infinity)
                }
            }.navigationTitle("设置")
                .confirmationDialog("退出当前账号？", isPresented: $confirmLogout, titleVisibility: .visible) {
                    Button("退出登录", role: .destructive) { loggingOut = true; Task { await store.logout(); loggingOut = false } }
                }
        }
    }
}

@MainActor @Observable
final class RemoteSettings {
    var values: [String: JSONValue] = [:]
    var loading = false
    var saving = false
    var error: String?
    var success: String?
    func load(_ api: XbotAPI?, methods: [String]) async {
        guard let api, !loading else { return }; loading = true; defer { loading = false }
        error = nil
        // Keep partial successful results visible when one optional RPC is unavailable.
        for method in methods {
            do { values[method] = try await api.rpc(method, method == "get_settings" ? ["namespace": .string("agent")] : [:]) }
            catch { self.error = error.localizedDescription }
        }
    }
    func mutate(_ api: XbotAPI?, method: String, params: [String: JSONValue], reload: [String]) async {
        guard let api, !saving else { return }; saving = true; defer { saving = false }; success = nil
        do { _ = try await api.rpc(method, params); await load(api, methods: reload); if error == nil { success = "已保存" } }
        catch { self.error = error.localizedDescription }
    }
}

struct ModelSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var vm = RemoteSettings()
    private let methods = ["list_all_model_entries", "list_subscriptions", "get_default_model"]
    var body: some View {
        List {
            if vm.loading { ProgressView("加载模型…") }
            if let error = vm.error { ErrorBanner(text: error) }
            Section("默认模型") {
                let current = vm.values["get_default_model"] ?? .null
                Text(current["model"].string.nonEmpty ?? "未设置").font(.headline)
                ForEach(Array((vm.values["list_all_model_entries"]?.array ?? []).enumerated()), id: \.offset) { _, entry in
                    Button {
                        Task { await vm.mutate(store.api, method: "set_default_model", params: ["sub_id": entry["sub_id"], "model": entry["model"]], reload: methods) }
                    } label: {
                        HStack { VStack(alignment: .leading, spacing: 4) {
                            Text(entry["model"].string).foregroundStyle(.primary)
                            Text(entry["sub_name"].string + (entry["vision"].bool ? " · 视觉" : "")).font(.caption).foregroundStyle(.secondary)
                        }; Spacer(); if current["sub_id"] == entry["sub_id"] && current["model"] == entry["model"] { Image(systemName: "checkmark") } }
                    }.disabled(vm.saving || entry["status"].string == "disabled")
                }
            }
            ForEach(Array((vm.values["list_subscriptions"]?.array ?? []).enumerated()), id: \.offset) { _, sub in
                Section(sub["name"].string.nonEmpty ?? sub["id"].string) {
                    Toggle("启用订阅", isOn: Binding(get: { sub["enabled"] != .bool(false) }, set: { enabled in
                        Task { await vm.mutate(store.api, method: "set_subscription_enabled", params: ["sub_id": sub["id"], "enabled": .bool(enabled)], reload: methods) }
                    })).disabled(vm.saving)
                    ForEach(Array((vm.values["list_all_model_entries"]?.array ?? []).filter { $0["sub_id"] == sub["id"] }.enumerated()), id: \.offset) { _, model in
                        Toggle(model["model"].string, isOn: Binding(get: { model["status"].string != "disabled" }, set: { enabled in
                            Task { await vm.mutate(store.api, method: "set_model_enabled", params: ["sub_id": sub["id"], "model": model["model"], "enabled": .bool(enabled)], reload: methods) }
                        })).font(.subheadline).disabled(vm.saving)
                    }
                }
            }
            if vm.values["list_all_model_entries"]?.array.isEmpty == true { ContentUnavailableView("暂无模型", systemImage: "cpu", description: Text("请先在服务端配置模型订阅。")) }
        }.navigationTitle("模型与订阅").navigationBarTitleDisplayMode(.inline)
            .task { await vm.load(store.api, methods: methods) }.refreshable { await vm.load(store.api, methods: methods) }
    }
}

struct AgentSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var vm = RemoteSettings()
    @State private var thinking = ""
    @State private var context = ""
    @State private var output = ""
    @State private var maxContext = ""
    @State private var concurrency = ""
    @State private var compression = ""
    private let methods = ["get_user_thinking_mode", "get_context_mode", "get_user_max_output_tokens", "get_user_max_context", "get_llm_concurrency", "get_settings"]
    var body: some View {
        Form {
            if vm.loading { ProgressView("加载设置…") }
            if let error = vm.error { ErrorBanner(text: error) }
            Section("推理与记忆") {
                Picker("思考模式", selection: $thinking) {
                    Text("自动").tag("auto"); Text("开启").tag("think"); Text("最大").tag("think-max"); Text("关闭").tag("disabled")
                    if !["auto", "think", "think-max", "disabled"].contains(thinking) { Text(thinking).tag(thinking) }
                }.accessibilityIdentifier("thinking-picker")
                Picker("上下文模式", selection: $context) {
                    Text("服务器默认").tag(""); Text("自动压缩").tag("phase1"); Text("不压缩").tag("none")
                    if !["", "phase1", "none"].contains(context) { Text(context).tag(context) }
                }
            }
            Section {
                numeric("最大输出 Token", text: $output)
                numeric("最大上下文 Token", text: $maxContext)
                numeric("个人并发数", text: $concurrency)
                HStack { Text("压缩阈值（0–1）"); Spacer(); TextField("0.8", text: $compression).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 120).accessibilityIdentifier("compression-field") }
            } header: { Text("资源上限") } footer: { Text("0 表示使用服务端默认值或不设上限，具体以服务端配置为准。") }
            Section {
                Button("保存设置") { Task { await save() } }.disabled(vm.loading || vm.saving || vm.values.count != methods.count).accessibilityIdentifier("save-agent-settings")
                if let success = vm.success { Label(success, systemImage: "checkmark.circle").foregroundStyle(Theme.accent) }
                if let error = vm.error { ErrorBanner(text: error) }
            }
        }.scrollDismissesKeyboard(.interactively).textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("思考与上下文").navigationBarTitleDisplayMode(.inline)
            .task {
                await vm.load(store.api, methods: methods)
                thinking = ThinkingMode.display(vm.values[methods[0]]?.string ?? ""); context = vm.values[methods[1]]?.string.nonEmpty ?? "phase1"
                output = String(vm.values[methods[2]]?.int ?? 0); maxContext = String(vm.values[methods[3]]?.int ?? 0); concurrency = String(vm.values[methods[4]]?.int ?? 0)
                let value = vm.values["get_settings"]?["compression_threshold"] ?? .null
                compression = value.isNull ? "" : value.string.nonEmpty ?? value.display
            }
    }
    private func numeric(_ label: String, text: Binding<String>) -> some View { HStack { Text(label); Spacer(); TextField("0", text: text).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 120) } }
    private func save() async {
        guard let api = store.api, let out = Int(output), let ctx = Int(maxContext), let conc = Int(concurrency), out >= 0, ctx >= 0, conc >= 0 else { vm.error = "请输入有效的非负整数"; return }
        guard let threshold = Double(compression), threshold.isFinite, (0...1).contains(threshold) else { vm.error = "压缩阈值必须在 0 到 1 之间"; return }
        vm.saving = true; defer { vm.saving = false }; vm.success = nil; vm.error = nil
        do {
            // The server exposes individual writes; report a partial failure instead of claiming atomicity.
            _ = try await api.rpc("set_user_thinking_mode", ["mode": .string(ThinkingMode.wire(thinking))])
            _ = try await api.rpc("set_context_mode", ["mode": .string(context)])
            _ = try await api.rpc("set_user_max_output_tokens", ["max_tokens": .number(Double(out))])
            _ = try await api.rpc("set_user_max_context", ["max_context": .number(Double(ctx))])
            _ = try await api.rpc("set_llm_concurrency", ["personal": .number(Double(conc))])
            _ = try await api.rpc("set_compression_threshold", ["threshold": .number(threshold)])
            vm.success = "已保存"
        } catch { vm.error = "部分设置可能已保存：" + error.localizedDescription }
    }
}

struct ToolsSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var vm = RemoteSettings()
    var body: some View {
        List {
            if vm.loading { ProgressView("加载工具…") }
            if let error = vm.error { ErrorBanner(text: error) }
            ForEach(Array((vm.values["get_tools_settings"]?["tools"].array ?? []).enumerated()), id: \.offset) { _, tool in
                Toggle(isOn: Binding(get: { tool["enabled"] != .bool(false) }, set: { enabled in
                    Task { await vm.mutate(store.api, method: "set_tool_enabled", params: ["name": tool["name"], "enabled": .bool(enabled)], reload: ["get_tools_settings"]) }
                })) {
                    VStack(alignment: .leading, spacing: 5) { Text(tool["name"].string).font(.headline); Text(tool["description"].string).font(.caption).foregroundStyle(.secondary) }
                }.disabled(vm.saving)
            }
            if vm.values["get_tools_settings"]?["tools"].array.isEmpty == true { ContentUnavailableView("暂无工具", systemImage: "wrench.and.screwdriver") }
        }.navigationTitle("工具管理").navigationBarTitleDisplayMode(.inline)
            .task { await vm.load(store.api, methods: ["get_tools_settings"]) }.refreshable { await vm.load(store.api, methods: ["get_tools_settings"]) }
    }
}
