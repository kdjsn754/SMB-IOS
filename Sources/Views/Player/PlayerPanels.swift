import SwiftUI

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
        }
    }
}

/// 面板本体。
///
/// **二级面板要能退回来**：从「更多」点进「屏幕方向 / 画面 / 字幕…」时，左上角出现返回箭头，
/// 退回上一级；右上角的 × 才是把整个面板关掉。所以这层需要 `canGoBack` / `onBack`，
/// 由页面用一个栈来维护（见 `VideoPlayerView.open(_:)` / `goBackPanel()`）。
struct PlayerPanelSheet: View {
    let panel: PlayerPanel
    @ObservedObject var model: VideoPlaybackModel

    var isLocked: Bool
    var canGoBack: Bool
    var onClose: () -> Void
    var onBack: () -> Void
    var onShow: (PlayerPanel) -> Void
    var onToggleLock: () -> Void
    var onDownload: () -> Void
    var onGestureSettings: () -> Void
    var onGestureHelp: () -> Void
    var orientationMode: PlaybackOrientationMode
    var onSelectOrientation: (PlaybackOrientationMode) -> Void

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
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 420)
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
                    onGestureSettings()
                }

                PanelRow(icon: "questionmark.circle", title: "手势说明") {
                    onGestureHelp()
                }
            }
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
