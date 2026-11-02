import AVFoundation
import SwiftUI
import UIKit

// MARK: - 控件显隐

/// 控件层自己的状态。
///
/// 单独拎出来是**为了手势不被打断**：显隐、是否锁定、横竖屏这些状态只要挂在页面的
/// `@State` 上，一改就让整个 body 重算，`gestureSurface` 里的 `DragGesture` 会被重建，
/// 拖到一半就断（真机上表现为「划一半停住」）。现在页面本体不读这些值，改的是这一层。
@MainActor
final class ChromeVisibility: ObservableObject {
    @Published var visible = true
    @Published var locked = false
    @Published var isLandscape = false
}

// MARK: - 画面舞台

/// 画面 + 亮度遮罩。
///
/// 单独成一个视图，是因为它是唯一跟着手势逐帧变化的东西：
/// 缩放、亮度遮罩都在这里观察，页面本体不参与，拖动时整页（含一大堆控件）一次都不重算。
struct PlayerStage: View {
    @ObservedObject var visual: PlayerVisualState
    let player: AVPlayer
    let fit: VideoFit

    var body: some View {
        ZStack {
            Color.black

            // 缩放用 SwiftUI 的 scaleEffect：UIKit 层直接改 AVPlayerLayer 的
            // affineTransform 会被视频层和布局刷掉（1.1.8 实测「缩放 1.3× 但画面不动」）。
            PlayerSurface(player: player, fit: fit)
                .scaleEffect(visual.zoom)

            // 亮度遮罩：盖住画面，但不盖控件与 HUD（它们在更上层）
            Color.black
                .opacity(visual.dim)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

// MARK: - 按钮零件

/// 圆形玻璃底 + 内容的容器。
/// `Menu` 的 label 用不了 `Button` 那套，所以玻璃底单独抽一层共用。
struct PlayerGlassCircle<Content: View>: View {
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
                    .fill(.black.opacity(0.40))
                    .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            }
            .contentShape(Circle())
    }
}

/// 播放页统一的圆形图标按钮
struct PlayerGlassButton: View {
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

/// 横竖屏按钮上那个小方框。
///
/// **不用 SF Symbol**：`rectangle.landscape` 这类名字在不同系统版本上会出现缺失，
/// 缺失时 `Image(systemName:)` 不报错、直接渲染成 0 尺寸空白——用户截图里
/// 「横屏时按钮只剩『横屏』两个字，竖屏时却有图标」就是这么来的。
/// 自己用 `RoundedRectangle` 画，系统怎么改都画得出来。
/// 画的是「点下去会变成的方向」：横着的那块 = 点了转横屏。
struct OrientationGlyph: View {
    /// true = 画横着的方块（点下去进横屏）
    var landscape: Bool
    var lineWidth: CGFloat = 1.5

    var body: some View {
        RoundedRectangle(cornerRadius: 2.4, style: .continuous)
            .strokeBorder(lineWidth: lineWidth)
            .frame(width: landscape ? 15 : 10, height: landscape ? 10 : 15)
    }
}

/// 胶囊按钮：底部那几个「有当前值」的项（倍速、画面）用它，
/// 值直接写在按钮上，不用点开才知道现在是什么状态。
struct PlayerGlassPill: View {
    let text: String
    var highlighted = false
    var height: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(highlighted ? Color.accentColor : Color.white)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: height)
                .background {
                    Capsule(style: .continuous)
                        .fill(.black.opacity(0.40))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    highlighted ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.16),
                                    lineWidth: 0.5
                                )
                        )
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(text)
    }
}

/// 按下缩一点、暗一点：这些按钮都浮在画面上，需要一点实体感
struct PlayerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

// MARK: - 进度条

