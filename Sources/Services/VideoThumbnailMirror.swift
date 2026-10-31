import Foundation
import AVFoundation
import UIKit

/// 远端视频封面的「稀疏镜像」抽帧器。
///
/// 为什么不直接用 AVAssetResourceLoader 抽帧：
/// AVFoundation 会发出「从某个偏移一直读到文件结尾」的请求。命中字节预算时我们只能提前
/// `finishLoading()`，它会认为资源被截断，整条解析链随即失败 —— 于是 `moov` 在尾部的大文件
/// 永远出不来封面（几 GB 的 MP4 基本都是这种布局）。
///
/// 这里改成确定性的做法：
/// 1. 只读 8～16 字节的盒子头，顺着顶层盒子找到 `moov`（在最前、在最后都行）；
/// 2. 把 `moov`、文件开头 1 MB、第一个视频关键帧附近 8 MB 取回来；
/// 3. 按原始偏移写成一个「稀疏文件」（其余位置是空洞，几乎不占磁盘）；
/// 4. 让 `AVAssetImageGenerator` 从本地文件抽帧。
///
/// 每次最多读 1 MB + moov + 8 MB，与文件总大小无关。
enum VideoThumbnailMirror {
    /// moov 读进内存的上限
    private static let maxMoovSize: Int64 = 8 * 1024 * 1024
    /// 文件开头读取量（ftyp / mdat 头，保证容器结构完整）
    private static let headerBytes: Int64 = 1024 * 1024
    /// 关键帧窗口大小
    private static let sampleWindow: Int64 = 8 * 1024 * 1024
    /// 关键帧窗口往前多取一点，覆盖 stco 指向的样本起点
    private static let sampleLeadIn: Int64 = 128 * 1024

    static func makeImage(
        connection: SMBConnection,
        path: String,
        fileSize: Int64,
        fileExtension: String,
        cancel: CancellationBox
    ) async -> UIImage? {
        guard fileSize > 0, !cancel.isCancelled else { return nil }
        guard let moov = await locateMoov(
            connection: connection, path: path, fileSize: fileSize, cancel: cancel
        ) else { return nil }
        guard moov.size >= 8, moov.size <= maxMoovSize else { return nil }

        let moovData: Data
        do {
            moovData = try await connection.read(
                path, offset: moov.offset, length: Int(moov.size), cancel: cancel
            )
        } catch {
            return nil
        }
        guard Int64(moovData.count) == moov.size else { return nil }

        let ext = fileExtension.isEmpty ? "mp4" : fileExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smbthumb-\(UUID().uuidString).\(ext)")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else { return nil }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let handle = try? FileHandle(forWritingTo: tempURL) else { return nil }
        defer { try? handle.close() }

        do {
            // 1) 文件头：保证 ftyp / mdat 头在正确位置
            let headLength = Int(min(headerBytes, fileSize))
            let head = try await connection.read(path, offset: 0, length: headLength, cancel: cancel)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: head)

            // 2) moov 本体：按原偏移写回，索引里的绝对偏移才对得上
            try handle.seek(toOffset: UInt64(moov.offset))
            try handle.write(contentsOf: moovData)

            // 3) 第一个视频关键帧附近的数据
            if let chunk = firstVideoChunkOffset(in: moovData), chunk > 0, chunk < fileSize {
                let start = max(0, chunk - sampleLeadIn)
                let length = Int(min(sampleWindow, fileSize - start))
                if length > 0 {
                    let samples = try await connection.read(
                        path, offset: start, length: length, cancel: cancel
                    )
                    try handle.seek(toOffset: UInt64(start))
                    try handle.write(contentsOf: samples)
                }
            }
        } catch {
            return nil
        }

        try? handle.synchronize()
        guard !cancel.isCancelled else { return nil }

        let asset = AVURLAsset(url: tempURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        for seconds in [1.0, 0.0, 3.0] {
            if cancel.isCancelled { return nil }
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let result = try? await generator.image(at: time) {
                return UIImage(cgImage: result.image)
            }
        }
        return nil
    }

