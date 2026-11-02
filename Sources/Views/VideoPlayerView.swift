import AVFoundation
import AVKit
import Combine
import MediaPlayer
import SwiftUI

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
    /// 播放器音量（0…1），右上角音量面板与上下拖动手势共用同一份，退出重进也记得
    @Published fileprivate(set) var volume: Float = 1
    /// 常速倍率（0.5×…2×）。长按加速只是「临时覆盖」，松手回到这个值。
    @Published fileprivate(set) var playbackRate: Float = 1

    private static let volumeKey = "settings.player.volume"

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

    /// 音量状态统一走这里（HUD 的百分比、持久化）。
    /// 真正改声音的地方在 `VideoPlayerView.updatePan`：那里调 `SystemVolume`，
    /// 也就是**系统输出音量**。不要再用 `AVPlayer.volume` 当交互音量——
    /// 它只影响 App 内部，手机音量条不动，用户会以为「音量手势没作用」。
    func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        guard abs(clamped - volume) > 0.005 else { return }
        volume = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.volumeKey)
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

/// 只用 AVPlayerLayer 铺画面，不带 AVKit 的播放器外壳（也就不会注册系统媒体活动）
private final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer?.player }
        set { playerLayer?.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        playerLayer?.videoGravity = .resizeAspect
        playerLayer?.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
        clipsToBounds = true
        playerLayer?.videoGravity = .resizeAspect
        playerLayer?.backgroundColor = UIColor.black.cgColor
    }

    // 画面缩放不在这里做：直接改 AVPlayerLayer 的仿射变换会被视频层/布局刷掉
    // （1.1.8 在真机上实测「状态变了但画面不动」），缩放统一交给 SwiftUI 的 scaleEffect。
}

private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
    }
}

// MARK: - 手势 HUD

/// 手势反馈气泡的形态
private enum GestureHUD: Equatable {
    /// 拖动进度：变化量 / 目标时间
    case seek(delta: Double, target: Double)
    case volume(Double)
    case brightness(Double)
    case speed(Float)
    case zoom(CGFloat)
    case playPause(Bool)
}

private enum DragMode: Equatable {
    case undecided
    case seek
    case vertical
}

/// HUD 独立成一个可观察对象：拖动进度时它每帧都在变，
/// 挂在播放页的 `@State` 上会把整页（含 AVPlayerLayer）也带着一起重算。
@MainActor
private final class HUDState: ObservableObject {
    @Published var value: GestureHUD?
}

// MARK: - 播放页

@MainActor
struct VideoPlayerView: View {
    let item: FileItem
    let serverID: UUID
    let connection: SMBConnection

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = VideoPlaybackModel()
    @ObservedObject private var gestures = PlayerGestureSettings.shared

    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?

    // 横竖屏
    /// 当前是不是横屏。跟着真实布局尺寸算，旋转完成后由 SwiftUI 自己回调过来，
    /// 比监听 `UIDevice.orientationDidChangeNotification` 准（那个在锁屏/分屏下会骗人）。
    @State private var isLandscape = false
    /// 进播放页那一刻的形态。退出时转回它——「回到手机原本的状态」，
    /// 而不是「按你躺着的姿态决定」。
    @State private var entryMode: ScreenMode = ScreenOrientationController.current
    /// 用户手动切过之后就不再按视频比例自动转，尊重手动选择
    @State private var manualMode: ScreenMode?
    /// 自动转只做一次，否则回调重入会把用户后来的手动选择抢回去
    @State private var didAutoOrient = false

    // 手势反馈
    @StateObject private var hud = HUDState()
    @State private var hudTask: Task<Void, Never>?
    /// 亮度用一层黑色遮罩表达：0 = 原始亮度，0.85 = 最暗
    @State private var dimLevel: Double = 0
    /// 画面缩放倍数（双指捏合）
    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat?

