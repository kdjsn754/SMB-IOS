import SwiftUI
import UIKit

/// 底部面板。主流播放器（Infuse / nPlayer / B 站）都把「按一下就改一个设置」的东西
/// 收进这种从底下升起来的卡片里，而不是弹一堆 `Menu` —— 菜单在横屏上会飘到屏幕中间，
/// 挡住画面，还只显示一列。
enum PlayerPanel: String, Identifiable {
    case speed
    case fit
    case orientation
    case subtitle
    case audio
    case timer
    case more
    /// 播放手势总览。**不再弹独立的全屏表单**（用户 2026-11-02 反馈「不要跳到那个界面去」），
    /// 它就是这个面板里的一页：左上角返回、右上角 × 关全部，风格和其它二级面板一致。
    case gestures
    /// 每一行手势的取值页（第三级）：双击 / 快退快进 / 左右拖 / 上下拖 / 长按 / 捏合
    case gestureDoubleTap
    case gestureSeekStep
    case gestureHorizontal
    case gestureVertical
    case gestureLongPress
    case gesturePinch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speed: return "播放速度"
        case .fit: return "画面"
        case .orientation: return "屏幕方向"
        case .subtitle: return "字幕"
        case .audio: return "音轨"
        case .timer: return "定时关闭"
        case .more: return "更多"
        case .gestures: return "播放手势"
        case .gestureDoubleTap: return "双击画面"
        case .gestureSeekStep: return "快进 / 快退"
        case .gestureHorizontal: return "左右拖动"
        case .gestureVertical: return "上下拖动"
        case .gestureLongPress: return "长按画面"
        case .gesturePinch: return "双指捏合"
        }
    }

    /// 是不是「某一项手势取值」这一层
    var isGestureOption: Bool {
        switch self {
        case .gestureDoubleTap, .gestureSeekStep, .gestureHorizontal,
             .gestureVertical, .gestureLongPress, .gesturePinch:
            return true
        default:
            return false
        }
    }
}

/// 面板本体。
///
/// **二级面板要能退回来**：从「更多」点进「屏幕方向 / 画面 / 字幕…」时，左上角出现返回箭头，
/// 退回上一级；右上角的 × 才是把整个面板关掉。所以这层需要 `canGoBack` / `onBack`，
/// 由页面用一个栈来维护（见 `VideoPlayerView.open(_:)` / `goBackPanel()`）。
@MainActor
struct PlayerPanelSheet: View {
    let panel: PlayerPanel
    @ObservedObject var model: VideoPlaybackModel
    /// 手势配置。播放页里的「播放手势」页直接改这一份，改完立刻生效
    @ObservedObject var gestures = PlayerGestureSettings.shared

    var isLocked: Bool
    var canGoBack: Bool
    var onClose: () -> Void
    var onBack: () -> Void
    var onShow: (PlayerPanel) -> Void
    var onToggleLock: () -> Void
    var onDownload: () -> Void
    var onGestureHelp: () -> Void
    var orientationMode: PlaybackOrientationMode
    var onSelectOrientation: (PlaybackOrientationMode) -> Void

    /// 每个面板各自的滚动位置 + 那个 `UIScrollView` 的句柄。
    ///
    /// 面板全是同一个 `ScrollView` 换内容：从「更多」（已经滚到工具那一组）点进「屏幕方向」，
    /// 内容一下变短，系统把偏移夹回 0，退回「更多」就停在顶部了 —— 用户要接着看下面的设置，
    /// 只能重新往下滑（2026-11-02 反馈）。所以按面板各记一份偏移，换回来时写回去。
    ///
    /// 偏移记在 `PanelScrollBox` 里而不是 `@State`：滚动时每帧都在变，
    /// 每帧改一次状态会把整块面板重绘，滚起来会卡。
    @State private var scrollBox = PanelScrollBox()

    private static let rates: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    private static let timerChoices = [15, 30, 45, 60]

