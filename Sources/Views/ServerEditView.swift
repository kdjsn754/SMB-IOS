import SwiftUI
import UIKit

/// 添加 / 编辑服务器。
///
/// 1.7.6 从 `Form` 换到统一卡片：`Form` 会给每行套不透明底和系统分隔线，
/// 壁纸透不上来，也和设置页不是一套观感（见 `AppSurface.swift`）。
@MainActor
struct ServerEditView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    let original: SMBServer
    let isNew: Bool

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var share: String
    @State private var domain: String
    @State private var username: String
    @State private var password: String

    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testSucceeded = false
    @State private var errorMessage: String?

    init(server: SMBServer, isNew: Bool) {
        self.original = server
        self.isNew = isNew
        _name = State(initialValue: server.name)
        _host = State(initialValue: server.host)
        _port = State(initialValue: String(server.port))
        _share = State(initialValue: server.share)
        _domain = State(initialValue: server.domain)
        _username = State(initialValue: server.username)
        _password = State(initialValue: CredentialStore.password(for: server.id))
    }

    var body: some View {
        NavigationStack {
            AppPage {
                AppGroup("服务器") {
                    AppField(label: "名称", placeholder: "可选，默认用主机地址", text: $name)
                    AppField(label: "主机", placeholder: "192.168.1.10", text: $host, keyboard: .URL)
                    AppField(label: "端口", placeholder: "445", text: $port, keyboard: .numberPad)
                    AppField(label: "共享", placeholder: "Video", text: $share, showsSeparator: false)
                }

                AppGroup(
                    "账户",
                    footer: "Windows 共享若使用微软账户，用户名可填写 MicrosoftAccount\\邮箱地址。"
                ) {
                    AppField(label: "用户名", placeholder: "guest 表示匿名", text: $username)
                    AppField(label: "密码", placeholder: "留空表示无密码", text: $password, isSecure: true)
                    AppField(label: "域", placeholder: "可选", text: $domain, showsSeparator: false)
                }

                AppGroup("连接") {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        AppRow(
                            title: isTesting ? "正在连接…" : "测试连接",
                            titleColor: .accentColor,
                            showsSeparator: testMessage != nil
                        ) {
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .buttonStyle(AppRowPressStyle())
                    .disabled(isTesting)

                    if let testMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: testSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.subheadline)
                            Text(testMessage)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(testSucceeded ? Color.green : Color.orange)
                        .padding(.horizontal, AppSurfaces.cardPadding)
                        .padding(.vertical, 12)
                    }
                }
            }
            .navigationTitle(isNew ? "添加服务器" : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .bold()
                }
            }
            .alert("信息不完整", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func buildServer() -> SMBServer? {
        let cleanedHost = SMBServer.normalize(host: host)
        guard !cleanedHost.isEmpty else {
            errorMessage = "请填写主机地址（IP 或域名）。"
            return nil
        }
        let cleanedShare = share.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedShare.isEmpty else {
            errorMessage = "请填写共享名称，例如 Video、homes、share。"
            return nil
        }

        var server = original
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        server.name = trimmedName.isEmpty ? cleanedHost : trimmedName
        server.host = cleanedHost
        let manualPort = Int(port.trimmingCharacters(in: .whitespaces))
        server.port = SMBServer.embeddedPort(host) ?? manualPort ?? 445
        server.share = cleanedShare
        server.domain = domain.trimmingCharacters(in: .whitespaces)
        server.username = username.trimmingCharacters(in: .whitespaces).isEmpty ? "guest" : username.trimmingCharacters(in: .whitespaces)
        return server
    }

    private func save() {
        guard let server = buildServer() else { return }
        app.upsert(server, password: password)
        dismiss()
    }

    private func testConnection() async {
        guard let server = buildServer() else { return }
        isTesting = true
        testMessage = nil
        let connection = SMBConnection(server: server, password: password)
        do {
            let items = try await connection.listDirectory("/")
            testSucceeded = true
            testMessage = "连接成功，共享根目录有 \(items.count) 个项目"
        } catch {
            testSucceeded = false
            testMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        await connection.disconnect()
        isTesting = false
    }
}
