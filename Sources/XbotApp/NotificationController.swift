import SwiftUI
import UserNotifications
@preconcurrency import BackgroundTasks
import CryptoKit

extension Notification.Name { static let openXbotChat = Notification.Name("dev.xbot.openChat") }

/// iOS equivalent of the Android foreground-service observer: finite background
/// execution plus scheduled refresh. APNs delivery is handled by the OS when configured.
@MainActor @Observable
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationController()
    static let refreshIdentifier = "dev.xbot.ios.refresh"
    private(set) var enabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
    private(set) var status = "未开启"
    private(set) var pushStatus = "系统推送未配置"
    private(set) var refreshStatus = "尚未申请后台刷新"
    var error: String?
    private(set) var deliveredCount = 0
    private var api: XbotAPI?
    private var chat: ChatSession?
    private var monitor: Task<Void, Never>?
    private var generation = UUID()
    private var cursor = EventCursor()
    private var snapshot = NotificationSnapshot()
    private var foreground = true
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var snapshotKey: String { "notice:" + (api?.baseURL.absoluteString ?? "") + ":" + (chat?.id ?? "") }
    var hasPushConfiguration: Bool { (Bundle.main.object(forInfoDictionaryKey: "XbotPushEnabled") as? String)?.uppercased() == "YES" }
    override init() { super.init(); UNUserNotificationCenter.current().delegate = self }

    func setEnabled(_ value: Bool, api: XbotAPI?) async {
        error = nil
        if !value { disable(); return }
        guard let api, let chat = ClientPreferences.active(server: api.baseURL) else { error = "请先打开一个会话，再开启通知"; return }
        do {
            guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else { throw ServerError("通知权限被拒绝，请在系统设置中允许通知") }
            enabled = true; UserDefaults.standard.set(true, forKey: "notificationsEnabled")
            attach(api: api, chat: chat)
            if hasPushConfiguration { UIApplication.shared.registerForRemoteNotifications() }
            scheduleRefresh()
        } catch { self.error = error.localizedDescription }
    }
    func attach(api: XbotAPI, chat: ChatSession) {
        if self.api === api && self.chat?.id == chat.id {
            self.chat = chat
            if enabled && monitor == nil { start() }; PushRelayController.shared.bind(api: api, chat: chat); return
        }
        stopStream(); self.api = api; self.chat = chat
        cursor = EventCursor(sequence: Int64(UserDefaults.standard.integer(forKey: snapshotKey + ":seq")))
        snapshot = UserDefaults.standard.data(forKey: snapshotKey).flatMap { try? JSONDecoder().decode(NotificationSnapshot.self, from: $0) } ?? NotificationSnapshot()
        if enabled { start(); PushRelayController.shared.bind(api: api, chat: chat); if hasPushConfiguration { UIApplication.shared.registerForRemoteNotifications() } }
    }
    func disable() {
        PushRelayController.shared.disconnect()
        if hasPushConfiguration { UIApplication.shared.unregisterForRemoteNotifications() }
        enabled = false; UserDefaults.standard.set(false, forKey: "notificationsEnabled")
        stopStream(); endBackgroundTime(); status = "未开启"; api = nil; chat = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    func visibility(_ phase: ScenePhase) {
        if phase == .active {
            foreground = true; endBackgroundTime()
            Task { deliveredCount = await UNUserNotificationCenter.current().deliveredNotifications().count }
            if enabled && monitor == nil { start() }
        } else if phase == .inactive {
            if enabled && backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "xbot session notifications") { [weak self] in
                    Task { @MainActor in self?.stopStream(); self?.endBackgroundTime(); self?.status = "实时连接已暂停，等待系统后台刷新" }
                }
            }
        } else {
            foreground = false
            if enabled { scheduleRefresh() }
        }
    }
    private func endBackgroundTime() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    private func stopStream() { generation = UUID(); monitor?.cancel(); monitor = nil }
    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(snapshot), forKey: snapshotKey)
        UserDefaults.standard.set(cursor.sequence, forKey: snapshotKey + ":seq")
    }
    private func start() {
        guard enabled, let api, let chat else { return }
        stopStream(); let token = UUID(); generation = token
        monitor = Task { [weak self] in
            guard let self else { return }
            await self.refreshInBackground()
            var attempt = 0, relogged = false
            while !Task.isCancelled && self.enabled && token == self.generation {
                do {
                    var request = URLRequest(url: try api.requestURL("/api/sse", query: ["chat_id": chat.chatID, "channel": chat.channel]))
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if self.cursor.sequence > 0 { request.setValue(String(self.cursor.sequence), forHTTPHeaderField: "Last-Event-ID") }
                    let (bytes, response) = try await api.session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse else { throw ServerError("通知连接响应无效") }
                    if response.statusCode == 401 && !relogged { try await api.silentLogin(); relogged = true; continue }
                    guard response.statusCode == 200 && response.mimeType == "text/event-stream" else { throw ServerError("通知连接失败（HTTP \(response.statusCode)）", unauthorized: response.statusCode == 401) }
                    self.status = "正在监听当前会话"; attempt = 0; relogged = false
                    var parser = SSEByteParser()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard token == self.generation else { return }
                        guard let frame = parser.consume(byte), let value = JSONValue.parse(frame.data) else { continue }
                        var object = value.object
                        if object["type"]?.string.isEmpty != false { object["type"] = .string(frame.event) }
                        let event = JSONValue.object(object)
                        guard self.cursor.accept(event, frameID: frame.id, chatID: chat.chatID, channel: chat.channel) else { continue }
                        await self.receive(event, chat: chat)
                        self.persist()
                    }
                } catch {
                    if Task.isCancelled || token != self.generation { return }
                    self.status = "通知连接中断，正在重试"
                    if (error as? ServerError)?.unauthorized == true { self.error = "通知登录已失效，请重新登录"; return }
                }
                do { try await Task.sleep(for: .seconds(min(30, pow(2, Double(min(attempt, 5)))))); attempt += 1 } catch { return }
            }
        }
    }
    private func receive(_ event: JSONValue, chat: ChatSession) async {
        switch event["type"].string {
        case "text":
            let turn = event["turn_id"].int
            if (turn == 0 || turn > snapshot.lastAssistantTurn || snapshot.wasBusy) && !event["cancelled"].bool && !event["interrupted"].bool && !event["content"].string.isEmpty {
                await deliver(SessionNotice(kind: .completed, body: event["content"].string), chat: chat, key: "turn-\(turn)-\(cursor.sequence)")
            }
            snapshot.lastAssistantTurn = max(snapshot.lastAssistantTurn, turn); snapshot.wasBusy = false
        case "ask_user":
            var state = ChatState(); state.apply(event)
            if let prompt = state.ask {
                let id = prompt.id.nonEmpty ?? prompt.questions.first?.question ?? "ask"
                if id != snapshot.lastQuestion { await deliver(SessionNotice(kind: .question, body: prompt.questions.first?.question ?? "Agent 需要你的回答"), chat: chat, key: "ask-" + id) }
                snapshot.lastQuestion = id
            }
        case "ask_user_resolved": snapshot.lastQuestion = ""
        case "resync_required": await refreshInBackground()
        default: break
        }
    }
    private func deliver(_ notice: SessionNotice, chat: ChatSession, key: String) async {
        guard enabled && !foreground && !PushRelayController.shared.registered else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.kind == .question ? "xbot 需要你的回答" : "xbot 已完成"
        content.subtitle = chat.title; content.body = String(notice.body.prefix(240)); content.sound = .default
        content.userInfo = ["chat_id": chat.chatID, "channel": chat.channel, "server": api?.baseURL.absoluteString ?? ""]
        let identity = snapshotKey + ":" + notice.kind.rawValue + ":" + key
        let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) }
        catch { self.error = "无法显示通知：" + error.localizedDescription }
    }
    @discardableResult func refreshInBackground() async -> Bool {
        guard enabled else { return true }
        do {
            if api == nil {
                guard let server = UserDefaults.standard.string(forKey: "serverURL") else { return false }
                let client = try XbotAPI(server: server)
                guard let active = ClientPreferences.active(server: client.baseURL) else { return false }
                self.api = client; self.chat = active
                cursor = EventCursor(sequence: Int64(UserDefaults.standard.integer(forKey: snapshotKey + ":seq")))
                snapshot = UserDefaults.standard.data(forKey: snapshotKey).flatMap { try? JSONDecoder().decode(NotificationSnapshot.self, from: $0) } ?? NotificationSnapshot()
            }
            guard let api, let chat else { return false }
            let history = try await api.history(chat)
            let pending = try await api.rpc("get_pending_ask_user", api.context(chat))
            try Task.checkCancellation()
            guard self.api === api && self.chat?.id == chat.id else { return false }
            let notices = snapshot.reconcile(history: history, pending: pending, reset: history["last_seq"].int < cursor.sequence)
            cursor.sequence = history["last_seq"].int
            for notice in notices { await deliver(notice, chat: chat, key: "snapshot-\(snapshot.lastAssistantTurn)-\(snapshot.lastQuestion)") }
            persist(); return true
        } catch { if !Task.isCancelled { self.error = "后台同步失败：" + error.localizedDescription }; return false }
    }
    func scheduleRefresh() {
        guard enabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(request); refreshStatus = "已申请，时间由系统决定" }
        catch { refreshStatus = "系统暂不允许后台刷新" }
    }
    func handle(_ task: BGAppRefreshTask) {
        foreground = false
        let work = Task { let success = await refreshInBackground(); task.setTaskCompleted(success: success); scheduleRefresh() }
        task.expirationHandler = { work.cancel() }
    }
    func recordPushToken(_ token: Data) {
        do {
            try SecureStore.write(token, account: "apns-device-token"); pushStatus = "设备已注册"
            if let api, let chat { PushRelayController.shared.bind(api: api, chat: chat) }
        }
        catch { pushStatus = "无法保存设备推送标识" }
    }
    func pushRegistrationFailed() { pushStatus = "系统推送注册失败，请检查签名与网络" }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let route = ["chat_id": info["chat_id"] as? String ?? "", "channel": info["channel"] as? String ?? "web", "server": info["server"] as? String ?? ""]
        await MainActor.run { NotificationCenter.default.post(name: .openXbotChat, object: nil, userInfo: route) }
    }
}

