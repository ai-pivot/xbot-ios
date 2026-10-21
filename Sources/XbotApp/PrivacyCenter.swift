import SwiftUI
import CryptoKit

@MainActor @Observable
final class PrivacyCenter {
    static let shared = PrivacyCenter()
    static let policyURL = URL(string: "https://github.com/ai-pivot/xbot-ios/blob/main/docs/PRIVACY.md")!
    static let appSupportURL = URL(string: "https://github.com/ai-pivot/xbot-ios/issues")!
    private(set) var policy: MobilePolicy?
    private(set) var error: String?
    private(set) var loading = false
    private(set) var blocked: [String: String] = [:]
    private(set) var accepted = false
    var localModelsOnly = false
    var additionalRecipients = ""
    var requestingConsent = false
    private var api: XbotAPI?
    private var account = ""
    private var revision = UUID()
    private var key: String { "privacy:" + (api?.baseURL.absoluteString ?? "") + ":" + account }
    private var fingerprint: Data? {
        guard let policy else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard var data = try? encoder.encode(policy) else { return nil }
        data.append(Data(("\n" + String(localModelsOnly) + "\n" + additionalRecipients.trimmingCharacters(in: .whitespacesAndNewlines)).utf8))
        return Data(SHA256.hash(data: data))
    }
    func configure(api: XbotAPI, username: String) async {
        revision = UUID(); self.api = api; account = username
        policy = nil; accepted = false; requestingConsent = false; loading = false; error = nil
        blocked = SecureStore.read(key + ":blocked").flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        let saved = SecureStore.read(key + ":recipients").flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        localModelsOnly = saved?["local_only"].bool ?? false
        additionalRecipients = saved?["recipients"].string ?? ""
        await reload()
    }
    func reload() async {
        guard let api, !loading else { return }
        let current = revision; loading = true; error = nil
        defer { if current == revision { loading = false } }
        do {
            let decoded: MobilePolicy
            if let result = try? await api.post("/api/mobile/policy", retry: false), let declared = try? MobilePolicy(result) {
                decoded = declared
            } else {
                let subscriptions = try await api.rpc("list_subscriptions")
                guard case .array = subscriptions else { throw ServerError("服务器订阅响应无效") }
                let tools = try await api.rpc("get_tools_settings")
                decoded = MobilePolicy(selfHostedServer: api.baseURL, subscriptions: subscriptions.array, tools: tools["tools"].array)
            }
            guard current == revision else { return }
            policy = decoded
            accepted = SecureStore.read(key + ":consent") == fingerprint
        } catch {
            guard current == revision else { return }
            policy = nil; accepted = false
            self.error = "暂时无法读取服务器的数据去向，请重试。自托管服务器无需部署额外服务；你可在确认页核对模型配置。"
        }
    }
    func requireConsent(for client: XbotAPI) async throws {
        guard api === client else { throw ServerError("工作空间已变更，请重新打开会话") }
        guard !loading else { throw ServerError("正在刷新服务器数据说明，请稍后重试") }
        await reload()
        guard api === client, policy != nil, accepted else {
            requestingConsent = true
            throw ServerError("请先阅读数据接收方说明并明确同意，再发送消息或上传附件")
        }
    }
    func accept() throws {
        guard let fingerprint, let policy else { throw ServerError("请先读取服务器配置") }
        if !policy.serverDeclared && !localModelsOnly && additionalRecipients.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (policy.providers.isEmpty || policy.providers.contains(where: { $0.endpoint == nil })) {
            throw ServerError("请填写实际使用的外部 AI 或代理服务商，或确认仅使用本地模型")
        }
        try SecureStore.write(JSONEncoder().encode(JSONValue.object(["local_only": .bool(localModelsOnly), "recipients": .string(additionalRecipients)])), account: key + ":recipients")
        try SecureStore.write(fingerprint, account: key + ":consent")
        accepted = true; requestingConsent = false
    }
    func revoke() {
        SecureStore.delete(key + ":consent"); accepted = false
        NotificationController.shared.disable()
    }
    func isBlocked(_ chat: ChatSession) -> Bool { blocked[chat.id] != nil }
    func block(_ chat: ChatSession) throws {
        var next = blocked
        func add(_ node: ChatSession) { next[node.id] = node.title; node.children.forEach(add) }
        add(chat)
        try SecureStore.write(JSONEncoder().encode(next), account: key + ":blocked"); blocked = next
        if let api, ClientPreferences.active(server: api.baseURL)?.id == chat.id { NotificationController.shared.disable() }
    }
    func unblock(_ id: String) throws {
        var next = blocked; next.removeValue(forKey: id)
        try SecureStore.write(JSONEncoder().encode(next), account: key + ":blocked"); blocked = next
    }
    func forgetAccount() {
        SecureStore.delete(key + ":consent"); SecureStore.delete(key + ":blocked"); SecureStore.delete(key + ":recipients")
        revision = UUID(); api = nil; account = ""; policy = nil; accepted = false; blocked = [:]; requestingConsent = false
    }
    func disconnect() {
        revision = UUID(); api = nil; account = ""; policy = nil; accepted = false; blocked = [:]; requestingConsent = false
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("xbot iOS 隐私说明").font(.title2.bold())
                Text("更新日期：2026 年 10 月 21 日")
                Text("这是连接用户自托管 xbot 服务器的通用客户端。应用维护者不提供或托管 xbot 账号，不接收你的密码、聊天或附件。登录时，用户名和密码仅发送给你指定的服务器；需要记住的密码和会话 Cookie 保存在本机钥匙串。公网连接使用 HTTPS；局域网 HTTP 无传输加密，仅应在可信网络中使用。")
                Text("发送消息、回答 Agent 问题或上传附件前，应用显示服务器地址及可读取的模型订阅配置，并请求你的明确同意。自托管服务器的运营方、模型、代理、工具和数据保留规则由你或管理员配置；兼容协议名称不代表实际供应商。你应核对真实接收方，可补充外部 AI/代理名称，也可确认仅使用本地模型。服务器声明完整隐私政策时，应用直接显示该说明。")
                Text("应用不包含广告或跨应用跟踪 SDK。外观、服务器地址、用户名和通知去重状态保存在本机；聊天历史主要从服务器读取。同源图片使用登录会话，外部图片服务不会收到 xbot Cookie。")
                Text("通知可选，拒绝通知不影响聊天。开启推送后，专用桥接会接收设备推送标识、服务器和会话标识；提醒只显示通用文字，不包含聊天正文或会话名称。服务器工具或对象存储可能处理附件，具体接收方与保留期限以工作空间说明为准。")
                Text("你可在“隐私与数据”中撤回 AI 分享同意、屏蔽会话、清除本机账号数据，或向支持删除接口的服务器发起账号及关联数据删除。撤回后停止新的 AI 消息和附件传输；已发送的数据由你或服务器管理员按各服务商政策处理。远端删除需服务器提供实际能力；“申请已受理”不代表已删除，清除本机数据也不会删除服务器数据。")
                Text("举报默认只提交会话标识、消息轮次和原因；只有你明确选择时才附带对应正文。请勿在公开 GitHub 问题中粘贴账号密码、聊天内容或其他个人信息。服务端数据事项请通过工作空间公布的支持渠道联系运营方；应用缺陷可联系开源维护者。")
                Link("查看公开隐私说明", destination: PrivacyCenter.policyURL)
                Link("联系应用维护者", destination: PrivacyCenter.appSupportURL)
            }.font(.subheadline).lineSpacing(5).padding(24).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }.navigationTitle("隐私说明").navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacySettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var privacy = PrivacyCenter.shared
    @State private var localError: String?
    var body: some View {
        Form {
            NavigationLink("应用隐私说明") { PrivacyPolicyView() }
            if !store.preview {
                PolicySections(privacy: privacy)
                Section {
                    LabeledContent("AI 数据分享", value: privacy.accepted ? "已同意" : "未同意")
                    Button("阅读并授权 AI 数据分享") { privacy.requestingConsent = true }.accessibilityIdentifier("privacy-review-consent")
                    Button("撤回 AI 数据分享同意", role: .destructive) { privacy.revoke() }.disabled(!privacy.accepted)
                    Button("刷新工作空间数据说明") { Task { await privacy.reload() } }.disabled(privacy.loading)
                    Button("清除此设备的账号数据", role: .destructive) { Task { await store.forgetAccount() } }
                }
                Section("已屏蔽的会话") {
                    if privacy.blocked.isEmpty { Text("暂无屏蔽会话").foregroundStyle(.secondary) }
                    ForEach(privacy.blocked.keys.sorted(), id: \.self) { id in
                        HStack { Text(privacy.blocked[id] ?? "会话"); Spacer(); Button("解除屏蔽") { do { try privacy.unblock(id) } catch { localError = error.localizedDescription } } }
                    }
                }
                Section {
                    NavigationLink("删除账号和关联数据") { AccountDeletionView() }.foregroundStyle(.red).accessibilityIdentifier("account-deletion-link")
                }
            }
            if let localError { ErrorBanner(text: localError) }
        }.navigationTitle("隐私与数据").navigationBarTitleDisplayMode(.inline)
            .privacyConsentSheet()
    }
}

