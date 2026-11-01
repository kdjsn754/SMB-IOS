import SwiftUI

/// 设置首页：外观直接展开在最上面（不再点进二级页），
/// 其余分类每行右侧显示当前值，点进去是二级页。
@MainActor
struct SettingsView: View {
    @ObservedObject private var cache = CacheManager.shared
    @ObservedObject private var gestures = PlayerGestureSettings.shared

    @AppStorage(SettingsKey.theme) private var themeRaw: String = AppTheme.light.rawValue
    @AppStorage(SettingsKey.gridLayout) private var useGrid: Bool = true
    @AppStorage(SettingsKey.thumbnailsEnabled) private var thumbnailsEnabled: Bool = true
    @AppStorage(SettingsKey.videoThumbnails) private var videoThumbnails: Bool = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ThemePicker(selection: $themeRaw)
                        .padding(.vertical, 6)
                        // 行背景留空，让两块玻璃浮在分组背景上（叠在白色卡片上几乎看不出边界）
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)

                    Toggle("网格视图", isOn: $useGrid)
                } header: {
                    Text("外观")
                }

                Section {
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
                } header: {
                    Text("播放")
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

    private var thumbnailSummary: String {
        guard thumbnailsEnabled else { return "已关闭" }
        return videoThumbnails ? "图片 + 视频" : "仅图片"
    }
}
