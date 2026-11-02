import SwiftUI
import UIKit

/// 关于。
///
/// 1.3.34 重设计：顶部加一块 App 标识（图标 + 名称 + 一句话定位 + 版本徽章），
/// 信息按「应用 / 连接 / 开源许可」三组排开。
/// 开源许可单独成组是必要的：libsmb2 是 LGPL-2.1，静态链接必须在应用内说明来源。
@MainActor
struct AboutSettingsView: View {
    var body: some View {
        SettingsDetail(title: "关于") {
            Section {
                banner
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                LabeledContent("版本", value: AppInfo.version)
                LabeledContent("构建", value: AppInfo.build)
                LabeledContent("最低系统", value: "iOS " + AppInfo.minimumOS)
            } header: {
                SettingsSectionTitle("应用")
            }

            Section {
                LabeledContent("连接协议", value: "SMB 2 / 3")
                LabeledContent("网络库", value: "AMSMB2 · libsmb2")
            } header: {
                SettingsSectionTitle("连接")
            } footer: {
                Text("只读访问：浏览、看图、看视频，不会修改服务器的文件。")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AMSMB2")
                        .font(.subheadline.weight(.medium))
                    Text("MIT 许可。SMB 协议的 Swift 封装，网络层由 libsmb2 提供。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("libsmb2")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 4)
                    Text("GNU LGPL v2.1。本 App 静态链接该库，源码直接取自上游、未做修改。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            } header: {
                SettingsSectionTitle("开源许可")
            }
        }
    }

    // MARK: - 顶部标识

    private var banner: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.68)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 72, height: 72)
            .shadow(color: Color.accentColor.opacity(0.28), radius: 12, y: 6)

            Text("SMBViewer")
                .font(.title3.weight(.semibold))
                .padding(.top, 2)

            Text("局域网 NAS · 看图与播放")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("版本 \(AppInfo.version)（\(AppInfo.build)）")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
