import SwiftUI

@MainActor
struct RootView: View {
    var body: some View {
        TabView {
            ServerListView()
                .tabItem { Label("服务器", systemImage: "externaldrive.connected.to.line.below") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
