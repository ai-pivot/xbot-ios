import SwiftUI

struct Attachment: Identifiable {
    let id = UUID()
    let key: String
    let name: String
    let size: Int64
    let mime: String
}

@MainActor @Observable
final class ChatStore {
    let chat: ChatSession
    let api: XbotAPI?
    var state = ChatState()
    var loading = false
    var sending = false
    var uploading = false
    var error: String?
    var connection = "连接中"
    var draft = ""
    var attachments: [Attachment] = []
    var model = "默认模型"
    var models: [JSONValue] = []
    var selectedModel = ""
    var preview: Bool
    private var streamTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var cursor = EventCursor()
    private var generation = UUID()
    private var active = false

    init(chat: ChatSession, api: XbotAPI?, preview: Bool) {
        self.chat = chat; self.api = api; self.preview = preview
        if preview {
            state.loadHistory(.parse(#"{"messages":[{"turn_id":1,"role":"user","content":"你能帮我做什么？"},{"turn_id":1,"role":"assistant","content":"我可以和你一起，把想法变成成果。\n\n**研究问题、编写代码、整理资料**，也可以调用服务器上的工具完成更复杂的任务。\n\n连接你的 xbot 服务器，就可以开始了。","iterations":[{"iteration":1,"reasoning":"先了解目标，再选择合适的工具。","tools":[{"call_id":"preview-tool","name":"工作空间","status":"done","summary":"已准备就绪","elapsed_ms":120}]}]}]}"#)!)
            connection = "界面预览"
        }
    }

    func start() async {
        guard !preview, !active else { return }
        active = true
        if let api {
            ClientPreferences.rememberActive(chat, server: api.baseURL)
            NotificationController.shared.attach(api: api, chat: chat)
        }
        await reload()
        guard active, !Task.isCancelled else { return }
        startStream()
        await loadModels()
    }
    func stop() {
        active = false; generation = UUID(); streamTask?.cancel(); streamTask = nil
        refreshTask?.cancel(); refreshTask = nil; connection = "已暂停"
    }
    func reload(older: Bool = false) async {
        guard let api, !loading, !preview else { return }
        loading = true; defer { loading = false }
        do {
            let result = try await api.history(chat, before: older ? state.oldestID : 0)
            try Task.checkCancellation()
            state.loadHistory(result, prepend: older)
            if !older { cursor = EventCursor(sequence: result["last_seq"].int) }
            error = nil
            if !older {
                let pending = try await api.rpc("get_pending_ask_user", api.context(chat))
                try Task.checkCancellation()
                if !pending.isNull { state.apply(.object(["type": .string("ask_user"), "progress": pending])) }
            }
        } catch { report(error) }
    }

    private func startStream() {
        guard let api else { return }
        streamTask?.cancel()
        let token = UUID(); generation = token
        streamTask = Task { [weak self] in
            var attempt = 0
            var reauthenticated = false
            while !Task.isCancelled {
                guard let self, self.active, self.generation == token else { return }
                self.connection = attempt == 0 ? "连接中" : "正在重连"
                do {
                    var request = URLRequest(url: try api.requestURL("/api/sse", query: ["chat_id": self.chat.chatID, "channel": self.chat.channel]))
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if self.cursor.sequence > 0 { request.setValue(String(self.cursor.sequence), forHTTPHeaderField: "Last-Event-ID") }
                    let (bytes, response) = try await api.session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ServerError("实时连接响应无效") }
                    if http.statusCode == 401 {
                        if reauthenticated { throw ServerError("登录已失效，请重新登录", unauthorized: true) }
                        try await api.silentLogin(); reauthenticated = true; continue
                    }
                    guard http.statusCode == 200, http.mimeType == "text/event-stream" else { throw ServerError("实时连接失败（HTTP \(http.statusCode)）") }
                    self.connection = "已连接"
                    self.error = nil; reauthenticated = false
                    var parser = SSEByteParser()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard self.generation == token else { return }
                        // Any byte activity, including heartbeat comments, proves liveness.
                        attempt = 0
                        guard let frame = parser.consume(byte), frame.event != "heartbeat" else { continue }
                        guard var object = JSONValue.parse(frame.data)?.object else { continue }
                        if object["type"]?.string.isEmpty != false { object["type"] = .string(frame.event) }
                        let event = JSONValue.object(object)
                        guard self.cursor.accept(event, frameID: frame.id, chatID: self.chat.chatID, channel: self.chat.channel) else { continue }
                        self.state.apply(event)
                        if self.state.needsReload {
                            self.connection = "同步中"
                            self.refreshTask?.cancel()
                            self.refreshTask = Task { [weak self] in
                                guard let self else { return }
                                self.streamTask?.cancel()
                                await self.reload()
                                if self.active && !Task.isCancelled { self.startStream() }
                            }
                            return
                        }
                    }
                } catch {
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.report(error)
                    if (error as? ServerError)?.unauthorized == true { self.connection = "需要重新登录"; return }
                }
                guard !Task.isCancelled else { return }
                self.connection = "正在重连"
                let delay = min(30.0, pow(2.0, Double(min(attempt, 5)))) + Double.random(in: 0...0.5)
                attempt += 1
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    func send() async {
        guard let api, !preview, !sending, !uploading, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines), files = attachments
        sending = true; defer { sending = false }
        do {
            var body = api.context(chat)
            body["content"] = .string(text); body["type"] = .string("message"); body["id"] = .string(UUID().uuidString)
            body["upload_keys"] = .array(files.map { .string($0.key) }); body["file_names"] = .array(files.map { .string($0.name) })
            body["file_sizes"] = .array(files.map { .number(Double($0.size)) }); body["file_mimes"] = .array(files.map { .string($0.mime) })
            let response = try await api.post("/api/message", body)
            state.accepted(text: text.isEmpty ? "（附件）" : text, response: response)
            // Preserve anything typed during the request.
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
            attachments.removeAll { attachment in files.contains { $0.id == attachment.id } }
            error = nil
            if state.needsReload { await reload() }
        } catch { report(error) }
    }
    func cancel() async {
        guard let api else { return }
        do { _ = try await api.post("/api/cancel", api.context(chat)) } catch { report(error) }
    }
    func answer(_ answers: [String: String], cancelled: Bool) async -> Bool {
        guard let api else { return false }
        do {
            var body = api.context(chat); body["answers"] = .object(answers.mapValues(JSONValue.string)); body["cancelled"] = .bool(cancelled)
            _ = try await api.post("/api/ask_user/respond", body); state.ask = nil; error = nil; return true
        } catch { report(error); return false }
    }
    func upload(data: Data, name: String, mime: String) async {
        guard let api, !preview, !uploading else { return }
        uploading = true; defer { uploading = false }
        do {
            let result = try await api.upload(data, name: name, mime: mime)
            guard !result["upload_key"].string.isEmpty else { throw ServerError("上传结果没有文件标识") }
            attachments.append(Attachment(key: result["upload_key"].string, name: result["name"].string.nonEmpty ?? name,
                                          size: result["size"].int > 0 ? result["size"].int : Int64(data.count), mime: result["mime"].string.nonEmpty ?? mime))
            error = nil
        } catch { report(error) }
    }
    func rewind(_ turn: ChatTurn) async {
        guard let api, turn.historyID > 0 else { return }
        do {
            var body = api.context(chat); body["history_id"] = .number(Double(turn.historyID))
            let response = try await api.post("/api/history/rewind", body)
            if !response["draft"].string.isEmpty { draft = response["draft"].string }
            else { draft = turn.user }
            stop(); await start()
            if !response["checkpoint_error"].string.isEmpty { error = "历史已回退，文件恢复未完成：" + response["checkpoint_error"].string }
        } catch { report(error) }
    }
    func loadModels() async {
        guard let api else { return }
        do {
            models = try await api.rpc("list_all_model_entries").array
            var current = try await api.rpc("get_session_subscription", api.context(chat))
            if current["model"].string.isEmpty {
                let fallback = try await api.rpc("get_default_model")
                current = .object(["subscription_id": fallback["sub_id"], "model": fallback["model"]])
            }
            model = current["model"].string.nonEmpty ?? "默认模型"
            selectedModel = current["subscription_id"].string + ":" + current["model"].string
        } catch { report(error) }
    }
    func selectModel(_ entry: JSONValue) async {
        guard let api else { return }
        do {
            var params = api.context(chat); params["sub_id"] = entry["sub_id"]; params["model"] = entry["model"]
            _ = try await api.rpc("select_model", params); await loadModels()
        } catch { report(error) }
    }
    private func report(_ error: Error) { if !(error is CancellationError) { self.error = error.localizedDescription } }
}
