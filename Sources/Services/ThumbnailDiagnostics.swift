import Combine
import Foundation

/// 缩略图失败原因的简易记录，设置页里能看到最近 5 条。
///
/// 用户那边只能靠截图反馈，所以失败原因必须「可读」：到底是找不到 moov、
/// 还是临时文件写不下、还是抽帧失败，一眼就能分辨。
final class ThumbnailDiagnostics: ObservableObject, @unchecked Sendable {
    static let shared = ThumbnailDiagnostics()

    struct Entry: Identifiable, Hashable {
        let id: String
        let name: String
        let reason: String
    }

    @Published private(set) var entries: [Entry] = []

    private static let storageKey = "thumbnail.diagnostics"
    private let lock = NSLock()

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        entries = stored.compactMap { line in
            let parts = line.components(separatedBy: "｜")
            guard parts.count == 2 else { return nil }
            return Entry(id: line, name: parts[0], reason: parts[1])
        }
    }

    static func record(_ name: String, _ reason: String) {
        shared.append(name: name, reason: reason)
    }

    func clear() {
        lock.lock()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.entries = []
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        }
    }

    private func append(name: String, reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let line = "\(name)｜\(reason)"
            var list = self.entries.filter { $0.id != line }
            list.insert(Entry(id: line, name: name, reason: reason), at: 0)
            if list.count > 5 { list.removeLast(list.count - 5) }
            self.entries = list
            UserDefaults.standard.set(list.map(\.id), forKey: Self.storageKey)
        }
    }
}
