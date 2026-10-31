import UIKit
import ImageIO

/// 把任意图片（JPEG / PNG / HEIC / BMP / TIFF …）缩到指定长边。
///
/// 两条路：
/// 1. `CGImageSourceCreateThumbnailAtIndex`：ImageIO 直接出缩略图，不用把整张图解码进内存；
/// 2. 失败就整张解码再缩放 —— BMP / TIFF 这类格式走的就是这里。
enum ImageDownsampler {
    // MARK: - 从内存数据

    static func downsample(data: Data, maxPixel: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        return downsample(source: source, maxPixel: maxPixel)
    }

    static func decodeAndScale(data: Data, maxPixel: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        return decodeAndScale(source: source, maxPixel: maxPixel)
    }

    // MARK: - 从文件（大图用：不会同时压着 Data 和解码位图）

    static func downsample(url: URL, maxPixel: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        return downsample(source: source, maxPixel: maxPixel)
    }

    static func decodeAndScale(url: URL, maxPixel: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        return decodeAndScale(source: source, maxPixel: maxPixel)
    }

    // MARK: - 共用实现

    private static func downsample(source: CGImageSource, maxPixel: Int) -> UIImage? {
        if let image = thumbnail(source: source, maxPixel: maxPixel) {
            return image
        }
        // 兜底：BMP / TIFF 这类格式不支持 ImageIO 的缩略图生成路径，
        // 直接完整解码再缩放。只有在前一步失败时才会走到这里，不影响常规 JPEG/PNG。
        return decodeAndScale(source: source, maxPixel: maxPixel)
    }

    /// ImageIO 缩略图路径：不会把整张图解码进内存
    private static func thumbnail(source: CGImageSource, maxPixel: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// 完整解码后按长边缩放。用于 BMP / TIFF 等 ImageIO 不支持缩略图生成的格式。
    static func decodeAndScale(source: CGImageSource, maxPixel: Int) -> UIImage? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let decodeOptions: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions as CFDictionary) else {
            return nil
        }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }

        let ratio = min(1, CGFloat(maxPixel) / max(width, height))
        let target = CGSize(
            width: max(1, (width * ratio).rounded()),
            height: max(1, (height * ratio).rounded())
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        // 不要 alpha 通道：BMP 常见 32 位且 alpha 全为 0，带 alpha 画出会变成全透明（看起来全黑）
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { renderer in
            let context = renderer.cgContext
            // .copy 直接把源 RGB 写进目标，alpha 一律强制为不透明，避免上面那个坑
            context.setBlendMode(.copy)
            context.draw(cgImage, in: CGRect(origin: .zero, size: target))
            context.setBlendMode(.normal)
        }
    }
}
