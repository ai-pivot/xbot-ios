import XCTest

@MainActor
final class XbotUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }
    func testPreviewChatAndSettings() {
        let app = XCUIApplication(); app.launchArguments = ["--preview"]; app.launch()
        XCTAssertTrue(app.buttons["session-preview"].waitForExistence(timeout: 10))
        app.buttons["session-preview"].tap()
        XCTAssertTrue(app.staticTexts["界面预览 · 登录服务器后可发送消息"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["send-button"].isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Chat Preview"; attachment.lifetime = .keepAlways; add(attachment)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["设置"].tap()
        app.swipeUp()
        XCTAssertTrue(app.buttons["连接我的服务器"].waitForExistence(timeout: 5))
        app.buttons["连接我的服务器"].tap()
        XCTAssertTrue(app.buttons["login-button"].waitForExistence(timeout: 5))
        app.buttons["login-button"].tap()
        XCTAssertTrue(app.staticTexts["请填写用户名和密码"].waitForExistence(timeout: 5))
    }

    func testDarkModePreview() {
        let app = XCUIApplication(); app.launchArguments = ["--preview", "-appearance", "dark"]; app.launch()
        XCTAssertTrue(app.buttons["session-preview"].waitForExistence(timeout: 10)); app.buttons["session-preview"].tap()
        XCTAssertTrue(app.staticTexts["界面预览 · 登录服务器后可发送消息"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Dark Chat Preview"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testFixtureLoginStreamAskUserAndRestore() async throws {
        let app = try await fixtureApp()
        let composer = app.textFields["message-field"]
        if !composer.waitForExistence(timeout: 3), app.buttons["session-fixture"].exists { app.buttons["session-fixture"].tap() }
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); composer.tap(); composer.typeText("hello fixture")
        app.buttons["send-button"].tap()
        XCTAssertTrue(app.staticTexts["已收到：hello fixture"].waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("need-input"); app.buttons["send-button"].tap()
        XCTAssertTrue(app.buttons["方案 A"].waitForExistence(timeout: 10)); app.buttons["方案 A"].tap(); app.buttons["提交"].tap()
        XCTAssertTrue(app.staticTexts["已选择：方案 A"].waitForExistence(timeout: 10))
        composer.tap(); composer.typeText("rich-markdown"); app.buttons["send-button"].tap()
        XCTAssertTrue(app.staticTexts["已对齐"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["图表已渲染"].waitForExistence(timeout: 25))
        app.buttons["mermaid-expand"].tap()
        XCTAssertTrue(app.buttons["mermaid-preview-close"].waitForExistence(timeout: 5)); app.buttons["mermaid-preview-close"].tap()
        let image = app.descendants(matching: .any).matching(identifier: "message-image").firstMatch
        for _ in 0..<4 { if image.exists { break }; app.swipeUp() }
        XCTAssertTrue(image.waitForExistence(timeout: 5)); image.tap()
        XCTAssertTrue(app.buttons["image-preview-close"].waitForExistence(timeout: 5))
        app.pinch(withScale: 2, velocity: 1)
        app.buttons["image-preview-close"].tap()
        let rich = XCTAttachment(screenshot: app.screenshot()); rich.name = "Android Parity Rich Content"; rich.lifetime = .keepAlways; add(rich)
        app.terminate(); app.launchArguments = ["--server", "http://127.0.0.1:18081", "--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["session-fixture"].waitForExistence(timeout: 10))
    }

    func testFixtureSettingsAndUpdates() async throws {
        let app = try await fixtureApp()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["设置"].tap()
        app.buttons["思考与上下文"].tap()
        let compression = app.textFields["compression-field"]
        XCTAssertTrue(compression.waitForExistence(timeout: 10))
        app.buttons["thinking-picker"].tap(); app.buttons["开启"].tap()
        compression.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let value = compression.value as? String { compression.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        compression.typeText("0.7"); XCTAssertEqual(compression.value as? String, "0.7")
        app.swipeUp(); XCTAssertTrue(app.buttons["save-agent-settings"].isEnabled); app.buttons["save-agent-settings"].tap()
        XCTAssertTrue(app.staticTexts["已保存"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.swipeUp(); app.buttons["版本更新"].tap()
        let update = app.textFields["update-url-field"]; XCTAssertTrue(update.waitForExistence(timeout: 5)); update.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        if let value = update.value as? String, !value.hasPrefix("https://…") { update.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        update.typeText("http://127.0.0.1:18081/ios/latest.json")
        app.buttons["check-update-button"].tap()
        XCTAssertTrue(app.buttons["install-update-link"].waitForExistence(timeout: 10))
    }

    func testFixtureBackgroundNotifications() async throws {
        let app = try await fixtureApp()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["设置"].tap()
        app.swipeUp()
        app.buttons["会话通知"].tap()
        let toggle = app.switches["notifications-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["允许"].waitForExistence(timeout: 3) { springboard.buttons["允许"].tap() }
        if springboard.buttons["Allow"].exists { springboard.buttons["Allow"].tap() }
        if app.alerts.buttons["允许"].exists { app.alerts.buttons["允许"].tap() }
        if app.alerts.buttons["Allow"].exists { app.alerts.buttons["Allow"].tap() }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "正在监听当前会话")).firstMatch.waitForExistence(timeout: 10), app.debugDescription + "\n" + springboard.debugDescription)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        try await Task.sleep(for: .seconds(1))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18081/__test/notice")!); request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        _ = try await URLSession.shared.data(for: request)
        try await Task.sleep(for: .seconds(3))
        app.activate()
        XCTAssertTrue(app.staticTexts["已投递提醒：1"].waitForExistence(timeout: 10), app.debugDescription)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func fixtureApp() async throws -> XCUIApplication {
        do {
            let (_, response) = try await URLSession.shared.data(for: URLRequest(url: URL(string: "http://127.0.0.1:18081/healthz")!, timeoutInterval: 2))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw XCTSkip("Local fixture is not running") }
        } catch { throw XCTSkip("Run scripts/fixture_server.py to enable protocol UI tests") }
        var reset = URLRequest(url: URL(string: "http://127.0.0.1:18081/__test/reset")!); reset.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: reset)
        let app = XCUIApplication(); app.launchArguments = ["--server", "http://127.0.0.1:18081", "--reset-auth", "--ui-testing"]; app.launch()
        let username = app.textFields["username-field"]
        XCTAssertTrue(username.waitForExistence(timeout: 10)); username.tap()
        if let value = username.value as? String, !value.isEmpty, value != "你的用户名" { username.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        username.typeText("tester")
        let password = app.secureTextFields["password-field"]; password.tap(); password.typeText("fixture-password")
        app.swipeUp(); app.buttons["login-button"].tap()
        XCTAssertTrue(app.buttons["session-fixture"].waitForExistence(timeout: 10))
        if app.buttons["以后"].waitForExistence(timeout: 2) { app.buttons["以后"].tap(); try await Task.sleep(for: .seconds(1)) }
        app.buttons["session-fixture"].tap()
        XCTAssertTrue(app.textFields["message-field"].waitForExistence(timeout: 10))
        return app
    }
}