    // 拖动过程中的临时状态
    @State private var dragMode: DragMode = .undecided
    @State private var dragStartPoint: CGPoint = .zero
    @State private var dragStartTime: Double = 0
    @State private var dragStartValue: Double = 0
    @State private var isHolding = false
    /// 捏合期间要压掉拖动，否则缩放的同时还会冒出进度 HUD
    @State private var isPinching = false
    @State private var showGestureHelp = false
    /// 从「⋯」菜单打开的播放手势设置面板
    @State private var showGestureSettings = false
    /// 手势诊断（设置里可开关）：看看到底有没有收到手势
    @State private var gestureEventCount = 0
    @State private var lastGestureText = "还没收到任何手势"
    @State private var lastDiagnosticAt = Date.distantPast
    // 触摸状态（SwiftUI 手势自己维护，不再依赖 UIKit 识别器）
    @State private var touchActive = false
    @State private var touchMoved = false
    @State private var didBeginPan = false
    @State private var holdFired = false
    @State private var holdStartTask: Task<Void, Never>?
    @State private var singleTapTask: Task<Void, Never>?
    @State private var lastTapDate = Date.distantPast

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                // 缩放用 SwiftUI 的 scaleEffect：UIKit 层直接改 AVPlayerLayer 的
                // affineTransform 会被视频层和布局刷掉（1.1.8 实测「缩放 1.3× 但画面不动」），
                // SwiftUI 的渲染变换由它自己维护，改了就一定生效。
                PlayerSurface(player: model.player)
                    .ignoresSafeArea()
                    .scaleEffect(zoom)

                // 亮度遮罩：盖住画面、但盖不到控件和 HUD
                Color.black
                    .opacity(dimLevel)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // 手势层放在控件下面：播放键、进度条仍然点得动，其余区域的触摸都归它
                gestureSurface

                // HUD 自己观察自己：拖动时只有它重算，播放页不跟着重算
                PlayerHUDOverlay(state: hud, duration: model.progress.duration)

                if chromeVisible {
                    // 顶部栏（关闭 / 标题 / 切方向 / ⋯）和底部控件是一整层，
                    // 播放 4 秒后一起收起
                    chromeLayer
                        .transition(.opacity)
                }

