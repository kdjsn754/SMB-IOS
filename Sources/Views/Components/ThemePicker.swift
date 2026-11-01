import SwiftUI

/// 外观 → 主题：两段式选择器，带太阳 / 月亮图标。
///
/// 用自绘而不是 `Picker(.segmented)`：分段控件的标签只吃文字，
/// `Label` 里的 SF Symbol 会被丢掉，用户就看不到太阳和月亮了。
struct ThemePicker: View {
    @Binding var selection: String

    private var current: AppTheme { AppTheme.resolve(selection) }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTheme.allCases) { theme in
                let isSelected = current == theme
                Button {
                    guard selection != theme.rawValue else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
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
                    .padding(.vertical, 7)
                    .foregroundStyle(isSelected ? Color.white : Color(uiColor: .secondaryLabel))
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.accentColor.gradient)
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(theme.title)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(
            Color(uiColor: .tertiarySystemFill),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}
