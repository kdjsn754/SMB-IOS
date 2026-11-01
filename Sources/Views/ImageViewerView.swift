import SwiftUI
import UIKit

/// 全屏看图。
///
/// 分页不用 `TabView(.page)`：它的翻页手势是 UIKit 内部 pan，
/// 会和外层「下拉退出」的 `DragGesture` 互相抢（要么翻不了页，要么拖不动退）。
/// 这里自己用 `ZStack + 每页绝对 offset` 算位置，一个手势同时处理「横向翻页 / 纵向下拉退出」。
///
/// 为什么不是 `HStack`：只渲染三页时，换页那一刻 `range` 会整体平移一格，
/// 每页在 `HStack` 里的**布局位置**会一次性跳一个屏宽，而 `.offset` 只负责补上手指拖出去的那一小段。
/// 布局跳变不可动画（兄弟页被 insert/remove），于是松手瞬间整排内容瞬移一屏——看起来就是「图片直接闪出来」。
/// 改成每页位置只由 `(i - index) * width` 这个 offset 决定，位移全部走图层变换，`withAnimation` 一定能动画。
///
/// 为什么不用系统自带的下滑退出：`fullScreenCover` 的呈现方式是 `fullScreen`，
/// 系统交互式下滑在它上面并不可靠（iOS 18+ 配 zoom 转场之后更明显：手指落下能跟，
/// 但拖快一点、或内容层还并挂着别的拖动识别器，它就退回不认）。所以手势自己做，
/// 但**位移只走图层**（offset / scaleEffect），并且用 `PageStack` 把图片内容按「不可变」隔离掉，
/// 拖动时不会重建页面树，手感和系统一样跟手。
@MainActor
struct ImageViewerView: View {
    let items: [FileItem]
    let serverID: UUID
    let connection: SMBConnection
    /// 目录页传进来的缩放转场命名空间。非 nil 且系统是 iOS 18+ 时，进出场交给系统的
    /// 「从缩略图长出来 / 缩回去」转场（照片 App 那套）；下滑手势仍由本页自绘。
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
    /// 当前页是否处于放大状态：放大时手势交给页内的 pan（移动画面），外层不做翻页/退出
    @State private var isZoomed = false
    /// 手势过程中的实时位移（只影响图层，不触发图片内容重建）
    @State private var drag: CGSize = .zero
    /// 本次拖动锁定的方向：判一次就锁住，避免斜着拖时在翻页/下拉之间来回跳
    @State private var dragAxis: DragAxis?
    /// 松手后正在收尾退出，期间忽略新手势
    @State private var isDismissing = false

