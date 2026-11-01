import Foundation
import Combine

@MainActor
final class BrowserModel: ObservableObject {
    let server: SMBServer
    let path: String

    @Published private(set) var items: [FileItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    /// 退出全屏看图后的一小段「不认点击」时间窗。
    ///
    /// **故意不是 `@Published`**：写入它不能触发刷新。退出看图那一刻目录页刚从转场里
    /// 恢复，此时任何一次 `objectWillChange` 都会让整页（含 `LazyVGrid` 的全部可见格子）
    /// 重算一遍，正好卡在系统恢复手势的时间点上 —— 表现就是「退出后要等一会才能右滑返回」。
    private var tapGuardUntil: Date = .distantPast

    /// 当前能不能点开一张图（退出动画刚结束的那一下不算点击）
    var canOpenViewer: Bool { Date() >= tapGuardUntil }

    /// 全屏看图退出了：接下来这么一小段时间忽略点击。
    ///
    /// 时间窗压到 0.25 s：退出动画本身已经把手指数百毫秒挡在外面，
    /// 再叠一个长的静默期只会让「退出后马上点下一张」变得迟钝。
    func noteViewerDismissed() {
        tapGuardUntil = Date().addingTimeInterval(0.25)
    }

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
