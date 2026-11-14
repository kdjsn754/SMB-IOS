import SwiftUI
import UIKit

/// 设置项左侧的彩色圆角图标块。
///
/// 用「淡色底 + 实色符号」，不是系统设置那种实色渐变块：
/// 设置页底色是浅灰分组卡，淡色底更轻；也和首页服务器卡片
/// （同样是 `accent.opacity(0.12)` 底 + 实色符号）保持同一套语言。
struct SettingsIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                tint.opacity(0.14),
                in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            )
    }
}

/// 设置行：图标 + 标题（可带一行说明）+ 右侧当前值。
///
/// 1.3.34 起支持副标题：只写「缩略图」「缓存」这种名词，用户得点进去才知道里面是什么；
/// 补一行 12 pt 灰字说明，设置首页本身就能读懂每一项。
struct SettingsRow: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String?
    var value: String?
    /// 标题颜色（清理类操作要红字）
    var titleTint: Color = .primary
    /// 右侧值的颜色
    var valueTint: Color = .secondary
    /// 右侧是否画 chevron：自绘卡片（设置首页，1.7.4）不在 `List` 里，
    /// 系统不再自动补箭头，得自己画，否则整行看不出可点。
    var showsChevron: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: icon, tint: tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(titleTint)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(valueTint)
                    .lineLimit(1)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 自绘分组卡片（设置首页，1.7.4）

/// 设置首页的分组：小标题 + 一张圆角卡片。
///
/// 为什么不用 `List`：iOS 26 起 `insetGrouped` 会在每个分组卡片下面画一条 hairline
/// （`.listSectionSeparator(.hidden)` 也拦不住，用户实测 1.7.3 仍在，见第 7 节 93 条）。
/// 分组、卡片、行间线全部自己画，系统就没有可以插手的地方。
struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    @ObservedObject private var background = BackgroundSettings.shared

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content
            }
            .background(
                background.cardFill,
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            // 卡片轮廓：透明度 0 时不画，越透越明显 —— 壁纸上靠它分辨模块，
            // 而不是在每个模块下面加一条横线（用户 2026-11-14 的原话）
            .overlay {
                if background.cardOutlineOpacity > 0.001 {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(
                            Color.primary.opacity(background.cardOutlineOpacity),
                            lineWidth: 0.5
                        )
                }
            }
        }
    }
}

/// 行间分隔线：缩进到文字起点（和系统 insetGrouped 的行间线一致），
/// 壁纸把卡片洗到半透以下时一起收掉（和 `BackgroundSettings.rowSeparator` 同一个判据）。
struct SettingsRowDivider: View {
    var leadingInset: CGFloat = 58

    @ObservedObject private var background = BackgroundSettings.shared

    var body: some View {
        if background.rowSeparator == .visible {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .padding(.leading, leadingInset)
        }
    }
}

/// 一行在自绘卡片里的内边距与点击区域。
extension View {
    func settingsRowChrome(horizontal: CGFloat = 16, vertical: CGFloat = 12) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .contentShape(Rectangle())
    }
}

/// 自绘卡片里的可点行：`List` 之外的 `NavigationLink` 默认会把 label 染成蓝色，
/// 用自定义 ButtonStyle 同时解决染色与按压反馈（轻微变淡）。
struct SettingsRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 开关行：和图标的设置行排在一起时不至于「少一个图标」显得错位。
struct SettingsToggleRow: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                SettingsIcon(symbol: icon, tint: tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .tint(.accentColor)
        .padding(.vertical, 2)
    }
}

/// 分组标题：统一小字灰色，中文不需要系统默认的全大写转换。
struct SettingsSectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

/// 二级设置页统一的外壳。
///
/// 1.3.34 从 `Form` 换成 `List`：两者在 iOS 上渲染几乎一样，但 `Form` 会强制套一层
/// grouped material，行内 `.glassEffect` 直接是 no-op（1.3.29 踩过）；
/// 换 `List` 之后二级页也能用和首页一样的玻璃控件。
struct SettingsDetail<Content: View>: View {
    let title: String
    let content: Content

    @ObservedObject private var background = BackgroundSettings.shared

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        List {
            content
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // 与设置首页一致：收掉 iOS 26 在分组卡片下面画的全宽 hairline（见 SettingsView）
        .listSectionSeparator(.hidden)
        // 兜住没写分组标题的那些行（各页自己有 header 的分组还会各自再设一次，值一样）
        .listRowBackground(background.cardFill)
        // 壁纸铺在**这一页**里，不靠 RootView 透底（见 `pageBackground()`）
        .pageBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // 设置首页隐藏了导航栏，二级页要把返回按钮要回来
        .toolbar(.visible, for: .navigationBar)
    }
}
