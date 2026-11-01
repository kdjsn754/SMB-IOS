import SwiftUI

/// 格子点击：只有「手指基本没动」才算点击。
///
/// 之前用的是 `Button`。SwiftUI 在滚动容器里的按钮会把「没触发滚动」的拖动也认成点击：
/// 从屏幕左边往右滑、想返回上一级时，横向位移不会产生滚动，抬手就变成了一次点击 ——
/// 表现正是「右滑返回很容易就触发成点击查看图片」。
///
/// 这里改成自己记「这次触摸有没有真的移动过」，移动过就不认这次点击。
/// 用 `.simultaneousGesture` 是为了不抢滚动：纵向滚动时两边同时进行，
/// 我们只是顺手把 `moved` 置上，滚动照旧。
struct TileTap: ViewModifier {
    /// 判成拖动的位移阈值，比系统识别点击的容差略大一点
    private static let dragThreshold: CGFloat = 8
    /// 松手后这段时间内继续认为「刚拖过」：同一次触摸可能还会排出一次点击事件
    private static let holdAfterDrag: UInt64 = 300_000_000

    let action: () -> Void

    @State private var moved = false
    @State private var resetTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                guard !moved else { return }
                action()
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: Self.dragThreshold)
                    .onChanged { _ in
                        moved = true
                    }
                    .onEnded { _ in
                        resetTask?.cancel()
                        resetTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: Self.holdAfterDrag)
                            guard !Task.isCancelled else { return }
                            moved = false
                        }
                    }
            )
    }
}

extension View {
    /// 见 `TileTap`：手指移动过的触摸不当作点击
    func tileTap(action: @escaping () -> Void) -> some View {
        modifier(TileTap(action: action))
    }
}
