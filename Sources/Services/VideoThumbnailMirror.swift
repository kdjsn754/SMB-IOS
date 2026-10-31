import Foundation
import AVFoundation
import UIKit

/// 远端视频封面的「迷你镜像」抽帧器。
///
/// 为什么不直接用 AVAssetResourceLoader 抽帧：
/// AVFoundation 会发出「从某个偏移一直读到文件结尾」的请求。命中字节预算时我们只能提前
/// `finishLoading()`，它会认为资源被截断、整条解析链随即失败 —— 于是 `moov` 在尾部的大文件
/// 永远出不来封面（几 GB 的 MP4 基本都是这种布局）。
///
/// 这里的做法：
/// 1. 只读 16 字节的盒子头，顺着顶层盒子摸清结构（`MP4Inspector`）：moov 在哪、是不是分片、
///    首个视频样本落在哪个偏移；
/// 2. 按结构决定镜像怎么切：
///    - **普通 MP4**：取文件开头一段（12 → 24 → 40 MB，必要时按首帧落点加大），
///      把 mdat 的「声明长度」改成实际拿到的字节数，moov 在尾部就接在末尾；
///    - **分片 MP4**（`moof` + `mdat` 成对）：**切在完整 fragment 的边界上**，一个字节都不截断，
///      否则最后一个 mdat 被切开、整个文件被判损坏（1.0.11 之前就是这样，`桃桃酱…mp4` 抽不出封面）。
/// 3. 让解码器从本地小文件抽首帧：**先用 `AVAssetReader` 顺着样本读第一个画面**
///    （和播放走同一条路，不需要 seek），失败才退回 `AVAssetImageGenerator`。
///
/// 关键点（1.0.6 之前踩过的坑）：老实现是「按原始偏移把 moov 写到文件末尾」，对 moov-at-end 的
/// 片子等于让临时文件撑到和原片一样大（522 MB / 1 GB）。现在临时文件永远只有十几兆。
enum VideoThumbnailMirror {
    /// moov 读进内存的上限
    private static let maxMoovSize: Int64 = 8 * 1024 * 1024
    /// 极小的片子至少也要读这么多
    private static let minPrefix: Int64 = 8 * 1024 * 1024
    /// 文件开头依次尝试取的字节数（覆盖头几秒的画面数据，够抽第一帧）。
    /// 单个 GOP 大的片子（4K / 高码率）12 MB 装不下第一帧，所以要逐级加大。
    private static let prefixAttempts: [Int64] = [
        12 * 1024 * 1024,
        24 * 1024 * 1024,
        40 * 1024 * 1024
    ]
    /// 镜像最多读这么多（再大就只是在浪费流量）
    private static let maxPrefix: Int64 = 48 * 1024 * 1024
    /// 分片 MP4 的镜像目标长度：切在不超过这个长度的最后一个 fragment 边界上
    private static let fragmentCap: Int64 = 24 * 1024 * 1024
    /// 顶层盒子的探测上限（分片文件每个 moof/mdat 都要走一轮）
    private static let probeBoxLimit = 64
    /// 小于这个大小的片子可以整份读进来（等于不截断），镜像才安全
    static let wholeFileLimit: Int64 = 64 * 1024 * 1024

    private struct Probe {
        let summary: MP4Inspector.Summary
        let moovData: Data?
    }