                if gestures.showDiagnostics {
                    diagnosticsOverlay
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        // 让开顶部栏（关闭按钮在左上角）
                        .padding(.top, 56)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let progress = model.downloadProgress {
                    VStack(spacing: 10) {
                        ProgressView(value: progress)
                            .tint(.white)
                            .frame(width: 180)
                        Text("正在下载到本地… \(Int(progress * 100))%")
                            .font(.footnote)
                            .foregroundStyle(.white)
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if let message = model.errorMessage {
                    errorOverlay(message)
                }
            }
            // 导航栏整个不要：顶部控件自己做（关闭 / 标题 / ⋯），才能跟着自动隐藏一起淡出
            .toolbar(.hidden, for: .navigationBar)
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width > proxy.size.height
            } action: { landscape in
                isLandscape = landscape
            }
        }
        .preferredColorScheme(.dark)
        // 视频尺寸就绪（首次读元数据可能几百毫秒）后按比例转一次
        .onChange(of: model.videoSize) { _, size in
            applyAutoOrientation(for: size)
        }
        .alert("播放器手势", isPresented: $showGestureHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(gestureHelpText)
        }
        .sheet(isPresented: $showGestureSettings) {
            PlayerGestureSettingsSheet()
        }
        .task {
            await model.start(item: item, serverID: serverID, connection: connection)
            // 用户可能用实体音量键调过，进页面先对齐一次
            model.volume = SystemVolume.shared.current
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            hudTask?.cancel()
            holdStartTask?.cancel()
            singleTapTask?.cancel()
            model.stop()
            // 兜底：正常关闭走 `close()`，那里已经把方向转回去了；
            // 这里是防止有别的退出路径（比如被上层直接 remove）时锁留在横屏。
            ScreenOrientationController.restore(to: entryMode)
        }
    }

    // MARK: - 横竖屏

    /// 按视频比例自动转：宽/高 ≥ 1.15 当横片（4:3、16:9 都算），
    /// 1.15 以下留在竖屏（竖拍、方形）。只自动一次。
    private func applyAutoOrientation(for size: CGSize) {
        guard manualMode == nil, !didAutoOrient,
              size.width > 0, size.height > 0 else { return }
        didAutoOrient = true
        ScreenOrientationController.lock(size.width / size.height >= 1.15 ? .landscape : .portrait)
    }

    /// 顶部按钮：手动切横竖屏
    private func toggleOrientation() {
        let target: ScreenMode = isLandscape ? .portrait : .landscape
        manualMode = target
        ScreenOrientationController.lock(target)
        scheduleHide()
    }

    /// 关闭播放页：先把方向转回「进页面之前」的形态，再退出。
    ///
    /// 反过来（先 dismiss 再转）的话，退出去那一帧下面还是横着的浏览器，
    /// 随后再被掰回竖屏，看起来就是「页面先横着闪一下」。
    private func close() {
        ScreenOrientationController.restore(to: entryMode)
        Task {
            // 等几何动画（约 0.25 s）走完再退
            try? await Task.sleep(nanoseconds: 260_000_000)
            dismiss()
        }
    }

    /// 菜单里「手势说明」显示的内容，按当前设置动态生成，避免说明和实际不一致
    private var gestureHelpText: String {
        var lines = ["单击：显示 / 隐藏控件"]
        guard gestures.isEnabled else {
            lines.append("其余手势已在「设置 → 播放手势」里关闭。")
            return lines.joined(separator: "\n")
        }
        lines.append("双击：\(gestures.doubleTap.title)")
        if gestures.doubleTap != .none {
            lines.append("快进 / 快退跨度：\(Int(gestures.seekStep)) 秒")
        }
        if gestures.horizontal == .seek {
            lines.append("左右拖动：拖动进度（松手才真正跳转）")
        }
        if gestures.vertical != .none {
            lines.append("上下拖动：\(gestures.vertical.detail)")
        }
        if gestures.longPress != .none {
            lines.append("长按：\(gestures.longPress.title)播放，松手恢复")
        }
        if gestures.pinch == .zoom {
            lines.append("双指捏合：放大画面，最大 4 倍")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 手势

    /// 手势层：一层「几乎透明但画得出来」的矩形。
    ///
    /// 1.1.7 之前用的是 `Color.clear` / 透明 `UIView`，真机上一个手势都收不到——
    /// SwiftUI 里只有**能画出像素**的视图才稳定参与命中测试，透明图层时灵时不灵。
    /// 这里改成 `Rectangle().fill(white 0.001)` + `contentShape`，再挂 SwiftUI 原生手势：
    /// 拖动（含单击 / 双击 / 长按）一个 `DragGesture(minimumDistance: 0)` 全包，
    /// 捏合用 `simultaneousGesture` 并行识别。
    private var gestureSurface: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .contentShape(Rectangle())
                .gesture(dragGesture(size: proxy.size))
                .simultaneousGesture(magnifyGesture)
        }
        .ignoresSafeArea()
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !touchActive {
                    beginTouch(at: value.startLocation, size: size)
                }
                let translation = CGSize(width: value.translation.width, height: value.translation.height)
                if !didBeginPan, !isPinching, gestures.isEnabled,
                   abs(translation.width) > 12 || abs(translation.height) > 12 {
                    holdStartTask?.cancel()
                    touchMoved = true
                    didBeginPan = true
                    beginPan(at: dragStartPoint, in: size)
                }
                if didBeginPan {
                    updatePan(translation, in: size)
                    logGesture("拖动中 \(Int(translation.width)),\(Int(translation.height))")
                }
            }
            .onEnded { value in
                holdStartTask?.cancel()
                let translation = CGSize(width: value.translation.width, height: value.translation.height)
                if didBeginPan {
                    endPan(translation, in: size)
                } else if holdFired {
                    handleHold(false)
                } else {
                    registerTap(at: value.startLocation, in: size)
                }
                touchActive = false
                touchMoved = false
                didBeginPan = false
                holdFired = false
                isHolding = false
            }
    }

    /// 按下：记录起点，并起一个 0.45 秒的定时器判断长按。
    /// `DragGesture` 手指不动时不会继续回调，长按只能靠定时器兜。
    private func beginTouch(at point: CGPoint, size: CGSize) {
        touchActive = true
        touchMoved = false
        didBeginPan = false
        holdFired = false
        dragStartPoint = point

        holdStartTask?.cancel()
        guard gestures.isEnabled, gestures.longPress != .none else { return }
        holdStartTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, !didBeginPan, !touchMoved, !isPinching else { return }
            holdFired = true
            logGesture("长按按下")
            handleHold(true)
        }
    }

    /// 抬手：靠两次点击的间隔区分单击 / 双击。
    /// 不用 SwiftUI 的 `.onTapGesture(count:)` 是因为拿不到点击位置（两侧快退/快进要用 x 坐标），
    /// 而 `SpatialTapGesture` 和拖动叠在一起时优先级很难调。
    private func registerTap(at point: CGPoint, in size: CGSize) {
        guard gestures.isEnabled else {
            toggleChrome()
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastTapDate) < 0.35 {
            lastTapDate = .distantPast
            singleTapTask?.cancel()
            singleTapTask = nil
            logGesture("双击 \(Int(point.x)),\(Int(point.y))")
            handleDoubleTap(at: point, in: size)
        } else {
            lastTapDate = now
            singleTapTask?.cancel()
            singleTapTask = Task {
                try? await Task.sleep(nanoseconds: 330_000_000)
                guard !Task.isCancelled else { return }
                logGesture("单击")
                toggleChrome()
            }
        }
    }

    private var magnifyGesture: some Gesture {
        // MagnifyGesture（iOS 17+）替代旧的 MagnificationGesture：同一套语义，
        // 系统未来只维护这一条 API（看图页 1.3.16 已换，这里补齐）
        MagnifyGesture()
            .onChanged { value in
                guard gestures.isEnabled else { return }
                let scale = value.magnification
                if !isPinching {
                    isPinching = true
                    holdStartTask?.cancel()
                    // 捏合优先：把可能已经开始的方向拖动收掉，免得一边缩放一边改进度
                    if dragMode != .undecided {
                        model.cancelScrub()
                        dragMode = .undecided
                    }
                    didBeginPan = false
                }
                logGesture("捏合中 \(String(format: "%.2f", scale))")
                handlePinch(scale, ended: false)
            }
            .onEnded { value in
                handlePinch(value.magnification, ended: true)
                isPinching = false
                logGesture("捏合结束 \(String(format: "%.2f", value.magnification))")
            }
    }

    private func logGesture(_ text: String) {
        guard gestures.showDiagnostics else { return }
        // 拖动一秒会来几十次回调，限流一下，别让排障浮层自己把画面拖卡
        let now = Date()
        guard now.timeIntervalSince(lastDiagnosticAt) > 0.12 else { return }
        lastDiagnosticAt = now
        gestureEventCount += 1
        lastGestureText = text
    }

    private var diagnosticsOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("手势诊断 · 共 \(gestureEventCount) 次")
                .font(.caption2.weight(.semibold))
            Text("最近：\(lastGestureText)")
                .font(.caption2.monospacedDigit())
            Text("音量 \(Int((model.volume * 100).rounded()))% · 缩放 \(String(format: "%.1f", zoom))× · 亮度 \(Int(((1 - dimLevel) * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
            // 左边是界面状态，右边是真正落到播放器/画面上的值，两者不一致就是这一层断了
            Text("生效 系统音量 \(String(format: "%.2f", SystemVolume.shared.current)) · 遮罩 \(String(format: "%.2f", dimLevel)) · 画面 \(String(format: "%.2f", zoom))×")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
            Text("开关：\(gestures.isEnabled ? "开" : "关") · 上下拖动：\(gestures.vertical.title)")
                .font(.caption2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.18)) {
            chromeVisible.toggle()
        }
        scheduleHide()
    }

    private func handleDoubleTap(at point: CGPoint, in size: CGSize) {
        switch gestures.doubleTap {
        case .none:
            return
        case .playPause:
            model.togglePlay()
            showHUD(.playPause(model.isPlaying))
        case .forward:
            jump(by: gestures.seekStep)
        case .backward:
            jump(by: -gestures.seekStep)
        case .sides:
            let ratio = size.width > 0 ? point.x / size.width : 0.5
            if ratio < 1.0 / 3.0 {
                jump(by: -gestures.seekStep)
            } else if ratio > 2.0 / 3.0 {
                jump(by: gestures.seekStep)
            } else {
                model.togglePlay()
                showHUD(.playPause(model.isPlaying))
            }
        }
        scheduleHide()
    }

    private func jump(by delta: Double) {
        let duration = model.progress.duration
        guard duration > 0 else { return }
        let from = model.progress.currentTime
        let target = min(max(from + delta, 0), duration)
        // 双击跳转给 0.3 秒容差：精确到帧在远端流上要多读一个 GOP，明显卡顿
        model.seek(to: target, tolerance: 0.3)
        showHUD(.seek(delta: target - from, target: target))
    }

    private func beginPan(at point: CGPoint, in size: CGSize) {
        dragMode = .undecided
        dragStartPoint = point
        dragStartTime = model.progress.currentTime

        switch verticalAction(at: point, in: size) {
        case .brightness:
            dragStartValue = 1 - dimLevel
        case .volume:
            dragStartValue = Double(SystemVolume.shared.current)
        default:
            dragStartValue = 0
        }
    }

    private func updatePan(_ translation: CGSize, in size: CGSize) {
        if dragMode == .undecided {
            // 先看主方向：横向是拖进度，纵向是亮度/音量，避免两个方向互相干扰
            guard abs(translation.width) > 12 || abs(translation.height) > 12 else { return }
            dragMode = abs(translation.width) >= abs(translation.height) ? .seek : .vertical
            if dragMode == .seek {
                model.beginScrub()
                // 拖进度期间别让控件自己淡出（4 秒定时器可能正好在这一刻到点）
                hideTask?.cancel()
            }
        }

        switch dragMode {
        case .seek:
            guard gestures.horizontal == .seek else { return }
            let duration = model.progress.duration
            guard duration > 0 else { return }
            let perPoint = duration / Double(max(size.width, 1))
            let target = min(max(dragStartTime + Double(translation.width) * perPoint, 0), duration)
            model.scrub(to: target)
            showHUD(.seek(delta: target - dragStartTime, target: target), autoHide: false)

        case .vertical:
            let action = verticalAction(at: dragStartPoint, in: size)
            guard action == .brightness || action == .volume else { return }
            let span = Double(max(size.height, 1)) * 0.6
            let value = min(max(dragStartValue - Double(translation.height) / span, 0), 1)
            if action == .brightness {
                dimLevel = 1 - value
                showHUD(.brightness(value), autoHide: false)
            } else {
                model.setVolume(Float(value))
                // 真正调手机音量：AVPlayer.volume 只影响 App 内，用户会觉得音量条没动
                SystemVolume.shared.set(Float(value))
                showHUD(.volume(value), autoHide: false)
            }

        case .undecided:
            break
        }
    }

    private func endPan(_ translation: CGSize, in size: CGSize) {
        switch dragMode {
        case .seek:
            // 拖动过程中一次都没 seek，这里才真正跳一次
            if gestures.horizontal == .seek {
                model.commitScrub()
            } else {
                model.cancelScrub()
            }
            scheduleHide()
            hideHUD(after: 0.6)

        case .vertical:
            hideHUD(after: 0.4)

        case .undecided:
            break
        }
        dragMode = .undecided
    }

    private func handleHold(_ began: Bool) {
        guard gestures.longPress != .none else { return }
        if began {
            guard !isHolding else { return }
            isHolding = true
            model.beginHold(rate: gestures.longPress.rate)
            showHUD(.speed(gestures.longPress.rate), autoHide: false)
        } else {
            guard isHolding else { return }
            isHolding = false
            model.endHold()
            hideHUD(after: 0.5)
        }
    }

    private func handlePinch(_ scale: CGFloat, ended: Bool) {
        guard gestures.pinch == .zoom else { return }
        if ended {
            pinchBase = nil
            if zoom < 1.05 {
                withAnimation(.easeOut(duration: 0.2)) { zoom = 1 }
            }
            hideHUD(after: 0.5)
        } else {
            let base = pinchBase ?? zoom
            pinchBase = base
            zoom = min(max(base * scale, 1), 4)
            showHUD(.zoom(zoom), autoHide: false)
        }
    }

    private func verticalAction(at point: CGPoint, in size: CGSize) -> VerticalDragAction {
        switch gestures.vertical {
        case .none: return .none
        case .volume: return .volume
        case .brightness: return .brightness
        case .split:
            let ratio = size.width > 0 ? point.x / size.width : 0.5
            return ratio < 0.5 ? .brightness : .volume
        }
    }

    // MARK: - HUD

    private func showHUD(_ value: GestureHUD, autoHide: Bool = true) {
        hudTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) {
            hud.value = value
        }
        guard autoHide else { return }
        hideHUD(after: 0.75)
    }

    private func hideHUD(after seconds: Double) {
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.18)) {
                hud.value = nil
            }
        }
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) {
            zoom = min(max(value, 1), 4)
        }
    }

    // MARK: - 控件

    /// 控件整层：上下压暗 + 顶部栏 + 中央播放键 + 底部控件。
    ///
    /// 四层各自贴自己那一侧铺在 ZStack 里。上一版把「关闭 / 标题 / 切方向 / ⋯」
    /// 排在一条 HStack 上，右边有两个按钮，标题就被压得偏左；现在标题单独居中。
    private var chromeLayer: some View {
        ZStack {
            // 上下两条压暗，用渐变而不是整块黑条：中间画面完全不受影响。
            // 图上叠白图标，遇到亮画面（白底 PPT、雪景）不加这层就看不见了。
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.62), .black.opacity(0.22), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 150)

                Spacer(minLength: 0)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.28), .black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 180)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                bottomBar
            }

            centerPlayButton
        }
    }

    /// 顶部：关闭 / 标题 / 切方向 / 更多
    private var topBar: some View {
        ZStack {
            Text(item.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .shadow(color: .black.opacity(0.55), radius: 8, y: 1)
                // 两边各留出两个 36pt 按钮的位置，长文件名也不会钻到按钮底下
                .padding(.horizontal, 108)

            HStack(spacing: 10) {
                PlayerGlassButton(symbol: "chevron.left", label: "关闭") {
                    close()
                }

                Spacer(minLength: 0)

                // 图标画的是「点下去会变成的方向」，不是当前方向
                PlayerGlassButton(
                    symbol: isLandscape ? "rectangle.portrait" : "rectangle.landscape",
                    label: isLandscape ? "切换到竖屏" : "切换到横屏"
                ) {
                    toggleOrientation()
                }

                moreMenu
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 14)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                Task { await model.downloadAndPlay(item: item, serverID: serverID, connection: connection) }
            } label: {
                Label("下载到本地播放", systemImage: "arrow.down.circle")
            }
            Divider()
            Button {
                showGestureSettings = true
                scheduleHide()
            } label: {
                Label("播放手势设置", systemImage: "hand.draw")
            }
            Button {
                showGestureHelp = true
                scheduleHide()
            } label: {
                Label("手势说明", systemImage: "questionmark.circle")
            }
            if zoom > 1.01 {
                Divider()
                Button {
                    setZoom(1)
                } label: {
                    Label("还原画面缩放", systemImage: "arrow.down.right.and.arrow.up.left")
                }
            }
        } label: {
            PlayerGlassCircle {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel("更多")
    }

    /// 中央播放键：这一块是「点一下继续看」的主要落点，
    /// 别的区域都留给手势层（单击显隐、双击跳转、拖动调进度）。
    private var centerPlayButton: some View {
        Button {
            model.togglePlay()
            scheduleHide()
        } label: {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.40))
                    .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                    .frame(width: 66, height: 66)

                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.2), value: model.isPlaying)
            }
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(model.isPlaying ? "暂停" : "播放")
    }

    private var bottomBar: some View {
        PlayerBottomBar(
            progress: model.progress,
            rate: model.playbackRate,
            seekStep: gestures.seekStep,
            isLandscape: isLandscape,
            onBackward: {
                jump(by: -gestures.seekStep)
                scheduleHide()
            },
            onForward: {
                jump(by: gestures.seekStep)
                scheduleHide()
            },
            onRate: { value in
                model.setPlaybackRate(value)
                showHUD(.speed(value))
                scheduleHide()
            },
            onBegin: {
                hideTask?.cancel()
                model.beginScrub()
            },
            onScrub: { model.scrub(to: $0) },
            onCommit: {
                model.commitScrub()
                scheduleHide()
            }
        )
    }

    private func scheduleHide() {
        hideTask?.cancel()
        // 暂停时不自动收控件：用户正停在某一帧看，控件得留着
        guard model.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            // 正在拖进度 / seek 在途时别收控件，否则拖到一半底部整块消失
            guard !model.progress.isScrubbing, !model.progress.isSeeking else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                chromeVisible = false
            }
        }
    }

    private func errorOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))
            Button {
                Task { await model.downloadAndPlay(item: item, serverID: serverID, connection: connection) }
            } label: {
                Label("下载到本地播放", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isDownloading)
        }
        .padding(24)
        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(24)
    }
}

