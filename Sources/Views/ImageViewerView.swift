import SwiftUI
import UIKit

/// 全屏看图。（最低系统 iOS 27，不做向下兼容 —— 2026-11-01 用户拍板：能用原生就用原生）
///
/// ## 1.4.3 重做：手势不再互相抢
///
/// 之前这一页是「SwiftUI 原生滚动翻页 + 自绘捏合/拖动缩放」，靠
/// `.gesture(pan, including: scale > 1.01 ? .all : .none)` 给两条手势分区 ——
/// 而 `including:` 在手势**安装**那一刻就定死了，捏合中途放大/归位都改不了归属。
/// 用户实测的「各手势很容易冲突，尤其是双指捏合和左右翻页」就是这套结构的必然结果：
/// 捏合的两指只要不同步，外层的 pan 就一起识别，画面边缩边横向漂；缩回 1x 后
/// 哪条手势活着全看上一帧，时灵时不灵。
///
/// 现在缩放与翻页全部搬进 `ZoomablePager`（外层分页 `UIScrollView` + 每页一个内层缩放
/// `UIScrollView`，苹果照片 App / `PhotoScroller` 的经典结构）。分工由 UIKit 的识别顺序
/// 决定，不再靠我们自己判断 `scale`：1x 时内层无可滚动内容 → 拖动归外层翻页；
/// 双指落下 → 内层 pinch 成立、立刻关掉外层；放大后拖动归内层平移。
///
/// 本页只剩三件事：黑底、浮层（关闭/页码/文件名）、前後页预热。
/// 下滑退出仍然全归系统（缩放转场自带的交互式关闭），系统的「捏合退出」由
/// `PinchDismissDisabler` 摘掉（它和内层捏合缩小是同一形态，会抢）。
@MainActor
struct ImageViewerView: View {
    let items: [FileItem]
    let serverID: UUID
    let connection: SMBConnection
    /// 目录页传进来的缩放转场命名空间。非 nil 时进出场和下拉/捏合退出
    /// 全部交给系统的「从缩略图长出来 / 缩回去」转场（照片 App 那套）。
    let zoomNamespace: Namespace.ID?

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    /// 浮层（关闭按钮、页码、文件名）是否可见。
    ///
    /// 走系统缩放转场时初值是 false：转场会把**整页内容**一起从格子里放大，
    /// 连按钮和页码也会被拉大，看着很怪（照片 App 里控件是图片到位之后才淡入的）。
    /// 所以先藏起来，等画面长到位再淡入；退出时也先收掉，不让它跟着缩回去。
    @State private var chromeVisible: Bool
    /// 用户在自动淡入之前自己点过（切过浮层）就不再替他打开
    @State private var chromeTouched = false

    init(
        items: [FileItem],
        startIndex: Int,
        serverID: UUID,
        connection: SMBConnection,
        zoomNamespace: Namespace.ID? = nil
    ) {
        self.items = items
        self.serverID = serverID
        self.connection = connection
        self.zoomNamespace = zoomNamespace
        let safeIndex = items.isEmpty ? 0 : min(max(0, startIndex), items.count - 1)
        _index = State(initialValue: safeIndex)
        _chromeVisible = State(initialValue: zoomNamespace == nil)
    }

    /// 缩放转场的终点 id：**由本页的 `index` 直接算**。
    ///
    /// 为什么不由目录页传：那样它会是 `BrowserView` 的 `@State`，
    /// 点开时和 `overlay` 在同一个更新周期里改。系统在呈现那一刻去读 destination 的
    /// `sourceID`，偶尔读到的还是**上一张**（跨视图的状态传播慢半拍），
    /// 配不上当前格子的 `matchedTransitionSource` 就退回默认的「从下往上」——
    /// 这正是「有时候动画还是从下面升上来」。`index` 是 `init` 里就定好的本页状态，
    /// 第一帧就是正确的值，不存在这个时序。
    private var currentItemID: String? {
        items[safe: index]?.id
    }

