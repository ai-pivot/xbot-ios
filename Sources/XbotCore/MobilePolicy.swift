import Foundation
import CryptoKit

public struct MobilePolicy: Codable, Equatable, Sendable {
    public struct Provider: Codable, Equatable, Sendable {
        public let name: String
        public let privacyURL: URL?
        public let endpoint: String?
    }
    public let version: String
    public let operatorName: String
    public let privacyURL: URL
    public let supportURL: URL
    public let providers: [Provider]
    public let retention: String
    public let deletionDays: Int
    public let contentFiltering: Bool
    public let serverDeclared: Bool
    public let tools: [String]
    public let configurationDigest: String

    public init(_ value: JSONValue) throws {
        func secureURL(_ raw: String) throws -> URL {
            guard let url = URL(string: raw), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else { throw ServerError("服务器的数据说明缺少有效的 HTTPS 链接") }
            return url
        }
        version = value["version"].string
        operatorName = value["operator_name"].string
        privacyURL = try secureURL(value["privacy_url"].string)
        supportURL = try secureURL(value["support_url"].string)
        providers = try value["providers"].array.map {
            guard !$0["name"].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServerError("AI 服务商名称不能为空") }
            return Provider(name: $0["name"].string, privacyURL: try secureURL($0["privacy_url"].string), endpoint: nil)
        }
        retention = value["retention"].string
        deletionDays = Int(value["deletion_days"].int)
        contentFiltering = value["content_filtering"].bool
        serverDeclared = true
        tools = []
        configurationDigest = ""
        guard case .array = value["providers"], !version.isEmpty, !operatorName.isEmpty, !retention.isEmpty,
              (1...30).contains(deletionDays) else { throw ServerError("服务器的数据说明不完整") }
    }

    /// A generic client must not invent an operator or infer a legal AI vendor
    /// from an OpenAI-compatible protocol. Show server configuration verbatim,
    /// without credentials, paths, query strings, or masked API keys.
    public init(selfHostedServer server: URL, subscriptions: [JSONValue], tools: [JSONValue] = []) {
        version = "self-hosted-disclosure-v1"
        operatorName = "你指定的服务器：" + (server.host ?? server.absoluteString)
        privacyURL = URL(string: "https://github.com/ai-pivot/xbot-ios/blob/main/docs/PRIVACY.md")!
        supportURL = URL(string: "https://github.com/ai-pivot/xbot-ios/issues")!
        providers = subscriptions.filter { $0["enabled"] != .bool(false) }.map { sub in
            let name = sub["name"].string.nonEmpty ?? sub["provider"].string.nonEmpty ?? "服务器模型订阅"
            var endpoint: String?
            if var url = URLComponents(string: sub["base_url"].string), url.host != nil {
                url.user = nil; url.password = nil; url.path = ""; url.query = nil; url.fragment = nil
                endpoint = url.string
            }
            return Provider(name: name, privacyURL: nil, endpoint: endpoint)
        }.sorted { ($0.name + ($0.endpoint ?? "")) < ($1.name + ($1.endpoint ?? "")) }
        retention = "数据由你指定的服务器及其配置的模型、代理和工具处理并保留。本客户端维护者不托管你的账号、消息或附件。具体保留与删除规则由你或服务器管理员决定。"
        deletionDays = 0; contentFiltering = false; serverDeclared = false
        self.tools = tools.filter { $0["enabled"] != .bool(false) }.map { $0["name"].string }.filter { !$0.isEmpty }.sorted()
        let relevant = subscriptions.map { sub in
            JSONValue.object(sub.object.filter { ["id", "name", "provider", "base_url", "model", "enabled"].contains($0.key) })
        }.sorted { $0["id"].string + $0["name"].string < $1["id"].string + $1["name"].string }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        configurationDigest = SHA256.hash(data: (try? encoder.encode(relevant)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
}

/// Local defense in depth. The service operator must also moderate model/tool output.
public enum ContentSafety {
    private static let patterns = [
        #"(?i)(child|minor|underage).{0,32}(porn|sexual|nude)"#,
        #"(?i)(porn|sexual|nude).{0,32}(child|minor|underage)"#,
        #"(儿童|幼童|未成年).{0,20}(色情|裸照|性行为)"#,
        #"(色情|裸照|性行为).{0,20}(儿童|幼童|未成年)"#,
        #"(?i)(non.?consensual|revenge).{0,20}(porn|intimate|nude)"#,
        #"(偷拍|报复|未经同意).{0,16}(裸照|私密影像|色情)"#
    ]
    public static func shouldHide(_ text: String) -> Bool {
        patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }
}
