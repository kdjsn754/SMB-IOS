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

    /// 屏幕级预览长边。2800 ≈ 竖屏满屏高度（932pt × 3 = 2796px）。
    /// 之前是 2000：竖屏照片（长边=高）连 1:1 满屏都盖不住，用户反馈「不是原图、看着很模糊」；
    /// 放大后另有 `zoomMaxPixel` 一档兜底（照片 App 的分级加载思路：低清跟手、放大换高清）。
    private static let previewMaxPixel = 2800
    /// 放大查看时从磁盘上的**原始文件**重新解码的长边上限。
    /// 双击 2.5× 在 3x 屏上约需 7000px 宽，5500 能覆盖常见 4000~5000 万像素照片的观感；
    /// 再往上就是 CATiledLayer 分块渲染的领域了，位图内存会爆，不做。
    private static let zoomMaxPixel = 5500
    /// 超过这个大小就不再整份读进内存，改成边读边落临时文件（见 `cacheLargeImage`）
    private static let streamThreshold: Int64 = 24 * 1024 * 1024
    /// 分块读取大小（单次 SMB 请求上限）
    private static let readChunk: Int = 8 * 1024 * 1024

    /// 在途的读取：退到后台时全部掐掉。
    ///
    /// 挂后台的那一刻如果还有一张几十兆的图在读、在解，进程会在后台被系统直接回收
    /// （用户看到的是「切回来 App 重新启动 / 像闪退」）。`NSCache` 清空只是把已经解好的丢掉，
    /// 在途任务不清，后台峰值照样会顶上去。
    private let inflight = NSHashTable<CancellationBox>.weakObjects()
    private let inflightLock = NSLock()

    init() {
        previews.countLimit = 3
        // 2800px 预览一张约 23MB，3 张 70MB —— 旧的 48MB 上限会让第三张把前面挤掉，
        // 白白多解码。96MB 仍然有上界，系统内存吃紧时 NSCache 照样自动清。
        previews.totalCostLimit = 96 * 1024 * 1024
    }

    /// 进后台时调用：把还在跑的读取/解码全部取消
    func cancelAllInflight() {
        inflightLock.lock()
        let boxes = inflight.allObjects
        inflightLock.unlock()
        for box in boxes { box.cancel() }
    }

    private func track(_ cancel: CancellationBox?) {
        guard let cancel else { return }
        inflightLock.lock()
        inflight.add(cancel)
        inflightLock.unlock()
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
        track(cancel)

        // 磁盘命中：一定要走 ImageIO 降采样，不能用 `UIImage(data:)`（懒解码会落到主线程）
        if FileManager.default.fileExists(atPath: url.path),
           let decoded = ImageDownsampler.downsample(url: url, maxPixel: Self.previewMaxPixel) {
            store(decoded, key: key)
            return decoded
        }

        // 大图**不看**「整份读进内存」这条路（见 `cacheLargeImage`）：
        // 一张 40MB 的图，`Data` 就占 40MB，再解出 3000 边长的位图又是 36MB，
        // 峰值能到八九十兆。切到临时文件之后，内存里只有「一个 8MB 的块」和「降采样后的位图」。
        if item.size > Self.streamThreshold {
            guard await cacheLargeImage(item: item, connection: connection, cacheURL: url, cancel: cancel) else {
                return nil
            }
            guard cancel?.isCancelled != true,
                  let preview = ImageDownsampler.downsample(url: url, maxPixel: Self.previewMaxPixel)
            else { return nil }
            store(preview, key: key)
            return preview
        }

        let data: Data
        do {
            data = try await connection.readAll(item.path, cancel: cancel)
        } catch {
            return nil
        }
        if cancel?.isCancelled == true { return nil }

        // 磁盘上**原样保留原始字节**，不做「解码→重压 JPEG→落盘」：
        // ① 重压会永久丢掉原始分辨率（之前落盘的是 3000px JPEG，放大要高清时无米下锅）；
        // ② 少一次解码+编码，读得更快。放大时的高清帧直接从这份原始文件重新解。
        try? data.write(to: url, options: .atomic)
        cache.noteWrite(bytes: Int64(data.count))

        guard let preview = ImageDownsampler.downsample(url: url, maxPixel: Self.previewMaxPixel) else {
            return nil
        }
        store(preview, key: key)
        return preview
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
        track(cancel)

        if !FileManager.default.fileExists(atPath: url.path) {
            // 大图同样走「分块落盘」：预热常常是在用户已经翻到下一页时跑完的，
            // 这时候再整份读进内存，和正在显示的图叠在一起，很容易被系统直接杀掉。
            if item.size > Self.streamThreshold {
                guard await cacheLargeImage(
                    item: item, connection: connection, cacheURL: url, cancel: cancel
                ) else { return }
            } else {
                let data: Data
                do {
                    data = try await connection.readAll(item.path, cancel: cancel)
                } catch {
                    return
                }
                if cancel?.isCancelled == true { return }

                // 原样落原始字节（理由见 `image(for:)`），解码只出屏幕级预览这一份
                try? data.write(to: url, options: .atomic)
                cache.noteWrite(bytes: Int64(data.count))
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

    /// 放大查看用的高清帧：从磁盘上的**原始文件**重新解码（长边 ≤ `zoomMaxPixel`）。
    ///
    /// 照片 App 的分级加载思路：平时显示屏幕级预览（跟手、省内存），
    /// 用户捏开放大后再按需解一份高清的换上去。不进 `NSCache` ——
    /// 一次只看一张、缩回 1x 就释放，缓存它反而挤占预览的配额。
    /// 非 isolated async：解码在后台线程跑，不占主线程。
    func highResImage(for item: FileItem, serverID: UUID) async -> UIImage? {
        let url = CacheManager.shared.mediaURL(serverID: serverID, item: item, suffix: "jpg")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return ImageDownsampler.downsample(url: url, maxPixel: Self.zoomMaxPixel)
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

    /// 大图：**分块读到临时文件 → 原样搬进缓存**。
    ///
    /// 为什么不 `readAll`：`connection.readAll` 会把整份文件读成一个 `Data`（相机 JPEG 常见 20–60MB），
    /// 再解出大位图，两个峰值叠在一起很容易被系统杀掉。走临时文件后，
    /// 内存里只有「一个 8MB 的块」。
    ///
    /// 1.3.19 起落盘的就是**原始文件本身**（搬完即止，不解码不重压）：
    /// 屏幕预览在需要时按 `previewMaxPixel` 从它现解，放大高清按 `zoomMaxPixel` 现解。
    ///
    /// - Returns: 缓存文件是否写好且可用（调用方据此决定要不要再解一次预览）。
    private func cacheLargeImage(
        item: FileItem,
        connection: SMBConnection,
        cacheURL: URL,
        cancel: CancellationBox?
    ) async -> Bool {
        let temp = cacheURL.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: temp)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temp)
        else { return false }

        var written: Int64 = 0
        do {
            while written < item.size {
                if cancel?.isCancelled == true { break }
                let want = Int(min(Int64(Self.readChunk), item.size - written))
                let chunk = try await connection.read(item.path, offset: written, length: want, cancel: cancel)
                if chunk.isEmpty { break }
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
            }
        } catch {
            written = -1
        }
        try? handle.close()

        // 没读满就是残缺数据：宁可下次再读，也别拿半张图当原图
        guard written >= item.size, cancel?.isCancelled != true else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }

        try? FileManager.default.removeItem(at: cacheURL)
        do {
            try FileManager.default.moveItem(at: temp, to: cacheURL)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        CacheManager.shared.noteWrite(bytes: item.size)
        return true
    }

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
