import Foundation

public struct ChatSession: Identifiable, Hashable, Sendable {
    public let chatID: String
    public let channel: String
    public var title: String
    public let preview: String
    public let running: Bool
    public let status: String
    public let lastActive: String
    public let children: [ChatSession]
    public var id: String { channel + ":" + chatID }
    public init(_ json: JSONValue) {
        chatID = json["chat_id"].string; channel = json["channel"].string.nonEmpty ?? "web"
        title = json["label"].string.nonEmpty ?? "新会话"; preview = json["preview"].string
        status = json["status"].string; lastActive = json["last_active"].string
        running = json["running"].bool; children = json["children"].array.map(Self.init)
    }
}

public struct ChatTool: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var status: String
    public var args: String
    public var summary: String
    public var detail: String
    public var output: String { detail.nonEmpty ?? summary }
    public var elapsed: Int64
    public init(_ j: JSONValue, iteration: Int64 = 1) {
        id = j["call_id"].string.nonEmpty ?? j["id"].string.nonEmpty ?? "\(j["name"].string)_\(iteration)_\(j["label"].string)"
        name = j["label"].string.nonEmpty ?? j["name"].string
        status = j["status"].string; args = j["args"].display
        if j["args"].isNull { args = "" }
        summary = j["summary"].string; detail = j["detail"].string
        elapsed = max(j["elapsed_ms"].int, j["elapsed"].int)
    }
    mutating func merge(_ newer: Self) {
        if !newer.name.isEmpty { name = newer.name }
        if !newer.status.isEmpty { status = newer.status }
        if !newer.args.isEmpty { args = newer.args }
        if !newer.summary.isEmpty { summary = newer.summary }
        if !newer.detail.isEmpty { detail = newer.detail }
        elapsed = max(elapsed, newer.elapsed)
    }
}

public struct ChatIteration: Identifiable, Sendable, Equatable {
    public var id: Int64
    public var content = ""
    public var reasoning = ""
    public var tools: [ChatTool] = []
    public init(id: Int64) { self.id = id }
    mutating func mergeTools(_ incoming: [ChatTool]) {
        for tool in incoming {
            if let i = tools.firstIndex(where: { $0.id == tool.id }) { tools[i].merge(tool) }
            else { tools.append(tool) }
        }
    }
}

public struct ChatTurn: Identifiable, Sendable, Equatable {
    public var id: Int64
    public var user = ""
    public var historyID: Int64 = 0
    public var final = ""
    public var iterations: [ChatIteration] = []
    public var cancelled = false
    public init(id: Int64) { self.id = id }
}

public struct AskQuestion: Identifiable, Sendable, Equatable {
    public var id: String { question }
    public var question: String
    public var options: [String]
    public var multiple: Bool
    public var allowOther: Bool
    public init(_ j: JSONValue) {
        question = j["question"].string; options = j["options"].array.map(\.string)
        multiple = j["multi_select"].bool; allowOther = j["allow_other"].bool
    }
}
public struct AskPrompt: Identifiable, Sendable, Equatable {
    public var id: String
    public var questions: [AskQuestion]
}

/// Pure reducer: terminal signals retain content; checkpoints replace, deltas append.
public struct ChatState: Sendable, Equatable {
    public var turns: [ChatTurn] = []
    public var busy = false
    public var liveTurn: Int64 = 0
    public var hasMore = false
    public var oldestID: Int64 = 0
    public var ask: AskPrompt?
    public var queue: [String] = []
    public var needsReload = false
    public init() {}

    private mutating func turnIndex(_ id: Int64) -> Int {
        if let i = turns.firstIndex(where: { $0.id == id }) { return i }
        turns.append(ChatTurn(id: id)); return turns.count - 1
    }

    public mutating func loadHistory(_ response: JSONValue, prepend: Bool = false) {
        let live = self
        if !prepend { turns = []; liveTurn = 0; ask = nil; queue = [] }
        for m in response["messages"].array {
            let rawID = m["turn_id"].int
            let fallbackID = max(m["history_id"].int, m["id"].int)
            let id = rawID > 0 ? rawID : -max(fallbackID, Int64(turns.count + 1))
            // An older page must never overwrite the currently streaming tail.
            if prepend, live.turns.contains(where: { $0.id == id }) { continue }
            let i = turnIndex(id)
            switch m["role"].string {
            case "user":
                turns[i].user = m["content"].string; turns[i].historyID = fallbackID
            case "assistant":
                if !m["turn_user"].isNull {
                    turns[i].user = m["turn_user"]["content"].string
                    turns[i].historyID = max(m["turn_user"]["history_id"].int, m["turn_user"]["id"].int)
                }
                turns[i].final = m["content"].string
                for entry in m["iterations"].array { mergeIteration(entry, turn: i) }
                if m["iterations"].array.isEmpty, !m["reasoning_content"].string.isEmpty {
                    var it = ChatIteration(id: 1); it.reasoning = m["reasoning_content"].string
                    turns[i].iterations = [it]
                }
            case "tool":
                var it = turns[i].iterations.last ?? ChatIteration(id: 1)
                it.mergeTools([ChatTool(.object(["call_id": m["tool_call_id"], "name": m["tool_name"], "args": m["tool_arguments"], "detail": m["content"], "status": .string("done")]))])
                if turns[i].iterations.isEmpty { turns[i].iterations = [it] }
                else { turns[i].iterations[turns[i].iterations.count - 1] = it }
            default: break
            }
        }
        if prepend {
            let old = turns.filter { t in !live.turns.contains(where: { $0.id == t.id }) }
            turns = old + live.turns
        }
        hasMore = response["has_more"].bool; oldestID = response["oldest_id"].int; needsReload = false
        if !prepend {
            let active = response["active_progress"]
            busy = response["processing"].bool || (!active["phase"].string.isEmpty && !Self.terminal(active["phase"].string))
            if active["turn_id"].int > 0 || busy { applyProgress(active) }
        }
    }