    static func makeImage(
        connection: SMBConnection,
        path: String,
        fileSize: Int64,
        fileExtension: String,
        cancel: CancellationBox
    ) async -> UIImage? {
        let name = (path as NSString).lastPathComponent
        guard fileSize > 0, !cancel.isCancelled else { return nil }

        guard let probe = await inspect(
            connection: connection, path: path, fileSize: fileSize, cancel: cancel
        ) else {
            ThumbnailDiagnostics.record(name, "文件头读不到（连接中断或没有权限）")
            return nil
        }
        let summary = probe.summary
        guard let moov = summary.moov else {
            ThumbnailDiagnostics.record(name, "结构 \(summary.compactLine)")
            return nil
        }
        guard moov.size >= 8, moov.size <= maxMoovSize else {
            ThumbnailDiagnostics.record(name, "moov \(moov.size / 1024) KB，超出处理范围")
            return nil
        }

        let ext = fileExtension.isEmpty ? "mp4" : fileExtension
        let lengths = mirrorLengths(summary: summary, fileSize: fileSize)
        var lastError = "未知原因"
        var triedLength: Int64 = 0

        for length in lengths {
            if cancel.isCancelled { return nil }
            triedLength = length

            var head: Data
            do {
                head = try await connection.read(path, offset: 0, length: Int(length), cancel: cancel)
            } catch {
                lastError = "读文件头失败：\(error.localizedDescription)"
                continue
            }
            guard Int64(head.count) == length else {
                lastError = "文件头只读到 \(head.count)/\(length) 字节"
                continue
            }

            // 普通 MP4：mdat 被截断了，必须把声明长度改成实际字节数，
            // 否则解析器一看「声明 512 MB、文件只有 12 MB」直接判损坏（-11821 的常见来源）
            let mirrored = summary.isFragmented ? head : patchMdatSize(head, layout: summary)

            // moov 落在镜像之外（moov-at-end）就接到末尾
            var tail = Data()
            if moov.end > length {
                var moovBytes: Data?
                if let cached = probe.moovData, Int64(cached.count) == moov.size {
                    moovBytes = cached
                } else {
                    moovBytes = try? await connection.read(
                        path, offset: moov.offset, length: Int(moov.size), cancel: cancel
                    )
                }
                guard let bytes = moovBytes, Int64(bytes.count) == moov.size else {
                    lastError = "moov 只读到部分字节（应为 \(moov.size)）"
                    continue
                }
                tail = bytes
            }
            if cancel.isCancelled { return nil }

            let url = temporaryURL(ext: ext)
            do {
                var data = mirrored
                data.append(tail)
                try data.write(to: url, options: .atomic)
            } catch {
                ThumbnailDiagnostics.record(name, "写临时文件失败：\(error.localizedDescription)")
                return nil
            }

            let attempt = await VideoFrameDecoder.firstFrame(from: AVURLAsset(url: url))
            try? FileManager.default.removeItem(at: url)

            if let image = attempt.image { return image }
            if !attempt.error.isEmpty { lastError = attempt.error }
            if length >= fileSize { break }
        }

        ThumbnailDiagnostics.record(name, "结构 \(summary.compactLine)")
        ThumbnailDiagnostics.record(
            name, "抽帧失败（镜像 \(triedLength / 1024 / 1024)MB）\(VideoFrameDecoder.shortError(lastError))"
        )
        return nil
    }

    // MARK: - 镜像长度

    /// 决定镜像要读多少字节。分片 MP4 只能切在 fragment 边界上；普通 MP4 逐级加大。
    private static func mirrorLengths(summary: MP4Inspector.Summary, fileSize: Int64) -> [Int64] {
        if summary.isFragmented {
            // 切在「完整 fragment 的结尾」：最后一个盒子的 end 就是安全边界
            var boundary: Int64 = 0
            for box in summary.boxes {
                guard box.end <= fileSize else { break }
                if box.end > fragmentCap, boundary > 0 { break }
                boundary = box.end
            }
            if boundary > 0 { return [min(boundary, fileSize)] }
        }

        // 超过镜像上限（48 MB）但还小到能整份读进来：直接整份读一次，
        // 别按 12/24/40/48 一次次试 —— 截断的镜像本来就会被判「样本偏移越界」，白费流量
        if fileSize > maxPrefix, fileSize <= wholeFileLimit {
            return [fileSize]
        }

        var first = min(fileSize, max(minPrefix, prefixAttempts[0]))
        // 首个视频样本的落点是最硬的约束：GOP 再大也不能把它切掉
        if let video = summary.videoTrack, video.firstSampleOffset > 0, video.firstSampleSize > 0 {
            let need = video.firstSampleOffset + video.firstSampleSize + 1024 * 1024
            if need > first {
                first = min(min(fileSize, maxPrefix), need)
            }
        }

        var candidates: [Int64] = [first]
        for base in prefixAttempts {
            candidates.append(min(fileSize, max(minPrefix, base)))
        }
        candidates.append(min(fileSize, maxPrefix))
        if fileSize <= wholeFileLimit { candidates.append(fileSize) }
        candidates.sort()

        var unique: [Int64] = []
        for value in candidates where value > 0 {
            if unique.last != value { unique.append(value) }
        }
        return unique
    }

