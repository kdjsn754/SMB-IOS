import Foundation
import CryptoKit
import Combine

/// 管理 App 产生的全部本地缓存（缩略图、缓存的图片、下载的视频）
final class CacheManager: ObservableObject, @unchecked Sendable {
    static let shared = CacheManager()

    @Published private(set) var thumbnailBytes: Int64 = 0
    @Published private(set) var mediaBytes: Int64 = 0
    @Published private(set) var isWorking = false

    /// 最近一次自动清理释放的字节数（用于设置页提示）
    @Published private(set) var lastFreedBytes: Int64 = 0

    var totalBytes: Int64 { thumbnailBytes + mediaBytes }

    let rootDirectory: URL
    let thumbnailDirectory: URL
    let mediaDirectory: URL

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.smbviewer.cache", qos: .utility)

    /// 自动清理的最小间隔，避免每写一张缩略图就全盘扫一次
    private static let autoCleanInterval: TimeInterval = 20

    private let stateLock = NSLock()
    private var directoriesReady = false
    private var enforcing = false
    /// 只在主线程读写
    private var lastAutoCleanCheck = Date.distantPast

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        rootDirectory = base.appendingPathComponent("SMBViewer", isDirectory: true)
        thumbnailDirectory = rootDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        mediaDirectory = rootDirectory.appendingPathComponent("Media", isDirectory: true)
        createDirectories()
    }

    // MARK: - 路径

    /// 缩略图生成逻辑变更时递增，让旧的（错误的）缩略图缓存自动失效
    private static let thumbnailVersion = 2

    func thumbnailURL(serverID: UUID, item: FileItem) -> URL {
        createDirectories()
        let base = Self.fileBaseName(serverID: serverID, item: item, salt: "thumb-v\(Self.thumbnailVersion)")
        return thumbnailDirectory.appendingPathComponent(base + ".jpg")
    }

    func mediaURL(serverID: UUID, item: FileItem, suffix: String) -> URL {
        createDirectories()
        let ext = suffix.isEmpty ? "bin" : suffix
        return mediaDirectory.appendingPathComponent(Self.fileBaseName(serverID: serverID, item: item) + "." + ext)
    }

    private static func fileBaseName(serverID: UUID, item: FileItem, salt: String = "") -> String {
        let stamp = Int64(item.modified?.timeIntervalSince1970 ?? 0)
        let raw = "\(salt)|\(serverID.uuidString)|\(item.path)|\(item.size)|\(stamp)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", Int($0)) }.joined()
    }

    /// 目录只建一次，避免每取一张缩略图就做一次 createDirectory 系统调用
    private func createDirectories() {
        stateLock.lock()
        let ready = directoriesReady
        stateLock.unlock()
        guard !ready else { return }

        for directory in [thumbnailDirectory, mediaDirectory] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        stateLock.lock()
        directoriesReady = true
        stateLock.unlock()
    }

    // MARK: - 统计

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let thumbnails = Self.size(of: self.thumbnailDirectory)
            let media = Self.size(of: self.mediaDirectory)
            DispatchQueue.main.async {
                self.thumbnailBytes = thumbnails
                self.mediaBytes = media
            }
        }
    }

    /// 写入缓存后调用：只做计数累加，最多每 20 秒触发一次真正的容量检查。
    /// 之前每写一张图就全盘遍历一次目录，滑动列表时会明显卡顿、也拖慢缩略图。
    func noteWrite(bytes: Int64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.thumbnailBytes = max(0, self.thumbnailBytes + max(0, bytes))
            guard Date().timeIntervalSince(self.lastAutoCleanCheck) >= Self.autoCleanInterval else { return }
            self.lastAutoCleanCheck = Date()
            self.autoCleanIfNeeded()
        }
    }

    static func size(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - 清理

    func clearAll(completion: (() -> Void)? = nil) {
        isWorking = true
        queue.async { [weak self] in
            guard let self else { return }
            for directory in [self.thumbnailDirectory, self.mediaDirectory] {
                self.removeContents(of: directory)
            }
            ThumbnailStore.shared.clearMemoryCache()
            DispatchQueue.main.async {
                self.isWorking = false
                self.thumbnailBytes = 0
                self.mediaBytes = 0
                completion?()
            }
        }
    }

    func clearThumbnails(completion: (() -> Void)? = nil) {
        isWorking = true
        queue.async { [weak self] in
            guard let self else { return }
            self.removeContents(of: self.thumbnailDirectory)
            ThumbnailStore.shared.clearMemoryCache()
            DispatchQueue.main.async {
                self.isWorking = false
                self.refresh()
                completion?()
            }
        }
    }

    private func removeContents(of directory: URL) {
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? fileManager.removeItem(at: item)
        }
    }

    // MARK: - 容量上限

    /// 按「最久未写入优先」删除，直到降到上限的 80%
    func enforceLimit(bytes limit: Int64, completion: (() -> Void)? = nil) {
        guard limit > 0 else {
            refresh()
            completion?()
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            if self.enforcing {
                self.stateLock.unlock()
                return
            }
            self.enforcing = true
            self.stateLock.unlock()
            defer {
                self.stateLock.lock()
                self.enforcing = false
                self.stateLock.unlock()
            }

            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            var files: [(url: URL, size: Int64, date: Date)] = []

            for directory in [self.thumbnailDirectory, self.mediaDirectory] {
                guard let enumerator = FileManager.default.enumerator(
                    at: directory,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true else { continue }
                    files.append((
                        fileURL,
                        Int64(values.fileSize ?? 0),
                        values.contentModificationDate ?? .distantPast
                    ))
                }
            }

            var total = files.reduce(Int64(0)) { $0 + $1.size }
            guard total > limit else {
                let thumbnails = Self.size(of: self.thumbnailDirectory)
                let media = Self.size(of: self.mediaDirectory)
                DispatchQueue.main.async {
                    self.thumbnailBytes = thumbnails
                    self.mediaBytes = media
                    completion?()
                }
                return
            }

            let target = Int64(Double(limit) * 0.8)
            var freed: Int64 = 0
            for file in files.sorted(by: { $0.date < $1.date }) {
                if total <= target { break }
                if (try? FileManager.default.removeItem(at: file.url)) != nil {
                    total -= file.size
                    freed += file.size
                }
            }

            let thumbnails = Self.size(of: self.thumbnailDirectory)
            let media = Self.size(of: self.mediaDirectory)
            DispatchQueue.main.async {
                self.thumbnailBytes = thumbnails
                self.mediaBytes = media
                self.lastFreedBytes = freed
                completion?()
            }
        }
    }

    /// 读取用户设置，达到上限时自动清理
    func autoCleanIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKey.autoClean) else {
            refresh()
            return
        }
        let limitMB = defaults.integer(forKey: SettingsKey.cacheLimitMB)
        guard limitMB > 0 else {
            refresh()
            return
        }
        enforceLimit(bytes: Int64(limitMB) * 1024 * 1024)
    }
}
