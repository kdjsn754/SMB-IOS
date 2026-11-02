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
        }
        .padding(.vertical, 2)
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
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // 设置首页隐藏了导航栏，二级页要把返回按钮要回来
        .toolbar(.visible, for: .navigationBar)
    }
}
