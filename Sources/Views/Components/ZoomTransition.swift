import SwiftUI

/// iOS 18 起提供的「缩放转场」：点缩略图时画面从格子里长出来，退出时缩回格子，
/// 和「照片」App 看图的进出完全同一套系统动画；转场过程中还能直接拖动、双指捏合反向退回，
/// 系统另外自带「单指下滑退出」，松手就顺着缩回原格子。
///
/// iOS 16 / 17 没有这套 API，两个入口都原样返回自己（等于什么都不做），
/// 旧行为（`fullScreenCover` 上滑 + 自绘下拉退出）保留在那两支里。
///
/// 注意：这里刻意不用自定义 `ViewModifier` 包一层——修饰器必须直接挂在
/// 「来源视图 / 被呈现视图的根」上，系统才认得出配对。
extension View {
    /// 标记「这是缩放的起点」。`id` / `namespace` 传 nil 时不做任何事（旧系统、非看图入口都用得上）。
    @ViewBuilder
    func zoomSource(id: String?, in namespace: Namespace.ID?, cornerRadius: CGFloat = 4) -> some View {
        if #available(iOS 18.0, *), let id, let namespace {
            // 圆角配置让「缩回格子」时的边缘和网格里的小图一致，不会先方后圆地跳一下
            matchedTransitionSource(id: id, in: namespace) { source in
                source.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            self
        }
    }

    /// 挂在全屏看图页上，声明「用缩放转场进来」。
    /// `id` 取当前这一页的文件路径：左右翻页后再退出，会缩回到**当前那张**所在的格子，
    /// 而不是最初点开的那一格。
    @ViewBuilder
    func zoomDestination(id: String?, in namespace: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let id, let namespace {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
