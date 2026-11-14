import SwiftUI
import UIKit

// MARK: - 表面令牌
//
// 全 App 的「卡片 / 内嵌面 / 浮起控件 / 描边 / 行间线」只从这里取。
//
// 为什么要有这一层：1.7.x 之前这些值是每个页面各写一遍的 —— 卡片底有时是
// `cardFill`、有时是 `secondarySystemGroupedBackground`（完全不透明，壁纸下是死白一块），
// 圆角出现过 26 / 18 / 16 / 14 四种，行间线有系统 `listRowSeparator`、手写 `Rectangle`、
// 裸 `Divider()` 三套。用户反馈「好多地方都有这个问题」就是这个：不是某一条线难看，
// 而是**同一件事有太多实现**。现在统一成一份令牌，改一个数值全 App 跟着变。
//
// 透明度的含义和 1.7.2 定下的一致：`controlOpacity` 是**透明度**，
// 0 = 原来的实心卡片，1 = 只剩壁纸。淡的只有表面色，文字始终实心。

/// 一套表面参数。由 `BackgroundSettings.surfaces` 计算，页面里不要自己拼颜色。
struct AppSurfaces {
    /// 分组卡片底
    let card: Color
    /// 卡片内部凹下去的表面（输入框、预览底、用量卡的槽）
    let inset: Color
    /// 浮在卡片之上的控件（圆形按钮、胶囊）
    let control: Color
    /// 进度槽 / 轨道
    let track: Color
    /// 卡片轮廓：实心时不画，越透明越明显
    let stroke: Color
    /// 轮廓强度（0 = 不画）。`Color` 判不了空，用它决定要不要加 overlay。
    let strokeOpacity: Double
    /// 行间分隔线
    let separator: Color
    /// 当前是否该画行间线（壁纸把卡片洗到半透以下就收掉，否则浮着一排灰线）
    let showsSeparator: Bool

    static let cardRadius: CGFloat = 24
    static let insetRadius: CGFloat = 14
    static let controlRadius: CGFloat = 16
    /// 卡片左右内边距，行、卡片内容都按这个来
    static let cardPadding: CGFloat = 16
}

extension BackgroundSettings {
    /// 表面令牌：全 App 唯一的取色入口。
    var surfaces: AppSurfaces {
        let transparency = min(max(controlOpacity, 0), 1)
        let solidity = 1 - transparency

        let strokeOpacity = 0.12 * transparency
        return AppSurfaces(
            card: Color(uiColor: .secondarySystemGroupedBackground).opacity(solidity),
            // 内嵌面始终留一点底：全透时也要能看出「输入框在哪」
            inset: Color(uiColor: .secondarySystemFill).opacity(0.55 + 0.35 * solidity),
            control: Color(uiColor: .tertiarySystemGroupedBackground).opacity(solidity),
            track: Color.primary.opacity(0.08),
            // 实心时完全不画（和 1.7.5 的表现一致），全透时约 12%
            stroke: Color.primary.opacity(strokeOpacity),
            strokeOpacity: strokeOpacity,
            separator: Color.primary.opacity(0.08),
            showsSeparator: transparency <= 0.55
        )
    }
}

// MARK: - 页面外壳

/// 页面外壳：壁纸 + 统一边距的滚动容器。
///
/// 取代二级设置页里原来的 `List`：`List` 会自己画分组线、自己决定行底色，
/// iOS 26 起连 Section 的最后一行也画（第 7 节 93 条），关不干净。
struct AppPage<Content: View>: View {
    var spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 22, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .padding(.horizontal, AppSurfaces.cardPadding)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        // 壁纸铺在这一页自己的视图树里，不靠父容器透底（见 `pageBackground()`）
        .pageBackground()
    }
}

/// 分组：小标题 + 一张卡片。卡片底、圆角、轮廓全部由令牌决定。
struct AppGroup<Content: View>: View {
    var title: String?
    /// 说明文字（替代 `Form` 的 footer）
    var footer: String?
    let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            VStack(spacing: 0) {
                content
            }
            // 让首/末行滑开时（`SwipeDeleteRow`）也被卡片圆角裁住
            .clipShape(RoundedRectangle(cornerRadius: AppSurfaces.cardRadius, style: .continuous))
            .appCardSurface()

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 给任意内容套一层统一卡片表面（没有分组标题的独立卡片用）。
struct AppCardSurface: ViewModifier {
    var radius: CGFloat = AppSurfaces.cardRadius

    @ObservedObject private var background = BackgroundSettings.shared