// MARK: - 底部控件

/// 只观察 `PlaybackProgress`：播放中每 0.25 秒的时间刷新只重绘这一条，
/// 不会把整页（含 `AVPlayerLayer`）带着重算。
@MainActor
private struct PlayerBottomBar: View {
    @ObservedObject var progress: PlaybackProgress
    var rate: Float
    var seekStep: Double
    var isLandscape: Bool
    var onBackward: () -> Void
    var onForward: () -> Void
    var onRate: (Float) -> Void
    var onBegin: () -> Void
    var onScrub: (Double) -> Void
    var onCommit: () -> Void

    private static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        VStack(spacing: isLandscape ? 2 : 6) {
            // 时间夹在进度条两端：一眼看到「现在到哪 / 一共多长」，
            // 又不用像上一版那样单独占一行还带个斜杠
            HStack(spacing: 12) {
                timeText(progress.displayTime)

                // 自绘进度条：整条 26pt 都是热区，点哪儿就跳哪儿
                ScrubBar(
                    value: progress.displayTime,
                    total: progress.duration,
                    isActive: progress.isSeeking,
                    onBegin: onBegin,
                    onScrub: onScrub,
                    onCommit: onCommit
                )
                .frame(height: 26)
                .disabled(progress.duration <= 0)
                .opacity(progress.duration > 0 ? 1 : 0.45)

                timeText(progress.duration)
            }

            HStack(spacing: 10) {
                PlayerGlassButton(
                    symbol: backSymbol,
                    size: 34,
                    label: "后退 \(Int(seekStep)) 秒"
                ) {
                    onBackward()
                }

                PlayerGlassButton(
                    symbol: forwardSymbol,
                    size: 34,
                    label: "前进 \(Int(seekStep)) 秒"
                ) {
                    onForward()
                }

                if progress.isBuffering {
                    // 跳到未缓冲位置 / 网络跟不上时转圈：远端流要重新读一段数据，
                    // 不给反馈的话用户只会觉得「点了没反应」
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                        .padding(.leading, 2)
                }

                Spacer(minLength: 8)

                speedMenu
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, isLandscape ? 10 : 20)
    }

