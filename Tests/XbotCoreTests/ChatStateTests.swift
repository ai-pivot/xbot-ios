import XCTest
@testable import XbotCore

final class ChatStateTests: XCTestCase {
    private func j(_ text: String) -> JSONValue { JSONValue.parse(text)! }
    func testDeltasAndCheckpointsDoNotDuplicate() {
        var s = ChatState()
        s.applyProgress(j(#"{"turn_id":1,"iteration":1,"phase":"streaming","stream_delta":"Hello"}"#))
        s.applyProgress(j(#"{"turn_id":1,"iteration":1,"phase":"streaming","stream_delta":" world"}"#))
        s.applyProgress(j(#"{"turn_id":1,"iteration":1,"phase":"streaming","stream_content":"Hello world!"}"#))
        XCTAssertEqual(s.turns.count, 1); XCTAssertEqual(s.turns[0].iterations[0].content, "Hello world!")
    }
    func testTerminalSignalPreservesContent() {
        var s = ChatState(); s.applyProgress(j(#"{"turn_id":1,"phase":"streaming","stream_content":"保留这段文字"}"#))
        s.applyProgress(j(#"{"phase":"done"}"#))
        XCTAssertFalse(s.busy); XCTAssertEqual(s.liveTurn, 0); XCTAssertEqual(s.turns[0].iterations[0].content, "保留这段文字")
    }
    func testCompletionOnlyHistoryIsIdle() {
        var s = ChatState(); s.loadHistory(j(#"{"processing":false,"messages":[],"active_progress":{"phase":"done","turn_id":0,"iteration":0}}"#))
        XCTAssertFalse(s.busy); XCTAssertTrue(s.turns.isEmpty)
    }
    func testReasoningAndToolsMergeAcrossIterations() {
        var s = ChatState()
        s.applyProgress(j(#"{"turn_id":2,"iteration":1,"phase":"running","reasoning_stream_delta":"想","active_tools":[{"call_id":"c","name":"search","status":"running","args":"query"}]}"#))
        s.applyProgress(j(#"{"turn_id":2,"iteration":1,"phase":"running","reasoning_stream_delta":"法","completed_tools":[{"call_id":"c","name":"search","status":"done","detail":"found","elapsed_ms":50}]}"#))
        s.applyProgress(j(#"{"turn_id":2,"iteration":2,"phase":"running","content":"结果"}"#))
        XCTAssertEqual(s.turns[0].iterations.count, 2)
        let first = s.turns[0].iterations[0]
        XCTAssertEqual(first.reasoning, "想法"); XCTAssertEqual(first.tools.count, 1)
        XCTAssertEqual(first.tools[0].status, "done"); XCTAssertEqual(first.tools[0].args, "query"); XCTAssertEqual(first.tools[0].output, "found")
    }
    func testAcceptedQueuedTurnDoesNotReplaceLiveTurn() {
        var s = ChatState(); s.applyProgress(j(#"{"turn_id":1,"phase":"running","stream_delta":"a"}"#))
        s.accepted(text: "later", response: j(#"{"turn_id":2,"queued":true}"#))
        XCTAssertEqual(s.liveTurn, 1); XCTAssertEqual(s.turns.count, 2)
    }
    func testPostResponseAfterSSECompletionDoesNotSetBusyAgain() {
        var s = ChatState(); s.apply(j(#"{"type":"text","turn_id":1,"content":"done"}"#))
        s.accepted(text: "question", response: j(#"{"turn_id":1}"#))
        XCTAssertFalse(s.busy); XCTAssertEqual(s.turns[0].user, "question")
    }
    func testAskUserStringPayloadAndResolutionID() {
        var s = ChatState()
        s.apply(j(#"{"type":"ask_user","content":"{\"request_id\":\"r1\",\"questions\":\"[{\\\"question\\\":\\\"choose\\\",\\\"options\\\":[\\\"A\\\",\\\"B\\\"],\\\"multi_select\\\":true}]\"}"}"#))
        XCTAssertEqual(s.ask?.id, "r1"); XCTAssertTrue(s.ask?.questions.first?.multiple == true)
        s.apply(j(#"{"type":"ask_user_resolved","request_id":"r2"}"#)); XCTAssertNotNil(s.ask)
        s.apply(j(#"{"type":"ask_user_resolved","request_id":"r1"}"#)); XCTAssertNil(s.ask)
    }
    func testStructuredAskUser() {
        var s = ChatState(); s.apply(j(#"{"type":"ask_user","progress":{"request_id":"r","questions":[{"question":"Q","allow_other":true}]}}"#))
        XCTAssertEqual(s.ask?.questions.first?.question, "Q"); XCTAssertTrue(s.ask?.questions.first?.allowOther == true)
    }
    func testHistoryNestedUserAndOlderPagePreserveLiveTail() {
        var s = ChatState()
        s.loadHistory(j(#"{"messages":[{"turn_id":2,"role":"assistant","content":"new","turn_user":{"history_id":20,"content":"question"}}],"has_more":true,"oldest_id":20}"#))
        s.applyProgress(j(#"{"turn_id":3,"phase":"running","stream_delta":"live"}"#))
        s.loadHistory(j(#"{"messages":[{"turn_id":1,"role":"assistant","content":"old"},{"turn_id":2,"role":"assistant","content":"stale"}],"has_more":false,"oldest_id":1}"#), prepend: true)
        XCTAssertEqual(s.turns.map(\.id), [1, 2, 3]); XCTAssertEqual(s.turns[1].final, "new")
        XCTAssertEqual(s.turns[1].historyID, 20); XCTAssertEqual(s.turns[1].user, "question")
        XCTAssertEqual(s.turns.last?.iterations.first?.content, "live"); XCTAssertTrue(s.busy)
    }
    func testStandaloneCommandReplyAndCancellation() {
        var s = ChatState(); s.apply(j(#"{"type":"text","turn_id":0,"content":"command output"}"#))
        XCTAssertEqual(s.turns.first?.final, "command output")
        s.applyProgress(j(#"{"turn_id":2,"phase":"running","stream_delta":"partial"}"#))
        s.apply(j(#"{"type":"text","turn_id":2,"content":"","cancelled":true}"#))
        XCTAssertFalse(s.busy); XCTAssertTrue(s.turns[1].cancelled); XCTAssertEqual(s.turns[1].iterations[0].content, "partial")
    }
    func testQueueAndResync() {
        var s = ChatState(); s.apply(j(#"{"type":"queue_state","queue_state":{"items":[{"preview":"pending"}]}}"#))
        XCTAssertEqual(s.queue, ["pending"])
        s.apply(j(#"{"type":"resync_required"}"#)); XCTAssertTrue(s.needsReload)
    }
}
