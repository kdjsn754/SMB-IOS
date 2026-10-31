import SwiftUI

@MainActor
struct AppearanceSettingsView: View {
    @AppStorage(SettingsKey.theme) private var themeRaw: String = AppTheme.system.rawValue
    @AppStorage(SettingsKey.gridLayout) private var useGrid: Bool = true

    var body: some View {
        SettingsDetail(title: "外观") {
            Section {
                Picker("主题", selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("网格视图", isOn: $useGrid)
            }
        }
    }
}