    var body: some View {
        VStack(spacing: 0) {
            Capsule(style: .continuous)
                .fill(.white.opacity(0.2))
                .frame(width: 34, height: 4)
                .padding(.top, 8)

            header

            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 18)
                    .background(
                        PanelScrollProbe(box: scrollBox) { y in
                            guard !scrollBox.isRestoring else { return }
                            scrollBox.offsets[panel.rawValue] = y
                        }
                    )
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 420)
            .onChange(of: panel) { _, newPanel in
                restoreScroll(to: newPanel)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if canGoBack {
                SheetCircleButton(symbol: "chevron.left", label: "返回", action: onBack)
            }

            Text(panel.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 8)

            SheetCircleButton(symbol: "xmark", label: "关闭", action: onClose)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .speed:
            speedGrid
        case .fit:
            fitList
        case .orientation:
            orientationList
        case .subtitle:
            trackList(
                tracks: model.subtitles,
                selected: model.selectedSubtitle,
                allowsOff: true,
                emptyText: "这个视频没有内嵌字幕",
                onSelect: { id in
                    model.selectSubtitle(id)
                    onClose()
                }
            )
        case .audio:
            trackList(
                tracks: model.audioTracks,
                selected: model.selectedAudio,
                allowsOff: false,
                emptyText: "这个视频只有一条音轨",
                onSelect: { id in
                    model.selectAudio(id)
                    onClose()
                }
            )
        case .timer:
            timerList
        case .more:
            moreList
        case .gestures:
            gestureList
        case .gestureDoubleTap, .gestureSeekStep, .gestureHorizontal,
             .gestureVertical, .gestureLongPress, .gesturePinch:
            gestureOptionList(panel)
        }
    }

    // MARK: - 倍速

    private var speedGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(Self.rates, id: \.self) { value in
                let active = abs(model.playbackRate - value) < 0.01
                Button {
                    model.setPlaybackRate(value)
                } label: {
                    Text(rateText(value))
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(active ? Color.black : Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(active ? Color.white : Color.white.opacity(0.10))
                        }
                }
                .buttonStyle(PlayerPressStyle())
            }
        }
    }

    // MARK: - 画面

    private var fitList: some View {
        card {
            ForEach(VideoFit.allCases) { option in
                PanelRow(
                    icon: fitIcon(option),
                    title: option.title,
                    checked: model.fit == option,
                    chevron: false
                ) {
                    model.setFit(option)
                    onClose()
                }
            }
        }
    }

    private func fitIcon(_ fit: VideoFit) -> String {
        switch fit {
        case .aspect: return "rectangle.arrowtriangle.2.inward"
        case .fill: return "rectangle.arrowtriangle.2.outward"
        case .stretch: return "arrow.left.and.right"
        }
    }

    // MARK: - 屏幕方向

    /// 三选一：自动识别 / 强制竖屏 / 强制横屏。
    ///
    /// 选中即生效、并且**记进 UserDefaults**——退出播放器重新打开还是这个方向。
    /// 只写选项名，不写解释：这三行的意思一看就懂，再多两行小字只会让面板变糊。
    private var orientationList: some View {
        card {
            ForEach(PlaybackOrientationMode.allCases) { option in
                OrientationRow(
                    option: option,
                    selected: orientationMode == option
                ) {
                    onSelectOrientation(option)
                }
            }
        }
    }

    // MARK: - 字幕 / 音轨

    private func trackList(
        tracks: [MediaTrack],
        selected: String?,
        allowsOff: Bool,
        emptyText: String,
        onSelect: @escaping (String?) -> Void
    ) -> some View {
        card {
            if allowsOff {
                PanelRow(
                    icon: "captions.bubble",
                    title: "关闭字幕",
                    checked: selected == nil,
                    chevron: false
                ) {
                    onSelect(nil)
                }
            }

            ForEach(tracks) { track in
                PanelRow(
                    icon: allowsOff ? "text.bubble" : "waveform",
                    title: track.name,
                    value: track.detail,
                    checked: track.id == selected,
                    chevron: false
                ) {
                    onSelect(track.id)
                }
            }

            if tracks.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
            }
        }
    }

    // MARK: - 定时

    private var timerList: some View {
        card {
            PanelRow(
                icon: "moon.zzz",
                title: "关闭定时",
                checked: model.sleepDeadline == nil,
                chevron: false
            ) {
                model.setSleepTimer(minutes: nil)
                onClose()
            }

            ForEach(Self.timerChoices, id: \.self) { minutes in
                PanelRow(
                    icon: "timer",
                    title: "\(minutes) 分钟"
                ) {
                    model.setSleepTimer(minutes: minutes)
                    onClose()
                }
            }
        }
    }

    // MARK: - 更多

    /// 分三组，每行只有「图标 + 名字 + 右侧状态」。
    ///
    /// 之前是十行平铺、每行下面挂一句灰色说明，整块看上去全是小字（用户反馈「太乱」）。
    /// 状态类的东西放右侧值或勾，解释留给「手势说明」那一页。
    private var moreList: some View {
        VStack(spacing: 14) {
            PanelSection(title: "播放") {
                PanelRow(
                    icon: isLocked ? "lock.fill" : "lock.open",
                    title: "锁定控件",
                    checked: isLocked,
                    chevron: false,
                    action: onToggleLock
                )

                PanelRow(
                    icon: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    title: "静音",
                    checked: model.isMuted,
                    chevron: false
                ) {
                    model.toggleMute()
                }

                PanelRow(
                    icon: "repeat",
                    title: "循环播放",
                    checked: model.isLooping,
                    chevron: false
                ) {
                    model.toggleLoop()
                }

                PanelRow(
                    icon: "timer",
                    title: "定时关闭",
                    value: timerValue
                ) {
                    onShow(.timer)
                }
            }

            PanelSection(title: "画面") {
                PanelRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "屏幕方向",
                    value: orientationMode.shortTitle
                ) {
                    onShow(.orientation)
                }

                PanelRow(
                    icon: "rectangle.arrowtriangle.2.inward",
                    title: "画面适配",
                    value: model.fit.shortTitle
                ) {
                    onShow(.fit)
                }

                if !model.subtitles.isEmpty {
                    PanelRow(
                        icon: "captions.bubble",
                        title: "字幕",
                        value: subtitleValue
                    ) {
                        onShow(.subtitle)
                    }
                }

                if model.audioTracks.count > 1 {
                    PanelRow(
                        icon: "waveform",
                        title: "音轨",
                        value: audioValue
                    ) {
                        onShow(.audio)
                    }
                }
            }

            PanelSection(title: "工具") {
                PanelRow(
                    icon: "arrow.down.circle",
                    title: "下载到本地",
                    chevron: false,
                    action: onDownload
                )

                PanelRow(icon: "hand.draw", title: "播放手势") {
                    onShow(.gestures)
                }

                PanelRow(icon: "questionmark.circle", title: "手势说明") {
                    onGestureHelp()
                }
            }
        }
    }

    // MARK: - 播放手势

    /// 手势总览页。每行只写「名字 + 当前取值」，点进去改哪一项就是哪一项。
    ///
    /// 关掉「启用手势」时，下面几行变暗也不可点（跟设置页里的 Form 一致），
    /// 但「启用手势」和「恢复默认手势」始终可点 —— 不然关了就再也没入口打开。
    private var gestureList: some View {
        VStack(spacing: 12) {
            card {
                PanelRow(
                    icon: "hand.draw",
                    title: "启用手势",
                    checked: gestures.isEnabled,
                    chevron: false
                ) {
                    gestures.isEnabled.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }

                PanelRow(
                    icon: "hand.tap",
                    title: "双击画面",
                    value: gestures.doubleTap.shortTitle,
                    enabled: gestures.isEnabled
                ) {
                    onShow(.gestureDoubleTap)
                }

                PanelRow(
                    icon: "goforward",
                    title: "快进 / 快退",
                    value: "\(Int(gestures.seekStep)) 秒",
                    enabled: gestures.isEnabled && gestures.doubleTap != .none
                ) {
                    onShow(.gestureSeekStep)
                }

                PanelRow(
                    icon: "arrow.left.and.right",
                    title: "左右拖动",
                    value: gestures.horizontal.title,
                    enabled: gestures.isEnabled
                ) {
                    onShow(.gestureHorizontal)
                }

                PanelRow(
                    icon: "arrow.up.and.down",
                    title: "上下拖动",
                    value: gestures.vertical.title,
                    enabled: gestures.isEnabled
                ) {
                    onShow(.gestureVertical)
                }

                PanelRow(
                    icon: "hand.point.up.left",
                    title: "长按画面",
                    value: gestures.longPress.title,
                    enabled: gestures.isEnabled
                ) {
                    onShow(.gestureLongPress)
                }

                PanelRow(
                    icon: "arrow.up.left.and.arrow.down.right",
                    title: "双指捏合",
                    value: gestures.pinch.title,
                    enabled: gestures.isEnabled
                ) {
                    onShow(.gesturePinch)
                }
            }

            card {
                PanelRow(icon: "arrow.counterclockwise", title: "恢复默认手势", chevron: false) {
                    gestures.resetToDefaults()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
        }
    }

    /// 某一项手势的取值页：一行一个选项，选完退回手势总览（不关面板）。
    private func gestureOptionList(_ panel: PlayerPanel) -> some View {
        card {
            ForEach(gestureOptions(panel)) { option in
                ChoiceRow(title: option.title, selected: option.selected) {
                    option.apply()
                    onBack()
                }
            }
        }
    }

    private struct GestureOption: Identifiable {
        let id: String
        let title: String
        let selected: Bool
        let apply: () -> Void
    }

    private func gestureOptions(_ panel: PlayerPanel) -> [GestureOption] {
        switch panel {
        case .gestureDoubleTap:
            return DoubleTapAction.allCases.map { action in
                GestureOption(
                    id: action.rawValue,
                    title: action.shortTitle,
                    selected: gestures.doubleTap == action
                ) {
                    gestures.doubleTap = action
                }
            }

        case .gestureSeekStep:
            return PlayerGestureSettings.seekStepChoices.map { step in
                GestureOption(
                    id: "\(step)",
                    title: "\(Int(step)) 秒",
                    selected: abs(gestures.seekStep - step) < 0.01
                ) {
                    gestures.seekStep = step
                }
            }

        case .gestureHorizontal:
            return HorizontalDragAction.allCases.map { action in
                GestureOption(
                    id: action.rawValue,
                    title: action.title,
                    selected: gestures.horizontal == action
                ) {
                    gestures.horizontal = action
                }
            }

        case .gestureVertical:
            return VerticalDragAction.allCases.map { action in
                GestureOption(
                    id: action.rawValue,
                    title: action.title,
                    selected: gestures.vertical == action
                ) {
                    gestures.vertical = action
                }
            }

        case .gestureLongPress:
            return LongPressAction.allCases.map { action in
                GestureOption(
                    id: action.rawValue,
                    title: action.title,
                    selected: gestures.longPress == action
                ) {
                    gestures.longPress = action
                }
            }

        case .gesturePinch:
            return PinchAction.allCases.map { action in
                GestureOption(
                    id: action.rawValue,
                    title: action.title,
                    selected: gestures.pinch == action
                ) {
                    gestures.pinch = action
                }
            }

        default:
            return []
        }
    }

    // MARK: - 滚动位置

    /// 换页后把这一页上次的位置写回去。
    ///
    /// 换页是**瞬变**的（见 `VideoPlayerView.open` 里的 `withTransaction`），所以
    /// 等当前这一轮 SwiftUI 更新落完，`contentSize` 就已经是最终值，写一次即准。
    ///
    /// 1.4.8 这里是在 0.34 s 弹簧动画里连写五拍、每拍 `layoutIfNeeded()`：动画每帧都在
    /// 改 scrollView 的 frame，我们又每拍强制整棵树布局 —— 用户反馈「很卡」。
    /// 现在最多两拍（第二拍只为兜底系统在本轮布局末尾的夹取），全程不做循环。
    private func restoreScroll(to panel: PlayerPanel) {
        let box = scrollBox
        let target = box.offsets[panel.rawValue] ?? 0
        guard target > 0.5 else {
            box.isRestoring = false
            return
        }
        box.isRestoring = true
        Task { @MainActor in
            // 让当前更新周期先跑完：此刻新内容的尺寸才写进 `contentSize`
            await Task.yield()
            writeScrollOffset(target)
            try? await Task.sleep(nanoseconds: 80_000_000)
            // 兜底一次：系统在一轮布局收尾时可能再压一次偏移
            writeScrollOffset(target)
            try? await Task.sleep(nanoseconds: 60_000_000)
            box.isRestoring = false
        }
    }

    /// 直接写 `contentOffset` —— 这是唯一确定生效的方式
    /// （`ScrollPosition.scrollTo(y:)` 在内容刚换的时候会被一起夹掉，见 `PanelScrollProbe`）。
    /// 内容比目标短时 UIKit 只会滚到能滚的最大值，所以每次写都重算上限，不硬写。
    private func writeScrollOffset(_ target: CGFloat) {
        guard let scroll = scrollBox.scrollView else { return }
        scroll.layoutIfNeeded()
        let maxY = max(0, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        let y = min(target, maxY)
        guard abs(scroll.contentOffset.y - y) > 0.5 else { return }
        UIView.performWithoutAnimation {
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
        }
    }

    private var timerValue: String? {
        guard let deadline = model.sleepDeadline else { return nil }
        return "\(max(1, Int(deadline.timeIntervalSinceNow / 60))) 分"
    }

    private var subtitleValue: String? {
        guard let id = model.selectedSubtitle else { return "关闭" }
        return model.subtitles.first(where: { $0.id == id })?.name ?? "开启"
    }

    private var audioValue: String? {
        guard let id = model.selectedAudio else { return model.audioTracks.first?.name }
        return model.audioTracks.first(where: { $0.id == id })?.name
    }

    private func rateText(_ value: Float) -> String {
        if value == value.rounded() { return "\(Int(value))×" }
        return String(format: "%g×", Double(value))
    }
}

// MARK: - 零件

/// 面板里的圆角卡片容器。行与行之间不画分隔线，靠留白分组，看起来更干净。
private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 0) {
        content()
    }
    .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.07))
    )
}

