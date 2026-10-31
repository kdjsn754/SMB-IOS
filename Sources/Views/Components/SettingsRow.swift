import SwiftUI

/// 设置首页的一行：彩色图标 + 标题 + 右侧摘要值。
/// 摘要值让用户不进二级页也能看到当前状态，页面因此可以只放入口。
struct SettingsRow: View {
    let icon: String
    let tint: Color
    let title: String
    var value: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(title)

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
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
    }
}
