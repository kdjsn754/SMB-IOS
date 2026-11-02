import UIKit

/// 修「退出全屏看图后，右滑返回要过很久才认手」。
///
/// **iOS 26 起有两个返回手势识别器**（这是本问题的根源，2026-11-02 查证）：
/// - `interactivePopGestureRecognizer`：老的「左边缘右滑」；
/// - `interactiveContentPopGestureRecognizer`：iOS 26 新增的「内容区任意位置右滑」，
///   即用户说的「从屏幕中间右滑返回上级」（Apple Developer Forums / Stack Overflow 均有官方确认：
///   它"recognizes on the entire content area … and initiates an interactive pop"）。
///
/// 模态（`fullScreenCover`）呈现期间，系统会把**两个都关掉**；退出后 SwiftUI 恢复得慢，
/// 而且会在转场结束后的多个 runloop 里反复重配导航栏、可能又关一次。
/// 旧实现只恢复了边缘那个、且只查 8 次 × 0.08s（0.64s）就收工 —— 用户实测
/// 「内容区右滑要很久才能用」，就是它没被及时恢复。
///
/// 这里只把 `isEnabled` 重新置为 `true`，**不动 `delegate`**：iOS 26 上两个识别器
/// 的 delegate 都归私有 `_UINavigationInteractiveTransition` 所有，且系统在它前面
/// 还有一层私有的 `_gestureRecognizer:shouldReceiveEvent:` 拦截，替换 delegate
/// 会让返回手势彻底失效（HANDOFF 第 7 节 25 的教训）。
///
/// 两个安全前提：
/// 1. 只在 `viewControllers.count > 1` 时开启 —— 栈里只有根页面时开着手势，
///    是 iOS 上著名的「界面卡死」触发器；
/// 2. 只在 `isEnabled == false` 时才写，已经是 `true` 的绝不碰。
@MainActor
enum PopGestureEnabler {
    /// 模态退出后按**指数退避**轮询：立即一次，然后 0.08s 起步、每次翻倍，共 8 次，
    /// 总覆盖约 10 秒。
    ///
    /// 为什么用退避而不是固定间隔：恢复窗口有多长取决于系统转场收尾的时机，
    /// 固定 0.64s 的窗口实测不够；指数退避在关键的前半秒查得密、后面拖长尾巴兜底，
    /// 每次检查只是读两个属性，开销可以忽略。
    static func enableAfterModalDismiss() {
        Task { @MainActor in
            var delay: UInt64 = 80_000_000
            for tick in 0..<8 {
                if tick > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                    if Task.isCancelled { return }
                    delay *= 2
                }
                enableOnce(tick: tick)
            }
        }
    }

    private static func enableOnce(tick: Int) {
        guard let nav = currentNavigationController(),
              nav.viewControllers.count > 1
        else { return }

        // 两个都要恢复：iOS 26+ 上只恢复边缘那个，用户从屏幕中间右滑照样没反应
        var recognizers: [(UIGestureRecognizer, String)] = []
        if let edge = nav.interactivePopGestureRecognizer {
            recognizers.append((edge, "边缘右滑"))
        }
        if #available(iOS 26.0, *), let content = nav.interactiveContentPopGestureRecognizer {
            recognizers.append((content, "内容区右滑"))
        }

        for (gesture, label) in recognizers where gesture.isEnabled == false {
            gesture.isEnabled = true
            // 记进操作轨迹：真机上如果还有残留失灵，日志能直接看出是哪个识别器没恢复
            DiagnosticsStore.shared.note("退出看图：\(label)已恢复（第\(tick)轮）")
        }
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
