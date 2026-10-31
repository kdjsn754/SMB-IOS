import Foundation

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

/// 按「格子序号」放行的并发闸门：最多同时跑 `limit` 个，排队时优先放行序号最小的。
///
/// 网格里的几十个格子几乎是同时发起请求的，只按到达顺序放行时，谁先完成取决于
/// 创建 Task 的调度，看起来就是「随机位置一张张冒出来」。带上行序号后，
/// 缩略图会按「左上 → 右下」的顺序稳定填满。
actor OrderedLimiter {
    private let limit: Int
    private var running = 0
    private var sequence = 0
    /// 放行下一个之前的宽限时间：同一批格子创建时间极接近，
    /// 先让它们把序号登记进队伍，再挑最小的，避免「后出现的格子抢到名额」
    private let graceNanos: UInt64

    private struct Waiter {
        let order: Int
        let seq: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waiters: [Waiter] = []

    init(limit: Int, graceMilliseconds: Int = 0) {
        self.limit = max(1, limit)
        self.graceNanos = UInt64(max(0, graceMilliseconds)) * 1_000_000
    }

    func acquire(order: Int) async {
        if running < limit, waiters.isEmpty {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            sequence += 1
            waiters.append(Waiter(order: order, seq: sequence, continuation: continuation))
        }
    }

    func release() async {
        guard !waiters.isEmpty else {
            running = max(0, running - 1)
            return
        }
        if graceNanos > 0 {
            // 等待期间 actor 可重入，新格子能继续登记序号
            try? await Task.sleep(nanoseconds: graceNanos)
        }
        guard !waiters.isEmpty else {
            running = max(0, running - 1)
            return
        }
        var best = 0
        for index in 1..<waiters.count {
            let candidate = waiters[index]
            let current = waiters[best]
            if candidate.order < current.order
                || (candidate.order == current.order && candidate.seq < current.seq) {
                best = index
            }
        }
        // 名额直接转交给下一个，running 保持不减
        waiters.remove(at: best).continuation.resume()
    }
}
