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
    /// 控件透明度默认 30%（= 白底还有 70% 不透明）：第一次选完壁纸就能看见，
    /// 又不至于把卡片洗到只剩字。**数值是「透明度」不是「不透明度」** —— 100 = 全透明。
    static let controlOpacity: Double = 0.30
}

/// 自定义背景（壁纸 / 纯色）与「控件透明度」的持久化。
///
/// 三份数据：
/// - `kind`：当前用哪种背景（`none` 回到系统分组底色 / `color` 纯色 / `image` 壁纸）；
/// - `colorHex`：纯色背景的颜色；
/// - `controlOpacity`：**控件白底的透明度** 0…1（**100 = 白底全透明只剩壁纸，0 = 原来的实心卡片**）。
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
        /// 1.7.2 换了 key：语义从「不透明度」翻成「透明度」，旧值不能再用，
        /// 否则上一版存的 70 会被当成「70% 透明」，界面一下子糊掉。
        static let opacity = "settings.backgroundTransparency"
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
    /// 所以改成把每个控件的表面色单独降下去 —— 壁纸透过卡片显出来，字仍然是实心的。
    ///
    /// 1.7.2 起数值是**透明度**：100 → 白底 alpha 0（全透），0 → alpha 1（实心卡片）。
    var cardFill: Color {
        Color(uiColor: .secondarySystemGroupedBackground).opacity(1 - controlOpacity)
    }

    /// 卡片几乎透明时把列表分隔线一起收掉：不然壁纸上浮着一排灰线，比不透明还难看。
    var rowSeparator: Visibility {
        1 - controlOpacity < 0.5 ? .hidden : .visible
    }

    /// 卡片**轮廓描边**的强度（1.7.5 起）。
    ///
    /// 分组卡片全透明时（100%）白底没了，模块之间只剩 22 pt 间距，
    /// 壁纸花一点就分不清哪几行是一组。用户原来的读法是「用一条细线区分模块」——
    /// 线太像分割条，改成一圈跟着圆角走的描边：透明度 0 时完全不画（和原来一样），
    /// 越透越明显，最高约 0.10，只在壁纸上勾出卡片轮廓。
    var cardOutlineOpacity: Double {
        let transparency = min(max(controlOpacity, 0), 1)
        return 0.10 * transparency
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
