import XCTest
@testable import XbotCore

final class ProtocolTests: XCTestCase {
    private func json(_ raw: String) -> JSONValue { JSONValue.parse(raw)! }

    func testWrappedAndRawRPCResponses() throws {
        XCTAssertEqual(try ProtocolCodec.unwrap(json(#"{"ok":true,"data":[{"model":"test"}]}"#)).array.count, 1)
        XCTAssertEqual(try ProtocolCodec.unwrap(json(#"{"model":"test"}"#))["model"].string, "test")
        XCTAssertTrue(try ProtocolCodec.unwrap(json(#"{"ok":true,"data":null}"#)).isNull)
    }
    func testErrorsAreNotSuccessfulRPCResults() {
        XCTAssertThrowsError(try ProtocolCodec.unwrap(json(#"{"ok":false,"error":{"message":"无权限"}}"#))) { error in
            XCTAssertEqual(error.localizedDescription, "无权限")
        }
        XCTAssertThrowsError(try ProtocolCodec.unwrap(.null, status: 401)) { error in XCTAssertTrue((error as? ServerError)?.unauthorized == true) }
    }
    func testURLNormalizationAndValidation() throws {
        XCTAssertEqual(try ProtocolCodec.baseURL("  localhost:16000/ ").absoluteString, "http://localhost:16000")
        XCTAssertEqual(try ProtocolCodec.baseURL("https://example.com/xbot///").absoluteString, "https://example.com/xbot")
        for raw in ["", "file:///tmp/a", "https://user:password@example.com", "https://example.com?token=secret", "http://"] {
            XCTAssertThrowsError(try ProtocolCodec.baseURL(raw))
        }
    }
    func testSSEMultilineCommentsAndCRLF() {
        var parser = SSEParser()
        for line in [": heartbeat", "id: 12\r", "event: text", "data: first", "data: second"] { XCTAssertNil(parser.consume(line)) }
        let frame = parser.consume("\r")
        XCTAssertEqual(frame, SSEFrame(id: "12", event: "text", data: "first\nsecond"))
        XCTAssertNil(parser.consume(""))
    }
    func testSSEIncompleteFrameIsNotDispatched() {
        var parser = SSEParser(); XCTAssertNil(parser.consume("data: unfinished"))
    }
    func testByteStreamPreservesBlankLinesAndUnicode() {
        for newline in ["\n", "\r\n", "\r"] {
            var parser = SSEByteParser()
            let input = "\u{FEFF}id: 1\(newline)data: 中文🙂\(newline)\(newline)id: 2\(newline)data: second\(newline)\(newline)"
            let frames = input.utf8.compactMap { parser.consume($0) }
            XCTAssertEqual(frames.count, 2)
            XCTAssertEqual(frames.first?.data, "中文🙂"); XCTAssertEqual(frames.last?.id, "2")
        }
    }
    func testByteParserDispatchesOnlyAfterEventBoundary() {
        var parser = SSEByteParser()
        XCTAssertTrue("data: one\ndata: two\n".utf8.compactMap { parser.consume($0) }.isEmpty)
        XCTAssertEqual(parser.consume(10)?.data, "one\ntwo")
    }
    func testReplayAndSessionRouting() {
        var cursor = EventCursor(sequence: 5)
        let event = json(#"{"type":"progress","chat_id":"a","channel":"web"}"#)
        XCTAssertFalse(cursor.accept(event, frameID: "5", chatID: "a", channel: "web"))
        XCTAssertTrue(cursor.accept(event, frameID: "6", chatID: "a", channel: "web"))
        XCTAssertFalse(cursor.accept(event, frameID: "6", chatID: "a", channel: "web"))
        XCTAssertFalse(cursor.accept(event, frameID: "7", chatID: "b", channel: "web"))
        XCTAssertFalse(cursor.accept(event, frameID: "7", chatID: "a", channel: "telegram"))
        XCTAssertEqual(cursor.sequence, 6)
    }
    func testRouteOverride() {
        var cursor = EventCursor()
        XCTAssertTrue(cursor.accept(json(#"{"chat_id":"source","route_chat_id":"target","route_channel":"web"}"#), frameID: "1", chatID: "target", channel: "web"))
    }
    func testJSONRoundTripRetainsUnknownValues() throws {
        let value = json(#"{"a":[true,null,3,"x"],"future":{"enabled":false}}"#)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }
}
