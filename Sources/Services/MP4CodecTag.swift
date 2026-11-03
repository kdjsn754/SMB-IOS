import Foundation

/// 视频采样描述的「编码标签」修正 + iOS 能不能解的判断。
///
/// HEVC 在 MP4 里有两种写法：
/// - `hvc1`：参数集（VPS/SPS/PPS）放在 `hvcC` 里，码流内不再重复 —— **Apple 的解复用器只认这个**；
/// - `hev1`：参数集可以只写在码流里。
///
/// x265 / ffmpeg 直接封装时默认写 `hev1`。这类文件结构完全正常（moov、样本表、hvcC 里的
/// 参数集都齐），但 AVFoundation 既不报「不支持」也不给画面：播放黑屏、抽帧拿不到帧。
/// 用户看到的就是「同一个目录只有这几个视频全灰，点开也是黑的」（实测 1.6.1：572 个视频里
/// 只有 3 个是 `hev1`，恰好就是报障的那 3 个）。
///
/// 修法和 `ffmpeg -tag:v hvc1` 完全等价：**只把 moov 里 stsd 采样描述的四个字节从 `hev1`
/// 改成 `hvc1`，一个码流字节都不动**。前提是 `hvcC` 里已经带着参数集（x265 产出的都有）。
/// 播放（`SMBAssetLoader`）、流式抽帧、镜像抽帧三条路各自在自己的字节流上做这个替换。
///
/// 顺带读 `hvcC` 里的色度格式：iOS 的 HEVC 解码器只有 4:2:0 —— `4:2:2` / `4:4:4`
/// （x265 的 lossless / 高保真预设会产出）改标签也解不了，只能如实告诉用户去转码。
struct VideoCodecProbe: Sendable {
    /// 视频采样描述的 fourcc（`avc1` / `hev1` / `hvc1` / `mp4v` …）
    let codec: String
    /// `hvcC` 里声明的色度格式：1 = 4:2:0，2 = 4:2:2，3 = 4:4:4，0 = 没读到
    let chroma: Int
    /// 需要改写的 `hev1` fourcc 偏移（文件内绝对偏移）
    let patchOffsets: [Int64]

    static let empty = VideoCodecProbe(codec: "", chroma: 0, patchOffsets: [])

    var isEmpty: Bool { codec.isEmpty }

    /// iOS 上没有解码器的组合：HEVC 4:2:2 / 4:4:4。
    /// 这两种改标签也没用 —— 与其让用户对着黑屏等，不如直接说清楚。
    var isUndecodableOnIOS: Bool {
        guard codec == "hev1" || codec == "hvc1" else { return false }
        return chroma >= 2
    }

    /// 一句人话，用于播放失败提示和诊断
    var unsupportedDescription: String {
        let chromaText = chroma == 3 ? "4:4:4" : (chroma == 2 ? "4:2:2" : "HEVC")
        return "HEVC \(chromaText)"
    }

    /// 把 `data`（从文件偏移 `base` 开始的一段字节）里落在 patch 位置上的 `hev1` 换成 `hvc1`。
    /// 没命中就原样返回（播放时每 1 MB 都要过一遍这里，不能无谓复制）。
    func applyingPatch(to data: Data, base: Int64) -> Data {
        guard !patchOffsets.isEmpty else { return data }
        var out: Data?
        for offset in patchOffsets {
            let local = Int(offset - base)
            guard local >= 0, local + 4 <= data.count else { continue }
            // 只在确实读到 "hev1" 时才改：偏移算错时也不会把别的字节写坏
            guard MP4Inspector.fourCC(data, local) == "hev1" else { continue }
            if out == nil { out = data }
            out?.replaceSubrange(local..<(local + 4), with: MP4CodecTag.hvc1Bytes)
        }
        return out ?? data
    }
}

enum MP4CodecTag {
    static let hev1Bytes = Array("hev1".utf8)
    static let hvc1Bytes = Array("hvc1".utf8)
    private static let hvcC = Data("hvcC".utf8)

    /// moov 读进内存的上限（和镜像一致）
    private static let maxMoovSize: Int64 = 8 * 1024 * 1024
    /// 顶层盒子探测上限（分片文件盒子多，别无限往后翻）
    private static let maxBoxProbe = 32

    // MARK: - moov 解析

    /// 从完整的 moov 里读出视频采样描述。`base` 是这份 moov 在文件里的起始偏移，
    /// 返回的 `patchOffsets` 已经是文件内的绝对偏移。
    ///
    /// 只看 `vide` 轨道：音频轨（`mp4a`）的 stsd 也在同一个 moov 里，
    /// 混进来会把编码名认成音频的。
    static func analyze(moov: Data, base: Int64) -> VideoCodecProbe {
        guard moov.count >= 8 else { return .empty }
        let moovHeader = (MP4Inspector.readU32(moov, 0) ?? 8) == 1 ? 16 : 8

        var codec = ""
        var chroma = 0
        var offsets: [Int64] = []

        for trak in MP4Inspector.boxes(in: moov, from: moovHeader) where trak.type == "trak" {
            let trakChildren = MP4Inspector.children(of: trak, in: moov)
            guard let mdia = trakChildren.first(where: { $0.type == "mdia" }) else { continue }
            let mdiaChildren = MP4Inspector.children(of: mdia, in: moov)
            guard let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }),
                  MP4Inspector.fourCC(moov, Int(hdlr.offset) + 16) == "vide",
                  let minf = mdiaChildren.first(where: { $0.type == "minf" }),
                  let stbl = MP4Inspector.children(of: minf, in: moov).first(where: { $0.type == "stbl" }),
                  let stsd = MP4Inspector.children(of: stbl, in: moov).first(where: { $0.type == "stsd" })
            else { continue }

