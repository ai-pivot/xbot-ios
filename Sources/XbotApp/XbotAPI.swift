import Foundation

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class MediaRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, (try? TransportSecurity.validate(url)) != nil else { completionHandler(nil); return }
        var safe = request; safe.setValue(nil, forHTTPHeaderField: "Cookie"); safe.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(safe)
    }
}

@MainActor
final class XbotAPI {
    let baseURL: URL
    let session: URLSession
    private let cookieStore: HTTPCookieStorage
    private var loginTask: Task<Void, Error>?
    private var key: String { baseURL.absoluteString }

    init(server: String) throws {
        baseURL = try ProtocolCodec.baseURL(server)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 55
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpCookieAcceptPolicy = .always
        cookieStore = configuration.httpCookieStorage!
        if let data = SecureStore.read("cookies:" + baseURL.absoluteString),
           let rows = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] {
            for row in rows {
                let props = Dictionary(uniqueKeysWithValues: row.map { (HTTPCookiePropertyKey($0.key), $0.value) })
                if let cookie = HTTPCookie(properties: props) { cookieStore.setCookie(cookie) }
            }
        }
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func requestURL(_ path: String, query: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw ServerError("服务器地址无效") }
        components.percentEncodedPath += path
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw ServerError("请求地址无效") }; return url
    }

    func post(_ path: String, _ body: [String: JSONValue] = [:], query: [String: String] = [:], retry: Bool = true) async throws -> JSONValue {
        var request = URLRequest(url: try requestURL(path, query: query))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        return try await execute(request, retry: retry)
    }

    func execute(_ request: URLRequest, retry: Bool = true) async throws -> JSONValue {
        if let url = request.url {
            try TransportSecurity.validate(url)
            let protected = ["/api/message", "/api/files/upload", "/api/ask_user/respond"]
            let body = request.httpBody.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            let cancellationOnly = url.path == baseURL.path + "/api/ask_user/respond" && body?["cancelled"].bool == true && body?["answers"].object.isEmpty == true
            if !cancellationOnly && protected.contains(where: { url.path == baseURL.path + $0 }) { try await PrivacyCenter.shared.requireConsent(for: self) }
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ServerError("服务器响应无效") }
            // Authentication requests must not be redirected to another origin.
            guard response.url?.host == baseURL.host, response.url?.scheme == baseURL.scheme,
                  response.url?.port == baseURL.port else { throw ServerError("服务器将请求重定向到其他地址，请直接填写最终服务器地址") }
            let value = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
            if value.isNull && (200..<300).contains(response.statusCode) { throw ServerError("服务器未返回有效的 JSON 数据") }
            let result = try ProtocolCodec.unwrap(value, status: response.statusCode)
            try saveCookies(); return result
        } catch let error as ServerError where error.unauthorized && retry {
            try await silentLogin()
            return try await execute(request, retry: false)
        }
    }

    func login(username: String, password: String, remember: Bool, register: Bool = false) async throws {
        let credentials: [String: JSONValue] = ["username": .string(username), "password": .string(password)]
        if register { _ = try await post("/api/auth/register", credentials, retry: false) }
        _ = try await post("/api/auth/login", credentials, retry: false)
        if remember {
            try SecureStore.write(JSONEncoder().encode(SavedCredentials(username: username, password: password)), account: "credentials:" + key)
        } else { SecureStore.delete("credentials:" + key) }
    }

    func silentLogin() async throws {
        if let task = loginTask { return try await task.value }
        guard let data = SecureStore.read("credentials:" + key), let saved = try? JSONDecoder().decode(SavedCredentials.self, from: data) else {
            throw ServerError("登录已失效，请重新登录", unauthorized: true)
        }
        let task = Task { _ = try await self.post("/api/auth/login", ["username": .string(saved.username), "password": .string(saved.password)], retry: false) }
        loginTask = task
        defer { loginTask = nil }
        _ = try await task.value
    }

    func logout() async {
        if let url = try? requestURL("/api/auth/logout") {
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            _ = try? await execute(request, retry: false)
        }
        clearLocalAuthentication()
    }
    func clearLocalAuthentication() {
        loginTask?.cancel(); loginTask = nil
        for cookie in cookieStore.cookies ?? [] { cookieStore.deleteCookie(cookie) }
        SecureStore.delete("credentials:" + key); SecureStore.delete("cookies:" + key)
        session.invalidateAndCancel()
    }
    private func saveCookies() throws {
        let rows = (cookieStore.cookies ?? []).compactMap(\.properties).map { props in
            Dictionary(uniqueKeysWithValues: props.map { ($0.key.rawValue, $0.value) })
        }
        let data = try PropertyListSerialization.data(fromPropertyList: rows, format: .binary, options: 0)
        try SecureStore.write(data, account: "cookies:" + key)
    }

    func rpc(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await post("/api/rpc", ["method": .string(method), "params": .object(params)])
    }
    func history(_ chat: ChatSession, before: Int64 = 0) async throws -> JSONValue {
        try await post("/api/history", context(chat).merging(["limit": .number(40), "before_id": .number(Double(before))]) { _, new in new })
    }
    func context(_ chat: ChatSession) -> [String: JSONValue] { ["chat_id": .string(chat.chatID), "channel": .string(chat.channel)] }
    func mediaData(_ url: URL, retry: Bool = true) async throws -> Data {
        try TransportSecurity.validate(url)
        let sameOrigin = url.host == baseURL.host && url.scheme == baseURL.scheme && url.port == baseURL.port
        let (data, response) = try await (sameOrigin ? session.data(from: url) : externalMedia(url))
        guard let http = response as? HTTPURLResponse else { throw ServerError("图片响应无效") }
        if http.statusCode == 401 && sameOrigin && retry { try await silentLogin(); return try await mediaData(url, retry: false) }
        if sameOrigin && (300..<400).contains(http.statusCode),
           let location = http.value(forHTTPHeaderField: "Location"), let target = URL(string: location, relativeTo: url)?.absoluteURL,
           ["http", "https"].contains(target.scheme ?? ""), target.user == nil, target.password == nil {
            // Object-store redirects must never inherit the xbot session cookies.
            try TransportSecurity.validate(target)
            let (redirected, result) = try await externalMedia(target)
            guard (result as? HTTPURLResponse)?.statusCode == 200 else { throw ServerError("对象存储图片加载失败") }
            return redirected
        }
        guard http.statusCode == 200 else { throw ServerError("图片加载失败（HTTP \(http.statusCode)）") }
        return data
    }
    private func externalMedia(_ url: URL) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        let external = URLSession(configuration: configuration, delegate: MediaRedirectDelegate(), delegateQueue: nil)
        defer { external.invalidateAndCancel() }
        return try await external.data(from: url)
    }
    func chatPath(_ chat: ChatSession, action: String) -> String {
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/?#%")
        return "/api/chats/\(chat.chatID.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")/\(action)"
    }
    func upload(_ data: Data, name: String, mime: String) async throws -> JSONValue {
        let boundary = "Xbot-" + UUID().uuidString
        let safeName = name.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: try requestURL("/api/files/upload")); request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"); request.httpBody = body
        return try await execute(request)
    }
}