    private mutating func mergeIteration(_ p: JSONValue, turn index: Int) {
        let number = max(1, p["iteration"].int)
        var it = turns[index].iterations.first(where: { $0.id == number }) ?? ChatIteration(id: number)
        if !p["stream_content"].string.isEmpty { it.content = p["stream_content"].string }
        else if !p["stream_delta"].string.isEmpty { it.content += p["stream_delta"].string }
        else if !p["content"].string.isEmpty { it.content = p["content"].string }
        if !p["reasoning_stream_content"].string.isEmpty { it.reasoning = p["reasoning_stream_content"].string }
        else if !p["reasoning_stream_delta"].string.isEmpty { it.reasoning += p["reasoning_stream_delta"].string }
        else if !p["reasoning"].string.isEmpty { it.reasoning = p["reasoning"].string }
        let tools = ["tools", "active_tools", "completed_tools", "streaming_tools", "tool_calls"].flatMap { p[$0].array }
        it.mergeTools(tools.map { ChatTool($0, iteration: number) })
        if let i = turns[index].iterations.firstIndex(where: { $0.id == number }) { turns[index].iterations[i] = it }
        else { turns[index].iterations.append(it) }
        turns[index].iterations.sort { $0.id < $1.id }
    }

    public mutating func applyProgress(_ p: JSONValue) {
        if p["resync_required"].bool { needsReload = true }
        let phase = p["phase"].string
        var id = p["turn_id"].int > 0 ? p["turn_id"].int : liveTurn
        if id <= 0, !p["turn_start"].isNull { id = (turns.map(\.id).max() ?? 0) + 1 }
        guard id > 0 else { if Self.terminal(phase) { busy = false; liveTurn = 0 }; return }
        let i = turnIndex(id)
        if !p["turn_start"]["content"].string.isEmpty { turns[i].user = p["turn_start"]["content"].string }
        for history in p["iteration_history"].array { mergeIteration(history, turn: i) }
        var current = p.object
        if p["iteration"].int == 0 { current["iteration"] = .number(Double(turns[i].iterations.last?.id ?? 1)) }
        mergeIteration(.object(current), turn: i)
        busy = !Self.terminal(phase); liveTurn = busy ? id : 0
        if Self.terminal(phase), !p["content"].string.isEmpty { turns[i].final = p["content"].string }
        if phase == "cancelled" { turns[i].cancelled = true }
    }

    public mutating func accepted(text: String, response: JSONValue) {
        let id = response["turn_id"].int
        guard id > 0 else { needsReload = true; return }
        let existing = turns.contains { $0.id == id }
        let i = turnIndex(id)
        if turns[i].user.isEmpty { turns[i].user = text }
        // The SSE completion may arrive before this POST returns.
        if !existing && !response["queued"].bool { busy = true; liveTurn = id }
    }

    public mutating func apply(_ event: JSONValue) {
        switch event["type"].string {
        case "progress_structured", "progress", "sync_progress", "stream_content", "turn_started":
            if !event["progress"].isNull { applyProgress(event["progress"]) }
        case "text":
            let id = event["turn_id"].int > 0 ? event["turn_id"].int : liveTurn
            if id <= 0 && event["content"].string.isEmpty { return }
            let i = turnIndex(id > 0 ? id : -(Int64(turns.count) + 1))
            if !event["content"].string.isEmpty { turns[i].final = event["content"].string }
            turns[i].cancelled = event["cancelled"].bool; busy = false; liveTurn = 0
        case "user_echo", "inject_user":
            let id = event["turn_id"].int
            if id > 0 { let i = turnIndex(id); turns[i].user = event["content"].string }
        case "session":
            switch event["session"]["action"].string {
            case "busy": busy = true
            case "idle", "deleted": busy = false; liveTurn = 0
            case "rewind", "rewound": needsReload = true
            default: break
            }
        case "ask_user":
            let p = event["progress"]
            let content = JSONValue.parse(event["content"].string) ?? .null
            var questions = p["questions"].array
            if questions.isEmpty {
                questions = content["questions"].array
                if questions.isEmpty { questions = JSONValue.parse(content["questions"].string)?.array ?? [] }
            }
            if !questions.isEmpty { ask = AskPrompt(id: p["request_id"].string.nonEmpty ?? content["request_id"].string, questions: questions.map(AskQuestion.init)) }
        case "ask_user_resolved":
            if event["request_id"].string.isEmpty || ask?.id == event["request_id"].string { ask = nil }
        case "queue_state": queue = event["queue_state"]["items"].array.map { $0["preview"].string.nonEmpty ?? $0["content"].string }
        case "resync_required": needsReload = true
        default: break
        }
    }
    private static func terminal(_ phase: String) -> Bool { ["done", "cancelled", "error"].contains(phase) }
}
