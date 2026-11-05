import SwiftUI
import UIKit

struct ServerEditorTarget: Identifiable {
    let id = UUID()
    let server: SMBServer
    let isNew: Bool
}

/// 首页（资源库）：自绘大标题 + 右侧圆形「+」，和服务器卡片同一条 24pt 竖线。
///
/// 为什么不用系统大标题导航栏：系统大标题和 `ToolbarItem` 的「+」**永远不在同一行**
/// （按钮在导航栏那行、标题在下一行），而设计要求两者齐平居中。所以导航栏整体隐藏，
/// 标题与按钮自己排一行；`NavigationStack` 仍保留，进二级页时由二级页
/// `.toolbar(.visible, for: .navigationBar)` 把返回按钮要回来。
@MainActor
struct ServerListView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var background = BackgroundSettings.shared
    @State private var editor: ServerEditorTarget?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                ScrollView {
                    LazyVStack(spacing: 10) {
                        if app.servers.isEmpty {
                            emptyCard
                        } else {
                            ForEach(app.servers) { server in
                                serverLink(server)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
                    .padding(.bottom, 28)
                }
            }
            // 壁纸铺在这一页自己的视图树里，不靠父容器透底（见 `pageBackground()`）
            .pageBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $editor) { target in
                ServerEditView(server: target.server, isNew: target.isNew)
                    .environmentObject(app)
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("资源库")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            Button {
                add()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("添加服务器")
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    // MARK: - 卡片

    private func serverLink(_ server: SMBServer) -> some View {
        NavigationLink {
            BrowserView(server: server, path: "/")
        } label: {
            serverCard(server)
        }
        .buttonStyle(ServerCardButtonStyle())
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

            // 唯一的一个小箭头：卡片自己画，不走 `List`/`NavigationLink` 的系统 accessory
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        // 卡片白底跟随「控件透明度」：文字始终实心，只有这块底在淡
        .background(
            background.cardFill,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            background.cardFill,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    // MARK: - 动作

    private func add() {
        DiagnosticsStore.shared.note("点「+」添加服务器")
        editor = ServerEditorTarget(
            server: SMBServer(name: "", host: "", port: 445, share: "", domain: "", username: "guest"),
            isNew: true
        )
    }

    private func edit(_ server: SMBServer) {
        DiagnosticsStore.shared.note("编辑服务器 \(server.displayName)")
        editor = ServerEditorTarget(server: server, isNew: false)
    }
}

/// 卡片按下时轻微缩放 + 变暗，代替 `List` 行自带的高亮（不在 `List` 里就没有那个效果）
private struct ServerCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
