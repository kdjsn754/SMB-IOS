import Foundation

/// 「看到哪儿了」的记忆。
///
/// 键 = 服务器 ID + 远端路径，所以同一个文件名放在两个目录里互不影响。
/// 只记**真看过一会儿**的位置（≥ 5 秒），并且距离结尾 15 秒以内当作看完、不再续播 ——
/// 否则片尾字幕一停就退出的片子，下次点开会从片尾黑屏开始。
///
/// 存 `UserDefaults` 里一段 JSON：条目量小（最多 200 条），读写都在主线程、
/// 一次编码几毫秒，不值得为它单独开队列。
@MainActor
final class PlaybackMemory {
    static let shared = PlaybackMemory()

    private struct Entry: Codable {
        var time: Double
        var duration: Double
        var updated: Date
    }

    private static let key = "settings.player.resume.entries"
    private static let limit = 200

    private let defaults: UserDefaults
    private var entries: [String: Entry] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// 该从哪儿接着看。nil = 从头播。
    func position(for key: String) -> Double? {
        guard let entry = entries[key] else { return nil }
        guard entry.time.isFinite, entry.time >= 5 else { return nil }
        if entry.duration > 0, entry.time >= entry.duration - 15 { return nil }
        return entry.time
    }

    func set(_ time: Double, duration: Double, for key: String) {
        guard time.isFinite, time >= 5 else { return }
        entries[key] = Entry(time: time, duration: max(0, duration), updated: Date())
        pruneIfNeeded()
        save()
    }

    func clear(for key: String) {
        guard entries.removeValue(forKey: key) != nil else { return }
        save()
    }

    // MARK: - 存储

    private func load() {
        guard let data = defaults.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// 超出上限就丢最旧的：这是「最近在看」的索引，不是收藏夹。
    private func pruneIfNeeded() {
        guard entries.count > Self.limit else { return }
        let sorted = entries.sorted { $0.value.updated > $1.value.updated }
        entries = Dictionary(uniqueKeysWithValues: sorted.prefix(Self.limit).map { ($0.key, $0.value) })
    }
}
