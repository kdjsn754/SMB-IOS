import AVFoundation
import AVKit
import Combine
import MediaPlayer
import SwiftUI

@MainActor
final class VideoPlaybackModel: ObservableObject {
    let player = AVPlayer()

    @Published var errorMessage: String?
    @Published var downloadProgress: Double?
    @Published var isDownloading = false
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    /// 拖动进度条 / 手势拖进度时暂停刷新，避免手指被时间回调抢走
    @Published var isSeeking = false
    /// 播放器音量（0…1），右上角音量面板与上下拖动手势共用同一份，退出重进也记得
    @Published fileprivate(set) var volume: Float = 1

    private static let volumeKey = "settings.player.volume"

    private var currentAsset: AVURLAsset?
    private var statusCancellable: AnyCancellable?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    /// 长按加速前的播放状态，松开后要还原
    private var wasPlayingBeforeHold = false

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
            if duration > 0, currentTime >= duration - 0.3 {
                player.seek(to: .zero)
                currentTime = 0
            }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
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

    /// 长按加速用：按住时把速率调高，松手还原。
    /// 按住前是暂停的话，松手后回到暂停（和主流播放器一致）。
    func beginHold(rate: Float) {
        guard rate > 1, player.currentItem != nil else { return }
        wasPlayingBeforeHold = player.timeControlStatus == .playing || player.rate > 0
        player.rate = rate
        isPlaying = true
    }

    func endHold() {
        guard player.currentItem != nil else { return }
        if wasPlayingBeforeHold {
            player.rate = 1
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
        isPlaying = false
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
            Task { @MainActor [weak self] in
                guard let self, !self.isSeeking else { return }
                self.currentTime = time.seconds
                self.isPlaying = self.player.timeControlStatus == .playing
                if let seconds = self.player.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                }
            }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        statusCancellable = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard status == .failed else { return }
                let reason = item?.error?.localizedDescription ?? "编码格式不受支持或网络中断"
                self?.errorMessage = "无法播放：\(reason)"
            }
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

    // 手势反馈
    @State private var hud: GestureHUD?
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

                if let hud {
                    // 抬到播放键上方：两者都在正中会重叠（音量胶囊正好压在暂停键上）
                    hudView(hud)
                        .offset(y: hudOffset(for: hud))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                if chromeVisible {
                    // 顶部栏（关闭 / 标题 / ⋯）和底部控件一起显隐，播放 4 秒后一起收起
                    VStack(spacing: 0) {
                        topBar
                        Spacer(minLength: 0)
                    }
                    .transition(.opacity)

                    controls
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
        }
        .preferredColorScheme(.dark)
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
                        model.isSeeking = false
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
        guard model.duration > 0 else { return }
        let target = min(max(model.currentTime + delta, 0), model.duration)
        let real = target - model.currentTime
        model.seek(to: target)
        showHUD(.seek(delta: real, target: target))
    }

    private func beginPan(at point: CGPoint, in size: CGSize) {
        dragMode = .undecided
        dragStartPoint = point
        dragStartTime = model.currentTime

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
                model.isSeeking = true
            }
        }

        switch dragMode {
        case .seek:
            guard gestures.horizontal == .seek, model.duration > 0 else { return }
            let perPoint = model.duration / Double(max(size.width, 1))
            let target = min(max(dragStartTime + Double(translation.width) * perPoint, 0), model.duration)
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
            model.isSeeking = false
            if gestures.horizontal == .seek, model.duration > 0 {
                // 远端流只在松手时真正 seek 一次：拖动过程中每帧都 seek 会把 SMB 读打爆
                let perPoint = model.duration / Double(max(size.width, 1))
                let target = min(max(dragStartTime + Double(translation.width) * perPoint, 0), model.duration)
                model.seek(to: target)
            }
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
            hud = value
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
                hud = nil
            }
        }
    }

    @ViewBuilder
    private func hudView(_ value: GestureHUD) -> some View {
        switch value {
        case let .seek(delta, target):
            VStack(spacing: 4) {
                Text(seekDeltaText(delta))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("\(Format.duration(target)) / \(Format.duration(model.duration))")
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

    private func setZoom(_ value: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) {
            zoom = min(max(value, 1), 4)
        }
    }

    // MARK: - 控件

    /// 顶部栏：自己做，跟着 `chromeVisible` 一起淡出（系统导航栏不参与自动隐藏）
    private var topBar: some View {
        HStack(spacing: 12) {
            // iOS 26 系统标准关闭钮（Liquid Glass 圆钮），替代自绘 xmark + 黑圈
            Button(role: .close) { dismiss() }
                .accessibilityLabel("关闭")

            Text(item.name)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)

            Menu {
                if zoom > 1.01 {
                    Button {
                        setZoom(1)
                    } label: {
                        Label("还原画面缩放", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    Divider()
                }
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
                Divider()
                Button {
                    Task { await model.downloadAndPlay(item: item, serverID: serverID, connection: connection) }
                } label: {
                    Label("下载到本地播放", systemImage: "arrow.down.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    /// 手势 HUD 的纵向偏移：除「播放/暂停」气泡外都抬到播放键上方，避免压住中间的暂停按钮
    private func hudOffset(for value: GestureHUD) -> CGFloat {
        switch value {
        case .playPause:
            return 0
        default:
            return -110
        }
    }

    private var controls: some View {
        ZStack {
            Button {
                model.togglePlay()
                scheduleHide()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)

            VStack {
                Spacer()
                progressBar
            }
        }
    }

    private var progressBar: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { model.duration > 0 ? min(model.currentTime, model.duration) : 0 },
                    set: { model.seek(to: $0) }
                ),
                in: 0...max(model.duration, 0.1),
                onEditingChanged: { editing in
                    model.isSeeking = editing
                }
            )
            .tint(.white)

            HStack(spacing: 6) {
                Text(Format.duration(model.currentTime))
                Text("/")
                    .foregroundStyle(.white.opacity(0.5))
                Text(Format.duration(model.duration))
                Spacer()
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
        .padding(.top, 10)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard model.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
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
