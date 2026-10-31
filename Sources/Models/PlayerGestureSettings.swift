import Combine
import Foundation

// MARK: - 动作枚举

/// 双击手势可以做的事
enum DoubleTapAction: String, CaseIterable, Identifiable {
    /// 左三分之一快退、右三分之一快进、中间播放/暂停（默认，和主流播放器一致）
    case sides
    /// 任意位置都是播放 / 暂停
    case playPause
    /// 任意位置都是快进
    case forward
    /// 任意位置都是快退
    case backward
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sides: return "两侧快退/快进，中间播放暂停"
        case .playPause: return "播放 / 暂停"
        case .forward: return "快进"
        case .backward: return "快退"
        case .none: return "关闭"
        }
    }

    /// 设置页里的一句话说明
    var detail: String {
        switch self {
        case .sides: return "左三分之一双击快退、右三分之一快进，中间双击暂停"
        case .playPause: return "双击画面任意位置切换播放与暂停"
        case .forward: return "双击画面任意位置向前跳"
        case .backward: return "双击画面任意位置向后跳"
        case .none: return "双击不做任何事，只响应单击"
        }
    }
}

/// 左右拖动
enum HorizontalDragAction: String, CaseIterable, Identifiable {
    case seek
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .seek: return "拖动进度"
        case .none: return "关闭"
        }
    }
}

/// 上下拖动
enum VerticalDragAction: String, CaseIterable, Identifiable {
    /// 屏幕左半边调亮度、右半边调音量（默认）
    case split
    case volume
    case brightness
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .split: return "左亮度 / 右音量"
        case .volume: return "调节音量"
        case .brightness: return "调节亮度"
        case .none: return "关闭"
        }
    }

    var detail: String {
        switch self {
        case .split: return "在左半边上下拖调亮度，右半边上下拖调音量"
        case .volume: return "任意位置上下拖都是调音量"
        case .brightness: return "任意位置上下拖都是调亮度"
        case .none: return "上下拖动不做任何事"
        }
    }
}

/// 长按（按住加速，松手恢复）
enum LongPressAction: String, CaseIterable, Identifiable {
    case half = "1.5"
    case double = "2"
    case triple = "3"
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .half: return "1.5 倍速"
        case .double: return "2 倍速"
        case .triple: return "3 倍速"
        case .none: return "关闭"
        }
    }

    var rate: Float {
        switch self {
        case .half: return 1.5
        case .double: return 2
        case .triple: return 3
        case .none: return 1
        }
    }
}

/// 双指捏合
enum PinchAction: String, CaseIterable, Identifiable {
    case zoom
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zoom: return "缩放画面"
        case .none: return "关闭"
        }
    }
}

// MARK: - 设置存储

/// 播放器手势配置。写进 `UserDefaults`，播放器与设置页读同一份，
/// 改完立刻生效（不需要重启播放页）。
@MainActor
final class PlayerGestureSettings: ObservableObject {
    static let shared = PlayerGestureSettings()

    /// 双击时快进 / 快退的秒数
    static let seekStepChoices: [Double] = [5, 10, 15, 30]

    private enum Key {
        static let enabled = "settings.gesture.enabled"
        static let doubleTap = "settings.gesture.doubleTap"
        static let seekStep = "settings.gesture.seekStep"
        static let horizontal = "settings.gesture.horizontal"
        static let vertical = "settings.gesture.vertical"
        static let longPress = "settings.gesture.longPress"
        static let pinch = "settings.gesture.pinch"
    }

    private let defaults: UserDefaults

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }
    @Published var doubleTap: DoubleTapAction {
        didSet { defaults.set(doubleTap.rawValue, forKey: Key.doubleTap) }
    }
    @Published var seekStep: Double {
        didSet { defaults.set(seekStep, forKey: Key.seekStep) }
    }
    @Published var horizontal: HorizontalDragAction {
        didSet { defaults.set(horizontal.rawValue, forKey: Key.horizontal) }
    }
    @Published var vertical: VerticalDragAction {
        didSet { defaults.set(vertical.rawValue, forKey: Key.vertical) }
    }
    @Published var longPress: LongPressAction {
        didSet { defaults.set(longPress.rawValue, forKey: Key.longPress) }
    }
    @Published var pinch: PinchAction {
        didSet { defaults.set(pinch.rawValue, forKey: Key.pinch) }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // 未写过就取注册的默认值（AppDefaults.register）
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }

        isEnabled = bool(Key.enabled, true)

        doubleTap = DoubleTapAction(rawValue: defaults.string(forKey: Key.doubleTap) ?? "")
            ?? .sides

        let step = defaults.object(forKey: Key.seekStep) as? Double ?? 10
        seekStep = Self.seekStepChoices.contains(step) ? step : 10

        horizontal = HorizontalDragAction(rawValue: defaults.string(forKey: Key.horizontal) ?? "")
            ?? .seek

        vertical = VerticalDragAction(rawValue: defaults.string(forKey: Key.vertical) ?? "")
            ?? .split

        longPress = LongPressAction(rawValue: defaults.string(forKey: Key.longPress) ?? "")
            ?? .double

        pinch = PinchAction(rawValue: defaults.string(forKey: Key.pinch) ?? "")
            ?? .zoom
    }

    /// 全部恢复默认
    func resetToDefaults() {
        isEnabled = true
        doubleTap = .sides
        seekStep = 10
        horizontal = .seek
        vertical = .split
        longPress = .double
        pinch = .zoom
    }
}
