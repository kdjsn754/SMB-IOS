import UIKit
import AVFoundation

/// 缩略图加载：内存缓存 → 磁盘缓存 → 远端读取后降采样
final class ThumbnailStore: @unchecked Sendable {
    static let shared = ThumbnailStore()

    private let memory = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let limiter = AsyncLimiter(limit: 4)

    init() {
        memory.countLimit = 400
        memory.totalCostLimit = 80 * 1024 * 1024
    }

    func clearMemoryCache() {
        memory.removeAllObjects()
    }

    func cachedThumbnail(for item: FileItem, serverID: UUID) -> UIImage? {
        memory.object(forKey: Self.key(for: item, serverID: serverID) as NSString)
    }

    func thumbnail(for item: FileItem, serverID: UUID, connection: SMBConnection) async -> UIImage? {
        let key = Self.key(for: item, serverID: serverID)
        if let image = memory.object(forKey: key as NSString) {
            return image
        }

        lock.lock()
        if let existing = inFlight[key] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            await self.limiter.acquire()
            let image = await self.render(item: item, serverID: serverID, connection: connection)
            await self.limiter.release()
            return image
        }
        inFlight[key] = task
        lock.unlock()

        let image = await task.value

        lock.lock()
        inFlight[key] = nil
        lock.unlock()

        if let image {
            memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        }
        return image
    }

    private func render(item: FileItem, serverID: UUID, connection: SMBConnection) async -> UIImage? {
        let cache = CacheManager.shared
        let url = cache.thumbnailURL(serverID: serverID, item: item)
        if let data = try? Data(contentsOf: url), let cached = UIImage(data: data) {
            return cached
        }

        var image: UIImage?
        switch item.kind {
        case .image:
            if let data = try? await connection.readAll(item.path) {
                image = ImageDownsampler.downsample(data: data, maxPixel: 480)
            }
        case .video:
            image = await VideoThumbnailRenderer.thumbnail(item: item, connection: connection)
        case .folder, .other:
            return nil
        }

        if let image, let data = image.jpegData(compressionQuality: 0.7) {
            try? data.write(to: url, options: .atomic)
            cache.autoCleanIfNeeded()
        }
        return image
    }

    private static func key(for item: FileItem, serverID: UUID) -> String {
        "\(serverID.uuidString)|\(item.path)|\(item.size)|\(item.modified?.timeIntervalSince1970 ?? 0)"
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}

/// 从视频里抽一帧当封面，走的是和播放同一套流式读取
enum VideoThumbnailRenderer {
    static func thumbnail(item: FileItem, connection: SMBConnection) async -> UIImage? {
        var size = item.size
        if size <= 0 {
            size = (try? await connection.fileSize(item.path)) ?? 0
        }
        guard size > 0 else { return nil }

        let asset = MediaAssetFactory.shared.makeAsset(
            connection: connection,
            path: item.path,
            fileSize: size,
            fileExtension: item.fileExtension
        )
        defer { MediaAssetFactory.shared.release(asset) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        if let result = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) {
            return UIImage(cgImage: result.image)
        }
        if let result = try? await generator.image(at: .zero) {
            return UIImage(cgImage: result.image)
        }
        return nil
    }
}
