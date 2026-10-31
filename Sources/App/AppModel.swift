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
