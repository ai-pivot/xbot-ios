import SwiftUI

struct LoginView: View {
    @Environment(AppStore.self) private var store
    @State private var password = ""
    @State private var remember = true
    @State private var bootstrap = false
    @State private var checkedServer = ""
    @State private var loading = false
    @State private var checking = false
    @State private var error: String?
    @State private var hint: String?
    @State private var privacyAccepted = false
    @FocusState private var focusedField: Field?
    private var testing: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        false
        #endif
    }
    private enum Field: Hashable { case server, username, password }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack { BrandMark(); Text("xbot").font(.system(size: 28, weight: .bold, design: .rounded)); Spacer(); Text("FOR iOS").font(.caption.monospaced()).foregroundStyle(.secondary) }
                        .padding(.top, 24)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("想法，在这里\n开始行动。").font(.system(size: 38, weight: .bold)).tracking(-1)
                        Text("连接你的 xbot 工作空间，让 AI 陪你把事情做好。")
                            .font(.body).foregroundStyle(.secondary).lineSpacing(5)
                    }.padding(.vertical, 12)
                    VStack(alignment: .leading, spacing: 18) {
                        Text("连接工作空间").font(.headline)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("服务器地址").font(.subheadline).foregroundStyle(.secondary)
                            TextField("https://xbot.example.com", text: $store.server)
                                .focused($focusedField, equals: .server)
                                .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier("server-field")
                                .onChange(of: store.server) { _, _ in bootstrap = false; checkedServer = ""; hint = nil; privacyAccepted = false }
                            Divider()
                            Button { Task { await probe() } } label: {
                                HStack { Text("检查服务器"); Spacer(); if checking { ProgressView() } else { Image(systemName: "arrow.up.right") } }
                            }.font(.subheadline).disabled(checking || loading || store.server.isEmpty)
                        }
                        labeledField("用户名") { TextField("你的用户名", text: $store.username).textContentType(testing ? .none : .username).focused($focusedField, equals: .username).accessibilityIdentifier("username-field") }
                        labeledField("密码") { SecureField("输入密码", text: $password).textContentType(testing ? .none : bootstrap ? .newPassword : .password).focused($focusedField, equals: .password).accessibilityIdentifier("password-field") }
                        Toggle("安全记住登录信息", isOn: $remember).font(.subheadline)
                        NavigationLink("隐私说明与数据去向") { PrivacyPolicyView() }.font(.subheadline)
                        Toggle("我已阅读隐私说明，同意将登录信息发送至我指定的服务器", isOn: $privacyAccepted).font(.footnote).accessibilityIdentifier("login-privacy-toggle")
                        if let hint { Text(hint).font(.footnote).foregroundStyle(Theme.accent) }
                        if let error = error ?? store.error { ErrorBanner(text: error) { self.error = nil; store.error = nil } }
                        Button {
                            Task { await submit() }
                        } label: {
                            HStack { Spacer(); if loading { ProgressView().tint(.white) }; Text(bootstrap ? "创建首个管理员账号" : "连接并登录").fontWeight(.semibold); Image(systemName: "arrow.right"); Spacer() }.padding(.vertical, 10)
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(loading || checking)
                            .accessibilityIdentifier("login-button")
                    }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(22).background(Theme.card, in: RoundedRectangle(cornerRadius: 24))
                    VStack(spacing: 14) {
                        Label("登录凭据保存在此设备的钥匙串中", systemImage: "lock.shield")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("先看看界面") { store.enterPreview() }.font(.subheadline)
                            .accessibilityIdentifier("preview-button")
                    }.frame(maxWidth: .infinity)
                }.padding(24).frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }.background(Theme.canvas).scrollDismissesKeyboard(.interactively)
                .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成") { focusedField = nil }.accessibilityIdentifier("dismiss-login-keyboard") } }
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { Text(title).font(.subheadline).foregroundStyle(.secondary); content(); Divider() }
    }
    private func probe() async {
        checking = true; defer { checking = false }
        error = nil; hint = nil
        do {
            let client = try XbotAPI(server: store.server)
            let config = try await client.post("/api/auth/config", retry: false)
            checkedServer = store.server; bootstrap = config["bootstrap"].bool
            hint = bootstrap ? "这是新服务器，首个账号将成为管理员。" : "服务器已就绪，请使用已有账号登录。"
        } catch { self.error = error.localizedDescription }
    }
    private func submit() async {
        focusedField = nil
        guard !store.username.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else { error = "请填写用户名和密码"; return }
        guard privacyAccepted else { error = "请先阅读隐私说明并确认登录信息的接收服务器"; return }
        loading = true; defer { loading = false }; error = nil
        do {
            // Discover bootstrap even if the user skipped the check button.
            if checkedServer != store.server {
                let client = try XbotAPI(server: store.server)
                let config = try await client.post("/api/auth/config", retry: false)
                checkedServer = store.server; bootstrap = config["bootstrap"].bool
                if bootstrap { hint = "这是新服务器，再次点击按钮可创建首个管理员账号。"; return }
            }
            try await store.login(password: password, remember: remember, register: bootstrap)
            password = ""
        } catch { self.error = error.localizedDescription }
    }
}
