import AVFoundation
import AVKit
import Combine
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - 画面填充方式

/// 画面怎么铺在屏幕上。SMB 上的片子比例很杂（4:3、2.35:1、竖拍），
/// 默认「适应」会留黑边，有些用户更想要「填满」——给一个开关，别让人去改文件。
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

    var next: VideoFit {
        switch self {
        case .aspect: return .fill
        case .fill: return .stretch
        case .stretch: return .aspect
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
    /// 等待数据（seek 到未缓冲位置、或网络跟不上）：进度条上显示一个小转圈
    @Published fileprivate(set) var isBuffering = false

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

    /// 换片前清干净：否则上一部片的时长会短暂留在进度条上，滑块位置也是旧的
    fileprivate func reset() {
        currentTime = 0
        duration = 0
        scrubTime = nil
        isSeeking = false
        isBuffering = false
    }
}

// MARK: - 播放模型

@MainActor
final class VideoPlaybackModel: ObservableObject {
    let player = AVPlayer()
    let progress = PlaybackProgress()

    @Published var errorMessage: String?
    @Published var downloadProgress: Double?
    @Published var isDownloading = false
    @Published var isPlaying = false
    /// 视频画面尺寸（已按旋转元数据摆正，宽 > 高就是横片）。
    /// 播放页拿它决定进页面时自动转横屏还是竖屏。
    @Published private(set) var videoSize: CGSize = .zero
    /// 系统输出音量（0…1）。真正改声音的是 `SystemVolume`，这里只是记着状态。
    ///
    /// **故意不是 `@Published`**：拖音量时它每帧都在变，一发布就会让整个播放页重算
    /// （含手势层），拖动立刻发涩。界面要显示音量时由手势自己发 HUD，不读这里。
    private(set) var volume: Float = 1
    /// 常速倍率（0.5×…2×）。长按加速只是「临时覆盖」，松手回到这个值。
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var fit: VideoFit = .aspect
    @Published private(set) var isMuted = false

    private static let volumeKey = "settings.player.volume"
    private static let fitKey = "settings.player.fit"

    private var currentAsset: AVURLAsset?
    private var statusCancellable: AnyCancellable?
    private var sizeCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    /// 长按加速前的播放状态，松开后要还原
    private var wasPlayingBeforeHold = false
    /// 长按加速进行中：这期间不许倍速按钮改 `rate`，否则按一下就把加速存下来了
    private var holdActive = false
    /// seek 代号：只让最后一次 seek 的回调生效（连续 seek 会互相取消）
    private var seekToken = 0

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double
        volume = Float(min(max(stored ?? 1, 0), 1))
        fit = VideoFit(rawValue: UserDefaults.standard.string(forKey: Self.fitKey) ?? "") ?? .aspect
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
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = false
            }
        }
    }

    func start(item: FileItem, serverID: UUID, connection: SMBConnection) async {
        configureAudioSession()
        // 不使用 AVKit 的播放器，也绝不注册「正在播放」信息，
        // 否则系统会在灵动岛弹一块媒体胶囊（用户明确要求去掉）。
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        var size = item.size
        if size <= 0 {
            size = (try? await connection.fileSize(item.path)) ?? 0
        }
        guard size > 0 else {
            errorMessage = "无法获取视频大小，文件可能为空或没有读取权限。"
            return
        }

        let asset = MediaAssetFactory.shared.makeAsset(
            connection: connection,
            path: item.path,
            fileSize: size,
            fileExtension: item.fileExtension
        )
        currentAsset = asset

        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 5
        observe(playerItem)

        resetPlaybackState()
        player.replaceCurrentItem(with: playerItem)
        applyMute()
        player.play()
        isPlaying = true
    }

    func downloadAndPlay(item: FileItem, serverID: UUID, connection: SMBConnection) async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        do {
            let url = try await MediaStore.shared.localVideoURL(
                for: item,
                serverID: serverID,
                connection: connection
            ) { [weak self] value in
                Task { @MainActor in
                    self?.downloadProgress = value
                }
            }
            let localItem = AVPlayerItem(url: url)
            observe(localItem)
            resetPlaybackState()
            player.replaceCurrentItem(with: localItem)
            applyMute()
            player.play()
            isPlaying = true
            downloadProgress = nil
        } catch {
            errorMessage = "下载失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            downloadProgress = nil
        }

        isDownloading = false
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // 播到最后再点播放就从头来
            if progress.duration > 0, progress.currentTime >= progress.duration - 0.3 {
                seek(to: 0, tolerance: 0.1)
            }
            player.play()
            isPlaying = true
        }
    }

    // MARK: - 拖动 / 跳转

    /// 换 `AVPlayerItem` 前清一遍：在途 seek 作废、进度归零、拖动状态复位。
    private func resetPlaybackState() {
        seekToken &+= 1
        progress.reset()
        // 换片时先清尺寸：否则上一部的横竖判断会留在 `videoSize` 上
        videoSize = .zero
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
        let clamped = min(max(value, 0.5), 2)
        guard abs(clamped - playbackRate) > 0.001 else { return }
        playbackRate = clamped
        player.defaultRate = clamped
        if isPlaying, !holdActive { player.rate = clamped }
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

    func cycleFit() {
        setFit(fit.next)
    }

    func setFit(_ value: VideoFit) {
        guard value != fit else { return }
        fit = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.fitKey)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusCancellable = nil
        sizeCancellable = nil
        videoSize = .zero
        isPlaying = false
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
                if let seconds = self.player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                    self.progress.setDuration(seconds)
                }
                // 只在真的变化时赋值：`@Published` 每次 set 都会让整个播放页重算。
                // 缓冲中也算「在播」，否则 seek 到未缓冲位置时按钮会闪成播放图标。
                let playing = status == .playing || status == .waitingToPlayAtSpecifiedRate
                if playing != self.isPlaying { self.isPlaying = playing }
            }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        statusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard let self else { return }
                // 兜底：有些流 ready 那一刻 KVO 还没把尺寸推过来，这里补读一次
                if status == .readyToPlay, let size = item?.presentationSize {
                    self.adopt(size)
                }
                guard status == .failed else { return }
                let reason = item?.error?.localizedDescription ?? "编码格式不受支持或网络中断"
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
