import SwiftUI

struct ToolCard: View {
    let tool: ChatTool
    let api: XbotAPI?
    private var running: Bool { ["running", "pending", "streaming", ""].contains(tool.status) }
    private var failed: Bool { ["error", "failed"].contains(tool.status) }
    var body: some View {
        if ContentSafety.shouldHide(tool.args + "\n" + tool.output) {
            Label("工具内容已因安全限制隐藏，可通过消息菜单举报", systemImage: "hand.raised").font(.footnote).foregroundStyle(.secondary)
        } else {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                if !tool.args.isEmpty {
                    Text("参数").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) { Text(tool.args).font(.caption.monospaced()).textSelection(.enabled) }
                }
                if !tool.summary.isEmpty && !tool.detail.isEmpty {
                    Text("摘要").font(.caption).foregroundStyle(.secondary)
                    MarkdownText(text: tool.summary, api: api).font(.subheadline)
                }
                if !tool.output.isEmpty {
                    Text("输出").font(.caption).foregroundStyle(.secondary)
                    MarkdownText(text: tool.output, api: api).font(.subheadline)
                }
                if tool.args.isEmpty && tool.output.isEmpty { Text("等待工具返回结果…").font(.caption).foregroundStyle(.secondary) }
            }.padding(.top, 12)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: failed ? "exclamationmark.circle" : running ? "gearshape.2" : "checkmark.circle")
                    .foregroundStyle(failed ? .red : Theme.accent)
                Text(tool.name.nonEmpty ?? "工具调用").font(.subheadline.weight(.medium)).foregroundStyle(Color.primary)
                Spacer()
                Text(running ? "执行中" : failed ? "失败" : "完成").font(.caption2).foregroundStyle(Color.secondary)
                if tool.elapsed > 0 { Text(String(format: "%.1fs", Double(tool.elapsed) / 1000)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
            }
        }.padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// Native Markdown blocks; only Mermaid uses an isolated offline WebKit renderer.
struct MarkdownText: View {
    let text: String
    var api: XbotAPI?
    var body: some View {
        if ContentSafety.shouldHide(text) {
            Label("内容已因安全限制隐藏，可通过消息菜单举报", systemImage: "hand.raised").font(.footnote).foregroundStyle(.secondary)
        } else {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let content): inline(content)
                case .heading(let level, let content): inline(content).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                case .listItem(let marker, let content, let indent):
                    HStack(alignment: .top, spacing: 8) { Text(marker).foregroundStyle(.secondary); inline(content) }.padding(.leading, CGFloat(indent) * 12)
                case .quote(let content):
                    HStack(alignment: .top, spacing: 10) { Rectangle().fill(Theme.accent.opacity(0.4)).frame(width: 3); MarkdownText(text: content, api: api).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
                case .code(let language, let source): codeBlock(language: language, source: source)
                case .mermaid(let code): MermaidView(code: code)
                case .image(let alt, let reference): MessageImage(reference: reference, alt: alt, api: api)
                case .table(let headers, let rows, let alignments): markdownTable(headers, rows: rows, alignments: alignments)
                case .rule: Divider().padding(.vertical, 4)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
        }
    }
    private func inline(_ value: String) -> some View {
        Text(attributed(value))
            .textSelection(.enabled).lineSpacing(5)
    }
    private func attributed(_ source: String) -> AttributedString {
        var result = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        let plain = String(result.characters)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let range = Range(match.range, in: plain), let url = match.url else { continue }
                let start = result.index(result.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: range.lowerBound))
                let end = result.index(start, offsetByCharacters: plain.distance(from: range.lowerBound, to: range.upperBound))
                if result[start..<end].link == nil { result[start..<end].link = url }
            }
        }
        return result
    }
    private func codeBlock(language: String, source: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(language.nonEmpty ?? "代码"); Spacer(); Button { UIPasteboard.general.string = source } label: { Label("复制", systemImage: "doc.on.doc") } }.font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) { Text(source).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }
        }.padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    private func markdownTable(_ headers: [String], rows: [[String]], alignments: [TableAlignment]) -> some View {
        let count = max(headers.count, rows.map(\.count).max() ?? 0)
        return ScrollView(.horizontal) {
            VStack(spacing: 0) {
                tableRow(headers, count: count, alignments: alignments, header: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(row, count: count, alignments: alignments, header: false).background(index.isMultiple(of: 2) ? Color(.tertiarySystemFill) : Color.clear)
                }
            }.overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), lineWidth: 0.5)).clipShape(RoundedRectangle(cornerRadius: 8))
        }.accessibilityIdentifier("markdown-table")
    }
    private func tableRow(_ cells: [String], count: Int, alignments: [TableAlignment], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                let alignment = index < alignments.count ? alignments[index] : .leading
                inline(index < cells.count ? cells[index] : "").font(header ? .subheadline.bold() : .subheadline)
                    .frame(width: 164, alignment: alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
                    .padding(10)
            }
        }.background(header ? Color(.secondarySystemBackground) : Color.clear)
    }
}

private struct MessageImage: View {
    let reference: String
    let alt: String
    let api: XbotAPI?
    @AppStorage("mediaBaseURL") private var mediaBase = ""
    @State private var image: UIImage?
    @State private var failed = false
    @State private var fullscreen = false
    var body: some View {
        Group {
            if let image {
                Button { fullscreen = true } label: {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 440).clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottomTrailing) { Image(systemName: "arrow.up.left.and.arrow.down.right").padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(6) }
                }.buttonStyle(.plain).accessibilityLabel(alt.nonEmpty ?? "放大图片").accessibilityIdentifier("message-image")
            }
            else if failed { VStack(alignment: .leading, spacing: 6) { Label(alt.nonEmpty ?? "无法加载图片", systemImage: "photo.badge.exclamationmark"); Text(reference).textSelection(.enabled).lineLimit(3) }.font(.caption).foregroundStyle(.secondary) }
            else { ProgressView().frame(height: 80) }
        }.task(id: reference + mediaBase) {
            image = nil; failed = false
            guard let url = MediaURLResolver.resolve(reference, server: api?.baseURL, mediaBase: mediaBase) else { failed = true; return }
            do {
                let data: Data
                if let api { data = try await api.mediaData(url) }
                else { let (bytes, _) = try await URLSession.shared.data(from: url); data = bytes }
                try Task.checkCancellation()
                guard let decoded = UIImage(data: data) else { throw ServerError("图片加载失败") }
                image = decoded
            } catch { if !Task.isCancelled { failed = true } }
        }
        .fullScreenCover(isPresented: $fullscreen) { if let image { ImagePreview(image: image, title: alt) } }
    }
}
