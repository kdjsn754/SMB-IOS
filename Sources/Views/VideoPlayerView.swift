import AVFoundation
import SwiftUI
import UIKit

/// 播放页。
///
/// 分四层，从下往上：
/// 1. `PlayerStage` —— 画面 + 亮度遮罩，只跟手势里的缩放/亮度重算；
/// 2. 手势层 —— 一整块可命中的矩形，拖动 / 单击 / 双击 / 长按 / 捏合都归它；
/// 3. HUD —— 手势反馈与双击涟漪；
/// 4. `PlayerChromeLayer` —— 顶部栏 + 中央控制 + 底部栏，自己观察自己的显隐状态。
///
/// **这个 struct 本体在拖动过程中一次都不重算**，这是「流畅」的前提：
/// 手势的中间状态在 `PlayerGestureEngine` 里（不发布），控件显隐在 `ChromeVisibility` 里
/// （由子视图观察）。页面一旦在拖动中途重算，手势层会被重建，拖动就会断。
@MainActor
struct VideoPlayerView: View {
    let item: FileItem
    let serverID: UUID
    let connection: SMBConnection
    /// 同目录的视频，按目录页当前的排序。单文件时就是一个元素。
    var playlist: [FileItem] = []

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = VideoPlaybackModel()
    /// 手势引擎用 `@State` 存：它不是 `ObservableObject`，页面永远不因它重算。
    @State private var engine = PlayerGestureEngine()
    @StateObject private var chrome = ChromeVisibility()
    @ObservedObject private var gestures = PlayerGestureSettings.shared
    /// 横竖屏策略（自动 / 强制竖 / 强制横），持久化在 UserDefaults
    @ObservedObject private var display = PlayerDisplaySettings.shared

    @State private var hideTask: Task<Void, Never>?
    /// 单击「隐藏控件」延迟 0.26 秒执行：双击时会被取消，避免控件闪一下
    @State private var tapHideTask: Task<Void, Never>?

    @State private var panel: PlayerPanel?
    /// 面板的返回栈：「更多 → 屏幕方向」时记下 `.more`，二级面板左上角就能退回上一级
    @State private var panelHistory: [PlayerPanel] = []
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var showGestureHelp = false

    // 横竖屏
    /// 进播放页那一刻的形态。退出时转回它——「回到手机原本的状态」，
    /// 而不是「按你躺着的姿态决定」。
    @State private var entryMode: ScreenMode = ScreenOrientationController.current
    /// 自动识别每个片子只判一次；连播换片时重置（见 `onChange(of: currentItem)`）
    @State private var didAutoOrient = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerStage(visual: engine.visual, player: model.player, fit: model.fit)

            // 手势层在控件下面：按钮仍然点得动，其余区域的触摸都归它
            gestureSurface

            PlayerHUDOverlay(bus: engine.hud)
            SeekRippleOverlay(bus: engine.hud)

            PlayerChromeLayer(
                chrome: chrome,
                title: currentTitle,
                subtitle: playlistSubtitle,
                progress: model.progress,
                isPlaying: model.isPlaying,
                didReachEnd: model.didReachEnd,
                canPlayNext: model.canPlayNext,
                canPlayPrevious: model.canPlayPrevious,
                rate: model.playbackRate,
                fit: model.fit,
                hasSubtitles: !model.subtitles.isEmpty,
                subtitleEnabled: model.selectedSubtitle != nil,
                seekStep: gestures.seekStep,
                sleepDeadline: model.sleepDeadline,
                onClose: close,
                onToggleLock: toggleLock,
                onPlayPause: {
                    model.togglePlay()
                    scheduleHide()
                },
                onReplay: {
                    model.seek(to: 0, tolerance: 0.1)
                    if !model.isPlaying { model.togglePlay() }
                    scheduleHide()
                },
                onNext: {
                    Task {
                        await model.playNext()
                        scheduleHide()
                    }
                },
                onPrevious: {
                    Task {
                        await model.playPrevious()
                        scheduleHide()
                    }
                },
                onBackward: { jump(by: -gestures.seekStep) },
                onForward: { jump(by: gestures.seekStep) },
                onRate: { open(.speed) },
                onFit: { model.setFit(nextFit) ; scheduleHide() },
                onSubtitles: { open(.subtitle) },
                onMore: { open(.more) },
                onBeginScrub: {
                    // 拖进度期间别让控件自己淡出（3.6 秒定时器可能正好在这一刻到点）
                    hideTask?.cancel()
                    tapHideTask?.cancel()
                    model.beginScrub()
                },
                onScrub: { model.scrub(to: $0) },
                onCommitScrub: {
                    model.commitScrub()
                    scheduleHide()
                }
            )

