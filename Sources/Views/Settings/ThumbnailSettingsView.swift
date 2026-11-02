import SwiftUI
import UIKit

/// 缩略图与视频封面。
///
/// 1.3.34 重设计：开关带图标与一行说明，维护操作从「两个裸按钮」改成两项带说明的行，
/// 失败记录的数量直接放在行尾，不用点进去才知道有没有。
@MainActor
struct ThumbnailSettingsView: View {
    @ObservedObject private var diagnostics = ThumbnailDiagnostics.shared

    @AppStorage(SettingsKey.thumbnailsEnabled) private var thumbnailsEnabled: Bool = true
    @AppStorage(SettingsKey.videoThumbnails) private var videoThumbnails: Bool = true

    @State private var toast: String?

    var body: some View {
        SettingsDetail(title: "缩略图与封面") {
            Section {
                SettingsToggleRow(
                    icon: "photo.fill",
                    tint: .pink,
                    title: "图片缩略图",
                    subtitle: "网格和列表里的预览图",
                    isOn: $thumbnailsEnabled
                )

                SettingsToggleRow(
                    icon: "film.fill",
                    tint: .purple,
                    title: "视频封面",
                    subtitle: thumbnailsEnabled
                        ? "读取视频首帧当封面，比图片慢一些"
                        : "需要先打开「图片缩略图」",
                    isOn: $videoThumbnails
                )
                .disabled(!thumbnailsEnabled)
            } header: {
                SettingsSectionTitle("显示")
            } footer: {
                Text("关掉之后只显示文件类型图标，目录加载会更快。")
            }

            Section {
                Button {
                    ThumbnailStore.shared.resetFailures()
                    toast = "已重新排队"
                } label: {
                    SettingsRow(
                        icon: "arrow.clockwise",
                        tint: .blue,
                        title: "重新加载失败的缩略图",
                        subtitle: "清空失败记录，下一轮重新尝试"
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    ThumbnailFailureListView()
                } label: {
                    SettingsRow(
                        icon: "exclamationmark.triangle.fill",
                        tint: .yellow,
                        title: "加载失败记录",
                        subtitle: diagnostics.entries.isEmpty ? "暂时没有失败的文件" : "点开可以查看原因",
                        value: diagnostics.entries.isEmpty ? nil : "\(diagnostics.entries.count)"
                    )
                }
            } header: {
                SettingsSectionTitle("维护")
            }
        }
        .toast($toast)
    }
}

/// 失败记录单独一页：列表长了也不会把设置页顶开
@MainActor
struct ThumbnailFailureListView: View {
    @ObservedObject private var diagnostics = ThumbnailDiagnostics.shared

    var body: some View {
        Group {
            if diagnostics.entries.isEmpty {
                ContentUnavailableViewCompat(title: "没有失败记录")
            } else {
                List {
                    ForEach(diagnostics.entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(entry.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            }
        }
        .navigationTitle("加载失败记录")
        .navigationBarTitleDisplayMode(.inline)
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

/// iOS 16 没有 ContentUnavailableView（17+ 才有），这里做个等价占位
struct ContentUnavailableViewCompat: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
