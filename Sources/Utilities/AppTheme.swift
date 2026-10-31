import Foundation
import SwiftUI

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
            SettingsKey.theme: AppTheme.system.rawValue,
            SettingsKey.cacheLimitMB: 500,
            SettingsKey.autoClean: true,
            SettingsKey.gridLayout: true,
            SettingsKey.sortOrder: BrowserSort.name.rawValue,
            SettingsKey.thumbnailsEnabled: true,
            SettingsKey.videoThumbnails: true
        ])
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
