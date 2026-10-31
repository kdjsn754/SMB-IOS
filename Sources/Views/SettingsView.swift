import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var cache = CacheManager.shared

    @AppStorage(SettingsKey.theme) private var themeRaw: String = AppTheme.system.rawValue
    @AppStorage(SettingsKey.cacheLimitMB) private var cacheLimit: Int = 500
    @AppStorage(SettingsKey.autoClean) private var autoClean: Bool = true
    @AppStorage(SettingsKey.gridLayout) private var useGrid: Bool = true

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
                    Label("视频缩略图会读取文件头部数据，文件很大时首次加载会稍慢。", systemImage: "photo.on.rectangle")
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
            .confirmationDialog("确定清空全部缓存？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空缓存", role: .destructive) {
                    cache.clearAll {
                        toast = "缓存已清空"
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将删除所有缩略图、缓存图片与已下载的视频。")
            }
            .confirmationDialog("确定清理缩略图？", isPresented: $showThumbnailConfirm, titleVisibility: .visible) {
                Button("清理缩略图", role: .destructive) {
                    cache.clearThumbnails {
                        toast = "缩略图已清理"
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只会删除缩略图缓存，已缓存的图片与视频会保留。")
            }
            .alert("完成", isPresented: Binding(
                get: { toast != nil },
                set: { if !$0 { toast = nil } }
            )) {
                Button("好", role: .cancel) { toast = nil }
            } message: {
                Text(toast ?? "")
            }
        }
    }

    private static var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