    private static func temporaryURL(ext: String) -> URL {
        let suffix = ext.isEmpty ? "mp4" : ext
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("smbthumb-\(UUID().uuidString).\(suffix)")
    }

    // MARK: - 结构探测

    /// 顺着顶层盒子读 16 字节的头，摸清 moov / mdat / moof 的位置，并把 moov 读回内存。
    private static func inspect(
        connection: SMBConnection,
        path: String,
        fileSize: Int64,
        cancel: CancellationBox
    ) async -> Probe? {
        var boxes: [MP4Inspector.Box] = []
        var offset: Int64 = 0
        var moovData: Data?
        var sawFragment = false
        var sawMdat = false

        while offset + 8 <= fileSize, boxes.count < probeBoxLimit {
            if cancel.isCancelled { return nil }
            guard let head = try? await connection.read(
                path, offset: offset, length: 16, cancel: cancel
            ), head.count >= 8 else { break }
            guard let size32 = MP4Inspector.readU32(head, 0),
                  let type = MP4Inspector.fourCC(head, 4) else { break }

            var size = Int64(size32)
            var header: Int64 = 8
            if size32 == 1 {
                guard head.count >= 16, let size64 = MP4Inspector.readU64(head, 8),
                      size64 <= UInt64(Int.max) else { break }
                size = Int64(size64)
                header = 16
            } else if size32 == 0 {
                size = fileSize - offset
            }
            guard size >= header else { break }

            boxes.append(MP4Inspector.Box(type: type, offset: offset, size: size, header: header))

            switch type {
            case "moov":
                if size <= maxMoovSize,
                   let data = try? await connection.read(
                       path, offset: offset, length: Int(size), cancel: cancel
                   ), Int64(data.count) == size {
                    moovData = data
                }
            case "mdat":
                sawMdat = true
            case "moof":
                sawFragment = true
            default:
                break
            }

            offset += size

            // 普通 MP4 拿到 moov + mdat 就够了，别继续往后扫
            if moovData != nil, sawMdat, !sawFragment { break }
            // 分片文件：攒够一个镜像长度的 fragment 就行
            if sawFragment, offset >= fragmentCap { break }
        }

        guard !boxes.isEmpty else { return nil }
        let tracks = moovData.map { MP4Inspector.tracks(in: $0) } ?? []
        return Probe(
            summary: MP4Inspector.Summary(boxes: boxes, tracks: tracks),
            moovData: moovData
        )
    }

    // MARK: - mdat 长度修补

    /// 把 mdat 盒子的 size 字段改成我们实际写入的字节数。
    /// 不改的话，parser 会发现「mdat 声称 522 MB，文件却只有 12 MB」，直接判定文件损坏。
    private static func patchMdatSize(_ data: Data, layout: MP4Inspector.Summary) -> Data {
        guard let mdat = layout.mdat else { return data }
        let boxStart = Int(mdat.offset)
        guard boxStart >= 0, boxStart + 16 <= data.count else { return data }

        let available = Int64(data.count - boxStart)
        guard available >= 8, available < mdat.size else { return data }

        var out = data
        if let size32 = MP4Inspector.readU32(out, boxStart), size32 == 1 {
            var value = UInt64(available).bigEndian
            withUnsafeBytes(of: &value) { raw in
                out.replaceSubrange((boxStart + 8)..<(boxStart + 16), with: raw)
            }
        } else {
            guard available <= Int64(UInt32.max) else { return data }
            var value = UInt32(available).bigEndian
            withUnsafeBytes(of: &value) { raw in
                out.replaceSubrange(boxStart..<(boxStart + 4), with: raw)
            }
        }
        return out
    }
}
