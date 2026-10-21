import SwiftUI

@main
struct XbotApp: App {
    @UIApplicationDelegateAdaptor(XbotAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AppStore()
    var body: some Scene {
        WindowGroup {
            ZStack {
                if let status = store.validationStatus {
                    VStack(spacing: 16) { BrandMark(size: 60); Text(status).accessibilityIdentifier("native-validation-status") }
                } else if store.restoring {
                    VStack(spacing: 20) { BrandMark(size: 64); ProgressView("正在连接工作空间…") }
                } else if store.authenticated { WorkspaceView() }
                else { LoginView() }
            }
            .environment(store)
            .tint(Theme.accent)
            .preferredColorScheme(store.colorScheme)
            .task { if store.restoring { await store.restore() } }
            .onChange(of: scenePhase) { _, phase in NotificationController.shared.visibility(phase) }
            .onReceive(NotificationCenter.default.publisher(for: .openXbotChat)) { note in store.routeNotification(note.userInfo) }
        }
    }
}

enum Theme {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.48, green: 0.76, blue: 0.64, alpha: 1)
            : UIColor(red: 0.19, green: 0.40, blue: 0.32, alpha: 1)
    })
    static let brand = Color(red: 0.19, green: 0.40, blue: 0.32)
    static let canvas = Color(.systemGroupedBackground)
    static let card = Color(.secondarySystemGroupedBackground)
}

struct BrandMark: View {
    var size: CGFloat = 42
    var body: some View {
        Image(systemName: "asterisk")
            .font(.system(size: size * 0.58, weight: .black))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.brand, in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

struct ErrorBanner: View {
    let text: String
    var dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.accessibilityLabel("关闭错误提示") }
        }
        .foregroundStyle(.red).padding(14).background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("error-banner")
    }
}

struct WorkspaceView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            SessionsView().tabItem { Label("会话", systemImage: "bubble.left.and.bubble.right") }.tag(0)
            SettingsView().tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag(1)
        }.task { if !store.preview { await UpdateController.shared.check(manual: false) } }
    }
}