/// 自绘进度条。相比系统 `Slider` 多两件事：
/// 1. **单击即跳转**——`DragGesture(minimumDistance: 0)` 让「按下」就等于「拖到该点」。
/// 2. 拖动时轨道变粗、圆点变大，手指压着的地方有明确反馈。
///
/// 它仍然只写本地 `scrubTime`（走 `onScrub`），一次都不碰播放器。
struct ScrubBar: View {
    var value: Double
    var total: Double
    /// seek 在途（不只是手指在拖）：圆点保持放大，表示「正在跳」
    var isActive: Bool
    var onBegin: () -> Void
    var onScrub: (Double) -> Void
    var onCommit: () -> Void

    @State private var isDragging = false
    @State private var lastSent: Double = -1

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
                    .scaleEffect(isDragging ? 1.0 : 0.9)
            }
            .frame(width: width, height: geo.size.height, alignment: .leading)
            // 整块都是热区：点哪儿跳哪儿
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            lastSent = -1
                            onBegin()
                        }
                        emit(gesture.location.x, width: width)
                    }
                    .onEnded { gesture in
                        // 再取一次点按位置：单击时 onChanged 和 onEnded 的 x 相同，
                        // 拖到边缘松手时这里能拿到最终落点
                        emit(gesture.location.x, width: width)
                        isDragging = false
                        onCommit()
                    }
            )
            .animation(.easeOut(duration: 0.14), value: isDragging)
            .animation(.easeOut(duration: 0.14), value: isActive)
        }
    }

    /// 值没变就别回调：手指按住不动时 `onChanged` 仍会持续触发，
    /// 每帧都发一次只会让进度条白白重绘。
    private func emit(_ x: CGFloat, width: CGFloat) {
        let seconds = seconds(at: x, width: width)
        guard lastSent < 0 || abs(seconds - lastSent) > 0.001 else { return }
        lastSent = seconds
        onScrub(seconds)
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> Double {
        guard total > 0, width > 0 else { return 0 }
        let ratio = min(max(Double(x / width), 0), 1)
        return ratio * total
    }
}

// MARK: - 底部控件

/// 底部一整块：进度条一行 + 按钮一行。
///
/// 传进来的 `progress` **不加 `@ObservedObject`**：播放中每 0.25 秒的时间刷新
/// 不该把这一排按钮也跟着重算，只有 `ScrubRow` 需要跟着跳。
struct PlayerBottomBar: View {
    let progress: PlaybackProgress
    let isPlaying: Bool
    let rate: Float
    let seekStep: Double
    let fit: VideoFit
    let isMuted: Bool
    var onBackward: () -> Void
    var onPlayPause: () -> Void
    var onForward: () -> Void
    var onRate: (Float) -> Void
    var onFit: () -> Void
    var onMute: () -> Void
    var onBeginScrub: () -> Void
    var onScrub: (Double) -> Void
    var onCommitScrub: () -> Void

    private static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        VStack(spacing: 10) {
            ScrubRow(
                progress: progress,
                onBegin: onBeginScrub,
                onScrub: onScrub,
                onCommit: onCommitScrub
            )

            HStack(spacing: 6) {
                PlayerGlassButton(
                    symbol: backSymbol,
                    size: 34,
                    label: "后退 \(Int(seekStep)) 秒",
                    action: onBackward
                )

                PlayerGlassButton(
                    symbol: isPlaying ? "pause.fill" : "play.fill",
                    size: 40,
                    label: isPlaying ? "暂停" : "播放",
                    action: onPlayPause
                )

                PlayerGlassButton(
                    symbol: forwardSymbol,
                    size: 34,
                    label: "前进 \(Int(seekStep)) 秒",
                    action: onForward
                )

                Spacer(minLength: 4)

                rateMenu

                PlayerGlassPill(
                    text: fit.shortTitle,
                    highlighted: fit != .aspect,
                    action: onFit
                )

                PlayerGlassButton(
                    symbol: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    size: 34,
                    label: isMuted ? "取消静音" : "静音",
                    action: onMute
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// 倍速胶囊。播放页不在 `List` 里，`Menu` 的 label 不会被染成 accent 色，
    /// 所以可以整体做成菜单（设置页那行是另一回事，见交接文档第 7 节 59 条）。
    private var rateMenu: some View {
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
                // 非 1× 时高亮，提醒「现在不是常速」
                .foregroundStyle(abs(rate - 1) > 0.01 ? Color.accentColor : Color.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background {
                    Capsule(style: .continuous)
                        .fill(.black.opacity(0.40))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    abs(rate - 1) > 0.01
                                        ? Color.accentColor.opacity(0.55)
                                        : Color.white.opacity(0.16),
                                    lineWidth: 0.5
                                )
                        )
                }
                .contentShape(Capsule(style: .continuous))
        }
        .accessibilityLabel("播放速度")
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

    private func rateText(_ value: Float) -> String {
        if value == value.rounded() { return "\(Int(value))×" }
        return String(format: "%g×", Double(value))
    }
}

/// 进度条那一行：自己观察进度，播放中每 0.25 秒只重绘这一条。
private struct ScrubRow: View {
    @ObservedObject var progress: PlaybackProgress
    var onBegin: () -> Void
    var onScrub: (Double) -> Void
    var onCommit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(Format.duration(progress.displayTime))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.4), radius: 3, y: 0.5)
                .frame(width: 58, alignment: .leading)

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

