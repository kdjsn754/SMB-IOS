import Combine
import Foundation

/// 播放页的横竖屏策略。
///
/// 就是用户要的三件事：**自动识别**（按视频比例判）、**强制竖屏**、**强制横屏**。
///
/// 为什么要有「强制」这两个：以前进页面只看视频比例，竖片就一定是竖屏，
/// 用户手动转过去之后，退出再进（或者连播下一个）又被按比例掰回来。
/// 现在选择写进 `UserDefaults`，退出播放器重新打开仍然按选的那个方向播。
enum PlaybackOrientationMode: String, CaseIterable, Identifiable {
    /// 按视频宽高比自动转：横片进横屏、竖片留竖屏
    case auto
    case portrait
    case landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动识别"
        case .portrait: return "强制竖屏"
        case .landscape: return "强制横屏"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "横着拍的视频转横屏，竖着拍的留在竖屏"
        case .portrait: return "不管视频是什么比例，都竖屏播放"
        case .landscape: return "不管视频是什么比例，都横屏播放"
        }
    }

    /// 顶栏 / 面板行尾那一点地方用的短写法
    var shortTitle: String {
        switch self {
        case .auto: return "自动"
        case .portrait: return "竖屏"
        case .landscape: return "横屏"
        }
    }
}

/// 播放页里「记住就生效」的显示设置。
///
/// 目前只有横竖屏策略，单独一个对象而不是塞进 `PlayerGestureSettings`：
/// 那个是手势，这个是画面，混在一起以后加「默认倍速」「默认画面适配」时不好分。
@MainActor
final class PlayerDisplaySettings: ObservableObject {
    static let shared = PlayerDisplaySettings()

    private enum Key {
        static let orientation = "settings.player.orientation"
    }

    private let defaults: UserDefaults

    /// 默认 `.auto`：没设置过的老用户行为不变（按比例自动转）
    @Published var orientationMode: PlaybackOrientationMode {
        didSet { defaults.set(orientationMode.rawValue, forKey: Key.orientation) }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        orientationMode = PlaybackOrientationMode(
            rawValue: defaults.string(forKey: Key.orientation) ?? ""
        ) ?? .auto
    }
}
