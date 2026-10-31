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
    @State private var showFailureRecords = false
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

                    Toggle("默认网格视图", isOn: $useGrid)
                }

                PlayerGestureSettingsSections {
                    showToast("已恢复默认手势")
                }

                Section("缩略图") {
                    Toggle("图片缩略图", isOn: $thumbnailsEnabled)
                    Toggle("视频封面", isOn: $videoThumbnails)
                        .disabled(!thumbnailsEnabled)

                    Button("重新加载失败的缩略图") {
                        ThumbnailStore.shared.resetFailures()
                        showToast("已重新排队")
                    }

                    if !diagnostics.entries.isEmpty {
                        DisclosureGroup(isExpanded: $showFailureRecords) {
                            ForEach(diagnostics.entries.prefix(6)) { entry in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .font(.footnote)
                                        .lineLimit(1)
                                    Text(entry.reason)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Button("清除记录", role: .destructive) {
                                diagnostics.clear()
                            }
                        } label: {
                            Text("加载失败记录（\(diagnostics.entries.count)）")
                        }
                    }
                }

                Section("缓存") {
                    LabeledContent("已用") {
                        Text("\(Format.bytes(cache.totalBytes))（缩略图 \(Format.bytes(cache.thumbnailBytes))）")
                            .monospacedDigit()
                    }

                    Picker("上限", selection: $cacheLimit) {
                        Text("200 MB").tag(200)
                        Text("500 MB").tag(500)
                        Text("1 GB").tag(1024)
                        Text("2 GB").tag(2048)
                        Text("5 GB").tag(5120)
                        Text("不限制").tag(0)
                    }

                    Toggle("超过上限自动清理", isOn: $autoClean)
                        .disabled(cacheLimit == 0)

                    Button("清理缩略图") {
                        showThumbnailConfirm = true
                    }

                    Button("清理全部缓存", role: .destructive) {
                        showClearConfirm = true
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: Self.versionText)
                }
            }
            .navigationTitle("设置")
            .onAppear { cache.refresh() }
            .onChange(of: cacheLimit) { _ in
                cache.autoCleanIfNeeded()
            }
            // 居中弹窗：confirmationDialog 在 iOS 26/27 上会锚定到按钮位置，
            // 从 Form 里弹出来时容易压到上方的开关，改成 alert 稳定居中。
            .alert("清空全部缓存？", isPresented: $showClearConfirm) {
                Button("清空", role: .destructive) {
                    cache.clearAll {
                        showToast("缓存已清空")
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("缩略图、缓存图片与已下载的视频都会被删除，服务器上的文件不受影响。")
            }
            .alert("清理缩略图？", isPresented: $showThumbnailConfirm) {
                Button("清理", role: .destructive) {
                    cache.clearThumbnails {
                        showToast("缩略图已清理")
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只删除缩略图，已缓存的图片与视频保留。")
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
