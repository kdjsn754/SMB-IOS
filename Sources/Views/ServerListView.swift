import SwiftUI
import UIKit

struct ServerEditorTarget: Identifiable {
    let id = UUID()
    let server: SMBServer
    let isNew: Bool
}

/// 首页（资源库）：系统大标题 + 右上角系统「+」，服务器以卡片形式列出。
/// 用 `List` 承载卡片，卡片边距和系统大标题共用同一套 20pt，顶部天然对齐。
@MainActor
struct ServerListView: View {
    @EnvironmentObject private var app: AppModel
    @State private var editor: ServerEditorTarget?

    var body: some View {
        NavigationStack {
            List {
                if app.servers.isEmpty {
                    emptyCard
                        .cardRow()
                } else {
                    ForEach(app.servers) { server in
                        NavigationLink {
                            BrowserView(server: server, path: "/")
                        } label: {
                            serverCard(server)
                        }
                        .buttonStyle(.plain)
                        .cardRow()
                        .contextMenu {
                            Button {
                                edit(server)
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                app.delete(server)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("资源库")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        add()
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

    // MARK: - 卡片

    private func serverCard(_ server: SMBServer) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(server.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(server.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                if let date = server.lastConnected {
                    Text(Format.date(date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    private var emptyCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            Text("还没有服务器")
                .font(.headline)

            Text("添加 NAS 或电脑的共享地址后，就能在这里浏览图片与视频。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                add()
            } label: {
                Label("添加服务器", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    // MARK: - 动作

    private func add() {
        editor = ServerEditorTarget(
            server: SMBServer(name: "", host: "", port: 445, share: "", domain: "", username: "guest"),
            isNew: true
        )
    }

    private func edit(_ server: SMBServer) {
        editor = ServerEditorTarget(server: server, isNew: false)
    }
}

private extension View {
    /// 把卡片放进 `List`：去掉分隔线、行底色和额外缩进，左右各留 20pt（和系统大标题同一条线）
    func cardRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
    }
}