    /// 一次拖动只属于一个方向
    private enum DragAxis { case horizontal, vertical }

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
        _chromeVisible = State(initialValue: !(Self.supportsZoom(zoomNamespace)))
    }

    private static func supportsZoom(_ namespace: Namespace.ID?) -> Bool {
        if #available(iOS 18.0, *) { return namespace != nil }
        return false
    }

    /// 走系统缩放转场吗？
    ///
    /// 走了之后：**进出场**由系统负责（从缩略图长大 / 缩回缩略图），点关闭或下滑退出都是这一套。
    /// 但**下滑手势本身**仍是我们自己的：`fullScreenCover` 没有可靠的系统交互式下滑，
    /// 所以 `interactiveDismissDisabled` 把系统那条关掉，纵向位移照旧写进 `drag`。
    private var usesSystemZoom: Bool {
        Self.supportsZoom(zoomNamespace)
    }

    /// 下拉退出的进度 0…1：背景变透明、画面缩小、顶部栏淡出都跟着它
    ///
    /// 系统缩放转场模式下也照常计算。原先这里把纵向整段交给系统的「下滑退出」，
    /// 但它挂在 `fullScreenCover` 上时只在部分时机认手（内容层有并挂的拖动、
    /// 或松手速度稍慢就退回），表现就是「很多时候下滑退不出去」。
    /// 现在纵向一律由下面这支手势自己跟手，超过阈值再 `dismiss()`，
    /// 由系统接着把画面缩回格子 —— 手感不依赖系统认不认手。
    private var pullProgress: CGFloat {
        min(1, max(0, drag.height) / 380)
    }

    /// 只保留「上一页 / 当前页 / 下一页」三张：目录可能有几百张图，
    /// 全建出来的话不但白占内存，换页时也要重算几百个视图。
    private var pageRange: ClosedRange<Int> {
        guard !items.isEmpty else { return 0...0 }
        let lower = max(0, index - 1)
        let upper = min(items.count - 1, index + 1)
        return lower...max(lower, upper)
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
            // 放在最外层后，第一帧就是满屏黑，跟后面的画面衔接不上任何空隙。
            // 往下拖时背景逐渐透明，能看见下面被遮住的目录页，明确「松手就退出」。
            Color.black
                .opacity(max(0, 1 - pullProgress * 1.1))
                .ignoresSafeArea()

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let height = max(proxy.size.height, 1)

                ZStack {
                    if items.isEmpty {
                        Color.clear
                    } else {
                        paged(
                            PageStack(
                                items: items,
                                range: pageRange,
                                index: index,
                                serverID: serverID,
                                connection: connection,
                                width: width,
                                height: height,
                                isZoomed: $isZoomed
                            )
                            .equatable()
                            // 横向位移必须落在裁剪框「里面」：翻页时下一张从屏幕边缘滑进来，
                            // 超出屏幕的部分被裁掉；否则下拉缩小（0.86 倍）时会在屏幕右边
                            // 露出一条别页的边。
                            .offset(x: drag.width)
                            .clipped()
                            // 纵向位移落在裁剪框「外面」：整块画面跟着手指往下走，
                            // 露出下面被遮住的目录页。
                            .offset(y: drag.height)
                            .scaleEffect(1 - pullProgress * 0.14)
                            .contentShape(Rectangle()),
                            width: width,
                            height: height
                        )
                        .onTapGesture { toggleChrome() }
                    }
                }
                .frame(width: width, height: height)
            }
            .ignoresSafeArea()

            // 浮层留在安全区内，不跟着画面全屏铺（否则按钮会压到状态栏）
            if chromeVisible && pullProgress < 0.1 {
                // 单独抽成 `Equatable` 子视图：拖动时外层 body 每帧重算，
                // 但这里的入参（页码 / 文件名 / 大小）在翻页前都不变，
                // SwiftUI 就会跳过它的 body —— 毛玻璃 `.ultraThinMaterial`
                // 和两段文字不必每帧重建，滑动时省下一大块主线程开销。
                ChromeLayer(
                    index: index,
                    count: items.count,
                    name: items[safe: index]?.name ?? "",
                    size: items[safe: index]?.size ?? 0,
                    onClose: close
                )
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(1 - pullProgress * 6)
                .allowsHitTesting(pullProgress < 0.02)
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        // 下滑退出只留一条通路：自己那条手势。系统的交互式关闭在 `fullScreenCover` 上
        // 时灵时不灵，放开的话会出现「手指拖到一半被系统接管、然后弹回去」的抖动。
        .interactiveDismissDisabled(usesSystemZoom)
        .statusBarHidden(!chromeVisible || pullProgress > 0.05)
        // 系统那层不透明黑底会让「下拉渐隐」白做，退出时还会跟着滑一次
        .clearPresentationBackground()
        // 声明「用缩放转场进来」，终点取本页当前这张的 id（见 `currentItemID`）。
        // 必须是这条链的最外层，系统才认得出它和缩略图的配对。
        .zoomDestination(id: currentItemID, in: zoomNamespace)
        .task {
            // 画面从缩略图长到位之后，浮层再淡入（照片 App 的节奏）。
            // 旧系统的上滑盖屏不用这一步，`chromeVisible` 初值就是 true，这里直接返回。
            guard usesSystemZoom, !chromeVisible else { return }
            try? await Task.sleep(nanoseconds: 480_000_000)
            guard !Task.isCancelled, !chromeTouched, !chromeVisible else { return }
            withAnimation(.easeOut(duration: 0.22)) {
                chromeVisible = true
            }
        }
        .onChange(of: index) { _ in
            // 换页时把上一页的放大状态清掉，否则新一页的翻页手势会被误判成「正在放大」。
            //
            // 这里曾经还会回写目录页的 `zoomedItemID`，但那会让**整个目录页**
            // （`LazyVGrid` 里全部格子 + 缩略图）在每一页切换时重算一遍，
            // 正好压翻页动画的时间段上，是「左右滑动很卡顿」的一部分。
            // 缩放转场的终点 id 现在由看图页内部按 `index` 算，不再需要那次回写。
            isZoomed = false
        }
        .task(id: index) {
            // 翻页动画落定后，把前后两张解码好放进内存预览缓存。
            // 这样下一次左右滑是「已经解码完毕」，滑过去第一帧就是清晰原图。
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await prefetchNeighbors()
        }
    }

    /// 预热前后两页：磁盘上没有的读回磁盘，然后把**解码好的屏幕级预览**放进内存缓存。
    /// 用户很快又划走时任务会被取消，`CancellationBox` 会把底层 SMB 传输一起掐掉，
    /// 不会在后台白读几十兆。
    ///
    /// 为什么现在也把图留在内存里：1.3.1 那版只写盘不落地，结果每次翻页都要在主线程解一张 3000 边长的大图 ——
    /// 「左右滑动切换图片很卡顿」就是这么来的。现在解码在后台完成、结果进 `NSCache`（最多 4 张、可被系统回收），
    /// 滑过去第一帧就是清晰的。
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

    // MARK: - 手势

    /// 翻页 + 下拉退出的手势挂法。
    ///
    /// 一律用 `.gesture`（独占）：纵向位移要在 `onChanged` 里逐帧写进 `drag` 让画面跟手，
    /// 这必须是同一条手势的连续事件。之前走系统缩放转场时改成 `.simultaneousGesture`
    /// 想把纵向让给系统，结果两边都不干脆：系统的下滑关闭时好时坏，我们这边又因为
    /// 收到纵向事件后直接 return，出现了「拖了半屏、松手什么都不发生」的空窗。
    /// 现在纵向也归自己，系统的交互式关闭在 `body` 里用 `interactiveDismissDisabled` 关掉，
    /// 只保留 `dismiss()` 时那一下缩回格子的转场。
    private func paged<Content: View>(_ content: Content, width: CGFloat, height: CGFloat) -> some View {
        content.gesture(pagingGesture(width: width, height: height))
    }

    private func pagingGesture(width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isZoomed, !isDismissing else { return }
                let dx = value.translation.width
                let dy = value.translation.height

                // 方向只判一次，判完就锁住。
                //
                // 逐帧比较 `abs(dy) > abs(dx)` 的话，手指稍微斜一点就会在
                // 「横向翻页」和「纵向下拉」之间反复跳：这一帧按纵向把画面拉下来，
                // 下一帧又按横向把 `drag.height` 清成 0，画面原地抖一下再回来。
                // 用户看到的正是「拖了没反应 / 拖到一半弹回去」，也就是
                // 「下滑退出很多时候触发不了」。锁定之后，一次拖动只会走一条路径。
                if dragAxis == nil {
                    guard max(abs(dx), abs(dy)) > 6 else { return }
                    dragAxis = abs(dy) > abs(dx) ? .vertical : .horizontal
                }

                switch dragAxis {
                case .vertical?:
                    // 往下才跟手：往上没有退出语义，别让画面乱飘
                    drag = CGSize(width: dx * 0.18, height: max(0, dy))
                case .horizontal?:
                    // 首尾页加阻尼，像系统那样拖到头有回弹感
                    var x = dx
                    if (index == 0 && dx > 0) || (index == items.count - 1 && dx < 0) {
                        x *= 0.32
                    }
                    drag = CGSize(width: x, height: 0)
                case .none:
                    break
                }
            }
            .onEnded { value in
                let axis = dragAxis
                dragAxis = nil
                guard !isZoomed, !isDismissing, let axis else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { drag = .zero }
                    return
                }
                let dx = value.translation.width
                let dy = value.translation.height

                if axis == .vertical {
                    // 拖过屏高约 1/7，或者甩得够快，就退出。
                    // 阈值别定太高：手指从图片中部往下拖到下巴附近也就 200pt 出头。
                    let distance = max(84, height * 0.14)
                    if dy > distance || value.predictedEndTranslation.height > height * 0.3 {
                        // 退出只动一次：画面现在停在哪就留在哪，交给系统转场缩回格子。
                        isDismissing = true
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            drag = .zero
                        }
                    }
                    return
                }

                let threshold = max(60, width * 0.22)
                var target = index
                if dx < -threshold || value.predictedEndTranslation.width < -width * 0.45 {
                    target = min(items.count - 1, index + 1)
                } else if dx > threshold || value.predictedEndTranslation.width > width * 0.45 {
                    target = max(0, index - 1)
                }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                    drag = .zero
                    index = target
                }
            }
    }

    /// 松手后的退出交给系统：不自己做第二段动画。
    /// （曾经试过「先甩出去 0.24s 再 dismiss」，看起来是图片和黑底分两次落下。）
}

