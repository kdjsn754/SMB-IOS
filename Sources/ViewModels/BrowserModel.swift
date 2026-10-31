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
        BrowserSort.name.sorted(items)
    }
}

/// 目录排序方式（文件夹永远排在文件前面）
enum BrowserSort: String, CaseIterable, Identifiable {
    case name
    case nameDescending
    case dateNewest
    case dateOldest
    case sizeLargest
    case sizeSmallest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .nameDescending: return "名称（倒序）"
        case .dateNewest: return "修改时间（新→旧）"
        case .dateOldest: return "修改时间（旧→新）"
        case .sizeLargest: return "大小（大→小）"
        case .sizeSmallest: return "大小（小→大）"
        }
    }

    var icon: String {
        switch self {
        case .name, .nameDescending: return "textformat"
        case .dateNewest, .dateOldest: return "clock"
        case .sizeLargest, .sizeSmallest: return "externaldrive"
        }
    }

    func sorted(_ items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }

            switch self {
            case .name:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .nameDescending:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
            case .dateNewest, .dateOldest:
                let left = lhs.modified ?? .distantPast
                let right = rhs.modified ?? .distantPast
                if left == right {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return self == .dateNewest ? left > right : left < right
            case .sizeLargest, .sizeSmallest:
                if lhs.size == rhs.size {
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
                return self == .sizeLargest ? lhs.size > rhs.size : lhs.size < rhs.size
            }
        }
    }
}
