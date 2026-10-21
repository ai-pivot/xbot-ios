import Foundation

public struct SessionNotice: Sendable, Equatable {
    public enum Kind: String, Sendable { case completed, question }
    public let kind: Kind
    public let body: String
}

/// Tracks observation state only, never stores chat text in preferences.
public struct NotificationSnapshot: Codable, Sendable {
    public var initialized = false
    public var lastAssistantTurn: Int64 = 0
    public var lastQuestion = ""
    public var wasBusy = false
    public init() {}
    public mutating func reconcile(history: JSONValue, pending: JSONValue, reset: Bool = false) -> [SessionNotice] {
        if reset { self = Self() }
        let assistant = history["messages"].array.filter { $0["role"].string == "assistant" }.last
        let turn = assistant?["turn_id"].int ?? 0
        let busy = history["processing"].bool
        let question = pending["request_id"].string.nonEmpty ?? pending["questions"].array.first?["question"].string ?? ""
        var notices: [SessionNotice] = []
        if initialized {
            if !busy && (turn > lastAssistantTurn || (wasBusy && turn > 0)) {
                notices.append(SessionNotice(kind: .completed, body: assistant?["content"].string ?? "任务已完成"))
            }
            if !question.isEmpty && question != lastQuestion {
                notices.append(SessionNotice(kind: .question, body: pending["questions"].array.first?["question"].string ?? "Agent 需要你的回答"))
            }
        }
        initialized = true; lastAssistantTurn = max(lastAssistantTurn, turn); lastQuestion = question; wasBusy = busy
        return notices
    }
}
