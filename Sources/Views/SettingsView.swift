import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var cache = CacheManager.shared
    @ObservedObject private var diagnostics = ThumbnailDiagnostics.shared

    @AppStorage(SettingsKey.theme) private var themeRaw: String = AppTheme.system.rawValue
    @AppStorage(SettingsKey.cacheLimitMB) private var cacheLimit: Int = 500
    @AppStorage(SettingsKey.autoClean) private var autoClean: Bool = true
    @AppStorage(SettingsKey.gridLayout) private var useGrid: Bool = true
    @AppStorage(SettingsKey.thumbnailsEnabled) private var thumbnailsEnabled: Bool = true
    @AppStorage(SettingsKey.videoThumbnails) private var videoThumbnails: Bool = true

    @State private var showClearConfirm = false
    @State private var showThumbnailConfirm = false
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("主题", selection: $themeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("默认使用网格视图", isOn: $useGrid)
                }

                Section {
                    Toggle("加载图片缩略图", isOn: $thumbnailsEnabled)
                    Toggle("加载视频封面", isOn: $videoThumbnails)
                        .disabled(!thumbnailsEnabled)
                    Button {
                        ThumbnailStore.shared.resetFailures()
                        showToast("已清除失败记录，返回目录会重新加载")
                    } label: {
                        Text("重新尝试加载失败的缩略图")
                    }

                    // 排障用：显示最近几次「没生成出来」的原因，用户截图即可定位
                    if !diagnostics.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(diagnostics.entries.prefix(3)) { entry in
                                Text("\(entry.name)：\(entry.reason)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Button {
                                diagnostics.clear()
                            } label: {
                                Text("清除诊断记录")
                                    .font(.footnote)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("缩略图")
                } footer: {
                    Text("只有出现在屏幕上的图片才会去读取，划走时会立刻中断传输。图片缩略图需要整份读取原图才能正确解码；视频封面只读文件头和索引（约 12 MB），不会下载整部影片。关闭后列表只显示图标，可以明显减少流量。")
                }

                Section {
                    LabeledContent("已用缓存") {
                        Text(Format.bytes(cache.totalBytes))
                            .monospacedDigit()
                    }
                    LabeledContent("其中缩略图") {
                        Text(Format.bytes(cache.thumbnailBytes))
                            .monospacedDigit()
                    }
                    LabeledContent("其中图片与视频") {
                        Text(Format.bytes(cache.mediaBytes))
                            .monospacedDigit()
                    }

                    Picker("缓存上限", selection: $cacheLimit) {
                        Text("200 MB").tag(200)
                        Text("500 MB").tag(500)
                        Text("1 GB").tag(1024)
                        Text("2 GB").tag(2048)
                        Text("5 GB").tag(5120)
                        Text("不限制").tag(0)
                    }

                    Toggle("超过上限自动清理", isOn: $autoClean)
                        .disabled(cacheLimit == 0)

                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Text("立即清理全部缓存")
                    }

                    Button {
                        showThumbnailConfirm = true
                    } label: {
                        Text("仅清理缩略图")
                    }
                } header: {
                    Text("缓存")
                } footer: {
                    Text("缓存只保存在本机，用于加快浏览与重复播放；清理不会删除服务器上的任何文件。开启自动清理后，缓存超过上限时会按写入时间从旧到新删除，降到上限的 80%。")
                }

                Section("使用说明") {
                    Label("支持 SMB2 / SMB3，视频以流式方式播放，不需要先下载整个文件。", systemImage: "play.rectangle")
                        .font(.footnote)
                    Label("MKV / AVI 等格式依赖系统解码能力，若无法播放可点右上角下载到本地再试。", systemImage: "film")
                        .font(.footnote)
                    Label("视频封面只读取索引与第一个关键帧（约 10 MB），不会下载整部影片。", systemImage: "photo.on.rectangle")
                        .font(.footnote)
                }

                Section("关于") {
                    LabeledContent("版本") {
                        Text(Self.versionText)
                    }
                    LabeledContent("缓存目录") {
                        Text("Caches/SMBViewer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
            .onAppear { cache.refresh() }
            .onChange(of: cacheLimit) { _ in
                cache.autoCleanIfNeeded()
            }
            // 居中弹窗：confirmationDialog 在 iOS 26/27 上会锚定到按钮位置，
            // 从 Form 里弹出来时容易压到上方的开关，改成 alert 稳定居中。
            .alert("确定清空全部缓存？", isPresented: $showClearConfirm) {
                Button("清空缓存", role: .destructive) {
                    cache.clearAll {
                        showToast("缓存已清空")
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除所有缩略图、缓存图片与已下载的视频。")
            }
            .alert("确定清理缩略图？", isPresented: $showThumbnailConfirm) {
                Button("清理缩略图", role: .destructive) {
                    cache.clearThumbnails {
                        showToast("缩略图已清理")
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只会删除缩略图缓存，已缓存的图片与视频会保留。")
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
                        .padding(.bottom, 32)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .task(id: toast) {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            withAnimation(.easeOut(duration: 0.2)) {
                                self.toast = nil
                            }
                        }
                }
            }
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            toast = message
        }
    }

    private static var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
