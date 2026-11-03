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

    // MARK: - 缩略图通道池（8 条独立 socket，空闲优先）

    /// 缩略图通道怎么分：`0~5` 给图片（6 条，正好对应 6 并发），`6~7` 留给视频封面。
    ///
    /// 为什么视频要独占通道：视频封面要读 `moov` / 首个 GOP（几兆到几十兆）再抽帧解码，
    /// 一张封面能把照片的名额占住 2~15 s。分道之后「一屏照片里夹着几个视频」不再拖慢整屏。
    enum ThumbLane {
        case image
        case video
    }

    /// 单条通道的「一次请求」最多读多少。超过就交给 `readSegmented` 拆段并发。
    ///
    /// 单条会话内部是「发一块 → 等一块」的串行循环（libsmb2 没有 pipelining，
    /// `AMSMB2.contents` 里就是 while + 一次 `smb2_pread_async`），所以一条连接的吞吐
    /// ≈ 块大小 ÷ 往返延迟。几十兆的文件靠一条连接读，永远吃不满千兆 ——
    /// 必须切成多段、多条会话同时飞，吞吐才会叠加（libsmb2 没有 SMB Multichannel，
    /// 只能靠我们自己在应用层开多会话）。
    private static let parallelThreshold = 8 * 1024 * 1024
    /// 分段大小：4 MB 一段（≥ 2 块协商读大小，摊薄每次 open/close 的往返）
    private static let segmentBytes = 4 * 1024 * 1024
    /// 单个请求最多拆几段，和图片通道数一致
    private static let maxSegments = 6

    /// 通道被禁用后多久允许重试一次
    private static let channelRetryInterval: TimeInterval = 60
    private static let imageChannelCount = 6
    private static let videoChannelCount = 2
    private static let thumbnailChannelCount = imageChannelCount + videoChannelCount

    /// 一条通道 = 一条独立 SMB 会话。
    private struct Channel {
        var manager: SMB2Manager?
        var connecting: Task<SMB2Manager, Error>?
        /// 已被某个请求占用（一条 socket 同时只放一个 range 请求）
        var busy = false
        /// 连续失败次数：单次失败不作废（作废会触发 TCP + 认证重建，滚动时表现为忽快忽慢）
        var failures = 0
        /// 建不起会话（服务器限制并发连接数）：暂时不再试，过一会儿再给一次机会。
        /// 永久禁用很危险 —— 一次「资源不足」会让这个目录整个生命周期都只剩主连接。
        var disabled = false
        var disabledAt: Date?
    }

    /// 8 = 图片 6 + 视频 2（属性初始化器里不能用 `Self.`，所以写死数字并注明来源）
    private var channels = Array(repeating: Channel(), count: 8)
    private var channelWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var waiterSequence = 0

    /// 等待通道的取消令牌：`onCancel` 与登记之间是竞态的，靠它判断"还该不该挂上"
    private final class WaiterToken: @unchecked Sendable {
        var cancelled = false
    }

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
        for channel in channels {
            try? await channel.manager?.disconnectShare()
        }
        resetChannels()
    }

    /// 作废当前连接（回前台时调用）。
    ///
    /// 只置空引用，**不** `disconnectShare()`：那条调用要往 socket 上写数据，而 socket
    /// 很可能已经在后台期间被对端回收，正好会触发 SIGPIPE。置空引用后，
    /// 下一次操作走 `connect()` 重建，AMSMB2 对象释放时自己会关掉旧 fd。
    func invalidate() {
        manager = nil
        connecting = nil
        resetChannels()
    }

    private func resetChannels() {
        channels = Array(repeating: Channel(), count: Self.thumbnailChannelCount)
        let waiters = channelWaiters
        channelWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
    }

    // MARK: - 缩略图读取（8 条独立会话：图片 6 + 视频 2，空闲优先）

    /// 读缩略图 / 照片头部这类字节，走**独立会话**，不和列目录、播放抢同一条连接。
    ///
    /// 两条机制决定它能不能吃满带宽：
    /// 1. **空闲优先取通道**（不是轮询）。轮询在读写耗时不均时会把两条请求压到同一条
    ///    socket 上排队、另一条却空着 —— 用户看到的就是「忽快忽慢」。
    /// 2. **大范围读分段并发**。单条会话内部是「发一块、等一块」的串行循环
    ///    （`AMSMB2.contents` 里就是 while + 一次 `smb2_pread_async`），一条连接的吞吐
    ///    ≈ 块大小 ÷ 往返延迟，几十兆的文件靠一条连接读永远吃不满千兆。
    func thumbRead(
        _ path: String,
        offset: Int64,
        length: Int,
        lane: ThumbLane = .image,
        cancel: CancellationBox? = nil
    ) async throws -> Data {
        guard length > 0, offset >= 0 else { return Data() }

        if length >= Self.parallelThreshold {
            return try await readSegmented(
                path: path, offset: offset, length: length, lane: lane, cancel: cancel
            )
        }

        guard let index = await acquireChannel(lane: lane) else {
            return try await transfer(
                path: path,
                range: UInt64(offset)..<(UInt64(offset) &+ UInt64(length)),
                cancel: cancel
            )
        }
        defer { releaseChannel(index) }
        return try await readOnChannel(
            index, path: path, offset: offset, length: length, cancel: cancel
        )
    }

    /// 预热通道：进目录时先把图片会话建好。
    ///
    /// 懒建的话，首屏那几个格子会同时触发多次 TCP + 认证握手 —— 既慢又互相抢带宽，
    /// 「刚进目录那一下特别慢」就是它。提前建好，首屏只剩纯粹的读。
    func prewarmThumbnailChannels() async {
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<Self.imageChannelCount {
                group.addTask { [weak self] in
                    guard let self else { return }
                    _ = try? await self.warmChannel(index)
                }
            }
        }
    }

    private func warmChannel(_ index: Int) async throws {
        guard channels.indices.contains(index),
              channels[index].manager == nil,
              !channels[index].disabled else { return }
        _ = try await channelManager(at: index)
    }

    // MARK: 通道调度

    /// 取一条**空闲**通道；全忙就等（取消安全）。
    /// 返回 `nil` 表示这一车道的通道全都建不起来 —— 调用方退回主连接。
    private func acquireChannel(lane: ThumbLane) async -> Int? {
        while true {
            if Task.isCancelled { return nil }
            if let free = idleChannel(lane: lane) {
                channels[free].busy = true
                return free
            }
            if allDisabled(lane: lane) { return nil }
            await waitForChannel()
        }
    }

    /// 取最多 `limit` 条通道：第一条阻塞等，其余只捡现成空闲的。
    ///
    /// 剩余几条**绝不能也阻塞等待** —— 多个分段任务同时各等好几条会把通道锁死
    /// （A 拿到 1 条在等第 2 条，B 也拿到 1 条在等第 2 条），所以只捡空闲。
    private func acquireChannels(lane: ThumbLane, limit: Int) async -> [Int] {
        guard limit > 0 else { return [] }
        guard let first = await acquireChannel(lane: lane) else { return [] }
        var result = [first]
        if limit > 1 {
            for index in laneRange(lane) where result.count < limit {
                if isIdle(index) {
                    channels[index].busy = true
                    result.append(index)
                }
            }
        }
        return result
    }

    private func idleChannel(lane: ThumbLane) -> Int? {
        for index in laneRange(lane) where isIdle(index) {
            return index
        }
        return nil
    }

    /// 空闲 = 没人占 + 没被禁用。被禁用的按 `channelRetryInterval` 给一次重试机会。
    private func isIdle(_ index: Int) -> Bool {
        if channels[index].disabled {
            guard let at = channels[index].disabledAt,
                  Date().timeIntervalSince(at) > Self.channelRetryInterval else { return false }
            channels[index].disabled = false
            channels[index].disabledAt = nil
            channels[index].failures = 0
        }
        return !channels[index].busy
    }

    private func allDisabled(lane: ThumbLane) -> Bool {
        for index in laneRange(lane) where channels[index].disabled {
            guard let at = channels[index].disabledAt,
                  Date().timeIntervalSince(at) > Self.channelRetryInterval else { continue }
            channels[index].disabled = false
            channels[index].disabledAt = nil
            channels[index].failures = 0
        }
        return laneRange(lane).allSatisfy { channels[$0].disabled }
    }

    private func laneRange(_ lane: ThumbLane) -> Range<Int> {
        lane == .video
            ? Self.imageChannelCount..<Self.thumbnailChannelCount
            : 0..<Self.imageChannelCount
    }

    private func releaseChannel(_ index: Int) {
        guard channels.indices.contains(index) else { return }
        channels[index].busy = false
        // 全唤醒、各自重新抢：通道状态只在 actor 内改，多唤醒几个只是多跑一轮循环
        let waiters = channelWaiters
        channelWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
    }

    /// 等一条通道空出来。取消时把续体摘掉再唤醒自己，不会永久挂住。
    private func waitForChannel() async {
        let token = WaiterToken()
        let id = waiterSequence
        waiterSequence += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if token.cancelled {
                    continuation.resume()
                    return
                }
                channelWaiters[id] = continuation
            }
        } onCancel: {
            token.cancelled = true
            Task { await self.withdrawWaiter(id) }
        }
    }

    private func withdrawWaiter(_ id: Int) {
        if let continuation = channelWaiters.removeValue(forKey: id) {
            continuation.resume()
        }
    }

    // MARK: 单通道读

    private func readOnChannel(
        _ index: Int, path: String, offset: Int64, length: Int, cancel: CancellationBox?
    ) async throws -> Data {
        let start = UInt64(offset)
        let end = start &+ UInt64(length)

        let manager: SMB2Manager
        do {
            manager = try await channelManager(at: index)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 建不起独立会话（个别服务器限制同账号并发连接）：这条通道本次不再试，
            // 退回主连接。功能不能丢，只是拿不到并发收益。
            channels[index].manager = nil
            channels[index].disabled = true
            channels[index].disabledAt = Date()
            return try await transfer(path: path, range: start..<end, cancel: cancel)
        }

        do {
            let data: Data = try await manager.contents(
                atPath: path,
                range: start..<end,
                progress: { _, _ in !(cancel?.isCancelled ?? false) }
            )
            if cancel?.isCancelled == true { throw CancellationError() }
            channels[index].failures = 0
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if cancel?.isCancelled == true { throw CancellationError() }
            // 单次失败**不作废会话**：作废会触发 TCP + 认证重建（几百毫秒），
            // 滚动时表现为「一卡一卡」。连续两次才认为这条会话真的坏了。
            channels[index].failures += 1
            if channels[index].failures >= 2 {
                channels[index].manager = nil
                channels[index].failures = 0
            }
            throw SMBFailure.operation(Self.describe(error))
        }
    }

    // MARK: 分段并发读

    /// 大范围读：切成 4 MB 一段，交给多条空闲通道同时读，按下标拼回去。
    ///
    /// 这是唯一能真正吃满千兆的办法 —— 单条 SMB 会话没有请求流水线，
    /// 吞吐被「块大小 ÷ 往返延迟」卡死；libsmb2 也没实现 SMB Multichannel，
    /// 只能自己在应用层开多会话并行。
    /// 段数不是写死的：**有几条空闲通道就切几段**，避免和别的格子互相等成串行。
    private func readSegmented(
        path: String, offset: Int64, length: Int, lane: ThumbLane, cancel: CancellationBox?
    ) async throws -> Data {
        let total = Int64(length)
        let wanted = min(
            Self.maxSegments,
            Int((total + Int64(Self.segmentBytes) - 1) / Int64(Self.segmentBytes))
        )
        let indices = await acquireChannels(lane: lane, limit: max(1, wanted))
        guard !indices.isEmpty else {
            return try await transfer(
                path: path,
                range: UInt64(offset)..<(UInt64(offset) &+ UInt64(length)),
                cancel: cancel
            )
        }
        defer { for channel in indices { releaseChannel(channel) } }

        // 按实际拿到的通道数重算分段，保证每段都落到一条通道上
        let segments = indices.count
        let segLength = Int((total + Int64(segments) - 1) / Int64(segments))
        var parts = [Data?](repeating: nil, count: segments)

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (slot, channel) in indices.enumerated() {
                let segStart = offset + Int64(slot) * Int64(segLength)
                let segEnd = min(offset + total, segStart + Int64(segLength))
                guard segEnd > segStart else { continue }
                group.addTask { [weak self] in
                    guard let self else { throw CancellationError() }
                    let data = try await self.readOnChannel(
                        channel,
                        path: path,
                        offset: segStart,
                        length: Int(segEnd - segStart),
                        cancel: cancel
                    )
                    return (slot, data)
                }
            }
            for try await (slot, data) in group {
                parts[slot] = data
            }
        }

        var result = Data()
        result.reserveCapacity(length)
        for part in parts {
            guard let part else { continue }
            result.append(part)
        }
        return result
    }

    /// 懒建会话：多条通道可以各自并行建，不会串成一队。
    private func channelManager(at index: Int) async throws -> SMB2Manager {
        if let manager = channels[index].manager { return manager }
        if let task = channels[index].connecting { return try await task.value }

        let server = self.server
        let password = self.password
        let task = Task<SMB2Manager, Error> {
            try await SMBConnection.makeManager(server: server, password: password)
        }
        channels[index].connecting = task

        do {
            let manager = try await task.value
            channels[index].manager = manager
            channels[index].connecting = nil
            return manager
        } catch {
            channels[index].connecting = nil
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
    ///
    /// 走缩略图通道池（图片车道）而不是主连接：主连接只有一条 socket，原图
    /// 20~60 MB 只能一块一块地读，单连接没有请求流水线，千兆下也就 300~400 Mbps。
    /// 走通道池后超过 8 MB 会自动切段、6 条会话并发，点开原图的等待时间直接砍掉一截。
    func readAll(_ path: String, cancel: CancellationBox? = nil) async throws -> Data {
        let size = (try? await fileSize(path)) ?? 0
        // 拿不到大小（或异常值）就退回主连接整份读，功能不能丢
        guard size > 0, size <= Int64(Int.max) else {
            return try await transfer(path: path, range: nil, cancel: cancel)
        }
        return try await thumbRead(path, offset: 0, length: Int(size), cancel: cancel)
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
    /// 下载整个文件到本地。
    ///
    /// `cancel` 传下去后，进度回调返回 false 会**真的把传输停掉**（AMSMB2 支持中途叫停），
    /// 而不是像以前那样只能等它下完。取消时会把写了一半的文件删掉再抛 `CancellationError`，
    /// 调用方据此静默收尾，不要当成「下载失败」报错。
    func download(
        _ path: String,
        to url: URL,
        cancel: CancellationBox? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        do {
            try await run { manager in
                try await manager.downloadItem(atPath: path, to: url, progress: { received, total in
                    if cancel?.isCancelled == true { return false }
                    if total > 0 {
                        progress(min(1, max(0, Double(received) / Double(total))))
                    }
                    return true
                })
            }
        } catch {
            // `run` 会把任何错误包装成 SMBFailure，所以取消要在外面重新认一次
            if cancel?.isCancelled == true {
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }
            throw error
        }
        // 停下来的那一刻可能刚好下完：仍然按取消处理，别把半成品当成品留下
        if cancel?.isCancelled == true {
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
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
