import SwiftUI
import UIKit

/// 设置首页：方块卡片网格。
/// 每张卡片 = 淡色图标 + 标题 + 当前状态，点进去是二级页（详细设置）。
@MainActor
struct SettingsView: View {
    @ObservedObject private var cache = CacheManager.shared
    @ObservedObject private var gestures = PlayerGestureSettings.shared

    @AppStorage(SettingsKey.theme) private var themeRaw: String = AppTheme.system.rawValue
    @AppStorage(SettingsKey.thumbnailsEnabled) private var thumbnailsEnabled: Bool = true
    @AppStorage(SettingsKey.videoThumbnails) private var videoThumbnails: Bool = true

    private let margin: CGFloat = 20
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("设置")
                        .font(.system(size: 32, weight: .bold))
                        .padding(.bottom, 2)

                    groupTitle("偏好设置")

                    LazyVGrid(columns: columns, spacing: 12) {
                        NavigationLink {
                            GestureSettingsView()
                        } label: {
                            SettingsCard(
                                icon: "hand.draw.fill",
                                tint: .orange,
                                title: "播放手势",
                                subtitle: gestures.isEnabled ? gestures.doubleTap.shortTitle : "已关闭"
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            AppearanceSettingsView()
                        } label: {
                            SettingsCard(
                                icon: "circle.lefthalf.filled",
                                tint: .indigo,
                                title: "外观",
                                subtitle: themeTitle
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    groupTitle("浏览与存储")

                    LazyVGrid(columns: columns, spacing: 12) {
                        NavigationLink {
                            ThumbnailSettingsView()
                        } label: {
                            SettingsCard(
                                icon: "photo.on.rectangle.angled",
                                tint: .pink,
                                title: "缩略图",
                                subtitle: thumbnailSummary
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            CacheSettingsView()
                        } label: {
                            SettingsCard(
                                icon: "internaldrive.fill",
                                tint: .green,
                                title: "缓存",
                                subtitle: Format.bytes(cache.totalBytes)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    groupTitle("其他")

                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        SettingsCardRow(
                            icon: "info.circle.fill",
                            tint: .gray,
                            title: "关于",
                            subtitle: "版本 " + AppInfo.versionWithBuild
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, margin)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { cache.refresh() }
        }
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .padding(.top, 10)
    }

    private var themeTitle: String {
        (AppTheme(rawValue: themeRaw) ?? .system).title
    }

    private var thumbnailSummary: String {
        guard thumbnailsEnabled else { return "已关闭" }
        return videoThumbnails ? "图片 + 视频" : "仅图片"
    }
}
