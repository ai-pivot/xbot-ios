import Foundation

public struct SSEFrame: Equatable, Sendable {
    public var id: String = ""
    public var event: String = ""
    public var data: String = ""
}

/// Dispatches only complete events, supports multiline data and ignores comments.
public struct SSEParser: Sendable {
    private var frame = SSEFrame()
    private var dataLines: [String] = []
    public init() {}
    public mutating func consume(_ raw: String) -> SSEFrame? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty {
            defer { frame = SSEFrame(); dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            frame.data = dataLines.joined(separator: "\n")
            return frame
        }
        if line.hasPrefix(":") { return nil }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch parts.first {
        case "data": dataLines.append(value)
        case "event": frame.event = value
        case "id": if !value.contains("\0") { frame.id = value }
        default: break
        }
        return nil
    }
}

/// URLSession.AsyncBytes.lines drops empty lines, which are significant in SSE.
/// Decode complete UTF-8 lines directly from bytes, retaining all event boundaries.
public struct SSEByteParser: Sendable {
    private var line: [UInt8] = []
    private var parser = SSEParser()
    private var previousCR = false
    private var firstLine = true
    public init() {}
    public mutating func consume(_ byte: UInt8) -> SSEFrame? {
        if previousCR {
            previousCR = false
            if byte == 10 { return nil }
        }
        if byte == 13 { previousCR = true; return flushLine() }
        if byte == 10 { return flushLine() }
        line.append(byte)
        return nil
    }
    private mutating func flushLine() -> SSEFrame? {
        var text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if firstLine {
            firstLine = false
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        return parser.consume(text)
    }
}

public struct EventCursor: Sendable {
    public var sequence: Int64
    public init(sequence: Int64 = 0) { self.sequence = sequence }
    public mutating func accept(_ event: JSONValue, frameID: String, chatID: String, channel: String) -> Bool {
        let incoming = Int64(frameID) ?? event["seq"].int
        if incoming > 0 && incoming <= sequence { return false }
        let route = event["route_chat_id"].string.nonEmpty ?? event["chat_id"].string.nonEmpty ?? event["session"]["chat_id"].string
        let routeChannel = event["route_channel"].string.nonEmpty ?? event["channel"].string
        if (!route.isEmpty && route != chatID) || (!routeChannel.isEmpty && routeChannel != channel) { return false }
        if incoming > 0 { sequence = incoming }
        return true
    }
}