// MARK: - 浮层

/// 顶部关闭按钮 + 页码、底部文件名 + 大小。
///
/// 单独抽成 `Equatable` 视图：外层拖动时 `ImageViewerView` 的 body 每帧重算，
/// 但只要这几项入参没变，SwiftUI 就跳过这里的 body —— `ultraThinMaterial` 毛玻璃
/// 和文字不必每帧重建。滑动时的卡顿有一截就来自这里（毛玻璃重合成的代价不小）。
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
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }

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

// MARK: - 页面容器

/// 三张页面的横向堆叠，但**位置不靠布局，靠 offset**。
///
/// 单独抽出来并实现 `Equatable`，配合 `.equatable()` 使用：外层拖动时
/// `drag` 每帧都在变、`body` 每帧都会重算，但只要这里的入参没变，
/// SwiftUI 就会跳过它的 `body`，里面的 `Image` 一帧都不重建。
///
/// 每页的 x 位移是 `(页号 - 当前页号) * 屏宽`：换页时这个值从 `±1 屏宽` 平滑过渡到 `0`，
/// 是一条纯图层变换，`withAnimation` 一定动画得出来。
/// 如果改成 `HStack` 布局 + 外层 offset 补偿，换页那一刻 `range` 会平移一格，
/// 兄弟页被增删会让布局位置**瞬间**跳一个屏宽（布局跳变无法动画），
/// 画面表现就是「图片直接闪出来」。
private struct PageStack: View, Equatable {
    let items: [FileItem]
    let range: ClosedRange<Int>
    let index: Int
    let serverID: UUID
    let connection: SMBConnection
    let width: CGFloat
    let height: CGFloat
    @Binding var isZoomed: Bool

