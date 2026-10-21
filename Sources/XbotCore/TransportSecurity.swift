import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// HTTPS everywhere except an explicitly addressed local network server.
public enum TransportSecurity {
    public static func isLocalHost(_ raw: String) -> Bool {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let octets = host.split(separator: ".").compactMap { UInt8($0) }
            guard octets.count == 4 else { return false }
            return octets[0] == 10 || octets[0] == 127 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
                (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254)
        }
        var v6 = in6_addr()
        let unscoped = String(host.split(separator: "%", maxSplits: 1).first ?? "")
        if inet_pton(AF_INET6, unscoped, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
            if bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) { return true }
            // IPv4-mapped literals must satisfy the same IPv4 rule.
            if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 {
                return isLocalHost(bytes.suffix(4).map(String.init).joined(separator: "."))
            }
        }
        return false
    }
    public static func validate(_ url: URL) throws {
        guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && isLocalHost(host)) else {
            throw ServerError("公网连接必须使用 HTTPS；HTTP 仅用于明确指定的局域网或本机服务器")
        }
    }
}
