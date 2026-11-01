import SwiftUI
import UIKit

@MainActor
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            ServerListView()
                .tabItem { Label("资源库", systemImage: "externaldrive.connected.to.line.below") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        // 缩略图内存缓存上限 64 MB、大图预览最多 4 张（约 55 MB），挂在后台时这部分内存白占着，
        // 系统在后台吃紧时更容易被 jetsam 掉（表现就是「切回来直接退出」）。
        // 进后台时丢掉，回来按需从磁盘缓存重建，纯本地读取、不跑网络。
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                ThumbnailStore.shared.clearMemoryCache()
                MediaStore.shared.clearMemoryCache()
                // 留个后台记号：下次启动靠它区分「后台被回收/被划掉」和「前台消失」
                DiagnosticsStore.shared.noteBackground()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            ThumbnailStore.shared.clearMemoryCache()
            MediaStore.shared.clearMemoryCache()
        }
    }
}
