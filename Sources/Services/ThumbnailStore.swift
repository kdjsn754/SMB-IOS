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
/// 5. 「读」可以无序完成，「上屏」**严格按格子序号**（`PublishBox`）：读好的图先放进
///    箱子，只有自己是「有图的最小序号」且前面没有未收工的序号时才放出去，一次放一张。
///    停滞只对**真的在跑**的任务计时（2.5 s），排队等闸门的时间不算 —— 上一版把两者
///    混在一起，导致一屏后半截的图集体「超时」抢先上屏。
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
    /// 大图落盘时的分块大小。>= 8 MB 的块会在通道层自动切段、多会话并发读，
    /// 所以这里给 16 MB：既让并行生效，又把内存峰值压在 16 MB 以内。
    private static let imageReadChunk: Int = 16 * 1024 * 1024
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

        /// 首次登记返回 true —— 调用方负责执行 `PublishBox.begin`
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

    /// 按序发布箱：**读好的缩略图先放进箱子，然后按格子序号一张张放出去**。
    ///
    /// 这是「读并发、出有序」的唯一实现点。前几版的毛病是让**每个任务自己算超时**：
    /// 一屏只有 6 个并发名额，第 7 张往后的任务在闸门里排队，而「停滞预算」是从
    /// **任务创建**那一刻开始烧的 —— 等它们真读完，前面的序号早被判成「已停滞」，
    /// 于是十几张图一起涌上屏。用户说「还是乱序」，根因就在这里。
    ///
    /// 现在改成集中式：
    /// 1. `begin` 登记序号（预载建的 job 被前台格子 join 时补登记）；
    /// 2. `markReading` 在**拿到闸门名额、真正开始读**时打点 —— 排队时间不算停滞；
    /// 3. 图读完 `park` 进箱子，**不直接返回给格子**，在这里等「轮到我」；
    /// 4. 箱子只在「自己是箱子里**有图的最小序号**，且前面没有未收工的序号挡着」时放行，
    ///    而且一次只放一张（`releaseGapNanos` 节流），观感就是左上 → 右下逐格替换；
    /// 5. 失败 / 取消 / 超时 `seal`，后面立刻推进 —— 一个坏文件不能把整屏卡死。
    private final class PublishBox: @unchecked Sendable {
        static let shared = PublishBox()

        /// 已经开始读的序号：读这么久还没出图才让位。照片正常 0.2~1 s，
        /// 2.5 s 说明是真慢（几十兆的大图 / 网络抖动），此时让后面的先出更合理。
        static let stallNanos: UInt64 = 2_500_000_000
        /// 还没轮到读的序号：在闸门里排这么久还没拿到名额才让位。
        /// 只在「并发名额被前面的慢图长期占着」时触发，正常情况用不到。
        static let queueNanos: UInt64 = 6_000_000_000
        /// 连续放行之间的间隔：让「逐格被替换」看得见。
        /// 12 ms 不到一帧，30 格铺满也只要 0.36 s，但不会「一片同时刷出来」。
        static let releaseGapNanos: UInt64 = 12_000_000
        /// 上一代残留的槽位（重进目录 / 刷新）超过这个年龄就当垃圾清掉
        private static let staleNanos: UInt64 = 30_000_000_000
        /// 首屏聚集窗口：目录从空变有之后，先等这么久再开始放行。
        ///
        /// 格子的 `.task` 触发顺序没有保证 —— 第 5 格完全可以比第 0 格早几十毫秒开始。
        /// 如果它一读完就放行，箱子会认为「前面没人」（第 0~4 格还没登记），
        /// 于是第 5 格先冒出来 —— 用户看到的还是乱序。等这一小会儿，让整屏都登记进来，
        /// 从最小序号开始按序放。90 ms 不到 6 帧，肉眼看不出延迟。
        private static let settleNanos: UInt64 = 90_000_000

        private struct Slot {
            var registeredAt: UInt64
            var readingAt: UInt64?
            var image: UIImage?
            var sealed = false
            var waiter: CheckedContinuation<Void, Never>?
        }

        private let lock = NSLock()
        /// 目录键 -> 序号 -> 槽位（只放「还没上屏」的）
        private var slots: [String: [Int: Slot]] = [:]
        /// 节流用的下一次推进
        private var wake: Task<Void, Never>?
        /// 目录键 -> 聚集窗口结束时刻（只在「目录从空变有」时设置）
        private var settleUntil: [String: UInt64] = [:]

        /// 同一台服务器下按目录分组：不同目录的序号互相独立，
        /// A 目录卡住的任务不许压住 B 目录刚点开的格子。
        private static func dirKey(serverID: UUID, path: String) -> String {
            var dir = path
            if let slash = dir.lastIndex(of: "/") { dir = String(dir[..<slash]) }
            return serverID.uuidString + "|" + dir
        }

        /// 这个序号什么时候该停止挡路：
        /// 已经在读的按「开读之后 `stallNanos`」算，还没轮到读的按「登记之后 `queueNanos`」算。
        /// **排队时间绝不算进前者** —— 上一版就是在这里错的。
        private static func stallPoint(_ slot: Slot) -> UInt64 {
            if let readingAt = slot.readingAt { return readingAt &+ stallNanos }
            return slot.registeredAt &+ queueNanos
        }

        // MARK: 登记

        func begin(serverID: UUID, path: String, order: Int) {
            let dir = Self.dirKey(serverID: serverID, path: path)
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            var per = slots[dir] ?? [:]
            // 同代重复登记（预载先建 job、格子 join 时补登记）保留原计时；
            // 太久的残项按新一代重新计时，否则重进目录时旧时间戳会让停滞判断立刻成立。
            if let existing = per[order], now &- existing.registeredAt < Self.staleNanos {
                // 保留
            } else {
                per[order] = Slot(registeredAt: now)
            }
            // 目录从空变有：留一个很短的聚集窗口，等这一屏的格子把序号都登记进来。
            // 已经有过槽位的（滚动中）不重置，否则每来一格都要重新等 90 ms。
            if per.count == 1, (slots[dir]?.isEmpty ?? true) {
                settleUntil[dir] = now &+ Self.settleNanos
            }
            slots[dir] = per
            lock.unlock()
        }

        /// 真正开始读（拿到闸门名额）—— 停滞预算从这一刻起算。
        func markReading(serverID: UUID, path: String, order: Int) {
            let dir = Self.dirKey(serverID: serverID, path: path)
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            if var per = slots[dir], var slot = per[order], slot.readingAt == nil {
                slot.readingAt = now
                per[order] = slot
                slots[dir] = per
            }
            lock.unlock()
        }

        /// 图读好了：放进箱子，等轮到自己再返回（返回 = 可以上屏了）。
        func park(serverID: UUID, path: String, order: Int, image: UIImage) async {
            let dir = Self.dirKey(serverID: serverID, path: path)
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    guard var per = slots[dir], var slot = per[order], slot.sealed == false else {
                        // 没登记 / 已收工：直接放行，绝不能把图吞掉
                        lock.unlock()
                        continuation.resume()
                        return
                    }
                    slot.image = image
                    slot.waiter = continuation
                    per[order] = slot
                    slots[dir] = per
                    let (resume, wakeAt) = drainLocked(dir)
                    lock.unlock()
                    for item in resume { item.resume() }
                    scheduleWake(at: wakeAt)
                }
            } onCancel: {
                withdraw(dir: dir, order: order)
            }
        }

        /// 收工：失败 / 取消 / 已放行。这个序号从此不再挡后面的任何一张。
        func seal(serverID: UUID, path: String, order: Int) {
            let dir = Self.dirKey(serverID: serverID, path: path)
            lock.lock()
            guard var per = slots[dir], var slot = per[order] else {
                lock.unlock()
                return
            }
            slot.sealed = true
            let waiter = slot.waiter
            slot.waiter = nil
            per[order] = slot
            slots[dir] = per
            let (resume, wakeAt) = drainLocked(dir)
            lock.unlock()
            waiter?.resume()
            for item in resume { item.resume() }
            scheduleWake(at: wakeAt)
        }

        // MARK: 放行

        /// 按序号推进放行。一次**最多放行一张**（剩下的排到 `releaseGapNanos` 后），
        /// 这样「左上 → 右下 逐格被替换」在视觉上成立，而不是一片同时刷出来。
        /// 返回：要 resume 的等待者、下一次该醒来的时刻。
        private func drainLocked(_ dir: String) -> ([CheckedContinuation<Void, Never>], UInt64?) {
            guard var per = slots[dir] else {
                settleUntil[dir] = nil
                return ([], nil)
            }
            let now = DispatchTime.now().uptimeNanoseconds

            // 聚集窗口内先不放：等这一屏的格子登记齐，从最小序号开始按序放
            if let until = settleUntil[dir] {
                if now < until { return ([], until) }
                settleUntil[dir] = nil
            }

            // 已收工的槽位直接清掉，不留垃圾。
            // 注意先收集 key 再删：遍历字典的同时修改是未定义行为（会崩）。
            let sealedOrders = per.filter { $0.value.sealed }.map { $0.key }
            for order in sealedOrders { per[order] = nil }

            // 箱子里**有图**的最小序号
            guard let pick = per
                .filter({ $0.value.image != nil })
                .min(by: { $0.key < $1.key })?.key
            else {
                slots[dir] = per.isEmpty ? nil : per
                return ([], nil)
            }

            // 挡在它前面的：序号更小、还没图
            let blockers = per.filter { $0.key < pick && $0.value.image == nil }

            if !blockers.isEmpty {
                let points = blockers.map { Self.stallPoint($0.value) }
                // 还有没到停滞点的 → 等它（或等它读完）
                if !points.allSatisfy({ $0 <= now }) {
                    slots[dir] = per
                    return ([], max(points.min() ?? now, now &+ 1))
                }
            }

            // 放行这张
            let waiter = per[pick]?.waiter
            per[pick] = nil
            slots[dir] = per.isEmpty ? nil : per
            // 箱子里还有别的图 → 排下一拍继续，避免十几张同一帧一起刷出来
            let next = per.isEmpty ? nil : now &+ Self.releaseGapNanos
            return (waiter.map { [$0] } ?? [], next)
        }

        /// 节流：到点继续放下一张。旧的一次性任务直接取消（新的会重新排）。
        private func scheduleWake(at deadline: UInt64?) {
            guard let deadline else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            // 至少 1 ms，别忙等
            let delay = max(deadline > now ? deadline - now : 0, 1_000_000)
            lock.lock()
            wake?.cancel()
            let task = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                self?.drainAll()
            }
            wake = task
            lock.unlock()
        }

        private func drainAll() {
            lock.lock()
            var resume: [CheckedContinuation<Void, Never>] = []
            var next: UInt64?
            for dir in Array(slots.keys) {
                let (list, wakeAt) = drainLocked(dir)
                resume.append(contentsOf: list)
                if let wakeAt { next = min(next ?? wakeAt, wakeAt) }
            }
            lock.unlock()
            for item in resume { item.resume() }
            scheduleWake(at: next)
        }

        /// 等待被取消（格子滚走）：把续体摘掉，别永远挂着。
        /// 槽位保留，`produce` / `thumbnail` 收尾的 `seal` 会把它清掉。
        private func withdraw(dir: String, order: Int) {
            lock.lock()
            var continuation: CheckedContinuation<Void, Never>?
            if var per = slots[dir], var slot = per[order], slot.waiter != nil {
                continuation = slot.waiter
                slot.waiter = nil
                per[order] = slot
                slots[dir] = per
            }
            lock.unlock()
            continuation?.resume()
            // 摘掉等待者后槽位可能还留着图（格子滚走、但任务恰好读完），
            // 补一次推进把它放出去，别让它卡在箱子里占着序号。
            drainAll()
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

    /// 图片车道：**同时 6 个**、按「优先级层 + 格子序号」放行，对应 6 条专用会话。
    ///
    /// 单个小文件的耗时几乎全是 SMB 往返延迟，多几个同时在飞，等于把「几十张串行」
    /// 变成「六张六张地读」。1.6.0 从 3 提到 6：千兆下 3 条会话的吞吐上限只到
    /// 300~400 Mbps（单连接没有请求流水线），6 条才开始摸到网卡上限。
    /// 完成序由 `PublishBox` 兜住（见上）。
    private let imageLimiter = OrderedLimiter(limit: 6, settleMilliseconds: 60)

    /// 后台预载的独立闸门：**最多 3 个**同时进图片/视频车道。
    ///
    /// 预载和前台格子共用同一个车道，如果让它把 6 个名额全占满，用户往下滑时
    /// 新格子只能等前面那几张几 MB 的大图读完 —— 观感就是「滑一下、停一下」。
    /// 给它单独限到 3，剩下 3 个名额永远留给屏幕上的格子：后台照旧填满整个目录，
    /// 前台随时插得进来。这是「速度不稳」的另一半原因。
    private let prefetchGate = AsyncLimiter(limit: 3)

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
            // 内存命中也要进发布箱排一次：否则「已经看过的几张秒出」会插到
            // 正在读网络的格子前面，用户看到的同样是乱序。
            // 视频封面不参与发布序列（见 `makeJob` 的说明）：它慢，却拿占位图标先站住，
            // 让它当「挡路的人」只会把后面整屏照片压住 2.5 s，然后自己最后一个出现 ——
            // 那正是「第 1 格先出、第 0 格后出」的观感来源。
            guard !isPrefetch, item.kind == .image else { return image }
            PublishBox.shared.begin(serverID: serverID, path: item.path, order: order)
            await PublishBox.shared.park(serverID: serverID, path: item.path, order: order, image: image)
            PublishBox.shared.seal(serverID: serverID, path: item.path, order: order)
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

        // 发布序号以凭据里记的为准：预载先建的 job 被前台格子 join 时补登记的是
        // 格子自己的序号，和这里传进来的 `order` 可能不是同一个（预载不看可见性）。
        let publishOrder = job.publish.order ?? order

        guard let result else {
            // 失败 / 取消：立刻收工，别让这个序号把后面整屏挡住
            if !isPrefetch, item.kind == .image {
                PublishBox.shared.seal(serverID: serverID, path: item.path, order: publishOrder)
            }
            return nil
        }
        memory.setObject(result, forKey: key as NSString, cost: Self.cost(of: result))
        guard !isPrefetch, item.kind == .image else { return result }

        // **照片上屏全部从这里过**：新建的 job、join 回来的 job、内存命中，一条不漏。
        // 图先放进箱子，轮到这一格才返回 —— 这就是「读好的先攒着、按顺序放出来」。
        PublishBox.shared.begin(serverID: serverID, path: item.path, order: publishOrder)
        await PublishBox.shared.park(
            serverID: serverID, path: item.path, order: publishOrder, image: result
        )
        PublishBox.shared.seal(serverID: serverID, path: item.path, order: publishOrder)
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
                if item.kind == .image, publish.register(order) {
                    PublishBox.shared.begin(serverID: serverID, path: item.path, order: order)
                }
            }
            return existing
        }

        let box = CancellationBox()
        let publish = PublishTicket()
        let priority = PriorityBox(tier)
        // 只有**照片的前台任务**登记发布序号：
        // - 后台预载的结果不直接上屏，它的序号不该去挡「用户刚滑到的那一屏」；
        // - 视频封面要读 moov / 首个 GOP 再抽帧，3~8 s 很常见。它挡在序列里就会
        //   把后面整屏照片压住一个停滞预算，然后自己最后一个出现 ——「第 1 格先出、
        //   第 0 格后出」。视频有占位图标先站住，走自己的车道（2 并发）即可。
        if !isPrefetch, item.kind == .image, publish.register(order) {
            PublishBox.shared.begin(serverID: serverID, path: item.path, order: order)
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
        // 发布序号的登记 / 收工**不在这里做**：统一由 `thumbnail` 那层负责。
        // 原因：同一个 job 可能先被预载创建、后被前台格子 join，图最后是从
        // `thumbnail` 返回给格子的；把「进箱子排队」放在下面任何一处，都会出现
        // 「produce 已经返回、格子还没排上队」的窗口 —— 那正是前几版漏掉的一条乱序缝。

        let cache = CacheManager.shared
        let url = cache.thumbnailURL(serverID: serverID, item: item)

        // 磁盘缓存命中：不产生任何网络流量。
        // 用 ImageIO 从文件解（和别处一致）：`UIImage(data:)` 是懒解码，
        // 位图会拖到主线程第一次绘制时才解出来，压缩数据也一直在内存里挂着。
        //
        // 命中直接返回：它照旧要经过 `thumbnail` 那层的发布箱排队，
        // 重进目录时「看过的几张秒出、没看过的还在读」也不会插到前面去。
        if let cached = ImageDownsampler.downsample(url: url, maxPixel: Self.pixelSize) {
            return cached
        }
        if cancel.isCancelled { return nil }

        var image: UIImage?
        switch item.kind {
        case .image, .video:
            // 后台预载先过自己的小闸门：最多 3 个在跑，永远给前台留 3 个名额。
            // 身份用优先级的活值判断（预载 = 2/3 层）：预载任务被前台格子 join 之后
            // 会升到 0/1，这时它就是前台请求，不该再算后台名额。
            let background = priority.current >= 2
            if background { await prefetchGate.acquire() }
            defer {
                if background {
                    // 这里的 release 是异步的：defer 体不能 await，扔一个 Task 收尾。
                    // 晚几微秒释放不影响正确性，只是下一波预载稍晚一点开始。
                    let gate = prefetchGate
                    Task { await gate.release() }
                }
            }

            // 分道放行：照片走图片车道（6 并发），视频封面走视频车道（2 并发），
            // 视频再慢也不会占住照片的名额。优先级是共享盒的活值：
            // 预载任务排队期间被前台格子 join，这里读到的就是前台层。
            let limiter = item.kind == .video ? videoLimiter : imageLimiter
            await limiter.acquire(order: order, priority: priority)
            if cancel.isCancelled {
                await limiter.release()
                return nil
            }
            // 从这一刻起才算「在读」：停滞预算只在这种状态下计时。
            // 在闸门里排队的时间绝不能被算成停滞 —— 并发 6、一屏 12 格时，
            // 后 6 格光排队就会把预算烧光，那是前几版乱序的真正来源。
            if item.kind == .image, let registered = publish.order {
                PublishBox.shared.markReading(
                    serverID: serverID, path: item.path, order: registered
                )
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

        // 这里只负责「把图生产出来」，**不负责什么时候上屏**：
        // 图交给 `thumbnail` 后先进发布箱，按格子序号一张张放出去。
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
        // **一次把整份读回来**（不再按 4 MB 分块反复调）。
        // 每次 `contents` 都要在服务端 open + close 一次文件，8 MB 的图分两块就是白付
        // 两轮往返；而超过 8 MB 时 `SMBConnection.thumbRead` 内部会自动切段、多条会话
        // 并发读 —— 分段并行只在这一层调用上才生效，这里分块会把并行能力挡掉。
        let data: Data
        do {
            data = try await connection.thumbRead(
                item.path, offset: 0, length: total, cancel: cancel
            )
        } catch is CancellationError {
            return nil
        } catch {
            ThumbnailDiagnostics.record(item.name, "读取失败：\(error.localizedDescription)")
            return nil
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

        // 已经探明是 iOS 解不了的编码（HEVC 4:4:4 / 4:2:2）：直接放弃，
        // 别再走一遍「读 moov + 三次抽帧等超时」—— 一屏都是这种片子时会白烧流量和时间
        if let known = MP4CodecTag.cachedProbe(
            connection: connection, path: item.path, fileSize: size
        ), known.isUndecodableOnIOS {
            return nil
        }

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
