import Foundation
import SwiftUI
import UIKit

/// 全 App 共用的背景层：壁纸 / 纯色 / 系统分组底色。
///
/// 放在 `RootView` 的 `ZStack` 最底层，上面才是 `TabView`。
/// 各页面因此要把自己的不透明底色去掉（见 `ServerListView` / `SettingsView` /
/// `SettingsDetail` 的 `.background(.clear)`），否则背景会被页面底色挡住。
///
/// 没有设自定义背景时，这里铺的就是原来的 `systemGroupedBackground` ——
/// 所以「不设背景」的观感和加这层之前完全一致。
struct AppBackground: View {
    @ObservedObject private var settings = BackgroundSettings.shared

    /// 壁纸上的压暗/提亮遮罩。0.18 是折中：花哨照片上文字还能读，
    /// 又不至于把壁纸洗成一片灰。纯色背景不需要。
    private let imageVeil: Double = 0.18

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                base

                if settings.kind == .image {
                    Color(uiColor: .systemBackground).opacity(imageVeil)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var base: some View {
        switch settings.kind {
        case .image:
            if let image = settings.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(uiColor: .systemGroupedBackground)
            }
        case .color:
            Color(hex: settings.colorHex)
        case .none:
            Color(uiColor: .systemGroupedBackground)
        }
    }
}

// MARK: - 颜色与十六进制互转

extension Color {
    /// `#RRGGBB` / `RRGGBB` / `#RGB` 都认；解析不出来就退回默认藏蓝。
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        var value: UInt64 = 0
        _ = Scanner(string: cleaned).scanHexInt64(&value)

        let red, green, blue: Double
        switch cleaned.count {
        case 3:
            red = Double((value >> 8) & 0xF) / 15
            green = Double((value >> 4) & 0xF) / 15
            blue = Double(value & 0xF) / 15
        case 6:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        default:
            self.init(hex: WallpaperDefaults.colorHex)
            return
        }
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

extension UIColor {
    /// 给 `ColorPicker` 回写用：把选中的颜色折成 `#RRGGBB`。
    var hexRGB: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return WallpaperDefaults.colorHex
        }
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}
