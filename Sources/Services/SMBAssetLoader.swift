import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// 让 AVPlayer 直接从 SMB 按需读取字节，实现「不下载整个文件也能播放」
final class SMBAssetLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "smbstream"

    private let connection: SMBConnection
    private let remotePath: String
    private let fileSize: Int64
    private let contentType: String?
    private let chunkSize = 512 * 1024

    init(connection: SMBConnection, remotePath: String, fileSize: Int64, fileExtension: String) {
        self.connection = connection
        self.remotePath = remotePath
        self.fileSize = fileSize
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
            if !request.isFinished { request.finishLoading() }
            return
        }

        let offset = dataRequest.requestedOffset
        var length = dataRequest.requestedLength
        if dataRequest.requestsAllDataToEndOfResource, fileSize > offset {
            length = Int(clamping: fileSize - offset)
        }

        let available = fileSize - offset
        guard available > 0 else {
            if !request.isFinished { request.finishLoading() }
            return
        }
        let wanted = min(Int64(length), available)
        guard wanted > 0 else {
            if !request.isFinished { request.finishLoading() }
            return
        }

        let path = remotePath
        let connection = self.connection
        let chunk = chunkSize

        Task {
            do {
                var sent: Int64 = 0
                while sent < wanted {
                    if request.isCancelled { return }
                    let size = Int(min(Int64(chunk), wanted - sent))
                    let data = try await connection.read(path, offset: offset + sent, length: size)
                    if data.isEmpty { break }
                    if request.isCancelled { return }
                    dataRequest.respond(with: data)
                    sent += Int64(data.count)
                    if data.count < size { break }
                }
                if !request.isCancelled, !request.isFinished {
                    request.finishLoading()
                }
            } catch {
                if !request.isCancelled, !request.isFinished {
                    request.finishLoading(with: error)
                }
            }
        }
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
        fileExtension: String
    ) -> AVURLAsset {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let ext = fileExtension.isEmpty ? "mp4" : fileExtension
        let url = URL(string: "\(SMBAssetLoader.scheme)://media/\(token).\(ext)")
            ?? URL(string: "\(SMBAssetLoader.scheme)://media/\(token).mp4")!

        let loader = SMBAssetLoader(
            connection: connection,
            remotePath: path,
            fileSize: fileSize,
            fileExtension: ext
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