    // MARK: - 顶层盒子定位

    private static func locateMoov(
        connection: SMBConnection,
        path: String,
        fileSize: Int64,
        cancel: CancellationBox
    ) async -> (offset: Int64, size: Int64)? {
        var offset: Int64 = 0
        var visited = 0

        while offset + 8 <= fileSize && visited < 64 {
            visited += 1
            if cancel.isCancelled { return nil }
            guard let head = try? await connection.read(
                path, offset: offset, length: 16, cancel: cancel
            ), head.count >= 8 else { return nil }
            guard let size32 = readU32(head, 0), let type = fourCC(head, 4) else { return nil }

            var size = Int64(size32)
            var header: Int64 = 8
            if size32 == 1 {
                guard head.count >= 16, let size64 = readU64(head, 8) else { return nil }
                size = Int64(bitPattern: size64)
                header = 16
            } else if size32 == 0 {
                size = fileSize - offset
            }
            guard size >= header else { return nil }
            if type == "moov" { return (offset, size) }
            offset += size
        }
        return nil
    }

    // MARK: - moov 内部解析

    private struct Box {
        let type: String
        /// 载荷起点（跳过头）
        let start: Int
        /// 盒子结束位置（不含）
        let end: Int
    }

    /// 只解析一层子盒子，够 trak / mdia / minf / stbl 用
    private static func boxes(in data: Data, from start: Int, to end: Int) -> [Box] {
        var result: [Box] = []
        var position = start
        let limit = min(end, data.count)

        while position + 8 <= limit {
            guard let size32 = readU32(data, position), let type = fourCC(data, position + 4) else { break }
            var size = Int(size32)
            var header = 8
            if size32 == 1 {
                guard let size64 = readU64(data, position + 8), size64 <= UInt64(Int.max) else { break }
                size = Int(size64)
                header = 16
            } else if size32 == 0 {
                size = limit - position
            }
            guard size >= header, position + size <= limit else { break }
            result.append(Box(type: type, start: position + header, end: position + size))
            position += size
        }
        return result
    }

    /// 找到视频轨第一个 chunk 的绝对偏移（就是第一帧关键帧的位置）
    private static func firstVideoChunkOffset(in moov: Data) -> Int64? {
        var start = 8
        if let size32 = readU32(moov, 0), size32 == 1 { start = 16 }

        for trak in boxes(in: moov, from: start, to: moov.count) where trak.type == "trak" {
            let trakKids = boxes(in: moov, from: trak.start, to: trak.end)
            guard let mdia = trakKids.first(where: { $0.type == "mdia" }) else { continue }

            let mdiaKids = boxes(in: moov, from: mdia.start, to: mdia.end)
            guard let hdlr = mdiaKids.first(where: { $0.type == "hdlr" }),
                  fourCC(moov, hdlr.start + 8) == "vide" else { continue }

            guard let minf = mdiaKids.first(where: { $0.type == "minf" }) else { continue }
            let minfKids = boxes(in: moov, from: minf.start, to: minf.end)
            guard let stbl = minfKids.first(where: { $0.type == "stbl" }) else { continue }
            let stblKids = boxes(in: moov, from: stbl.start, to: stbl.end)

            if let stco = stblKids.first(where: { $0.type == "stco" }),
               let count = readU32(moov, stco.start + 4), count > 0,
               let first = readU32(moov, stco.start + 8) {
                return Int64(first)
            }
            if let co64 = stblKids.first(where: { $0.type == "co64" }),
               let count = readU32(moov, co64.start + 4), count > 0,
               let first = readU64(moov, co64.start + 8) {
                return Int64(bitPattern: first)
            }
        }
        return nil
    }

    // MARK: - 字节工具

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private static func readU64(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        return data.withUnsafeBytes {
            UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }

    private static func fourCC(_ data: Data, _ offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        let bytes = [data[base], data[base + 1], data[base + 2], data[base + 3]]
        return String(bytes: bytes, encoding: .isoLatin1)
    }
}
