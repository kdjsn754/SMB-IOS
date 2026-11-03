import Foundation
import Combine

/// 一条「已经下载到本机」的视频。
///
/// `id` 就是缓存目录里的文件名（SHA256 + 扩展名），目录内唯一，直接拿来做 `Identifiable`，
/// 删除时也不用再反算路径。
struct DownloadedVideo: Identifiable, Codable, Equatable {
    var id: String
    /// 服务器上的原始文件名（旧版本下载的文件没有记录，只能合成一个）
    var name: String
    var serverID: UUID?
    var remotePath: String?
    var byteSize: Int64
    var downloadedAt: Date
    /// 1.6.4 之前下载的文件没有索引记录，只能按扩展名扫出来
    var isLegacy: Bool = false

    /// 列表副标题：大小 + 下载时间
    var detail: String {
        let size = Format.bytes(byteSize)
        guard downloadedAt > .distantPast else { return size }
        return size + " · " + Self.dateFormatter.string(from: downloadedAt)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

/// 「下载到本地」的视频清单。
///
/// 为什么要单独做一个清单：缓存目录里的文件名是 SHA256，光看磁盘根本不知道是哪个视频。
/// 下载完成时把「原文件名 + 服务器 + 远端路径 + 大小 + 时间」记进 `Downloads.json`，
/// 设置页才能列出人话。
///
/// **磁盘是唯一的事实来源**：每次刷新都扫一遍 `Media` 目录，只列视频扩展名的文件，
/// 再和索引对账。这样即使索引丢了 / 老版本下载的文件不在索引里，列表也不会漏 ——
/// 只是名字显示成「视频（旧版本下载）」。反过来，文件被缓存上限自动淘汰后，
/// 索引里的残留记录也不会再出现在列表里。
final class VideoDownloadStore: ObservableObject, @unchecked Sendable {
    static let shared = VideoDownloadStore()

    @Published private(set) var items: [DownloadedVideo] = []
    @Published private(set) var isLoading = false

    var totalBytes: Int64 { items.reduce(Int64(0)) { $0 + $1.byteSize } }

    /// 一句话摘要，设置首页右侧显示
    var summary: String {
        guard !items.isEmpty else { return "无" }
        return "\(items.count) 个 · \(Format.bytes(totalBytes))"
    }

    private let fileManager = FileManager.default
    private var directory: URL { CacheManager.shared.mediaDirectory }
    private var indexURL: URL { CacheManager.shared.rootDirectory.appendingPathComponent("Downloads.json") }
    private let queue = DispatchQueue(label: "com.smbviewer.downloads", qos: .utility)

    /// 只认这些扩展名，避免把缓存的图片也列进「视频下载」
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "ts", "m2ts", "webm",
        "flv", "wmv", "mpg", "mpeg", "3gp", "rmvb", "rm", "vob", "ogv"
    ]

    private init() {
        reload()
    }

    // MARK: - 读取

    /// 重扫目录（进入设置页、下载完成、删除之后都要调）
    func reload() {
        isLoading = true
        queue.async { [weak self] in
            guard let self else { return }
            let scanned = self.scan()
            DispatchQueue.main.async {
                self.items = scanned
                self.isLoading = false
            }
        }
    }

    private func scan() -> [DownloadedVideo] {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var records = loadIndex()
        var byName: [String: DownloadedVideo] = [:]
        for record in records { byName[record.id] = record }

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [DownloadedVideo] = []
        for url in files {
            guard Self.videoExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            let name = url.lastPathComponent
            let size = Int64(values.fileSize ?? 0)
            let date = values.contentModificationDate ?? .distantPast

            if var record = byName.removeValue(forKey: name) {
                // 大小以磁盘为准（索引记的是远端大小，理论上一致，但别信两次）
                record.byteSize = size
                result.append(record)
            } else {
                result.append(
                    DownloadedVideo(
                        id: name,
                        name: "视频（旧版本下载）",
                        serverID: nil,
                        remotePath: nil,
                        byteSize: size,
                        downloadedAt: date,
                        isLegacy: true
                    )
                )
            }
        }

        // 索引里指向的文件已经被淘汰 / 手动删掉的，顺手清掉，别越积越多
        if byName.count > 0 {
            records.removeAll { byName[$0.id] != nil }
            saveIndex(records)
        }

        return result.sorted { lhs, rhs in
            if lhs.downloadedAt == rhs.downloadedAt { return lhs.name < rhs.name }
            return lhs.downloadedAt > rhs.downloadedAt
        }
    }

    // MARK: - 记录

    /// 这一条在缓存目录里的实际位置（`id` 就是文件名）
    func fileURL(for video: DownloadedVideo) -> URL {
        directory.appendingPathComponent(video.id)
    }

    /// 下载成功、文件已经搬进缓存目录后调用（`MediaStore.localVideoURL` 里）。
    /// 不在主线程上跑，写完再回主线程刷新列表。
    func record(item: FileItem, serverID: UUID, url: URL) {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? item.size
        let entry = DownloadedVideo(
            id: url.lastPathComponent,
            name: item.name,
            serverID: serverID,
            remotePath: item.path,
            byteSize: size,
            downloadedAt: Date()
        )

        queue.async { [weak self] in
            guard let self else { return }
            var records = self.loadIndex()
            records.removeAll { $0.id == entry.id }
            records.append(entry)
            self.saveIndex(records)
            DispatchQueue.main.async { self.reload() }
        }
    }

    // MARK: - 删除

    func delete(_ video: DownloadedVideo) {
        let url = directory.appendingPathComponent(video.id)
        queue.async { [weak self] in
            guard let self else { return }
            try? self.fileManager.removeItem(at: url)
            // .part 半成品顺手一起清掉（正常情况不会有，取消下载时已经删过）
            try? self.fileManager.removeItem(at: url.appendingPathExtension("part"))

            let records = self.loadIndex().filter { $0.id != video.id }
            self.saveIndex(records)

            CacheManager.shared.refresh()
            DispatchQueue.main.async { self.reload() }
        }
    }

    /// 删除全部已下载的视频。**只删视频扩展名的文件**，缩略图和缓存的图片不动
    /// （那是「清空全部缓存」的活）。
    func deleteAll() {
        queue.async { [weak self] in
            guard let self else { return }
            let keys: [URLResourceKey] = [.isRegularFileKey]
            if let files = try? self.fileManager.contentsOfDirectory(
                at: self.directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) {
                for url in files where Self.videoExtensions.contains(url.pathExtension.lowercased()) {
                    try? self.fileManager.removeItem(at: url)
                }
            }
            self.saveIndex([])
            CacheManager.shared.refresh()
            DispatchQueue.main.async { self.reload() }
        }
    }

    // MARK: - 索引读写

    private func loadIndex() -> [DownloadedVideo] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DownloadedVideo].self, from: data)) ?? []
    }

    private func saveIndex(_ records: [DownloadedVideo]) {
        guard !records.isEmpty else {
            try? fileManager.removeItem(at: indexURL)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