    private func timeText(_ seconds: Double) -> some View {
        Text(Format.duration(seconds))
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 0.5)
    }

    /// 图标跟着「快进跨度」走：按钮上写的数字就是实际会跳的秒数，
    /// 设置里改成 30 秒，这里也跟着变成 30。
    private var backSymbol: String {
        switch Int(seekStep) {
        case 10: return "gobackward.10"
        case 15: return "gobackward.15"
        case 30: return "gobackward.30"
        default: return "gobackward"   // 5 秒没有带数字的符号
        }
    }

    private var forwardSymbol: String {
        switch Int(seekStep) {
        case 10: return "goforward.10"
        case 15: return "goforward.15"
        case 30: return "goforward.30"
        default: return "goforward"
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(Self.rates, id: \.self) { value in
                Button {
                    onRate(value)
                } label: {
                    if abs(rate - value) < 0.01 {
                        Label(rateText(value), systemImage: "checkmark")
                    } else {
                        Text(rateText(value))
                    }
                }
            }
        } label: {
            Text(rateText(rate))
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                // 非 1× 时用强调色，提醒「现在不是常速」
                .foregroundStyle(rate == 1 ? Color.white : Color.accentColor)
                .frame(height: 34)
                .padding(.horizontal, 13)
                .background {
                    Capsule(style: .continuous)
                        .fill(.black.opacity(0.38))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                        )
                }
                .contentShape(Capsule(style: .continuous))
        }
        .accessibilityLabel("播放速度")
    }

    private func rateText(_ value: Float) -> String {
        if value == value.rounded() { return "\(Int(value))×" }
        return String(format: "%g×", Double(value))
    }
}

