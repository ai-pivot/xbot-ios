import SwiftUI

/// A relay has its own credential. The xbot password and cookies never leave XbotAPI.
@MainActor @Observable
final class PushRelayController {
    static let shared = PushRelayController()
    struct Configuration: Codable { var url: String; var secret: String }
    private struct Receipt: Codable { var configuration: Configuration; var id: String }
    var configuration: Configuration {
        SecureStore.read("push-relay-config").flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration(url: "", secret: "")
    }
    private(set) var registered = false
    private(set) var status = "未配置推送桥接"
    private var generation = UUID()
    private var operation: Task<Void, Error>?
    private var bindingContext = ""
    private var receipt: Receipt? {
        get { SecureStore.read("push-relay-receipt").flatMap { try? JSONDecoder().decode(Receipt.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { try? SecureStore.write(data, account: "push-relay-receipt") }
            else { SecureStore.delete("push-relay-receipt") }
        }
    }
    private func endpoint(_ raw: String, path: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw ServerError("桥接地址需要使用 HTTPS，且不能包含账号、查询参数或片段") }
        return url.appendingPathComponent(path)
    }
    private func request(_ configuration: Configuration, path: String, method: String, body: Data? = nil) async throws -> JSONValue {
        var request = URLRequest(url: try endpoint(configuration.url, path: path), timeoutInterval: 20)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + configuration.secret, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let result = try? JSONDecoder().decode(JSONValue.self, from: data), result["ok"].bool else { throw ServerError("推送桥接请求失败，请检查服务地址与绑定密钥") }
        return result
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    }
    func save(url: String, secret: String) async throws {
        if !url.isEmpty { _ = try endpoint(url, path: "devices"); guard secret.count >= 32 else { throw ServerError("绑定密钥至少需要 32 个字符") } }
        generation = UUID(); let current = generation
        registered = false; bindingContext = ""
        let previous = operation
        let work = Task<Void, Error> {
            _ = await previous?.result
            guard current == generation else { throw CancellationError() }
            try await removeReceipt()
            try SecureStore.write(JSONEncoder().encode(Configuration(url: url, secret: secret)), account: "push-relay-config")
            status = url.isEmpty ? "未配置推送桥接" : "配置已保存，等待设备注册"
        }
        operation = work; try await work.value
    }
    private func removeReceipt() async throws {
        guard let previous = receipt else { return }
        _ = try await request(previous.configuration, path: "devices/" + previous.id, method: "DELETE")
        receipt = nil
    }
    func disconnect() {
        generation = UUID(); let current = generation
        registered = false; bindingContext = ""
        let previous = operation
        operation = Task<Void, Error> {
            _ = await previous?.result
            guard current == generation else { return }
            do { try await removeReceipt(); status = configuration.url.isEmpty ? "未配置推送桥接" : "推送绑定已关闭" }
            catch { status = "解除推送绑定失败，请重试或在桥接服务移除此设备" }
        }
    }
    func bind(api: XbotAPI, chat: ChatSession) {
        guard NotificationController.shared.enabled, NotificationController.shared.hasPushConfiguration else { return }
        let config = configuration
        guard !config.url.isEmpty, let token = SecureStore.read("apns-device-token") else { return }
        let context = api.baseURL.absoluteString + chat.id + config.url + token.base64EncodedString()
        guard bindingContext != context else { return }
        bindingContext = context
        generation = UUID(); let current = generation
        let previous = operation; registered = false
        operation = Task<Void, Error> {
            _ = await previous?.result
            guard current == generation else { return }
            do {
                try await removeReceipt()
                let body: [String: String] = ["device_token": token.map { String(format: "%02x", $0) }.joined(), "server": api.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), "chat_id": chat.chatID, "channel": chat.channel]
                let result = try await request(config, path: "devices", method: "POST", body: JSONEncoder().encode(body))
                let id = result["id"].string
                guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { throw ServerError("推送桥接返回了无效绑定") }
                // Retain the receipt even if the context changed during the request,
                // so the next operation can remove a completed stale registration.
                receipt = Receipt(configuration: config, id: id)
                guard current == generation else { return }
                registered = true; status = "APNs 桥接已绑定当前会话"
            } catch {
                guard current == generation else { return }
                bindingContext = ""; status = "推送绑定失败，请检查桥接服务与配置"
            }
        }
    }
}

struct PushRelaySettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var relay = PushRelayController.shared
    @State private var url = ""
    @State private var secret = ""
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                TextField("https://push.example.com", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("绑定密钥", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text(relay.status).font(.footnote).foregroundStyle(.secondary)
                Button("保存并绑定") {
                    saving = true; error = nil
                    Task {
                        do {
                            try await relay.save(url: url.trimmingCharacters(in: .whitespacesAndNewlines), secret: secret)
                            if let api = store.api, let chat = ClientPreferences.active(server: api.baseURL) { relay.bind(api: api, chat: chat) }
                        } catch { self.error = error.localizedDescription }
                        saving = false
                    }
                }.disabled(saving)
            } header: { Text("推送桥接服务") } footer: { Text("填写你部署的 xbot APNs 桥接地址与专用绑定密钥。绑定密钥安全保存在钥匙串。留空地址并保存可解除绑定。") }
            if let error { Section { ErrorBanner(text: error) } }
        }.navigationTitle("推送桥接").navigationBarTitleDisplayMode(.inline)
            .task { let config = relay.configuration; url = config.url; secret = config.secret }
    }
}