            let entryCount = Int(MP4Inspector.readU32(moov, Int(stsd.offset) + 12) ?? 0)
            var cursor = Int(stsd.offset) + 16
            let end = Int(stsd.end)

            for _ in 0..<max(0, entryCount) {
                guard cursor + 8 <= end, let size = MP4Inspector.readU32(moov, cursor) else { break }
                let entrySize = Int(size)
                guard entrySize >= 8, cursor + entrySize <= end else { break }

                let entryType = MP4Inspector.fourCC(moov, cursor + 4) ?? ""
                if codec.isEmpty { codec = entryType }
                if entryType == "hev1" {
                    offsets.append(base + Int64(cursor + 4))
                }
                // 只有 HEVC 的采样描述带 hvcC；avc1 没有等价字段，色度保持 0
                if chroma == 0, entryType == "hev1" || entryType == "hvc1" {
                    chroma = chromaFormat(in: moov, entryStart: cursor, entryEnd: cursor + entrySize)
                }
                cursor += entrySize
            }
        }

        return VideoCodecProbe(codec: codec, chroma: chroma, patchOffsets: offsets)
    }

    /// 在采样描述内部找 `hvcC`，读它声明的色度格式。
    ///
    /// 直接按字节找子盒而不是硬算 VisualSampleEntry 的 78 字节固定长度：
    /// 各种 muxer 写的字段长度一致，但这么找不怕将来多出别的变体，
    /// 而且一个采样描述只有几百字节到几 KB，找一次的成本可以忽略。
    private static func chromaFormat(in moov: Data, entryStart: Int, entryEnd: Int) -> Int {
        let start = min(entryStart + 8, moov.count)
        let end = min(entryEnd, moov.count)
        guard start < end, let range = moov.range(of: hvcC, in: start..<end) else { return 0 }
        // hvcC 记录里第 16 个字节是 chromaFormat（低 2 位有效）
        let index = range.lowerBound + 4 + 16
        guard index < end else { return 0 }
        return Int(moov[index] & 0x03)
    }

    // MARK: - 远端探测

    private static let cacheLock = NSLock()
    private static var cache: [String: VideoCodecProbe] = [:]
    private static var cacheOrder: [String] = []
    private static let cacheLimit = 400

    /// 拼缓存键：连接 + 路径 + 大小。同一路径换个文件会重探，不会张冠李戴。
    private static func cacheKey(_ connection: SMBConnection, _ path: String, _ fileSize: Int64) -> String {
        "\(UInt(bitPattern: ObjectIdentifier(connection)))|\(path)|\(fileSize)"
    }

    static func cachedProbe(
        connection: SMBConnection,
        path: String,
        fileSize: Int64
    ) -> VideoCodecProbe? {
        let key = cacheKey(connection, path, fileSize)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    /// 把已经解析过的结果记进缓存（镜像路径手上就有 moov，顺手记下，
    /// 用户点开播放时不用再探测一次）。
    static func remember(
        _ probe: VideoCodecProbe,
        connection: SMBConnection,
        path: String,
        fileSize: Int64
    ) {
        guard !probe.isEmpty else { return }
        let key = cacheKey(connection, path, fileSize)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = probe
        while cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    /// 读远端文件的 moov 做一次探测（结果按「连接 + 路径 + 大小」缓存）。
    ///
    /// 探测失败**不缓存**：网络抖一下就把这个文件永久记成「没问题」，
    /// 用户下次还是黑屏，且再也不会重试。
    static func probe(
        connection: SMBConnection,
        path: String,
        fileSize: Int64,
        cancel: CancellationBox? = nil
    ) async -> VideoCodecProbe {
        guard fileSize > 8, cancel?.isCancelled != true else { return .empty }
        if let hit = cachedProbe(connection: connection, path: path, fileSize: fileSize) {
            return hit
        }
        guard let moov = await locateMoov(
            connection: connection, path: path, fileSize: fileSize, cancel: cancel
        ), moov.size >= 8, moov.size <= maxMoovSize else { return .empty }

        guard let data = try? await connection.thumbRead(
            path, offset: moov.offset, length: Int(moov.size), lane: .video, cancel: cancel
        ), Int64(data.count) == moov.size else { return .empty }

        let probe = analyze(moov: data, base: moov.offset)
        remember(probe, connection: connection, path: path, fileSize: fileSize)
        return probe
    }

    /// 顺着顶层盒子找 moov（只读 16 字节的头，读到 moov 才整段读）
    private static func locateMoov(
        connection: SMBConnection,
        path: String,
        fileSize: Int64,
        cancel: CancellationBox?
    ) async -> (offset: Int64, size: Int64)? {
        var offset: Int64 = 0
        var probes = 0
        while offset + 8 <= fileSize, probes < maxBoxProbe {
            probes += 1
            guard let head = try? await connection.thumbRead(
                path, offset: offset, length: 16, lane: .video, cancel: cancel
            ), head.count >= 8,
                let size32 = MP4Inspector.readU32(head, 0),
                let type = MP4Inspector.fourCC(head, 4)
            else { return nil }

            var size = Int64(size32)
            var header: Int64 = 8
            if size32 == 1 {
                guard head.count >= 16, let size64 = MP4Inspector.readU64(head, 8),
                      size64 <= UInt64(Int.max) else { return nil }
                size = Int64(size64)
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

    // MARK: - 本地文件修正

    /// 本地文件补标签的结果。
    ///
    /// 光「调用过 patch」不代表改成功：文件被别人占着、盘满、偏移算错都会静默失败，
    /// 而失败的后果是——播放黑屏、有声音、不报错。所以改完必须回读确认。
    struct LocalTagResult {
        let probe: VideoCodecProbe
        /// 需要改的都确实改成 `hvc1` 了（本来不需要改也算成功）
        let applied: Bool
    }

    /// 落盘 / 播放前统一走这里：补标签，然后回读那四个字节确认。
    ///
    /// - Returns: `nil` 表示压根没读到 moov（不是标准 MP4 / 文件不可读）。
    static func ensureLocalTag(at url: URL) -> LocalTagResult? {
        guard let probe = patchLocalFile(at: url) else { return nil }
        guard !probe.patchOffsets.isEmpty else {
            return LocalTagResult(probe: probe, applied: true)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return LocalTagResult(probe: probe, applied: false)
        }
        defer { try? handle.close() }
        for offset in probe.patchOffsets {
            guard let bytes = try? handle.readBytes(at: offset, count: 4),
                  MP4Inspector.fourCC(bytes, 0) == "hvc1"
            else { return LocalTagResult(probe: probe, applied: false) }
        }
        return LocalTagResult(probe: probe, applied: true)
    }

    /// 下载到本地的文件就地修正：把 stsd 里的 `hev1` 换成 `hvc1`。
    ///
    /// 远端播放要经过 `SMBAssetLoader`，那里每个回给 AVFoundation 的分块都会过一遍
    /// `applyingPatch`；但「下载到本地再播」走的是 `AVPlayerItem(url:)`，字节从磁盘直接
    /// 进解复用器，**不经过加载器** —— 所以必须在落盘之后改文件本身，否则下载完照样黑屏。
    ///
    /// 只读 moov 那一小段（几十 KB 到几 MB），改的也只是四个字节，不做任何转码。
    /// - Returns: 探测结果；找不到 moov 时返回 nil，文件保持原样。
    @discardableResult
    static func patchLocalFile(at url: URL) -> VideoCodecProbe? {
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 8 else { return nil }

        var offset: Int64 = 0
        var probes = 0
        var moov: (offset: Int64, size: Int64)?

        while offset + 8 <= Int64(fileSize), probes < maxBoxProbe {
            probes += 1
            guard let head = try? handle.readBytes(at: offset, count: 16), head.count >= 8,
                  let size32 = MP4Inspector.readU32(head, 0),
                  let type = MP4Inspector.fourCC(head, 4)
            else { return nil }

            var size = Int64(size32)
            var header: Int64 = 8
            if size32 == 1 {
                guard head.count >= 16, let size64 = MP4Inspector.readU64(head, 8),
                      size64 <= UInt64(Int64.max) else { return nil }
                size = Int64(size64)
                header = 16
            } else if size32 == 0 {
                size = Int64(fileSize) - offset
            }
            guard size >= header else { return nil }
            if type == "moov" {
                moov = (offset, size)
                break
            }
            offset += size
        }

        guard let moov, moov.size >= 8, moov.size <= maxMoovSize,
              let data = try? handle.readBytes(at: moov.offset, count: Int(moov.size))
        else { return nil }

        let probe = analyze(moov: data, base: moov.offset)
        for patch in probe.patchOffsets {
            // 只在那个位置确实是 "hev1" 时才写，偏移算错也不会把别的字节改坏
            guard let current = try? handle.readBytes(at: patch, count: 4),
                  MP4Inspector.fourCC(current, 0) == "hev1"
            else { continue }
            try? handle.seek(toOffset: UInt64(patch))
            try? handle.write(contentsOf: Data(hvc1Bytes))
        }
        return probe
    }
}

private extension FileHandle {
    /// 从指定偏移读一段（不改变调用方关心的「当前偏移」语义，读完偏移停在末尾）
    func readBytes(at offset: Int64, count: Int) throws -> Data {
        try seek(toOffset: UInt64(offset))
        return try read(upToCount: count) ?? Data()
    }
}
