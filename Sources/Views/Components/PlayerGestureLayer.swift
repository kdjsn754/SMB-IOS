import SwiftUI
import UIKit

/// 播放器手势层发出的事件。
///
/// 用 UIKit 手势而不是 SwiftUI 的 `.gesture`，原因有三条：
/// 1. 单击必须等双击失败才能触发（否则每次单击都会先闪一下控制条），
///    这个优先级只有 `require(toFail:)` 能干净地表达；
/// 2. 长按 + 拖动 + 捏合要能互斥/并存，SwiftUI 的组合手势很难调；
/// 3. 手势要**挂在画面视图自己身上**（`PlayerUIView`，承载 `AVPlayerLayer` 的那个 UIView），
///    这样不依赖 SwiftUI 的透明覆盖层能不能命中，识别一定收得到。
enum PlayerGestureEvent {
    /// 单击：位置 / 视图尺寸
    case singleTap(CGPoint, CGSize)
    /// 双击：位置 / 视图尺寸
    case doubleTap(CGPoint, CGSize)
    /// 拖动开始：起点 / 尺寸
    case panBegan(CGPoint, CGSize)
    /// 拖动中：相对起点的位移 / 尺寸
    case panChanged(CGSize, CGSize)
    /// 拖动结束：总位移 / 尺寸
    case panEnded(CGSize, CGSize)
    /// 长按按下 / 松开
    case longPress(Bool)
    /// 双指捏合：累计倍数 / 是否结束
    case pinch(CGFloat, Bool)
}

/// 把识别结果翻译成 `PlayerGestureEvent`。挂到任意全屏 UIView 上即可用。
@MainActor
final class PlayerGestureCoordinator: NSObject, UIGestureRecognizerDelegate {
    var onEvent: @MainActor (PlayerGestureEvent) -> Void

    private weak var view: UIView?
    private var recognizers: [UIGestureRecognizer] = []

    init(onEvent: @escaping @MainActor (PlayerGestureEvent) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    func attach(to view: UIView) {
        guard recognizers.isEmpty else { return }
        self.view = view

        // 不打开这个的话，双指捏合在部分机型上只认得第一根手指
        view.isMultipleTouchEnabled = true

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.cancelsTouchesInView = false
        // 单击要等双击确认失败：否则每次想双击都会先闪一次控制条
        singleTap.require(toFail: doubleTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delegate = self

        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.45
        press.allowableMovement = 14
        press.cancelsTouchesInView = false
        press.delegate = self

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = self

        for recognizer in [doubleTap, singleTap, pan, press, pinch] {
            view.addGestureRecognizer(recognizer)
        }
        recognizers = [doubleTap, singleTap, pan, press, pinch]
    }

    func setEnabled(_ enabled: Bool) {
        for recognizer in recognizers {
            recognizer.isEnabled = enabled
        }
    }

    // 捏合时允许同时拖动（单纯捏合也可能带一点点平移），
    // 其余组合互斥，避免「长按加速」中途被拖动手势打断
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
    }

    private func size() -> CGSize {
        view?.bounds.size ?? .zero
    }

    /// 位置用画面视图自己的坐标系；位移用父视图（未缩放）坐标系，
    /// 这样放大到 2 倍后拖动的手感不会变迟钝。
    private func translation(of gesture: UIPanGestureRecognizer) -> CGSize {
        let reference = view?.superview ?? view
        let t = gesture.translation(in: reference)
        return CGSize(width: t.x, height: t.y)
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        onEvent(.singleTap(gesture.location(in: view), size()))
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        onEvent(.doubleTap(gesture.location(in: view), size()))
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            onEvent(.panBegan(gesture.location(in: view), size()))
        case .changed:
            onEvent(.panChanged(translation(of: gesture), size()))
        case .ended, .cancelled, .failed:
            onEvent(.panEnded(translation(of: gesture), size()))
        default:
            break
        }
    }

    @objc private func handlePress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            onEvent(.longPress(true))
        case .ended, .cancelled, .failed:
            onEvent(.longPress(false))
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        onEvent(.pinch(gesture.scale, gesture.state == .ended || gesture.state == .cancelled))
    }
}