// MARK: - 控件零件

/// 圆形玻璃底 + 内容的容器。
/// `Menu` 的 label 用不了 `Button` 那套，所以玻璃底单独抽一层共用。
@MainActor
private struct PlayerGlassCircle<Content: View>: View {
    var size: CGFloat = 36
    let content: Content

    init(size: CGFloat = 36, @ViewBuilder content: () -> Content) {
        self.size = size
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(.black.opacity(0.38))
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            }
            .contentShape(Circle())
    }
}

/// 播放页统一的圆形图标按钮
@MainActor
private struct PlayerGlassButton: View {
    let symbol: String
    var size: CGFloat = 36
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            PlayerGlassCircle(size: size) {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(label)
    }
}

/// 按下缩一点、暗一点：这些按钮都浮在画面上，需要一点实体感
private struct PlayerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

/// 自绘进度条。相比系统 `Slider` 多两件事：
/// 1. **单击即跳转**——`DragGesture(minimumDistance: 0)` 让「按下」就等于「拖到该点」，
///    松手立刻 commit；系统 Slider 只有拖才动，点一下没反应。
/// 2. 拖动时轨道变粗、圆点变大，手指压着的地方有明确反馈。
///
/// 它仍然只写本地 `scrubTime`（走 `onScrub`），一次都不碰播放器，
/// 所以拖动过程依旧不会像 1.3.30 之前那样每帧 seek 远端流。
@MainActor
private struct ScrubBar: View {
    var value: Double
    var total: Double
    /// seek 在途（不只是手指在拖）：圆点保持放大，表示「正在跳」
    var isActive: Bool
    var onBegin: () -> Void
    var onScrub: (Double) -> Void
    var onCommit: () -> Void

