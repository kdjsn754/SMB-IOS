import UIKit
import AVFoundation

/// 缩略图调度：内存缓存 → 磁盘缓存 → 远端读取（限并发、限流量、可取消）
///
/// 设计要点：
/// 1. 同一个文件只生成一份 480px 缩略图，网格和列表共用，避免同一张图取两次。
/// 2. 图片和视频走各自的并发闸门（图片 3、视频 1），视频封面再慢也不会把图片挤死。
/// 3. 每次读取都有字节上限，取消时通过 `CancellationBox` 立刻中止传输。
/// 4. 失败的文件进负缓存冷却几分钟，避免「划回去就重试」把 NAS 打满。
final class ThumbnailStore: @unchecked Sendable {
    static let shared = ThumbnailStore()

    /// 统一缩略图长边像素（网格最宽 160pt × 3 倍屏 = 480）
    private static let pixelSize = 480
    /// 图片一次读完的上限，超过这个大小才分阶段读
    private static let imageReadLimit: Int64 = 16 * 1024 * 1024
    /// 视频封面允许消耗的字节额度。1GB 以上的 MP4，`moov` 索引本身就可能十几兆，
    /// 额度给小了会导致索引读不全、直接解析失败（大文件缩略图出不来的根因）
    private static let videoByteBudget: Int64 = 32 * 1024 * 1024
    /// 必须完整读取才能正确解码的图片格式（无压缩 / 分块存储）。
    /// 这类文件被截断后 ImageIO 不会返回 nil，而是给出一张「主体全黑」的图，正好对上 BMP 全黑的现象。
    private static let fullReadImageExtensions: Set<String> = ["bmp", "dib", "tif", "tiff"]
    /// 完整读取类图片的大小上限，超过就放弃（不至于为了一张图传几百兆）
    private static let fullImageReadLimit: Int64 = 64 * 1024 * 1024
    /// 完整读取时的分块大小
    private static let fullReadChunk: Int = 8 * 1024 * 1024
    /// 视频封面允许消耗的字节额度
    private static let videoByteBudget: Int64 = 10 * 1024 * 1024
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

    private let imageLimiter = AsyncLimiter(limit: 3)
    private let videoLimiter = AsyncLimiter(limit: 1)

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
    func thumbnail(for item: FileItem, serverID: UUID, connection: SMBConnection) async -> UIImage? {
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

        let job = makeJob(key: key, item: item, serverID: serverID, connection: connection)
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

    private func makeJob(key: String, item: FileItem, serverID: UUID, connection: SMBConnection) -> Job {
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
                key: key, item: item, serverID: serverID, connection: connection, cancel: box
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
        case .image:
            await imageLimiter.acquire()
            image = await imageThumbnail(item: item, connection: connection, cancel: cancel)
            await imageLimiter.release()
        case .video:
            await videoLimiter.acquire()
            image = await videoThumbnail(item: item, connection: connection, cancel: cancel)
            await videoLimiter.release()
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

    private func imageThumbnail(item: FileItem, connection: SMBConnection, cancel: CancellationBox) async -> UIImage? {
        // BMP / TIFF 必须整份拿到才能解码，走独立路径
        if Self.fullReadImageExtensions.contains(item.fileExtension) {
            return await fullReadImageThumbnail(item: item, connection: connection, cancel: cancel)
        }

        for step in Self.readPlan(for: item.size) {
            if cancel.isCancelled { return nil }
            // 传输被取消会抛 CancellationError，这里当成「没取到」，不要污染失败缓存
            let data: Data
            do {
                data = try await connection.read(item.path, offset: 0, length: step, cancel: cancel)
            } catch is CancellationError {
                return nil
            } catch {
                return nil
            }
            if data.isEmpty { return nil }
            if let image = ImageDownsampler.downsample(data: data, maxPixel: Self.pixelSize) {
                return image
            }
        }
        return nil
    }

    /// 分阶段读取计划：小图一次读完；超大图先读头部，解码不出来再放宽。
    private static func readPlan(for size: Int64) -> [Int] {
        let limit = imageReadLimit
        if size > 0, size <= limit {
            return [Int(size)]
        }
        if size > limit {
            return [8 * 1024 * 1024, Int(limit)]
        }
        // 目录列表没给大小，只能试探
        return [1024 * 1024, 4 * 1024 * 1024, Int(limit)]
    }

    /// BMP / TIFF 专用：分块读完整份文件再解码。
    /// 目录列表没给大小时先问一次服务器，避免用 1MB 去试而解出一张全黑的图。
    private func fullReadImageThumbnail(
        item: FileItem,
        connection: SMBConnection,
        cancel: CancellationBox
    ) async -> UIImage? {
        var size = item.size
        if size <= 0 {
            size = (try? await connection.fileSize(item.path)) ?? 0
        }
        guard size > 0, size <= Self.fullImageReadLimit else { return nil }

        var data = Data()
        data.reserveCapacity(Int(size))
        var offset: Int64 = 0

        while offset < size {
            if cancel.isCancelled { return nil }
            let want = Int(min(Int64(Self.fullReadChunk), size - offset))
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

        guard !data.isEmpty else { return nil }
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
        for time in candidates {
            if cancel.isCancelled { return nil }
            if let result = try? await generator.image(at: time) {
                return UIImage(cgImage: result.image)
            }
            if cancel.isCancelled || budget.remaining() <= 0 { return nil }
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
