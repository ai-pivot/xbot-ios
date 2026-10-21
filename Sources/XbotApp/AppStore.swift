import SwiftUI

@MainActor @Observable
final class AppStore {
    var api: XbotAPI?
    var sessions: [ChatSession] = []
    var authenticated = false
    var restoring = true
    var loading = false
    var error: String?
    var preview = false
    var selectedTab = 0
    var notifiedSession: ChatSession?
    var validationStatus: String?
    var server = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    var username = UserDefaults.standard.string(forKey: "username") ?? ""
    var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system" {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance") }
    }

    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }

    func restore() async {
        defer { restoring = false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--validate-live") { await LiveValidation.run(self); return }
        #endif
        if ProcessInfo.processInfo.arguments.contains("--preview") { enterPreview(); return }
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "--server"), ProcessInfo.processInfo.arguments.count > i + 1 {
            server = ProcessInfo.processInfo.arguments[i + 1]
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--reset-auth"), let client = try? XbotAPI(server: server) {
            await PrivacyCenter.shared.configure(api: client, username: username); PrivacyCenter.shared.forgetAccount()
            client.clearLocalAuthentication(); username = ""; NotificationController.shared.disable(); return
        }
        #endif
        guard !server.isEmpty else { return }
        do {
            let client = try XbotAPI(server: server)
            guard SecureStore.read("login-privacy-v1:" + client.baseURL.absoluteString + ":" + username) == Data("accepted".utf8) else { return }
            api = client; try await refreshThrowing()
            await PrivacyCenter.shared.configure(api: client, username: username); authenticated = true
            if let active = ClientPreferences.active(server: client.baseURL) { NotificationController.shared.attach(api: client, chat: active) }
        }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    func login(password: String, remember: Bool, register: Bool) async throws {
        let client = try XbotAPI(server: server)
        username = username.trimmingCharacters(in: .whitespaces)
        try SecureStore.write(Data("accepted".utf8), account: "login-privacy-v1:" + client.baseURL.absoluteString + ":" + username)
        try await client.login(username: username, password: password, remember: remember, register: register)
        // Retain the authenticated client even when the first session-list fetch fails.
        api = client; sessions = []; server = client.baseURL.absoluteString
        UserDefaults.standard.set(server, forKey: "serverURL"); UserDefaults.standard.set(username, forKey: "username")
        await PrivacyCenter.shared.configure(api: client, username: username)
        authenticated = true; preview = false; error = nil
        await refresh()
    }

    func refreshThrowing() async throws {
        guard let api else { return }
        let result = try await api.post("/api/session-tree")
        guard self.api === api else { return }
        sessions = (result["sessions"].array + result["orphan_subagents"].array).map(ChatSession.init)
    }
    func refresh() async {
        guard !preview, !loading, let client = api else { return }
        loading = true; defer { loading = false }
        do { try await refreshThrowing(); if api === client { error = nil } }
        catch { if api === client { handle(error) } }
    }
    func handle(_ error: Error) {
        guard !(error is CancellationError) else { return }
        self.error = error.localizedDescription
        if (error as? ServerError)?.unauthorized == true { NotificationController.shared.disable(); authenticated = false; sessions = [] }
    }

    func create(_ label: String, source: ChatSession? = nil) async throws -> ChatSession {
        guard let api, !preview else { throw ServerError("请先连接服务器") }
        let response: JSONValue
        if let source {
            response = try await api.post("/api/chats/fork", ["source_chat_id": .string(source.chatID), "source_channel": .string(source.channel), "label": .string(label)])
        } else { response = try await api.post("/api/chats/create", ["label": .string(label)]) }
        guard !response["chat_id"].string.isEmpty else { throw ServerError("服务端没有返回会话 ID") }
        await refresh()
        return ChatSession(.object(["chat_id": response["chat_id"], "channel": .string(response["channel"].string.nonEmpty ?? source?.channel ?? "web"), "label": .string(label)]))
    }
    func rename(_ chat: ChatSession, label: String) async throws {
        guard let api else { return }
        _ = try await api.post(api.chatPath(chat, action: "rename"), ["label": .string(label)], query: ["channel": chat.channel]); await refresh()
        if ClientPreferences.active(server: api.baseURL)?.id == chat.id {
            var renamed = chat; renamed.title = label
            ClientPreferences.rememberActive(renamed, server: api.baseURL)
            NotificationController.shared.attach(api: api, chat: renamed)
        }
    }
    func delete(_ chat: ChatSession) async throws {
        guard let api else { return }
        _ = try await api.post(api.chatPath(chat, action: "delete"), ["channel": .string(chat.channel)]); await refresh()
        if ClientPreferences.active(server: api.baseURL)?.id == chat.id {
            NotificationController.shared.disable(); ClientPreferences.clearActive(server: api.baseURL)
        }
    }
    func logout() async {
        NotificationController.shared.disable()
        if let api { ClientPreferences.clearActive(server: api.baseURL) }
        if let api { await api.logout() }
        PrivacyCenter.shared.disconnect()
        api = nil; authenticated = false; preview = false; sessions = []; error = nil; notifiedSession = nil; selectedTab = 0
    }
    func forgetAccount() async {
        if let api {
            let origin = api.baseURL.absoluteString
            SecureStore.delete("login-privacy-v1:" + origin + ":" + username)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key == "active:" + origin || key.hasPrefix("notice:" + origin + ":") {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        PrivacyCenter.shared.forgetAccount()
        await logout()
        UserDefaults.standard.removeObject(forKey: "username"); username = ""
    }
    func enterPreview() {
        api = nil; preview = true; authenticated = true; error = nil
        sessions = [ChatSession(.object(["chat_id": .string("preview"), "channel": .string("web"), "label": .string("认识你的工作伙伴"), "preview": .string("从一个想法，到把事情做好。")]))]
    }
    func routeNotification(_ info: [AnyHashable: Any]?) {
        guard let id = info?["chat_id"] as? String, !id.isEmpty,
              let origin = info?["server"] as? String, origin == server,
              PrivacyCenter.shared.blocked[(info?["channel"] as? String ?? "web") + ":" + id] == nil else { return }
        notifiedSession = ChatSession(.object(["chat_id": .string(id), "channel": .string(info?["channel"] as? String ?? "web"), "label": .string("会话")]))
        selectedTab = 0
    }
}
