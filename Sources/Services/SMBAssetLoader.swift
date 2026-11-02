import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// 让 AVPlayer / AVAssetImageGenerator 直接从 SMB 按需读取字节，
/// 实现「不下载整个文件也能播放、也能抽封面」。
final class SMBAssetLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "smbstream"

    private let connection: SMBConnection
    private let remotePath: String
    private let fileSize: Int64
    private let contentType: String?
    private let chunkSize: Int
    /// `hev1` → `hvc1` 的标签修正。不给就原样透传（绝大多数片子都不需要改）
    private let codecProbe: VideoCodecProbe

    /// 本次资源允许传输的字节额度；`nil` 表示不限（播放用）。
    /// 生成视频封面时必须给额度，否则 AVFoundation 会一路读到文件末尾。
    private let budget: ByteBudget?
    private let cancel: CancellationBox?

    init(
        connection: SMBConnection,
        remotePath: String,
        fileSize: Int64,
        fileExtension: String,
        budget: ByteBudget? = nil,
        cancel: CancellationBox? = nil,
        codecProbe: VideoCodecProbe = .empty,
        chunkSize: Int = 1024 * 1024
    ) {
        self.connection = connection
        self.remotePath = remotePath
        self.fileSize = fileSize
        self.budget = budget
        self.cancel = cancel
        self.codecProbe = codecProbe
        self.chunkSize = max(64 * 1024, chunkSize)
        if !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) {
            self.contentType = type.identifier
        } else {
            self.contentType = nil
        }
        super.init()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        respond(to: loadingRequest)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest
    ) -> Bool {
        respond(to: renewalRequest)
        return true
    }

    private func respond(to request: AVAssetResourceLoadingRequest) {
        if let info = request.contentInformationRequest {
            if let contentType {
                info.contentType = contentType
            }
            info.contentLength = fileSize
            info.isByteRangeAccessSupported = true
        }

        guard let dataRequest = request.dataRequest else {
            Self.finish(request)
            return
        }

        if cancel?.isCancelled == true {
            Self.fail(request, CancellationError())
            return
        }

        let offset = max(0, dataRequest.requestedOffset)
        var wanted = Int64(dataRequest.requestedLength)
        if dataRequest.requestsAllDataToEndOfResource, fileSize > offset {
            wanted = fileSize - offset
        }
        // 关键修复：有额度时绝不越过额度，避免「读一帧却下整部片」
        if let budget {
            let remaining = budget.remaining()
            if remaining <= 0 {
                Self.fail(request, SMBFailure.operation("已达到本次读取上限"))
                return
            }
            // 只受总额度约束，不再把单次响应砍到 4MB。
            // 大文件的 moov 索引本身就有十几兆，被砍断后 AVFoundation 解析失败，
            // 表现就是「1GB 以上的 MP4 出不来封面」。
            wanted = min(wanted, remaining)
        }
        wanted = min(wanted, fileSize - offset)
        guard wanted > 0 else {
            Self.finish(request)
            return
        }

        let path = remotePath
        let connection = self.connection
        let chunk = chunkSize
        let budget = self.budget
        let cancel = self.cancel
        let codecProbe = self.codecProbe

        Task {
            do {
                var sent: Int64 = 0
                while sent < wanted {
                    if request.isCancelled { return }
                    if cancel?.isCancelled == true {
                        Self.fail(request, CancellationError())
                        return
                    }

                    var size = Int(min(Int64(chunk), wanted - sent))
                    if let budget {
                        let remaining = budget.remaining()
                        if remaining <= 0 { break }
                        size = Int(min(Int64(size), remaining))
                    }
                    guard size > 0 else { break }

                    // 走**视频专用缩略图通道**而不是主连接：抽帧会连着发几十个 range 请求，
                    // 挤在主连接上会和列目录 / 正在播放的视频互抢，播放端就会卡顿。
                    let data = try await connection.thumbRead(
                        path, offset: offset + sent, length: size, lane: .video, cancel: cancel
                    )
                    if data.isEmpty { break }
                    if request.isCancelled { return }
                    if cancel?.isCancelled == true {
                        Self.fail(request, CancellationError())
                        return
                    }

                    dataRequest.respond(
                        with: codecProbe.applyingPatch(to: data, base: offset + sent)
                    )
                    sent += Int64(data.count)
                    budget?.consume(Int64(data.count))
                    if data.count < size { break }
                }
                Self.finish(request)
            } catch {
                Self.fail(request, error)
            }
        }
    }

    private static func finish(_ request: AVAssetResourceLoadingRequest) {
        guard !request.isCancelled, !request.isFinished else { return }
        request.finishLoading()
    }

    private static func fail(_ request: AVAssetResourceLoadingRequest, _ error: Error) {
        guard !request.isCancelled, !request.isFinished else { return }
        request.finishLoading(with: error)
    }
}

/// 持有 loader 的强引用（AVAssetResourceLoader.delegate 是 weak），并用自定义 scheme 的 URL 关联
final class MediaAssetFactory: @unchecked Sendable {
    static let shared = MediaAssetFactory()

    private let lock = NSLock()
    private var loaders: [String: SMBAssetLoader] = [:]
    private var queues: [String: DispatchQueue] = [:]

    func makeAsset(
        connection: SMBConnection,
        path: String,
        fileSize: Int64,
        fileExtension: String,
        budget: ByteBudget? = nil,
        cancel: CancellationBox? = nil,
        codecProbe: VideoCodecProbe = .empty
    ) -> AVURLAsset {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let ext = fileExtension.isEmpty ? "mp4" : fileExtension
        let url = URL(string: "\(SMBAssetLoader.scheme)://media/\(token).\(ext)")
            ?? URL(string: "\(SMBAssetLoader.scheme)://media/\(token).mp4")!

        let loader = SMBAssetLoader(
            connection: connection,
            remotePath: path,
            fileSize: fileSize,
            fileExtension: ext,
            budget: budget,
            cancel: cancel,
            codecProbe: codecProbe
        )
        let queue = DispatchQueue(label: "com.smbviewer.asset.\(token)")

        lock.lock()
        loaders[url.absoluteString] = loader
        queues[url.absoluteString] = queue
        lock.unlock()

        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: queue)
        return asset
    }

    func release(_ asset: AVURLAsset) {
        let key = asset.url.absoluteString
        lock.lock()
        loaders[key] = nil
        queues[key] = nil
        lock.unlock()
    }
}
