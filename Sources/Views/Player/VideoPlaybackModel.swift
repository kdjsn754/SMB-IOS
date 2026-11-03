import AVFoundation
import AVKit
import Combine
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - 画面填充方式

/// 画面怎么铺在屏幕上。SMB 上的片子比例很杂（4:3、2.35:1、竖拍），
/// 默认「适应」会留黑边，有些用户更想要「填满」——给一个选择，别让人去改文件。
enum VideoFit: String, CaseIterable, Identifiable {
    case aspect
    case fill
    case stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aspect: return "适应屏幕"
        case .fill: return "填满屏幕"
        case .stretch: return "拉伸铺满"
        }
    }

    var detail: String {
        switch self {
        case .aspect: return "完整显示画面，多出来的地方留黑边"
        case .fill: return "按屏幕裁掉多余部分，不留黑边"
        case .stretch: return "把画面硬拉到屏幕比例，会变形"
        }
    }

    var shortTitle: String {
        switch self {
        case .aspect: return "适应"
        case .fill: return "填充"
        case .stretch: return "拉伸"
        }
    }

    var gravity: AVLayerVideoGravity {
        switch self {
        case .aspect: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        }
    }
}

// MARK: - 播放进度

/// 播放进度单独一个对象：每 0.25 秒刷新一次，只让进度条这个子视图重算，
/// 不牵动整个播放页（页面里有 `AVPlayerLayer` 的 `UIViewRepresentable`，整页重算代价高）。
///
/// 三个状态的区别很关键：
/// - `currentTime` 播放器真实位置；
/// - `scrubTime` 手指拖动中的目标位置（非 nil 时界面只认它，绝不回读播放器）；
/// - `isSeeking` seek 在途（此时周期回调不许覆盖界面）。
@MainActor
final class PlaybackProgress: ObservableObject {
    @Published fileprivate(set) var currentTime: Double = 0
    @Published fileprivate(set) var duration: Double = 0
    @Published fileprivate(set) var scrubTime: Double?
    @Published fileprivate(set) var isSeeking = false
    /// 等待数据（seek 到未缓冲位置、或网络跟不上）：中间显示转圈
    @Published fileprivate(set) var isBuffering = false
    /// 已缓冲到的秒数（进度条上那段浅色轨道）
    @Published fileprivate(set) var buffered: Double = 0

    var isScrubbing: Bool { scrubTime != nil }

    /// 界面该显示的位置：拖动优先，其次播放器时间
    var displayTime: Double {
        if let scrubTime { return max(0, scrubTime) }
        if duration > 0 { return min(max(currentTime, 0), duration) }
        return max(currentTime, 0)
    }

    /// 只在真的变化时赋值：`@Published` 每次 set 都会发通知，
    /// 每 0.25 秒无脑赋一次同样的值，等于每秒让进度条白重算 4 次。
    fileprivate func setCurrentTime(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = max(0, value)
        if abs(clamped - currentTime) > 0.002 { currentTime = clamped }
    }

    fileprivate func setDuration(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        if abs(value - duration) > 0.2 { duration = value }
    }

    fileprivate func setScrubTime(_ value: Double?) {
        if scrubTime != value { scrubTime = value }
    }

    fileprivate func setSeeking(_ value: Bool) {
        if isSeeking != value { isSeeking = value }
    }

    fileprivate func setBuffering(_ value: Bool) {
        if isBuffering != value { isBuffering = value }
    }

    fileprivate func setBuffered(_ value: Double) {
        guard value.isFinite else { return }
        if abs(value - buffered) > 1 { buffered = max(0, value) }
    }

    /// 换片前清干净：否则上一部片的时长会短暂留在进度条上，滑块位置也是旧的
    fileprivate func reset() {
        currentTime = 0
        duration = 0
        scrubTime = nil
        isSeeking = false
        isBuffering = false
        buffered = 0
    }
}

// MARK: - 字幕 / 音轨

/// 一条可选轨道。`AVMediaSelectionOption` 不能直接进 `@Published` 数组
/// （不 Equatable、也不稳定），这里只留展示需要的东西，选择时再按 id 映射回去。
struct MediaTrack: Identifiable, Equatable {
    let id: String
    let name: String
    let detail: String?
}

