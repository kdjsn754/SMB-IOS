import SwiftUI
import UIKit

/// 设置首页。
///
/// 布局与首页（`ServerListView`）统一：**不用系统大标题导航栏**，自绘「设置」38 pt 粗体、
/// 与「资源库」同一条 24 pt 竖线；导航栏整体隐藏，进二级页时由 `SettingsDetail`
/// 的 `.toolbar(.visible, for: .navigationBar)` 把返回按钮要回来。
///
/// 1.3.34 全页重设计（用户要求「显示文本和布局都要」）：
/// - 每项从单行名词改成「图标 + 标题 + 一行灰字说明」，设置页本身就能读懂每个入口是什么；
/// - 分组按「外观 / 浏览 / 播放 / 关于」重排，去掉了和浏览页工具栏重复的「网格视图」开关；
/// - 图标块换成淡色底 + 实色符号（`SettingsIcon`），和首页服务器卡片同一套语言。
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

                List {
                    Section {
                        ThemePicker(selection: $themeRaw)
                            .padding(.vertical, 6)

                        NavigationLink {
                            BackgroundSettingsView()
                        } label: {
                            SettingsRow(
                                icon: "photo.fill",
                                tint: .indigo,
                                title: "自定义背景",
                                subtitle: "图片或纯色，控件透明度可调",
                                value: background.summary
                            )
                        }
                    } header: {
                        SettingsSectionTitle("外观")
                    }
                    .listRowBackground(BackgroundSettings.shared.cardFill)
                    .listRowSeparator(BackgroundSettings.shared.rowSeparator)

                    Section {
                        NavigationLink {
                            ThumbnailSettingsView()
                        } label: {
                            SettingsRow(
                                icon: "photo.on.rectangle.angled",
                                tint: .pink,
                                title: "缩略图与封面",
                                subtitle: "网格里的图片预览、视频首帧",
                                value: thumbnailSummary
                            )
                        }

                        NavigationLink {
                            CacheSettingsView()
                        } label: {
                            SettingsRow(
                                icon: "internaldrive.fill",
                                tint: .green,
                                title: "存储空间",
                                subtitle: "缩略图与已缓存的媒体文件",
                                value: Format.bytes(cache.totalBytes)
                            )
                        }
                    } header: {
                        SettingsSectionTitle("浏览")
                    }
                    .listRowBackground(BackgroundSettings.shared.cardFill)
                    .listRowSeparator(BackgroundSettings.shared.rowSeparator)

                    Section {
                        NavigationLink {
                            GestureSettingsView()
                        } label: {
                            SettingsRow(
                                icon: "hand.draw.fill",
                                tint: .orange,
                                title: "播放手势",
                                subtitle: "双击、拖动、长按分别做什么",
                                value: gestures.isEnabled ? gestures.doubleTap.shortTitle : "已关闭"
                            )
                        }
                    } header: {
                        SettingsSectionTitle("播放")
                    }
                    .listRowBackground(BackgroundSettings.shared.cardFill)
                    .listRowSeparator(BackgroundSettings.shared.rowSeparator)

                    Section {
                        NavigationLink {
                            DownloadSettingsView()
                        } label: {
                            SettingsRow(
                                icon: "arrow.down.circle.fill",
                                tint: .blue,
                                title: "视频下载",
                                subtitle: "已存到本机的视频，可单独删除",
                                value: downloads.summary
                            )
                        }
                    } header: {
                        SettingsSectionTitle("下载")
                    }
                    .listRowBackground(BackgroundSettings.shared.cardFill)
                    .listRowSeparator(BackgroundSettings.shared.rowSeparator)

                    Section {
                        NavigationLink {
                            AboutSettingsView()
                        } label: {
                            SettingsRow(
                                icon: "info.circle.fill",
                                tint: .gray,
                                title: "关于 SMBViewer",
                                subtitle: "版本、连接协议与开源许可",
                                value: AppInfo.version
                            )
                        }
                    } header: {
                        SettingsSectionTitle("关于")
                    }
                    .listRowBackground(BackgroundSettings.shared.cardFill)
                    .listRowSeparator(BackgroundSettings.shared.rowSeparator)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
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