/// 分组标题 + 一张卡片
private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
                .padding(.leading, 10)

            card { content }
        }
    }
}

/// 面板标题栏上那颗圆形按钮（返回 / 关闭）
private struct SheetCircleButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(label)
    }
}

/// 面板里的一行：图标 + 名字 +（右侧）短值 / 勾 / 箭头。
///
/// **不再有第二行小字说明**（用户 2026-11-02 明确要求）：说明越细，整块看上去越糊。
/// 需要解释的只有「手势说明」那一页。
private struct PanelRow: View {
    let icon: String
    let title: String
    var value: String?
    var checked = false
    var chevron = true
    /// 关掉某项功能后，被它连带的几行变暗、不可点（仍然占位，位置不跳）
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: 22)

                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                if let value {
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }

                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                } else if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 47)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerRowPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

/// 选项行：只有名字 +（选中时）一个勾，没有图标。
///
/// 手势取值页用它。第三级页面不再挂图标 —— 上面两级已经用图标区分了功能，
/// 到这里全是同类选项，再多一列图标反而会把「哪个被选中」这件事冲淡。
private struct ChoiceRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 47)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerRowPressStyle())
    }
}

/// 屏幕方向的一行。
///
/// 竖屏 / 横屏的图标用 `OrientationGlyph` 自绘，不用 SF Symbol：
/// `rectangle.landscape` 这类名字在部分系统版本上会缺失，缺失时 `Image(systemName:)`
/// 不报错、直接渲染成 0 尺寸空白（1.3.x 用户截图里「只剩两个字没有图标」就是这么来的）。
private struct OrientationRow: View {
    let option: PlaybackOrientationMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: 22)

                Text(option.title)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)

                Spacer(minLength: 8)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 47)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerRowPressStyle())
    }

    @ViewBuilder
    private var icon: some View {
        switch option {
        case .auto:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .medium))
        case .portrait:
            OrientationGlyph(landscape: false, lineWidth: 1.6)
        case .landscape:
            OrientationGlyph(landscape: true, lineWidth: 1.6)
        }
    }
}

private struct PlayerRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.08 : 0))
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