    static func == (lhs: PageStack, rhs: PageStack) -> Bool {
        lhs.index == rhs.index
            && lhs.range == rhs.range
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.items.count == rhs.items.count
            && lhs.items.first?.id == rhs.items.first?.id
    }

    var body: some View {
        ZStack {
            ForEach(range, id: \.self) { offset in
                ZoomableImageView(
                    item: items[offset],
                    serverID: serverID,
                    connection: connection,
                    // 只加载当前这一页，相邻页等翻过去再读，避免一次把整个目录的原图全下一遍。
                    isActive: offset == index,
                    isZoomed: $isZoomed
                )
                .frame(width: width, height: height)
                .offset(x: CGFloat(offset - index) * width)
                .animation(.spring(response: 0.32, dampingFraction: 0.88), value: index)
            }
        }
        .frame(width: width, height: height)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@MainActor
struct ZoomableImageView: View {
    let item: FileItem
    let serverID: UUID
    let connection: SMBConnection
    /// 是否是当前显示的那一页（只有当前页才去读原图）
    let isActive: Bool
    /// 把放大状态报给外层：放大时外层不再处理翻页/下拉退出
    @Binding var isZoomed: Bool

    @State private var image: UIImage?
    /// 缩略图占位：网格里已经有 480px 的缩略图在内存里，先把它铺上去。
    /// 原图从 NAS 读完要几百毫秒到几秒，没有占位的话这期间是一片黑，
    /// 原图一回来又「啪」地整张出现——翻页时看着就是闪一下。
    @State private var placeholder: UIImage?
    @State private var isLoading: Bool
    @State private var failed = false

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero

    /// 缩略图在 `init` 里就取好：`.onAppear` 要等封面已经滑上来才开始跑，
    /// 那之前的一两帧只有黑底，缩略图随后「啪」地出现，同样是「点开闪一下」的来源。
    /// 放进 `State` 的初始值后，第一帧画出来就已经是缩略图。
    ///
    /// 原图同理：预热过的相邻页在内存里已经有**解码好的**预览，这里直接拿来当初值，
    /// 翻页时第一帧就是清晰原图，不会「先糊着缩略图、再啪一下换掉」。
    init(
        item: FileItem,
        serverID: UUID,
        connection: SMBConnection,
        isActive: Bool,
        isZoomed: Binding<Bool>
    ) {
        self.item = item
        self.serverID = serverID
        self.connection = connection
        self.isActive = isActive
        _isZoomed = isZoomed
        let preview = MediaStore.shared.cachedPreview(for: item, serverID: serverID)
        let cached = preview == nil
            ? ThumbnailStore.shared.cachedThumbnail(for: item, serverID: serverID)
            : nil
        _image = State(initialValue: preview)
        _placeholder = State(initialValue: cached)
        // 有图（原图或缩略图）就不转圈；都没有才安静地显示加载指示器
        _isLoading = State(initialValue: preview == nil && cached == nil)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                // 底层：缩略图，**全程保持不透明**，原图淡入时它只是被盖住。
                //
                // 不要让它跟着原图一起淡出：两层同时半透明叠在黑底上，中间那一刻
                // 合成覆盖率只有 1-(1-0.5)² = 0.75，画面会先暗一下再亮回来——
                // 慢速加载时还看不出来，缓存命中（原图几乎瞬间到达）时就是明显的「闪一下」。
                if let placeholder {
                    filled(placeholder, size: size)
                        .allowsHitTesting(false)
                }

                // 上层：原图，加载完成后淡入，盖住缩略图
                if let image {
                    filled(image, size: size)
                        .transition(.opacity)
                }

                if placeholder == nil {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else if failed {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 34, weight: .light))
                            Text("图片加载失败")
                                .font(.footnote)
                        }
                        .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            // 缩放 / 平移挂在容器上，两层图片共用同一套变换，淡入过程中不会错位
            .scaleEffect(scale)
            .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
            .contentShape(Rectangle())
            // 只有放大之后才接管拖动（未放大时的拖动归外层，用来翻页和下拉退出）
            .gesture(panGesture, including: scale > 1.01 ? .all : .none)
            .simultaneousGesture(magnificationGesture)
            .onTapGesture(count: 2) { toggleZoom() }
        }
        .task(id: isActive) {
            guard isActive else {
                // 变成前后页之后，把解码好的图放掉，降低内存峰值。
                // 但如果它正躺在解码缓存里（翻页预热留下的那张），放掉也省不到内存 ——
                // 缓存拿着同一个对象 —— 反而会让翻回来时先看到糊的缩略图。那就留着。
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                guard MediaStore.shared.cachedPreview(for: item, serverID: serverID) == nil else { return }
                if image != nil {
                    placeholder = ThumbnailStore.shared.cachedThumbnail(for: item, serverID: serverID)
                    image = nil
                }
                return
            }
            await load()
        }
    }