            HStack(spacing: 5) {
                if progress.isBuffering {
                    // 跳到未缓冲位置 / 网络跟不上时转圈：远端流要重新读一段数据，
                    // 不给反馈的话用户只会觉得「点了没反应」
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                }
                Text(Format.duration(progress.duration))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(width: 58, alignment: .trailing)
        }
    }
}

// MARK: - 手势 HUD

struct PlayerHUDOverlay: View {
    @ObservedObject var bus: PlayerHUDBus

    var body: some View {
        ZStack {
            if let value = bus.value {
                content(value)
                    .transition(.opacity)
            }
        }
        // 只在「出现 / 消失」时做淡入淡出；数值变化不做动画，
        // 否则拖动时每帧都开一个动画事务，反而拖慢手感
        .animation(.easeOut(duration: 0.16), value: bus.value == nil)
        .allowsHitTesting(false)
    }
}

private extension PlayerHUDOverlay {
    @ViewBuilder
    func content(_ value: GestureHUD) -> some View {
        switch value {
        case let .seek(delta, target, total):
            VStack(spacing: 5) {
                Text(deltaText(delta))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("\(Format.duration(target)) / \(Format.duration(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

        case let .volume(level):
            levelPill(
                icon: level <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                level: level,
                text: "\(Int((level * 100).rounded()))%"
            )

        case let .brightness(level):
            levelPill(
                icon: "sun.max.fill",
                level: level,
                text: "\(Int((level * 100).rounded()))%"
            )

        case let .speed(rate):
            pill(icon: "forward.fill", text: rateText(rate) + " 倍速播放中")

        case let .zoom(scale):
            pill(icon: "aspectratio", text: rateText(Float(scale)) + "×")

        case let .playPause(showingPlay):
            Image(systemName: showingPlay ? "play.fill" : "pause.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(.black.opacity(0.5), in: Circle())
        }
    }

    /// 音量 / 亮度：图标 + 百分比 + 一条细进度条，比光秃秃的数字更好读
    func levelPill(icon: String, level: Double, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 20)

            Capsule(style: .continuous)
                .fill(.white.opacity(0.25))
                .frame(width: 96, height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule(style: .continuous)
                            .fill(.white)
                            .frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
                    }
                    .frame(height: 4)
                }

            Text(text)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 38, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    func pill(icon: String, text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
            Text(text)
                .font(.footnote.weight(.medium).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    func deltaText(_ delta: Double) -> String {
        let magnitude = Format.duration(abs(delta))
        if delta > 0.3 { return "+" + magnitude }
        if delta < -0.3 { return "-" + magnitude }
        return magnitude
    }

    func rateText(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))" : String(format: "%.1f", rate)
    }
}
