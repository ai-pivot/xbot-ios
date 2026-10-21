#if DEBUG
import SwiftUI

/// Debug-only native integration harness. Credentials are read once from a
/// simulator sandbox file, removed immediately, and never included in reports.
@MainActor
enum LiveValidation {
    static func run(_ store: AppStore) async {
        let directory = URL.documentsDirectory
        let input = directory.appendingPathComponent("live-validation.json")
        let reportURL = directory.appendingPathComponent("native-validation-report.json")
        var steps: [String] = [], current = "configuration"
        var api: XbotAPI?, chatStore: ChatStore?
        var created: [ChatSession] = []
        func mark(_ name: String) { current = name; store.validationStatus = "真实接口验证中 · " + name }
        func require(_ condition: Bool) throws { if !condition { throw ServerError("Native validation assertion failed") } }
        var passed = false, failureKind = ""
        NotificationController.shared.disable()
        do {
            let data = try Data(contentsOf: input)
            try FileManager.default.removeItem(at: input)
            let config = try JSONDecoder().decode(JSONValue.self, from: data)
            let client = try XbotAPI(server: config["server"].string); api = client
            mark("login")
            try await client.login(username: config["username"].string, password: config["password"].string, remember: true)
            _ = try await client.post("/api/session-tree"); steps.append(current)
            mark("401_relogin")
            _ = try await client.post("/api/auth/logout", retry: false)
            _ = try await client.post("/api/session-tree"); steps.append(current)
            mark("settings_read_write")
            let thinking = try await client.rpc("get_user_thinking_mode")
            let context = try await client.rpc("get_context_mode")
            let agent = try await client.rpc("get_settings", ["namespace": .string("agent")])
            let threshold = Double(agent["compression_threshold"].string.nonEmpty ?? agent["compression_threshold"].display)
            try require(threshold != nil)
            // Write existing values only: exercise the contract without changing
            // settings that could affect this account's other sessions.
            _ = try await client.rpc("set_user_thinking_mode", ["mode": .string(ThinkingMode.wire(ThinkingMode.display(thinking.string)))])
            _ = try await client.rpc("set_context_mode", ["mode": context])
            _ = try await client.rpc("set_compression_threshold", ["threshold": .number(threshold!)])
            for (read, write, key) in [("get_user_max_output_tokens", "set_user_max_output_tokens", "max_tokens"), ("get_user_max_context", "set_user_max_context", "max_context"), ("get_llm_concurrency", "set_llm_concurrency", "personal")] {
                let original = try await client.rpc(read); _ = try await client.rpc(write, [key: original])
            }
            let models = try await client.rpc("list_all_model_entries").array
            let subscriptions = try await client.rpc("list_subscriptions").array
            let tools = try await client.rpc("get_tools_settings")["tools"].array
            try require(!models.isEmpty)
            if let tool = tools.first { _ = try await client.rpc("set_tool_enabled", ["name": tool["name"], "enabled": .bool(tool["enabled"] != .bool(false))]) }
            if let sub = subscriptions.first { _ = try await client.rpc("set_subscription_enabled", ["sub_id": sub["id"], "enabled": .bool(sub["enabled"] != .bool(false))]) }
            if let model = models.first { _ = try await client.rpc("set_model_enabled", ["sub_id": model["sub_id"], "model": model["model"], "enabled": .bool(model["status"].string != "disabled")]) }
            steps.append(current)
            mark("session_create_rename")
            let label = "iOS 兼容验收 " + String(UUID().uuidString.prefix(8))
            let response = try await client.post("/api/chats/create", ["label": .string(label)])
            try require(!response["chat_id"].string.isEmpty)
            let chat = ChatSession(.object(["chat_id": response["chat_id"], "channel": .string("web"), "label": .string(label)])); created.append(chat)
            _ = try await client.post(client.chatPath(chat, action: "rename"), ["label": .string(label + " · renamed")], query: ["channel": chat.channel])
            let tree = try await client.post("/api/session-tree")
            try require(tree["sessions"].array.contains { $0["chat_id"].string == chat.chatID && $0["label"].string.hasSuffix("renamed") }); steps.append(current)
            mark("model_select")
            let defaultModel = try await client.rpc("get_default_model")
            var selected = client.context(chat); selected["sub_id"] = defaultModel["sub_id"]; selected["model"] = defaultModel["model"]
            _ = try await client.rpc("select_model", selected)
            let currentModel = try await client.rpc("get_session_subscription", client.context(chat))
            try require(currentModel["model"] == defaultModel["model"]); steps.append(current)
            mark("upload_download")
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
            let png = renderer.pngData { ctx in UIColor.systemGreen.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16)) }
            let upload = try await client.upload(png, name: "ios-validation.png", mime: "image/png")
            try require(!upload["upload_key"].string.isEmpty)
            let download = try await client.mediaData(client.requestURL("/api/files/download", query: ["key": upload["upload_key"].string, "inline": "1"]))
            try require(UIImage(data: download) != nil); steps.append(current)
            mark("message_sse_history")
            let vm = ChatStore(chat: chat, api: client, preview: false); chatStore = vm
            await vm.start()
            vm.draft = "这是 iOS 客户端兼容性测试。请只回复 IOS_OK，不要调用任何工具。"
            await vm.send()
            try require(vm.error == nil)
            let deadline = Date(timeIntervalSinceNow: 120)
            while Date() < deadline {
                let hasResult = vm.state.turns.contains { !$0.final.isEmpty || !$0.iterations.compactMap { $0.content.nonEmpty }.isEmpty }
                if hasResult && !vm.state.busy { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            try require(!vm.state.busy && vm.state.turns.contains { !$0.final.isEmpty || $0.iterations.contains { !$0.content.isEmpty } })
            vm.stop(); await vm.start()
            try require(vm.state.turns.contains { $0.historyID > 0 && !$0.user.isEmpty }); steps.append(current)
            mark("session_fork")
            let fork = try await client.post("/api/chats/fork", ["source_chat_id": .string(chat.chatID), "source_channel": .string(chat.channel), "label": .string(label + " · fork")])
            try require(!fork["chat_id"].string.isEmpty)
            let forkChat = ChatSession(.object(["chat_id": fork["chat_id"], "channel": .string(fork["channel"].string.nonEmpty ?? "web"), "label": .string("fork")]))
            created.append(forkChat)
            let forkHistory = try await client.history(forkChat); try require(!forkHistory["messages"].array.isEmpty); steps.append(current)
            mark("cancel")
            vm.draft = "这是取消生成接口的测试，请只回复 IOS_CANCEL_TEST。"
            await vm.send(); await vm.cancel()
            let cancelDeadline = Date(timeIntervalSinceNow: 30)
            while vm.state.busy && Date() < cancelDeadline { try await Task.sleep(for: .milliseconds(250)) }
            try require(!vm.state.busy); steps.append(current)
            mark("rewind_draft")
            vm.stop(); await vm.start()
            guard let target = vm.state.turns.first(where: { $0.historyID > 0 && !$0.user.isEmpty }) else { throw ServerError("Missing persisted rewind target") }
            await vm.rewind(target)
            try require(vm.error == nil && vm.draft == target.user); steps.append(current)
            passed = true
        } catch { failureKind = String(reflecting: type(of: error)) }
        chatStore?.stop()
        if let api {
            for chat in created.reversed() {
                do { _ = try await api.post(api.chatPath(chat, action: "delete"), ["channel": .string(chat.channel)]) }
                catch { passed = false; failureKind = "cleanup_failed" }
            }
            await api.logout()
        }
        NotificationController.shared.disable()
        try? FileManager.default.removeItem(at: input)
        let report: [String: JSONValue] = ["passed": .bool(passed), "steps": .array(steps.map(JSONValue.string)), "last_step": .string(current), "failure_kind": .string(failureKind), "cleanup_attempted": .bool(true)]
        try? JSONEncoder().encode(JSONValue.object(report)).write(to: reportURL, options: .atomic)
        store.validationStatus = passed ? "真实接口验证通过" : "真实接口验证失败 · " + current
    }
}
#endif
