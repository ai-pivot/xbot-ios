import Foundation

public enum ThinkingMode {
    public static func display(_ value: String) -> String {
        switch value { case "", "auto": "auto"; case "think", "enabled": "think"; default: value }
    }
    public static func wire(_ value: String) -> String {
        switch value { case "auto": ""; case "think": "enabled"; default: value }
    }
}

public enum MediaURLResolver {
    public static func resolve(_ raw: String, server: URL?, mediaBase: String) -> URL? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let scheme = URLComponents(string: value)?.scheme {
            guard ["http", "https"].contains(scheme.lowercased()),
                  var url = URLComponents(string: value), url.user == nil, url.password == nil,
                  let host = url.host else { return nil }
            if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) {
                guard let media = try? ProtocolCodec.baseURL(mediaBase),
                      let origin = URLComponents(url: media, resolvingAgainstBaseURL: false) else { return nil }
                url.scheme = origin.scheme; url.host = origin.host; url.port = origin.port
            }
            return url.url
        }
        guard !value.hasPrefix("//"), let server else { return nil }
        return URL(string: server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (value.hasPrefix("/") ? "" : "/") + value)
    }
}

public struct ReleaseManifest: Sendable, Equatable {
    public let version: String
    public let build: Int64
    public let url: URL
    public let changelog: String
    public let mandatory: Bool
    public let publishedAt: String
    public init(_ value: JSONValue) throws {
        guard value["platform"].string == "ios" else { throw ServerError("这不是 iOS 更新清单，请配置 iOS 专用清单地址") }
        version = value["versionName"].string
        build = value["versionCode"].int
        guard !version.isEmpty, build > 0, let link = URL(string: value["url"].string),
              link.scheme == "https", let host = link.host?.lowercased(),
              ["apps.apple.com", "testflight.apple.com"].contains(host), link.user == nil, link.password == nil else {
            throw ServerError("更新清单必须包含版本号、构建号以及有效的 App Store 或 TestFlight 链接")
        }
        url = link; changelog = value["changelog"].string
        mandatory = value["mandatory"].bool; publishedAt = value["publishedAt"].string
    }
    public func isNewer(version installed: String, build installedBuild: Int64) -> Bool {
        let comparison = version.compare(installed, options: .numeric)
        return comparison == .orderedDescending || (comparison == .orderedSame && build > installedBuild)
    }
}
