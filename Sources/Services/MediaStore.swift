import UIKit

/// 下载到本地时可能出的错。都要能说人话 —— 用户看到的必须是「为什么」，不是「失败」。
enum MediaStoreError: LocalizedError {
    /// 收到的字节数和远端大小不一致
    case incompleteDownload(expected: Int64, got: Int64)
    /// `hev1 → hvc1` 标签改不动（文件被占用 / 只读），本地播放会黑屏，宁可报错
    case tagPatchFailed

    var errorDescription: String? {
        switch self {
        case let .incompleteDownload(expected, got):
            return "只下到 \(Format.bytes(got)) / \(Format.bytes(expected))，文件不完整"
        case .tagPatchFailed:
            return "本地文件的编码标签改不动（可能被别的程序占着），这个文件在 iPhone 上会黑屏"
        }
    }
}

/// 大图与「下载后播放」的本地文件管理，全部落在缓存目录里，受缓存上限约束
final class MediaStore: @unchecked Sendable {
    static let shared = MediaStore()

    /// 已解码的原图：只留「正在看的那张 + 刚翻过去的一张」。
    ///
    /// 1.3.24 起**没有分级加载**（用户明确要求：点开看图就是原图，不要低清预览+放大换高清）：
    /// 当前页直接按原始分辨率解码。解码仍在后台线程（ImageIO，`shouldCacheImmediately`），
    /// 主线程只负责把位图交给 GPU。
    /// `NSCache` 会在系统内存吃紧时自动清空，加上 `countLimit` / `totalCostLimit`，占用有上界。
    private let previews = NSCache<NSString, UIImage>()

    /// 原图解码的像素上限。10⁸ = 1 亿像素，市面上所有相机原图都够不到 ——
    /// 实际等于「不降采样、按原始分辨率解」，留这个数只是防极端文件把内存打爆。
    private static let fullPixel = 100_000
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
        // 原图位图很重（一张 4800 万像素 ≈ 190MB），只留 2 张：
        // 当前页 + 刚翻过去还没被视图释放的那页。系统内存吃紧时 NSCache 自动清。
        previews.countLimit = 2
        previews.totalCostLimit = 512 * 1024 * 1024
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

    /// 同步取已解码的原图（`NSCache` 命中，微秒级）。
    ///
    /// 看图页在 `init` 里就调它：翻到刚看过的那张时，第一帧画出来就是原图。
    func cachedPreview(for item: FileItem, serverID: UUID) -> UIImage? {
        previews.object(forKey: Self.cacheKey(for: item, serverID: serverID))
    }

    /// 原图（**全分辨率解码**，没有分级）：只在当前这一页真正显示时才读取，划走立刻取消
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

        // 磁盘命中：一定要走 ImageIO 解码，不能用 `UIImage(data:)`（懒解码会落到主线程）
        if FileManager.default.fileExists(atPath: url.path),
           let decoded = ImageDownsampler.downsample(url: url, maxPixel: Self.fullPixel) {
            store(decoded, key: key)
            return decoded
        }

        // 大图**不看**「整份读进内存」这条路（见 `cacheLargeImage`）：
        // 一张 40MB 的图，`Data` 就占 40MB，再解出全分辨率位图又是两三百兆，
        // 峰值能到三百多兆。切到临时文件之后，内存里只有「一个 8MB 的块」和解码结果。
        if item.size > Self.streamThreshold {
            guard await cacheLargeImage(item: item, connection: connection, cacheURL: url, cancel: cancel) else {
                return nil
            }
            guard cancel?.isCancelled != true,
                  let decoded = ImageDownsampler.downsample(url: url, maxPixel: Self.fullPixel)
            else { return nil }
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

        // 磁盘上**原样保留原始字节**，不做「解码→重压 JPEG→落盘」：
        // ① 重压会永久丢掉原始分辨率；② 少一次解码+编码，读得更快。
        try? data.write(to: url, options: .atomic)
        cache.noteWrite(bytes: Int64(data.count))

        guard let decoded = ImageDownsampler.downsample(url: url, maxPixel: Self.fullPixel) else {
            return nil
        }
        store(decoded, key: key)
        return decoded
    }

