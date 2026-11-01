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
struct PinchDismissDisabler: UIViewControllerRepresentable {
    /// 系统捏合退出识别器的私有类名（iOS 26/27，社区验证）。
    private static let pinchDismissClass = "_UITransformGestureRecognizer"

    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        vc.view.isUserInteractionEnabled = false
        return vc
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        // 手势识别器在呈现转场稳定之后才挂上，扫多几轮确保抓到；
        // 抓到就停，没抓到（类名被苹果改掉）就安静放弃，行为退回系统默认。
        Task { @MainActor in
            for _ in 0..<12 {
                if Self.sweepAndRemove(from: vc) { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// 从本节点沿 parent 链爬到呈现层级的根部，再向下递归清一遍。
    @MainActor
    private static func sweepAndRemove(from vc: UIViewController) -> Bool {
        var top = vc
        while let parent = top.parent { top = parent }
        return remove(from: top)
    }

    @MainActor
    private static func remove(from vc: UIViewController) -> Bool {
        var found = false

        if let gestures = vc.view.gestureRecognizers {
            for gesture in gestures where String(describing: type(of: gesture)) == pinchDismissClass {
                vc.view.removeGestureRecognizer(gesture)
                found = true
            }
        }

        for child in vc.children where remove(from: child) {
            found = true
        }
        if let presented = vc.presentedViewController, remove(from: presented) {
            found = true
        }

        return found
    }
}