final class XbotAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = NotificationController.shared
        BGTaskScheduler.shared.register(forTaskWithIdentifier: NotificationController.refreshIdentifier, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { NotificationController.shared.handle(refresh) }
        }
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) { NotificationController.shared.recordPushToken(deviceToken) }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) { NotificationController.shared.pushRegistrationFailed() }
}

struct NotificationSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var notifications = NotificationController.shared
    @State private var requesting = false
    var body: some View {
        Form {
            Section {
                Toggle("后台会话通知", isOn: Binding(get: { notifications.enabled }, set: { value in
                    requesting = true; Task { await notifications.setEnabled(value, api: store.api); requesting = false }
                })).disabled(requesting).accessibilityIdentifier("notifications-toggle")
                LabeledContent("状态", value: notifications.enabled ? notifications.status : "未开启")
                LabeledContent("后台刷新", value: notifications.refreshStatus).font(.caption)
                Text("已投递提醒：\(notifications.deliveredCount)").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("delivered-notification-count")
                if let api = store.api, let chat = ClientPreferences.active(server: api.baseURL) { LabeledContent("当前会话", value: chat.title) }
            } footer: { Text("提醒当前会话的完成与 Agent 提问。iOS 会限制后台连接时长；连接暂停后，由系统决定后台刷新时间，提醒可能延迟。") }
            Section("系统推送") {
                Text(notifications.pushStatus).font(.subheadline)
                NavigationLink("配置推送桥接") { PushRelaySettingsView() }
                Text(PushRelayController.shared.status).font(.footnote)
                Text("长期实时提醒由 APNs 投递，需要启用推送的 Apple 签名，并配置桥接服务。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = notifications.error { Section { ErrorBanner(text: error) } }
            Section { Link(destination: URL(string: UIApplication.openSettingsURLString)!) { Label("打开系统通知与后台刷新设置", systemImage: "gear") } }
        }.navigationTitle("会话通知").navigationBarTitleDisplayMode(.inline)
    }
}
