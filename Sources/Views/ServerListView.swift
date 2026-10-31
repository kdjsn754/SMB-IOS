import SwiftUI

struct ServerEditorTarget: Identifiable {
    let id = UUID()
    let server: SMBServer
    let isNew: Bool
}

@MainActor
struct ServerListView: View {
    @EnvironmentObject private var app: AppModel
    @State private var editor: ServerEditorTarget?

    var body: some View {
        NavigationStack {
            Group {
                if app.servers.isEmpty {
                    emptyState
                } else {
                    serverList
                }
            }
            .navigationTitle("SMB 服务器")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editor = ServerEditorTarget(
                            server: SMBServer(name: "", host: "", port: 445, share: "", domain: "", username: "guest"),
                            isNew: true
                        )
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加服务器")
                }
            }
            .sheet(item: $editor) { target in
                ServerEditView(server: target.server, isNew: target.isNew)
                    .environmentObject(app)
            }
        }
    }

    private var serverList: some View {
        List {
            Section {
                ForEach(app.servers) { server in
                    NavigationLink {
                        BrowserView(server: server, path: "/")
                    } label: {
                        row(for: server)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            app.delete(server)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            editor = ServerEditorTarget(server: server, isNew: false)
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
            } footer: {
                Text("支持 SMB2 / SMB3 协议的 NAS、Windows 共享、群晖、威联通、路由器挂载盘等。")
            }
        }
    }

    private func row(for server: SMBServer) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(server.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let date = server.lastConnected {
                Text(Format.date(date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有添加服务器")
                .font(.headline)
            Text("点击右上角「+」填写 NAS 或电脑的共享信息，\n即可浏览其中的图片与视频。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                editor = ServerEditorTarget(
                    server: SMBServer(name: "", host: "", port: 445, share: "", domain: "", username: "guest"),
                    isNew: true
                )
            } label: {
                Label("添加服务器", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
