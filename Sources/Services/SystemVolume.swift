import AVFoundation
import MediaPlayer
import UIKit

/// 系统输出音量控制。
///
/// iOS 没有公开的「设置系统音量」API，唯一可行的路子是 `MPVolumeView` 内部那个 `UISlider`：
/// 把 volume view 塞到一个屏幕外的窗口上，改它的 slider 值并 `sendActions`，
/// 系统音量就会真的跟着变（和抖音 / 系统播放器拖音量一样），而且**不会弹系统音量 HUD**。
@MainActor
final class SystemVolume {
    static let shared = SystemVolume()

    private let volumeView = MPVolumeView(frame: CGRect(x: -300, y: -300, width: 40, height: 40))
    private var slider: UISlider?

    /// 当前系统音量（拿不到 slider 时退回 AVAudioSession 的输出音量）
    var current: Float {
        if let slider {
            return slider.value
        }
        return AVAudioSession.sharedInstance().outputVolume
    }

    func set(_ value: Float) {
        installIfNeeded()
        let clamped = min(max(value, 0), 1)
        if slider == nil {
            slider = Self.findSlider(in: volumeView)
        }
        guard let slider else { return }
        slider.value = clamped
        slider.sendActions(for: .valueChanged)
    }

    private func installIfNeeded() {
        guard volumeView.superview == nil else { return }
        volumeView.isUserInteractionEnabled = false
        volumeView.alpha = 0.01
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true

        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })
        else { return }

        window.addSubview(volumeView)
        slider = Self.findSlider(in: volumeView)
    }

    private static func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for sub in view.subviews {
            if let found = findSlider(in: sub) { return found }
        }
        return nil
    }
}
