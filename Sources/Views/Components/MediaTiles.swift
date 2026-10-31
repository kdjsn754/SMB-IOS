import SwiftUI
import UIKit

/// 网格缩略图的长宽比。所有格子都用 `.fit` 完整显示图片。
/// 这里只给出「加载完成前」的占位比例（正方形最中性），
/// 图片真正加载出来后会用它的真实宽高比撑开格子，竖幅就竖条、横幅就横条。
enum TileAspect {
    /// 加载完成前的占位比例（正方形）
    static let placeholder: CGFloat = 1
}

/// 通用缩略图视图：先看缓存，再按需从服务器读取。
/// 失败会退化成占位图标（不会一直转圈），划走时会取消传输。
/// 加载到真实图片后，通过 `onAspectChange` 把真实宽高比回传给父级，
/// 父级用它做瀑布流布局，让竖屏内容也能完整撑满格子、不被压成一条。
@MainActor
struct ThumbnailImage: View {
    let item: FileItem
    let serverID: UUID
    let connection: SMBConnection
    var cornerRadius: CGFloat = 4
    /// 在目录里的显示序号：让缩略图按「左上 → 右下」的顺序出现，而不是随机位置冒出来
    var order: Int = 0
    /// 加载到真实图片后回传宽高比（width / height）
    var onAspectChange: (CGFloat) -> Void = { _ in }

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .secondarySystemFill))
            .overlay {
                if let image {
                    // 完整显示整张图，不做填充裁切（参照同类文件管理软件的做法）
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else if failed {
                    Image(systemName: placeholderIcon)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(Rectangle())
            .task(id: item.id) {
                await load()
            }
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
        let w = image.size.width
        let h = image.size.height
        guard w > 0, h > 0 else { return }
        onAspectChange(w / h)
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
    /// 当前已知的缩略图宽高比（width / height），加载完成前用占位比例
    var aspect: CGFloat = TileAspect.placeholder
    /// 缩略图加载后回传真实宽高比
    var onAspectChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        if useGrid {
            gridBody
        } else {
            listBody
        }
    }

    private var gridBody: some View {
        VStack(spacing: 5) {
            ThumbnailImage(
                item: item,
                serverID: serverID,
                connection: connection,
                order: order,
                onAspectChange: onAspectChange
            )
            .aspectRatio(aspect, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(5)
                }
            }

            FileNameLabel(name: item.name)
            TileCaption(size: Format.bytes(item.size), date: Format.shortDate(item.modified))
        }
    }

    private var listBody: some View {
        HStack(spacing: 12) {
            ThumbnailImage(item: item, serverID: serverID, connection: connection, cornerRadius: 6, order: order)
                .frame(width: 56, height: 56)

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
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "folder.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
            }
            .aspectRatio(1, contentMode: .fit)

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
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
                Image(systemName: "doc.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
            }
            .aspectRatio(1, contentMode: .fit)

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
