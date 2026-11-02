import AVFoundation
import SwiftUI
import UIKit

/// 播放页。
///
/// 分三层，从下往上：
/// 1. `PlayerStage` —— 画面 + 亮度遮罩，只跟手势里的缩放/亮度重算；
/// 2. 手势层 —— 一整块可命中的矩形，拖动 / 单击 / 双击 / 长按 / 捏合都归它；
/// 3. `PlayerChromeLayer` —— 顶部栏 + 底部栏 + 锁定徽标，自己观察自己的显隐状态。
///
/// **这个 struct 本体在拖动过程中一次都不重算**，这是「流畅」的前提：
/// 手势的中间状态在 `PlayerGestureEngine` 里（不发布），控件显隐在 `ChromeVisibility` 里
/// （由子视图观察）。页面一旦在拖动中途重算，手势层会被重建，拖动就会断。
@MainActor
struct VideoPlayerView: View {
    let item: FileItem
    let serverID: UUID
    let connection: SMBConnection

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = VideoPlaybackModel()
    /// 手势引擎用 `@State` 存：它不是 `ObservableObject`，页面永远不因它重算。
    @State private var engine = PlayerGestureEngine()
    @StateObject private var chrome = ChromeVisibility()
    @ObservedObject private var gestures = PlayerGestureSettings.shared

    @State private var hideTask: Task<Void, Never>?
    /// 单击「隐藏控件」延迟 0.26 秒执行：双击时会被取消，避免控件闪一下
    @State private var tapHideTask: Task<Void, Never>?

    // 横竖屏
    /// 进播放页那一刻的形态。退出时转回它——「回到手机原本的状态」，
    /// 而不是「按你躺着的姿态决定」。
    @State private var entryMode: ScreenMode = ScreenOrientationController.current
    /// 用户手动切过之后就不再按视频比例自动转，尊重手动选择
    @State private var manualMode: ScreenMode?
    /// 自动转只做一次，否则回调重入会把用户后来的手动选择抢回去
    @State private var didAutoOrient = false

    @State private var showGestureHelp = false
    @State private var showGestureSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                PlayerStage(visual: engine.visual, player: model.player, fit: model.fit)

                // 手势层在控件下面：按钮仍然点得动，其余区域的触摸都归它
                gestureSurface

                PlayerHUDOverlay(bus: engine.hud)

                PlayerChromeLayer(
                    chrome: chrome,
                    gestures: gestures,
                    progress: model.progress,
                    title: item.name,
                    isPlaying: model.isPlaying,
                    rate: model.playbackRate,
                    fit: model.fit,
                    isMuted: model.isMuted,
                    onClose: close,
                    onToggleOrientation: toggleOrientation,
                    onToggleLock: toggleLock,
                    onPlayPause: {
                        model.togglePlay()
                        scheduleHide()
                    },
                    onBackward: { jump(by: -gestures.seekStep) },
                    onForward: { jump(by: gestures.seekStep) },
                    onRate: { value in
                        model.setPlaybackRate(value)
                        engine.hud.show(.speed(value), autoHideAfter: 0.8)
                        scheduleHide()
                    },
                    onFit: {
                        // 适应 → 填充 → 拉伸 循环，按钮上直接显示当前是哪种
                        model.cycleFit()
                        scheduleHide()
                    },
                    onSetFit: { value in
                        model.setFit(value)
                        scheduleHide()
                    },
                    onMute: {
                        model.toggleMute()
                        scheduleHide()
                    },
                    onBeginScrub: {
                        // 拖进度期间别让控件自己淡出（4 秒定时器可能正好在这一刻到点）
                        hideTask?.cancel()
                        tapHideTask?.cancel()
                        model.beginScrub()
                    },
                    onScrub: { model.scrub(to: $0) },
                    onCommitScrub: {
                        model.commitScrub()
                        scheduleHide()
                    },
                    onDownload: {
                        Task { await model.downloadAndPlay(item: item, serverID: serverID, connection: connection) }
                    },
                    onGestureSettings: {
                        showGestureSettings = true
                        scheduleHide()
                    },
                    onGestureHelp: {
                        showGestureHelp = true
                        scheduleHide()
                    }
                )

                if let progress = model.downloadProgress {
                    downloadOverlay(progress)
                }

                if let message = model.errorMessage {
                    errorOverlay(message)
                }
            }
            // 导航栏整个不要：顶部控件自己做，才能跟着自动隐藏一起淡出
            .toolbar(.hidden, for: .navigationBar)
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
        .onAppear {
            engine.model = model
            // 进页面还没转屏之前，按钮就要显示对：横着进来的（浏览器里横屏点开）
            // 得马上是「竖屏」文案 + 竖条，否则第一眼又是反的。
            chrome.isLandscape = (entryMode == .landscape)
        }
        .task {
            await model.start(item: item, serverID: serverID, connection: connection)
            // 用户可能用实体音量键调过，进页面先对齐一次
            model.syncVolumeFromSystem()
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            tapHideTask?.cancel()
            engine.setLocked(false)
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
        applyOrientation(size.width / size.height >= 1.15 ? .landscape : .portrait)
    }

    /// 顶部按钮：手动切横竖屏
    private func toggleOrientation() {
        let target: ScreenMode = chrome.isLandscape ? .portrait : .landscape
        manualMode = target
        applyOrientation(target)
        scheduleHide()
    }

    /// 转屏的唯一入口：**先把形态写进控件状态，再请求系统转**。
    ///
    /// 「现在是横是竖」不能靠几何探测（原来用 `proxy.size.width > height`）：
    /// 旋转动画那一拍 `onGeometryChange` 会先报一次旧值，之后尺寸虽然换了，
    /// 但按钮文案/图标已经按旧值算过——用户看到的「横屏里写着横屏、图标空白」
    /// 就是这一次错配加上 SF Symbol 缺失叠出来的。`isLandscape` 现在跟着
    /// 「我们让系统去做什么」走，两者永远一致。
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
                            // 开始横向拖进度时把控件临时叫出来：控件收着的时候拖画面，
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
        guard !chrome.locked else { return }
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

    /// 跳转（底部 ±秒 按钮用）。引擎里有一份同样的逻辑给双击用，两边共用同一个 HUD。
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
        guard model.isPlaying, !chrome.locked, chrome.visible else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            // 正在拖进度 / seek 在途时别收控件，否则拖到一半底部整块消失
            guard !model.progress.isScrubbing, !model.progress.isSeeking else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                chrome.visible = false
            }
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
                Task { await model.downloadAndPlay(item: item, serverID: serverID, connection: connection) }
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

