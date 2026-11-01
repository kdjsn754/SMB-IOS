import Darwin
import Foundation
import UIKit

/// 自己记「上次是怎么退出的」。
///
/// 为什么需要：侧载重签的包经常拿不到系统「分析数据」里的 `.ips`（有时压根不生成），
/// 一旦闪退就完全没线索。这里只做三件事，不联网、不上报：
///
/// 1. **会话标记**：每次启动写一个 `session.flag`，只有 App 正常终止（`willTerminate`）才删。
///    下次启动时标记还在，就说明上一次不是正常退出。
/// 2. **崩溃落盘**：接住 `NSException` 和常见信号，把类型与调用栈写进 `crash.txt`。
/// 3. **结论存档**：下次启动把判定结果写成 `last-exit.txt`，设置页里直接能看。
///
/// 判定顺序：有 `crash.txt` → 崩溃（带栈）；没有但标记还在 → 被系统终止（多为内存回收）；
/// 都没有 → 上次正常退出。
final class DiagnosticsStore: @unchecked Sendable {
    static let shared = DiagnosticsStore()

    enum Exit: Equatable {
        /// 还没读过（理论上只在 `start()` 之前出现）
        case unknown
        case clean
        case crash(String)
        /// 退到后台之后进程没了：划掉多任务 / 系统回收内存，**都不算闪退**
        case terminatedInBackground
        /// 没进过后台、也不在正常终止里：进程在前台直接消失，这才最可疑
        case terminatedInForeground

        var title: String {
            switch self {
            case .unknown: return "未知"
            case .clean: return "正常退出"
            case .crash: return "上次是崩溃退出"
            case .terminatedInBackground: return "上次在后台结束（无崩溃记录）"
            case .terminatedInForeground: return "上次在前台意外消失（无崩溃记录）"
            }
        }

        /// 设置首页右侧那一小段
        var shortTitle: String {
            switch self {
            case .unknown: return "-"
            case .clean: return "正常"
            case .crash: return "崩溃"
            case .terminatedInBackground: return "后台结束"
            case .terminatedInForeground: return "前台消失"
            }
        }

        var hint: String {
            switch self {
            case .unknown:
                return "还没有记录。"
            case .clean:
                return "上一次会话是正常结束的。"
            case .crash:
                return "App 自己捕获到了崩溃，下面的调用栈可以直接对照代码定位。"
            case .terminatedInBackground:
                return "App 退到后台之后进程没了，这种情况本身**不算闪退**："
                    + "① 你在多任务里把它划掉了；② 后台内存超限被系统回收（看图多、机型内存紧时更容易）。"
                    + "想确认是不是闪退，看下面有没有出现「前台消失」这一条。"
            case .terminatedInForeground:
                return "没有崩溃记录，也没进过后台的痕迹 —— 进程是在前台直接消失的，这一条才值得查。"
                    + "重点怀疑：重签证书被吊销或过期（表现是「点开就退回桌面」）、"
                    + "以及启动时卡太久被看门狗判定超时（0x8badf00d）。"
            }
        }
    }

    /// 上次退出的判定结果，`start()` 之后可读
    private(set) var previousExit: Exit = .unknown
    /// `last-exit.txt` 的落盘时间（等于上次启动时间）
    private(set) var previousExitAt: Date?

    private let directory: URL
    /// 信号处理里不能用 `FileManager`，提前把路径转成 C 字符串
    private var crashPath: UnsafeMutablePointer<CChar>?
    /// 一次崩溃只写一次，避免 handler 里递归
    private var crashRecorded = false
    /// `start()` 只跑一次（App 的 `init` 理论上只跑一次，防一手）
    private var started = false

    private init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private var crashURL: URL { directory.appendingPathComponent("crash.txt") }
    private var flagURL: URL { directory.appendingPathComponent("session.flag") }
    /// 每次退到后台留一个记号：用来区分「进程在前台没了」和「退到后台之后没的」
    private var backgroundURL: URL { directory.appendingPathComponent("background.flag") }
    private var reportURL: URL { directory.appendingPathComponent("last-exit.txt") }
    /// 内存警告次数（`UserDefaults`，进程被杀也留得住）
    private static let memoryWarningKey = "diag.memoryWarnings"

    // MARK: - 生命周期

    /// App 启动时调用一次（`SMBViewerApp.init`）
    func start() {
        guard !started else { return }
        started = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        crashPath = strdup(crashURL.path)
        installHandlers()
        readPreviousExit()
        beginSession()
    }

    /// 正常终止时调用（`willTerminate`）：抹掉标记，下次启动就不会误报
    func markCleanExit() {
        try? FileManager.default.removeItem(at: flagURL)
        try? FileManager.default.removeItem(at: backgroundURL)
    }

    /// 每次退到后台记一笔。
    ///
    /// App 在**挂起状态**被用户从多任务划掉时，系统不会调 `willTerminate`。
    /// 只看会话标记的话，「手动划掉」和「后台被系统回收」会混在一起，
    /// 全都被报成「被系统终止」，容易让人误以为又闪退了。
    /// 有了这个记号就能把两种情况分开：
    /// 有它 → 进程是退到后台之后没的；没有它 → 进程是在前台直接消失的。
    func noteBackground() {
        guard started else { return }
        // 顺便把「收到过几次内存警告」写进去：如果进程是被 jetsam 干掉的，
        // 这一行就是最直接的证据（诊断页能看到）。
        let warnings = UserDefaults.standard.integer(forKey: Self.memoryWarningKey)
        let detail = "内存警告累计 \(warnings) 次"
        try? Data(detail.utf8).write(to: backgroundURL, options: .atomic)
    }

