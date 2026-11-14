import SwiftUI
import UIKit

/// 设置首页。
///
/// 布局与首页（`ServerListView`）统一：**不用系统大标题导航栏**，自绘「设置」38 pt 粗体、
/// 与「资源库」同一条 24 pt 竖线；导航栏整体隐藏，进二级页时由 `SettingsDetail`
/// 的 `.toolbar(.visible, for: .navigationBar)` 把返回按钮要回来。
///
/// 1.7.6 全页改到 `AppSurface` 的令牌与组件上：分组卡片、行间线、轮廓都不再由
/// 每个页面自己拼（见 `AppSurface.swift` 顶部说明）。
@MainActor
struct SettingsView: View {
    @ObservedObject private var cache = CacheManager.shared
    @ObservedObject private var gestures = PlayerGestureSettings.shared
    @ObservedObject private var downloads = VideoDownloadStore.shared
    @ObservedObject private var background = BackgroundSettings.shared

    @AppStorage(SettingsKey.theme) private var themeRaw: String = AppTheme.light.rawValue
    @AppStorage(SettingsKey.thumbnailsEnabled) private var thumbnailsEnabled: Bool = true
    @AppStorage(SettingsKey.videoThumbnails) private var videoThumbnails: Bool = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        AppGroup("外观") {
                            ThemePicker(selection: $themeRaw)
                                .padding(.horizontal, 14)
                                .padding(.top, 14)
                                .padding(.bottom, 8)

                            AppSeparator(leadingInset: 14)

                            NavigationLink {
                                BackgroundSettingsView()
                            } label: {
                                AppRow(
                                    icon: "photo.fill",
                                    iconTint: .indigo,
                                    title: "自定义背景",
                                    subtitle: "选一张壁纸，控件透明度可调",
                                    value: background.summary,
                                    chevron: true,
                                    showsSeparator: false
                                )
                            }
                            .buttonStyle(AppRowPressStyle())
                        }

                        AppGroup("浏览") {
                            NavigationLink {
                                ThumbnailSettingsView()
                            } label: {
                                AppRow(
                                    icon: "photo.on.rectangle.angled",
                                    iconTint: .pink,
                                    title: "缩略图与封面",
                                    subtitle: "网格里的图片预览、视频首帧",
                                    value: thumbnailSummary,
                                    chevron: true
                                )
                            }
                            .buttonStyle(AppRowPressStyle())

                            NavigationLink {
                                CacheSettingsView()
                            } label: {
                                AppRow(
                                    icon: "internaldrive.fill",
                                    iconTint: .green,
                                    title: "存储空间",
                                    subtitle: "缩略图与已缓存的媒体文件",
                                    value: Format.bytes(cache.totalBytes),
                                    chevron: true,
                                    showsSeparator: false
                                )
                            }
                            .buttonStyle(AppRowPressStyle())
                        }

                        AppGroup("播放") {
                            NavigationLink {
                                GestureSettingsView()
                            } label: {
                                AppRow(
                                    icon: "hand.draw.fill",
                                    iconTint: .orange,
                                    title: "播放手势",
                                    subtitle: "双击、拖动、长按分别做什么",
                                    value: gestures.isEnabled ? gestures.doubleTap.shortTitle : "已关闭",
                                    chevron: true,
                                    showsSeparator: false
                                )
                            }
                            .buttonStyle(AppRowPressStyle())
                        }

                        AppGroup("下载") {
                            NavigationLink {
                                DownloadSettingsView()
                            } label: {
                                AppRow(
                                    icon: "arrow.down.circle.fill",
                                    iconTint: .blue,
                                    title: "视频下载",
                                    subtitle: "已存到本机的视频，可单独删除",
                                    value: downloads.summary,
                                    chevron: true,
                                    showsSeparator: false
                                )
                            }
                            .buttonStyle(AppRowPressStyle())
                        }

                        AppGroup("关于") {
                            NavigationLink {
                                AboutSettingsView()
                            } label: {
                                AppRow(
                                    icon: "info.circle.fill",
                                    iconTint: .gray,
                                    title: "关于 SMBViewer",
                                    subtitle: "版本、连接协议与开源许可",
                                    value: AppInfo.version,
                                    chevron: true,
                                    showsSeparator: false
                                )
                            }
                            .buttonStyle(AppRowPressStyle())
                        }
                    }
                    .padding(.horizontal, AppSurfaces.cardPadding)
                    .padding(.top, 2)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            // 壁纸铺在这一页自己的视图树里，不靠父容器透底（见 `pageBackground()`）
            .pageBackground()
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                cache.refresh()
                downloads.reload()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("设置")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var thumbnailSummary: String {
        guard thumbnailsEnabled else { return "已关闭" }
        return videoThumbnails ? "图片与视频" : "仅图片"
    }
}
