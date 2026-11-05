import SwiftUI
import UIKit

/// 背景相关的默认值。
///
/// 单独放一个**非隔离**的 enum，而不是挂在 `@MainActor` 的 `BackgroundSettings` 上：
/// `Color(hex:)` 这类纯工具处在非隔离上下文，引用 MainActor 类的 static 属性
/// 在严格并发下会编译不过。
enum WallpaperDefaults {
    /// 纯色背景的默认值（藏蓝，配浅色/深色两种主题都不刺眼）
    static let colorHex = "#3D5A80"
    /// 控件透明度默认 70%：第一次选完壁纸就能看见，又不会把文字压得读不清
    static let controlOpacity: Double = 0.70
}

/// 自定义背景（壁纸 / 纯色）与「控件透明度」的持久化。
///
/// 三份数据：
/// - `kind`：当前用哪种背景（`none` 回到系统分组底色 / `color` 纯色 / `image` 壁纸）；
/// - `colorHex`：纯色背景的颜色；
/// - `controlOpacity`：**控件白底**的不透明度 0…1（0 = 白底全透明只剩壁纸，1 = 原来的实心卡片）。
///   文字**不跟着淡** —— 早先版本用整页 `.opacity()`，标题和文件名一起被洗掉才改成现在这样。
///
/// 壁纸不存进 `UserDefaults`（几百 KB 的二进制会把偏好文件撑爆），
/// 落盘到 `Application Support/SMBViewer/wallpaper.jpg`，偏好里只留开关与颜色。
@MainActor
final class BackgroundSettings: ObservableObject {

    enum Kind: String {
        case none
        case color
        case image
    }

    static let shared = BackgroundSettings()

    private enum Key {
        static let kind = "settings.backgroundKind"
        static let color = "settings.backgroundColor"
        static let opacity = "settings.backgroundOpacity"
    }

    /// 纯色背景的默认值（藏蓝，配浅色/深色两种主题都不刺眼）
    /// 控件透明度默认 70%：第一次选完壁纸就能看见，又不会把文字压得读不清
    static let defaultColorHex = WallpaperDefaults.colorHex
    static let defaultOpacity = WallpaperDefaults.controlOpacity

    @Published private(set) var kind: Kind
    /// 壁纸（`kind == .image` 时才有）
    @Published private(set) var image: UIImage?

    @Published var colorHex: String {
        didSet {
            guard oldValue != colorHex else { return }
            UserDefaults.standard.set(colorHex, forKey: Key.color)
        }
    }

    /// 控件层不透明度，0…1。滑块直接绑这个值。
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
            Key.color: Self.defaultColorHex,
            Key.opacity: Self.defaultOpacity
        ])

        var storedKind = Kind(rawValue: defaults.string(forKey: Key.kind) ?? "") ?? .none
        colorHex = defaults.string(forKey: Key.color) ?? Self.defaultColorHex
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

    var isActive: Bool { kind != .none }

    /// 设置首页那一行右侧的值
    var summary: String {
        switch kind {
        case .none: return "未设置"
        case .image: return "图片 · \(percentText)"
        case .color: return "纯色 · \(percentText)"
        }
    }

    var percentText: String {
        "\(Int((controlOpacity * 100).rounded()))%"
    }

    /// 卡片 / 行 / 面板的「白底」颜色，透明度就是控件透明度。
    ///
    /// 1.7.1 起**只淡白底，不淡文字**：整页 `.opacity()` 会把标题、文件名一起洗掉，
    /// 所以改成把每个控件的表面色单独降到 `controlOpacity` ——
    /// 壁纸透过卡片显出来，字仍然是实心的。
    var cardFill: Color {
        Color(uiColor: .secondarySystemGroupedBackground).opacity(controlOpacity)
    }

    /// 卡片几乎透明时把列表分隔线一起收掉：不然壁纸上浮着一排灰线，比不透明还难看。
    var rowSeparator: Visibility {
        controlOpacity < 0.5 ? .hidden : .visible
    }

    // MARK: - 写入

    func setColor(_ hex: String) {
        colorHex = hex
        kind = .color
        UserDefaults.standard.set(Kind.color.rawValue, forKey: Key.kind)
    }

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
