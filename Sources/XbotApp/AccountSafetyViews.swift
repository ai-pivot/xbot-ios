import SwiftUI

struct AccountDeletionView: View {
    @Environment(AppStore.self) private var store
    @State private var password = ""
    @State private var confirmation = ""
    @State private var submitting = false
    @State private var error: String?
    @State private var receipt: JSONValue?
    @State private var requestID = UUID().uuidString
    var body: some View {
        Form {
            Section("删除账号及关联数据") {
                Text("删除将涉及服务器上的账号、聊天、附件及关联记录。操作不可撤销；法律要求保留的部分以服务器隐私政策为准。")
                Text("请求由服务器运营方处理，提交成功后会显示回执及期限。受理期间请勿继续提交新任务。")
                if let policy = PrivacyCenter.shared.policy, policy.serverDeclared { Link("查看服务器隐私与保留规则", destination: policy.privacyURL) }
                Text("这是你的自托管服务器账号。本应用维护者不持有该账号；旧版服务器若没有删除接口，需由你或管理员在服务器端执行删除。清除本机数据不会删除远端内容。").font(.footnote)
            }
            if let receipt {
                Section("服务器回执") {
                    Text(receipt["status"].string == "deleted" ? "服务器已确认完成删除" : "删除申请已受理，尚待完成").font(.headline).accessibilityIdentifier("deletion-receipt-status")
                    LabeledContent("申请编号", value: receipt["id"].string).textSelection(.enabled)
                    if receipt["status"].string != "deleted" { LabeledContent("处理期限", value: receipt["deadline"].string) }
                    if receipt["status"].string != "deleted" {
                        Button("查询处理状态") { Task { await refreshReceipt() } }.disabled(submitting)
                    }
                    Text("请保留申请编号。你可以退出并清除此设备保存的账号数据。")
                    Button("退出并清除此设备的账号数据", role: .destructive) { Task { await store.forgetAccount() } }
                }
            } else {
                Section {
                    LabeledContent("当前账号", value: store.username)
                    SecureField("重新输入当前账号密码", text: $password).textContentType(.password).accessibilityIdentifier("delete-account-password")
                    TextField("输入“删除账号”确认", text: $confirmation).accessibilityIdentifier("delete-account-confirmation")
                    Button("申请删除账号和关联数据", role: .destructive) { Task { await submit() } }
                        .disabled(password.isEmpty || confirmation != "删除账号" || submitting).accessibilityIdentifier("delete-account-submit")
                    if submitting { ProgressView("正在向服务器提交…") }
                }
            }
            if let error { ErrorBanner(text: error) }
        }.navigationTitle("删除账号").navigationBarTitleDisplayMode(.inline)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
    }
    private func submit() async {
        guard let api = store.api else { return }
        submitting = true; defer { submitting = false }; error = nil
        do {
            let value = try await api.post("/api/mobile/account-deletion", ["username": .string(store.username), "password": .string(password), "request_id": .string(requestID)], retry: false)
            guard !value["id"].string.isEmpty, ["pending", "deleted"].contains(value["status"].string),
                  value["status"].string == "deleted" || !value["deadline"].string.isEmpty else { throw ServerError("服务器未返回有效的删除回执，尚未确认受理") }
            receipt = value; password = ""; NotificationController.shared.disable(); PrivacyCenter.shared.revoke()
        } catch { self.error = "未确认删除申请已受理：" + error.localizedDescription }
    }
    private func refreshReceipt() async {
        guard let api = store.api, let receipt else { return }
        submitting = true; defer { submitting = false }; error = nil
        do {
            let value = try await api.post("/api/mobile/status", ["id": receipt["id"]], retry: false)
            guard value["id"] == receipt["id"], ["pending", "deleted"].contains(value["status"].string) else { throw ServerError("服务器状态无效") }
            self.receipt = value
        } catch { self.error = "暂时无法确认处理状态：" + error.localizedDescription }
    }
}

struct ContentReportView: View {
    let api: XbotAPI?
    let chat: ChatSession
    let turn: ChatTurn?
    @State private var reason = "不当或有害内容"
    @State private var detail = ""
    @State private var includeContent = false
    @State private var blockChat = true
    @State private var submitting = false
    @State private var receipt: String?
    @State private var error: String?
    @State private var requestID = UUID().uuidString
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("举报原因", selection: $reason) { ForEach(["不当或有害内容", "侵犯隐私或非自愿私密影像", "涉及未成年人安全", "骚扰或仇恨", "其他"], id: \.self) { Text($0) } }
                    TextField("补充说明（可选，请勿填写敏感信息）", text: $detail, axis: .vertical).lineLimit(3...6)
                    Toggle("附上这条回答正文供运营方核查", isOn: $includeContent).disabled(turn == nil)
                    Toggle("同时屏蔽此会话", isOn: $blockChat)
                    Text("默认仅向当前服务器的运营方发送会话标识、轮次和举报原因。附带正文需你单独同意；不会公开发布到 GitHub。").font(.footnote)
                    if let policy = PrivacyCenter.shared.policy, policy.serverDeclared { Link("联系服务器运营方", destination: policy.supportURL) }
                }
                if let receipt {
                    Section { Label("举报已受理", systemImage: "checkmark.circle"); Text("回执：" + receipt).textSelection(.enabled); Button("完成") { dismiss() } }
                } else {
                    Button("提交举报") { Task { await submit() } }.disabled(submitting || api == nil).accessibilityIdentifier("report-submit")
                    if submitting { ProgressView() }
                    Section {
                        ShareLink("导出举报给自托管管理员", item: exportText)
                        Text("旧版服务器未提供举报接口时，可通过你自己的渠道把此文件交给管理员。导出不表示服务器已受理。").font(.footnote)
                    }
                }
                if let error { ErrorBanner(text: error) }
            }.navigationTitle("举报内容")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
    private var exportText: String {
        var lines = ["xbot 内容举报", "服务器：" + (api?.baseURL.absoluteString ?? ""), "会话：" + chat.chatID, "通道：" + chat.channel, "轮次：\(turn?.id ?? 0)", "原因：" + reason, "说明：" + String(detail.prefix(1000))]
        if includeContent, let turn { lines.append("已同意附带正文：\n" + String((turn.final.nonEmpty ?? turn.iterations.map(\.content).joined(separator: "\n")).prefix(8000))) }
        return lines.joined(separator: "\n")
    }
    private func submit() async {
        guard let api else { return }
        submitting = true; defer { submitting = false }; error = nil
        do {
            var body = api.context(chat)
            body["request_id"] = .string(requestID); body["turn_id"] = .number(Double(turn?.id ?? 0))
            body["reason"] = .string(reason); body["detail"] = .string(String(detail.prefix(1000)))
            if includeContent, let turn { body["content"] = .string(String((turn.final.nonEmpty ?? turn.iterations.map(\.content).joined(separator: "\n")).prefix(8000))) }
            let value = try await api.post("/api/mobile/reports", body, retry: false)
            guard !value["id"].string.isEmpty, value["status"].string == "received" else { throw ServerError("服务器未返回有效举报回执") }
            receipt = value["id"].string
            if blockChat {
                do { try PrivacyCenter.shared.block(chat) }
                catch { self.error = "举报已受理，但本机屏蔽未保存：" + error.localizedDescription }
            }
        } catch { self.error = "未确认举报已受理：" + error.localizedDescription }
    }
}
