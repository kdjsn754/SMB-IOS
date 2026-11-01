import SwiftUI
import UIKit

/// 网格缩略图的展示框尺寸。所有格子共用同一个固定框，图片 `.fit` 完整显示并在框内**居中**：
/// 同一行格子尺寸一致，横屏内容上下留白均匀、竖屏内容左右留白均匀，留白是页面底色（不是灰块）。
/// 框下面的文件名 / 大小 / 日期三列齐平。
enum TileAspect {
    /// 展示框的「宽度 / 高度」（0.87 ≈ 宽:高 = 1 : 1.15，略高于正方形，竖屏内容不至于被挤成窄条）
    static let box: CGFloat = 0.87
}

/// 通用缩略图视图：先看缓存，再按需从服务器读取。
/// 失败会退化成占位图标（不会一直转圈），划走时会取消传输。
/// 图片完整显示（不裁切）并在展示框里居中，没有图片时才铺灰色占位底。
@MainActor
struct ThumbnailImage: View {
    let item: FileItem
    let serverID: UUID
    let connection: SMBConnection
    var cornerRadius: CGFloat = 4
    /// 在目录里的显示序号：让缩略图按「左上 → 右下」的顺序出现，而不是随机位置冒出来
    var order: Int = 0
    /// 视频是否显示左下角的播放角标（列表页已有播放图标，传 false 避免重复）
    var showPlayBadge: Bool = true

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay(alignment: .bottomLeading) {
                        if showPlayBadge, item.kind == .video { playBadge }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
                    .overlay {
                        if failed {
                            Image(systemName: placeholderIcon)
                                .font(.system(size: 20, weight: .regular))
                                .foregroundStyle(.tertiary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
            }
        }
        // 撑满展示框并居中：横屏图上下留白、竖屏图左右留白，都是均匀的
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .task(id: item.id) {
            await load()
        }
    }

    private var playBadge: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(.black.opacity(0.45), in: Circle())
            .padding(5)
    }

    private var placeholderIcon: String {
        item.kind == .video ? "film" : "photo"
    }

    private func load() async {
        if let cached = ThumbnailStore.shared.cachedThumbnail(for: item, serverID: serverID) {
            apply(cached)
            return
        }
        if image == nil { failed = false }

        let result = await ThumbnailStore.shared.thumbnail(
            for: item,
            serverID: serverID,
            connection: connection,
            order: order
        )

        // 被取消（划走 / 翻页）时不要写状态，回来时还要重新尝试
        if Task.isCancelled { return }

        if let result {
            apply(result)
        } else {
            failed = true
        }
    }

    private func apply(_ image: UIImage) {
        self.image = image
        failed = false
    }
}

/// 两行居中、中间省略的文件名（对齐「文件名 / 大小 / 日期」三行式网格）
struct FileNameLabel: View {
    let name: String

    /// 名字太长时拆成「前半 + …后半」，避免只看到一长串前缀
    private var split: (head: String, tail: String)? {
        guard name.count > 26 else { return nil }
        return (String(name.prefix(16)), String(name.suffix(12)))
    }

    var body: some View {
        Group {
            if let split {
                VStack(spacing: 0) {
                    Text(split.head)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("…" + split.tail)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text(name)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 13))
        .multilineTextAlignment(.center)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        // 固定成两行的高度：同一行里短文件名不会把下面的「大小 / 日期」提上去
        .frame(minHeight: 32, alignment: .top)
    }
}

/// 缩略图下方的两行说明文字（大小 / 日期）
struct TileCaption: View {
    let size: String
    let date: String

    var body: some View {
        VStack(spacing: 2) {
            Text(size)
            Text(date)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}

@MainActor
struct MediaTile: View {
    let item: FileItem
    let serverID: UUID
    let connection: SMBConnection
    let useGrid: Bool
    var order: Int = 0
    /// 看图页的缩放转场命名空间：挂在缩略图上，点开时画面就从这个格子长出来。
    /// 不传（nil）时完全不生效，旧系统 / 其它入口照旧。
    var zoomNamespace: Namespace.ID? = nil

    var body: some View {
        if useGrid {
            gridBody
        } else {
            listBody
        }
    }

    private var gridBody: some View {
        VStack(spacing: 6) {
            ThumbnailImage(
                item: item,
                serverID: serverID,
                connection: connection,
                order: order
            )
            .aspectRatio(TileAspect.box, contentMode: .fit)
            // 缩放起点只包缩略图这块，不含下面的文件名 / 大小 / 日期，
            // 否则画面会从一个「带两行文字的大方块」里长出来，落点和图片对不上。
            .zoomSource(id: item.id, in: zoomNamespace)

            FileNameLabel(name: item.name)
            TileCaption(size: Format.bytes(item.size), date: Format.shortDate(item.modified))
        }
    }

    private var listBody: some View {
        HStack(spacing: 12) {
            ThumbnailImage(
                item: item,
                serverID: serverID,
                connection: connection,
                cornerRadius: 6,
                order: order,
                showPlayBadge: false
            )
            .frame(width: 56, height: 56)
            .zoomSource(id: item.id, in: zoomNamespace, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if item.kind == .video {
                        Image(systemName: "play.rectangle.fill")
                    }
                    Text(Format.bytes(item.size))
                    Text("·")
                    Text(Format.shortDate(item.modified))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

@MainActor
struct FolderTile: View {
    let item: FileItem
    let useGrid: Bool

    var body: some View {
        if useGrid {
            gridBody
        } else {
            listBody
        }
    }

    private var gridBody: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "folder.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
            }
            .aspectRatio(TileAspect.box, contentMode: .fit)

            FileNameLabel(name: item.name)
            TileCaption(size: "文件夹", date: Format.shortDate(item.modified))
        }
    }

    private var listBody: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "folder.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(Format.shortDate(item.modified))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

@MainActor
struct OtherTile: View {
    let item: FileItem
    let useGrid: Bool

    var body: some View {
        if useGrid {
            gridBody
        } else {
            listBody
        }
    }

    private var gridBody: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
                Image(systemName: "doc.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
            }
            .aspectRatio(TileAspect.box, contentMode: .fit)

            FileNameLabel(name: item.name)
            TileCaption(size: Format.bytes(item.size), date: Format.shortDate(item.modified))
        }
    }

    private var listBody: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
                Image(systemName: "doc.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(Format.bytes(item.size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
