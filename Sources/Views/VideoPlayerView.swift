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
        player.volume = volume
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

    /// 音量统一走这里：手势上下拖、右上角音量面板、静音按钮都调它，保证 UI 与播放器一致。
    /// 用 `AVPlayer.volume`（App 内音量）而不是 `MPVolumeView`，不弹系统音量条、也不动系统音量。
    func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        guard abs(clamped - volume) > 0.0005 else { return }
        volume = clamped
        player.volume = clamped
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

    /// 双指捏合缩放：缩放 **AVPlayerLayer 自己**，而不是给 view 套 transform。
    /// 套 transform 会和 SwiftUI 的布局打架（每次 layout 都可能被重置），
    /// 直接改 layer 的仿射变换既不会被布局覆盖，也不会让手势坐标跟着缩放。
    func applyZoom(_ scale: CGFloat) {
        let clamped = min(max(scale, 1), 4)
        guard let layer = playerLayer else { return }
        guard abs(layer.affineTransform().a - clamped) > 0.001 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(CGAffineTransform(scaleX: clamped, y: clamped))
        CATransaction.commit()
    }
}

private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var zoom: CGFloat = 1
    var gesturesEnabled: Bool = true
    var onEvent: @MainActor (PlayerGestureEvent) -> Void = { _ in }

    func makeCoordinator() -> PlayerGestureCoordinator {
        PlayerGestureCoordinator(onEvent: onEvent)
    }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.player = player
        // 手势直接挂在画面视图上：不依赖上面那层 SwiftUI 透明视图能不能命中
        context.coordinator.attach(to: view)
        context.coordinator.setEnabled(gesturesEnabled)
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
        context.coordinator.onEvent = onEvent
        context.coordinator.setEnabled(gesturesEnabled)
        uiView.applyZoom(zoom)
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

/// 右上角浮层：音量 / 画面缩放
private enum QuickPanel: Equatable {
    case volume
    case zoom
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
    /// 右上角音量 / 缩放浮层
    @State private var quickPanel: QuickPanel?
    /// 右上角「手势」按钮弹出的设置面板
    @State private var showGestureSettings = false
    /// 手势诊断（设置里可开关）：看看到底有没有收到手势
    @State private var gestureEventCount = 0
    @State private var lastGestureText = "还没收到任何手势"
    @State private var lastDiagnosticAt = Date.distantPast

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                PlayerSurface(
                    player: model.player,
                    zoom: zoom,
                    gesturesEnabled: gestures.isEnabled,
                    onEvent: handle
                )
                .ignoresSafeArea()

                // 亮度遮罩：盖住画面、但盖不到控件和 HUD
                Color.black
                    .opacity(dimLevel)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // 手势挂在画面视图上；只有关掉手势时才铺一层，保证还能单击显隐控件
                if !gestures.isEnabled {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { toggleChrome() }
                }

                // 右上角浮层打开时，点空白处先收起浮层（同时挡住误触播放手势）
                if quickPanel != nil {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture { closeQuickPanel() }
                }

