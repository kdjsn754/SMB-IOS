import UIKit
import AVFoundation

/// 缩略图调度：内存缓存 → 磁盘缓存 → 远端读取（限并发、限流量、可取消）
///
/// 设计要点：
/// 1. 同一个文件只生成一份 480px 缩略图，网格和列表共用，避免同一张图取两次。
/// 2. 图片和视频共用一道有序闸门（一次一个、按格子序号放行），缩略图严格按「左上 → 右下」依次出现。
/// 3. 每次读取都有字节上限，取消时通过 `CancellationBox` 立刻中止传输。
/// 4. 失败的文件进负缓存冷却几分钟，避免「划回去就重试」把 NAS 打满。
final class ThumbnailStore: @unchecked Sendable {
    static let shared = ThumbnailStore()

    /// 统一缩略图长边像素（网格最宽 160pt × 3 倍屏 = 480）
    private static let pixelSize = 480
    /// 图片必须整份读到才解码：JPEG / PNG 被截断时 ImageIO 不会返回 nil，
    /// 而是给出一张「上半张正常、下半张灰」的假图（缩略图加载不全的根因）。
    /// 所以这里不再按大小分阶段试探，一律读满；超过上限的直接放弃。
    private static let imageHardLimit: Int64 = 64 * 1024 * 1024
    /// 分块读取大小（单次 SMB 读请求上限）
    private static let imageReadChunk: Int = 8 * 1024 * 1024
    /// 视频封面允许消耗的字节额度（仅流式兜底路径使用）
    private static let videoByteBudget: Int64 = 32 * 1024 * 1024
    /// 失败冷却时间
    private static let failureTTL: TimeInterval = 180
    /// AVFoundation 无法解码的容器，直接不做封面，避免白读十几兆
    private static let undecodableVideoExtensions: Set<String> = [
        "mkv", "avi", "wmv", "flv", "rmvb", "rm", "webm", "vob"
    ]

    private final class Job: @unchecked Sendable {
        let task: Task<UIImage?, Never>
        let box: CancellationBox
        var waiters: Int = 0

        init(task: Task<UIImage?, Never>, box: CancellationBox) {
            self.task = task
            self.box = box
        }
    }

