import Foundation
import AVFoundation
import UIKit
import CoreImage

/// 从 AVAsset 里取出「第一个画面」。
///
/// 顺序解码（`AVAssetReader`）是首选：它按样本表一路往前读，不按时间 seek，
/// 和播放器走同一条路径；`AVAssetImageGenerator` 只作兜底，因为它要按时间找样本，
/// 数据没覆盖到目标时间就直接抛 `-11821`。
enum VideoFrameDecoder {
    /// 取第一个画面。
    ///
    /// 两条路各有适用范围，按资产类型排先后：
    /// - **本地文件（镜像）**：先 `AVAssetReader` 顺序解码，失败再按时间取帧；
    /// - **流式资产（`smbstream://`）**：先走**播放器管线**（`AVPlayer` + 视频输出），
    ///   因为 App 里点开能播说明这条路一定拿得到画面；reader / generator 在
    ///   自定义资源加载器上要求按样本表随机偏移取样，取不到就直接抛 `-11821`。
    static func firstFrame(
        from asset: AVURLAsset,
        preferPlayer: Bool = false
    ) async -> (image: UIImage?, error: String) {
        var errors: [String] = []

        let steps: [Step]
        if preferPlayer {
            steps = [.player, .reader, .generator]
        } else {
            steps = [.reader, .generator, .player]
        }

        for step in steps {
            if Task.isCancelled { return (nil, "已取消") }
            let attempt: (image: UIImage?, error: String)
            switch step {
            case .player:
                attempt = await playerFrame(from: asset)
            case .reader:
                attempt = await readerFrame(from: asset)
            case .generator:
                attempt = await generatorFrame(from: asset)
            }
            if let image = attempt.image { return (image, "") }
            if !attempt.error.isEmpty {
                errors.append("\(step.label) \(shortError(attempt.error))")
            }
        }
        return (nil, errors.joined(separator: " / "))
    }

    private enum Step {
        case player, reader, generator

        var label: String {
            switch self {
            case .player: return "播放器"
            case .reader: return "顺序解码"
            case .generator: return "按时间取帧"
            }
        }
    }

    /// 播放器管线取帧：`AVPlayer` 负责把数据拉下来并解码（和 App 里播放完全同一条路），
    /// `AVPlayerItemVideoOutput` 负责把画面截下来。
    ///
    /// 这条路的代价是要「真的播一下」：静音、不接管音频会话、拿到第一帧就停。
    /// 好处是对远端资产最友好 —— 播放器会自己决定要读哪些区间，不依赖样本表的随机偏移。
    @MainActor
    static func playerFrame(from asset: AVURLAsset) async -> (image: UIImage?, error: String) {
        var transform = CGAffineTransform.identity
        if let track = (try? await asset.loadTracks(withMediaType: .video))?.first,
           let preferred = try? await track.load(.preferredTransform) {
            transform = preferred
        }

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
        ])
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        player.play()

        defer {
            player.pause()
            item.remove(output)
            player.replaceCurrentItem(with: nil)
        }

        let deadline = Date().addingTimeInterval(12)
        var waited = 0
        while Date() < deadline {
            if Task.isCancelled { return (nil, "已取消") }
            try? await Task.sleep(nanoseconds: 80_000_000)
            waited += 80
            if item.status == .failed, let error = item.error {
                let ns = error as NSError
                return (nil, "\(ns.localizedDescription)(\(ns.code))")
            }
            let time = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
               let image = makeImage(from: buffer, transform: transform) {
                return (image, "")
            }
            // 播了 4 秒还没画面、且已经有时间进度：说明起点就是黑的/只有音频，别再等了
            if waited >= 4000, item.currentTime().seconds >= 3 {
                break
            }
        }
        return (nil, "\(waited)ms 内没取到画面")
    }

    /// 顺着样本读第一个能解出画面的 sample。
    static func readerFrame(from asset: AVURLAsset) async -> (image: UIImage?, error: String) {
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return (nil, "没有视频轨道") }
            let transform = (try? await track.load(.preferredTransform)) ?? .identity

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA)
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return (nil, "reader 不接受该轨道") }
            reader.add(output)
            guard reader.startReading() else {
                let reason = reader.error?.localizedDescription ?? "未知原因"
                return (nil, "顺序解码启动失败：\(reason)")
            }
            defer { reader.cancelReading() }

            var seen = 0
            while let sample = output.copyNextSampleBuffer() {
                seen += 1
                if let buffer = CMSampleBufferGetImageBuffer(sample),
                   let image = makeImage(from: buffer, transform: transform) {
                    return (image, "")
                }
                if seen >= 8 { break }
            }
            if let error = reader.error {
                let ns = error as NSError
                return (nil, "\(ns.localizedDescription)(\(ns.code))")
            }
            return (nil, "读到 \(seen) 个样本但解不出画面")
        } catch {
            let ns = error as NSError
            return (nil, "\(ns.localizedDescription)(\(ns.code))")
        }
    }

    /// 兜底：按时间取最靠前的关键帧（容差无限，等价于「就近取第一个关键帧」）
    static func generatorFrame(from asset: AVURLAsset) async -> (image: UIImage?, error: String) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        do {
            let result = try await generator.image(at: .zero)
            return (UIImage(cgImage: result.image), "")
        } catch {
            let ns = error as NSError
            return (nil, "\(ns.localizedDescription)(\(ns.code))")
        }
    }

    // MARK: - 像素转图片

    private static let renderContext = CIContext(options: [.cacheIntermediates: false])

    /// CVPixelBuffer → UIImage：套上轨道的旋转/镜像变换，并缩到长边 480
    static func makeImage(from buffer: CVPixelBuffer, transform: CGAffineTransform) -> UIImage? {
        var image = CIImage(cvPixelBuffer: buffer)
        if !transform.isIdentity {
            image = image.transformed(by: transform)
        }
        var extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return nil }
        if extent.origin != .zero {
            image = image.transformed(
                by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
            )
            extent = image.extent
        }
        let longest = max(extent.width, extent.height)
        if longest > 480 {
            let scale = 480 / longest
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = renderContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// 把解码器的报错压缩成一行：去掉重复的域前缀，保留错误码
    static func shortError(_ error: String) -> String {
        let trimmed = error
            .replacingOccurrences(of: "The operation could not be completed. ", with: "")
            .replacingOccurrences(of: "AVFoundationErrorDomain ", with: "")
        if trimmed.count <= 40 { return trimmed }
        let head = String(trimmed.prefix(40))
        return head + "…"
    }
}
