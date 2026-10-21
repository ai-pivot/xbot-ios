import Foundation

public enum TableAlignment: Sendable, Equatable { case leading, center, trailing }
public enum MarkdownBlock: Sendable, Equatable {
    case paragraph(String), heading(Int, String), quote(String)
    case listItem(marker: String, text: String, indent: Int)
    case code(language: String, text: String), mermaid(String)
    case image(alt: String, url: String)
    case table(headers: [String], rows: [[String]], alignments: [TableAlignment])
    case rule
}

public enum MarkdownParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = [], paragraph: [String] = []
        var index = 0
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        while index < lines.count {
            let line = lines[index], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); index += 1; continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix { $0 == trimmed.first })
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var source: [String] = []; index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { source.append(lines[index]); index += 1 }
                if index < lines.count { index += 1 }
                let code = source.joined(separator: "\n")
                blocks.append(language.lowercased() == "mermaid" ? .mermaid(code) : .code(language: language, text: code))
                continue
            }
            if index + 1 < lines.count, let alignment = tableSeparator(lines[index + 1]), line.contains("|") {
                flush()
                let headers = splitRow(line); var rows: [[String]] = []; index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(splitRow(lines[index])); index += 1
                }
                blocks.append(.table(headers: headers, rows: rows, alignments: alignment)); continue
            }
            if let heading = captures("^(#{1,6})\\s+(.+?)(?:\\s+#+)?$", trimmed) {
                flush(); blocks.append(.heading(heading[0].count, heading[1])); index += 1; continue
            }
            if trimmed.hasPrefix(">") {
                flush(); var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let value = String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
                    quote.append(value.hasPrefix(" ") ? String(value.dropFirst()) : value); index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n"))); continue
            }
            if let image = captures("^!\\[([^\\]]*)\\]\\((.+?)(?:\\s+\"[^\"]*\")?\\)$", trimmed) {
                flush(); blocks.append(.image(alt: image[0], url: image[1])); index += 1; continue
            }
            if let item = captures("^([ \\t]*)([-+*]|[0-9]+[.)])\\s+(.+)$", line) {
                flush(); blocks.append(.listItem(marker: ["-", "+", "*"].contains(item[1]) ? "•" : item[1], text: item[2], indent: min(8, item[0].replacingOccurrences(of: "\t", with: "    ").count / 2)))
                index += 1; continue
            }
            if trimmed.range(of: "^(?:\\*\\s*){3,}$|^(?:-\\s*){3,}$|^(?:_\\s*){3,}$", options: .regularExpression) != nil {
                flush(); blocks.append(.rule); index += 1; continue
            }
            paragraph.append(line); index += 1
        }
        flush(); return blocks
    }
    private static func captures(_ pattern: String, _ input: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else { return nil }
        return (1..<match.numberOfRanges).map { i in Range(match.range(at: i), in: input).map { String(input[$0]) } ?? "" }
    }
    public static func splitRow(_ row: String) -> [String] {
        var text = row.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|") && !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = [], cell = "", escaped = false, inCode = false
        for character in text {
            if escaped { cell.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "`" { inCode.toggle() }
            if character == "|" && !inCode { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces)); return cells
    }
    private static func tableSeparator(_ line: String) -> [TableAlignment]? {
        let cells = splitRow(line)
        guard !cells.isEmpty, cells.allSatisfy({ $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }) else { return nil }
        return cells.map { value in value.hasPrefix(":") && value.hasSuffix(":") ? .center : value.hasSuffix(":") ? .trailing : .leading }
    }
}
