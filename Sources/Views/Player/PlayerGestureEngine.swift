import SwiftUI
import UIKit

// MARK: - 手势反馈数据

/// 手势 HUD 的形态。
///
/// `seek` 带上 `total` 是有意的：HUD 自己不再去观察 `PlaybackProgress`，
/// 否则播放中每 0.25 秒的周期刷新会把 HUD 也带着重算一遍（哪怕它根本没显示）。
enum GestureHUD: Equatable {
    case seek(delta: Double, target: Double, total: Double)
    case volume(Double)
    case brightness(Double)
    case speed(Float)
    case zoom(CGFloat)
    case playPause(Bool)
}

/// 双击左右两侧的反馈：一段涟漪 + 箭头 + 秒数。
/// 单独一条，因为它是一次性动画，不该占据 `GestureHUD` 的「当前值」。
struct SeekRipple: Equatable, Identifiable {
    let id = UUID()
    let forward: Bool
    let seconds: Int
    /// 0…1，涟漪出现在屏幕的哪个横向位置（左三分之一 / 右三分之一）
    let position: CGFloat
}

/// HUD 单独一条总线：拖动时它每帧都在变，挂到页面上会把整页带着重算。
@MainActor
final class PlayerHUDBus: ObservableObject {
    @Published private(set) var value: GestureHUD?
    @Published private(set) var ripple: SeekRipple?

    private var hideTask: Task<Void, Never>?
    private var rippleTask: Task<Void, Never>?

    /// 显示一条反馈。数值型（音量/亮度/进度）不自动隐藏，由手势结束时收。
    func show(_ value: GestureHUD, autoHideAfter seconds: Double? = nil) {
        hideTask?.cancel()
        hideTask = nil
        if self.value != value { self.value = value }
        if let seconds { hideLater(seconds) }
    }

    func showRipple(_ ripple: SeekRipple) {
        rippleTask?.cancel()
        // 换一个 id，视图才能重新播动画
        self.ripple = ripple
        rippleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.ripple = nil
        }
    }

    func hideLater(_ seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.value = nil
        }
    }

    func hideNow() {
        hideTask?.cancel()
        hideTask = nil
        if value != nil { value = nil }
    }
}

/// 画面自身的视觉状态（亮度遮罩、缩放）。
///
/// 和 `PlayerHUDBus` 一样单独拎出来：这两个值在拖动时逐帧变化，
/// 挂到页面 `@State` 上会让整页（含 `AVPlayerLayer`）一起重算——这正是旧版拖动发涩的主因。
@MainActor
final class PlayerVisualState: ObservableObject {
    /// 亮度压暗层浓度：0 = 原始，0.85 = 最暗（保留 15% 让画面还能看见）
    @Published var dim: Double = 0
    @Published var zoom: CGFloat = 1
}

/// 一次触摸结束后，页面需要做的动作
enum PlayerGestureOutcome {
    case none
    case singleTap
    case doubleTap
}

// MARK: - 手势引擎

/// 播放页的全部触摸逻辑。
///
/// 设计要点（都是「流畅」这两个字的来源）：
/// 1. **不发布任何逐帧状态给页面**。拖动中的模式、起点、基准时间全在这里的私有字段里，
///    页面在拖动过程中一次都不重算；只有 `hud` 和 `visual` 两个小对象在动。
/// 2. **按下即记录基准**（`anchorTime` / `startVolume` / `startBrightness`），
///    拖动过程中播放继续也不会让进度基准漂移。
/// 3. **横向灵敏度自适应**：整屏滑动对应「总时长的一半多」，但夹在 60 秒 ~ 20 分钟之间。
///    整屏 = 全长的映射在 2 小时的片子上一点就飞，在 1 分钟的片子上又完全拖不动。
/// 4. **纵向整屏 = 满量程**。旧版是 0.6 屏高走完 0~100%，稍动就爆音/全黑。
@MainActor
final class PlayerGestureEngine {
    let hud = PlayerHUDBus()
    let visual = PlayerVisualState()

    weak var model: VideoPlaybackModel?

    private let settings = PlayerGestureSettings.shared

    private(set) var locked = false

    /// 页面读它来决定「拖动进度时把底部控件临时叫出来」（只在开始那一帧读一次）
    private(set) var isSeekingByGesture = false

    private enum Mode: Equatable {
        case idle
        case seek
        case volume
        case brightness
        /// 识别出来了但不做任何事（设置里关了），保持到抬手，别每帧重新判定
        case ignored
    }

    private var mode: Mode = .idle
    private var pressed = false
    private var moved = false
    private var holding = false

