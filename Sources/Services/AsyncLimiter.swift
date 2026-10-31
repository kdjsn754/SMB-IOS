import Foundation
import Dispatch

/// 简单的并发闸门，避免一次性向 NAS 发起几十个请求
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            running = max(0, running - 1)
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

/// 按「格子序号」放行的并发闸门：最多同时跑 `limit` 个，放行顺序严格按格子序号。
///
/// 关键点是**空闲后先聚集、再选拔**：
/// 网格里几十个格子几乎是同时发起请求的，但「谁先跑到闸门」取决于 SwiftUI 起 `.task` 的顺序、
/// 以及每个格子读磁盘缓存花的时间，没有保证。如果空闲时来一个就放一个，
/// 就会出现「先冒出来一张后面的，然后才从第一个开始按顺序」。
///
/// 所以每一次「从空闲变成忙」都先睡一个聚集窗口（默认 250 ms），等这一批格子把序号
/// 登记完，再挑最小的那个放行；之后队列里已经排满了，逐个挑选即可，不再有额外等待。
actor OrderedLimiter {
    private let limit: Int
    /// 聚集窗口：空闲后第一张图放行前的等待
    private let settleNanos: UInt64
    /// 两次请求间隔超过这个时间才算「新的一批」（滚动时一张接一张地进来，不需要再等）
    private let burstGapNanos: UInt64

    private struct Waiter {
        let order: Int
        let seq: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var running = 0
    private var sequence = 0
    private var waiters: [Waiter] = []
    /// 只有一个 pump 在跑，避免重复放行
    private var pumping = false
    /// 下一次放行前是否要先聚集
    private var pendingSettle = true
    /// 上次放行/释放的时间点（uptime 纳秒），用来判断是不是新的一批
    private var lastActivityNanos: UInt64?

    init(limit: Int, settleMilliseconds: Int = 250, burstGapMilliseconds: Int = 400) {
        self.limit = max(1, limit)
        self.settleNanos = UInt64(max(0, settleMilliseconds)) * 1_000_000
        self.burstGapNanos = UInt64(max(0, burstGapMilliseconds)) * 1_000_000
    }

    func acquire(order: Int) async {
        if running == 0, waiters.isEmpty {
            // 从空闲转忙：只有「隔了一段时间」才当成新一批，需要聚集；
            // 连续滚动时一张接一张地来，不额外等待
            let now = DispatchTime.now().uptimeNanoseconds
            if let last = lastActivityNanos {
                pendingSettle = now &- last >= burstGapNanos
            } else {
                pendingSettle = true
            }
        }

        sequence += 1
        let seq = sequence
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(order: order, seq: seq, continuation: continuation))
            // 不能在 continuation 体内直接 await pump（会把「登记」卡住）
            Task { await self.pump() }
        }
    }

    func release() {
        running = max(0, running - 1)
        lastActivityNanos = DispatchTime.now().uptimeNanoseconds
        Task { await self.pump() }
    }

    private func pump() async {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }

        while running < limit, !waiters.isEmpty {
            if pendingSettle {
                // 睡眠期间 actor 可重入，这一批格子会继续把序号登记进来
                try? await Task.sleep(nanoseconds: settleNanos)
                pendingSettle = false
            }
            guard !waiters.isEmpty else { break }

            var best = 0
            for index in 1..<waiters.count {
                let candidate = waiters[index]
                let current = waiters[best]
                if candidate.order < current.order
                    || (candidate.order == current.order && candidate.seq < current.seq) {
                    best = index
                }
            }
            let waiter = waiters.remove(at: best)
            running += 1
            lastActivityNanos = DispatchTime.now().uptimeNanoseconds
            waiter.continuation.resume()
        }
    }
}
