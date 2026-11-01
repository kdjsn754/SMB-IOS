import SwiftUI

/// 外观 → 主题：两段式选择器，用 iOS 26 原生的液态玻璃（`glassEffect`）。
///
/// - 用自绘而不是 `Picker(.segmented)`：分段控件的标签只吃文字，`Label` 里的 SF Symbol 会被丢掉。
/// - 两块玻璃必须包进 `GlassEffectContainer`：相邻玻璃共享同一份背景采样，
///   否则各自采样会出现可见接缝（系统媒体控件也是这个做法）。
/// - 选中段 `.tint(accent)` 着色，未选中段用 `.regular` 保持通透；都带 `.interactive()`，
///   按下时有系统自带的形变与高光跟随。
struct ThemePicker: View {
    @Binding var selection: String

    private var current: AppTheme { AppTheme.resolve(selection) }

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(AppTheme.allCases) { theme in
                    segment(theme)
                }
            }
        }
    }

    private func segment(_ theme: AppTheme) -> some View {
        let isSelected = current == theme
        return Button {
            guard selection != theme.rawValue else { return }
            withAnimation(.snappy(duration: 0.24, extraBounce: 0.06)) {
                selection = theme.rawValue
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: theme.icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(theme.title)
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected
                ? Glass.regular.tint(Color.accentColor).interactive()
                : Glass.regular.interactive(),
            in: .capsule
        )
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
