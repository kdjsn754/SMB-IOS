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
    /// 本地镜像 / 流式资产通用：先顺序解码第一帧，失败再按时间取帧
    static func firstFrame(from asset: AVURLAsset) async -> (image: UIImage?, error: String) {
        let byReader = await readerFrame(from: asset)
        if let image = byReader.image { return (image, "") }

        let byGenerator = await generatorFrame(from: asset)
        if let image = byGenerator.image { return (image, "") }

        var text = byReader.error
        if !byGenerator.error.isEmpty {
            text = text.isEmpty ? byGenerator.error : "\(text) / \(byGenerator.error)"
        }
        return (nil, text)
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
