import Foundation

/// 跨线程的取消标记。
///
/// Swift 的 `Task` 取消不会自动传进 AMSMB2 的 C 回调里，而 AMSMB2 的读取进度回调
/// 是唯一能在传输过程中「叫停」的入口（返回 false 即中止）。所以用一个显式的标记
/// 对象把「视图已经消失」这件事传下去，避免用户划走之后还在后台白读几十兆。
final class CancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// 一次读取允许消耗的字节额度。
///
/// 用户看到的「一打开就一直跑流量」，根因是 `AVAssetImageGenerator` 会发出
/// 「从当前位置读到文件结尾」的请求，旧实现照单全收，等于每生成一个视频封面就
/// 把整个视频下载一遍。这里给一个硬额度，读满就停。
final class ByteBudget: @unchecked Sendable {
    private let limit: Int64
    private let lock = NSLock()
    private var used: Int64 = 0

    init(limit: Int64) {
        self.limit = max(0, limit)
    }

    func remaining() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return max(0, limit - used)
    }

    func consume(_ bytes: Int64) {
        guard bytes > 0 else { return }
        lock.lock()
        used += bytes
        lock.unlock()
    }
}
