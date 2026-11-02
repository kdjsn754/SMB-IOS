import SwiftUI
import UIKit

@main
@MainActor
struct SMBViewerApp: App {
    /// 只为播放页的横竖屏锁定存在：SwiftUI 没有 supportedInterfaceOrientations 的入口，
    /// 必须挂一个 delegate。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel()
    @AppStorage(SettingsKey.theme) private var themeRaw: String = AppTheme.light.rawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppDefaults.register()
        // 尽早装：崩溃只有在 handler 装好之后才记得下来。
        // 上一次的判定结果由它自己落盘（设置页已不展示，日志留着备用）。
        DiagnosticsStore.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(AppTheme.resolve(themeRaw).colorScheme)
                .task { app.bootstrap() }
                .onChange(of: scenePhase) { phase in
                    if phase != .active {
                        app.cache.autoCleanIfNeeded()
                    }
                }
                // 用户从多任务里划掉 App 时会走到这里：抹掉会话标记，
                // 免得下次启动把「正常关闭」误报成「被系统终止」。
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    DiagnosticsStore.shared.markCleanExit()
                }
        }
    }
}
