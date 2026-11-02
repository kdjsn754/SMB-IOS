import SwiftUI
import UIKit

/// 屏幕形态。播放页只用这两个：横屏 / 竖屏。
enum ScreenMode {
    case portrait
    case landscape

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .portrait: return .portrait
        case .landscape: return .landscape
        }
    }

    var toggled: ScreenMode {
        self == .portrait ? .landscape : .portrait
    }
}

/// 全 App 的方向闸门。
///
/// 只在播放页收窄成单一方向；平时是 `.allButUpsideDown`，和 `Info.plist` 一致，
/// 也就是「浏览器页面照样能跟着机身转」。真正让系统照做的入口是
/// `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`——
/// 没有那一层，`requestGeometryUpdate` 只是「请求」，系统可以不理。
@MainActor
enum OrientationGate {
    static var mask: UIInterfaceOrientationMask = .allButUpsideDown
    /// 当前被锁住的形态；nil = 没锁（播放页之外）
    static var locked: ScreenMode?
    /// 锁的代次。每次 `lock()` 自增，用来作废「延迟放开」的旧任务：
    /// 关掉播放页又立刻点开下一个视频时，上一个任务不许把新的锁清掉。
    static var generation = 0
}

/// 播放页的横竖屏切换。
///
/// iOS 16 起 `UIDevice.setValue(_:forKey: "orientation")` 已经失效（会抛
/// `UIApplication.setStatusBarOrientation` 同款的 KVC 异常），唯一受支持的做法是
/// `UIWindowScene.requestGeometryUpdate` + 收窄 `supportedInterfaceOrientations`。
@MainActor
enum ScreenOrientationController {

    /// 锁到指定形态并转过去
    static func lock(_ mode: ScreenMode) {
        OrientationGate.generation &+= 1
        OrientationGate.mask = mode.mask
        OrientationGate.locked = mode

        guard let scene = activeScene() else { return }
        // 先让系统重新问一遍「这个界面支持哪些方向」，否则几何请求会被拒
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mode.mask)) { _ in
            // 台前调度 / iPad 分屏下系统会直接拒绝，静默忽略：
            // 那种窗口形态本来就不由 App 决定方向。
        }
    }

    /// 离开播放页：先转回**进播放页之前**的形态，再放开方向锁。
    ///
    /// 为什么不能「只放开锁、按机身姿态落回去」：横屏看完直接退出时，人会横着
    /// 拿手机，于是浏览器停在那个人躺着的横屏里（1.3.38 的行为，用户明确否掉）。
    /// 主流播放器也是这个逻辑——YouTube / Netflix 退出全屏就是回到进入前的形态，
    /// 视频放完自动转回竖屏。
    ///
    /// 顺序不能反：先 `lock(mode)` 把 mask 收窄成目标形态，几何请求才会被接受；
    /// 转完再把 mask 放开。放开时当前形态仍在支持列表里，系统不会自己再转一次，
    /// 之后只有用户真的转动手机才会跟着转。
    static func restore(to mode: ScreenMode) {
        guard OrientationGate.locked != nil else { return }
        lock(mode)
        let token = OrientationGate.generation

        Task { @MainActor in
            // 等几何动画走完再放开，避免旋转到一半 mask 变宽被系统重算
            try? await Task.sleep(nanoseconds: 500_000_000)
            // 期间若又进了播放页（连续点开），别把新的锁清掉
            guard token == OrientationGate.generation else { return }
            OrientationGate.mask = .allButUpsideDown
            OrientationGate.locked = nil
            activeScene()?.keyWindow?.rootViewController?
                .setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    /// 当前界面方向。读 `windowScene.interfaceOrientation`，不要读 `UIDevice` 的——
    /// 后者是机身姿态，锁屏时两者会不一致。
    static var current: ScreenMode {
        guard let scene = activeScene() else { return .portrait }
        switch scene.interfaceOrientation {
        case .landscapeLeft, .landscapeRight: return .landscape
        default: return .portrait
        }
    }
    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

/// 只为「方向闸门」存在的 AppDelegate。
///
/// SwiftUI 的 `App` 没有这个回调，必须挂一个 delegate 才能参与
/// `supportedInterfaceOrientationsFor`。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // 这个方法只在主线程被调用
        MainActor.assumeIsolated { OrientationGate.mask }
    }
}
