import SwiftUI

@MainActor @Observable
final class UpdateController {
    static let shared = UpdateController()
    var manifest: ReleaseManifest?
    var checking = false
    var error: String?
    var message: String?
    var manifestURL = UserDefaults.standard.string(forKey: "updateManifestURL") ?? "" {
        didSet {
            if oldValue != manifestURL { manifest = nil; message = nil; error = nil }
            UserDefaults.standard.set(manifestURL, forKey: "updateManifestURL")
        }
    }
    var lastChecked: Date? {
        let time = UserDefaults.standard.double(forKey: "updateCheck:" + manifestURL)
        return time > 0 ? Date(timeIntervalSince1970: time) : nil
    }
    var installedVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0" }
    var installedBuild: Int64 { Int64(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") ?? 1 }
    var available: Bool { manifest?.isNewer(version: installedVersion, build: installedBuild) == true }
    func check(manual: Bool) async {
        guard !checking else { return }
        let raw = manifestURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { if manual { error = "请先填写 iOS 更新清单地址" }; return }
        if !manual, manifest != nil, let date = lastChecked, Date().timeIntervalSince(date) < 6 * 3600 { return }
        checking = true; defer { checking = false }; error = nil; message = nil
        do {
            guard let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw ServerError("更新清单地址无效") }
            try TransportSecurity.validate(url)
            let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 1024 * 1024 else { throw ServerError("无法获取有效的更新清单") }
            let decoded = try ReleaseManifest(JSONDecoder().decode(JSONValue.self, from: data))
            guard manifestURL.trimmingCharacters(in: .whitespacesAndNewlines) == raw else { return }
            manifest = decoded
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "updateCheck:" + manifestURL)
            message = available ? "发现新版本 \(decoded.version)" : "已是最新版本"
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

struct UpdateSettingsView: View {
    @State private var updates = UpdateController.shared
    var body: some View {
        @Bindable var updates = updates
        Form {
            Section("当前版本") { LabeledContent("版本", value: "\(updates.installedVersion) (\(updates.installedBuild))") }
            Section {
                TextField("https://…/ios/latest.json", text: $updates.manifestURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("update-url-field")
                Button { Task { await updates.check(manual: true) } } label: { HStack { Text("检查更新"); if updates.checking { Spacer(); ProgressView() } } }.disabled(updates.checking).accessibilityIdentifier("check-update-button")
                if let date = updates.lastChecked { LabeledContent("上次检查", value: date.formatted(date: .abbreviated, time: .shortened)) }
            } header: { Text("iOS 更新清单") } footer: { Text("使用 iOS 专用更新清单。新版本通过 App Store 或 TestFlight 安装。") }
            if let error = updates.error { Section { ErrorBanner(text: error) } }
            if let message = updates.message { Section { Label(message, systemImage: updates.available ? "arrow.down.circle" : "checkmark.circle").foregroundStyle(Theme.accent) } }
            if let manifest = updates.manifest, updates.available {
                Section("新版本 \(manifest.version)") {
                    if manifest.mandatory { Label("此版本标记为必要更新", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                    if !manifest.changelog.isEmpty { MarkdownText(text: manifest.changelog) }
                    if !manifest.publishedAt.isEmpty { Text(manifest.publishedAt).font(.caption).foregroundStyle(.secondary) }
                    Link(destination: manifest.url) { Label(manifest.url.host == "testflight.apple.com" ? "前往 TestFlight 更新" : "前往 App Store 更新", systemImage: "arrow.up.right.square") }.accessibilityIdentifier("install-update-link")
                }
            }
        }.navigationTitle("版本更新").navigationBarTitleDisplayMode(.inline)
    }
}
