import Foundation

/// The server's internal protocol is extensible. Preserve unknown payload fields.
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue {
        if case .object(let v) = self { return v[key] ?? .null }; return .null
    }
    public var string: String { if case .string(let v) = self { return v }; return "" }
    public var int: Int64 { if case .number(let v) = self, v.isFinite, v >= Double(Int64.min), v < Double(Int64.max) { return Int64(v) }; return 0 }
    public var bool: Bool { if case .bool(let v) = self { return v }; return false }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    public var object: [String: JSONValue] { if case .object(let v) = self { return v }; return [:] }
    public var isNull: Bool { self == .null }
    public var display: String {
        if case .string(let s) = self { return s }
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    public static func parse(_ text: String) -> JSONValue? { try? JSONDecoder().decode(Self.self, from: Data(text.utf8)) }
}

public struct ServerError: LocalizedError, Sendable {
    public let message: String
    public let unauthorized: Bool
    public init(_ message: String, unauthorized: Bool = false) { self.message = message; self.unauthorized = unauthorized }
    public var errorDescription: String? { message }
}

public enum ProtocolCodec {
    public static func unwrap(_ value: JSONValue, status: Int = 200) throws -> JSONValue {
        if status == 401 || value["error"]["code"].string == "unauthorized" {
            throw ServerError("登录已失效，请重新登录", unauthorized: true)
        }
        if !(200..<300).contains(status) || value["ok"] == .bool(false) {
            throw ServerError(value["error"]["message"].string.nonEmpty ?? value["error"].string.nonEmpty ?? "服务器请求失败（HTTP \(status)）")
        }
        if value["ok"] == .bool(true), value.object.keys.contains("data") { return value["data"] }
        return value
    }

    public static func baseURL(_ raw: String) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ServerError("请填写服务器地址") }
        if !text.contains("://") { text = "http://" + text }
        guard var c = URLComponents(string: text), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              c.host?.isEmpty == false, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else {
            throw ServerError("请输入有效的 HTTP 或 HTTPS 服务器地址")
        }
        while c.path.hasSuffix("/") { c.path.removeLast() }
        guard let url = c.url else { throw ServerError("服务器地址无效") }; return url
    }
}

extension String {
    public var nonEmpty: String? { isEmpty ? nil : self }
}
