import Foundation

/// 版本信息统一入口：设置首页、关于页都读这一份，避免两处各算一遍。
enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var versionWithBuild: String {
        "\(version) (\(build))"
    }

    static var minimumOS: String {
        Bundle.main.infoDictionary?["MinimumOSVersion"] as? String ?? "-"
    }
}