    private final class Waiter: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        /// 返回 true 表示这是第一次收尾，需要真正释放
        func finishOnce() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }
    }

    private let memory = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var failures: [String: Date] = [:]

    /// 缩略图唯一的闸门：图片和视频共用，一次只跑一个、按格子序号放行。
    /// 分成「图片 3 并发 + 视频 1 并发」两道闸门时是排不出全局顺序的
    /// （视频可能比它前面几张图片先返回），所以合并成一道。
    /// 宽限 60 ms 让同一批创建的格子先把序号登记进队伍。
    private let displayLimiter = OrderedLimiter(limit: 1, graceMilliseconds: 60)

    init() {
        memory.countLimit = 600
        memory.totalCostLimit = 64 * 1024 * 1024
    }

    func clearMemoryCache() {
        lock.lock()
        failures.removeAll()
        lock.unlock()
        memory.removeAllObjects()
    }

    func cachedThumbnail(for item: FileItem, serverID: UUID) -> UIImage? {
        memory.object(forKey: Self.key(for: item, serverID: serverID) as NSString)
    }

    /// 取缩略图。返回 nil 表示「没有 / 暂时失败」，界面应显示占位图标，不要一直转圈。
    /// - Parameter order: 该文件在目录里的显示序号，用来让缩略图按「左上 → 右下」的顺序出现。
    func thumbnail(for item: FileItem, serverID: UUID, connection: SMBConnection, order: Int = 0) async -> UIImage? {
        guard item.isMedia else { return nil }

        let key = Self.key(for: item, serverID: serverID)
        if let image = memory.object(forKey: key as NSString) { return image }

        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: SettingsKey.thumbnailsEnabled) as? Bool ?? true
        guard enabled else { return nil }
        if item.kind == .video {
            let videos = defaults.object(forKey: SettingsKey.videoThumbnails) as? Bool ?? true
            if !videos { return nil }
        }

        if isCoolingDown(key: key) { return nil }

        let job = makeJob(key: key, item: item, serverID: serverID, connection: connection, order: order)
        let waiter = Waiter()
        let result = await withTaskCancellationHandler {
            await job.task.value
        } onCancel: {
            // 视图被划走 / 页面退出：没有人再等这张图了，直接掐断传输
            if waiter.finishOnce() {
                ThumbnailStore.shared.detach(key: key, job: job)
            }
        }
        if waiter.finishOnce() {
            detach(key: key, job: job)
        }
        if let result {
            memory.setObject(result, forKey: key as NSString, cost: Self.cost(of: result))
        }
        return result
    }

    /// 清掉某个目录下所有缩略图的负缓存，用户手动刷新时调用
    func resetFailures() {
        lock.lock()
        failures.removeAll()
        lock.unlock()
    }

    // MARK: - 任务管理

    private func makeJob(key: String, item: FileItem, serverID: UUID, connection: SMBConnection, order: Int) -> Job {
        lock.lock()
        if let existing = jobs[key] {
            existing.waiters += 1
            lock.unlock()
            return existing
        }

        let box = CancellationBox()
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.produce(
                key: key, item: item, serverID: serverID, connection: connection, order: order, cancel: box
            )
        }
        let job = Job(task: task, box: box)
        job.waiters = 1
        jobs[key] = job
        lock.unlock()
        return job
    }

    private func detach(key: String, job: Job) {
        lock.lock()
        job.waiters -= 1
        let empty = job.waiters <= 0
        if empty, jobs[key] === job {
            jobs[key] = nil
        }
        lock.unlock()
        if empty {
            job.box.cancel()
        }
    }

    private func isCoolingDown(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let at = failures[key] else { return false }
        if Date().timeIntervalSince(at) < Self.failureTTL { return true }
        failures[key] = nil
        return false
    }

    private func markFailure(key: String) {
        lock.lock()
        failures[key] = Date()
        lock.unlock()
    }

    // MARK: - 生产

    private func produce(
        key: String,
        item: FileItem,
        serverID: UUID,
        connection: SMBConnection,
        order: Int,
        cancel: CancellationBox
    ) async -> UIImage? {
        let cache = CacheManager.shared
        let url = cache.thumbnailURL(serverID: serverID, item: item)

        // 磁盘缓存命中：不产生任何网络流量
        if let data = try? Data(contentsOf: url), let cached = UIImage(data: data) {
            return cached
        }
        if cancel.isCancelled { return nil }

        var image: UIImage?
        switch item.kind {
        case .image, .video:
            // 图片和视频共用一道闸门：一次只跑一个、按格子序号放行，
            // 缩略图才会严格按「左上 → 右下」依次出现
            await displayLimiter.acquire(order: order)
            if cancel.isCancelled {
                await displayLimiter.release()
                return nil
            }
            if item.kind == .image {
                image = await imageThumbnail(item: item, connection: connection, cancel: cancel)
            } else {
                image = await videoThumbnail(item: item, connection: connection, cancel: cancel)
            }
            await displayLimiter.release()
        case .folder, .other:
            return nil
        }

        // 被取消就不落盘、也不记失败，下次出现时还能重来
        if cancel.isCancelled { return nil }

        if let image, let data = image.jpegData(compressionQuality: 0.72) {
            try? data.write(to: url, options: .atomic)
            cache.noteWrite(bytes: Int64(data.count))
        } else {
            markFailure(key: key)
        }
        return image
    }

    // MARK: - 图片

    /// 图片缩略图：整份读回来再解码。
    ///
    /// 这里刻意不做「先读 8MB 试试能不能解开」的分阶段优化——1.0.5 之前就是这么干的，
    /// 结果 16MB 以上的 JPEG 在读到 8MB 时 ImageIO 直接返回一张「上半张有内容、下半张灰」的图，
    /// 而 `CGImageSourceCreateThumbnailAtIndex` 认为成功、我们就把这张残图写进了缓存。
    /// JPEG 的结束标记 EOI 在文件末尾，除了读满没有别的办法确认完整，所以只能整份读。
    private func imageThumbnail(item: FileItem, connection: SMBConnection, cancel: CancellationBox) async -> UIImage? {
        var size = item.size
        if size <= 0 {
            size = (try? await connection.fileSize(item.path)) ?? 0
        }
        guard size > 0, size <= Self.imageHardLimit else { return nil }

        let total = Int(size)
        var data = Data()
        // 只预留在 16MB 以内，避免一张几十兆的图一上来就吃掉大块内存
        data.reserveCapacity(min(total, 16 * 1024 * 1024))
        var offset: Int64 = 0

        while data.count < total {
            if cancel.isCancelled { return nil }
            let want = min(Self.imageReadChunk, total - data.count)
            let chunk: Data
            do {
                chunk = try await connection.read(item.path, offset: offset, length: want, cancel: cancel)
            } catch is CancellationError {
                return nil
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            data.append(chunk)
            offset += Int64(chunk.count)
        }

        // 没读满就是残缺数据：宁可显示占位图标，也不要糊一张半截图上去
        guard data.count >= total else {
            ThumbnailDiagnostics.record(item.name, "图片只读到 \(data.count)/\(total) 字节")
            return nil
        }
        return ImageDownsampler.downsample(data: data, maxPixel: Self.pixelSize)
    }

    // MARK: - 视频

    private func videoThumbnail(item: FileItem, connection: SMBConnection, cancel: CancellationBox) async -> UIImage? {
        // AVFoundation 解不了的容器就别浪费流量了（这些格式本身也播不了）
        if Self.undecodableVideoExtensions.contains(item.fileExtension) { return nil }

        var size = item.size
        if size <= 0 {
            size = (try? await connection.fileSize(item.path)) ?? 0
        }
        guard size > 0 else { return nil }

        // 一律先走「迷你镜像」：只读文件头（12 MB 起，不够再逐级加到 24 / 40 MB）+ moov，
        // 跟文件总大小无关，也不会被 AVFoundation「一直读到文件尾」的请求拖住（大文件封面失败的根因）。
        if let mirrored = await VideoThumbnailMirror.makeImage(
            connection: connection,
            path: item.path,
            fileSize: size,
            fileExtension: item.fileExtension,
            cancel: cancel
        ) {
            return mirrored
        }
        if cancel.isCancelled { return nil }

        // 兜底：流式抽帧（镜像失败时，比如封装里找不到 moov）
        return await streamingVideoThumbnail(
            item: item, connection: connection, size: size, cancel: cancel
        )
    }

    /// 原始做法：让 AVFoundation 通过自定义 scheme 边读边解析
    private func streamingVideoThumbnail(
        item: FileItem,
        connection: SMBConnection,
        size: Int64,
        cancel: CancellationBox
    ) async -> UIImage? {
        let budget = ByteBudget(limit: Self.videoByteBudget)
        let asset = MediaAssetFactory.shared.makeAsset(
            connection: connection,
            path: item.path,
            fileSize: size,
            fileExtension: item.fileExtension,
            budget: budget,
            cancel: cancel
        )
        defer { MediaAssetFactory.shared.release(asset) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        // 允许取最近的关键帧，这样只需读 moov 和一小段样本数据
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let candidates: [CMTime] = [
            CMTime(seconds: 1, preferredTimescale: 600),
            .zero,
            CMTime(seconds: 5, preferredTimescale: 600)
        ]
        var lastError = ""
        for time in candidates {
            if cancel.isCancelled { return nil }
            do {
                let result = try await generator.image(at: time)
                return UIImage(cgImage: result.image)
            } catch {
                let code = (error as NSError).code
                lastError = code == 0 ? error.localizedDescription : "\(error.localizedDescription)(\(code))"
            }
            if cancel.isCancelled || budget.remaining() <= 0 { return nil }
        }
        if !lastError.isEmpty {
            ThumbnailDiagnostics.record(item.name, "流式抽帧也失败：\(lastError)")
        }
        return nil
    }

    // MARK: - 辅助

    private static func key(for item: FileItem, serverID: UUID) -> String {
        "\(serverID.uuidString)|\(item.path)|\(item.size)|\(item.modified?.timeIntervalSince1970 ?? 0)"
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