    @State private var isDragging = false

    private var fraction: Double {
        guard total > 0, value.isFinite else { return 0 }
        return min(max(value / total, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let barHeight: CGFloat = (isDragging || isActive) ? 6 : 4
            let knob: CGFloat = (isDragging || isActive) ? 15 : 11

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.28))
                    .frame(height: barHeight)

                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: width * CGFloat(fraction), height: barHeight)

                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 0.5)
                    // 贴到两端时圆点不越界（否则最左/最右会露出半个圆）
                    .offset(x: min(max(width * CGFloat(fraction) - knob / 2, 0), max(width - knob, 0)))
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
            // 整块 26pt 高都是热区：点哪儿跳哪儿
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onBegin()
                        }
                        onScrub(seconds(at: gesture.location.x, width: width))
                    }
                    .onEnded { gesture in
                        // 再取一次点按位置：单击时 onChanged 和 onEnded 的 x 相同，
                        // 拖到边缘松手时这里能拿到最终落点
                        onScrub(seconds(at: gesture.location.x, width: width))
                        isDragging = false
                        onCommit()
                    }
            )
            .animation(.easeOut(duration: 0.14), value: isDragging)
            .animation(.easeOut(duration: 0.14), value: isActive)
        }
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> Double {
        guard total > 0, width > 0 else { return 0 }
        let ratio = min(max(Double(x / width), 0), 1)
        return ratio * total
    }
}

