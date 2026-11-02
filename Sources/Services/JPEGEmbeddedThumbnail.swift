import UIKit

/// 从 JPEG 的 EXIF 里取那张**内嵌缩略图**（IFD1 的 `JPEGInterchangeFormat`）。
///
/// 手机、相机拍的照片几乎都在 APP1 段里带一张 160~480 的预览图。一张 8 MB 的照片，
/// 只读**头部 256 KB** 就能出图，不用把整份拉下来 —— 这是「照片目录慢」的大头
/// （Android 端优化说明第 4 节，实测把首屏从「几十张串行」压到「一轮往返就出图」）。
///
/// **为什么自己解析段、不用 `CGImageSourceCreateIncremental`**：
/// 增量源在数据不完整时，`kCGImageSourceCreateThumbnailFromImageAlways` 会「成功」返回
/// 一张上半截正常、下半截灰的残图 —— 1.0.5 就是这么把残图写进缓存的。
/// 只解 IFD1 指向的那一段**独立 JPEG**，则绝无可能出残图：那段数据本身是完整的。
///
/// 任何一步解析不出来都返回 `nil`，调用方回退到「整份读」。绝不让「省流量」变成「没图」。
enum JPEGEmbeddedThumbnail {
    /// 解出来的缩略图长边小于这个值就放弃（480 的格子里放 160×120 会糊成一团）
    static let minimumPixel: CGFloat = 320

    /// - Parameter data: 文件头部若干字节（建议 256 KB，EXIF APP1 段最大 64 KB）
    /// - Parameter maxPixel: 输出长边上限
    static func image(fromHeader data: Data, maxPixel: Int) -> UIImage? {
        // 拷贝成 0 基索引的 Data：调用方可能传的是 `prefix(_:)` 切片
        let bytes = Data(data)
        guard let tiff = app1TIFFStart(in: bytes) else { return nil }
        guard let thumbnail = thumbnailRange(in: bytes, tiffStart: tiff) else { return nil }

        let jpeg = bytes.subdata(in: thumbnail)
        guard jpeg.count > 4, jpeg[jpeg.startIndex] == 0xFF, jpeg[jpeg.startIndex + 1] == 0xD8 else {
            return nil
        }
        guard let image = ImageDownsampler.downsample(data: jpeg, maxPixel: maxPixel) else { return nil }
        let longEdge = max(image.size.width, image.size.height) * image.scale
        guard longEdge >= minimumPixel else { return nil }
        return image
    }

    // MARK: - 找 APP1

    /// 扫 JPEG 段，找到以 `Exif\0\0` 开头的 APP1，返回其后 TIFF header 的偏移。
    private static func app1TIFFStart(in data: Data) -> Int? {
        guard data.count > 4, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        var index = 2
        while index + 4 <= data.count {
            guard data[index] == 0xFF else { return nil }
            let marker = data[index + 1]

            // 不带长度的标记（填充、RSTn、SOI）
            if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
                index += 2
                continue
            }
            // SOS 之后是压缩数据，EXIF 不可能在后面；EOI 直接结束
            if marker == 0xDA || marker == 0xD9 { return nil }

            let length = Int(data[index + 2]) << 8 | Int(data[index + 3])
            guard length >= 2 else { return nil }
            let payload = index + 4
            let end = payload + length - 2
            // 头部没读全（段超出这次读到的字节）—— 说明 APP1 不在这段里，放弃
            guard end <= data.count else { return nil }

            if marker == 0xE1, end - payload >= 6,
               data[payload] == 0x45, data[payload + 1] == 0x78,
               data[payload + 2] == 0x69, data[payload + 3] == 0x66,
               data[payload + 4] == 0x00, data[payload + 5] == 0x00 {
                return payload + 6
            }
            index = end
        }
        return nil
    }

    // MARK: - 读 IFD1 的缩略图区间

    /// IFD0 里没有缩略图信息，真正的指针在 IFD1（IFD0 的 next IFD）。
    private static func thumbnailRange(in data: Data, tiffStart: Int) -> Range<Int>? {
        guard tiffStart >= 0, tiffStart + 8 <= data.count else { return nil }

        let little: Bool
        if data[tiffStart] == 0x49, data[tiffStart + 1] == 0x49 {
            little = true
        } else if data[tiffStart] == 0x4D, data[tiffStart + 1] == 0x4D {
            little = false
        } else {
            return nil
        }

        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= data.count else { return nil }
            let a = Int(data[offset])
            let b = Int(data[offset + 1])
            return little ? (a | b << 8) : (a << 8 | b)
        }

        func u32(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let b0 = Int(data[offset])
            let b1 = Int(data[offset + 1])
            let b2 = Int(data[offset + 2])
            let b3 = Int(data[offset + 3])
            return little
                ? (b0 | b1 << 8 | b2 << 16 | b3 << 24)
                : (b0 << 24 | b1 << 16 | b2 << 8 | b3)
        }

        // TIFF header: "II"/"MM" + 42 + IFD0 偏移
        guard u16(tiffStart + 2) == 0x002A, let ifd0Offset = u32(tiffStart + 4) else { return nil }
        guard let ifd0 = add(tiffStart, ifd0Offset), let count0 = u16(ifd0) else { return nil }

        // IFD0 末尾 4 字节 = IFD1 偏移
        guard let ifd1Offset = u32(ifd0 + 2 + count0 * 12), ifd1Offset != 0 else { return nil }
        guard let ifd1 = add(tiffStart, ifd1Offset), let count1 = u16(ifd1), count1 > 0 else { return nil }

        var offset = 0
        var length = 0
        for index in 0..<count1 {
            let entry = ifd1 + 2 + index * 12
            guard let tag = u16(entry) else { return nil }
            // 0x0201 JPEGInterchangeFormat / 0x0202 JPEGInterchangeFormatLength
            if tag == 0x0201 {
                offset = u32(entry + 8) ?? 0
            } else if tag == 0x0202 {
                length = u32(entry + 8) ?? 0
            }
        }
        guard offset > 0, length > 0 else { return nil }
        guard let start = add(tiffStart, offset) else { return nil }
        let end = start + length
        guard end <= data.count else { return nil }
        return start..<end
    }

    private static func add(_ base: Int, _ delta: Int) -> Int? {
        guard base >= 0, delta >= 0, base <= Int.max - delta else { return nil }
        return base + delta
    }
}
