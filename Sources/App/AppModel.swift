import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var servers: [SMBServer] = []

    let cache = CacheManager.shared

    private var connections: [UUID: SMBConnection] = [:]
    private static let storageKey = "smbviewer.servers.v1"

    init() {
        load()
    }

    func bootstrap() {
        cache.refresh()
        cache.autoCleanIfNeeded()
    }

    func connection(for server: SMBServer) -> SMBConnection {
        if let existing = connections[server.id] {
            return existing
        }
        let password = CredentialStore.password(for: server.id)
        let connection = SMBConnection(server: server, password: password)
        connections[server.id] = connection
        return connection
    }

    /// 回到前台时把陈旧的 SMB 连接全部作废。
    ///
    /// 挂后台期间（尤其几分钟以上）服务器或路由器很可能已经把 TCP 连接回收了。
    /// 继续拿旧 socket 干活：轻则每个请求先挂 30 秒超时（回到前台满屏转圈，缩略图全空），
    /// 重则往死连接上写数据触发 **SIGPIPE** —— 内核直接杀进程，连崩溃栈都没有。
    ///
    /// 这里只是丢掉引用（下一次操作按需重建），**不做** `disconnectShare()`：
    /// 那个调用本身就要往死 socket 上写，正好会踩到上面那个坑。
    func invalidateConnections() {
        // 不换对象、只作废里面的 socket：视图手里拿的还是同一个 `SMBConnection`，
        // 下一次操作会在它内部重建连接，不会出现「新旧两个对象连同一个服务器」
        for connection in connections.values {
            Task { await connection.invalidate() }
        }
    }

    func upsert(_ server: SMBServer, password: String?) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        if let password {
            CredentialStore.setPassword(password, for: server.id)
        }
        connections[server.id] = nil
        save()
    }

    func delete(_ server: SMBServer) {
        servers.removeAll { $0.id == server.id }
        connections[server.id] = nil
        CredentialStore.delete(for: server.id)
        save()
    }

    func markConnected(_ server: SMBServer) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        if let last = servers[index].lastConnected, Date().timeIntervalSince(last) < 300 { return }
        servers[index].lastConnected = Date()
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([SMBServer].self, from: data) else {
            return
        }
        servers = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