                if let hud {
                    hudView(hud)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                if chromeVisible {
                    controls
                        .transition(.opacity)
                }

                if gestures.showDiagnostics {
                    diagnosticsOverlay
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, 8)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let panel = quickPanel {
                    quickPanelView(panel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, 8)
                        .padding(.trailing, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
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
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            toggleQuickPanel(.volume)
                        } label: {
                            Image(systemName: volumeIconName)
                                .font(.system(size: 16, weight: .medium))
                        }
                        .accessibilityLabel("音量")

                        Button {
                            toggleQuickPanel(.zoom)
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(zoom > 1.01 ? Color.accentColor : Color.primary)
                        }
                        .accessibilityLabel("画面缩放")

                        Button {
                            closeQuickPanel()
                            showGestureSettings = true
                        } label: {
                            Image(systemName: "hand.draw")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .accessibilityLabel("播放手势设置")

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
                                Task { await model.downloadAndPlay(item: item, serverID: serverID, connection: connection) }
                            } label: {
                                Label("下载到本地播放", systemImage: "arrow.down.circle")
                            }
                            Divider()
                            Button {
                                showGestureHelp = true
                            } label: {
                                Label("手势说明", systemImage: "hand.draw")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
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
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            hudTask?.cancel()
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

    private func handle(_ event: PlayerGestureEvent) {
        if gestures.showDiagnostics {
            // 拖动一秒会来几十次事件，限流一下，别让排障浮层自己把画面拖卡
            let now = Date()
            if now.timeIntervalSince(lastDiagnosticAt) > 0.12 {
                lastDiagnosticAt = now
                gestureEventCount += 1
                lastGestureText = describe(event)
            }
        }

        switch event {
        case .singleTap(_, _):
            toggleChrome()
        case let .doubleTap(point, size):
            handleDoubleTap(at: point, in: size)
        case let .panBegan(point, size):
            guard !isPinching else { return }
            beginPan(at: point, in: size)
        case let .panChanged(translation, size):
            guard !isPinching else { return }
            updatePan(translation, in: size)
        case let .panEnded(translation, size):
            guard !isPinching else { return }
            endPan(translation, in: size)
        case let .longPress(began):
            handleHold(began)
        case let .pinch(scale, ended):
            if !ended, !isPinching {
                isPinching = true
                // 捏合优先：把可能已经开始的方向拖动收掉，免得一边缩放一边改进度
                if dragMode != .undecided {
                    model.isSeeking = false
                    dragMode = .undecided
                }
            }
            handlePinch(scale, ended: ended)
            if ended { isPinching = false }
        }
    }

    private func describe(_ event: PlayerGestureEvent) -> String {
        switch event {
        case let .singleTap(point, size):
            return "单击 \(Int(point.x)),\(Int(point.y)) / 画布 \(Int(size.width))×\(Int(size.height))"
        case .doubleTap:
            return "双击"
        case .panBegan:
            return "拖动开始"
        case let .panChanged(translation, _):
            return "拖动中 \(Int(translation.width)),\(Int(translation.height))"
        case let .panEnded(translation, _):
            return "拖动结束 \(Int(translation.width)),\(Int(translation.height))"
        case let .longPress(began):
            return began ? "长按按下" : "长按松开"
        case let .pinch(scale, ended):
            return "\(ended ? "捏合结束" : "捏合中") \(String(format: "%.2f", scale))"
        }
    }

    private var diagnosticsOverlay: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("手势诊断 · 共 \(gestureEventCount) 次")
                .font(.caption2.weight(.semibold))
            Text("最近：\(lastGestureText)")
                .font(.caption2.monospacedDigit())
            Text("音量 \(Int((model.volume * 100).rounded()))% · 缩放 \(String(format: "%.1f", zoom))× · 亮度 \(Int(((1 - dimLevel) * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
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
            dragStartValue = Double(model.volume)
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

    // MARK: - 右上角浮层（音量 / 画面缩放）

    private var volumeIconName: String {
        let level = model.volume
        if level <= 0.001 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func toggleQuickPanel(_ panel: QuickPanel) {
        hideTask?.cancel()
        if !chromeVisible {
            withAnimation(.easeInOut(duration: 0.18)) { chromeVisible = true }
        }
        withAnimation(.easeOut(duration: 0.16)) {
            quickPanel = quickPanel == panel ? nil : panel
        }
    }

    private func closeQuickPanel() {
        guard quickPanel != nil else { return }
        withAnimation(.easeOut(duration: 0.14)) { quickPanel = nil }
        scheduleHide()
    }

    @ViewBuilder
    private func quickPanelView(_ panel: QuickPanel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: panel == .volume ? volumeIconName : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .semibold))
                Text(panel == .volume ? "音量" : "画面缩放")
                    .font(.footnote.weight(.semibold))
                Spacer(minLength: 12)
                Text(panel == .volume
                     ? "\(Int((model.volume * 100).rounded()))%"
                     : String(format: "%.1f×", zoom))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
            }

            if panel == .volume {
                Slider(
                    value: Binding(get: { Double(model.volume) },
                                   set: { model.setVolume(Float($0)) }),
                    in: 0...1
                )
                .tint(.white)

                HStack(spacing: 8) {
                    quickChip("静音") { model.setVolume(0) }
                    quickChip("50%") { model.setVolume(0.5) }
                    quickChip("100%") { model.setVolume(1) }
                }
            } else {
                Slider(
                    value: Binding(get: { Double(zoom) },
                                   set: { setZoom(CGFloat($0)) }),
                    in: 1...4
                )
                .tint(.white)

                HStack(spacing: 6) {
                    ForEach(Self.zoomChoices, id: \.self) { value in
                        quickChip(zoomChipTitle(value), selected: abs(zoom - CGFloat(value)) < 0.01) {
                            setZoom(CGFloat(value))
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: 244)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .environment(\.colorScheme, .dark)
    }

    private static let zoomChoices: [Double] = [1, 1.5, 2, 3, 4]

    private func zoomChipTitle(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value))×" : String(format: "%.1f×", value)
    }

    private func quickChip(_ title: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.monospacedDigit())
                .fontWeight(selected ? .semibold : .regular)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    Color.white.opacity(selected ? 0.26 : 0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) {
            zoom = min(max(value, 1), 4)
        }
    }

    // MARK: - 控件

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
        // 右上角浮层开着的时候不要自动收控件，否则浮层会跟着消失
        guard model.isPlaying, quickPanel == nil else { return }
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
