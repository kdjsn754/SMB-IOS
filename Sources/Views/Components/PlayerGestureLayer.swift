import SwiftUI
import UIKit

/// 播放器手势层发出的事件。
///
/// 用 UIKit 手势而不是 SwiftUI 的 `.gesture`，原因有两条：
/// 1. `AVPlayerLayer` 铺满全屏时，SwiftUI 手势和视频层会互相抢 touches，
///    单击 / 双击 / 拖动叠在一起时经常只识别到其中一个；
/// 2. 单击必须等双击失败才能触发（否则每次单击都会先闪一下控制条），
///    这个优先级只有 `require(toFail:)` 能干净地表达。
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

/// 覆盖在视频上的透明手势层，只负责识别，不带任何视觉。
struct PlayerGestureLayer: UIViewRepresentable {
    var isEnabled: Bool = true
    var onEvent: @MainActor (PlayerGestureEvent) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    func makeUIView(context: Context) -> UIView {
        let view = TouchThroughView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onEvent = onEvent
        context.coordinator.setEnabled(isEnabled)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.setEnabled(false)
    }

    /// 只吞掉「落在自己身上」的触摸；上层控件（按钮、进度条）本来就在上面，不受影响
    final class TouchThroughView: UIView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            isUserInteractionEnabled && super.point(inside: point, with: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onEvent: @MainActor (PlayerGestureEvent) -> Void

        private weak var view: UIView?
        private var recognizers: [UIGestureRecognizer] = []

        init(onEvent: @escaping @MainActor (PlayerGestureEvent) -> Void) {
            self.onEvent = onEvent
        }

        func attach(to view: UIView) {
            self.view = view

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2

            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            singleTap.numberOfTapsRequired = 1
            // 单击要等双击确认失败：否则每次想双击都会先闪一次控制条
            singleTap.require(toFail: doubleTap)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self

            let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
            press.minimumPressDuration = 0.45
            press.allowableMovement = 12
            press.delegate = self

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
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

        @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            onEvent(.singleTap(gesture.location(in: view), size()))
        }

        @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            onEvent(.doubleTap(gesture.location(in: view), size()))
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: view)
            let delta = CGSize(width: translation.x, height: translation.y)
            switch gesture.state {
            case .began:
                onEvent(.panBegan(gesture.location(in: view), size()))
            case .changed:
                onEvent(.panChanged(delta, size()))
            case .ended, .cancelled, .failed:
                onEvent(.panEnded(delta, size()))
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
}
