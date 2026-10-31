import SwiftUI

@MainActor
struct AboutSettingsView: View {
    var body: some View {
        SettingsDetail(title: "关于") {
            Section {
                LabeledContent("版本", value: AppInfo.version)
                LabeledContent("构建", value: AppInfo.build)
                LabeledContent("最低系统", value: "iOS " + AppInfo.minimumOS)
            }

            Section {
                LabeledContent("协议", value: "SMB 2 / 3")
                LabeledContent("网络库", value: "AMSMB2")
            }
        }
    }
}
