import SwiftUI
import UIKit

/// 背景相关的默认值。
///
/// 单独放一个**非隔离**的 enum，而不是挂在 `@MainActor` 的 `BackgroundSettings` 上：
/// 非隔离上下文的静态常量引用 MainActor 类会编译不过。
enum WallpaperDefaults {
    /// 控件透明度默认 30%（= 白底还有 70% 不透明）：第一次选完壁纸就能看见，
    /// 又不至于把卡片洗到只剩字。**数值是「透明度」不是「不透明度」** —— 100 = 全透明。
    static let controlOpacity: Double = 0.30
}

/// 自定义背景（壁纸）与「控件透明度」的持久化。
///
/// 只保留两种状态：
/// - `none`：不设背景，用系统分组底色（和加这个功能之前完全一样）；
/// - `image`：用户从相册选的壁纸。
///
/// 1.7.6 去掉了「纯色背景」—— 设置项越多，用户越要先想「我到底选了哪种」，
/// 而纯色能做的壁纸都能做（挑一张纯色图即可），干脆只留一条路。
///
/// 壁纸不存进 `UserDefaults`（几百 KB 的二进制会把偏好文件撑爆），
/// 落盘到 `Application Support/SMBViewer/wallpaper.jpg`，偏好里只留开关。
@MainActor
final class BackgroundSettings: ObservableObject {

    enum Kind: String {
        case none
        case image
    }

    static let shared = BackgroundSettings()

    private enum Key {
        static let kind = "settings.backgroundKind"
        /// 1.7.2 换了 key：语义从「不透明度」翻成「透明度」，旧值不能再用，
        /// 否则上一版存的 70 会被当成「70% 透明」，界面一下子糊掉。
        static let opacity = "settings.backgroundTransparency"
    }

    static let defaultOpacity = WallpaperDefaults.controlOpacity

    @Published private(set) var kind: Kind
    /// 壁纸（`kind == .image` 时才有）
    @Published private(set) var image: UIImage?

    /// 控件白底的**透明度**，0…1（100% = 白底全透明）。滑杆直接绑这个值。
    @Published var controlOpacity: Double {
        didSet {
            let clamped = min(max(controlOpacity, 0), 1)
            if clamped != controlOpacity {
                controlOpacity = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Key.opacity)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.kind: Kind.none.rawValue,
            Key.opacity: Self.defaultOpacity
        ])

        var storedKind = Kind(rawValue: defaults.string(forKey: Key.kind) ?? "") ?? .none
        controlOpacity = min(max(defaults.double(forKey: Key.opacity), 0), 1)

        // 图片文件被系统清掉 / 用户重装后恢复失败：不要把 kind 留在 image 上，
        // 否则背景层会一直回落到系统色，而设置页却显示「已设置」。
        if storedKind == .image {
            if let data = try? Data(contentsOf: Self.imageURL), let loaded = UIImage(data: data) {
                image = loaded
            } else {
                storedKind = .none
                defaults.set(Kind.none.rawValue, forKey: Key.kind)
            }
        } else {
            image = nil
        }
        kind = storedKind
    }

    // MARK: - 状态

    /// 设置首页那一行右侧的值
    var summary: String {
        kind == .image ? "图片 · \(percentText)" : "未设置"
    }

    var percentText: String {
        "\(Int((controlOpacity * 100).rounded()))%"
    }

    // MARK: - 写入

    func setImage(_ newImage: UIImage) {
        guard let data = newImage.jpegData(compressionQuality: 0.92) else { return }
        do {
            try data.write(to: Self.imageURL, options: .atomic)
        } catch {
            DiagnosticsStore.shared.note("保存背景图失败：\(error.localizedDescription)")
            return
        }
        image = newImage
        kind = .image
        UserDefaults.standard.set(Kind.image.rawValue, forKey: Key.kind)
        // 落个记号：壁纸「设了但看不见」时，日志里能立刻分清是没存下来还是被挡住了
        DiagnosticsStore.shared.note(
            "设置壁纸 \(Int(newImage.size.width))×\(Int(newImage.size.height))，\(data.count / 1024) KB"
        )
    }

    func clear() {
        kind = .none
        image = nil
        try? FileManager.default.removeItem(at: Self.imageURL)
        UserDefaults.standard.set(Kind.none.rawValue, forKey: Key.kind)
    }

    // MARK: - 落盘位置

    static var imageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SMBViewer", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base.appendingPathComponent("wallpaper.jpg")
    }
}