    private func filled(_ image: UIImage, size: CGSize) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height)
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let next = min(max(1, baseScale * value), 6)
                scale = next
                isZoomed = next > 1.01
            }
            .onEnded { _ in
                if scale <= 1.02 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scale = 1
                        baseScale = 1
                        offset = .zero
                    }
                    isZoomed = false
                } else {
                    baseScale = scale
                    isZoomed = true
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.01 else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard scale > 1.01 else {
                    dragOffset = .zero
                    return
                }
                offset.width += value.translation.width
                offset.height += value.translation.height
                dragOffset = .zero
            }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if scale > 1.01 {
                scale = 1
                baseScale = 1
                offset = .zero
                isZoomed = false
            } else {
                scale = 2.5
                baseScale = 2.5
                isZoomed = true
            }
        }
    }

    private func load() async {
        if image != nil { return }
        // 这张图在本页创建之后才被预热好（后台解码刚完成）：直接用内存里那份，
        // 不再读盘再解一遍。轻微淡入，避免和占位缩略图之间「啪」地换一张。
        if let cached = MediaStore.shared.cachedPreview(for: item, serverID: serverID) {
            withAnimation(.easeOut(duration: 0.12)) {
                image = cached
            }
            return
        }
        // 已经有缩略图铺底就不要再转圈，否则会在缩略图上盖一个加载指示器
        if placeholder == nil {
            placeholder = ThumbnailStore.shared.cachedThumbnail(for: item, serverID: serverID)
        }
        isLoading = placeholder == nil
        failed = false

        let box = CancellationBox()
        let loaded = await withTaskCancellationHandler {
            await MediaStore.shared.image(
                for: item,
                serverID: serverID,
                connection: connection,
                cancel: box
            )
        } onCancel: {
            box.cancel()
        }

        if Task.isCancelled { return }
        isLoading = false
        if let loaded {
            // 淡入盖住缩略图，而不是「啪」地整张换掉
            withAnimation(.easeOut(duration: 0.18)) {
                image = loaded
            }
            // 淡入结束后再丢掉缩略图（省内存）。这一步没有动画、原图也已完全不透明，
            // 所以看不出任何变化；如果在同一个事务里一起清掉，就会又变成两层交叉淡出。
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                placeholder = nil
            }
        } else if placeholder == nil {
            failed = true
        }
    }
}

extension View {
    /// 让 `fullScreenCover` 自带的背景透明。
    ///
    /// 系统那层底默认是不透明的黑：下拉时我们把画面缩小、背景渐隐，下面其实一直是黑的，
    /// 退出时它还会跟着一起滑下去（就是「图片下去了，黑屏又跟了一次」的来源）。
    /// 设成透明之后，下拉过程能真的看见下面的目录页，退出也只剩画面这一段运动。
    @ViewBuilder
    func clearPresentationBackground() -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(Color.clear)
        } else {
            self
        }
    }
}