    private var startPoint: CGPoint = .zero
    private var anchorTime: Double = 0
    private var startVolume: Float = 0
    private var startBrightness: Double = 1

    private var holdTask: Task<Void, Never>?
    private var lastTapAt: Date = .distantPast

    private var pinchBase: CGFloat?
    private var pinching = false

    /// HUD 的节流阀：目标时间变化超过 0.1 秒才刷新一次
    private var lastHUDTarget: Double = .infinity
    private var lastVolumeSent: Float = -1

    /// 拖动进度时每跨过 30 秒轻震一下，手上有「刻度感」
    private let ticker = UISelectionFeedbackGenerator()
    private var lastTickBucket = Int.min

    // MARK: - 锁定

    func setLocked(_ value: Bool) {
        guard locked != value else { return }
        locked = value
        if value { abandon() }
    }

    func resetZoom() {
        visual.zoom = 1
    }

    // MARK: - 拖动

    func dragChanged(_ value: DragGesture.Value, in size: CGSize) {
        guard !locked else { return }
        if !pressed { begin(at: value.startLocation, in: size) }
        guard !pinching else { return }

        let dx = value.translation.width
        let dy = value.translation.height

        if mode == .idle {
            // 阈值 8 pt：再大一点就会有「明明划了却没反应」的感觉
            guard max(abs(dx), abs(dy)) > 8 else { return }
            holdTask?.cancel()
            moved = true

            if abs(dx) >= abs(dy) {
                guard settings.isEnabled, settings.horizontal == .seek, model != nil else {
                    mode = .ignored
                    return
                }
                mode = .seek
                isSeekingByGesture = true
                anchorTime = model?.progress.currentTime ?? 0
                lastHUDTarget = .infinity
                lastTickBucket = Int.min
                ticker.prepare()
                model?.beginScrub()
            } else {
                mode = verticalMode(at: startPoint, in: size)
                if mode == .idle {
                    mode = .ignored
                    return
                }
            }
        }

        switch mode {
        case .seek:
            let duration = model?.progress.duration ?? 0
            guard duration > 0, size.width > 0 else { return }
            let span = min(max(duration * 0.55, 60), 1200)
            let delta = Double(dx / size.width) * span
            let target = min(max(anchorTime + delta, 0), duration)
            // 只写本地显示值，一次都不碰播放器（松手才 seek）
            model?.scrub(to: target)
            // 每跨过 30 秒轻震一下：手上有刻度，就不需要一直盯着 HUD
            let bucket = Int(target / 30)
            if bucket != lastTickBucket {
                lastTickBucket = bucket
                ticker.selectionChanged()
            }
            if abs(target - lastHUDTarget) > 0.1 {
                lastHUDTarget = target
                hud.show(.seek(delta: target - anchorTime, target: target, total: duration))
            }

        case .volume, .brightness:
            guard size.height > 0 else { return }
            // 整屏高度 = 满量程，矮窗口上给个最小行程，避免一划到底
            let span = max(Double(size.height), 320)
            let ratio = Double(-dy) / span

            if mode == .brightness {
                let level = quantize(min(max(startBrightness + ratio, 0.15), 1))
                visual.dim = 1 - level
                hud.show(.brightness(level))
            } else {
                let level = quantize(min(max(Double(startVolume) + ratio, 0), 1))
                // 系统音量的写入有成本（会走一次 MPVolumeView），别每帧都发
                if lastVolumeSent < 0 || abs(Float(level) - lastVolumeSent) > 0.01 {
                    lastVolumeSent = Float(level)
                    model?.setVolume(Float(level))
                    SystemVolume.shared.set(Float(level))
                }
                hud.show(.volume(level))
            }

        case .idle, .ignored:
            break
        }
    }

    func dragEnded(_ value: DragGesture.Value, in size: CGSize) -> PlayerGestureOutcome {
        holdTask?.cancel()
        holdTask = nil

        var outcome = PlayerGestureOutcome.none

        if holding {
            endHold()
        } else if moved {
            switch mode {
            case .seek:
                model?.commitScrub()
                hud.hideLater(0.5)
            case .volume, .brightness:
                hud.hideLater(0.45)
            default:
                break
            }
        } else {
            let isDouble = settings.isEnabled
                && value.time.timeIntervalSince(lastTapAt) < 0.32
            if isDouble {
                lastTapAt = .distantPast
                handleDoubleTap(at: value.startLocation, in: size)
                outcome = .doubleTap
            } else {
                lastTapAt = value.time
                outcome = .singleTap
            }
        }

        reset()
        return outcome
    }

