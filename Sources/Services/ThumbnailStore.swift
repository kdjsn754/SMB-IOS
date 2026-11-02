import UIKit
import AVFoundation
import Dispatch

/// 缩略图调度：内存缓存 → 磁盘缓存 → 远端读取（限并发、限流量、可取消）
///
/// 设计要点：
/// 1. 同一个文件只生成一份 480px 缩略图，网格和列表共用，避免同一张图取两次。
/// 2. **图片和视频分道**：
///    - 图片：3 并发 + 3 条专用 SMB 会话，一条一个；
///    - 视频封面：2 并发 + 2 条专用会话。视频要读 moov / 首个 GOP 再抽帧，又大又慢，
///      和照片挤一个闸门时一张封面就能把照片的并发吃掉一半（这是「比别人慢」的大头）。
///    - 两条车道内部都按优先级层 + 格子序号放行：0 前台图片 > 1 前台视频 >
///      2 预载图片 > 3 预载视频。优先级是**活值**（`PriorityBox`），预载抢先建的任务
///      一旦被前台格子 join，闸门立刻按前台对待，不会出现「第一个文件反而最后出来」。
/// 3. 每次读取都有字节上限，取消时通过 `CancellationBox` 立刻中止传输；
///    单张还有 15 s 时间预算，到点让位，避免一个卡住的请求堵死整屏。
/// 4. 失败的文件进负缓存冷却（图片 45 s / 视频 15 s），避免「划回去就重试」把 NAS 打满。
/// 5. 「读」可以无序完成，「上屏」**严格按格子序号**（`PublishOrder`）：序号更小的格子
///    没结束，这张就先等。只有「已经跑了 2.5 s 还没结束」的才不再挡路 ——
///    视频封面、卡住的读这类慢任务到点让位，正常照片一张 0.2~1 s 全部落在预算内，
///    所以常态就是「左上 → 右下」逐格被替换成真图（占位图标先站住，观感与系统相册一致）。
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
    /// 图片失败冷却。原来 180 s 太长：一次网络抖动换来三分钟的图标，用户得重进目录才有机会重来；
    /// 45 s 足够躲开「正在被占用」这类瞬时状态。
    private static let imageFailureTTL: TimeInterval = 45
    /// 视频封面失败冷却短一些：抽帧是重活，一次超时换来 45 s 的灰块太扎眼；
    /// 15 s 既能避开「瞬时卡顿」，用户重进目录时也基本能立刻重试。
    private static let videoFailureTTL: TimeInterval = 15
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
        /// 按序发布的登记凭据：预载建的 job 不登记序号，前台格子 join 时补登记。
        let publish: PublishTicket
        var waiters: Int = 0

        init(task: Task<UIImage?, Never>, box: CancellationBox, priority: PriorityBox, publish: PublishTicket) {
            self.task = task
            self.box = box
            self.priority = priority
            self.publish = publish
        }
    }

    /// 按序发布的登记凭据。
    ///
    /// 任务可能是预载先建的（`isPrefetch`，不登记序号），随后前台格子 join 进来 ——
    /// 这时必须补登记，否则最前面几格不在发布序列里，后面的图会直接越过它们上屏。
    /// 「登记了没有、登的是哪个序号」要跟着任务走：`end` 必须和 `begin` 用同一个序号配对。
    private final class PublishTicket: @unchecked Sendable {
        private let lock = NSLock()
        private var registeredOrder: Int?

        /// 首次登记返回 true —— 调用方负责执行 `PublishOrder.begin`
        func register(_ order: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard registeredOrder == nil else { return false }
            registeredOrder = order
            return true
        }

        var order: Int? {
            lock.lock()
            defer { lock.unlock() }
            return registeredOrder
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
    /// 「读」保持并发（图片 3 张同时在飞），「出」在这里排队：任务登记序号后，
    /// 拿到真图要等所有**更小序号**的任务结束才返回。
    ///
    /// 1.5.2 修掉两个致命缺陷：
    /// 1. **序号必须由前台补登记**。预载（`isPrefetch`）不登记序号，而它从第 0 个
    ///    开始、又总是抢在格子的 `.task` 之前建任务 —— 前几格的 job 大多是预载建的，
    ///    如果格子 join 时不补登记，这些序号压根不在活跃表里，`waitTurn` 看到「前面
    ///    没人」就直接放行，顺序保护对最前面几格完全失效。这就是「还是乱序」的根因。
    /// 2. **按阻塞者计时，而不是给等待者设全局上限**。旧版每个等待者最多等 0.7 s，
    ///    到点就放行 —— 而 0.7 s 对「还没读完的这张」来说根本不够，于是第 2、3 格的
    ///    快图集体超时抢先上屏，照样乱。现在只看**阻塞者自己跑了多久**：超过
    ///    `stallNanos` 还没结束的才不再挡路。正常照片一张 0.2~1 s 完成，全部落在
    ///    预算内 → 严格按序；真正慢的（视频封面 / 卡住的读）到点自动让位，不拖整屏。
    ///
    /// - 失败 / 取消的返回占位图标，占位长得都一样、没有排序意义，不在这里等；
    ///   但它们的 `end` 照样登记 —— 否则后面的序号被永久压住。
    /// - `end` 由 `produce` 的 `defer` 无条件执行（成功 / 失败 / 超时 / 取消都到），
    ///   所以等待最坏压住一个停滞预算，不存在死锁。
    /// - 用「活跃表」而不是「推进计数（nextToRelease++）」：重进目录 / 刷新时
    ///   序号重新从 0 开始，上一代留下的推进值会把新一代任务全部误判成「已轮到」、
    ///   直接放行又乱序；活跃表只看「前面还有没有人没跑完」，换代天然自洽。
    private final class PublishOrder: @unchecked Sendable {
        static let shared = PublishOrder()

        /// 一个格子最多挡后面的图多久。正常照片远小于它，所以常态就是严格按序；
        /// 视频封面（3~15 s）到点自动让位，不让整屏等一张封面。
        static let stallNanos: UInt64 = 2_500_000_000

        private let lock = NSLock()
        /// 目录键 -> 序号 -> 登记时间（uptime 纳秒）
        private var active: [String: [Int: UInt64]] = [:]
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
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            var perOrder = active[dir] ?? [:]
            // 同一个序号被重复登记（预载 + 格子 join）时保留最早的计时，不重置停滞预算；
            // 但上一代留下的残项（大于两个停滞预算还没清）要按新一代重新计时，
            // 否则重进目录时序号 0 的旧时间戳会把新任务直接判成「已停滞」、顺序保护失效。
            if let started = perOrder[order], now &- started <= stallNanos * 2 {
                // 同一代，保留原计时
            } else {
                perOrder[order] = now
            }
            active[dir] = perOrder
            lock.unlock()
        }

        func end(serverID: UUID, path: String, order: Int) {
            let dir = Self.dirKey(serverID: serverID, path: path)
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            if var perOrder = active[dir] {
                perOrder[order] = nil
                active[dir] = perOrder.isEmpty ? nil : perOrder
            }
            // 找出刚获得放行资格的等待者：它前面再没有「还在预算内」的序号了
            var ready: [CheckedContinuation<Void, Never>] = []
            let running = active[dir] ?? [:]
            if var perOrder = waiters[dir] {
                for (waitingOrder, continuations) in perOrder
                where Self.deadline(running: running, order: waitingOrder, now: now) == nil {
                    perOrder[waitingOrder] = nil
                    ready.append(contentsOf: continuations)
                }
                waiters[dir] = perOrder.isEmpty ? nil : perOrder
            }
            lock.unlock()
            for continuation in ready { continuation.resume() }
        }

        /// 还有没有阻塞者？返回「最早解除阻塞」的时刻（阻塞者各自的停滞点）。
        /// 已经跑过 `stallNanos` 的序号不再算阻塞者 —— 它慢，但不许拖住整屏。
        private static func deadline(running: [Int: UInt64], order: Int, now: UInt64) -> UInt64? {
            var earliest: UInt64?
            for (runningOrder, startedAt) in running where runningOrder < order {
                let at = startedAt &+ stallNanos
                guard at > now else { continue }
                earliest = min(earliest ?? at, at)
            }
            return earliest
        }

        /// 等所有「还在预算内」的更小序号任务结束。
        /// 每一轮都重算阻塞者：前面的人结束时立刻往下走，停滞点到了也往下走。
        func waitTurn(serverID: UUID, path: String, order: Int) async {
            let dir = Self.dirKey(serverID: serverID, path: path)
            while true {
                if Task.isCancelled { return }

                lock.lock()
                let running = active[dir] ?? [:]
                let now = DispatchTime.now().uptimeNanoseconds
                let at = Self.deadline(running: running, order: order, now: now)
                lock.unlock()
                guard let at else { return }

                // 两路赛跑：一路等前面结束，一路睡到停滞点。谁先到都重算一遍。
                // 被取消的那一路会走 `withdraw`，把续体摘掉再 resume，不会泄漏。
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.waitForRelease(dir: dir, order: order) }
                    group.addTask {
                        let now = DispatchTime.now().uptimeNanoseconds
                        if at > now { try? await Task.sleep(nanoseconds: at - now) }
                    }
                    await group.next()
                    group.cancelAll()
                }
            }
        }

        private func waitForRelease(dir: String, order: Int) async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    // 双检：快速路径判断和真正挂起之间，前面的任务可能刚好全部 end
                    let running = active[dir] ?? [:]
                    let now = DispatchTime.now().uptimeNanoseconds
                    if Self.deadline(running: running, order: order, now: now) == nil {
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

    /// 图片车道：**同时 3 个**、按「优先级层 + 格子序号」放行，对应 3 条专用会话。
    ///
    /// 并发 1 → 3 是 1.4.10 的主要提速点：单个小文件的耗时几乎全是 SMB 往返延迟，
    /// 三个同时在飞，等于把「几十张串行」变成「三张三张地读」。
    /// 完成序由 `PublishOrder` 兜住（见上）。
    private let imageLimiter = OrderedLimiter(limit: 3, settleMilliseconds: 100)

    /// 视频车道：**同时 2 个**，对应 2 条专用会话。
    ///
    /// 视频封面要读 moov / 首个 GOP 再解码抽帧，和照片挤同一个闸门时一张封面就能把
    /// 照片的 3 个名额吃掉 1~3 个 —— 「一屏里夹几个视频，照片就慢下来」就是这么来的。
    /// 分道之后视频慢只影响它自己。
    /// 并发 1 → 2（1.5.2）：一屏里往往连着几个视频，串行时第三个要等前面两个全做完，
    /// 用户看到的就是「三个格子一直灰着」。两条视频通道（3、4）正好一条一个。
    private let videoLimiter = OrderedLimiter(limit: 2, settleMilliseconds: 0)

    /// 闸门优先级层。数字越小越先放行：
    /// 屏幕上正在看的图片 → 屏幕上正在看的视频 → 后台预载的图片 → 后台预载的视频。
    /// 视频永远排在图片后面：封面晚一点出现没关系，照片晚出现就是「卡」。
    private static func priorityTier(isVideo: Bool, isPrefetch: Bool) -> Int {
        (isPrefetch ? 2 : 0) + (isVideo ? 1 : 0)
    }

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
        if let image = memory.object(forKey: key as NSString) {
            // 内存命中也要占一个发布序号：否则「已经看过的几张秒出」会插到
            // 正在读网络的格子前面，用户看到的同样是乱序。
            if !isPrefetch {
                await publishInline(serverID: serverID, path: item.path, order: order)
            }
            return image
        }

        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: SettingsKey.thumbnailsEnabled) as? Bool ?? true
        guard enabled else { return nil }
        if item.kind == .video {
            let videos = defaults.object(forKey: SettingsKey.videoThumbnails) as? Bool ?? true
            if !videos { return nil }
        }

        if isCoolingDown(key: key) { return nil }

        // 前台格子 join 预载抢先创建的任务时，`makeJob` 内部会把优先级提回前台、
        // 并补登记发布序号（见那里）。
        let job = makeJob(key: key, item: item, serverID: serverID, connection: connection, order: order, isPrefetch: isPrefetch)
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

    /// 「已经有图、不走网络」的路径也按序放行一次：占一个序号 → 等前面的结束 → 交还。
    ///
    /// 内存命中 / 磁盘命中本来可以立刻返回，但那样它就绕过了整条发布链 ——
    /// 重进目录时「看过的几张秒出、没看过的还在读」，先冒出来的就是后面那几张。
    /// 这里只是补一个序号和一次等待，真正的时间成本几乎为零（前面的图本身也很快）。
    private func publishInline(serverID: UUID, path: String, order: Int) async {
        let ticket = PublishTicket()
        guard ticket.register(order) else { return }
        PublishOrder.shared.begin(serverID: serverID, path: path, order: order)
        await PublishOrder.shared.waitTurn(serverID: serverID, path: path, order: order)
        PublishOrder.shared.end(serverID: serverID, path: path, order: order)
    }

    // MARK: - 任务管理

    private func makeJob(key: String, item: FileItem, serverID: UUID, connection: SMBConnection, order: Int, isPrefetch: Bool = false) -> Job {
        let tier = Self.priorityTier(isVideo: item.kind == .video, isPrefetch: isPrefetch)

        lock.lock()
        if let existing = jobs[key] {
            existing.waiters += 1
            let publish = existing.publish
            lock.unlock()

            // 前台格子 join 了预载抢先创建的任务（预载从第 0 个开始、又比格子的 `.task`
            // 起跑得早，所以最前面几格的 job 基本都由预载创建）：
            // ① 优先级实时提回前台，否则它会排在整屏前台格子后面；
            // ② **补登记发布序号** —— 少了这一步，这几个序号压根不在发布序列里，
            //    后面的图会直接越过它们先上屏（「缩略图还是乱序」的根因）。
            if !isPrefetch {
                existing.priority.promote(to: Self.priorityTier(isVideo: item.kind == .video, isPrefetch: false))
                if publish.register(order) {
                    PublishOrder.shared.begin(serverID: serverID, path: item.path, order: order)
                }
            }
            return existing
        }

        let box = CancellationBox()
        let publish = PublishTicket()
        let priority = PriorityBox(tier)
        // 只有前台任务登记发布序号：后台预载的结果不直接上屏，它的序号不该去挡
        // 「用户刚滑到的那一屏」。预载登记会让快速下滑时的新格子白等前面的预载任务。
        if !isPrefetch, publish.register(order) {
            PublishOrder.shared.begin(serverID: serverID, path: item.path, order: order)
        }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.produce(
                key: key, item: item, serverID: serverID, connection: connection,
                order: order, priority: priority, publish: publish, cancel: box
            )
        }
        let job = Job(task: task, box: box, priority: priority, publish: publish)
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
        guard let until = failures[key] else { return false }
        if Date() < until { return true }
        failures[key] = nil
        return false
    }

    private func markFailure(key: String, isVideo: Bool) {
        let ttl = isVideo ? Self.videoFailureTTL : Self.imageFailureTTL
        lock.lock()
        failures[key] = Date().addingTimeInterval(ttl)
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
        publish: PublishTicket,
        cancel: CancellationBox
    ) async -> UIImage? {
        // 结束登记必须和 `begin` 成对：按序发布层靠「更小序号都结束了」放行，
        // 漏一次 end 就把后面的序号永久压住（会被停滞预算兜住，但会平白多挡 2.5 s）。
        // 用凭据里记住的序号，而不是入参 `order` —— 前台 join 时补登记用的是格子自己的序号。
        defer {
            if let registeredOrder = publish.order {
                PublishOrder.shared.end(serverID: serverID, path: item.path, order: registeredOrder)
            }
        }

        let cache = CacheManager.shared
        let url = cache.thumbnailURL(serverID: serverID, item: item)

        // 磁盘缓存命中：不产生任何网络流量。
        // 用 ImageIO 从文件解（和别处一致）：`UIImage(data:)` 是懒解码，
        // 位图会拖到主线程第一次绘制时才解出来，压缩数据也一直在内存里挂着。
        //
        // 命中也要排队（1.5.2）：重进目录时「看过的几张秒出、没看过的还在读」，
        // 秒出的那几张会插到整屏前面 —— 用户看到的同样是乱序。排队只是等
        // 序号更小的格子，而它们自己通常也是几毫秒的解码，几乎不增加总时间。
        if let cached = ImageDownsampler.downsample(url: url, maxPixel: Self.pixelSize) {
            if priority.current <= 1, !cancel.isCancelled {
                await PublishOrder.shared.waitTurn(
                    serverID: serverID, path: item.path, order: publish.order ?? order
                )
            }
            return cached
        }
        if cancel.isCancelled { return nil }

        var image: UIImage?
        switch item.kind {
        case .image, .video:
            // 分道放行：照片走图片车道（3 并发），视频封面走视频车道（2 并发），
            // 视频再慢也不会占住照片的名额。优先级是共享盒的活值：
            // 预载任务排队期间被前台格子 join，这里读到的就是前台层。
            let limiter = item.kind == .video ? videoLimiter : imageLimiter
            await limiter.acquire(order: order, priority: priority)
            if cancel.isCancelled {
                await limiter.release()
                return nil
            }

            // 单张时间预算：到点就掐断传输（读在块边界干净退出），把名额让出去。
            // 不这么做的话，一个卡在 NAS 那边的大文件会把名额永久占住。
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
            await limiter.release()
            // 超时跟「用户取消」不是一回事：要记一次失败进冷却，别让它在滚动时反复重试
            if timeout.isFired { markFailure(key: key, isVideo: item.kind == .video) }
        case .folder, .other:
            return nil
        }

        // 被取消就不落盘、也不记失败，下次出现时还能重来
        if cancel.isCancelled { return nil }

        // 绿帧绝不进缓存：一旦落盘就永久化了（Android 端为此每张封面都是绿的）
        if item.kind == .video, let frame = image, ImageValidator.isMostlyGreen(frame) {
            ThumbnailDiagnostics.record(item.name, "取到纯绿帧，不缓存")
            markFailure(key: key, isVideo: true)
            return nil
        }

        if let image, let data = image.jpegData(compressionQuality: 0.72) {
            try? data.write(to: url, options: .atomic)
            cache.noteWrite(bytes: Int64(data.count))
        } else {
            markFailure(key: key, isVideo: item.kind == .video)
        }

        // 按序发布：读是并发的、完成顺序不可控，真图要等「还在停滞预算内」的更小序号任务出完。
        // 快图（0.2~1 s）互相严格按序；超过 2.5 s 仍未结束的那张不再挡路（视频封面 / 卡住的读），
        // 后面的按序继续出，它自己晚一点补进来 —— 「有界重排」而不是旧版的「等待者全局超时」。
        // 判定用**活值**（priority ≤ 1 = 前台）：预载抢先建的任务被格子 join 后同样要排队。
        // 失败 / 取消返回的占位图标长得都一样，没有排序意义，不在这里等。
        if let image, priority.current <= 1, !cancel.isCancelled {
            await PublishOrder.shared.waitTurn(
                serverID: serverID,
                path: item.path,
                order: publish.order ?? order
            )
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

        // ① 迷你镜像（**所有大小都先走这条**）：读 16 字节盒子头摸结构 → 只读
        //    「首帧落点 + moov」拼成本地小文件，本地解码器抽首帧。一次 2~12 MB，两秒内出图。
        //
        //    1.5.1 曾把 > 64 MB 的片子直接交给流式（`VideoThumbnailStream`），结果手机拍的大视频
        //    全部 15 s 超时、整屏占位（用户实测 3 个 mp4 全灰）：AVPlayer 在自定义资源加载器上
        //    会反复发 range 请求，moov 在尾部的片子等于要来回把整片摸一遍。而镜像这条路
        //    本来就是为 moov-at-end 设计的（`patchMdatSize` 改声明长度 + 尾部 moov 接到末尾），
        //    老版本 500 MB 的片子也能出图。所以恢复成镜像优先。
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

        // ② 镜像覆盖不到首帧（首帧落在 48 MB 之后、结构异常）才走流式兜底
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
