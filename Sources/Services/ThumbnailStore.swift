import UIKit
import AVFoundation

/// 缩略图调度：内存缓存 → 磁盘缓存 → 远端读取（限并发、限流量、可取消）
///
/// 设计要点：
/// 1. 同一个文件只生成一份 480px 缩略图，网格和列表共用，避免同一张图取两次。
/// 2. 图片和视频共用一道有序闸门（**同时 3 个**，先比优先级层再比格子序号放行）：
///    前台（屏幕上的格子）**开始跑**的顺序严格按「左上 → 右下」；目录级后台预载（`isPrefetch`）
///    排在所有前台之后，负责把整个文件夹的缩略图都加载完。
///    优先级是**活值**（`PriorityBox`）：预载抢先建的任务一旦被前台格子 join，
///    闸门立刻按前台对待，不会出现「第一个文件反而最后出来」。
///    并发 3 必须配 `SMBConnection` 的 3 条缩略图会话才有效果 —— 见那里。
/// 3. 每次读取都有字节上限，取消时通过 `CancellationBox` 立刻中止传输；
///    单张还有 15 s 时间预算，到点让位，避免一个卡住的请求堵死整屏。
/// 4. 失败的文件进负缓存冷却 45 s，避免「划回去就重试」把 NAS 打满。
/// 5. 并发 3 之后「放行」有序但「完成」无序 —— 三个名额同时在飞，谁先读完谁先上屏。
///    所以真图上屏前还要过一道按序发布层（`PublishOrder`）：等所有更小序号的任务
///    都结束才返回。读提速、观感仍是「左上 → 右下」逐张出。
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
    private static let imageReadChunk: Int = 4 * 1024 * 1024
    /// 照片快路径：只读头部这么多字节，够把 EXIF APP1（最大 64 KB）连内嵌缩略图一起拿到
    private static let quickPathHeaderBytes = 256 * 1024
    /// 照片快路径只对 jpg/jpeg 生效（只有它们带 EXIF 内嵌缩略图）
    private static let quickPathExtensions: Set<String> = ["jpg", "jpeg"]
    /// 小于这个体积的图整份读更快，不值得多一次「读头部 → 失败回退」的判断
    private static let quickPathMinSize: Int64 = 3 * 1024 * 1024
    /// 单张缩略图的总时间预算。超时就掐断并记一次失败，把并发名额让给后面的 ——
    /// 否则一个卡住的请求会把整屏缩略图堵死（Android 端踩过：300 MB 视频把队列占十几分钟）
    private static let jobBudgetNanos: UInt64 = 15 * 1_000_000_000
    /// 失败冷却时间。原来 180 s 太长：一次网络抖动换来三分钟的图标，用户得重进目录才有机会重来；
    /// 45 s 足够躲开「正在被播放 / 正在被镜像」这类瞬时状态。
    private static let failureTTL: TimeInterval = 45
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

    /// 按序发布协调器：并发读的结果按「格子序号」依次放行上屏。
    ///
    /// 闸门并发 3 之后，「放行」有序但「完成」无序 —— 三个名额同时在飞，谁先读完
    /// 谁先上屏，第 2、3 张的小图会抢在第 1 张的大视频前面（用户实测：「缩略图
    /// 又不是按顺序放出来了」）。把「读」与「出」拆开：读保持 3 并发（提速不动），
    /// 出图在这里排队 —— 任务创建时 `begin` 登记序号；真图到手后 `waitTurn`，
    /// 只要还有**更小序号**的任务没跑完就挂着，直到它们 `end`。
    ///
    /// - 失败 / 取消的返回占位图标，占位长得都一样、没有排序意义，不在这里等；
    ///   但它们的 `end` 照样登记 —— 否则后面的序号被永久压住。
    /// - `end` 由 `produce` 的 `defer` 无条件执行（成功 / 失败 / 超时 / 取消都到），
    ///   所以等待最坏压住一个单张预算（15 s），不存在死锁。
    /// - 用「活跃集合」而不是「推进计数（nextToRelease++）」：重进目录 / 刷新时
    ///   序号重新从 0 开始，上一代留下的推进值会把新一代任务全部误判成「已轮到」、
    ///   直接放行又乱序；活跃集合只看「前面还有没有人没跑完」，换代天然自洽。
    private final class PublishOrder: @unchecked Sendable {
        static let shared = PublishOrder()

        private let lock = NSLock()
        /// 目录键 -> 仍在跑（未 end）的格子序号
        private var active: [String: Set<Int>] = [:]
        /// 目录键 -> 序号 -> 等待放行的续体
        private var waiters: [String: [Int: [CheckedContinuation<Void, Never>]]] = [:]

        /// 同一台服务器下按目录分组：不同目录的序号互相独立，
        /// A 目录卡住的任务不许压住 B 目录刚点开的格子
        private static func dirKey(serverID: UUID, path: String) -> String {
            var dir = path
            if let slash = dir.lastIndex(of: "/") { dir = String(dir[..<slash]) }
            return serverID.uuidString + "|" + dir
        }

        func begin(serverID: UUID, path: String, order: Int) {
            let dir = Self.dirKey(serverID: serverID, path: path)
            lock.lock()
            active[dir, default: []].insert(order)
            lock.unlock()
        }

        func end(serverID: UUID, path: String, order: Int) {
            let dir = Self.dirKey(serverID: serverID, path: path)
            lock.lock()
            active[dir]?.remove(order)
            if active[dir]?.isEmpty == true { active[dir] = nil }
            // 找出刚获得放行资格的等待者：它前面再没有活跃序号了
            var ready: [CheckedContinuation<Void, Never>] = []
            if let running = active[dir] {
                if var perOrder = waiters[dir] {
                    for (waitingOrder, continuations) in perOrder
                    where running.allSatisfy({ $0 >= waitingOrder }) {
                        perOrder[waitingOrder] = nil
                        ready.append(contentsOf: continuations)
                    }
                    waiters[dir] = perOrder.isEmpty ? nil : perOrder
                }
            } else if let perOrder = waiters.removeValue(forKey: dir) {
                for continuations in perOrder.values { ready.append(contentsOf: continuations) }
            }
            lock.unlock()
            for continuation in ready { continuation.resume() }
        }

        /// 等所有更小序号的任务结束。已轮到就立即返回；
        /// 等待期间任务被取消也放行（调用方检查取消标记自行返回）。
        func waitTurn(serverID: UUID, path: String, order: Int) async {
            let dir = Self.dirKey(serverID: serverID, path: path)

            lock.lock()
            let running = active[dir]
            if running == nil || running!.allSatisfy({ $0 >= order }) {
                lock.unlock()
                return
            }
            lock.unlock()

            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    // 双检：快速路径判断和真正挂起之间，前面的任务可能刚好全部 end
                    let running = active[dir]
                    if running == nil || running!.allSatisfy({ $0 >= order }) {
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    waiters[dir, default: [:]][order, default: []].append(continuation)
                    lock.unlock()
                }
            } onCancel: {
                withdraw(dir: dir, order: order)
            }
        }

        /// 取消时从等待队列摘除自己的续体。摘到才 resume —— `end` 那边摘不到就
        /// 不会再 resume，两边靠「同一把锁下的字典移除只有一方成功」保证不双 resume。
        private func withdraw(dir: String, order: Int) {
            lock.lock()
            var continuation: CheckedContinuation<Void, Never>?
            if var perOrder = waiters[dir], var list = perOrder[order] {
                continuation = list.popLast()
                if list.isEmpty { perOrder[order] = nil } else { perOrder[order] = list }
                if perOrder.isEmpty { waiters[dir] = nil } else { waiters[dir] = perOrder }
            }
            lock.unlock()
            continuation?.resume()
        }
    }

    /// 单张缩略图是否被 `jobBudget` 掐断过。掐断和「用户取消」要区分对待：
    /// 后者不记失败（下次出现还要重来），前者要进冷却（这文件确实难搞）。
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false

        /// 返回 true 表示是它第一次触发（避免重复 cancel）
        func mark() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }

        var isFired: Bool {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }
    }

    private let memory = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var failures: [String: Date] = [:]

    /// 缩略图读端的闸门：图片和视频共用，**一次跑 3 个**、按格子序号放行。
    ///
    /// 并发 1 → 3 是这轮的主要提速点：单个小文件的耗时几乎全是 SMB 往返延迟，
    /// 三个同时在飞，等于把「几十张串行」变成「三张三张地读」。
    /// 注意它只保证**开始**的顺序，不保证**完成**的顺序 —— 完成序由 `PublishOrder`
    /// 兜住（见下）。1.4.10 只加了并发、没加发布层，用户实测「缩略图不按顺序出了」。
    ///
    /// 并发数必须和 `SMBConnection` 的缩略图会话数一致（3 条独立 socket）——
    /// 只加并发不加会话，三条请求还是挤在一条 TCP 上排队，等于没加。
    private let displayLimiter = OrderedLimiter(limit: 3, settleMilliseconds: 250)

    init() {
        memory.countLimit = 600
        // 64 MB：一个 480px 的格子约 0.4~0.9 MB，够压住两三个满屏目录，
        // 滑动回去时不用再读网络（原来是 40 MB，翻几屏就被挤掉了）
        memory.totalCostLimit = 64 * 1024 * 1024
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
        // 按序发布层登记序号（只登记一次 —— join 进来的等待者用的是同一个 job）
        PublishOrder.shared.begin(serverID: serverID, path: item.path, order: order)
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.produce(
                key: key, item: item, serverID: serverID, connection: connection,
                order: order, priority: priority, isPrefetch: isPrefetch, cancel: box
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
        isPrefetch: Bool,
        cancel: CancellationBox
    ) async -> UIImage? {
        // 结束登记必须无条件发生：按序发布层靠「更小序号都结束了」放行，
        // 漏一次 end 就把后面的序号永久压住
        defer { PublishOrder.shared.end(serverID: serverID, path: item.path, order: order) }

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
            // 图片和视频共用一道闸门：最多三个同时在跑、按「优先级层 + 格子序号」放行 ——
            // 优先级是共享盒的活值：预载任务排队期间被前台格子 join，
            // 这里读到的就是前台层，随时插到整屏前台队列的正确位置
            await displayLimiter.acquire(order: order, priority: priority)
            if cancel.isCancelled {
                await displayLimiter.release()
                return nil
            }

            // 单张时间预算：到点就掐断传输（读在块边界干净退出），把名额让出去。
            // 不这么做的话，一个卡在 NAS 那边的大文件会把三个名额之一永久占住。
            let timeout = TimeoutFlag()
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: Self.jobBudgetNanos)
                guard !Task.isCancelled else { return }
                if timeout.mark() { cancel.cancel() }
            }
            if item.kind == .image {
                image = await imageThumbnail(item: item, connection: connection, cancel: cancel)
            } else {
                image = await videoThumbnail(item: item, connection: connection, cancel: cancel)
            }
            watchdog.cancel()
            await displayLimiter.release()
            // 超时跟「用户取消」不是一回事：要记一次失败进冷却，别让它在滚动时反复重试
            if timeout.isFired { markFailure(key: key) }
        case .folder, .other:
            return nil
        }

        // 被取消就不落盘、也不记失败，下次出现时还能重来
        if cancel.isCancelled { return nil }

        // 绿帧绝不进缓存：一旦落盘就永久化了（Android 端为此每张封面都是绿的）
        if item.kind == .video, let frame = image, ImageValidator.isMostlyGreen(frame) {
            ThumbnailDiagnostics.record(item.name, "取到纯绿帧，不缓存")
            markFailure(key: key)
            return nil
        }

        if let image, let data = image.jpegData(compressionQuality: 0.72) {
            try? data.write(to: url, options: .atomic)
            cache.noteWrite(bytes: Int64(data.count))
        } else {
            markFailure(key: key)
        }

        // 按序发布：读是 3 并发、完成顺序不可控，真图要等更小序号的任务都出完再返回。
        // 失败 / 取消返回的占位图标长得都一样，没有排序意义，不在这里等；
        // 预载任务（isPrefetch）同样不等 —— 它们的结果进缓存，不直接上屏。
        if let image, !isPrefetch, !cancel.isCancelled {
            await PublishOrder.shared.waitTurn(serverID: serverID, path: item.path, order: order)
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

        // ① 照片快路径：只读头部 256 KB，取 EXIF 里那张内嵌缩略图。
        //    手机拍的照片基本都带一张 320~480 的预览图 —— 一张 8 MB 的照片
        //    不必把整份拉下来，这一条把「照片目录」的首屏从几十次往返压到一次。
        //    解不出来（或太小）就返回 nil，继续走下面的整份读，绝不让「省流量」变成「没图」。
        if let quick = await embeddedThumbnail(
            item: item, size: size, connection: connection, cancel: cancel
        ) {
            return quick
        }
        if cancel.isCancelled { return nil }

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
                chunk = try await connection.thumbRead(item.path, offset: offset, length: want, cancel: cancel)
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

    /// 照片快路径：读头部 256 KB，从 EXIF 里取内嵌缩略图。
    ///
    /// 只在「jpg/jpeg + ≥ 3 MB」时尝试：小图整份读本来就比一次判断更快，
    /// 而且不带 EXIF 的图（截图、导出图）多读一次头纯属浪费。
    /// 任何失败都返回 `nil` 让调用方回退，**不在这里记失败** —— 快路径失败不代表这张图没救。
    private func embeddedThumbnail(
        item: FileItem,
        size: Int64,
        connection: SMBConnection,
        cancel: CancellationBox
    ) async -> UIImage? {
        guard Self.quickPathExtensions.contains(item.fileExtension),
              size >= Self.quickPathMinSize else { return nil }

        let want = Int(min(size, Int64(Self.quickPathHeaderBytes)))
        guard want > 0 else { return nil }

        do {
            let header = try await connection.thumbRead(
                item.path, offset: 0, length: want, cancel: cancel
            )
            guard !header.isEmpty, !cancel.isCancelled else { return nil }
            return JPEGEmbeddedThumbnail.image(fromHeader: header, maxPixel: Self.pixelSize)
        } catch {
            return nil
        }
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
                let chunk = try await connection.thumbRead(
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
