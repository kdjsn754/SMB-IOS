import UIKit

/// 大图与「下载后播放」的本地文件管理，全部落在缓存目录里，受缓存上限约束
final class MediaStore: @unchecked Sendable {
    static let shared = MediaStore()

    /// 原图预览：只在当前这一页真正显示时才读取，划走立刻取消
    func image(
        for item: FileItem,
        serverID: UUID,
        connection: SMBConnection,
        cancel: CancellationBox? = nil
    ) async -> UIImage? {
        let cache = CacheManager.shared
        let url = cache.mediaURL(serverID: serverID, item: item, suffix: "jpg")
        if let data = try? Data(contentsOf: url), let cached = UIImage(data: data) {
            return cached
        }

        let data: Data
        do {
            data = try await connection.readAll(item.path, cancel: cancel)
        } catch {
            return nil
        }
        if cancel?.isCancelled == true { return nil }

        guard let image = ImageDownsampler.downsample(data: data, maxPixel: 3000) else { return nil }
        if let jpeg = image.jpegData(compressionQuality: 0.9) {
            try? jpeg.write(to: url, options: .atomic)
            cache.noteWrite(bytes: Int64(jpeg.count))
        }
        return image
    }

    func localVideoURL(
        for item: FileItem,
        serverID: UUID,
        connection: SMBConnection,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let cache = CacheManager.shared
        let suffix = item.fileExtension.isEmpty ? "mp4" : item.fileExtension
        let url = cache.mediaURL(serverID: serverID, item: item, suffix: suffix)

        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber,
           size.int64Value > 0 {
            return url
        }

        // 下载前先清理一次，避免撑爆缓存，也尽量不删掉刚下载的文件
        cache.autoCleanIfNeeded()

        let temporary = url.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: temporary)
        do {
            try await connection.download(item.path, to: temporary, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
        cache.refresh()
        return url
    }
}
