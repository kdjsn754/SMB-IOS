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
        // 进后台的清理，只动「真正的大头」：
        // ① 取消在途的读取/解码（几十兆的原图正读一半，这才是后台内存峰值来源）；
        // ② 清掉大图预览缓存（每张几十兆）。
        // **刻意不清缩略图内存缓存**：缩略图每张才几百 KB、上限 40 MB，它让「切回来不闪占位图」；
        // 而且它从来不是闪退主因（真凶 SIGPIPE 已在 1.3.7 修掉）。内存真告急时，
        // 下面 `didReceiveMemoryWarning` 会把全部缓存一起清掉，保命优先。
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                cameBackFromBackground = true
                DiagnosticsStore.shared.note("退到后台")
                ThumbnailStore.shared.cancelAllInflight()
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
