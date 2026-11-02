import SwiftUI
import UIKit

/// 缓存 / 存储空间。
///
/// 1.3.34 重设计：顶部换成一张「用量卡」—— 大号数字 + 占用进度条 + 两项明细，
/// 一眼能看出「用了多少、还剩多少」；下面才是上限、自动清理、清理操作。
/// 之前只有三行 `LabeledContent`，看不出占用比例。
@MainActor
struct CacheSettingsView: View {
    @ObservedObject private var cache = CacheManager.shared

    @AppStorage(SettingsKey.cacheLimitMB) private var cacheLimit: Int = 500
    @AppStorage(SettingsKey.autoClean) private var autoClean: Bool = true

    @State private var confirmClearAll = false
    @State private var confirmClearThumbnails = false
    @State private var toast: String?

    var body: some View {
        SettingsDetail(title: "存储空间") {
            Section {
                usageCard
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                Picker(selection: $cacheLimit) {
                    Text("200 MB").tag(200)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("5 GB").tag(5120)
                    Text("不限制").tag(0)
                } label: {
                    HStack(spacing: 12) {
                        SettingsIcon(symbol: "gauge.with.dots.needle.33percent", tint: .indigo)
                        Text("缓存上限")
                    }
                }
                .pickerStyle(.menu)

                SettingsToggleRow(
                    icon: "arrow.triangle.2.circlepath",
                    tint: .teal,
                    title: "自动清理",
                    subtitle: cacheLimit == 0
                        ? "设为「不限制」时不需要自动清理"
                        : "超过上限时先删最旧的，保留最近看的",
                    isOn: $autoClean
                )
                .disabled(cacheLimit == 0)
            } header: {
                SettingsSectionTitle("上限")
            }

            Section {
                Button {
                    confirmClearThumbnails = true
                } label: {
                    SettingsRow(
                        icon: "photo.stack.fill",
                        tint: .blue,
                        title: "清理缩略图",
                        subtitle: "下次打开目录会重新生成",
                        value: Format.bytes(cache.thumbnailBytes)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    confirmClearAll = true
                } label: {
                    SettingsRow(
                        icon: "trash.fill",
                        tint: .red,
                        title: "清空全部缓存",
                        subtitle: "缩略图、图片与视频",
                        titleTint: .red
                    )
                }
                .buttonStyle(.plain)
            } header: {
                SettingsSectionTitle("清理")
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
                    .fill(Color.primary.opacity(0.08))
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

            Divider()

            HStack(spacing: 0) {
                metric(title: "缩略图", bytes: cache.thumbnailBytes)
                Divider().frame(height: 30)
                metric(title: "图片与视频", bytes: cache.mediaBytes)
            }
        }
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
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
