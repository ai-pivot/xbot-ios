import XCTest
@testable import XbotCore

final class PrivacySafetyTests: XCTestCase {
    func testPublicOriginsDefaultToHTTPSAndRejectCleartext() throws {
        XCTAssertEqual(try ProtocolCodec.baseURL("example.com/xbot/").absoluteString, "https://example.com/xbot")
        for raw in ["http://example.com", "http://8.8.8.8", "http://172.32.0.1", "http://192.169.1.1", "http://10.evil.test", "http://localhost.evil.test", "http://[::ffff:8.8.8.8]", "http://[2001:4860:4860::8888]"] {
            XCTAssertThrowsError(try ProtocolCodec.baseURL(raw), raw)
        }
    }
    func testExplicitLocalOriginsRemainSupported() throws {
        for host in ["localhost", "127.0.0.1", "192.168.1.9", "10.0.0.8", "172.16.0.1", "172.31.255.254", "169.254.1.1", "xbot.local", "[::1]", "[fd00::a]", "[fe80::1234]", "[::ffff:192.168.1.1]"] {
            XCTAssertNoThrow(try ProtocolCodec.baseURL("http://" + host + ":16000/xbot"), host)
        }
        XCTAssertEqual(try ProtocolCodec.baseURL("192.168.1.9:16000").scheme, "http")
    }
    func testMediaCannotBypassPublicTransportRule() {
        XCTAssertNil(MediaURLResolver.resolve("http://cdn.test/private.png", server: nil, mediaBase: ""))
        XCTAssertNil(MediaURLResolver.resolve("/private.png", server: URL(string: "http://public.test"), mediaBase: ""))
        XCTAssertNotNil(MediaURLResolver.resolve("http://192.168.1.10/image.png", server: nil, mediaBase: ""))
    }
    func testSelfHostedDisclosureDoesNotInventProviderOrExposeSecrets() {
        let subscription = JSONValue.parse(#"{"name":"My proxy","provider":"openai","base_url":"https://user:pass@proxy.test/path?api_key=secret#fragment","api_key":"secret","enabled":true}"#)!
        let policy = MobilePolicy(selfHostedServer: URL(string: "https://my-server.test")!, subscriptions: [subscription])
        XCTAssertFalse(policy.serverDeclared)
        XCTAssertEqual(policy.providers.first?.name, "My proxy")
        XCTAssertEqual(policy.providers.first?.endpoint, "https://proxy.test")
        XCTAssertNil(policy.providers.first?.privacyURL)
        XCTAssertFalse(String(decoding: try! JSONEncoder().encode(policy), as: UTF8.self).contains("secret"))
        XCTAssertFalse(policy.contentFiltering) // Never claim the server filters content without evidence.
    }
    func testChangingModelRouteChangesConsentMaterial() {
        let server = URL(string: "https://server.test")!
        let first = MobilePolicy(selfHostedServer: server, subscriptions: [.parse(#"{"name":"Proxy","base_url":"https://a.test"}"#)!])
        let second = MobilePolicy(selfHostedServer: server, subscriptions: [.parse(#"{"name":"Proxy","base_url":"https://b.test"}"#)!])
        XCTAssertNotEqual(first, second)
        let routeA = MobilePolicy(selfHostedServer: server, subscriptions: [.parse(#"{"name":"Proxy","base_url":"https://proxy.test/vendor-a"}"#)!])
        let routeB = MobilePolicy(selfHostedServer: server, subscriptions: [.parse(#"{"name":"Proxy","base_url":"https://proxy.test/vendor-b"}"#)!])
        XCTAssertEqual(routeA.providers, routeB.providers)
        XCTAssertNotEqual(routeA.configurationDigest, routeB.configurationDigest)
    }
    func testDeclaredPolicyRejectsMissingRecipientsOrInsecureLinks() throws {
        var value = JSONValue.parse(#"{"version":"1","operator_name":"Fixture operator","privacy_url":"https://example.test/privacy","support_url":"https://example.test/support","retention":"7 days","deletion_days":7,"providers":[],"content_filtering":true}"#)!.object
        XCTAssertTrue(try MobilePolicy(.object(value)).serverDeclared)
        value["providers"] = .string("unknown")
        XCTAssertThrowsError(try MobilePolicy(.object(value)))
        value["providers"] = .array([]); value["privacy_url"] = .string("http://example.test/privacy")
        XCTAssertThrowsError(try MobilePolicy(.object(value)))
    }
    func testHighRiskContentIsHiddenWhileOrdinaryCodeAndMermaidRemainUsable() {
        for text in ["child sexual material", "未成年人色情内容", "未经同意的私密影像"] { XCTAssertTrue(ContentSafety.shouldHide(text)) }
        for text in ["写一个 Swift HTTP 客户端", "graph TD; A[child process] --> B[worker]", "hello fixture"] { XCTAssertFalse(ContentSafety.shouldHide(text)) }
    }
}
