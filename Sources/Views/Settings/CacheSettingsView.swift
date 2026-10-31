import SwiftUI

@MainActor
struct CacheSettingsView: View {
    @ObservedObject private var cache = CacheManager.shared

    @AppStorage(SettingsKey.cacheLimitMB) private var cacheLimit: Int = 500
    @AppStorage(SettingsKey.autoClean) private var autoClean: Bool = true

    @State private var confirmClearAll = false
    @State private var confirmClearThumbnails = false
    @State private var toast: String?

    private func showToast(_ text: String) {
        toast = text
    }

    var body: some View {
        SettingsDetail(title: "缓存") {
            Section {
                LabeledContent("已用", value: Format.bytes(cache.totalBytes))
                LabeledContent("缩略图", value: Format.bytes(cache.thumbnailBytes))
                LabeledContent("视频与图片", value: Format.bytes(cache.mediaBytes))
            }

            Section {
                Picker("上限", selection: $cacheLimit) {
                    Text("200 MB").tag(200)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("5 GB").tag(5120)
                    Text("不限制").tag(0)
                }
                .pickerStyle(.menu)

                Toggle("超过上限自动清理", isOn: $autoClean)
                    .disabled(cacheLimit == 0)
            }

            Section {
                Button("清理缩略图") {
                    confirmClearThumbnails = true
                }
                Button("清理全部缓存", role: .destructive) {
                    confirmClearAll = true
                }
            }
        }
        .toast($toast)
        .onAppear { cache.refresh() }
        .onChange(of: cacheLimit) { _ in
            cache.autoCleanIfNeeded()
        }
        // 居中弹窗：confirmationDialog 会锚到按钮位置，容易压住上方的开关，统一用 alert
        .alert("清空全部缓存？", isPresented: $confirmClearAll) {
            Button("清空", role: .destructive) {
                cache.clearAll { showToast("缓存已清空") }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("缩略图、缓存图片与已下载的视频都会被删除，服务器上的文件不受影响。")
        }
        .alert("清理缩略图？", isPresented: $confirmClearThumbnails) {
            Button("清理", role: .destructive) {
                cache.clearThumbnails { showToast("缩略图已清理") }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除缩略图，已缓存的图片与视频保留。")
        }
    }
}
