import SwiftUI
import UIKit

/// 「视频下载」管理页。
///
/// 之前「下载到本地」是一条单向路：下完就播，播完想清掉只能去「存储空间」里
/// **连缩略图和图片一起**清空 —— 用户根本分不清哪个文件是哪个视频。
/// 这里把已下载的视频按「原文件名 + 大小 + 下载时间」列出来，可以一个一个删。
///
/// 数据来自 `VideoDownloadStore`：下载时写索引，列表则每次都按磁盘对账，
/// 所以文件被缓存上限淘汰后这里也会同步消失，不会留下点不开的死条目。
@MainActor
struct DownloadSettingsView: View {
    @ObservedObject private var store = VideoDownloadStore.shared

    @State private var pendingDelete: DownloadedVideo?
    @State private var confirmClearAll = false
    @State private var toast: String?

    var body: some View {
        SettingsDetail(title: "视频下载") {
            if store.items.isEmpty {
                emptySection
            } else {
                listSection
                clearSection
            }
        }
        .toast($toast)
        .onAppear { store.reload() }
        .alert("删除这个视频？", isPresented: deleteAlertBinding) {
            Button("删除", role: .destructive) {
                if let video = pendingDelete {
                    store.delete(video)
                    toast = "已删除「\(video.name)」"
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("只删本机这份拷贝，服务器上的原文件不受影响，之后还能重新下载。")
        }
    }

    // MARK: - 列表

    private var listSection: some View {
        Section {
            ForEach(store.items) { video in
                row(video)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDelete = video
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        } header: {
            SettingsSectionTitle("\(store.items.count) 个 · \(Format.bytes(store.totalBytes))")
        } footer: {
            Text("这里只列出下载到本机的视频，左滑或点垃圾桶删除。删除后服务器上的原文件不受影响。")
        }
    }

    private func row(_ video: DownloadedVideo) -> some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: "film.fill", tint: .blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(video.name)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(video.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                pendingDelete = video
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 32, height: 32)
                    .background(Color.red.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除 \(video.name)")
        }
        .padding(.vertical, 2)
    }

    // MARK: - 空状态 / 全部删除

    private var emptySection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)

                Text("还没有下载到本机的视频")
                    .font(.subheadline.weight(.medium))

                Text("播放页里播不动的片子，点过「下载到本地播放」之后就会出现在这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var clearSection: some View {
        Section {
            Button {
                confirmClearAll = true
            } label: {
                SettingsRow(
                    icon: "trash.fill",
                    tint: .red,
                    title: "删除全部下载",
                    subtitle: "只删视频，不动缩略图和图片缓存",
                    titleTint: .red
                )
            }
            .buttonStyle(.plain)
            // 弹窗挂在按钮上、不挂整页：同一页两个 `.alert` 挂在同一个视图上，
            // 后挂的会把先挂的顶掉，删除单个视频的确认框就弹不出来了
            .alert("删除全部已下载的视频？", isPresented: $confirmClearAll) {
                Button("全部删除", role: .destructive) {
                    store.deleteAll()
                    toast = "已删除全部下载"
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("共 \(store.items.count) 个、\(Format.bytes(store.totalBytes))。缩略图和缓存的图片不受影响。")
            }
        } header: {
            SettingsSectionTitle("清理")
        }
    }

    /// `alert(isPresented:)` 需要 Bool 绑定，删除对象用可选值驱动
    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }
}
