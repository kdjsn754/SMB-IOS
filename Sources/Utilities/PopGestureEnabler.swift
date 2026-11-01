import UIKit

/// 修「退出全屏看图后，右滑返回要过半秒才认手」。
///
/// 现象（用户 2026-11-01 实测）：退出看图回到目录页，**上下滚、点文件夹都是立刻响应的**，
/// 只有「从左边往右滑返回上一级」要等半秒左右才生效 —— 说明触摸本身没有被人挡住，
/// 是 `interactivePopGestureRecognizer` 还停留在「modal 呈现期间被关掉」的状态。
///
/// 这里在模态退出后的一小段时间里做几次轻量检查：只把 `isEnabled` 重新置为 `true`，
/// **不动 `delegate`**（SwiftUI `NavigationStack` 的 delegate 有自己的判断，改它容易让
/// iOS 26 的返回手势彻底失效，见 HANDOFF 第 7 节 25）。
///
/// 两个安全前提：
/// 1. 只在 `viewControllers.count > 1` 时开启 —— 栈里只有根页面时开着手势，
///    是 iOS 上著名的「界面卡死」触发器。
/// 2. 只在 `isEnabled == false` 时才写，已经是 `true` 的绝不碰。
@MainActor
enum PopGestureEnabler {
    /// 模态退出后连续检查若干次。
    ///
    /// 为什么要「连续」：SwiftUI 会在退出转场结束后的若干个 runloop 里重新配置导航栏，
    /// 期间可能又把手势关一次；单次设置容易被覆盖掉。
    static func enableAfterModalDismiss(times: Int = 8, interval: TimeInterval = 0.08) {
        Task { @MainActor in
            for tick in 0..<times {
                if tick > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Task.isCancelled { return }
                }
                enableOnce()
            }
        }
    }

    private static func enableOnce() {
        guard let nav = currentNavigationController(),
              nav.viewControllers.count > 1,
              let pop = nav.interactivePopGestureRecognizer,
              pop.isEnabled == false
        else { return }
        pop.isEnabled = true
    }

    private static func currentNavigationController() -> UINavigationController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for window in scenes.flatMap(\.windows) where window.isKeyWindow {
            if let found = firstNavigationController(in: window.rootViewController) {
                return found
            }
        }
        return nil
    }

    private static func firstNavigationController(
        in controller: UIViewController?
    ) -> UINavigationController? {
        guard let controller else { return nil }
        if let nav = controller as? UINavigationController { return nav }
        if let nav = controller.navigationController { return nav }
        for child in controller.children {
            if let found = firstNavigationController(in: child) { return found }
        }
        if let presented = controller.presentedViewController {
            return firstNavigationController(in: presented)
        }
        return nil
    }
}
