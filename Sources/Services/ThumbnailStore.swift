import UIKit
import AVFoundation

/// 缩略图调度：内存缓存 → 磁盘缓存 → 远端读取（限并发、限流量、可取消）
///
/// 设计要点：
/// 1. 同一个文件只生成一份 480px 缩略图，网格和列表共用，避免同一张图取两次。
/// 2. 图片和视频共用一道有序闸门（一次一个，先比优先级层再比格子序号放行）：
///    前台（屏幕上的格子）严格按「左上 → 右下」依次出现；目录级后台预载（`isPrefetch`）
///    排在所有前台之后，负责把整个文件夹的缩略图都加载完。
///    优先级是**活值**（`PriorityBox`）：预载抢先建的任务一旦被前台格子 join，
///    闸门立刻按前台对待，不会出现「第一个文件反而最后出来」。
/// 3. 每次读取都有字节上限，取消时通过 `CancellationBox` 立刻中止传输。
/// 4. 失败的文件进负缓存冷却几分钟，避免「划回去就重试」把 NAS 打满。
final class ThumbnailStore: @unchecked Sendable {
    static let shared = ThumbnailStore()

    /// 统一缩略图长边像素（网格最宽 160pt × 3 倍屏 = 480）
    private static let pixelSize = 480
    /// 图片必须整份读到才解码：JPEG / PNG 被截断时 ImageIO 不会返回 nil，
    /// 而是给出一张「上半张正常、下半张灰」的假图（缩略图加载不全的根因）。
    /// 所以这里不再按大小分阶段试探，一律读满；超过上限的直接放弃。
    /// 上限放到 160 MB：BMP 动辄几十兆（手机截图/无损导出很常见），64 MB 会把它们全挡在外面。
    private static let imageHardLimit: Int64 = 160 * 1024 * 1024
    /// 超过这个大小就不再整份塞进内存，改成边读边落临时文件，让 ImageIO 从文件里取
    private static let imageMemoryLimit: Int64 = 24 * 1024 * 1024
    /// 分块读取大小（单次 SMB 读请求上限）
    private static let imageReadChunk: Int = 8 * 1024 * 1024
    /// 失败冷却时间
    private static let failureTTL: TimeInterval = 180
    /// AVFoundation 无法解码的容器，直接不做封面，避免白读十几兆
    private static let undecodableVideoExtensions: Set<String> = [
        "mkv", "avi", "wmv", "flv", "rmvb", "rm", "webm", "vob"
    ]

    private final class Job: @unchecked Sendable {
        let task: Task<UIImage?, Never>
        let box: CancellationBox
        /// 闸门优先级（0 前台 / 1 后台）的共享盒：任务被谁创建就先按谁的层级起步，
        /// 但**排队期间可被实时提级** —— 后台预载抢先创建的任务，一旦有前台格子
        /// join 进来，闸门选拔时就会按前台处理（修「第一个文件总是最后加载出来」）。
        let priority: PriorityBox
        var waiters: Int = 0

