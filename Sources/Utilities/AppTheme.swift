import Foundation
import SwiftUI
import UIKit

/// 用户可配置项的存储键
enum SettingsKey {
    static let theme = "settings.theme"
    static let cacheLimitMB = "settings.cacheLimitMB"
    static let autoClean = "settings.autoClean"
    static let gridLayout = "settings.gridLayout"
    static let sortOrder = "settings.sortOrder"
    static let thumbnailsEnabled = "settings.thumbnailsEnabled"
    static let videoThumbnails = "settings.videoThumbnails"
}

enum AppDefaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.theme: AppTheme.light.rawValue,
            SettingsKey.cacheLimitMB: 500,
            SettingsKey.autoClean: true,
            SettingsKey.gridLayout: true,
            SettingsKey.sortOrder: BrowserSort.name.rawValue,
            SettingsKey.thumbnailsEnabled: true,
            SettingsKey.videoThumbnails: true
        ])
    }
}

/// 只有浅色 / 深色两种。1.3.28 起去掉「跟随系统」——
/// 老版本存过 `system`，`resolve` 会按当前系统外观落成浅色或深色，不会出现空主题。
enum AppTheme: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 选择器上的图标（太阳 / 月亮）
    var icon: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// 解析存储值：未知值（含旧版的 `system`）按当前系统外观取一个确定值
    static func resolve(_ raw: String) -> AppTheme {
        if let theme = AppTheme(rawValue: raw) { return theme }
        return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
    }
}
