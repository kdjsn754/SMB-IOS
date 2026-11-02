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
    /// 面板打开时不自动隐藏（面板盖住画面，控件收起来没有意义）
    @Published var panelOpen = false
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

/// 按下缩一点、暗一点：这些按钮都浮在画面上，需要一点实体感
struct PlayerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

/// 画面上的图标按钮。
///
/// **不做黑色圆底**：那是旧版的样子，一排黑疙瘩压在画面上很吵。
/// 现在只有图标 + 一层很淡的投影（亮画面里也看得清），命中区域仍然 40×40。
struct PlayerIconButton: View {
    let symbol: String
    var size: CGFloat = 20
    var weight: Font.Weight = .semibold
    var tint: Color = .white
    var hit: CGFloat = 40
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                .frame(width: hit, height: hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPressStyle())
        .accessibilityLabel(label)
    }
}

/// 圆形按钮（中央播放键、结束卡片、锁定徽标）：这些地方需要一块底，
/// 否则图标直接怼在画面上，白底视频里会消失。
struct PlayerRoundButton<Content: View>: View {
    var size: CGFloat = 44
    var filled = false
    let content: Content

    init(size: CGFloat = 44, filled: Bool = false, @ViewBuilder content: () -> Content) {
        self.size = size
        self.filled = filled
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(filled ? Color.white.opacity(0.92) : Color.black.opacity(0.42))
                    .overlay(
                        Circle().strokeBorder(.white.opacity(filled ? 0 : 0.18), lineWidth: 0.5)
                    )
            }
            .contentShape(Circle())
    }
}

/// 胶囊按钮：底部那几个「有当前值」的项（倍速、画面、字幕）用它，
/// 值直接写在按钮上，不用点开才知道现在是什么状态。
struct PlayerPill: View {
    let text: String
    var icon: String? = nil
    var highlighted = false
    var height: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(text)
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(highlighted ? Color.accentColor : Color.white)
            .padding(.horizontal, 11)
            .frame(height: height)
            .background {
                Capsule(style: .continuous)
                    .fill(highlighted ? Color.accentColor.opacity(0.16) : Color.black.opacity(0.35))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                highlighted
                                    ? Color.accentColor.opacity(0.5)
                                    : Color.white.opacity(0.16),
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

/// 横竖屏按钮上那个小方框。
///
/// **不用 SF Symbol**：`rectangle.landscape` 这类名字在不同系统版本上会出现缺失，
/// 缺失时 `Image(systemName:)` 不报错、直接渲染成 0 尺寸空白——用户截图里
/// 「横屏时按钮只剩『横屏』两个字，竖屏时却有图标」就是这么来的。
struct OrientationGlyph: View {
    /// true = 画横着的方块（点下去进横屏）
    var landscape: Bool
    var lineWidth: CGFloat = 1.5

    var body: some View {
        RoundedRectangle(cornerRadius: 2.4, style: .continuous)
            .strokeBorder(lineWidth: lineWidth)
            .frame(width: landscape ? 15 : 10, height: landscape ? 15 : 10)
    }
}

// MARK: - 进度条

/// 自绘进度条，按主流播放器的做法重做：
///
/// 1. **三段轨道**：已播（强调色）/ 已缓冲（半透明白）/ 未播（淡轨道）。
///    缓冲段是从 `AVPlayerItem.loadedTimeRanges` 来的真实数据，远端流上很需要——
///    用户能看出「跳到这儿不用等」。
/// 2. **静止时很细（4 pt），按下变粗（7 pt）并冒出圆点**，不占地也不挡画面。
/// 3. **拖动时上方浮出时间气泡**，不用低头看两端的小字。
/// 4. `DragGesture(minimumDistance: 0)` 让「按下」就等于「拖到该点」，单击即可跳转。
///
/// 它仍然只写本地 `scrubTime`（走 `onScrub`），一次都不碰播放器。
struct PlayerScrubBar: View {
    var value: Double
    var total: Double
    var buffered: Double
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

    private var bufferedFraction: Double {
        guard total > 0, buffered.isFinite else { return 0 }
        return min(max(buffered / total, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let active = isDragging || isActive
            let barHeight: CGFloat = active ? 7 : 4
            let knob: CGFloat = 14
            let played = width * CGFloat(fraction)
            let bufferedWidth = width * CGFloat(max(bufferedFraction, fraction))

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.22))
                    .frame(height: barHeight)

                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.34))
                    .frame(width: bufferedWidth, height: barHeight)

                Capsule(style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: played, height: barHeight)

                if active {
                    Circle()
                        .fill(Color.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        // 贴到两端时圆点不越界（否则最左/最右会露出半个圆）
                        .offset(x: min(max(played - knob / 2, 0), max(width - knob, 0)))
                }
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
            .overlay(alignment: .topLeading) {
                if isDragging, total > 0 {
                    Text("\(Format.duration(value)) / \(Format.duration(total))")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous).fill(.black.opacity(0.72))
                        )
                        .fixedSize()
                        .offset(x: min(max(played - 44, 0), max(width - 88, 0)), y: -30)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.14), value: isDragging)
            .animation(.easeOut(duration: 0.14), value: isActive)
        }
        .frame(height: 26)
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

