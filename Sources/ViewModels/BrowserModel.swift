import Foundation
import Combine

@MainActor
final class BrowserModel: ObservableObject {
    let server: SMBServer
    let path: String

    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    init(server: SMBServer, path: String) {
        self.server = server
        self.path = path
    }

    func load(using connection: SMBConnection) async {
        if isLoading { return }
        isLoading = true
        errorMessage = nil
        do {
            let list = try await connection.listDirectory(path)
            items = Self.sorted(list)
        } catch {
            if items.isEmpty {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        isLoading = false
    }

    func refresh(using connection: SMBConnection) async {
        isLoading = false
        await load(using: connection)
    }

    static func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
