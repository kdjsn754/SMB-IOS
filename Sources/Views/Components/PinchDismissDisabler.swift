import SwiftUI
import UIKit

/// 只关掉缩放转场自带的「双指捏合退出」，**保留下滑退出**。
///
/// 背景（用户 2026-11-01 实测）：1.3.17 放开系统交互式关闭之后，下滑退出和照片 App 一样顺了，
/// 但系统还附带一条「捏合退出」。照片 App 里它不碍事是因为捏合本来就在缩放图片、
/// 捏到 1x 以下才算退出；我们页内图片放大后的向内捏合是 `MagnifyGesture` 在缩小图片，
/// 两条手势同时识别，系统那条一赢整个页面就被关掉 —— 用户看到的是「缩小不起作用、直接退出」。
///
/// 公开 API 只有 `.interactiveDismissDisabled`，是「全关」、没有按手势粒度的开关；
/// 查证过社区方案（DabbyNdubisi 的 gist，iOS 26/27 可用）：唯一的办法是在呈现层级里
/// 找到系统那条私有捏合识别器（`_UITransformGestureRecognizer`）并**移除**。
/// 按「能用原生就原生」规则的交代：这不是有原生不用，而是原生没有提供按手势禁用的
/// 公开途径；最坏情况苹果改了类名 → 找不到识别器 → 退回「捏合也会退出」的现状，不会崩。
/// （只移除不 disable：系统在部分滑动后会重新启用被禁用的识别器，移除是彻底的。）
///
/// 1.3.32 修「还是有概率捏合退出」——旧实现只在 `updateUIViewController` 里扫
/// **12 次 × 200 ms**（转场期间识别器才挂上），扫不到就永久放弃；而且只扫
/// `UIViewController.view` 这一层，识别器如果挂在某个子视图上就永远看不见。
/// 改为 `PinchDismissGuard` 常驻守护：递归扫整棵视图树，页面存活期间持续扫。
///
/// 1.3.33 修「左右翻页后、刚切到新图时捏合**必定**退出」。两个洞：
/// 1. **翻页会触发系统重建识别器**。`isActive` 翻转 → `ZoomableImageView` 的 body 重算 →
///    `.simultaneousGesture` 重新安装，同时系统在滚动落定后把 `_UITransformGestureRecognizer`
///    又挂回来；而 1.3.32 的轮询在开页 3 秒之后降到了 **0.8 秒一次**，切页后正好落在这段
///    空档里 —— 手指捏下去的那 100~200 ms 内没人清理，系统直接判定退出。
/// 2. **页内 `MagnifyGesture` 在这一刻收不到手指**：切页时手势刚被重装，新识别器从
///    `.possible` 起步，接不住已经在屏上的两指 → `onChanged` 不触发 → 起手那一次
///    `enforce()` 也一起失效，等于唯一的「即时清理」正好在最需要的时刻缺席。
///
/// 现在改成「触摸落下即清 + 恒定短周期兜底」：
/// - **触摸探针**（`TouchProbeRecognizer`）：挂在窗口上的一个从不接收触摸的空识别器，
///   唯一作用是在手指**刚碰到屏幕**时（`shouldReceive`）立刻 `sweep()` 一遍，
///   再在下一拍 runloop 补一次 —— 早于系统判定「缩到阈值」，且完全不改变任何手势语义；
/// - 轮询改为**恒定 250 ms**（不再 3 秒后降频），兜住系统在任何时刻的重挂
///   （手指落下那一下已经由探针同步处理，轮询只是兜底，不需要更密）；
/// - 看图页 `index` 变化（翻页）时立刻 `enforce()` 一次。
struct PinchDismissDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        PinchGuardHost()
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        PinchDismissGuard.shared.attach(vc)
    }
}

/// 只用来拿到「当前处在哪个呈现层级」的宿主控制器。
private final class PinchGuardHost: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 转场落定后再补一次：识别器通常在这之后才真正挂上
        PinchDismissGuard.shared.enforce()
    }
}

/// 常驻守护：页面在，就一直盯着那条私有捏合识别器。
@MainActor
final class PinchDismissGuard: NSObject, UIGestureRecognizerDelegate {
    static let shared = PinchDismissGuard()

