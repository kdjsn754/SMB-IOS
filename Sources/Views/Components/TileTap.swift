import SwiftUI

/// 格子点击。
///
/// 1.3.3 这里挂过一条 `simultaneousGesture(DragGesture(minimumDistance: 8))`，
/// 用来记「这次触摸有没有移动过」，想把「右滑返回被当成点开图片」挡掉。
/// 但它是**每个格子**一个拖动识别器，和 ScrollView 的 pan、以及 iOS 26 的
/// 「从内容区右滑返回」争同一串触摸事件。实测代价是整页手势被它接管：
/// 退出看图回到目录页之后**上下滑不动**、**右滑返回也没反应**。
///
/// 所以这里只留系统点击识别器。`UITapGestureRecognizer` 本身要求
/// 「按下到抬起的位移不超过 ~10pt」才算点击，真的右滑（几十点位移）不会触发；
/// 滚动或返回手势一开场，系统也会把这个点击取消。不需要我们自己再判一次位移。
struct TileTap: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            // 没有 contentShape 的话，只有真正画了像素的地方能点到
            // （格子留白、文件名两边的空白会点不动），观感上像「点了没反应」。
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

extension View {
    /// 见 `TileTap`：格子的点击入口（不要在这里加拖动识别器）
    func tileTap(action: @escaping () -> Void) -> some View {
        modifier(TileTap(action: action))
    }
}
