import UIKit

/// 视频封面「坏帧」检测。
///
/// Android 端实测：一批大视频用自定义数据源取出的首帧是**纯深绿** —— 解码器只写了
/// Y 平面、UV 平面全 0（UV=0 换算成 RGB 就是纯绿）。这种图一旦落进磁盘缓存就永久化了，
/// 之后每次都是绿图（见优化说明第 6 节）。
///
/// iOS 上没观察到同样的现象，但取帧路径同样是「流式资产 + 兜底解码」，
/// 落盘前花几百微秒过一遍没坏处。**只判纯绿**，不判平灰：
/// 平灰会把正常的纯色片头误杀，绿色误判的概率则极低（真实画面很难 G > R×2 且 G > B×2）。
enum ImageValidator {
    private static let grid = 16

    /// 整张图是否基本是一片绿（解码失败的特征色）
    static func isMostlyGreen(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }

        var pixels = [UInt8](repeating: 0, count: grid * grid * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // 必须用 withUnsafeMutableBytes：直接 `CGContext(data: &pixels, ...)` 传出去的指针
        // 在调用返回后就失效了，而 context 之后还会往里画 —— 典型悬垂指针。
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: grid,
                    height: grid,
                    bitsPerComponent: 8,
                    bytesPerRow: grid * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: grid, height: grid))
            return true
        }
        guard drawn else { return false }

        var greenSum = 0.0
        var greenEnough = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index])
            let g = Double(pixels[index + 1])
            let b = Double(pixels[index + 2])
            greenSum += g
            if g >= 30, g > r * 2, g > b * 2 { greenEnough += 1 }
        }

        let total = Double(grid * grid)
        let greenAverage = greenSum / total
        return greenAverage >= 25 && Double(greenEnough) >= total * 0.8
    }
}
