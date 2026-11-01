import UIKit

/// 大图与「下载后播放」的本地文件管理，全部落在缓存目录里，受缓存上限约束
final class MediaStore: @unchecked Sendable {
    static let shared = MediaStore()

    /// 屏幕级预览：已降采样、**已完全解码**，只留「正在看的那张 + 前后各一张」。
    ///
    /// 为什么要这一层（1.3.3）：
    /// 1. **把解码搬离主线程**。原来缓存命中走的是 `UIImage(data:)`，它只是把压缩数据挂上去，
    ///    真正的解码发生在主线程第一次绘制 —— 每翻一页就卡一下，这就是「左右滑动很卡顿」的主因。
    ///    换成 `ImageDownsampler.downsample(url:)`（ImageIO，`shouldCacheImmediately`）之后，
    ///    解码完整地发生在后台线程，主线程只负责把位图交给 GPU。
    /// 2. **翻页第一帧就是清晰的**。滑到下一张时它已经解码好躺在缓存里，
    ///    不会出现「先糊着 480px 缩略图、再啪一下换成原图」。
    /// `NSCache` 会在系统内存吃紧时自动清空，加上 `countLimit`，占用有上界。
    private let previews = NSCache<NSString, UIImage>()

    /// 预览长边。2000 ≈ 3 倍屏宽（430pt × 3 = 1290）的 1.55 倍，
    /// 在这个倍率内放大仍是一比一像素；比原来 3000 边长省一半以上内存。
    private static let previewMaxPixel = 2000
    /// 落盘的长边：放大时更耐看，和预览分开
    private static let diskMaxPixel = 3000

    init() {
        previews.countLimit = 4
        previews.totalCostLimit = 64 * 1024 * 1024
    }

    /// 内存吃紧 / 进后台时调用
    func clearMemoryCache() {
        previews.removeAllObjects()
    }

    /// 同步取已解码的预览（`NSCache` 命中，微秒级）。
    ///
    /// 看图页在 `init` 里就调它：翻到已经有预览的那张时，**第一帧**画出来就是清晰原图。
    func cachedPreview(for item: FileItem, serverID: UUID) -> UIImage? {
        previews.object(forKey: Self.cacheKey(for: item, serverID: serverID))
    }

    /// 原图预览：只在当前这一页真正显示时才读取，划走立刻取消
    func image(
        for item: FileItem,
        serverID: UUID,
        connection: SMBConnection,
        cancel: CancellationBox? = nil
    ) async -> UIImage? {
        let cache = CacheManager.shared
        let url = cache.mediaURL(serverID: serverID, item: item, suffix: "jpg")
        let key = Self.cacheKey(for: item, serverID: serverID)

        if let hit = previews.object(forKey: key) { return hit }

        // 磁盘命中：一定要走 ImageIO 降采样，不能用 `UIImage(data:)`（懒解码会落到主线程）
        if FileManager.default.fileExists(atPath: url.path),
           let decoded = ImageDownsampler.downsample(url: url, maxPixel: Self.previewMaxPixel) {
            store(decoded, key: key)
            return decoded
        }

        let data: Data
        do {
            data = try await connection.readAll(item.path, cancel: cancel)
        } catch {
            return nil
        }
        if cancel?.isCancelled == true { return nil }

        guard let full = ImageDownsampler.downsample(data: data, maxPixel: Self.diskMaxPixel) else {
            return nil
        }
        if let jpeg = full.jpegData(compressionQuality: 0.9) {
            try? jpeg.write(to: url, options: .atomic)
            cache.noteWrite(bytes: Int64(jpeg.count))
        }
        // 刚落盘的文件再取一次屏幕级的：一次 ImageIO 小文件解码，比在主线程解 3000 边长便宜得多
        if let preview = ImageDownsampler.downsample(url: url, maxPixel: Self.previewMaxPixel) {
            store(preview, key: key)
            return preview
        }
        store(full, key: key)
        return full
    }

    /// 预热（翻页用）：保证磁盘上有压缩副本，**并把已解码的预览放进内存**。
    ///
    /// 1.3.1 那版预热只写盘、不留在内存，理由是省内存；但代价是每次翻页都要重新解码一张大图，
    /// 滑过去先是糊的缩略图、再卡一下变清晰。现在解码结果进 `NSCache`（最多 4 张、可被系统回收），
    /// 换来的是「滑过去第一帧就是清晰的」；进后台 / 内存警告时整层清掉。
    func warm(
        for item: FileItem,
        serverID: UUID,
        connection: SMBConnection,
        cancel: CancellationBox? = nil
    ) async {
        let cache = CacheManager.shared
        let url = cache.mediaURL(serverID: serverID, item: item, suffix: "jpg")
        let key = Self.cacheKey(for: item, serverID: serverID)
        if previews.object(forKey: key) != nil { return }

        if !FileManager.default.fileExists(atPath: url.path) {
            let data: Data
            do {
                data = try await connection.readAll(item.path, cancel: cancel)
            } catch {
                return
            }
            if cancel?.isCancelled == true { return }

            autoreleasepool {
                if let image = ImageDownsampler.downsample(data: data, maxPixel: Self.diskMaxPixel),
                   let jpeg = image.jpegData(compressionQuality: 0.9) {
                    try? jpeg.write(to: url, options: .atomic)
                    cache.noteWrite(bytes: Int64(jpeg.count))
                }
            }
            if cancel?.isCancelled == true { return }
        }

        autoreleasepool {
            guard let decoded = ImageDownsampler.downsample(url: url, maxPixel: Self.previewMaxPixel) else {
                return
            }
            store(decoded, key: key)
        }
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

    // MARK: - 内部

    private func store(_ image: UIImage, key: NSString) {
        previews.setObject(image, forKey: key, cost: Self.cost(of: image))
    }

    /// 键里带上大小和修改时间：同名文件被替换后不会命中旧图
    private static func cacheKey(for item: FileItem, serverID: UUID) -> NSString {
        "\(serverID.uuidString)|\(item.path)|\(item.size)|\(item.modified?.timeIntervalSince1970 ?? 0)" as NSString
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