    // MARK: - 捏合

    func magnify(_ value: MagnifyGesture.Value, finished: Bool) {
        guard !locked, settings.isEnabled, settings.pinch == .zoom else { return }

        if finished {
            pinching = false
            pinchBase = nil
            if visual.zoom < 1.05 { visual.zoom = 1 }
            hud.hideLater(0.6)
            return
        }

        if !pinching {
            pinching = true
            holdTask?.cancel()
            // 捏合优先：把可能已经开始的方向拖动收掉，免得一边缩放一边改进度
            if mode == .seek {
                model?.cancelScrub()
                isSeekingByGesture = false
            }
            mode = .ignored
        }

        let base = pinchBase ?? visual.zoom
        pinchBase = base
        visual.zoom = min(max(base * value.magnification, 1), 4)
        hud.show(.zoom(visual.zoom))
    }

    // MARK: - 内部

    private func begin(at point: CGPoint, in size: CGSize) {
        pressed = true
        mode = .idle
        moved = false
        holding = false
        pinching = false
        startPoint = point
        anchorTime = model?.progress.currentTime ?? 0
        startVolume = SystemVolume.shared.current
        startBrightness = 1 - visual.dim
        lastHUDTarget = .infinity
        lastVolumeSent = -1

        holdTask?.cancel()
        guard settings.isEnabled, settings.longPress != .none else { return }
        holdTask = Task { [weak self] in
            // 0.4 秒：比系统的 0.5 秒稍快，长按加速才「按得动」
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled,
                  !self.moved, !self.pinching, !self.locked else { return }
            self.beginHold()
        }
    }

    private func reset() {
        pressed = false
        mode = .idle
        moved = false
        holding = false
        isSeekingByGesture = false
        lastHUDTarget = .infinity
        lastVolumeSent = -1
        lastTickBucket = Int.min
    }

    /// 锁屏 / 页面销毁：把在途的一切收干净，别让「长按 2 倍速」留在播放器上
    private func abandon() {
        holdTask?.cancel()
        holdTask = nil
        if holding {
            holding = false
            model?.endHold()
        }
        if mode == .seek { model?.cancelScrub() }
        pinching = false
        pinchBase = nil
        reset()
        hud.hideNow()
    }

    private func verticalMode(at point: CGPoint, in size: CGSize) -> Mode {
        guard settings.isEnabled else { return .idle }
        switch settings.vertical {
        case .none:
            return .idle
        case .volume:
            return .volume
        case .brightness:
            return .brightness
        case .split:
            return point.x < size.width / 2 ? .brightness : .volume
        }
    }

    private func beginHold() {
        guard !holding, let model else { return }
        holding = true
        model.beginHold(rate: settings.longPress.rate)
        hud.show(.speed(settings.longPress.rate))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func endHold() {
        guard holding else { return }
        holding = false
        model?.endHold()
        hud.hideLater(0.5)
    }

    private func handleDoubleTap(at point: CGPoint, in size: CGSize) {
        guard settings.isEnabled, let model else { return }
        let ratio = size.width > 0 ? max(0, min(1, point.x / size.width)) : 0.5

        switch settings.doubleTap {
        case .none:
            return
        case .playPause:
            model.togglePlay()
            hud.show(.playPause(model.isPlaying), autoHideAfter: 0.6)
        case .forward:
            jump(by: settings.seekStep, position: ratio)
        case .backward:
            jump(by: -settings.seekStep, position: ratio)
        case .sides:
            if ratio < 1.0 / 3.0 {
                jump(by: -settings.seekStep, position: 0.16)
            } else if ratio > 2.0 / 3.0 {
                jump(by: settings.seekStep, position: 0.84)
            } else {
                model.togglePlay()
                hud.show(.playPause(model.isPlaying), autoHideAfter: 0.6)
            }
        }
    }

    private func jump(by delta: Double, position: CGFloat) {
        guard let model else { return }
        let duration = model.progress.duration
        guard duration > 0 else { return }
        let from = model.progress.currentTime
        let target = min(max(from + delta, 0), duration)
        // 双击跳转给 0.3 秒容差：精确到帧在远端流上要多读一个 GOP，明显卡顿
        model.seek(to: target, tolerance: 0.3)
        hud.show(
            .seek(delta: target - from, target: target, total: duration),
            autoHideAfter: 0.7
        )
        hud.showRipple(
            SeekRipple(forward: delta >= 0, seconds: Int(abs(delta).rounded()), position: position)
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func quantize(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
