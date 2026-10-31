import SwiftUI
import UIKit

/// 通用缩略图视图：先看缓存，再按需从服务器读取。
/// 失败会退化成占位图标（不会一直转圈），划走时会取消传输。
@MainActor
struct ThumbnailImage: View {
    let item: FileItem
    let serverID: UUID
    let connection: SMBConnection
    let cornerRadius: CGFloat

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .secondarySystemFill))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if failed {
                    Image(systemName: placeholderIcon)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: item.id) {
                await load()
            }
    }

    private var placeholderIcon: String {
        item.kind == .video ? "film" : "photo"
    }

    private func load() async {
        if let cached = ThumbnailStore.shared.cachedThumbnail(for: item, serverID: serverID) {
            image = cached
            failed = false
            return
        }
        if image == nil { failed = false }

        let result = await ThumbnailStore.shared.thumbnail(
            for: item,
            serverID: serverID,
            connection: connection
        )

        // 被取消（划走 / 翻页）时不要写状态，回来时还要重新尝试
        if Task.isCancelled { return }

        if let result {
            image = result
            failed = false
        } else {
            failed = true
        }
    }
}

@MainActor
struct MediaTile: View {
    let item: FileItem
    let serverID: UUID
    let connection: SMBConnection
    let useGrid: Bool

    var body: some View {
        if useGrid {
            gridBody
        } else {
            listBody
        }
    }

    private var gridBody: some View {
        ZStack(alignment: .bottomLeading) {
            ThumbnailImage(item: item, serverID: serverID, connection: connection, cornerRadius: 10)

            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .center,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 3) {
                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                }
                Text(item.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.bottom, 5)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var listBody: some View {
        HStack(spacing: 10) {
            ThumbnailImage(item: item, serverID: serverID, connection: connection, cornerRadius: 8)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.subheadline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if item.kind == .video {
                        Label("视频", systemImage: "play.rectangle.fill")
                    }
                    Text(Format.bytes(item.size))
                    Text(Format.date(item.modified))
                }
                .font(.caption2)
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
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                VStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.accentColor)
                    Text(item.name)
                        .font(.system(size: 10.5))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 4)
                }
                .padding(6)
            }
            .aspectRatio(1, contentMode: .fit)
        } else {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                    Image(systemName: "folder.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(Format.date(item.modified))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
    }
}

@MainActor
struct OtherTile: View {
    let item: FileItem
    let useGrid: Bool

    var body: some View {
        if useGrid {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
                VStack(spacing: 6) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(item.name)
                        .font(.system(size: 10.5))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .padding(6)
            }
            .aspectRatio(1, contentMode: .fit)
            .opacity(0.75)
        } else {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemFill))
                    Image(systemName: "doc.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(Format.bytes(item.size))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .opacity(0.8)
        }
    }
}
