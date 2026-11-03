import AVFoundation
import UIKit

/// 给「视频下载」列表生成本机文件的首帧缩略图。
///
/// 为什么不复用 `ThumbnailStore`：那条路是为目录网格设计的，走 SMB 读远端字节、
/// 还要经过按序发布箱。这里的文件**已经在本地磁盘上**，直接 `AVAssetImageGenerator`
/// 抓一帧最快，而且不需要任何服务器连接 —— 断网、服务器被删掉也还能显示封面。
///
/// 同一条视频只解析一次：结果进内存缓存；解不出来的（比如 4:4:4 的 HEVC，
/// iOS 没有解码器）记进失败表，不再重试 —— 否则每次滚动都要重新烧一遍解码器。
final class LocalVideoThumbnailer: @unchecked Sendable {
    static let shared = LocalVideoThumbnailer()

    /// 一帧封面 + 时长。时长用来在缩略图右下角打角标。
    struct Snapshot: @unchecked Sendable {
        let image: UIImage
        let duration: Double
    }

    private let images = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var durations: [String: Double] = [:]
    private var failed: Set<String> = []

    private init() {
        images.countLimit = 200
    }

    /// 已经解出来的直接给，用来在列表刷新时先占位，避免封面闪一下又回来
    func cachedImage(for key: String) -> UIImage? {
        images.object(forKey: key as NSString)
    }

    /// 取封面。`key` 用缓存目录里的文件名（本身就是 SHA256，唯一且稳定）。
    func snapshot(for url: URL, key: String) async -> Snapshot? {
        if let image = images.object(forKey: key as NSString) {
            return Snapshot(image: image, duration: duration(for: key) ?? 0)
        }
        guard !isFailed(key) else { return nil }

        let decoded = await Task.detached(priority: .utility) { await Self.decode(url: url) }.value
        guard let decoded else {
            markFailed(key)
            return nil
        }

        images.setObject(decoded.image, forKey: key as NSString)
        let seconds = decoded.duration.isFinite ? decoded.duration : 0
        storeDuration(seconds, for: key)
        return Snapshot(image: decoded.image, duration: seconds)
    }

    // MARK: - 解码

    private static func decode(url: URL) async -> Snapshot? {
        let asset = AVURLAsset(url: url)
        let duration = ((try? await asset.load(.duration))?.seconds) ?? 0

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 列表里只有 64 pt，给到 128 pt 已经足够清楚（3x 屏也不糊）
        generator.maximumSize = CGSize(width: 128, height: 128)
        // 容差放到 0.5 秒：HEVC 的关键帧可能很稀，要求精确到帧会慢一个数量级，
        // 而封面差半秒完全看不出来
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        // 取 1 秒处：0 秒经常是黑场或片头空白
        let seek = duration > 1.5 ? 1.0 : max(0.05, duration * 0.2)
        if let frame = try? await generator.image(at: CMTime(seconds: seek, preferredTimescale: 600)).image {
            return Snapshot(image: UIImage(cgImage: frame), duration: duration)
        }
        // 有些容器第一帧抽不出来（moov 在尾部、关键帧稀疏），退到 0 秒再试一次
        if let frame = try? await generator.image(at: .zero).image {
            return Snapshot(image: UIImage(cgImage: frame), duration: duration)
        }
        return nil
    }

    // MARK: - 记录（都是同步方法：锁不能直接在 async 上下文里拿）

    private func duration(for key: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return durations[key]
    }

    private func storeDuration(_ seconds: Double, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        durations[key] = seconds
    }

    private func isFailed(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed.contains(key)
    }

    private func markFailed(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        failed.insert(key)
    }

    /// 文件被删掉 / 重新下载之后，旧的失败记录不该继续挡着
    func forget(key: String) {
        images.removeObject(forKey: key as NSString)
        lock.lock()
        defer { lock.unlock() }
        failed.remove(key)
        durations[key] = nil
    }
}
