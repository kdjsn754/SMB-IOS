import SwiftUI

@MainActor
struct GestureSettingsView: View {
    var body: some View {
        SettingsDetail(title: "播放手势") {
            // 二级页标题已经写了「播放手势」，表单里不再重复分组标题
            PlayerGestureSettingsSections(header: nil)
        }
    }
}
