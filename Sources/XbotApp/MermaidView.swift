import SwiftUI
import WebKit

struct MermaidView: View {
    let code: String
    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 180
    @State private var state = "正在绘制图表…"
    @State private var fullscreen = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Mermaid", systemImage: "point.3.connected.trianglepath.dotted").font(.caption)
                Spacer()
                Button { UIPasteboard.general.string = code } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("复制图表源码")
                Button { fullscreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("放大图表").accessibilityIdentifier("mermaid-expand")
            }.foregroundStyle(.secondary)
            MermaidCanvas(code: code, dark: scheme == .dark, interactive: false, height: $height, state: $state)
                .frame(height: height).overlay { Color.clear.contentShape(Rectangle()).onTapGesture { fullscreen = true } }
            Text(state).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("mermaid-status")
        }.padding(12).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .fullScreenCover(isPresented: $fullscreen) {
                NavigationStack {
                    MermaidCanvas(code: code, dark: scheme == .dark, interactive: true, height: $height, state: $state)
                        .navigationTitle("图表预览").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { fullscreen = false }.accessibilityIdentifier("mermaid-preview-close") } }
                }
            }
    }
}

private struct MermaidCanvas: UIViewRepresentable {
    let code: String
    let dark: Bool
    let interactive: Bool
    @Binding var height: CGFloat
    @Binding var state: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "diagram")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = interactive; web.isUserInteractionEnabled = interactive
        web.navigationDelegate = context.coordinator
        web.accessibilityLabel = "Mermaid 图表"; web.accessibilityIdentifier = "mermaid-canvas"
        if let file = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Mermaid") {
            web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        } else { state = "缺少离线图表资源" }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render(web)
    }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading(); web.configuration.userContentController.removeScriptMessageHandler(forName: "diagram"); web.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MermaidCanvas
        private var ready = false
        private var rendered = ""
        init(_ parent: MermaidCanvas) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; render(webView) }
        func render(_ web: WKWebView) {
            let key = parent.code + String(parent.dark) + String(parent.interactive)
            guard ready && rendered != key else { return }; rendered = key
            Task { [weak self] in
                guard let self else { return }
                do { _ = try await web.callAsyncJavaScript("await window.renderDiagram(code, dark, interactive)", arguments: ["code": self.parent.code, "dark": self.parent.dark, "interactive": self.parent.interactive], in: nil, contentWorld: .page) }
                catch { self.parent.state = "图表渲染失败，可复制源码重试" }
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
            if !parent.interactive, let value = body["height"] as? Double, value.isFinite { parent.height = min(1600, max(80, value)) }
            parent.state = (body["error"] as? String)?.nonEmpty ?? "图表已渲染"
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Diagrams are untrusted content. They can never navigate to the network.
            navigationAction.request.url?.isFileURL == true ? .allow : .cancel
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.state = "图表加载失败" }
    }
}