// MARK: - 状态件

/// 中央转圈：只观察 `progress.isBuffering`，播放中每 0.25 秒的刷新不会牵动整页。
struct PlayerBufferingIndicator: View {
    @ObservedObject var progress: PlaybackProgress
    var visible: Bool

    var body: some View {
        ZStack {
            if visible, progress.isBuffering {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.25)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: progress.isBuffering)
        .allowsHitTesting(false)
    }
}

/// 续播提示：进页面时浮一下「已从 12:33 继续播放」
struct PlayerToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.black.opacity(0.66), in: Capsule(style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
    }
}

// MARK: - 手势 HUD

struct PlayerHUDOverlay: View {
    @ObservedObject var bus: PlayerHUDBus

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let value = bus.value {
                    content(value)
                        .position(x: geo.size.width / 2, y: placement(for: value, in: geo))
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // 只在「出现 / 消失」时做淡入淡出；数值变化不做动画，
            // 否则拖动时每帧都开一个动画事务，反而拖慢手感
            .animation(.easeOut(duration: 0.16), value: bus.value == nil)
        }
        .allowsHitTesting(false)
    }

    /// 手势 HUD 的落点。
    ///
    /// **默认往上挪到屏幕中线以上**：中线是播放 / 暂停按钮和「播放结束」卡片的位置，
    /// 以前 HUD 就摆在正中，暂停时拖一下进度，黑色气泡正好扣在暂停按钮上（用户报的问题）。
    /// 上移 86 pt 之后，竖屏停在按钮上方、横屏落在顶栏与中央按钮之间的空档里，两边都不压。
    /// 唯一留在正中是「锁屏状态下的播放 / 暂停」——那时画面上没有任何控件，中间是空的。
    private func placement(for value: GestureHUD, in geo: GeometryProxy) -> CGFloat {
        let center = geo.size.height / 2
        if case .playPause = value { return center }
        return max(64, center - 86)
    }

    @ViewBuilder
    private func content(_ value: GestureHUD) -> some View {
        switch value {
        case let .seek(delta, target, total):
            VStack(spacing: 4) {
                Text(deltaText(delta))
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                Text("\(Format.duration(target)) / \(Format.duration(total))")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 13)
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
            pill(icon: "forward.fill", text: rateText(rate) + "× 加速中")

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
        rate == rate.rounded() ? "\(Int(rate))" : String(format: "%.2f", rate)
    }
}

// MARK: - 双击涟漪

/// 双击屏幕左右两侧时，那一下的视觉反馈。
///
/// 只放在「点的那一侧」，一条 96 pt 的圆扩散开、随即变淡 ——
/// 抖音 / YouTube 的做法，比在正中间弹一个数字更容易看清「刚才点的是哪边」。
struct SeekRippleOverlay: View {
    @ObservedObject var bus: PlayerHUDBus

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let ripple = bus.ripple {
                    RippleBubble(ripple: ripple)
                        .position(
                            x: geo.size.width * ripple.position,
                            y: geo.size.height / 2
                        )
                        .id(ripple.id)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct RippleBubble: View {
    let ripple: SeekRipple
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(expanded ? 0 : 0.18))
                .frame(width: 96, height: 96)
                .scaleEffect(expanded ? 1.5 : 0.7)

            Circle()
                .strokeBorder(Color.white.opacity(expanded ? 0 : 0.35), lineWidth: 1)
                .frame(width: 96, height: 96)
                .scaleEffect(expanded ? 1.5 : 0.7)

            VStack(spacing: 4) {
                HStack(spacing: 1) {
                    if ripple.forward {
                        Image(systemName: "chevron.right.2")
                        Image(systemName: "chevron.right")
                    } else {
                        Image(systemName: "chevron.left")
                        Image(systemName: "chevron.left.2")
                    }
                }
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)

                Text("\(ripple.seconds) 秒")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .opacity(expanded ? 0 : 1)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) { expanded = true }
        }
    }
}