            if let toast {
                VStack {
                    Spacer()
                    PlayerToast(text: toast)
                        .padding(.bottom, 150)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            if let progress = model.downloadProgress {
                downloadOverlay(progress)
            }

            if let message = model.errorMessage {
                errorOverlay(message)
            }

            if let panel {
                panelLayer(panel)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        // 系统那条「双指捏合退出」和页内捏合缩放是同一形态，不摘掉一捏就关页
        .background(PinchDismissDisabler().allowsHitTesting(false))
        // 视频尺寸就绪（首次读元数据可能几百毫秒）后按比例转一次
        .onChange(of: model.videoSize) { _, size in
            applyAutoOrientation(for: size)
        }
        // 连播换了片子：自动识别要按新的比例重新判一次
        .onChange(of: model.currentItem?.path) { _, _ in
            didAutoOrient = false
        }
        .onChange(of: model.didReachEnd) { _, ended in
            guard ended else { return }
            tapHideTask?.cancel()
            withAnimation(.easeOut(duration: 0.2)) { chrome.visible = true }
        }
        .onChange(of: model.resumeHint) { _, hint in
            guard let hint else { return }
            showToast(hint)
        }
        .alert("播放器手势", isPresented: $showGestureHelp) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(gestureHelpText)
        }
        .onAppear {
            engine.model = model
            // 进页面还没转屏之前，按钮就要显示对：横着进来的（浏览器里横屏点开）
            // 得马上是「竖屏」文案 + 竖条，否则第一眼又是反的。
            chrome.isLandscape = (entryMode == .landscape)
            // 按记住的策略先摆好方向（强制横屏的竖片，一进来就该是横的）
            applyStoredOrientation()

            // 强制方向要再补一次：覆盖层弹出的那 0.35 秒里，`requestGeometryUpdate`
            // 有可能被系统直接忽略，只请求一次就会停在进入时的形态上（竖屏策略下看不出来，
            // 强制横屏的竖片最明显——明明选了横屏却还是竖的）。
            if display.orientationMode != .auto {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 420_000_000)
                    guard display.orientationMode != .auto else { return }
                    applyStoredOrientation()
                }
            }
        }
        .task {
            await model.start(
                item: item,
                serverID: serverID,
                connection: connection,
                playlist: playlist
            )
            // 用户可能用实体音量键调过，进页面先对齐一次
            model.syncVolumeFromSystem()
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            tapHideTask?.cancel()
            toastTask?.cancel()
            engine.setLocked(false)
            model.stop()
            // 兜底：正常关闭走 `close()`，那里已经把方向转回去了；
            // 这里是防止有别的退出路径（比如被上层直接 remove）时锁留在横屏。
            ScreenOrientationController.restore(to: entryMode)
        }
    }

    // MARK: - 文案

    private var currentTitle: String {
        model.currentItem?.name ?? item.name
    }

    /// 有多个视频时显示「第 3 / 12 个」，单文件不占这行
    private var playlistSubtitle: String? {
        guard playlist.count > 1, let current = model.currentItem,
              let index = playlist.firstIndex(where: { $0.path == current.path })
        else { return nil }
        return "第 \(index + 1) / \(playlist.count) 个"
    }

    private var nextFit: VideoFit {
        switch model.fit {
        case .aspect: return .fill
        case .fill: return .stretch
        case .stretch: return .aspect
        }
    }

    // MARK: - 横竖屏

    /// 当前策略。面板里三选一，选择会记住。
    private var orientationMode: PlaybackOrientationMode { display.orientationMode }

    /// 进页面时按「记住的策略」落一次方向。
    ///
    /// 这一步就是「强制横屏之后，退出再打开还是横屏」的全部实现：
    /// 策略存在 UserDefaults 里，跟视频比例无关，所以竖片也会被摆成横屏。
    /// 自动识别这时尺寸还没读到，交给 `onChange(of: videoSize)` 那一路。
    private func applyStoredOrientation() {
        switch display.orientationMode {
        case .portrait: applyOrientation(.portrait)
        case .landscape: applyOrientation(.landscape)
        case .auto: applyAutoOrientation(for: model.videoSize)
        }
    }

    /// 按视频比例自动转：宽/高 ≥ 1.15 当横片（4:3、16:9 都算），
    /// 1.15 以下留在竖屏（竖拍、方形）。只自动一次，且只在「自动识别」策略下生效。
    private func applyAutoOrientation(for size: CGSize) {
        guard display.orientationMode == .auto, !didAutoOrient,
              size.width > 0, size.height > 0 else { return }
        didAutoOrient = true
        applyOrientation(size.width / size.height >= 1.15 ? .landscape : .portrait)
    }

    /// 面板里选中一个策略：先记下来，再立刻转。
    private func selectOrientation(_ mode: PlaybackOrientationMode) {
        display.orientationMode = mode
        didAutoOrient = false
        closePanel()

        switch mode {
        case .portrait:
            applyOrientation(.portrait)
            showToast("强制竖屏（已记住）")
        case .landscape:
            applyOrientation(.landscape)
            showToast("强制横屏（已记住）")
        case .auto:
            // 尺寸已经读到就立刻判；还没读到就等 `onChange(of: videoSize)`
            applyAutoOrientation(for: model.videoSize)
            showToast("自动识别方向")
        }
        scheduleHide()
    }

    /// 转屏的唯一入口：**先把形态写进控件状态，再请求系统转**。
    private func applyOrientation(_ mode: ScreenMode) {
        chrome.isLandscape = (mode == .landscape)
        ScreenOrientationController.lock(mode)
    }

    /// 关闭播放页：先把方向转回「进页面之前」的形态，再退出。
    ///
    /// 反过来（先 dismiss 再转）的话，退出去那一帧下面还是横着的浏览器，
    /// 随后再被掰回竖屏，看起来就是「页面先横着闪一下」。
    ///
    /// **只在方向真的要变时才等**：竖屏看竖屏视频（最常见的一种）根本不用转，
    /// 白等 260 ms 就变成「点了关闭还顿一下」，退出动画被硬生生推迟了。
    private func close() {
        engine.setLocked(false)
        chrome.locked = false
        panel = nil

        guard ScreenOrientationController.current != entryMode else {
            ScreenOrientationController.restore(to: entryMode)
            dismiss()
            return
        }

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
    /// SwiftUI 里只有**能画出像素**的视图才稳定参与命中测试。
    private var gestureSurface: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            engine.dragChanged(value, in: proxy.size)
                            // 开始横向拖进度时把底部控件临时叫出来：控件收着的时候拖画面，
                            // 不把底部进度条叫出来，用户只能盯着 HUD 的数字猜。
                            // （改的是 `chrome` 而不是页面的 @State，所以手势不会被打断）
                            if engine.isSeekingByGesture, !chrome.visible, !chrome.locked {
                                tapHideTask?.cancel()
                                hideTask?.cancel()
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    chrome.visible = true
                                }
                            }
                        }
                        .onEnded { value in
                            switch engine.dragEnded(value, in: proxy.size) {
                            case .singleTap:
                                handleSingleTap()
                            case .doubleTap:
                                handleDoubleTap()
                            case .none:
                                scheduleHide()
                            }
                        }
                )
                .simultaneousGesture(
                    // MagnifyGesture（iOS 17+）替代旧的 MagnificationGesture
                    MagnifyGesture()
                        .onChanged { engine.magnify($0, finished: false) }
                        .onEnded { engine.magnify($0, finished: true) }
                )
        }
        .ignoresSafeArea()
    }

    /// 单击：**立即**显示，**延迟**隐藏。
    ///
    /// 延迟那一半是给双击让路的：双击的第一下手也会走到这里，
    /// 若隐藏立刻生效，双击过程中控件会闪一下。反过来「显示」可以立即做，
    /// 因为双击时本来就要看到控件。
    private func handleSingleTap() {
        guard !chrome.locked, panel == nil else { return }
        tapHideTask?.cancel()
        if chrome.visible {
            tapHideTask = Task {
                try? await Task.sleep(nanoseconds: 260_000_000)
                guard !Task.isCancelled else { return }
                hideTask?.cancel()
                withAnimation(.easeInOut(duration: 0.18)) {
                    chrome.visible = false
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                chrome.visible = true
            }
            scheduleHide()
        }
    }

    /// 双击已经由引擎执行完动作，这里只负责让控件可见 + 重置自动隐藏计时
    private func handleDoubleTap() {
        tapHideTask?.cancel()
        if !chrome.visible, !chrome.locked {
            withAnimation(.easeInOut(duration: 0.16)) { chrome.visible = true }
        }
        scheduleHide()
    }

    /// 跳转（底部 ±秒 按钮用）。
    ///
    /// 只走 HUD、不再发涟漪：涟漪是「点在画面上」的反馈，从底栏按钮点出来的
    /// 画面上不该凭空出现一圈。双击跳转反过来——那里只有涟漪，没有中间那块 HUD
    /// （HUD 会和播放 / 暂停按钮撞在一起，见 `PlayerHUDOverlay` 的注释）。
    private func jump(by delta: Double) {
        let duration = model.progress.duration
        guard duration > 0 else { return }
        let from = model.progress.currentTime
        let target = min(max(from + delta, 0), duration)
        model.seek(to: target, tolerance: 0.3)
        engine.hud.show(
            .seek(delta: target - from, target: target, total: duration),
            autoHideAfter: 0.8
        )
        scheduleHide()
    }

    // MARK: - 锁定

    private func toggleLock() {
        let next = !chrome.locked
        chrome.locked = next
        engine.setLocked(next)
        tapHideTask?.cancel()
        hideTask?.cancel()
        if next { panel = nil }
        withAnimation(.easeInOut(duration: 0.2)) {
            chrome.visible = !next
        }
        if next {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        } else {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        // 暂停时不自动收控件：用户正停在某一帧看，控件得留着
        guard model.isPlaying, !chrome.locked, chrome.visible, panel == nil else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_600_000_000)
            if Task.isCancelled { return }
            // 正在拖进度 / seek 在途时别收控件，否则拖到一半底部整块消失
            guard !model.progress.isScrubbing, !model.progress.isSeeking else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                chrome.visible = false
            }
        }
    }

    // MARK: - 面板

    /// 打开一个面板。已经有一个开着（从「更多」点进二级）时，把当前这个压栈，
    /// 二级面板左上角就有了「返回」。
    private func open(_ panel: PlayerPanel) {
        hideTask?.cancel()
        tapHideTask?.cancel()
        chrome.panelOpen = true
        if !chrome.visible, !chrome.locked {
            withAnimation(.easeOut(duration: 0.16)) { chrome.visible = true }
        }
        if let current = self.panel, current != panel {
            panelHistory.append(current)
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            self.panel = panel
        }
    }

    /// 二级面板左上角的返回：退回上一级；没有上一级就整个关掉。
    private func goBackPanel() {
        guard let previous = panelHistory.popLast() else {
            closePanel()
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            panel = previous
        }
    }

    private func closePanel() {
        chrome.panelOpen = false
        panelHistory.removeAll()
        withAnimation(.easeOut(duration: 0.22)) {
            panel = nil
        }
        scheduleHide()
    }

    private func panelLayer(_ panel: PlayerPanel) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { closePanel() }

            PlayerPanelSheet(
                panel: panel,
                model: model,
                isLocked: chrome.locked,
                canGoBack: !panelHistory.isEmpty,
                onClose: closePanel,
                onBack: goBackPanel,
                onShow: { next in open(next) },
                onToggleLock: {
                    closePanel()
                    toggleLock()
                },
                onDownload: {
                    closePanel()
                    Task {
                        await model.downloadAndPlay(
                            item: model.currentItem ?? item,
                            serverID: serverID,
                            connection: connection
                        )
                    }
                },
                onGestureHelp: {
                    closePanel()
                    showGestureHelp = true
                },
                orientationMode: orientationMode,
                onSelectOrientation: selectOrientation
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .zIndex(10)
    }

    // MARK: - 轻提示

    private func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = text }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { toast = nil }
        }
    }

    // MARK: - 覆盖层

    private func downloadOverlay(_ progress: Double) -> some View {
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
                Task {
                    await model.downloadAndPlay(
                        item: model.currentItem ?? item,
                        serverID: serverID,
                        connection: connection
                    )
                }
            } label: {
                Label("下载到本地播放", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isDownloading)
        }
        .padding(24)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(24)
    }
}