    func body(content: Content) -> some View {
        content
            .background(
                background.surfaces.card,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                if background.surfaces.strokeOpacity > 0.001 {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(background.surfaces.stroke, lineWidth: 0.5)
                }
            }
    }
}

extension View {
    func appCardSurface(radius: CGFloat = AppSurfaces.cardRadius) -> some View {
        modifier(AppCardSurface(radius: radius))
    }
}

// MARK: - 图标

/// 设置项左侧的彩色圆角图标块。
///
/// 用「淡色底 + 实色符号」，不是系统设置那种实色渐变块：
/// 底色更轻，和首页服务器卡片（同样是 `tint.opacity(0.14)` 底 + 实色符号）同一套语言。
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

// MARK: - 行

/// 独立的分隔线：给「不是 `AppRow`」的内容之间用（比如主题选择器下面）。
///
/// 已经有 `AppRow` 的地方不要再手动加 —— 行自带底部线，两处都画会出双线。
struct AppSeparator: View {
    var leadingInset: CGFloat = AppSurfaces.cardPadding

    @ObservedObject private var background = BackgroundSettings.shared

    var body: some View {
        if background.surfaces.showsSeparator {
            Rectangle()
                .fill(background.surfaces.separator)
                .frame(height: 0.5)
                .padding(.leading, leadingInset)
        }
    }
}

/// 行右侧的常见附属内容：当前值 / 箭头 / 勾。
struct AppRowAccessory: View {
    var value: String?
    var chevron: Bool = false
    var checkmark: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if let value {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if checkmark {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            } else if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// 卡片里的一行：图标 + 标题（可带一行说明）+ 右侧内容。
///
/// 行自带**缩进正确的底部线**，最后一行传 `showsSeparator: false`。
/// 之所以让行自己画线：`List` 之外没有系统行线可用，而每个调用方手写
/// `Rectangle + padding` 正是之前左右缩进对不齐的原因。
struct AppRow<Trailing: View>: View {
    var icon: String?
    var iconTint: Color = .accentColor
    var title: String
    var subtitle: String?
    var titleColor: Color = .primary
    var showsSeparator: Bool = true
    @ViewBuilder var trailing: Trailing

    @ObservedObject private var background = BackgroundSettings.shared

    init(
        icon: String? = nil,
        iconTint: Color = .accentColor,
        title: String,
        subtitle: String? = nil,
        titleColor: Color = .primary,
        showsSeparator: Bool = true,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.title = title
        self.subtitle = subtitle
        self.titleColor = titleColor
        self.showsSeparator = showsSeparator
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                SettingsIcon(symbol: icon, tint: iconTint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(titleColor)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.horizontal, AppSurfaces.cardPadding)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            separator
        }
    }

    @ViewBuilder
    private var separator: some View {
        if showsSeparator, background.surfaces.showsSeparator {
            Rectangle()
                .fill(background.surfaces.separator)
                .frame(height: 0.5)
                // 和文字起点对齐：卡片内边距 + 图标宽 + 图标与文字的间距
                .padding(.leading, icon == nil ? AppSurfaces.cardPadding : AppSurfaces.cardPadding + 42)
        }
    }
}

extension AppRow where Trailing == AppRowAccessory {
    /// 最常用的一行：右侧只有「值 / 箭头 / 勾」。
    init(
        icon: String? = nil,
        iconTint: Color = .accentColor,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        chevron: Bool = false,
        checkmark: Bool = false,
        titleColor: Color = .primary,
        showsSeparator: Bool = true
    ) {
        self.init(
            icon: icon,
            iconTint: iconTint,
            title: title,
            subtitle: subtitle,
            titleColor: titleColor,
            showsSeparator: showsSeparator
        ) {
            AppRowAccessory(value: value, chevron: chevron, checkmark: checkmark)
        }
    }
}

/// 自绘卡片里的可点行：`List` 之外的 `NavigationLink` 默认把 label 染成蓝色，
/// 这个 style 同时解决染色与按压反馈。
struct AppRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 输入行

/// 表单里的一行输入：左标签 + 无边框输入框。
///
/// 取代 `Form` 里的裸 `TextField`：`Form` 会给每行套一层不透明底和系统分隔线，
/// 壁纸透不上来，也和其它页的卡片不是一套。标签固定宽度让几行输入框左边对齐。
struct AppField: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var isSecure: Bool = false
    var showsSeparator: Bool = true

    @ObservedObject private var background = BackgroundSettings.shared

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(.subheadline)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.horizontal, AppSurfaces.cardPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if showsSeparator, background.surfaces.showsSeparator {
                Rectangle()
                    .fill(background.surfaces.separator)
                    .frame(height: 0.5)
                    .padding(.leading, AppSurfaces.cardPadding)
            }
        }
    }
}

// MARK: - 二级设置页外壳

/// 二级设置页统一的外壳（取代原来的 `List` 版）。
///
/// 页面内容直接写 `AppGroup { AppRow ... }`，不再用 `Section`。
struct SettingsDetail<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        AppPage {
            content
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // 设置首页隐藏了导航栏，二级页要把返回按钮要回来
        .toolbar(.visible, for: .navigationBar)
    }
}
