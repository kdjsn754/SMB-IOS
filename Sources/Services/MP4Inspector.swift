import Foundation

/// MP4 / MOV 的盒子结构分析（只读）。
///
/// 两个用途：
/// 1. 给「迷你镜像」提供装配依据：顶层盒子清单、moov 位置、首帧样本落点、是否分片（moof）；
/// 2. 给设置页诊断提供一行可查的结构摘要 —— 用户只能截图反馈，字符串必须一眼能看出问题在哪。
enum MP4Inspector {
    struct Box {
        let type: String
        /// 相对所在 buffer 的起点（顶层扫描时就是相对文件开头）
        let offset: Int64
        let size: Int64
        let header: Int64

        var end: Int64 { offset + size }
    }

    struct Track {
        /// `vide` / `soun` / `text` …
        let handler: String
        /// `avc1` / `hvc1` / `av01` …
        let codec: String
        let width: Int
        let height: Int
        let firstSampleOffset: Int64
        let firstSampleSize: Int64
        let hasEditList: Bool
    }

    struct Summary {
        let boxes: [Box]
        let tracks: [Track]

        var moov: Box? { boxes.first { $0.type == "moov" } }
        var mdat: Box? { boxes.first { $0.type == "mdat" } }
        /// 分片 MP4（moof + mdat 成对出现）：镜像必须切在 fragment 边界上，
        /// 否则最后一个 mdat 会被截断，整个文件被判为损坏。
        var isFragmented: Bool { boxes.contains { $0.type == "moof" } }
        var moofCount: Int { boxes.filter { $0.type == "moof" }.count }
        var videoTrack: Track? { tracks.first { $0.handler == "vide" } }

        /// 一行诊断摘要（尽量短：设置页一行显示不下会被省略号截掉）。
        /// 例：`mdat@40 522MB · moov尾 412KB · avc1 1080×1920 · 首帧@40+2.4MB`
        var compactLine: String {
            var parts: [String] = []
            if let mdat {
                parts.append("mdat@\(mdat.offset) \(Self.sizeText(mdat.size))")
            }
            if let moov {
                let atEnd = moov.offset > (mdat?.offset ?? 0)
                parts.append("\(atEnd ? "moov尾" : "moov头") \(Self.sizeText(moov.size))")
            }
            if isFragmented { parts.append("分片×\(moofCount)") }
            if let video = videoTrack {
                parts.append("\(video.codec) \(video.width)×\(video.height)")
                parts.append("首帧@\(video.firstSampleOffset)+\(Self.sizeText(video.firstSampleSize))")
            } else {
                parts.append(tracks.isEmpty ? "moov无轨道" : "无视频轨道")
            }
            return parts.joined(separator: " · ")
        }

        static func sizeText(_ bytes: Int64) -> String {
            if bytes >= 1024 * 1024 {
                return "\(bytes / 1024 / 1024)MB"
            }
            if bytes >= 1024 {
                return "\(bytes / 1024)KB"
            }
            return "\(bytes)B"
        }
    }

    // MARK: - 盒子遍历

    /// 列出 `[start, end)` 区间内的同级盒子。遇到解析不下去的字节就停下（截断的文件很常见）。
    static func boxes(in data: Data, from start: Int = 0, to end: Int? = nil, limit: Int = 512) -> [Box] {
        var out: [Box] = []
        let upper = min(end ?? data.count, data.count)
        var cursor = max(0, start)
        while cursor + 8 <= upper, out.count < limit {
            guard let size32 = readU32(data, cursor), let type = fourCC(data, cursor + 4) else { break }
            var size = Int(size32)
            var header = 8
            if size32 == 1 {
                guard cursor + 16 <= upper, let size64 = readU64(data, cursor + 8),
                      size64 <= UInt64(Int.max) else { break }
                size = Int(size64)
                header = 16
            } else if size32 == 0 {
                size = upper - cursor
            }
            guard size >= header, cursor + size <= upper else { break }
            out.append(Box(type: type, offset: Int64(cursor), size: Int64(size), header: Int64(header)))
            cursor += size
        }
        return out
    }

    static func children(of box: Box, in data: Data) -> [Box] {
        boxes(in: data, from: Int(box.offset + box.header), to: Int(box.end))
    }

    // MARK: - 轨道信息

    /// 从 moov 里解出轨道：编码 fourcc、显示尺寸、首帧样本落点、有没有 edit list。
    /// 只取 tkhd/stsd/stsz/stco 里最必要的几个字段，够诊断和定镜像长度即可。
    static func tracks(in moov: Data) -> [Track] {
        // moov 自己也是盒子：先跳过它的头，再枚举里面的 trak
        let moovHeader = (readU32(moov, 0) ?? 8) == 1 ? 16 : 8
        var result: [Track] = []
        for trak in boxes(in: moov, from: moovHeader) where trak.type == "trak" {
            let trakChildren = children(of: trak, in: moov)
            var handler = ""
            var codec = ""
            var width = 0
            var height = 0
            var firstOffset: Int64 = 0
            var firstSize: Int64 = 0
            var hasEditList = false

            if let edts = trakChildren.first(where: { $0.type == "edts" }) {
                hasEditList = children(of: edts, in: moov).contains { $0.type == "elst" }
            }

            guard let mdia = trakChildren.first(where: { $0.type == "mdia" }) else {
                result.append(Track(
                    handler: handler, codec: codec, width: width, height: height,
                    firstSampleOffset: firstOffset, firstSampleSize: firstSize, hasEditList: hasEditList
                ))
                continue
            }
            let mdiaChildren = children(of: mdia, in: moov)
            if let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }) {
                handler = fourCC(moov, Int(hdlr.offset) + 16) ?? "?"
            }
            if let minf = mdiaChildren.first(where: { $0.type == "minf" }),
               let stbl = children(of: minf, in: moov).first(where: { $0.type == "stbl" }) {
                let stblChildren = children(of: stbl, in: moov)
                if let stsd = stblChildren.first(where: { $0.type == "stsd" }) {
                    let base = Int(stsd.offset)
                    codec = fourCC(moov, base + 20) ?? "?"
                    width = Int(readU16(moov, base + 48) ?? 0)
                    height = Int(readU16(moov, base + 50) ?? 0)
                }
                if let stsz = stblChildren.first(where: { $0.type == "stsz" }) {
                    let base = Int(stsz.offset)
                    let fixed = readU32(moov, base + 12) ?? 0
                    firstSize = fixed != 0 ? Int64(fixed) : Int64(readU32(moov, base + 20) ?? 0)
                }
                if let stco = stblChildren.first(where: { $0.type == "stco" }) {
                    firstOffset = Int64(readU32(moov, Int(stco.offset) + 16) ?? 0)
                } else if let co64 = stblChildren.first(where: { $0.type == "co64" }) {
                    firstOffset = Int64(bitPattern: readU64(moov, Int(co64.offset) + 16) ?? 0)
                }
            }

            result.append(Track(
                handler: handler, codec: codec, width: width, height: height,
                firstSampleOffset: firstOffset, firstSampleSize: firstSize, hasEditList: hasEditList
            ))
        }
        return result
    }

    // MARK: - 字节工具

    static func readU32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return data.withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    static func readU16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return data.withUnsafeBytes {
            UInt16(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }

    static func readU64(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        return data.withUnsafeBytes {
            UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }

    static func fourCC(_ data: Data, _ offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        let bytes = [data[base], data[base + 1], data[base + 2], data[base + 3]]
        return String(bytes: bytes, encoding: .isoLatin1)
    }
}
