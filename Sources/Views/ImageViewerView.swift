import SwiftUI
import UIKit

/// 全屏看图。（最低系统 iOS 27，不做向下兼容 —— 2026-11-01 用户拍板：能用原生就用原生）
///
/// 分页：交给**系统原生滚动** `ScrollView(.horizontal) + .scrollTargetBehavior(.paging)`，
/// 对齐安卓版的 `HorizontalPager` —— 手指拖动由底层 UIScrollView 完成，
/// 位移 1:1、自带速度追踪/惯性/换页吸附，拖动全程不经过任何 SwiftUI 状态。
/// 之前手搓 `ZStack + 每页 offset`（哪怕拖动时只改一个数值）每帧都要走一遍
/// SwiftUI 更新管线，快速拖动时永远差一口气 —— 「不实时跟手」的根子在这。
///
/// 下拉退出**没有** UIScrollView 原生的东西可用：
/// - UIScrollView 只有「内容滚动」，没有任何「把页面关掉」的语义；
/// - `fullScreenCover` 的系统交互式关闭实测不可靠（内容层并挂着别的拖动识别器时，
///   只在部分时机认手、拖快一点就退回不认），而且它和我们页内的手势互相抢。
///   这不是 iOS 偷懒 —— 安卓版同样是自己写的下拉手势（`pointerInput` 里的
///   `verticalPull`），`HorizontalPager` 也不提供下拉关闭。
/// 所以纵向由本页自绘手势负责，`simultaneousGesture` 并挂：
/// 横向归滚动、纵向归下拉，各走各的（和安卓版同一个分工）。
@MainActor
struct ImageViewerView: View {
    let items: [FileItem]
    let serverID: UUID
    let connection: SMBConnection
    /// 目录页传进来的缩放转场命名空间。非 nil 时进出场交给系统的
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
    /// 本次拖动锁定的方向：判一次就锁住，避免斜着拖时在下拉和「放给滚动」之间来回跳
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
        _chromeVisible = State(initialValue: zoomNamespace == nil)
    }

    /// 下拉退出的进度 0…1：背景变透明、画面缩小、顶部栏淡出都跟着它
    private var pullProgress: CGFloat {
        min(1, max(0, drag.height) / 380)
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
                        // 横向翻页交给**系统原生滚动**（对齐安卓版的 `HorizontalPager`）：
                        // 手指拖动由底层 UIScrollView 原生完成 —— 位移 1:1、自带速度追踪和惯性，
                        // 拖动全程不经过任何 SwiftUI 状态，「实时跟手」由系统保证。
                        // 这里只保留纵向下拉退出，用 simultaneous 挂上，不拦横向。
                        NativePageStack(
                            items: items,
                            serverID: serverID,
                            connection: connection,
                            index: $index,
                            width: width,
                            height: height,
                            isZoomed: $isZoomed
                        )
                        .simultaneousGesture(verticalPullGesture(height: height))
                        // 纵向位移落在裁剪框「外面」：整块画面跟着手指往下走，
                        // 露出下面被遮住的目录页。（横向不再有自定义位移 —— 滚动自己管。）
                        .offset(y: drag.height)
                        .scaleEffect(1 - pullProgress * 0.14)
                        .contentShape(Rectangle())
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
        .interactiveDismissDisabled(true)
        .statusBarHidden(!chromeVisible || pullProgress > 0.05)
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

    /// **纵向下拉退出**手势（横向翻页归原生滚动，这里完全不管横向）。
    ///
    /// 用 `simultaneousGesture` 并挂而不是 `.gesture`：`.gesture` 会和滚动的 pan
    /// 抢识别，抢赢了横向就翻不动页。并挂模式下横向位移归滚动、纵向位移归这里，
    /// 各走各的 —— 和安卓版「horizontalDrag：不消费，交给 pager」同一个分工。
    private func verticalPullGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !isZoomed, !isDismissing else { return }
                let dx = value.translation.width
                let dy = value.translation.height

                // 方向只判一次：判完锁住，避免斜着拖在下拉和「放给滚动」之间来回跳。
                // 判成横向就什么都不做 —— 那次拖动整个归滚动视图。
                if dragAxis == nil {
                    guard max(abs(dx), abs(dy)) > 6 else { return }
                    dragAxis = abs(dy) > abs(dx) ? .vertical : .horizontal
                }

                if dragAxis == .vertical {
                    // 只往下跟手：往上没有退出语义。横向分量不叠加
                    // （安卓版下拉也只动 offsetY）。
                    drag = CGSize(width: 0, height: max(0, dy))
                }
            }
            .onEnded { value in
                let axis = dragAxis
                dragAxis = nil
                guard !isZoomed, !isDismissing, axis == .vertical else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        drag = .zero
                    }
                    return
                }
                let dy = value.translation.height
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
                // iOS 26+ 的系统标准关闭钮（Liquid Glass 圆钮 + xmark），
                // 替代自绘的 xmark + 毛玻璃圆底 —— 原生控件自带正确的高亮/按压反馈
                Button(role: .close, action: onClose)
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

