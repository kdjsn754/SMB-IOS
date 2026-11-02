import SwiftUI
import UIKit

/// 面板滚动位置的句柄。
///
/// 面板永远是**同一个** `UIScrollView` 换内容，所以只要拿到它一次，之后就一直有效。
/// 用一个小盒子在外面握着弱引用，避免「scrollView → 子视图(探针) → 闭包 → @State(scrollView)」
/// 这样绕回去的循环引用。
final class PanelScrollBox {
    weak var scrollView: UIScrollView?

    /// 每个面板各自的滚动位置。
    ///
    /// 故意**不放进 `@State`**：滚动时每一帧都会变，写进 SwiftUI 状态会让整个面板
    /// 每帧重绘，滚动直接掉帧。这里只是个普通字典，不进 diff。
    var offsets: [String: CGFloat] = [:]

    /// 正在把偏移写回去（这期间的位移是程序造成的，不是用户滚的，别记录）
    var isRestoring = false
}

/// 塞在面板内容里的一根探针：向上找出自己所在的 `UIScrollView`，
/// 一边把滚动位移报给外面记着，一边把它交出去，供换页时写回偏移。
///
/// **为什么不继续用 `ScrollPosition` / `onScrollGeometryChange`**：
/// 面板换页时内容变短，`UIScrollView` 会立刻把 `contentOffset` 夹回 0；
/// `ScrollPosition.scrollTo(y:)` 只是一次「请求」，内容还没重新布局完就发出去会被
/// 一起夹掉，写晚了又会被弹簧动画再压一次 —— 1.4.7 实测**读和写两头都不稳**
/// （用户反馈「没实现」）。而 `setContentOffset` 是直接赋值，`layoutIfNeeded()`
/// 之后写一次就是一次，没有中间态。
///
/// 全程**只观察、不接管 delegate**：SwiftUI 的滚动、回弹、指示器行为一点不动。
struct PanelScrollProbe: UIViewRepresentable {
    let box: PanelScrollBox
    /// 当前页滚动到哪了（用于按页记忆）
    let onScroll: (CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.box = box
        view.onScroll = onScroll
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.box = box
        uiView.onScroll = onScroll
        uiView.resolveIfNeeded()
    }

    final class ProbeView: UIView {
        weak var box: PanelScrollBox?
        var onScroll: ((CGFloat) -> Void)?
        private var observation: NSKeyValueObservation?
        private weak var observed: UIScrollView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolveIfNeeded()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            resolveIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // 第一次进树时 superview 链可能还没接好，多试几次（很便宜）
            resolveIfNeeded()
        }

        func resolveIfNeeded() {
            // 已经挂在同一个滚动视图上就别重复监听
            if observation != nil, observed != nil { return }

            var node: UIView? = superview
            while let current = node {
                if let scroll = current as? UIScrollView {
                    observed = scroll
                    box?.scrollView = scroll
                    observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                        let y = scroll.contentOffset.y
                        self?.onScroll?(y)
                    }
                    return
                }
                node = current.superview
            }
        }
    }
}
