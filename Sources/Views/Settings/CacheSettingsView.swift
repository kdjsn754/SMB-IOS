import SwiftUI
import UIKit

/// 缓存 / 存储空间。
///
/// 1.3.34 重设计：顶部换成一张「用量卡」—— 大号数字 + 占用进度条 + 两项明细，
/// 一眼能看出「用了多少、还剩多少」；下面才是上限、自动清理、清理操作。
/// 1.7.6 换到统一表面令牌：用量卡的底不再写死不透明色（壁纸下曾是死白一块）。
@MainActor
struct CacheSettingsView: View {
    @ObservedObject private var cache = CacheManager.shared
    @ObservedObject private var background = BackgroundSettings.shared

    @AppStorage(SettingsKey.cacheLimitMB) private var cacheLimit: Int = 500
    @AppStorage(SettingsKey.autoClean) private var autoClean: Bool = true

    @State private var confirmClearAll = false
    @State private var confirmClearThumbnails = false
    @State private var toast: String?

    var body: some View {
        SettingsDetail(title: "存储空间") {
            usageCard

            AppGroup("上限") {
                AppRow(
                    icon: "gauge.with.dots.needle.33percent",
                    iconTint: .indigo,
                    title: "缓存上限"
                ) {
                    Picker("", selection: $cacheLimit) {
                        Text("200 MB").tag(200)
                        Text("500 MB").tag(500)
                        Text("1 GB").tag(1024)
                        Text("2 GB").tag(2048)
                        Text("5 GB").tag(5120)
                        Text("不限制").tag(0)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                AppRow(
                    icon: "arrow.triangle.2.circlepath",
                    iconTint: .teal,
                    title: "自动清理",
                    subtitle: cacheLimit == 0
                        ? "设为「不限制」时不需要自动清理"
                        : "超过上限时先删最旧的，保留最近看的",
                    showsSeparator: false
                ) {
                    Toggle("", isOn: $autoClean)
                        .labelsHidden()
                }
                .disabled(cacheLimit == 0)
            }

            AppGroup("清理") {
                Button {
                    confirmClearThumbnails = true
                } label: {
                    AppRow(
                        icon: "photo.stack.fill",
                        iconTint: .blue,
                        title: "清理缩略图",
                        subtitle: "下次打开目录会重新生成",
                        value: Format.bytes(cache.thumbnailBytes)
                    )
                }
                .buttonStyle(AppRowPressStyle())

                Button {
                    confirmClearAll = true
                } label: {
                    AppRow(
                        icon: "trash.fill",
                        iconTint: .red,
                        title: "清空全部缓存",
                        subtitle: "缩略图、图片与视频",
                        titleColor: .red,
                        showsSeparator: false
                    )
                }
                .buttonStyle(AppRowPressStyle())
            }
        }
        .toast($toast)
        .onAppear { cache.refresh() }
        .onChange(of: cacheLimit) { _ in
            cache.autoCleanIfNeeded()
        }
        // 居中弹窗：confirmationDialog 会锚到按钮位置，容易压住上方的开关，统一用 alert
        .alert("清空全部缓存？", isPresented: $confirmClearAll) {
            Button("删除", role: .destructive) {
                cache.clearAll { toast = "缓存已清空" }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("缩略图、已缓存的图片和视频都会被删除。服务器上的原文件不受影响，下次浏览会重新下载。")
        }
        .alert("清理缩略图？", isPresented: $confirmClearThumbnails) {
            Button("清理", role: .destructive) {
                cache.clearThumbnails { toast = "缩略图已清理" }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除缩略图，已缓存的图片和视频保留；下次打开目录时会按需重新生成。")
        }
    }

    // MARK: - 用量卡

    private var limitBytes: Int64 {
        Int64(max(0, cacheLimit)) * 1024 * 1024
    }

    private var ratio: Double {
        guard cacheLimit > 0, limitBytes > 0 else { return 0 }
        return min(1, Double(cache.totalBytes) / Double(limitBytes))
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.bytes(cache.totalBytes))
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()

                Text("已使用")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Text(cacheLimit == 0 ? "不限制" : "上限 " + Format.bytes(limitBytes))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if cacheLimit > 0 {
                Capsule()
                    .fill(background.surfaces.track)
                    .frame(height: 8)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: proxy.size.width * CGFloat(ratio))
                        }
                    }
                    .clipShape(Capsule())

                HStack {
                    Text("已用 \(Int((ratio * 100).rounded()))%")
                    Spacer()
                    Text("剩余 " + Format.bytes(max(0, limitBytes - cache.totalBytes)))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Rectangle()
                .fill(background.surfaces.separator)
                .frame(height: 0.5)

            HStack(spacing: 0) {
                metric(title: "缩略图", bytes: cache.thumbnailBytes)
                Rectangle()
                    .fill(background.surfaces.separator)
                    .frame(width: 0.5, height: 30)
                metric(title: "图片与视频", bytes: cache.mediaBytes)
            }
        }
        .padding(16)
        .appCardSurface()
    }

    private func metric(title: String, bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Format.bytes(bytes))
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 2)
    }
}
