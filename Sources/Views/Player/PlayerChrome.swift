import SwiftUI

/// 播放页的控件层：顶部栏 / 中央控制 / 底部栏 / 锁定徽标。
///
/// 单独成一个视图只因为一件事：显隐、锁定、横竖屏都归它自己观察，
/// 页面本体不受影响，手势层也就不会因为「拖动时把控件叫出来」而被重建。
struct PlayerChromeLayer: View {
    @ObservedObject var chrome: ChromeVisibility

    let title: String
    let subtitle: String?
    let progress: PlaybackProgress
    let isPlaying: Bool
    let didReachEnd: Bool
    let canPlayNext: Bool
    let canPlayPrevious: Bool
    let rate: Float
    let fit: VideoFit
    let hasSubtitles: Bool
    let subtitleEnabled: Bool
    let seekStep: Double
    let sleepDeadline: Date?

    var onClose: () -> Void
    var onToggleLock: () -> Void
    var onPlayPause: () -> Void
    var onReplay: () -> Void
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onBackward: () -> Void
    var onForward: () -> Void
    var onRate: () -> Void
    var onFit: () -> Void
    var onSubtitles: () -> Void
    var onMore: () -> Void
    var onBeginScrub: () -> Void
    var onScrub: (Double) -> Void
    var onCommitScrub: () -> Void

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
                    colors: [.black.opacity(0.58), .black.opacity(0.20), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 140)