    var body: some View {
        ZStack {
            // 黑底放在 `GeometryReader` **外面**：弹进来的第一帧 `proxy.size` 可能还是 0，
            // 那样里的黑底只有 1×1 点，整页会先透出底下目录页、下一帧才变黑（就是「点开闪一下」）。
            // 放在最外层后，第一帧就是满屏黑。
            // 下拉退出时露出的目录页由系统交互式关闭自己处理（转场层往下挪，本页黑底跟着走）。
            Color.black
                .ignoresSafeArea()

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let height = max(proxy.size.height, 1)

                if items.isEmpty {
                    Color.clear
                } else {
                    // 分页 + 缩放 + 单击切浮层，全部在 UIKit 层里由同一套识别器分工（见 ZoomablePager）。
                    // 按钮/页码/文件名仍留在这里（SwiftUI 做浮层比 UIView 省事得多），
                    // 两边唯一的接口是 `index` 和 `onTap`。
                    ZoomablePager(
                        items: items,
                        serverID: serverID,
                        connection: connection,
                        index: $index,
                        onTap: { toggleChrome() }
                    )
                    .frame(width: width, height: height)
                }
            }
            // 注意：这里**不要** ignoresSafeArea。width/height 就是页面的尺寸，
            // 必须和滚动视口一致；曾经全屏扩展过，932 高的页面塞进 840 高的视口里
            // 垂直溢出，图片能顶到状态栏。

            // 浮层留在安全区内，不跟着画面全屏铺（否则按钮会压到状态栏）
            if chromeVisible {
                // 单独抽成 `Equatable` 子视图：翻页时外层 body 重算，
                // 但这里的入参（页码 / 文件名 / 大小）在翻页前都不变，
                // SwiftUI 就会跳过它的 body —— 毛玻璃 `.ultraThinMaterial`
                // 和两段文字不必跟着重建。
                ChromeLayer(
                    index: index,
                    count: items.count,
                    name: items[safe: index]?.name ?? "",
                    size: items[safe: index]?.size ?? 0,
                    onClose: close
                )
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        // 下滑退出交给系统的交互式关闭（缩放转场原生手势）：不要 disable。
        // 历史教训：之前在这里 disable 掉系统、换自绘手势，是因为当时自绘翻页
        // 手势和系统抢识别；翻页归原生滚动后已无竞争者。
        //
        // 但系统那条「捏合退出」要单独摘掉：它和页内图片放大后的向内捏合缩小
        // 是同一个手势形态，两条同时识别，系统一赢页面就被关掉（用户实测
        // 「缩小不起作用了，直接退出」）。见 `PinchDismissDisabler`。
        .background {
            PinchDismissDisabler()
                .frame(width: 0, height: 0)
        }
        .statusBarHidden(!chromeVisible)
        // 系统那层不透明黑底会让「下拉渐隐」白做，退出时还会跟着滑一次
        .presentationBackground(Color.clear)
        // 声明「用缩放转场进来」，终点取本页当前这张的 id（见 `currentItemID`）。
        // 必须是这条链的最外层，系统才认得出它和缩略图的配对。
        .zoomDestination(id: currentItemID, in: zoomNamespace)
        .task {
            // 画面从缩略图长到位之后，浮层再淡入（照片 App 的节奏）。
            // 不走缩放转场时浮层初值就是 true，这里直接返回。
            guard !chromeVisible else { return }
            try? await Task.sleep(nanoseconds: 480_000_000)
            guard !Task.isCancelled, !chromeTouched, !chromeVisible else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                chromeVisible = true
            }
        }
        .onChange(of: index) { _ in
            // 翻页会让系统把「捏合退出」识别器重新挂上（1.3.33 的必现 bug：
            // 刚切到新图就捏合必定退出）。落定这一拍立刻清一遍，不等轮询的下一拍。
            //
            // 注意这里**只做这一件事**：以前还会清 `isZoomed`、回写目录页的
            // `zoomedItemID`，前者已经由 `PhotoPageView` 自己按页管理，
            // 后者会让整个目录页（LazyVGrid 全部格子）在每次翻页时重算，
            // 正好压在翻页动画上，是「左右滑动卡顿」的一部分。
            PinchDismissGuard.shared.enforce()
        }
        .task(id: index) {
            // 翻页后，把前后两张搬进本地缓存（只搬不解码）。
            // 这样下一次左右滑是「磁盘已就绪」，省掉一次 SMB 往返。
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await prefetchNeighbors()
        }
    }

    /// 预热前后两页：**只保证磁盘上有原始副本，不解码**（1.3.24 起当前页直接解原图，
    /// 全分辨率位图一张一两百 MB，把没显示的邻居页也解进内存吃不消）。
    /// 用户很快又划走时任务会被取消，`CancellationBox` 会把底层 SMB 传输一起掐掉，
    /// 不会在后台白读几十兆。翻到邻居页那一刻再由 `MediaStore.image(for:)` 现解原图，
    /// 等待期由缩略图铺底。
    private func prefetchNeighbors() async {
        for offset in [index + 1, index - 1] {
            guard !Task.isCancelled, items.indices.contains(offset) else { continue }
            let item = items[offset]

            let box = CancellationBox()
            await withTaskCancellationHandler {
                await MediaStore.shared.warm(
                    for: item,
                    serverID: serverID,
                    connection: connection,
                    cancel: box
                )
            } onCancel: {
                box.cancel()
            }
        }
    }

    /// 单击画面切浮层。识别在 UIKit 层（`PhotoPageView` 的 tap recognizer），
    /// 单击要等双击失败才触发 —— 否则双击放大时会顺带把浮层切一下。
    private func toggleChrome() {
        chromeTouched = true
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible.toggle()
        }
    }

    /// 关闭：先收掉浮层，再让系统做缩回缩略图的转场，
    /// 否则关闭按钮和页码会跟着画面一起缩成一粒。
    private func close() {
        chromeVisible = false
        dismiss()
    }
}

// MARK: - 浮层

/// 顶部关闭按钮 + 页码、底部文件名 + 大小。
///
/// 单独抽成 `Equatable` 视图：翻页换 `index` 时外层 body 重算，
/// 但只要这几项入参没变，SwiftUI 就跳过这里的 body —— `ultraThinMaterial` 毛玻璃
/// 和文字不必跟着重建。
private struct ChromeLayer: View, Equatable {
    let index: Int
    let count: Int
    let name: String
    let size: Int64
    /// 闭包不参与比较：`==` 为真时沿用上一次的闭包，捕获的 `@State` / `dismiss` 都是稳定的
    let onClose: () -> Void

    static func == (lhs: ChromeLayer, rhs: ChromeLayer) -> Bool {
        lhs.index == rhs.index && lhs.count == rhs.count && lhs.name == rhs.name && lhs.size == rhs.size
    }

    var body: some View {
        VStack {
            HStack {
                // 和播放页左上角完全同款：白箭头 + 36 pt 黑色圆底（1.3.32）
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.45), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
                .padding(.leading, 8)

                Spacer()

                if count > 1 {
                    Text("\(index + 1) / \(count)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 4) {
                Text(name)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if size > 0 {
                    Text(Format.bytes(size))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