// MARK: - 控件层

/// 顶部栏 + 底部栏 + 锁定徽标。
///
/// 单独成一个视图只因为一件事：显隐、锁定、横竖屏都归它自己观察，
/// 页面本体不受影响，手势层也就不会因为「拖动时把控件叫出来」而被重建。
private struct PlayerChromeLayer: View {
    @ObservedObject var chrome: ChromeVisibility
    @ObservedObject var gestures: PlayerGestureSettings

    let progress: PlaybackProgress
    let title: String
    let isPlaying: Bool
    let rate: Float
    let fit: VideoFit
    let isMuted: Bool

    var onClose: () -> Void
    var onToggleOrientation: () -> Void
    var onToggleLock: () -> Void
    var onPlayPause: () -> Void
    var onBackward: () -> Void
    var onForward: () -> Void
    var onRate: (Float) -> Void
    var onFit: () -> Void
    var onSetFit: (VideoFit) -> Void
    var onMute: () -> Void
    var onBeginScrub: () -> Void
    var onScrub: (Double) -> Void
    var onCommitScrub: () -> Void
    var onDownload: () -> Void
    var onGestureSettings: () -> Void
    var onGestureHelp: () -> Void

    var body: some View {
        ZStack {
            if chrome.visible {
                controls
                    .transition(.opacity)
            }
            if chrome.locked {
                lockBadge
                    .transition(.opacity)
            }
        }
    }

    private var controls: some View {
        ZStack {
            // 上下压暗用渐变而不是整块黑条：中间画面完全不受影响。
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
                    colors: [.clear, .black.opacity(0.30), .black.opacity(0.74)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 200)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                Spacer(minLength: 0)
                bottomBar
            }
        }
    }

    /// 顶部：关闭 / 标题 / 切方向 / 更多。
    ///
    /// 标题不用「绝对居中」的写法：竖屏里它会被右边两颗按钮压得偏左，
    /// 现在让标题吃掉剩余宽度、左对齐，长文件名也不会钻到按钮下面。
    private var topBar: some View {
        HStack(spacing: 10) {
            PlayerGlassButton(symbol: "chevron.left", label: "关闭", action: onClose)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)

            orientationPill
            moreMenu
        }
    }

    /// 切横竖屏：文字 + 自绘小方块。方块一定画得出来，
    /// 不像 SF Symbol 那样会因为名字在不同系统版本上缺失而渲染成空白。
    private var orientationPill: some View {
        Button(action: onToggleOrientation) {
            HStack(spacing: 6) {
                OrientationGlyph(landscape: !chrome.isLandscape)
                    .foregroundStyle(.white)
                Text(chrome.isLandscape ? "竖屏" : "横屏")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background {
                Capsule(style: .continuous)
                    .fill(.black.opacity(0.40))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                    )
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(chrome.isLandscape ? "切换到竖屏" : "切换到横屏")
    }

    private var moreMenu: some View {
        Menu {
            Button(action: onToggleLock) {
                Label("锁定手势", systemImage: "lock")
            }

            Divider()

            Section("画面") {
                ForEach(VideoFit.allCases) { option in
                    Button {
                        onSetFit(option)
                    } label: {
                        if option == fit {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }

            Divider()

            Button(action: onDownload) {
                Label("下载到本地播放", systemImage: "arrow.down.circle")
            }
            Button(action: onGestureSettings) {
                Label("播放手势设置", systemImage: "hand.draw")
            }
            Button(action: onGestureHelp) {
                Label("手势说明", systemImage: "questionmark.circle")
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

    private var bottomBar: some View {
        PlayerBottomBar(
            progress: progress,
            isPlaying: isPlaying,
            rate: rate,
            seekStep: gestures.seekStep,
            fit: fit,
            isMuted: isMuted,
            onBackward: onBackward,
            onPlayPause: onPlayPause,
            onForward: onForward,
            onRate: onRate,
            onFit: onFit,
            onMute: onMute,
            onBeginScrub: onBeginScrub,
            onScrub: onScrub,
            onCommitScrub: onCommitScrub
        )
    }

    /// 锁定后画面全干净，只留右下角这一颗锁，不然用户没法解锁
    private var lockBadge: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button(action: onToggleLock) {
                    PlayerGlassCircle(size: 44) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .buttonStyle(PlayerPressStyle())
                .accessibilityLabel("解锁手势")
                .padding(.trailing, 16)
                .padding(.bottom, 18)
            }
        }
    }
}