private struct PolicySections: View {
    let privacy: PrivacyCenter
    var body: some View {
        if let policy = privacy.policy {
            Section(policy.serverDeclared ? "工作空间运营方" : "你的自托管服务器") {
                Text(policy.operatorName)
                if policy.serverDeclared {
                    Link("服务器隐私政策", destination: policy.privacyURL)
                    Link("联系服务器运营方", destination: policy.supportURL)
                } else {
                    Text("服务器由你或管理员维护。请从服务器配置核对数据接收方与保留规则；本应用不要求填写统一运营主体。").font(.footnote)
                }
                Text(policy.retention).font(.footnote)
                    if policy.serverDeclared { Text("账号删除申请将在 \(policy.deletionDays) 天内处理。法律要求保留的数据以服务器政策为准。").font(.footnote) }
            }
            Section("AI 与工具的数据接收方") {
                if policy.providers.isEmpty { Text(policy.serverDeclared ? "运营方声明仅在自有服务器内处理，不转交第三方 AI 服务商。" : "请按你的服务器实际配置确认本地模型或外部 AI/代理服务商。") }
                ForEach(Array(policy.providers.enumerated()), id: \.offset) { _, provider in
                    VStack(alignment: .leading) {
                        Text(provider.name)
                        if let endpoint = provider.endpoint { Text(endpoint).font(.caption).textSelection(.enabled) }
                        if let link = provider.privacyURL { Link("服务商隐私政策", destination: link) }
                    }
                }
                Text("分享内容包括你发送的消息、回答、所选照片和文件，以及完成任务所需的历史上下文。工具在服务器上执行，不获得本机的额外系统权限。").font(.footnote)
                if !policy.tools.isEmpty { Text("已启用的服务器工具：" + policy.tools.joined(separator: "、")).font(.footnote) }
                if !policy.serverDeclared { Text("这些名称与地址来自你的服务器配置；代理后面的模型供应商和工具接收方仍需你核实。它们不由客户端维护者指定。").font(.footnote) }
            }
        } else {
            Section("工作空间数据说明") {
                if privacy.loading { ProgressView("正在获取…") }
                Text(privacy.error ?? "连接服务器后可查看运营方及 AI 服务商说明。").font(.subheadline)
            }
        }
    }
}

