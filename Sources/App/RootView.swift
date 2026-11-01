import SwiftUI
import UIKit

@MainActor
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var app: AppModel

    /// 这次是不是「真的进过后台再回来」。
    ///
    /// `.active` 不只从后台回来时触发：下拉控制中心、拉通知中心、来电都会走
    /// `.inactive → .active`。那种情况下连接是好的，不能跟着作废，否则每拉一次
    /// 控制中心就要重连一次 SMB。
    @State private var cameBackFromBackground = false

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
            switch phase {
            case .background:
                cameBackFromBackground = true
                DiagnosticsStore.shared.note("退到后台")
                ThumbnailStore.shared.cancelAllInflight()
                ThumbnailStore.shared.clearMemoryCache()
                MediaStore.shared.cancelAllInflight()
                MediaStore.shared.clearMemoryCache()
                // 留个后台记号：下次启动靠它区分「后台被回收」和「前台消失」，
                // 顺便把当时的内存占用记下来（诊断页能看到）
                DiagnosticsStore.shared.noteBackground()
            case .active:
                if cameBackFromBackground {
                    cameBackFromBackground = false
                    DiagnosticsStore.shared.note("回到前台")
                    // 回前台第一件事：撤掉后台记号。否则之后任何一次前台闪退，下次启动都会被
                    // 判成「后台结束（无崩溃记录）」—— 真正的闪退永远看不见（1.3.6 及之前就是这样）。
                    DiagnosticsStore.shared.noteForeground()
                    // 挂后台期间 SMB 的 socket 大概率已经被对端回收。这里把旧连接全部作废，
                    // 让下一次真正的操作去建新连接 —— 继续用旧 socket 的话，轻则每个请求先挂
                    // 30 秒超时（回来缩略图全空），重则往死 socket 上写触发 SIGPIPE 被内核杀掉。
                    app.invalidateConnections()
                }
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            DiagnosticsStore.shared.noteMemoryWarning()
            DiagnosticsStore.shared.note("收到内存警告")
            ThumbnailStore.shared.clearMemoryCache()
            MediaStore.shared.clearMemoryCache()
        }
    }
}
