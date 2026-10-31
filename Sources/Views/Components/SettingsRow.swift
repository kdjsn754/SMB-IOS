import SwiftUI
import UIKit

/// 设置首页的行：彩色图标块 + 标题 + 右侧当前值（系统「设置」的样式）。
struct SettingsRow: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)

            Spacer(minLength: 8)

            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
        // 设置首页自己的导航栏也要显示（别被别处的 .toolbar(.hidden) 带歪）
        .toolbar(.visible, for: .navigationBar)
    }
}