        init(task: Task<UIImage?, Never>, box: CancellationBox, priority: PriorityBox) {
            self.task = task
            self.box = box
            self.priority = priority
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
    /// 空闲后的新一批先聚集 250 ms 再挑最小序号，避免「后出现的格子抢到第一个名额」。
    private let displayLimiter = OrderedLimiter(limit: 1, settleMilliseconds: 250)

    init() {
        memory.countLimit = 400
        memory.totalCostLimit = 40 * 1024 * 1024
    }

    /// 进后台时调用：把还在排队的缩略图任务全部取消。
    ///
    /// 挂后台时列表里可能还有一堆缩略图在陆续读 SMB，每张都要经过「读 → 解码」，
    /// 峰值叠在后台那点内存额度上，很容易被系统回收掉进程。
    func cancelAllInflight() {
        lock.lock()
        let running = Array(jobs.values)
        jobs.removeAll()
        lock.unlock()
        for job in running { job.box.cancel() }
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
    /// - Parameter isPrefetch: 目录级后台预载走这条通道 —— 闸门里排在所有前台格子之后，
    ///   屏幕上的格子永远优先；内存/磁盘已缓存的照常快速跳过。
    func thumbnail(
        for item: FileItem,
        serverID: UUID,
        connection: SMBConnection,
        order: Int = 0,
        isPrefetch: Bool = false
    ) async -> UIImage? {
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

        let job = makeJob(key: key, item: item, serverID: serverID, connection: connection, order: order, isPrefetch: isPrefetch)
        // 前台格子 join 了预载抢先创建的任务：把闸门优先级实时提回前台，
        // 否则这个文件会排在整屏前台格子后面（预载循环从第 0 个开始，
        // 总是抢在格子的 .task 之前建任务 —— 第一个文件必然中招）
        if !isPrefetch {
            job.priority.promote(to: 0)
        }
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

    private func makeJob(key: String, item: FileItem, serverID: UUID, connection: SMBConnection, order: Int, isPrefetch: Bool = false) -> Job {
        lock.lock()
        if let existing = jobs[key] {
            existing.waiters += 1
            lock.unlock()
            return existing
        }

        let box = CancellationBox()
        let priority = PriorityBox(isPrefetch ? 1 : 0)
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.produce(
                key: key, item: item, serverID: serverID, connection: connection,
                order: order, priority: priority, cancel: box
            )
        }
        let job = Job(task: task, box: box, priority: priority)
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
        priority: PriorityBox,
        cancel: CancellationBox
    ) async -> UIImage? {
        let cache = CacheManager.shared
        let url = cache.thumbnailURL(serverID: serverID, item: item)

        // 磁盘缓存命中：不产生任何网络流量。
        // 用 ImageIO 从文件解（和别处一致）：`UIImage(data:)` 是懒解码，
        // 位图会拖到主线程第一次绘制时才解出来，压缩数据也一直在内存里挂着。
        if let cached = ImageDownsampler.downsample(url: url, maxPixel: Self.pixelSize) {
            return cached
        }
        if cancel.isCancelled { return nil }

        var image: UIImage?
        switch item.kind {
        case .image, .video:
            // 图片和视频共用一道闸门：一次只跑一个、按「优先级层 + 格子序号」放行 ——
            // 优先级是共享盒的活值：预载任务排队期间被前台格子 join，
            // 这里读到的就是前台层，随时插到整屏前台队列的正确位置
            await displayLimiter.acquire(order: order, priority: priority)
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

    /// 图片缩略图。
    ///
    /// 这里刻意不做「先读 8MB 试试能不能解开」的分阶段优化 —— 1.0.5 之前就是这么干的，
    /// 结果 16MB 以上的 JPEG 在读到 8MB 时 ImageIO 直接返回一张「上半张有内容、下半张灰」的图，
    /// 而 `CGImageSourceCreateThumbnailAtIndex` 认为成功、我们就把这张残图写进了缓存。
    ///
    /// 1.0.13 起大图（> 24 MB）改为边读边落临时文件、让 ImageIO 从文件里取：
    /// BMP 这类格式动辄几十兆，同时压着 Data + 解码位图很容易被系统回收。
    private func imageThumbnail(item: FileItem, connection: SMBConnection, cancel: CancellationBox) async -> UIImage? {
        var size = item.size
        if size <= 0 {
            size = (try? await connection.fileSize(item.path)) ?? 0
        }
        guard size > 0 else {
            ThumbnailDiagnostics.record(item.name, "拿不到文件大小")
            return nil
        }
        guard size <= Self.imageHardLimit else {
            ThumbnailDiagnostics.record(
                item.name,
                "图片 \(size / 1024 / 1024)MB 超出上限 \(Self.imageHardLimit / 1024 / 1024)MB"
            )
            return nil
        }

        if size > Self.imageMemoryLimit {
            return await largeImageThumbnail(
                item: item, size: size, connection: connection, cancel: cancel
            )
        }

        let total = Int(size)
        var data = Data()
        // 只预留在 16MB 以内，避免一张大图一上来就吃掉大块内存
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
                ThumbnailDiagnostics.record(item.name, "读取失败：\(error.localizedDescription)")
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
        guard let image = ImageDownsampler.downsample(data: data, maxPixel: Self.pixelSize) else {
            ThumbnailDiagnostics.record(item.name, "解码失败（\(item.fileExtension) \(size / 1024 / 1024)MB）")
            return nil
        }
        return image
    }

    /// 大图：边读边写临时文件，再让 ImageIO 从文件里解码出缩略图。
    /// 好处是内存里不会同时存在「几十兆的 Data」和「几十兆的解码位图」。
    private func largeImageThumbnail(
        item: FileItem,
        size: Int64,
        connection: SMBConnection,
        cancel: CancellationBox
    ) async -> UIImage? {
        let ext = item.fileExtension.isEmpty ? "img" : item.fileExtension
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smbimg-\(UUID().uuidString).\(ext)")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            ThumbnailDiagnostics.record(item.name, "建不了临时文件")
            return nil
        }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }

        var written: Int64 = 0
        do {
            while written < size {
                if cancel.isCancelled { return nil }
                let want = Int(min(Int64(Self.imageReadChunk), size - written))
                let chunk = try await connection.read(
                    item.path, offset: written, length: want, cancel: cancel
                )
                if chunk.isEmpty { break }
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
            }
        } catch is CancellationError {
            return nil
        } catch {
            ThumbnailDiagnostics.record(item.name, "读取失败：\(error.localizedDescription)")
            return nil
        }

        guard written >= size else {
            ThumbnailDiagnostics.record(
                item.name, "图片只读到 \(written / 1024 / 1024)MB/\(size / 1024 / 1024)MB"
            )
            return nil
        }
        try? handle.synchronize()
        guard let image = ImageDownsampler.downsample(url: url, maxPixel: Self.pixelSize) else {
            ThumbnailDiagnostics.record(
                item.name, "解码失败（\(ext) \(size / 1024 / 1024)MB）"
            )
            return nil
        }
        return image
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

        // ① 小文件：整份读进来做「镜像」，等于一个不截断的本地文件，最稳
        if size <= VideoThumbnailMirror.wholeFileLimit {
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
        }

        // ② 大文件：镜像必然截断 mdat，样本偏移越界就报 -11821（和首帧在不在镜像里无关），
        //    所以直接对流式资产做顺序解码：只读 moov + 第一个 GOP，没有截断
        return await VideoThumbnailStream.makeImage(
            connection: connection,
            path: item.path,
            fileSize: size,
            fileExtension: item.fileExtension,
            cancel: cancel
        )
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
