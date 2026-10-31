import SwiftUI

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
            Form {
                Section("服务器") {
                    TextField("名称（可选）", text: $name)
                    TextField("主机地址，如 192.168.1.10", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                    TextField("共享名称，如 Video", text: $share)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("用户名（guest 表示匿名）", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                    TextField("域 / 工作组（可选）", text: $domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("账户")
                } footer: {
                    Text("Windows 共享若使用微软账户，用户名可填写 MicrosoftAccount\\邮箱地址。")
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView().padding(.trailing, 4)
                            }
                            Text(isTesting ? "正在连接…" : "测试连接")
                        }
                    }
                    .disabled(isTesting)

                    if let testMessage {
                        Label(testMessage, systemImage: testSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(testSucceeded ? Color.green : Color.orange)
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
