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

struct PlayerPanelSheet: View {
    let panel: PlayerPanel
    @ObservedObject var model: VideoPlaybackModel

    var isLocked: Bool
    var onClose: () -> Void
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

            HStack {
                Text(panel.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(PlayerPressStyle())
                .accessibilityLabel("关闭面板")
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
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
        VStack(spacing: 0) {
            // 屏幕方向也放一份入口：从底栏「画面」胶囊进来就能顺手改，
            // 不用绕回「更多」。真正的内容在 `.orientation` 面板里。
            PanelRow(
                icon: "arrow.triangle.2.circlepath",
                title: "屏幕方向",
                detail: orientationMode.title,
                selected: false
            ) {
                onShow(.orientation)
            }

            ForEach(VideoFit.allCases) { option in
                PanelRow(
                    icon: fitIcon(option),
                    title: option.title,
                    detail: option.detail,
                    selected: model.fit == option
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
    /// 以前只有一个「切换横竖屏」开关，只在本次播放有效，退出再进又被视频比例掰回去。
    private var orientationList: some View {
        VStack(spacing: 0) {
            ForEach(PlaybackOrientationMode.allCases) { option in
                OrientationRow(
                    option: option,
                    selected: orientationMode == option
                ) {
                    onSelectOrientation(option)
                }
            }

            Text("选择会被记住，下次打开播放器仍按这个方向；退出播放器时浏览器页面回到进入前的方向。")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 12)
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
        VStack(spacing: 0) {
            if allowsOff {
                PanelRow(
                    icon: "captions.bubble",
                    title: "关闭字幕",
                    detail: nil,
                    selected: selected == nil
                ) {
                    onSelect(nil)
                }
            }

            ForEach(tracks) { track in
                PanelRow(
                    icon: allowsOff ? "text.bubble" : "waveform",
                    title: track.name,
                    detail: track.detail,
                    selected: track.id == selected
                ) {
                    onSelect(track.id)
                }
            }

            if tracks.isEmpty && !allowsOff {
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
                    .padding(.horizontal, 4)
            } else if tracks.isEmpty && allowsOff {
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - 定时

    private var timerList: some View {
        VStack(spacing: 0) {
            PanelRow(
                icon: "moon.zzz",
                title: "关闭定时",
                detail: nil,
                selected: model.sleepDeadline == nil
            ) {
                model.setSleepTimer(minutes: nil)
                onClose()
            }

            ForEach(Self.timerChoices, id: \.self) { minutes in
                PanelRow(
                    icon: "timer",
                    title: "\(minutes) 分钟后",
                    detail: nil,
                    selected: false
                ) {
                    model.setSleepTimer(minutes: minutes)
                    onClose()
                }
            }
        }
    }

    // MARK: - 更多

    private var moreList: some View {
        VStack(spacing: 0) {
            PanelRow(
                icon: isLocked ? "lock.fill" : "lock.open",
                title: isLocked ? "解锁控件" : "锁定控件",
                detail: "锁上之后画面上的手势全部失效，防止误触",
                selected: false,
                showChevron: false,
                action: onToggleLock
            )

            PanelRow(
                icon: "arrow.triangle.2.circlepath",
                title: "屏幕方向",
                detail: "\(orientationMode.title)（\(orientationMode.shortTitle)）",
                selected: false
            ) {
                onShow(.orientation)
            }

            PanelRow(
                icon: "rectangle.arrowtriangle.2.inward",
                title: "画面",
                detail: model.fit.title,
                selected: false
            ) {
                onShow(.fit)
            }

            if !model.subtitles.isEmpty {
                PanelRow(
                    icon: "captions.bubble",
                    title: "字幕",
                    detail: subtitleDetail,
                    selected: false
                ) {
                    onShow(.subtitle)
                }
            }

            if model.audioTracks.count > 1 {
                PanelRow(
                    icon: "waveform",
                    title: "音轨",
                    detail: audioDetail,
                    selected: false
                ) {
                    onShow(.audio)
                }
            }

            PanelRow(
                icon: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                title: model.isMuted ? "取消静音" : "静音",
                detail: "只影响本 App，不动系统音量",
                selected: model.isMuted,
                showChevron: false
            ) {
                model.toggleMute()
            }

            PanelRow(
                icon: "timer",
                title: "定时关闭",
                detail: timerDetail,
                selected: false
            ) {
                onShow(.timer)
            }

            PanelRow(
                icon: "repeat",
                title: "循环播放",
                detail: "播完自动从头再来",
                selected: model.isLooping,
                showChevron: false
            ) {
                model.toggleLoop()
            }

            PanelRow(
                icon: "arrow.down.circle",
                title: "下载到本地播放",
                detail: "远端流播不动时用这个兜底",
                selected: false,
                showChevron: false,
                action: onDownload
            )

            PanelRow(
                icon: "hand.draw",
                title: "播放手势设置",
                detail: nil,
                selected: false
            ) {
                onGestureSettings()
            }

            PanelRow(
                icon: "questionmark.circle",
                title: "手势说明",
                detail: nil,
                selected: false
            ) {
                onGestureHelp()
            }
        }
    }

    private var timerDetail: String? {
        guard let deadline = model.sleepDeadline else { return nil }
        let minutes = max(1, Int(deadline.timeIntervalSinceNow / 60))
        return "还有约 \(minutes) 分钟"
    }

    private var subtitleDetail: String? {
        guard let id = model.selectedSubtitle else { return "已关闭" }
        return model.subtitles.first(where: { $0.id == id })?.name ?? "已开启"
    }

    private var audioDetail: String? {
        guard let id = model.selectedAudio else { return model.audioTracks.first?.name }
        return model.audioTracks.first(where: { $0.id == id })?.name
    }

    private func rateText(_ value: Float) -> String {
        if value == value.rounded() { return "\(Int(value))×" }
        return String(format: "%g×", Double(value))
    }
}

// MARK: - 行

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
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                    Text(option.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 50)
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

private struct PanelRow: View {
    let icon: String
    let title: String
    let detail: String?
    let selected: Bool
    var showChevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                } else if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerRowPressStyle())
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
