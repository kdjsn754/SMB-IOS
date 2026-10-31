import SwiftUI
import UIKit

/// 设置首页的方块卡片：淡色图标块 + 标题 + 当前状态。
struct SettingsCard: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 50, height: 50)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            Spacer(minLength: 12)

            Text(title)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// 设置首页的整行卡片（单独一项时用，和方块卡片同一套底色与圆角）
struct SettingsCardRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// 二级设置页统一的外壳：同一套 Form 样式与标题，避免各页各写一遍。
struct SettingsDetail<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Form {
            content
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // 设置首页把导航栏藏了（自己做标题），二级页必须显式显示才有返回按钮
        .toolbar(.visible, for: .navigationBar)
    }
}
