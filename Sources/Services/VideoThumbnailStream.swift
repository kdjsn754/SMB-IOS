import Foundation
import AVFoundation
import UIKit

/// 大文件的视频封面：**不做镜像**，直接对 `smbstream://` 资产做顺序解码。
///
/// 为什么大文件不能走镜像：镜像必然把 `mdat` 截断，而 `moov` 里的样本偏移是按原始文件写的，
/// AVFoundation 一旦发现偏移越界就判「文件损坏」（`-11821`），和「首帧在不在镜像里」无关。
/// 只有把整份文件读进来才安全 —— 那对大文件不现实。
///
/// 流式读取则按样本表逐个区间要数据：只读 `moov`（可能在文件尾部）+ 第一个 GOP，
/// 流量通常比 48 MB 的镜像还小，而且没有任何截断。
enum VideoThumbnailStream {
    /// 一次抽帧允许传输的字节上限（moov 本身可能有十几兆，额度别给太紧）
    private static let byteBudget: Int64 = 96 * 1024 * 1024

    static func makeImage(
        connection: SMBConnection,
        path: String,
        fileSize: Int64,
        fileExtension: String,
        cancel: CancellationBox
    ) async -> UIImage? {
        guard fileSize > 0, !cancel.isCancelled else { return nil }
        let name = (path as NSString).lastPathComponent

        let budget = ByteBudget(limit: byteBudget)
        let asset = MediaAssetFactory.shared.makeAsset(
            connection: connection,
            path: path,
            fileSize: fileSize,
            fileExtension: fileExtension,
            budget: budget,
            cancel: cancel
        )
        defer { MediaAssetFactory.shared.release(asset) }

        // 流式资产优先走播放器管线：App 里点开能播，说明这条路拿得到画面；
        // reader / generator 在自定义资源加载器上要按样本表随机偏移取样，取不到就报 -11821
        let attempt = await VideoFrameDecoder.firstFrame(from: asset, preferPlayer: true)
        if let image = attempt.image { return image }
        if cancel.isCancelled { return nil }

        ThumbnailDiagnostics.record(
            name, "流式取帧失败 \(attempt.error)"
        )
        return nil
    }
}
