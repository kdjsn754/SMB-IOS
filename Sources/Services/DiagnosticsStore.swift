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
///
/// **`background.flag` 只在「这次真的没回前台」时才算数**：回前台由 `noteForeground()` 撤掉。
/// 1.3.6 及之前没有这一步，于是「进过后台 → 回前台 → 前台闪退」被一律误判成「后台结束」，
/// 真正的闪退永远显示不出来。1.3.7 起改掉，并额外记一份操作轨迹（`steps.txt`）——
/// `SIGPIPE`、看门狗这类死法没有崩溃栈，只有「最后一步在干什么」能定位。
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
                return "进程是在**退到后台之后**没的：挂在后台被系统回收，或你在多任务里划掉了。"
                    + "这种情况本身不算闪退；但如果它出现得太频繁，把下面的「退到后台时占用」发我。"
            case .terminatedInForeground:
                return "没有崩溃记录，也没进过后台的痕迹 —— 进程是在前台直接消失的，这一条最值得查："
                    + "① 往已断开的 SMB 连接上写数据触发 SIGPIPE（1.3.7 起已全局忽略）；"
                    + "② 主线程卡太久被看门狗判死（0x8badf00d）；③ 内存超限。"
                    + "往下看「上次会话最后几步」，最后一条基本就是出事那一刻在做什么。"
            }
        }
    }

    /// 上次退出的判定结果，`start()` 之后可读
    private(set) var previousExit: Exit = .unknown
    /// `last-exit.txt` 的落盘时间（等于上次启动时间）
    private(set) var previousExitAt: Date?
    /// 上一次会话最后几步操作（启动时读出来，写进日志备用）
    private(set) var previousSteps: [String] = []

    /// 本次会话的操作轨迹（只在关键节点追加，最多 24 条）
    private let stepsLock = NSLock()
    private var steps: [String] = []
    /// 上一条轨迹（内容 + 时间），用于节流
    private var lastNote: (text: String, at: Date)?

    private let directory: URL
    /// 信号处理里不能用 `FileManager`，提前把路径转成 C 字符串
    private var crashPath: UnsafeMutablePointer<CChar>?
    /// 一次崩溃只写一次，避免 handler 里递归
    private var crashRecorded = false
    /// `start()` 只跑一次（App 的 `init` 理论上只跑一次，防一手）
    private var started = false

    private init() {
        // **放 Caches，不放 Documents**（1.4.6 起）：Documents 会被「文件」App
        // 直接展示成 App 目录（用户截图里的「SMB 播放器 → Diagnostics」），
        // 而这里存的只是崩溃 / 退出轨迹，属于派生数据，不该长在用户眼皮底下。
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private var crashURL: URL { directory.appendingPathComponent("crash.txt") }
    private var flagURL: URL { directory.appendingPathComponent("session.flag") }
    /// 每次退到后台留一个记号：用来区分「进程在前台没了」和「退到后台之后没的」
    private var backgroundURL: URL { directory.appendingPathComponent("background.flag") }
    /// 上一次「退到后台时的内存占用」长期存档（`backgroundURL` 会在回前台时被撤掉）
    private var lastBackgroundURL: URL { directory.appendingPathComponent("last-bg.txt") }
    /// 上一次会话最后几步操作（崩溃前在干什么）
    private var stepsURL: URL { directory.appendingPathComponent("steps.txt") }
    private var reportURL: URL { directory.appendingPathComponent("last-exit.txt") }
    /// 内存警告次数（`UserDefaults`，进程被杀也留得住）
    private static let memoryWarningKey = "diag.memoryWarnings"

    // MARK: - 生命周期

    /// App 启动时调用一次（`SMBViewerApp.init`）
    func start() {
        guard !started else { return }
        started = true
        removeLegacyDocumentsDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        crashPath = strdup(crashURL.path)
        installHandlers()
        readPreviousExit()
        beginSession()
    }

    /// 删掉老版本留在 `Documents/Diagnostics` 的那一份（1.4.6 之前的位置）。
    ///
    /// 只认这一个目录名，`Documents` 里别的东西一律不碰；删完顺手把空的 `Documents`
    /// 也收掉 —— App 本身不往那里存任何东西，它唯一的作用就是被「文件」App 展示成
    /// 一个空的「SMB 播放器」文件夹（用户 2026-11-02 明确要求去掉）。
    private func removeLegacyDocumentsDirectory() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let legacy = documents.appendingPathComponent("Diagnostics", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.removeItem(at: legacy)
        }
        // 只剩空壳才删：万一以后真有东西存进去，这里会安静地什么都不做
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []
        if contents.isEmpty {
            try? FileManager.default.removeItem(at: documents)
        }
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
        // 把「收到过几次内存警告」和「此刻进程占多少内存」写进去：
        // 进程是不是被 jetsam 干掉的，这两行就是最直接的证据（日志里能看到）。
        // `phys_footprint` 正是系统判定内存超限用的那个指标。
        let warnings = UserDefaults.standard.integer(forKey: Self.memoryWarningKey)
        let detail = "内存警告累计 \(warnings) 次；退后台时占用 \(Self.footprintMB()) MB"
        try? Data(detail.utf8).write(to: backgroundURL, options: .atomic)
    }

    /// 每次回到前台记一笔：把「后台记号」撤掉。
    ///
    /// 不撤的后果很严重（1.3.6 及之前一直是这样）：只要进过一次后台，这条记号就一直留着，
    /// 之后哪怕进程是在**前台**点导航栏时没的，下次启动也一律判成「后台结束（无崩溃记录）」——
    /// 真正的闪退被这条过期记号盖住了，于是「反复闪退、却永远查不到」。
    ///
    /// 记号里的内容（内存占用）搬到 `last-bg.txt` 继续写进日志备用，不影响对账。
    func noteForeground() {
        guard started else { return }
        if let data = try? Data(contentsOf: backgroundURL) {
            try? data.write(to: lastBackgroundURL, options: .atomic)
        }
        try? FileManager.default.removeItem(at: backgroundURL)
    }

    /// 记一步操作轨迹（只写一个小文件，几十字节）。
    ///
    /// 为什么需要：`SIGPIPE`、`0x8badf00d`（看门狗）这类死法**不会留下任何崩溃栈**，
    /// 只有「进程消失前最后一步在干什么」能帮上忙。轨迹只在关键节点写（进目录、点工具栏、
    /// 退/回前台、SMB 出错），不会拖慢滚动。
    func note(_ step: String) {
        guard started else { return }
        let now = Date()
        let line = "\(Self.clockText(now)) \(step)"
        stepsLock.lock()
        // 同一条内容 2 秒内只记一次：批量失败（几十个格子同时报同一个错）时不刷屏，
        // 也不会因为频繁写文件拖慢主线程
        if let last = lastNote, last.text == step, now.timeIntervalSince(last.at) < 2 {
            stepsLock.unlock()
            return
        }
        lastNote = (text: step, at: now)
        steps.append(line)
        if steps.count > 24 { steps.removeFirst(steps.count - 24) }
        let text = steps.joined(separator: "\n")
        stepsLock.unlock()
        try? text.write(to: stepsURL, atomically: true, encoding: .utf8)
    }

    /// 只取时钟部分，轨迹里不需要日期
    private static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 进程当前的物理内存占用（MB）。拿不到返回 -1。
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / 1024 / 1024)
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
        try? FileManager.default.removeItem(at: lastBackgroundURL)
        previousExit = .unknown
        previousExitAt = nil
        previousSteps = []
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
        if let background = try? String(contentsOf: lastBackgroundURL, encoding: .utf8),
           !background.isEmpty {
            lines.append("")
            lines.append("上次退到后台时：\(background)")
        }
        if !previousSteps.isEmpty {
            lines.append("")
            lines.append("上次会话最后几步：")
            // 只展示最近 10 步，够定位、又不至于刷屏
            lines.append(contentsOf: previousSteps.suffix(10).map { "· \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 上次退出

    private func readPreviousExit() {
        // 先把上次的后台记号内容搬走：下面 `beginSession()` 会删掉记号文件本身
        if FileManager.default.fileExists(atPath: backgroundURL.path) {
            try? FileManager.default.removeItem(at: lastBackgroundURL)
            try? FileManager.default.copyItem(at: backgroundURL, to: lastBackgroundURL)
        }
        // 上次会话的操作轨迹（崩溃前最后几步）
        previousSteps = ((try? String(contentsOf: stepsURL, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map { String($0) }

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

    /// 本次会话开始：清掉上一次的崩溃文件、后台记号与操作轨迹，立一个新标记
    private func beginSession() {
        try? FileManager.default.removeItem(at: crashURL)
        try? FileManager.default.removeItem(at: backgroundURL)
        try? FileManager.default.removeItem(at: stepsURL)
        stepsLock.lock()
        steps.removeAll()
        stepsLock.unlock()
        try? Data().write(to: flagURL, options: .atomic)
    }

    // MARK: - 崩溃捕获

    private func installHandlers() {
        // 用文件级函数而不是闭包：C 函数指针不能捕获上下文，抽成函数最稳
        NSSetUncaughtExceptionHandler(smbViewerExceptionHandler)

        // ⚠️ SIGPIPE 必须忽略 —— 这是「回前台点一下导航栏就退回桌面、诊断里却一条记录都没有」的元凶。
        //
        // SMB 的底层是 TCP socket。App 挂后台期间（尤其是几分钟以上），服务器或路由器
        // 会把这条连接悄悄回收掉。回到前台后任何一次操作继续往死 socket 上写，内核就给
        // 进程发 SIGPIPE —— **默认行为是直接终止进程**，它既不走 `NSException`，也走不到
        // 下面那几个信号的处理器（我们没注册它）。于是进程静默消失、`crash.txt` 为空，
        // 只留下一条过期的 `background.flag`，被判定成「后台结束（无崩溃记录）」。
        //
        // 忽略之后，写失败会退化成正常的 `EPIPE` 错误码，由 SMB 那一层当普通 I/O 错误处理
        // （见 `SMBConnection.describe`），连接会被丢弃、下一次操作自动重连。
        signal(SIGPIPE, SIG_IGN)

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
