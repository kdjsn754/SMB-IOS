import Foundation
import AMSMB2

enum SMBFailure: LocalizedError {
    case badConfiguration
    case cannotConnect(String)
    case operation(String)

    var errorDescription: String? {
        switch self {
        case .badConfiguration:
            return "服务器配置不完整，请检查主机地址与共享名称。"
        case .cannotConnect(let message):
            return "无法连接共享：\(message)"
        case .operation(let message):
            return message
        }
    }
}

/// 每个服务器对应一个连接对象，内部由 AMSMB2 管理线程安全
actor SMBConnection {
    private let server: SMBServer
    private let password: String

    private var manager: SMB2Manager?
    private var connecting: Task<SMB2Manager, Error>?

    // MARK: - 缩略图专用会话（3 条独立 socket）

    /// 缩略图通道数。文档（Android 端实测）给的是 3：4 条以上时部分群晖 / 路由器共享
    /// 会开始回 `STATUS_INSUFFICIENT_RESOURCES`，3 条已经把「小文件往返延迟」这张网织密。
    private static let thumbnailChannelCount = 3
    private var thumbnailManagers: [SMB2Manager?] = [nil, nil, nil]
    private var thumbnailConnecting: [Int: Task<SMB2Manager, Error>] = [:]
    private var thumbnailCursor = 0

    init(server: SMBServer, password: String) {
        self.server = server
        self.password = password
    }

    var serverID: UUID { server.id }

    // MARK: - 连接

    func connect() async throws -> SMB2Manager {
        if let manager { return manager }
        if let connecting { return try await connecting.value }

        let server = self.server
        let password = self.password
        let task = Task<SMB2Manager, Error> {
            try await SMBConnection.makeManager(server: server, password: password)
        }
        connecting = task

        do {
            let manager = try await task.value
            self.manager = manager
            self.connecting = nil
            return manager
        } catch {
            self.connecting = nil
            throw error
        }
    }

    private static func makeManager(server: SMBServer, password: String) async throws -> SMB2Manager {
        guard let url = server.baseURL else { throw SMBFailure.badConfiguration }
        let credential = URLCredential(user: server.username, password: password, persistence: .forSession)
        guard let manager = SMB2Manager(url: url, domain: server.domain, credential: credential) else {
            throw SMBFailure.badConfiguration
        }
        manager.timeout = 30
        do {
            try await manager.connectShare(name: server.share)
        } catch {
            throw SMBFailure.cannotConnect(describe(error))
        }
        return manager
    }

    /// 执行一次操作；失败时丢弃连接，下一次操作会自动重连
    private func run<T>(_ body: (SMB2Manager) async throws -> T) async throws -> T {
        let manager = try await connect()
        do {
            return try await body(manager)
        } catch {
            self.manager = nil
            let message = Self.describe(error)
            // 记一步轨迹：这类失败往往紧接着就是「进程没了」，事后能对上时间
            DiagnosticsStore.shared.note("SMB 操作失败：\(message)")
            throw SMBFailure.operation(message)
        }
    }

    func disconnect() async {
        if let manager {
            try? await manager.disconnectShare()
            self.manager = nil
        }
        for thumbnail in thumbnailManagers {
            try? await thumbnail?.disconnectShare()
        }
        thumbnailManagers = [nil, nil, nil]
        thumbnailConnecting = [:]
    }

    /// 作废当前连接（回前台时调用）。
    ///
    /// 只置空引用，**不** `disconnectShare()`：那条调用要往 socket 上写数据，而 socket
    /// 很可能已经在后台期间被对端回收，正好会触发 SIGPIPE。置空引用后，
    /// 下一次操作走 `connect()` 重建，AMSMB2 对象释放时自己会关掉旧 fd。
    func invalidate() {
        manager = nil
        connecting = nil
        thumbnailManagers = [nil, nil, nil]
        thumbnailConnecting = [:]
    }

    // MARK: - 缩略图读取（3 条独立会话）

    /// 读缩略图 / 照片头部这类小文件的字节，走**独立的 3 条会话**，不和列目录、播放抢同一条连接。
    ///
    /// 为什么不是「一条连接上并发三个读」：一条 TCP 只有一条接收流水线，多个文件的响应
    /// 只能排队到达。而缩略图这种百 KB 级文件的耗时几乎全是往返延迟（WiFi 下 3~5 ms / 次），
    /// 只有让多个请求**同时在飞**，把几十次往返重叠起来，目录才会一批一批地出图
    /// （Android 端把这叫 THUMB 通道，见优化说明第 2、3 节）。
    ///
    /// 失败时只作废这一条通道，主连接（列目录 / 播放）不受影响。
    func thumbRead(_ path: String, offset: Int64, length: Int, cancel: CancellationBox? = nil) async throws -> Data {
        guard length > 0, offset >= 0 else { return Data() }
        let start = UInt64(offset)
        let end = start &+ UInt64(length)
        let index = nextThumbnailChannel()

        let manager: SMB2Manager
        do {
            manager = try await thumbnailManager(at: index)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 建不起独立会话（个别服务器限制同账号并发连接）：退回主连接。
            // 功能不能丢，只是拿不到并发收益 —— 绝不能因为「多开一条连接」让缩略图全不加载。
            thumbnailManagers[index] = nil
            return try await transfer(path: path, range: start..<end, cancel: cancel)
        }

        do {
            let data: Data = try await manager.contents(
                atPath: path,
                range: start..<end,
                progress: { _, _ in !(cancel?.isCancelled ?? false) }
            )
            if cancel?.isCancelled == true { throw CancellationError() }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if cancel?.isCancelled == true { throw CancellationError() }
            // 只作废这一条通道；主连接（列目录 / 播放）不受影响
            self.thumbnailManagers[index] = nil
            throw SMBFailure.operation(Self.describe(error))
        }
    }

    /// 三条通道轮询取用。并发 3 时正好一条一个，不会都挤在同一个 socket 上。
    private func nextThumbnailChannel() -> Int {
        let index = thumbnailCursor % Self.thumbnailChannelCount
        thumbnailCursor = (thumbnailCursor + 1) % Self.thumbnailChannelCount
        return index
    }

    /// 懒建会话：第一条通道还没建好时，后面两条会各自并行建，不会串成一队。
    private func thumbnailManager(at index: Int) async throws -> SMB2Manager {
        if let manager = thumbnailManagers[index] { return manager }
        if let task = thumbnailConnecting[index] { return try await task.value }

        let server = self.server
        let password = self.password
        let task = Task<SMB2Manager, Error> {
            try await SMBConnection.makeManager(server: server, password: password)
        }
        thumbnailConnecting[index] = task

        do {
            let manager = try await task.value
            self.thumbnailManagers[index] = manager
            self.thumbnailConnecting[index] = nil
            return manager
        } catch {
            self.thumbnailConnecting[index] = nil
            throw error
        }
    }

    // MARK: - 目录与文件

    func listDirectory(_ path: String) async throws -> [FileItem] {
        try await run { manager in
            let entries = try await manager.contentsOfDirectory(atPath: path)
            return entries.compactMap { FileItem(dictionary: $0, parentPath: path) }
        }
    }

    func fileSize(_ path: String) async throws -> Int64 {
        try await run { manager in
            let attributes = try await manager.attributesOfItem(atPath: path)
            return Self.number(from: attributes[.fileSizeKey])
        }
    }

    /// 读取整个文件。只用于图片预览这类必须完整解码的场景，调用方要自己控制频率。
    func readAll(_ path: String, cancel: CancellationBox? = nil) async throws -> Data {
        try await transfer(path: path, range: nil, cancel: cancel)
    }

    /// 按区间读取，供视频流式播放与缩略图使用。
    ///
    /// - Parameter cancel: 置位后底层传输会在下一个数据块返回时中止，并抛出 `CancellationError`。
    ///   中止不会破坏 SMB 会话，只有真正的 I/O 错误才会重建连接。
    func read(_ path: String, offset: Int64, length: Int, cancel: CancellationBox? = nil) async throws -> Data {
        guard length > 0, offset >= 0 else { return Data() }
        let start = UInt64(offset)
        let end = start &+ UInt64(length)
        return try await transfer(path: path, range: start..<end, cancel: cancel)
    }

    private func transfer(path: String, range: Range<UInt64>?, cancel: CancellationBox?) async throws -> Data {
        let manager = try await connect()
        do {
            let data: Data = try await manager.contents(
                atPath: path,
                range: range,
                progress: { _, _ in !(cancel?.isCancelled ?? false) }
            )
            if cancel?.isCancelled == true { throw CancellationError() }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 被取消导致的「半截数据」不算故障，不要把会话扔掉重建
            if cancel?.isCancelled == true { throw CancellationError() }
            self.manager = nil
            throw SMBFailure.operation(Self.describe(error))
        }
    }

    /// 下载到本地（用于「下载后播放」兜底方案）
    func download(_ path: String, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        try await run { manager in
            try await manager.downloadItem(atPath: path, to: url, progress: { received, total in
                if total > 0 {
                    progress(min(1, max(0, Double(received) / Double(total))))
                }
                return true
            })
        }
    }

    // MARK: - 辅助

    private static func number(from value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? UInt64 { return Int64(clamping: value) }
        return 0
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? SMBFailure {
            return failure.errorDescription ?? "未知错误"
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch Int32(nsError.code) {
            case ECONNREFUSED:
                return "连接被拒绝，请确认 IP 与端口是否正确"
            case ETIMEDOUT:
                return "连接超时，请确认设备与服务器在同一网络"
            case EHOSTUNREACH, ENETUNREACH:
                return "网络不可达，请检查网络连接"
            case EACCES, EPERM:
                return "没有访问权限，请检查账号与密码"
            case ENOENT:
                return "文件或目录不存在"
            case ENOTDIR:
                return "目标不是目录"
            case EIO:
                return "读写失败（I/O 错误）"
            case EPIPE:
                // 后台回来最常见的错误：连接在挂起期间被对端关掉了。
                // 我们已全局忽略 SIGPIPE（见 `DiagnosticsStore.installHandlers`），
                // 所以这里只是普通失败，丢弃连接后下一次会自动重连。
                return "连接已断开，正在重新连接"
            case 80:
                return "认证失败，请检查用户名、密码与域"
            default:
                return nsError.localizedDescription
            }
        }
        return nsError.localizedDescription
    }
}