    /// 收到系统内存警告时记一笔（跨进程保留，进程被杀也还在）
    func noteMemoryWarning() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: Self.memoryWarningKey) + 1, forKey: Self.memoryWarningKey)
    }

    /// 设置里「清除记录」
    func clear() {
        try? FileManager.default.removeItem(at: reportURL)
        try? FileManager.default.removeItem(at: crashURL)
        try? FileManager.default.removeItem(at: backgroundURL)
        previousExit = .unknown
        previousExitAt = nil
    }

    /// 给设置页展示的完整文本
    var reportText: String {
        var lines: [String] = []
        lines.append("App 版本：\(AppInfo.version)")
        if let date = previousExitAt {
            lines.append("上次会话：\(Self.stampText(date))")
        }
        lines.append("判定：\(previousExit.title)")
        if case .crash(let detail) = previousExit {
            lines.append("")
            lines.append(detail)
        } else {
            lines.append("")
            lines.append(previousExit.hint)
        }
        if let background = try? String(contentsOf: backgroundURL, encoding: .utf8),
           !background.isEmpty {
            lines.append("")
            lines.append("上次退到后台时：\(background)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 上次退出

    private func readPreviousExit() {
        let crashText = (try? String(contentsOf: crashURL, encoding: .utf8)) ?? ""
        if !crashText.isEmpty {
            previousExit = .crash(crashText)
            // 崩溃文件的修改时间 ≈ 崩溃发生的那一刻
            previousExitAt = Self.modified(crashURL) ?? Date()
        } else if FileManager.default.fileExists(atPath: flagURL.path) {
            if FileManager.default.fileExists(atPath: backgroundURL.path) {
                previousExit = .terminatedInBackground
                // 后台记号的时间 ≈ 最后一次退到后台的时刻
                previousExitAt = Self.modified(backgroundURL) ?? Self.modified(flagURL)
            } else {
                previousExit = .terminatedInForeground
                previousExitAt = Self.modified(flagURL)
            }
        } else if FileManager.default.fileExists(atPath: reportURL.path) {
            previousExit = .clean
            previousExitAt = Self.modified(reportURL)
        } else {
            // 首次安装：还没有任何记录，别急着说「正常」
            previousExit = .unknown
            previousExitAt = nil
        }

        // 落盘一份，供设置页长期查看（crash.txt 在下面会被清掉，避免重复报告）
        try? reportText.write(to: reportURL, atomically: true, encoding: .utf8)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// 本次会话开始：清掉上一次的崩溃文件与后台记号，立一个新标记
    private func beginSession() {
        try? FileManager.default.removeItem(at: crashURL)
        try? FileManager.default.removeItem(at: backgroundURL)
        try? Data().write(to: flagURL, options: .atomic)
    }

    // MARK: - 崩溃捕获

    private func installHandlers() {
        // 用文件级函数而不是闭包：C 函数指针不能捕获上下文，抽成函数最稳
        NSSetUncaughtExceptionHandler(smbViewerExceptionHandler)

        // 只接「会被系统判死」的那几个：Swift 的数组越界 / 强制解包 nil 走 SIGTRAP，
        // fatalError 走 SIGILL/SIGTRAP，野指针走 SIGSEGV/SIGBUS。
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, smbViewerSignalHandler)
        }
    }

    /// 信号/异常处理里调用：用 `open`/`write` 直接落盘，不碰 `FileManager`
    fileprivate func recordCrash(_ text: String) {
        guard !crashRecorded, let path = crashPath else { return }
        crashRecorded = true

        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { return }
        text.withCString { pointer in
            _ = write(fd, pointer, strlen(pointer))
        }
        close(fd)
    }

    fileprivate static func signalText(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default: return "signal"
        }
    }

    fileprivate static func stampText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - 崩溃回调
//
// 必须是**文件级的普通函数**：`NSSetUncaughtExceptionHandler` 与 `signal`
// 要的是 C 函数指针，闭包一旦捕获上下文就转不过去。

private func smbViewerExceptionHandler(_ exception: NSException) {
    let stack = exception.callStackSymbols.joined(separator: "\n")
    let text = """
    类型：OC 异常
    名称：\(exception.name.rawValue)
    原因：\(exception.reason ?? "-")
    时间：\(DiagnosticsStore.stampText(Date()))

    调用栈：
    \(stack)
    """
    DiagnosticsStore.shared.recordCrash(text)
}

private func smbViewerSignalHandler(_ sig: Int32) {
    let stack = Thread.callStackSymbols.joined(separator: "\n")
    // 信号处理里不碰 `DateFormatter`（会分配内存，有死锁风险），时间看文件修改时间
    let text = """
    类型：信号 \(sig)（\(DiagnosticsStore.signalText(sig))）

    调用栈：
    \(stack)
    """
    DiagnosticsStore.shared.recordCrash(text)
    // 交回系统默认处理，保证系统那边的崩溃记录照常生成
    signal(sig, SIG_DFL)
    raise(sig)
}