struct AIConsentView: View {
    @State private var privacy = PrivacyCenter.shared
    @State private var confirmed = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("请先确认数据接收方").font(.headline); Text("确认后再点击发送或重新选择附件。拒绝不会影响查看历史、管理账号或申请删除数据。") }
                PolicySections(privacy: privacy)
                if privacy.policy?.serverDeclared == false {
                    Section("确认你的服务器配置") {
                        Toggle("仅使用自托管本地模型，不转交第三方 AI", isOn: $privacy.localModelsOnly)
                        if !privacy.localModelsOnly { TextField("实际 AI、代理或工具服务商（缺少地址时必填）", text: $privacy.additionalRecipients, axis: .vertical).accessibilityIdentifier("ai-recipient-field") }
                        Text("请核对上方订阅与实际接收方。配置代理时，请确认其后续数据处理方；不要填写 API 密钥。").font(.footnote)
                    }
                }
                NavigationLink("应用隐私说明") { PrivacyPolicyView() }
                Section {
                    Toggle("我已核对接收方，同意将上述数据发送至此服务器及其配置的 AI 和工具", isOn: $confirmed).accessibilityIdentifier("ai-consent-toggle")
                    Button("同意并继续") {
                        do { try privacy.accept(); dismiss() } catch { self.error = error.localizedDescription }
                    }.disabled(!confirmed || privacy.policy == nil).accessibilityIdentifier("ai-consent-accept")
                    Button("暂不同意", role: .cancel) { dismiss() }.accessibilityIdentifier("ai-consent-decline")
                    Button("重新获取服务器说明") { Task { confirmed = false; await privacy.reload() } }.disabled(privacy.loading)
                    if let error { ErrorBanner(text: error) }
                }
            }.navigationTitle("AI 数据分享")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .onChange(of: privacy.policy) { _, _ in confirmed = false }
                .onChange(of: privacy.localModelsOnly) { _, _ in confirmed = false }
                .onChange(of: privacy.additionalRecipients) { _, _ in confirmed = false }
        }
    }
}

private struct PrivacyConsentPresenter: ViewModifier {
    let enabled: Bool
    @State private var privacy = PrivacyCenter.shared
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { enabled && privacy.requestingConsent }, set: { if !$0 { privacy.requestingConsent = false } })) { AIConsentView() }
    }
}
extension View {
    func privacyConsentSheet(enabled: Bool = true) -> some View { modifier(PrivacyConsentPresenter(enabled: enabled)) }
}