// MARK: - 播放模型

@MainActor
final class VideoPlaybackModel: ObservableObject {
    let player = AVPlayer()
    let progress = PlaybackProgress()

    @Published var errorMessage: String?
    @Published var downloadProgress: Double?
    @Published var isDownloading = false
    /// 当前这次「下载到本地」的取消标记。点了取消就把它 cancel 掉，
    /// 传输中的 SMB 回调会看到并主动停下来（不是等它下完再丢掉）。
    private var downloadCancel: CancellationBox?
    /// 开始下载前播放页原有的提示（通常是「无法播放」）。
    /// 取消下载后要把它还原，不然页面会变成一片纯黑、没有任何可点的东西。
    private var messageBeforeDownload: String?
    @Published var isPlaying = false
    /// 视频画面尺寸（已按旋转元数据摆正，宽 > 高就是横片）。
    /// 播放页拿它决定进页面时自动转横屏还是竖屏。
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var fit: VideoFit = .aspect
    @Published private(set) var isMuted = false
    /// 播完了（停在最后一帧），页面显示「重播 / 下一个」
    @Published private(set) var didReachEnd = false
    @Published private(set) var currentItem: FileItem?
    @Published private(set) var canPlayNext = false
    @Published private(set) var canPlayPrevious = false
    /// 进页面时从上次位置续播的提示，页面弹一次 toast 后清掉
    @Published var resumeHint: String?
    @Published private(set) var isLooping = false
    @Published private(set) var sleepDeadline: Date?

    @Published private(set) var subtitles: [MediaTrack] = []
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var selectedSubtitle: String?
    @Published private(set) var selectedAudio: String?

    /// 系统输出音量（0…1）。真正改声音的是 `SystemVolume`，这里只是记着状态。
    ///
    /// **故意不是 `@Published`**：拖音量时它每帧都在变，一发布就会让整个播放页重算
    /// （含手势层），拖动立刻发涩。界面要显示音量时由手势自己发 HUD，不读这里。
    private(set) var volume: Float = 1

    private static let volumeKey = "settings.player.volume"
    private static let fitKey = "settings.player.fit"
    private static let rateKey = "settings.player.rate"
    private static let loopKey = "settings.player.loop"

    private var currentAsset: AVURLAsset?
    private var statusCancellable: AnyCancellable?
    private var sizeCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var sleepTask: Task<Void, Never>?

    /// 长按加速前的播放状态，松开后要还原
    private var wasPlayingBeforeHold = false
    /// 长按加速进行中：这期间不许倍速按钮改 `rate`，否则按一下就把加速存下来了
    private var holdActive = false
    /// seek 代号：只让最后一次 seek 的回调生效（连续 seek 会互相取消）
    private var seekToken = 0

    private var serverID: UUID?
    private var connection: SMBConnection?
    private var playlist: [FileItem] = []
    /// 元数据就绪后再跳：还没 ready 时 seek 有时会被丢掉
    private var pendingResume: Double?
    private var lastResumeSave: Date = .distantPast

