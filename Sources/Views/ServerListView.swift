import SwiftUI
import UIKit

struct ServerEditorTarget: Identifiable {
    let id = UUID()
    let server: SMBServer
    let isNew: Bool
}

/// 首页（资源库）：自定义顶部标题 + 卡片式服务器列表。
/// 标题、右上角「+」和下面的卡片共用同一条 20pt 边距，视觉上是一条竖线对齐。
@MainActor
struct ServerListView: View {
    @EnvironmentObject private var app: AppModel
    @State private var editor: ServerEditorTarget?

    private let margin: CGFloat = 20

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header

                    if app.servers.isEmpty {
                        emptyCard
                    } else {
                        ForEach(app.servers) { server in
                            NavigationLink {
                                BrowserView(server: server, path: "/")
                            } label: {
                                serverCard(server)
                            }
                            .buttonStyle(.plain)
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
                .padding(.horizontal, margin)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $editor) { target in
                ServerEditView(server: target.server, isNew: target.isNew)
                    .environmentObject(app)
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("资源库")
                    .font(.system(size: 32, weight: .bold))
                Text(app.servers.isEmpty ? "还没有连接" : "\(app.servers.count) 个位置")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                add()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.14), in: Circle())
            }
            .accessibilityLabel("添加服务器")
        }
        .padding(.bottom, 6)
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