    /// 系统捏合退出识别器的私有类名（iOS 26/27，社区验证）。
    private static let targetClassNames: Set<String> = ["_UITransformGestureRecognizer"]

    /// 常驻轮询间隔。
    ///
    /// 「手指刚落下」这一刻已经由触摸探针同步兜住了（`shouldReceive` 里当场 `sweep()`），
    /// 轮询只是防止「手没动、系统自己把识别器挂回来」这种极端情况，不需要 100 ms 那么密。
    /// 屏幕上还压着底层目录页的上百个格子视图，整树遍历在主线程上跑，
    /// 100 ms 一次在退出转场期间是会抢帧的 —— 放到 250 ms，行为不变、开销降到 1/2.5。
    private static let pollInterval: UInt64 = 250_000_000

    private weak var host: UIViewController?
    /// 触摸探针：挂在窗口上、从不接收触摸，只在手指落下时触发清理。
    private var probe: UIGestureRecognizer?
    private var pollTask: Task<Void, Never>?
    /// 一笔触摸只排一次「下一拍再清」，避免一根手指排一个
    private var sweepQueued = false

    private override init() {
        super.init()
    }

    func attach(_ controller: UIViewController) {
        host = controller
        if pollTask == nil {
            startPolling()
        }
        enforce()
    }

    /// 立刻扫一遍。捏合手势一起手 / 触摸落下 / 翻页时调。
    func enforce() {
        _ = sweep()
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while true {
                guard let self else { return }
                // 页面被关掉之后宿主 VC 会被释放（weak），顺手停表并摘掉探针
                guard self.host != nil else {
                    self.pollTask = nil
                    self.teardownProbe()
                    return
                }
                _ = self.sweep()
                do {
                    try await Task.sleep(nanoseconds: Self.pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    // MARK: - 触摸探针

    /// 手指刚落屏就清一次：这是离系统判定退出最近的一个时机，
    /// 而且不依赖页内 SwiftUI 手势是否已经重新装好（1.3.33 的根因之一）。
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // 返回 false：探针不接收任何触摸，永远停在 .possible，不参与任何手势竞争
        MainActor.assumeIsolated {
            self.sweep()
            // 系统有可能在本次事件处理中把识别器重新挂上（翻页落定就在同一拍附近），
            // 下一拍 runloop 再清一次兜底
            guard !self.sweepQueued else { return }
            self.sweepQueued = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sweepQueued = false
                    _ = self.sweep()
                }
            }
        }
        return false
    }

    private func installProbe(on window: UIWindow) {
        if let probe, probe.view?.window === window { return }
        teardownProbe()
        // 无 target / 无 action 的空识别器：不会做任何事，只用来接 `shouldReceive` 回调
        let recognizer = UIGestureRecognizer(target: nil, action: nil)
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        window.addGestureRecognizer(recognizer)
        probe = recognizer
    }

    private func teardownProbe() {
        if let probe {
            probe.view?.removeGestureRecognizer(probe)
        }
        probe = nil
        sweepQueued = false
    }

    // MARK: - 扫描

    /// 从当前页面所在窗口的最外层往下扫整棵视图树。
    /// 走窗口而不是走 `parent` 链：识别器可能挂在呈现容器的子视图上，
    /// 那些视图不在任何 VC 的 `view` 属性上，靠 VC 链扫不到。
    @discardableResult
    private func sweep() -> Bool {
        guard let window = resolveWindow() else { return false }
        installProbe(on: window)
        return Self.remove(from: window)
    }

    private func resolveWindow() -> UIWindow? {
        if let window = host?.view.window { return window }
        return UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
    }

    @discardableResult
    private static func remove(from view: UIView) -> Bool {
        var found = false

        if let gestures = view.gestureRecognizers {
            for gesture in gestures where isPinchDismiss(gesture) {
                view.removeGestureRecognizer(gesture)
                found = true
            }
        }

        for subview in view.subviews where remove(from: subview) {
            found = true
        }

        return found
    }

    private static func isPinchDismiss(_ gesture: UIGestureRecognizer) -> Bool {
        let name = String(describing: type(of: gesture))
        if targetClassNames.contains(name) { return true }
        // 苹果若把类名微调（加前缀/后缀），按「含 TransformGestureRecognizer」兜一下
        return name.contains("TransformGestureRecognizer")
    }
}