// MARK: - 页面容器

/// 翻页容器：**SwiftUI 版的 `HorizontalPager`**（对齐安卓实现）。
///
/// `ScrollView(.horizontal) + LazyHStack + .scrollTargetBehavior(.paging)`：
/// - 页与页**紧贴连排**（安卓版没有任何缝隙逻辑），滚动位移由系统 1:1 跟手，
///   带速度追踪、惯性、换页吸附 —— 全是 UIScrollView 原生行为；
/// - 拖动全程**没有任何 SwiftUI 状态变化**（`index` 只在换页落定时更新一次），
///   也就是说不存在「每帧走一遍 SwiftUI 更新管线」这回事，跟手性由系统保证；
/// - `LazyHStack` 只物化可视页和相邻页，几百张的目录不亏内存；
/// - `scrollDisabled(isZoomed)`：放大后关掉翻页滚动，拖动归页内 pan（同安卓 `userScrollEnabled`）。
private struct NativePageStack: View {
    let items: [FileItem]
    let serverID: UUID
    let connection: SMBConnection
    /// 当前页。由滚动落定回写（换页只发生一次状态更新），不反向驱动布局。
    @Binding var index: Int
    let width: CGFloat
    let height: CGFloat
    @Binding var isZoomed: Bool

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { page in
                    ZoomableImageView(
                        item: items[page],
                        serverID: serverID,
                        connection: connection,
                        isActive: page == index,
                        isZoomed: $isZoomed
                    )
                    .equatable()
                    .frame(width: width, height: height)
                }
            }
            // 换页吸附以「整页宽」为单位，靠它把每个格子标成滚动目标
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        // 滚动落定回写 index；程序侧不改 index，所以 set 只处理非 nil
        .scrollPosition(id: Binding<Int?>(
            get: { index },
            set: { if let page = $0 { index = page } }
        ))
        .scrollDisabled(isZoomed)
        .scrollIndicators(.hidden)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 单页图片视图。
///
/// 实现 `Equatable` 配合 `.equatable()`：拖动翻页时外层每帧都在改各页的 offset，
/// 但这一页自己的入参（哪张图、是不是当前页）没变，SwiftUI 就跳过这里的 `body` ——
/// `GeometryReader`、两层 `Image`、手势修饰符一帧都不重建，拖动全程零重建。
/// （`@State` 的变化 —— 比如原图加载完成 —— 不受影响，照常刷新。）
@MainActor
struct ZoomableImageView: View, Equatable {
    let item: FileItem
    let serverID: UUID
    let connection: SMBConnection
    /// 是否是当前显示的那一页（只有当前页才去读原图）
    let isActive: Bool
    /// 把放大状态报给外层：放大时外层不再处理翻页/下拉退出
    @Binding var isZoomed: Bool

    /// 入参比较：同一张图、同一个当前页标志即可复用上一帧的视图。
    /// `isZoomed` 是绑定（内容稳定，不比较）；`serverID` / `connection`
    /// 在一次会话里不会变；`@State`（图片加载进度）不经过父视图，不受此门影响。
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item.id == rhs.item.id && lhs.isActive == rhs.isActive
    }

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
        // MagnifyGesture（iOS 17+）替代旧的 MagnificationGesture：同一套语义，
        // 值从 magnification 里取，系统未来只维护这一条 API
        MagnifyGesture()
            .onChanged { value in
                let next = min(max(1, baseScale * value.magnification), 6)
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
