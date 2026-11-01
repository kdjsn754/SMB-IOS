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
/// 现在改为 `PinchDismissGuard` 常驻守护：
/// 1. **整个视图树**递归扫（不再只扫 VC 的根视图）；
/// 2. 页面存活期间**持续**扫（前 3 秒 150 ms 一次兜住转场，之后 0.8 s 一次兜住系统重建），
///    遍历成本是微秒级，比一次缩略图解码便宜得多；
/// 3. 页内 `MagnifyGesture` 一发力就 `enforce()` 立刻清一次 —— 就算识别器是在
///    捏合开始前一瞬才挂上的，也会在它够到退出阈值之前被移除。
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
final class PinchDismissGuard {
    static let shared = PinchDismissGuard()

    /// 系统捏合退出识别器的私有类名（iOS 26/27，社区验证）。
    private static let targetClassNames: Set<String> = ["_UITransformGestureRecognizer"]

    private weak var host: UIViewController?
    private var pollTask: Task<Void, Never>?

    private init() {}

    func attach(_ controller: UIViewController) {
        host = controller
        if pollTask == nil {
            startPolling()
        }
        enforce()
    }

    /// 立刻扫一遍。捏合手势一起手就调，避免「识别器比轮询晚一步挂上」。
    func enforce() {
        _ = sweep()
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                // 页面被关掉之后宿主 VC 会被释放（weak），这里顺手停掉轮询
                guard self.host != nil else {
                    self.pollTask = nil
                    return
                }
                _ = self.sweep()
                // 前 3 秒密集（转场 / 首帧期间识别器才挂上），之后降频但仍持续，
                // 兜住「系统在翻页或某些滑动之后重建识别器」
                let interval: UInt64 = tick < 20 ? 150_000_000 : 800_000_000
                tick += 1
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// 从当前页面所在窗口的最外层往下扫整棵视图树。
    /// 走窗口而不是走 `parent` 链：识别器可能挂在呈现容器的子视图上，
    /// 那些视图不在任何 VC 的 `view` 属性上，靠 VC 链扫不到。
    @discardableResult
    private func sweep() -> Bool {
        guard let host, let window = host.view.window ?? UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first
        else { return false }
        return Self.remove(from: window)
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
