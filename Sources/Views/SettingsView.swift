import SwiftUI

/// 设置首页：只放分类入口，每行的当前值直接显示在右侧，
/// 点进去是二级页（详细设置）。这样首页一眼能看完，不会堆满开关和小字。
@MainActor
struct SettingsView: View {
    @ObservedObject private var cache = CacheManager.shared
    @ObservedObject private var gestures = PlayerGestureSettings.shared

    @AppStorage(SettingsKey.theme) private var themeRaw: String = AppTheme.system.rawValue
    @AppStorage(SettingsKey.thumbnailsEnabled) private var thumbnailsEnabled: Bool = true
    @AppStorage(SettingsKey.videoThumbnails) private var videoThumbnails: Bool = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AppearanceSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "circle.lefthalf.filled",
                            tint: .indigo,
                            title: "外观",
                            value: themeTitle
                        )
                    }

                    NavigationLink {
                        GestureSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "hand.draw.fill",
                            tint: .orange,
                            title: "播放手势",
                            value: gestures.isEnabled ? gestures.doubleTap.shortTitle : "已关闭"
                        )
                    }
                }

                Section {
                    NavigationLink {
                        ThumbnailSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "photo.on.rectangle.angled",
                            tint: .pink,
                            title: "缩略图",
                            value: thumbnailSummary
                        )
                    }

                    NavigationLink {
                        CacheSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "internaldrive.fill",
                            tint: .green,
                            title: "缓存",
                            value: Format.bytes(cache.totalBytes)
                        )
                    }
                }

                Section {
                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        SettingsRow(
                            icon: "info.circle.fill",
                            tint: .gray,
                            title: "关于",
                            value: AppInfo.version
                        )
                    }
                }
            }
            .navigationTitle("设置")
            .onAppear { cache.refresh() }
        }
    }

    private var themeTitle: String {
        (AppTheme(rawValue: themeRaw) ?? .system).title
    }

    private var thumbnailSummary: String {
        guard thumbnailsEnabled else { return "已关闭" }
        return videoThumbnails ? "图片 + 视频" : "仅图片"
    }
}
