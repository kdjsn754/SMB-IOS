import SwiftUI

@main
@MainActor
struct SMBViewerApp: App {
    @StateObject private var app = AppModel()
    @AppStorage(SettingsKey.theme) private var themeRaw: String = AppTheme.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppDefaults.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme)
                .task { app.bootstrap() }
                .onChange(of: scenePhase) { phase in
                    if phase != .active {
                        app.cache.autoCleanIfNeeded()
                    }
                }
        }
    }
}
