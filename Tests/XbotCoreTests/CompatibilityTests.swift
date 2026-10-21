import XCTest
@testable import XbotCore

final class CompatibilityTests: XCTestCase {
    func testThinkingModesMatchAndroidWireValues() {
        for (stored, shown, wire) in [("", "auto", ""), ("auto", "auto", ""), ("enabled", "think", "enabled"), ("think", "think", "enabled"), ("think-max", "think-max", "think-max"), ("disabled", "disabled", "disabled")] {
            XCTAssertEqual(ThinkingMode.display(stored), shown); XCTAssertEqual(ThinkingMode.wire(shown), wire)
        }
    }
    func testMediaRelativePathsPreserveReverseProxyPrefix() {
        let server = URL(string: "https://example.com/xbot")!
        XCTAssertEqual(MediaURLResolver.resolve("/api/files/download?key=a%2Fb", server: server, mediaBase: "")?.absoluteString, "https://example.com/xbot/api/files/download?key=a%2Fb")
        XCTAssertEqual(MediaURLResolver.resolve("images/a.png", server: server, mediaBase: "")?.absoluteString, "https://example.com/xbot/images/a.png")
    }
    func testLoopbackMediaRequiresExplicitOriginAndPreservesQuery() {
        let raw = "http://127.0.0.1:9000/bucket/a.png?signature=fixture#x"
        XCTAssertNil(MediaURLResolver.resolve(raw, server: URL(string: "https://server.test"), mediaBase: ""))
        XCTAssertEqual(MediaURLResolver.resolve(raw, server: nil, mediaBase: "https://objects.test:9443/ignored-prefix")?.absoluteString, "https://objects.test:9443/bucket/a.png?signature=fixture#x")
        XCTAssertEqual(MediaURLResolver.resolve("https://other.test/a.png", server: nil, mediaBase: "https://objects.test")?.host, "other.test")
    }
    func testUnsafeMediaSchemesAreRejected() {
        for raw in ["javascript:alert(1)", "file:///tmp/private", "data:image/png,abc", "https://user:password@host/a", "//other.test/a"] {
            XCTAssertNil(MediaURLResolver.resolve(raw, server: URL(string: "https://server.test"), mediaBase: ""))
        }
    }
    func testIOSReleaseComparisonAndPlatformValidation() throws {
        let value = JSONValue.parse(#"{"platform":"ios","versionName":"1.10.0","versionCode":12,"url":"https://testflight.apple.com/join/fixture","mandatory":true}"#)!
        let manifest = try ReleaseManifest(value)
        XCTAssertTrue(manifest.isNewer(version: "1.9.0", build: 50)); XCTAssertFalse(manifest.isNewer(version: "1.10.0", build: 12))
        XCTAssertTrue(manifest.isNewer(version: "1.10.0", build: 11)); XCTAssertTrue(manifest.mandatory)
        XCTAssertThrowsError(try ReleaseManifest(JSONValue.parse(#"{"versionName":"2","versionCode":2,"url":"https://example.com/a.apk"}"#)!))
        XCTAssertThrowsError(try ReleaseManifest(JSONValue.parse(#"{"platform":"ios","versionName":"2","versionCode":2,"url":"https://apps.apple.com.evil.test/a"}"#)!))
    }
    func testNotificationBaselineDoesNotAlertForOldHistory() {
        var snapshot = NotificationSnapshot()
        let history = JSONValue.parse(#"{"messages":[{"role":"assistant","turn_id":1,"content":"old"}]}"#)!
        XCTAssertTrue(snapshot.reconcile(history: history, pending: .null).isEmpty)
        XCTAssertTrue(snapshot.reconcile(history: history, pending: .null).isEmpty)
    }
    func testBackgroundCompletionAndQuestionAreDeduplicated() {
        var snapshot = NotificationSnapshot()
        _ = snapshot.reconcile(history: JSONValue.parse(#"{"processing":true,"messages":[]}"#)!, pending: .null)
        let final = JSONValue.parse(#"{"processing":false,"messages":[{"role":"assistant","turn_id":2,"content":"done"}]}"#)!
        let question = JSONValue.parse(#"{"request_id":"q1","questions":[{"question":"Choose"}]}"#)!
        let notices = snapshot.reconcile(history: final, pending: question)
        XCTAssertEqual(notices.map(\.kind), [.completed, .question]); XCTAssertEqual(notices.map(\.body), ["done", "Choose"])
        XCTAssertTrue(snapshot.reconcile(history: final, pending: question).isEmpty)
    }
    func testNotificationSequenceResetRebaselinesOldTurnIDs() {
        var snapshot = NotificationSnapshot()
        _ = snapshot.reconcile(history: .parse(#"{"messages":[{"role":"assistant","turn_id":10000,"content":"old"}]}"#)!, pending: .null)
        XCTAssertTrue(snapshot.reconcile(history: .parse(#"{"messages":[]}"#)!, pending: .null, reset: true).isEmpty)
        let notices = snapshot.reconcile(history: .parse(#"{"messages":[{"role":"assistant","turn_id":2,"content":"new"}]}"#)!, pending: .null)
        XCTAssertEqual(notices.map(\.body), ["new"])
    }

}