// MARK: - 手势 HUD 浮层

@MainActor
private struct PlayerHUDOverlay: View {
    @ObservedObject var state: HUDState
    let duration: Double

    var body: some View {
        if let value = state.value {
            content(value)
                .offset(y: offset(for: value))
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// 除「播放/暂停」气泡外都抬到播放键上方，避免压住中间的暂停按钮
    private func offset(for value: GestureHUD) -> CGFloat {
        switch value {
        case .playPause:
            return 0
        default:
            return -110
        }
    }

    @ViewBuilder
    private func content(_ value: GestureHUD) -> some View {
        switch value {
        case let .seek(delta, target):
            VStack(spacing: 4) {
                Text(seekDeltaText(delta))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("\(Format.duration(target)) / \(Format.duration(duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

        case let .volume(level):
            pill(icon: level <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                 text: "\(Int((level * 100).rounded()))%")

        case let .brightness(level):
            pill(icon: "sun.max.fill", text: "\(Int((level * 100).rounded()))%")

        case let .speed(rate):
            pill(icon: "forward.fill", text: rateText(rate) + " 倍速播放中")

        case let .zoom(scale):
            pill(icon: "arrow.up.left.and.arrow.down.right", text: rateText(Float(scale)) + "×")

        case let .playPause(showingPlay):
            Image(systemName: showingPlay ? "play.fill" : "pause.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.black.opacity(0.45), in: Circle())
        }
    }

    private func pill(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
            Text(text)
                .font(.footnote.monospacedDigit())
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func seekDeltaText(_ delta: Double) -> String {
        let magnitude = Format.duration(abs(delta))
        if delta > 0.3 { return "+" + magnitude }
        if delta < -0.3 { return "-" + magnitude }
        return magnitude
    }

    private func rateText(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))" : String(format: "%.1f", rate)
    }
}
