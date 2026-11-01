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
        // 缩略图内存缓存上限 40 MB、大图预览最多 3 张（约 40 MB），挂在后台时这部分内存白占着，
        // 系统在后台吃紧时更容易被 jetsam 掉（表现就是「切回来直接退出」）。
        // 进后台时丢掉；同时把**还在跑**的读取/解码掐掉 —— 只清缓存不清在途任务的话，
        // 后台峰值照样会被一张几十兆的图顶上去。回来按需从磁盘缓存重建，纯本地读取、不跑网络。
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                ThumbnailStore.shared.cancelAllInflight()
                ThumbnailStore.shared.clearMemoryCache()
                MediaStore.shared.cancelAllInflight()
                MediaStore.shared.clearMemoryCache()
                // 留个后台记号：下次启动靠它区分「后台被回收」和「前台消失」，
                // 顺便把当时的可用内存记下来（诊断页能看到）
                DiagnosticsStore.shared.noteBackground()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            DiagnosticsStore.shared.noteMemoryWarning()
            ThumbnailStore.shared.clearMemoryCache()
            MediaStore.shared.clearMemoryCache()
        }
    }
}