                Spacer(minLength: 0)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.28), .black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 190)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 14)
                    .padding(.top, 2)

                Spacer(minLength: 0)

                bottomBar
            }

            // 中央控制：暂停时是播放键，缓冲时是转圈，播完是结束卡片。
            // 单独一个视图观察 `progress`，播放中每 0.25 秒的刷新不会牵动上下两条栏。
            PlayerCenterControl(
                progress: progress,
                isPlaying: isPlaying,
                didReachEnd: didReachEnd,
                canPlayNext: canPlayNext,
                canPlayPrevious: canPlayPrevious,
                onPlayPause: onPlayPause,
                onReplay: onReplay,
                onNext: onNext,
                onPrevious: onPrevious
            )
        }
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 10) {
            PlayerIconButton(
                symbol: "chevron.down",
                size: 18,
                weight: .semibold,
                label: "关闭",
                action: onClose
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 1)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if sleepDeadline != nil {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .shadow(color: .black.opacity(0.4), radius: 6, y: 1)
            }

            PlayerIconButton(
                symbol: chrome.locked ? "lock.fill" : "lock.open",
                size: 16,
                weight: .medium,
                tint: .white.opacity(0.9),
                label: chrome.locked ? "解锁" : "锁定控件",
                action: onToggleLock
            )
        }
    }

    // MARK: - 底部

    private var bottomBar: some View {
        VStack(spacing: 8) {
            PlayerScrubSection(
                progress: progress,
                onBegin: onBeginScrub,
                onScrub: onScrub,
                onCommit: onCommitScrub
            )

            HStack(spacing: 2) {
                PlayerIconButton(
                    symbol: backSymbol,
                    size: 20,
                    label: "后退 \(Int(seekStep)) 秒",
                    action: onBackward
                )

                PlayerIconButton(
                    symbol: isPlaying ? "pause.fill" : "play.fill",
                    size: 26,
                    weight: .semibold,
                    label: isPlaying ? "暂停" : "播放",
                    action: onPlayPause
                )

                PlayerIconButton(
                    symbol: forwardSymbol,
                    size: 20,
                    label: "前进 \(Int(seekStep)) 秒",
                    action: onForward
                )

                Spacer(minLength: 6)

                PlayerPill(
                    text: rateText(rate),
                    highlighted: abs(rate - 1) > 0.01,
                    action: onRate
                )

                if hasSubtitles {
                    PlayerPill(
                        text: "字幕",
                        icon: "captions.bubble",
                        highlighted: subtitleEnabled,
                        action: onSubtitles
                    )
                }

                if chrome.isLandscape {
                    PlayerPill(
                        text: fit.shortTitle,
                        highlighted: fit != .aspect,
                        action: onFit
                    )
                }

                PlayerIconButton(
                    symbol: "ellipsis",
                    size: 18,
                    label: "更多",
                    action: onMore
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    /// 图标跟着「快进跨度」走：按钮上写的数字就是实际会跳的秒数，
    /// 设置里改成 30 秒，这里也跟着变成 30。
    private var backSymbol: String {
        switch Int(seekStep) {
        case 10: return "gobackward.10"
        case 15: return "gobackward.15"
        case 30: return "gobackward.30"
        default: return "gobackward"
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

    private func rateText(_ value: Float) -> String {
        if value == value.rounded() { return "\(Int(value))×" }
        return String(format: "%g×", Double(value))
    }

    // MARK: - 锁

    /// 锁定后画面全干净，只留右下角这一颗锁，不然用户没法解锁
    private var lockBadge: some View {
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Button(action: onToggleLock) {
                    PlayerRoundButton(size: 44) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .buttonStyle(PlayerPressStyle())
                .accessibilityLabel("解锁控件")
                .padding(.trailing, 16)
                .padding(.bottom, 18)
            }
        }
    }
}

// MARK: - 进度条 + 时间

/// 进度条那一块：自己观察进度，播放中每 0.25 秒只重绘这一条。
private struct PlayerScrubSection: View {
    @ObservedObject var progress: PlaybackProgress
    var onBegin: () -> Void
    var onScrub: (Double) -> Void
    var onCommit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PlayerScrubBar(
                value: progress.displayTime,
                total: progress.duration,
                buffered: progress.buffered,
                isActive: progress.isSeeking,
                onBegin: onBegin,
                onScrub: onScrub,
                onCommit: onCommit
            )
            .disabled(progress.duration <= 0)
            .opacity(progress.duration > 0 ? 1 : 0.4)

            HStack(spacing: 0) {
                Text(Format.duration(progress.displayTime))
                Spacer(minLength: 8)
                Text(Format.duration(progress.duration))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.72))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 0.5)
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - 中央控制

private struct PlayerCenterControl: View {
    @ObservedObject var progress: PlaybackProgress

    let isPlaying: Bool
    let didReachEnd: Bool
    let canPlayNext: Bool
    let canPlayPrevious: Bool

    var onPlayPause: () -> Void
    var onReplay: () -> Void
    var onNext: () -> Void
    var onPrevious: () -> Void

    var body: some View {
        Group {
            if didReachEnd {
                endCard.transition(.opacity)
            } else if progress.isBuffering {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.3)
            } else if !isPlaying {
                Button(action: onPlayPause) {
                    PlayerRoundButton(size: 68) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(.white)
                            // 光学居中：三角形的视觉重心偏左，往右挪 1.5 pt 才像在圆心上
                            .offset(x: 1.5)
                    }
                }
                .buttonStyle(PlayerPressStyle())
                .accessibilityLabel("播放")
            }
        }
        .animation(.easeOut(duration: 0.16), value: didReachEnd)
    }

    /// 播完：重播 / 上一个 / 下一个
    private var endCard: some View {
        VStack(spacing: 14) {
            Text("播放结束")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
                .tracking(1)

            HStack(spacing: 10) {
                if canPlayPrevious {
                    EndActionButton(icon: "backward.end.fill", text: "上一个", filled: false, action: onPrevious)
                }

                EndActionButton(icon: "arrow.counterclockwise", text: "重播", filled: true, action: onReplay)

                if canPlayNext {
                    EndActionButton(icon: "forward.end.fill", text: "下一个", filled: false, action: onNext)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct EndActionButton: View {
    let icon: String
    let text: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(filled ? Color.black : Color.white)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background {
                Capsule(style: .continuous)
                    .fill(filled ? Color.white : Color.white.opacity(0.16))
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PlayerPressStyle())
    }
}