    /// 预热（翻页用）：只保证磁盘上有压缩副本，**不做解码**。
    ///
    /// 1.3.24 起当前页直接解码原图（全分辨率位图一张就要一两百 MB），
    /// 把没显示的邻居页也解出来内存吃不消 —— 所以预热只负责「把文件搬下来」，
    /// 翻过去那一刻由 `image(for:)` 现解，等待期由缩略图铺底。
    /// 进后台 / 内存警告时 `clearMemoryCache` 整层清掉。
    func warm(
        for item: FileItem,
        serverID: UUID,
        connection: SMBConnection,
        cancel: CancellationBox? = nil
    ) async {
        let cache = CacheManager.shared
        let url = cache.mediaURL(serverID: serverID, item: item, suffix: "jpg")
        if FileManager.default.fileExists(atPath: url.path) { return }
        track(cancel)

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

            // 原样落原始字节（理由见 `image(for:)`）
            try? data.write(to: url, options: .atomic)
            cache.noteWrite(bytes: Int64(data.count))
        }
    }

    func localVideoURL(
        for item: FileItem,
        serverID: UUID,
        connection: SMBConnection,
        cancel: CancellationBox? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let cache = CacheManager.shared
        let suffix = item.fileExtension.isEmpty ? "mp4" : item.fileExtension
        let url = cache.mediaURL(serverID: serverID, item: item, suffix: suffix)

        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = (attributes[.size] as? NSNumber)?.int64Value,
           size > 0 {
            // 大小和远端对不上的就是残片（老版本下到一半被系统杀掉）。
            // 残片交给 AVPlayer 的表现是「点开黑一下、然后什么都没发生」，宁可删掉重下。
            if item.size > 0, size != item.size {
                try? FileManager.default.removeItem(at: url)
            } else {
                // 老版本下的文件没打过 `hev1 → hvc1` 补丁：这里顺手补一次（幂等，只读 moov）
                MP4CodecTag.ensureLocalTag(at: url)
                // 补记一条，设置页里就能显示原始文件名
                VideoDownloadStore.shared.record(item: item, serverID: serverID, url: url)
                return url
            }
        }

        // 下载前先清理一次，避免撑爆缓存，也尽量不删掉刚下载的文件
        cache.autoCleanIfNeeded()

        let temporary = url.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: temporary)
        do {
            try await connection.download(item.path, to: temporary, cancel: cancel, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)

        // ① 大小校验：AMSMB2 的报告偶尔会「成功但少收」，少一个字节播放器都可能直接黑屏
        let landedAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let landed = (landedAttributes?[.size] as? NSNumber)?.int64Value ?? 0
        if item.size > 0, landed != item.size {
            try? FileManager.default.removeItem(at: url)
            throw MediaStoreError.incompleteDownload(expected: item.size, got: landed)
        }

        // ② 落盘之后就地把 `hev1` 改成 `hvc1`（本地播放走的是文件本身，
        // 不经过 `SMBAssetLoader`，不打这个补丁下载完照样黑屏），并回读确认改成功了
        if let tag = MP4CodecTag.ensureLocalTag(at: url), !tag.applied {
            try? FileManager.default.removeItem(at: url)
            throw MediaStoreError.tagPatchFailed
        }

        // 记进下载清单：缓存目录里是 SHA256 文件名，不留记录的话设置页没法列出「下载了哪些」
        VideoDownloadStore.shared.record(item: item, serverID: serverID, url: url)

        cache.refresh()
        return url
    }

    /// 这个资源是不是已经下载到本机了（有就返回缓存文件路径，直接播放，不再走网络）。
    ///
    /// 路径是「服务器 + 路径 + 大小 + 修改时间」算出来的，和 `localVideoURL` 完全一致，
    /// 所以老版本下载的文件也能命中，不依赖索引。
    func existingLocalVideoURL(for item: FileItem, serverID: UUID) -> URL? {
        let suffix = item.fileExtension.isEmpty ? "mp4" : item.fileExtension
        let url = CacheManager.shared.mediaURL(serverID: serverID, item: item, suffix: suffix)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size > 0
        else { return nil }
        // 大小对不上就是半截文件（下载被系统杀掉之类），宁可重新走网络也别放个残片
        if item.size > 0, size != item.size {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
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
    /// 看图时按原始分辨率从它现解（用户要求点开即原图，无分级）。
    ///
    /// - Returns: 缓存文件是否写好且可用（调用方据此决定要不要再解一次原图）。
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
