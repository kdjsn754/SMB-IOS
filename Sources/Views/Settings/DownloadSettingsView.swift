import SwiftUI
import UIKit

/// 「视频下载」管理页。
///
/// 之前「下载到本地」是一条单向路：下完就播，播完想清掉只能去「存储空间」里
/// **连缩略图和图片一起**清空 —— 用户根本分不清哪个文件是哪个视频。
/// 这里把已下载的视频按「封面 + 原文件名 + 大小 + 下载时间」列出来。
///
/// 1.7.6 不再用 `List`：卡片与行线交给统一组件，左滑删除用 `SwipeDeleteRow`
/// 自己实现，观感和其它设置页一致（见 `AppSurface.swift`）。
@MainActor
struct DownloadSettingsView: View {
    @ObservedObject private var store = VideoDownloadStore.shared

    @State private var pendingDelete: DownloadedVideo?
    @State private var confirmClearAll = false
    @State private var toast: String?
    /// 正在播放哪一条（`fullScreenCover` 的驱动）
    @State private var playing: PlaybackRequest?

    /// 点一行 → 进播放页。带着文件地址一起走，播放页不用再查索引。
    private struct PlaybackRequest: Identifiable {
        let id: String
        let item: FileItem
        let url: URL
    }

    var body: some View {
        SettingsDetail(title: "视频下载") {
            if store.items.isEmpty {
                AppGroup {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.secondary)

                        Text("还没有下载到本机的视频")
                            .font(.subheadline.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            } else {
                videoList
                clearSection
            }
        }
        .toast($toast)
        .onAppear { store.reload() }
        .fullScreenCover(item: $playing) { request in
            // 没有服务器上下文：放的就是 `request.url` 这个本机文件。
            // 断网、服务器被删掉都不影响。
            VideoPlayerView(
                item: request.item,
                serverID: nil,
                connection: nil,
                localURL: request.url
            )
        }
        .alert("删除这个视频？", isPresented: deleteAlertBinding) {
            Button("删除", role: .destructive) {
                if let video = pendingDelete {
                    LocalVideoThumbnailer.shared.forget(key: video.id)
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

    private var videoList: some View {
        AppGroup("\(store.items.count) 个 · \(Format.bytes(store.totalBytes))") {
            ForEach(Array(store.items.enumerated()), id: \.element.id) { index, video in
                SwipeDeleteRow(onDelete: { pendingDelete = video }) {
                    Button {
                        play(video)
                    } label: {
                        row(video)
                    }
                    .buttonStyle(.plain)
                }

                if index < store.items.count - 1 {
                    AppSeparator()
                }
            }
        }
    }

    private func row(_ video: DownloadedVideo) -> some View {
        HStack(spacing: 12) {
            DownloadThumbnail(url: store.fileURL(for: video), key: video.id)

            VStack(alignment: .leading, spacing: 3) {
                Text(video.name)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary)
                Text(video.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSurfaces.cardPadding)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - 播放

    private func play(_ video: DownloadedVideo) {
        let url = store.fileURL(for: video)
        // 文件刚好被缓存淘汰 / 被别的入口删掉了：刷新一下列表，别进一个黑屏
        guard FileManager.default.fileExists(atPath: url.path) else {
            toast = "这个文件已经不在了，正在刷新列表"
            store.reload()
            return
        }
        let item = FileItem(
            name: video.name,
            // 老版本下载的条目没有远端路径，用文件名兜底 —— 只用来做「这是哪一条」的标识
            path: video.remotePath ?? video.name,
            isDirectory: false,
            size: video.byteSize,
            modified: nil
        )
        playing = PlaybackRequest(id: video.id, item: item, url: url)
    }

    // MARK: - 全部删除

    private var clearSection: some View {
        AppGroup("清理") {
            Button {
                confirmClearAll = true
            } label: {
                AppRow(
                    icon: "trash.fill",
                    iconTint: .red,
                    title: "删除全部下载",
                    subtitle: "只删视频，不动缩略图和图片缓存",
                    titleColor: .red,
                    showsSeparator: false
                )
            }
            .buttonStyle(AppRowPressStyle())
            // 弹窗挂在按钮上、不挂整页：同一页两个 `.alert` 挂在同一个视图上，
            // 后挂的会把先挂的顶掉，删除单个视频的确认框就弹不出来了
            .alert("删除全部已下载的视频？", isPresented: $confirmClearAll) {
                Button("全部删除", role: .destructive) {
                    for video in store.items {
                        LocalVideoThumbnailer.shared.forget(key: video.id)
                    }
                    store.deleteAll()
                    toast = "已删除全部下载"
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("共 \(store.items.count) 个、\(Format.bytes(store.totalBytes))。缩略图和缓存的图片不受影响。")
            }
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

/// 列表行左边的封面。
///
/// 直接从**本机文件**抓首帧（`LocalVideoThumbnailer`），不走 SMB ——
/// 这样服务器不在线也能看到封面。抓不出来（比如 4:4:4 的 HEVC）就退回胶片图标。
private struct DownloadThumbnail: View {
    let url: URL
    let key: String

    @State private var image: UIImage?
    @State private var duration: Double = 0

    private let side: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .secondarySystemFill))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film.fill")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            // 播放角标：一眼看出这一行点了能播
            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.black.opacity(0.42), in: Circle())
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if duration > 0 {
                Text(Format.duration(duration))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(3)
            }
        }
        .task(id: key) {
            // 已经解过的先摆上，避免列表刷新时封面闪一下
            image = LocalVideoThumbnailer.shared.cachedImage(for: key)
            guard let snapshot = await LocalVideoThumbnailer.shared.snapshot(for: url, key: key) else { return }
            guard !Task.isCancelled else { return }
            image = snapshot.image
            duration = snapshot.duration
        }
    }
}
