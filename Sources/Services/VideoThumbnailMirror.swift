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
/// 这里改成确定性的做法：
/// 1. 只读 16 字节的盒子头，顺着顶层盒子找到 `moov` 与 `mdat`（moov 在最前、最后都行）；
/// 2. 取**文件开头一小段**（默认 12 MB，够解码头几秒）和 `moov`；
/// 3. 把 mdat 的「声明长度」改成实际拿到的字节数，拼成一个小而连续的文件（**不留空洞**）；
/// 4. 让 `AVAssetImageGenerator` 从本地文件抽帧。
///
/// 关键点（1.0.6 之前踩过的坑）：老实现是「按原始偏移把 moov 写到文件末尾」，对 moov-at-end 的
/// 片子等于让临时文件撑到和原片一样大（522 MB / 1 GB）。写这么大的文件在手机上一来极慢、
/// 二来很容易因空间不足直接失败，失败了就只能退回胶片图标。现在临时文件永远只有十几兆。
enum VideoThumbnailMirror {
    /// moov 读进内存的上限
    private static let maxMoovSize: Int64 = 8 * 1024 * 1024
    /// 文件开头取的字节数（覆盖头几秒的画面数据，够抽第一帧）
    private static let prefixLength: Int64 = 12 * 1024 * 1024
    /// 极小的片子至少也要读这么多
    private static let minPrefixLength: Int64 = 2 * 1024 * 1024

    static func makeImage(
        connection: SMBConnection,
        path: String,
        fileSize: Int64,
        fileExtension: String,
        cancel: CancellationBox
    ) async -> UIImage? {
        let name = (path as NSString).lastPathComponent
        guard fileSize > 0, !cancel.isCancelled else { return nil }

        guard let layout = await scan(
            connection: connection, path: path, fileSize: fileSize, cancel: cancel
        ) else {
            ThumbnailDiagnostics.record(name, "找不到 moov（可能是不支持的封装）")
            return nil
        }
        guard layout.moovSize >= 8, layout.moovSize <= maxMoovSize else {
            ThumbnailDiagnostics.record(name, "moov \(layout.moovSize / 1024) KB，超出处理范围")
            return nil
        }

        var prefix = min(fileSize, max(minPrefixLength, prefixLength))
        // moov 刚好压在前缀边界上：把前缀延长到 moov 结束，避免出现两个 moov
        if layout.moovOffset < prefix, layout.moovOffset + layout.moovSize > prefix {
            prefix = layout.moovOffset + layout.moovSize
        }
        guard prefix > 0, prefix <= Int64(Int.max) else { return nil }

        var head: Data
        do {
            head = try await connection.read(path, offset: 0, length: Int(prefix), cancel: cancel)
        } catch {
            return nil
        }
        guard Int64(head.count) == prefix else {
            ThumbnailDiagnostics.record(name, "文件头只读到 \(head.count) 字节")
            return nil
        }

        // moov 不在前缀里就单独读回来，接在文件末尾
        var tail = Data()
        if layout.moovOffset >= prefix {
            do {
                tail = try await connection.read(
                    path, offset: layout.moovOffset, length: Int(layout.moovSize), cancel: cancel
                )
            } catch {
                return nil
            }
            guard Int64(tail.count) == layout.moovSize else {
                ThumbnailDiagnostics.record(name, "moov 只读到 \(tail.count) 字节")
                return nil
            }
        }
        if cancel.isCancelled { return nil }

        // 把 mdat 的声明长度改成「实际拿到的字节数」，否则解析器会认为文件被截断
        head = patchMdatSize(head, layout: layout)

        let ext = fileExtension.isEmpty ? "mp4" : fileExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smbthumb-\(UUID().uuidString).\(ext)")
        do {
            var data = head
            data.append(tail)
            try data.write(to: tempURL, options: .atomic)
        } catch {
            ThumbnailDiagnostics.record(name, "写临时文件失败：\(error.localizedDescription)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if let image = await extractFrame(at: tempURL, cancel: cancel) {
            return image
        }
        ThumbnailDiagnostics.record(name, "抽帧失败（已取 \(head.count / 1024) KB + moov）")
        return nil
    }

    /// 从镜像文件抽一帧
    private static func extractFrame(at url: URL, cancel: CancellationBox) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        // 允许取最近的关键帧，这样只需解开头几个 GOP
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        // 从小时间点试起：镜像里只有头十几兆，越靠后越可能没有数据
        for seconds in [1.0, 0.0, 3.0, 0.5] {
            if cancel.isCancelled { return nil }
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let result = try? await generator.image(at: time) {
                return UIImage(cgImage: result.image)
            }
        }
        return nil
    }

    // MARK: - 顶层盒子扫描

    private struct Layout {
        let moovOffset: Int64
        let moovSize: Int64
        /// 没找到 mdat 时为 -1
        let mdatOffset: Int64
        let mdatSize: Int64
    }

    private static func scan(
        connection: SMBConnection,
        path: String,
        fileSize: Int64,
        cancel: CancellationBox
    ) async -> Layout? {
        var offset: Int64 = 0
        var visited = 0
        var moovOffset: Int64?
        var moovSize: Int64 = 0
        var mdatOffset: Int64 = -1
        var mdatSize: Int64 = 0

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

            switch type {
            case "moov":
                moovOffset = offset
                moovSize = size
                // mdat 已经拿到了，没必要再往后扫
                if mdatOffset >= 0 { return makeLayout(offset, size, mdatOffset, mdatSize) }
            case "mdat":
                mdatOffset = offset
                mdatSize = size
            default:
                break
            }
            offset += size
        }

        guard let moovOffset else { return nil }
        return makeLayout(moovOffset, moovSize, mdatOffset, mdatSize)
    }

    private static func makeLayout(
        _ moovOffset: Int64, _ moovSize: Int64, _ mdatOffset: Int64, _ mdatSize: Int64
    ) -> Layout {
        Layout(moovOffset: moovOffset, moovSize: moovSize, mdatOffset: mdatOffset, mdatSize: mdatSize)
    }

    // MARK: - mdat 长度修补

    /// 把 mdat 盒子的 size 字段改成我们实际写入的字节数。
    /// 不改的话，parser 会发现「mdat 声称 522 MB，文件却只有 12 MB」，直接判定文件损坏。
    private static func patchMdatSize(_ data: Data, layout: Layout) -> Data {
        guard layout.mdatOffset >= 0 else { return data }
        let boxStart = Int(layout.mdatOffset)
        guard boxStart >= 0, boxStart + 16 <= data.count else { return data }

        let available = Int64(data.count - boxStart)
        guard available >= 8, available < layout.mdatSize else { return data }

        var out = data
        let size32 = readU32(out, boxStart) ?? 0
        if size32 == 1 {
            guard boxStart + 16 <= out.count else { return data }
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
