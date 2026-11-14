import SwiftUI
import UIKit

/// 缩略图与视频封面。
///
/// 1.3.34 重设计：开关带图标与一行说明，维护操作从「两个裸按钮」改成两项带说明的行，
/// 失败记录的数量直接放在行尾，不用点进去才知道有没有。
/// 1.7.6 换到统一的 `AppGroup` / `AppRow`（不再用 `List`，见 `AppSurface.swift`）。
@MainActor
struct ThumbnailSettingsView: View {
    @ObservedObject private var diagnostics = ThumbnailDiagnostics.shared

    @AppStorage(SettingsKey.thumbnailsEnabled) private var thumbnailsEnabled: Bool = true
    @AppStorage(SettingsKey.videoThumbnails) private var videoThumbnails: Bool = true

    @State private var toast: String?

    var body: some View {
        SettingsDetail(title: "缩略图与封面") {
            VStack(alignment: .leading, spacing: 22) {
                AppGroup("显示") {
                AppRow(
                    icon: "photo.fill",
                    iconTint: .pink,
                    title: "图片缩略图",
                    subtitle: "网格和列表里的预览图"
                ) {
                    Toggle("", isOn: $thumbnailsEnabled)
                        .labelsHidden()
                }

                AppRow(
                    icon: "film.fill",
                    iconTint: .purple,
                    title: "视频封面",
                    subtitle: thumbnailsEnabled
                        ? "读取视频首帧当封面，比图片慢一些"
                        : "需要先打开「图片缩略图」",
                    showsSeparator: false
                ) {
                    Toggle("", isOn: $videoThumbnails)
                        .labelsHidden()
                }
                .disabled(!thumbnailsEnabled)
            }

            AppGroup("维护") {
                Button {
                    ThumbnailStore.shared.resetFailures()
                    toast = "已重新排队"
                } label: {
                    AppRow(
                        icon: "arrow.clockwise",
                        iconTint: .blue,
                        title: "重新加载失败的缩略图",
                        subtitle: "清空失败记录，下一轮重新尝试"
                    )
                }
                .buttonStyle(AppRowPressStyle())

                NavigationLink {
                    ThumbnailFailureListView()
                } label: {
                    AppRow(
                        icon: "exclamationmark.triangle.fill",
                        iconTint: .yellow,
                        title: "加载失败记录",
                        subtitle: diagnostics.entries.isEmpty ? "暂时没有失败的文件" : "点开可以查看原因",
                        value: diagnostics.entries.isEmpty ? nil : "\(diagnostics.entries.count)",
                        chevron: true,
                        showsSeparator: false
                    )
                }
                .buttonStyle(AppRowPressStyle())
                }
            }
        }
        .toast($toast)
    }
}

/// 失败记录单独一页：列表长了也不会把设置页顶开。
@MainActor
struct ThumbnailFailureListView: View {
    @ObservedObject private var diagnostics = ThumbnailDiagnostics.shared

    var body: some View {
        SettingsDetail(title: "加载失败记录") {
            if diagnostics.entries.isEmpty {
                AppGroup {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("没有失败记录")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            } else {
                AppGroup {
                    ForEach(Array(diagnostics.entries.enumerated()), id: \.element.id) { index, entry in
                        AppRow(
                            title: entry.name,
                            subtitle: entry.reason,
                            showsSeparator: index < diagnostics.entries.count - 1
                        ) {
                            EmptyView()
                        }
                    }
                }
            }
        }
        .toolbar {
            if !diagnostics.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清除", role: .destructive) {
                        diagnostics.clear()
                    }
                }
            }
        }
    }
}