    private var subtitleGroup: AVMediaSelectionGroup?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleOptions: [String: AVMediaSelectionOption] = [:]
    private var audioOptions: [String: AVMediaSelectionOption] = [:]

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double
        volume = Float(min(max(stored ?? 1, 0), 1))
        fit = VideoFit(rawValue: UserDefaults.standard.string(forKey: Self.fitKey) ?? "") ?? .aspect
        let storedRate = UserDefaults.standard.object(forKey: Self.rateKey) as? Double
        playbackRate = Float(min(max(storedRate ?? 1, 0.25), 3))
        isLooping = UserDefaults.standard.bool(forKey: Self.loopKey)
        // App 内音量固定拉满：音量统一交给系统输出音量（见 setVolume），
        // 两边都调的话只会互相打折。
        player.volume = 1
        player.actionAtItemEnd = .pause
        player.preventsDisplaySleepDuringVideoPlayback = true
        installTimeObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self,
                      let ended = note.object as? AVPlayerItem,
                      ended === self.player.currentItem
                else { return }
                self.handleReachEnd()
            }
        }
    }

    // MARK: - 打开

    func start(
        item: FileItem,
        serverID: UUID,
        connection: SMBConnection,
        playlist: [FileItem] = []
    ) async {
        self.serverID = serverID
        self.connection = connection
        self.playlist = playlist.isEmpty ? [item] : playlist
        configureAudioSession()
        // 不使用 AVKit 的播放器，也绝不注册「正在播放」信息，
        // 否则系统会在灵动岛弹一块媒体胶囊（用户明确要求去掉）。
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        await open(item: item)
    }

    /// 换到列表里的另一集：不退出播放页，直接换 `AVPlayerItem`。
    func playNext() async {
        guard let index = playlistIndex, index + 1 < playlist.count else { return }
        await open(item: playlist[index + 1])
    }

    func playPrevious() async {
        guard let index = playlistIndex, index > 0 else { return }
        await open(item: playlist[index - 1])
    }

    private var playlistIndex: Int? {
        guard let currentItem else { return nil }
        return playlist.firstIndex(where: { $0.path == currentItem.path })
    }

    private func open(item: FileItem) async {
        guard let connection else { return }
        player.pause()
        isPlaying = false

        var size = item.size
        if size <= 0 {
            size = (try? await connection.fileSize(item.path)) ?? 0
        }
        guard size > 0 else {
            errorMessage = "无法获取视频大小，文件可能为空或没有读取权限。"
            return
        }

        errorMessage = nil

        // 先探一次编码再建资产：
        // - `hev1` 标签 Apple 不认（只认 `hvc1`），探测结果会带着改写位置进 loader；
        // - `4:4:4` / `4:2:2` 的 HEVC 在 iOS 上根本没有解码器，直接说清楚，
        //   别让用户对着黑屏等半天还不知道为什么。
        let codecProbe = await MP4CodecTag.probe(
            connection: connection, path: item.path, fileSize: size
        )
        if codecProbe.isUndecodableOnIOS {
            errorMessage = """
            这个视频是 \(codecProbe.unsupportedDescription) 编码，iPhone 上没有任何播放器能解码。
            用电脑转成 H.264（或 HEVC 4:2:0）之后就能正常播放。
            """
            return
        }

        let previousAsset = currentAsset
        currentAsset = nil

        let asset = MediaAssetFactory.shared.makeAsset(
            connection: connection,
            path: item.path,
            fileSize: size,
            fileExtension: item.fileExtension,
            codecProbe: codecProbe
        )
        currentAsset = asset

        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 5

        resetPlaybackState()
        currentItem = item
        updateNeighbours()

        // 续播：元数据就绪后再跳（见 status 回调里的 `pendingResume`）
        if let position = PlaybackMemory.shared.position(for: resumeKey(for: item)) {
            pendingResume = position
            resumeHint = "已从 \(Format.duration(position)) 继续播放"
        } else {
            pendingResume = nil
            resumeHint = nil
        }

        observe(playerItem)
        player.replaceCurrentItem(with: playerItem)
        // 旧资产等换完再放：先放会把它底下还在读的 loader 拆掉
        if let previousAsset {
            MediaAssetFactory.shared.release(previousAsset)
        }
        applyMute()
        player.defaultRate = playbackRate
        player.play()
        isPlaying = true
    }

    /// 下载到本地再播：远端流因为容器/码率播不动时的兜底
    func downloadAndPlay(item: FileItem, serverID: UUID, connection: SMBConnection) async {
        guard !isDownloading else { return }
        let box = CancellationBox()
        downloadCancel = box
        messageBeforeDownload = errorMessage
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        do {
            let url = try await MediaStore.shared.localVideoURL(
                for: item,
                serverID: serverID,
                connection: connection,
                cancel: box
            ) { [weak self] value in
                // 点了取消就别再刷新进度条了（传输要下一次回调才真正停）
                guard !box.isCancelled else { return }
                Task { @MainActor in
                    self?.downloadProgress = value
                }
            }
            guard !box.isCancelled else { return }
            let localItem = AVPlayerItem(url: url)
            observe(localItem)
            resetPlaybackState()
            currentItem = item
            updateNeighbours()
            player.replaceCurrentItem(with: localItem)
            applyMute()
            player.play()
            isPlaying = true
        } catch is CancellationError {
            // 用户自己点的取消，不是故障，安静退回播放页
        } catch {
            if !box.isCancelled {
                errorMessage = "下载失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }

        // 已经被取消时状态早就清过了，别让它覆盖掉新一次下载
        if downloadCancel === box {
            downloadCancel = nil
            messageBeforeDownload = nil
            downloadProgress = nil
            isDownloading = false
        }
    }

    /// 取消「下载到本地」：立刻收起进度浮层，并让正在跑的 SMB 传输停手。
    /// 写了一半的临时文件由 `MediaStore` 在取消分支里删掉，不会留下半截文件。
    func cancelDownload() {
        downloadCancel?.cancel()
        downloadCancel = nil
        downloadProgress = nil
        isDownloading = false
        // 还原下载前的那条提示，让用户还能再点一次「下载到本地播放」或直接退出
        errorMessage = messageBeforeDownload
        messageBeforeDownload = nil
    }

    // MARK: - 播放 / 暂停

    func togglePlay() {
        if isPlaying {
            pause()
        } else {
            // 播到最后再点播放就从头来
            if progress.duration > 0, progress.currentTime >= progress.duration - 0.3 {
                seek(to: 0, tolerance: 0.1)
            }
            if didReachEnd { seek(to: 0, tolerance: 0.1) }
            didReachEnd = false
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
        saveResume(force: true)
    }

    /// 播完那一刻：循环就重播，否则停在最后一帧等用户选「重播 / 下一个」
    private func handleReachEnd() {
        isPlaying = false
        if isLooping {
            seek(to: 0, tolerance: 0.1)
            player.play()
            isPlaying = true
            return
        }
        didReachEnd = true
        if let currentItem {
            PlaybackMemory.shared.clear(for: resumeKey(for: currentItem))
        }
    }

    // MARK: - 拖动 / 跳转

    /// 换 `AVPlayerItem` 前清一遍：在途 seek 作废、进度归零、拖动状态复位。
    private func resetPlaybackState() {
        seekToken &+= 1
        progress.reset()
        // 换片时先清尺寸：否则上一部的横竖判断会留在 `videoSize` 上
        videoSize = .zero
        didReachEnd = false
        subtitles = []
        audioTracks = []
        selectedSubtitle = nil
        selectedAudio = nil
        subtitleGroup = nil
        audioGroup = nil
        subtitleOptions = [:]
        audioOptions = [:]
        lastResumeSave = .distantPast
    }

    /// 手指按下进度条（或开始横向拖画面）：记下起点，之后界面只认 `scrubTime`。
    func beginScrub() {
        // Slider 有时先 set 再回调 onEditingChanged(true)，别把已有的值冲掉
        guard progress.scrubTime == nil else { return }
        progress.setScrubTime(progress.currentTime)
    }

    /// 拖动中：只更新本地显示值，**一次都不碰播放器**。
    ///
    /// 这是 1.3.30 之前「进度跳转很卡、滑块来回跳」的根因之一：
    /// 旧实现每一帧都 `player.seek(tolerance: .zero)`，SMB 远端流为了精确到帧
    /// 要回退到上一个关键帧重新读，请求在链路上排队，越拖越卡。
    func scrub(to seconds: Double) {
        guard seconds.isFinite else { return }
        let upper = progress.duration > 0 ? progress.duration : Double.greatestFiniteMagnitude
        progress.setScrubTime(min(max(seconds, 0), upper))
    }

    /// 松手：只发这一次真正的 seek。
    func commitScrub() {
        guard let target = progress.scrubTime else { return }
        seek(to: target, tolerance: 0.2)
    }

    func cancelScrub() {
        progress.setScrubTime(nil)
    }

    /// 跳转。`tolerance` 是允许的落点偏差（秒）——
    /// 远端流必须给容差：精确到帧的 seek 要从前一个关键帧重新解码，
    /// 大文件上会卡好几秒（用户反馈的「跳转很卡」就是这么来的）。
    func seek(to seconds: Double, tolerance: Double = 0.25) {
        guard seconds.isFinite, seconds >= 0, player.currentItem != nil else { return }
        let target = progress.duration > 0 ? min(seconds, progress.duration) : seconds

        seekToken &+= 1
        let token = seekToken

        progress.setScrubTime(nil)
        progress.setSeeking(true)
        // 先把显示推到位：否则松手瞬间界面会回到旧位置，等 seek 完成才跳过来
        progress.setCurrentTime(target)
        didReachEnd = false

        let time = CMTime(seconds: target, preferredTimescale: 600)
        let tol = CMTime(seconds: max(0, tolerance), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tol, toleranceAfter: tol) { [weak self] finished in
            Task { @MainActor [weak self] in
                // 连续 seek 时只有最后一次算数，中间被取消的回调一律忽略
                guard let self, token == self.seekToken else { return }
                if finished,
                   let actual = self.player.currentItem?.currentTime().seconds,
                   actual.isFinite {
                    // 以播放器实际落点为准（容差内会有几十毫秒偏差），
                    // 下一次周期回调才不会把进度往回拽
                    self.progress.setCurrentTime(actual)
                }
                self.progress.setSeeking(false)
            }
        }
    }

    // MARK: - 音量 / 倍速 / 画面

    /// 音量状态统一走这里（HUD 的百分比、持久化）。
    /// 真正改声音的地方在 `PlayerGestureEngine`：那里调 `SystemVolume`，
    /// 也就是**系统输出音量**。不要再用 `AVPlayer.volume` 当交互音量——
    /// 它只影响 App 内部，手机音量条不动，用户会以为「音量手势没作用」。
    func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        guard abs(clamped - volume) > 0.005 else { return }
        volume = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.volumeKey)
    }

    /// 进页面时把状态对齐到系统音量：用户可能在外面用实体音量键调过
    func syncVolumeFromSystem() {
        let current = SystemVolume.shared.current
        let clamped = min(max(current, 0), 1)
        if abs(clamped - volume) > 0.005 {
            volume = clamped
            UserDefaults.standard.set(Double(clamped), forKey: Self.volumeKey)
        }
    }

    /// 静音只影响本 App（系统音量不动），和底部那个喇叭键一一对应
    func toggleMute() {
        isMuted.toggle()
        applyMute()
    }

    private func applyMute() {
        player.isMuted = isMuted
    }

    /// 倍速。
    ///
    /// `defaultRate` 决定之后每次 `play()` 用哪个速率（seek 完自动续播、从头重播都算），
    /// `rate` 只影响「此刻正在播」的那一次，所以两个都要设。
    /// 长按加速期间不碰 `rate`：那时 2× 是临时的，改了就变成长期倍速了。
    func setPlaybackRate(_ value: Float) {
        let clamped = min(max(value, 0.25), 3)
        guard abs(clamped - playbackRate) > 0.001 else { return }
        playbackRate = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.rateKey)
        player.defaultRate = clamped
        if isPlaying, !holdActive, !didReachEnd { player.rate = clamped }
    }

    /// 长按加速用：按住时把速率调高，松手还原。
    /// 按住前是暂停的话，松手后回到暂停（和主流播放器一致）。
    func beginHold(rate: Float) {
        guard rate > 1, player.currentItem != nil else { return }
        holdActive = true
        wasPlayingBeforeHold = player.timeControlStatus == .playing || player.rate > 0
        player.rate = rate
        isPlaying = true
    }

    func endHold() {
        guard player.currentItem != nil else { return }
        holdActive = false
        if wasPlayingBeforeHold {
            // 回到用户的常速设置，而不是硬写 1（可能是 1.5× 在看）
            player.rate = playbackRate
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
        wasPlayingBeforeHold = false
    }

    func setFit(_ value: VideoFit) {
        guard value != fit else { return }
        fit = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.fitKey)
    }

    func toggleLoop() {
        isLooping.toggle()
        UserDefaults.standard.set(isLooping, forKey: Self.loopKey)
    }

    // MARK: - 字幕 / 音轨

    func selectSubtitle(_ id: String?) {
        guard let group = subtitleGroup, let item = player.currentItem else { return }
        let option = id.flatMap { subtitleOptions[$0] }
        item.select(option, in: group)
        selectedSubtitle = option == nil ? nil : id
    }

    func selectAudio(_ id: String?) {
        guard let group = audioGroup, let item = player.currentItem else { return }
        let option = id.flatMap { audioOptions[$0] }
        item.select(option, in: group)
        selectedAudio = id
    }

    private func loadTracks(for item: AVPlayerItem) {
        let asset = item.asset

        if let group = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            subtitleGroup = group
            var list: [MediaTrack] = []
            var map: [String: AVMediaSelectionOption] = [:]
            for (index, option) in group.options.enumerated() {
                let id = "s\(index)"
                list.append(
                    MediaTrack(
                        id: id,
                        name: option.displayName,
                        detail: nil
                    )
                )
                map[id] = option
            }
            subtitleOptions = map
            subtitles = list
            if let current = item.currentMediaSelection.selectedMediaOption(in: group) {
                selectedSubtitle = list.first(where: { map[$0.id] === current })?.id
            } else {
                selectedSubtitle = nil
            }
        } else {
            subtitleGroup = nil
            subtitleOptions = [:]
            subtitles = []
            selectedSubtitle = nil
        }

        if let group = asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            audioGroup = group
            var list: [MediaTrack] = []
            var map: [String: AVMediaSelectionOption] = [:]
            for (index, option) in group.options.enumerated() {
                let id = "a\(index)"
                list.append(
                    MediaTrack(
                        id: id,
                        name: option.displayName,
                        detail: nil
                    )
                )
                map[id] = option
            }
            audioOptions = map
            audioTracks = list
            selectedAudio = item.currentMediaSelection
                .selectedMediaOption(in: group)
                .flatMap { current in list.first(where: { map[$0.id] === current })?.id }
        } else {
            audioGroup = nil
            audioOptions = [:]
            audioTracks = []
            selectedAudio = nil
        }
    }

    // MARK: - 定时关闭

    /// 到点自动暂停。`minutes == nil` 关掉。
    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        guard let minutes else {
            sleepDeadline = nil
            return
        }
        sleepDeadline = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Double(minutes) * 60 * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.pause()
            self.sleepDeadline = nil
            self.sleepTask = nil
        }
    }

    // MARK: - 收尾

    func stop() {
        saveResume(force: true)
        sleepTask?.cancel()
        sleepTask = nil
        sleepDeadline = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusCancellable = nil
        sizeCancellable = nil
        videoSize = .zero
        isPlaying = false
        didReachEnd = false
        progress.setScrubTime(nil)
        progress.setSeeking(false)
        progress.setBuffering(false)
        // 作废所有在途 seek 的回调：页面已经关了，不能再回来改状态
        seekToken &+= 1
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let currentAsset {
            MediaAssetFactory.shared.release(currentAsset)
        }
        currentAsset = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 续播

    private func resumeKey(for item: FileItem) -> String {
        "\(serverID?.uuidString ?? "-")|\(item.path)"
    }

    /// 每 5 秒落一次盘：写得比这勤会让 `UserDefaults` 一直在写文件，
    /// 退到后台被系统杀掉时最多丢 5 秒，可接受。
    private func saveResume(force: Bool) {
        guard let currentItem, !didReachEnd else { return }
        let time = progress.currentTime
        guard time >= 5, time.isFinite else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastResumeSave) > 5 else { return }
        lastResumeSave = now
        PlaybackMemory.shared.set(time, duration: progress.duration, for: resumeKey(for: currentItem))
    }

    // MARK: - 观察

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // 回调本来就在主队列上，直接同步处理。
            // 旧实现又套了一层 `Task { @MainActor }`，多一次调度，正好叠在拖动的那一帧上。
            MainActor.assumeIsolated {
                guard let self else { return }
                let status = self.player.timeControlStatus
                // 缓冲状态先更新：seek 到未缓冲位置时这段时间界面是被锁住的，
                // 但用户更需要看到「在转圈」而不是一片死寂
                self.progress.setBuffering(status == .waitingToPlayAtSpecifiedRate)
                // 拖动中 / seek 在途：绝不覆盖界面，否则滑块会被播放器时间拽回旧位置
                guard !self.progress.isScrubbing, !self.progress.isSeeking else { return }
                self.progress.setCurrentTime(time.seconds)
                if let item = self.player.currentItem {
                    let seconds = item.duration.seconds
                    if seconds.isFinite, seconds > 0 {
                        self.progress.setDuration(seconds)
                    }
                    if let range = item.loadedTimeRanges.last?.timeRangeValue {
                        self.progress.setBuffered(range.start.seconds + range.duration.seconds)
                    }
                }
                // 只在真的变化时赋值：`@Published` 每次 set 都会让整个播放页重算。
                // 缓冲中也算「在播」，否则 seek 到未缓冲位置时按钮会闪成播放图标。
                let playing = status == .playing || status == .waitingToPlayAtSpecifiedRate
                if playing != self.isPlaying { self.isPlaying = playing }
                self.saveResume(force: false)
            }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        statusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self, let item else { return }
                if status == .readyToPlay {
                    // 兜底：有些流 ready 那一刻 KVO 还没把尺寸推过来，这里补读一次
                    self.adopt(item.presentationSize)
                    // 元数据已经解析完，这里读轨道组不会再触发远端 I/O
                    self.loadTracks(for: item)
                    if let pending = self.pendingResume {
                        self.pendingResume = nil
                        self.seek(to: pending, tolerance: 1.0)
                    }
                }
                guard status == .failed else { return }
                let reason = item.error?.localizedDescription ?? "编码格式不受支持或网络中断"
                // 失败时把播放键还原成「播放」，否则它会一直停在暂停图标上
                self.isPlaying = false
                self.errorMessage = "无法播放：\(reason)"
            }

        // `presentationSize` 已经算上 `preferredTransform`，
        // 手机竖拍的 MOV 也能拿到「看起来是竖的」宽高，不用自己解旋转。
        // 就绪前是 `.zero`，所以用 KVO 跟着它走，别只在 status 回调里读一次。
        sizeCancellable = item.publisher(for: \.presentationSize)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] size in
                self?.adopt(size)
            }
    }

    /// 收下视频尺寸。只认有效值、只在真的变了才赋值（`@Published` 一 set 整页重算）。
    private func adopt(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != videoSize else { return }
        videoSize = size
    }

    private func updateNeighbours() {
        guard let index = playlistIndex else {
            canPlayNext = false
            canPlayPrevious = false
            return
        }
        canPlayPrevious = index > 0
        canPlayNext = index + 1 < playlist.count
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}

// MARK: - 画面层

/// 只用 AVPlayerLayer 铺画面，不带 AVKit 的播放器外壳（也就不会注册系统媒体活动）
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    private var currentFit: VideoFit = .aspect

    var player: AVPlayer? {
        get { playerLayer?.player }
        set { playerLayer?.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .black
        clipsToBounds = true
        playerLayer?.videoGravity = .resizeAspect
        playerLayer?.backgroundColor = UIColor.black.cgColor
    }

    /// 只在真的变了才写：`videoGravity` 一写就会让图层重新算一遍布局
    func apply(_ fit: VideoFit) {
        guard fit != currentFit else { return }
        currentFit = fit
        playerLayer?.videoGravity = fit.gravity
    }

    // 画面缩放不在这里做：直接改 AVPlayerLayer 的仿射变换会被视频层/布局刷掉
    // （1.1.8 在真机上实测「状态变了但画面不动」），缩放统一交给 SwiftUI 的 scaleEffect。
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var fit: VideoFit

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        view.apply(fit)
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
        uiView.apply(fit)
    }
}
