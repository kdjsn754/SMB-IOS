import Foundation
import SwiftUI
import UIKit

/// 全 App 共用的背景层：壁纸 / 系统分组底色。
///
/// 两处都要铺（缺一不可，见 1.7.1 的实机表现）：
/// - `RootView` 的 `ZStack` 最底层 —— 兜底的整窗底图；
/// - **每一页自己的视图树里**（`.pageBackground()`）—— `TabView` / `NavigationStack`
///   的容器会自己垫一层不透明底色，只铺在最底下的话壁纸根本透不上来。
///
/// 没有设壁纸时，这里铺的就是原来的 `systemGroupedBackground` ——
/// 所以「不设背景」的观感和加这层之前完全一致。
struct AppBackground: View {
    @ObservedObject private var settings = BackgroundSettings.shared

    var body: some View {
        GeometryReader { proxy in
            base
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var base: some View {
        if settings.kind == .image, let image = settings.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Color(uiColor: .systemGroupedBackground)
        }
    }
}

extension View {
    /// 把自定义背景铺到**这一页**的最底层。
    ///
    /// 为什么不能只在 `RootView` 铺一层：`TabView` / `NavigationStack` 的容器在
    /// 部分系统版本上会自己垫不透明底色，铺在最底下的壁纸就被整个挡住 ——
    /// 1.7.0 用户实测「设了壁纸看不到」就是这个。铺进每页自己的视图树，
    /// 它一定在「容器之上、页面内容之下」，不受容器怎么画影响。
    func pageBackground() -> some View {
        ZStack {
            AppBackground()
            self
        }
    }
}
