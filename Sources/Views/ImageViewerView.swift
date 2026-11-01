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
/// 下拉退出：**全归系统**。
///
/// 缩放转场自带原生交互式关闭（见 `ZoomTransition.swift`：单指下滑 / 双指捏合，
/// 松手顺着缩回原格子 —— 照片 App 就是这一套）。之前把自绘下拉手势和它并挂，
/// 两边抢识别导致系统那条「时灵时不灵」，于是索性 `interactiveDismissDisabled`
/// 关掉系统、全部自绘 —— 但自绘每帧写 `@State` 走 SwiftUI 更新管线，
/// 松手后画面还要交接给系统转场，两段式衔接怎么看都不如系统一条龙顺滑。
/// 1.3.14 横向翻页归了原生滚动之后，内容层已经没有任何纵向手势竞争者，
/// 系统交互式关闭可以完全放开了：整条自绘下拉删除，位移/回弹/缩回格子
/// 全是 UIScrollView + 转场层的原生行为，跟手性和流畅度由系统保证。
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
    /// 当前页是否处于放大状态：放大时拖动归页内 pan（移动画面），外层滚动已 `scrollDisabled`
    @State private var isZoomed = false

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

                ZStack {
                    if items.isEmpty {
                        Color.clear
                    } else {
                        // 横向翻页交给**系统原生滚动**（对齐安卓版的 `HorizontalPager`）：
                        // 手指拖动由底层 UIScrollView 原生完成 —— 位移 1:1、自带速度追踪和惯性，
                        // 拖动全程不经过任何 SwiftUI 状态，「实时跟手」由系统保证。
                        // 纵向下拉退出同样全归系统（缩放转场的原生交互式关闭）：
                        // 本页不再挂任何纵向手势，横向/纵向各归各的原生机制。
                        NativePageStack(
                            items: items,
                            serverID: serverID,
                            connection: connection,
                            index: $index,
                            width: width,
                            height: height,
                            isZoomed: $isZoomed
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { toggleChrome() }
                    }
                }
                .frame(width: width, height: height)
            }
            // 注意：这里**不要** ignoresSafeArea。width/height 就是页面的尺寸，
            // 必须和 ScrollView 的安全区视口一致（页面遵守安全区，见 NativePageStack）；
            // 曾经全屏扩展过，932 高的页面塞进 840 高的视口里垂直溢出，图片能顶到状态栏。

            // 浮层留在安全区内，不跟着画面全屏铺（否则按钮会压到状态栏）
            if chromeVisible {
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
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        // 下滑退出交给系统的交互式关闭（缩放转场原生手势）：不要 disable。
        // 历史教训：之前在这里 disable 掉系统、换自绘手势，是因为当时自绘翻页
        // 手势和系统抢识别；1.3.14 翻页归原生滚动后已无竞争者，系统的
        // 下滑/捏合关闭（松手缩回原格子，照片 App 同款）是最顺滑的一条路。
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
            // 换页时把上一页的放大状态清掉，否则新一页的翻页手势会被误判成「正在放大」。
            //
            // 这里曾经还会回写目录页的 `zoomedItemID`，但那会让**整个目录页**
            // （`LazyVGrid` 里全部格子 + 缩略图）在每一页切换时重算一遍，
            // 正好压翻页动画的时间段上，是「左右滑动很卡顿」的一部分。
            // 缩放转场的终点 id 现在由看图页内部按 `index` 算，不再需要那次回写。
            isZoomed = false
            // 翻页会让系统把「捏合退出」识别器重新挂上（1.3.33 的必现 bug：
            // 刚切到新图就捏合必定退出）。滚动落定这一拍立刻清一遍，
            // 不等 100 ms 轮询的下一拍。
            PinchDismissGuard.shared.enforce()
        }
        .task(id: index) {
            // 翻页动画落定后，把前后两张解码好放进内存预览缓存。
            // 这样下一次左右滑是「已经解码完毕」，滑过去第一帧就是清晰原图。
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
        // 页面遵守安全区（不要 ignoresSafeArea）：用户明确要求图片**不要贴到物理屏幕边** ——
        // 页面顶到底都停在安全区内，状态栏/Home 指示条区域保持黑底；放大平移的钳制按页面算，
        // 图片边缘最多到安全区边界，永远不会顶进状态栏或 Home 条底下。
        // （1.3.22 曾为了对齐照片 App 改成全出血，用户实测否掉 —— 需求本体是「别顶到状态栏」。）
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

    /// 捏合起点快照：两指中点（锚点）、起始 offset / scale。整个捏合手势期间不变。
    /// 锚点缩放（照片 App 的手感）：**捏哪儿，哪儿不动** —— 之前锚死视图中心，
    /// 无论捏哪里图像都朝上下对称膨胀，顶部一路顶进状态栏区。
    @State private var pinchAnchor: CGPoint?
    @State private var pinchBaseOffset: CGSize = .zero
    @State private var pinchBaseScale: CGFloat = 1

    /// 缩略图在 `init` 里就取好：`.onAppear` 要等封面已经滑上来才开始跑，
    /// 那之前的一两帧只有黑底，缩略图随后「啪」地出现，同样是「点开闪一下」的来源。
    /// 放进 `State` 的初始值后，第一帧画出来就已经是缩略图。
    ///
    /// 原图：刚看过的那张在内存里还有解码好的原图（`MediaStore` 缓存），直接拿来当初值；
    /// 没有的话显示缩略图铺底，原图在后台解码完淡入（1.3.24 起解码的就是全分辨率原图，无分级）。
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
            // 实际显示的那张图（原图 > 缩略图）。
            // 平移钳制必须按**它的真实渲染尺寸**算：图片是 scaledToFit 进容器的，
            // 横图/竖图总有一个方向没铺满容器，按容器算可拖距离会远超图片实际大小。
            let displaySize = (image ?? placeholder)?.size

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

                // 上层：原图（全分辨率，无分级），加载完成后淡入，盖住缩略图
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
            .gesture(panGesture(size: size, imageSize: displaySize), including: scale > 1.01 ? .all : .none)
            .simultaneousGesture(magnificationGesture(size: size, imageSize: displaySize))
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                toggleZoom(at: location, size: size, imageSize: displaySize)
            }
        }
        .task(id: isActive) {
            guard isActive else {
                // 变成前后页之后，把解码好的原图放掉，降低内存峰值（全分辨率位图很重）。
                // 但如果它正躺在解码缓存里（刚看过的那张），放掉也省不到内存 ——
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

    /// 双指缩放。
    /// - 中途缩小时用 `clamped` 收紧 offset，保证画面始终盖住屏幕（不会有边缘露黑）。
    /// 双指缩放（照片 App 的锚点手感）。
    /// - 捏合中点下的图像内容**保持原地**：offset 由锚点补偿公式闭式算出，
    ///   每帧都从起点状态重算（不是增量累加），锚点不会漂；
    /// - 图像盖满屏幕后继续捏，边界钳制接管（边贴住屏幕边，锚点让位）—— 同照片 App；
    /// - 缩到 1x 时归零（显示的本来就是原图，没有要释放的分层帧）。
    private func magnificationGesture(size: CGSize, imageSize: CGSize?) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchAnchor == nil {
                    pinchAnchor = CGPoint(x: value.startAnchor.x * size.width,
                                          y: value.startAnchor.y * size.height)
                    pinchBaseOffset = offset
                    pinchBaseScale = baseScale
                    // 捏合一发力就把系统那条「捏合退出」再清一遍：
                    // 它可能是在轮询的间隙才挂上的，等它够到退出阈值就被关页了
                    PinchDismissGuard.shared.enforce()
                }
                guard let anchor = pinchAnchor else { return }
                let next = min(max(1, pinchBaseScale * value.magnification), 6)
                // 锚点补偿：屏幕位置 = center + (内容点 - center)×s + offset，
                // 要求锚点处的内容点钉在锚点的屏幕位置上，解出 offset：
                // offset = u - (u - offset0)×(s/s0)，u = 锚点 - center
                let ux = anchor.x - size.width / 2
                let uy = anchor.y - size.height / 2
                let ratio = next / max(pinchBaseScale, 0.001)
                let compensated = CGSize(
                    width: ux - (ux - pinchBaseOffset.width) * ratio,
                    height: uy - (uy - pinchBaseOffset.height) * ratio
                )
                scale = next
                offset = Self.clamped(compensated, scale: next, container: size, imageSize: imageSize)
                isZoomed = next > 1.01
            }
            .onEnded { _ in
                pinchAnchor = nil
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

    /// 放大状态下拖动画面。
    ///
    /// 钳制规则（对齐苹果照片）：
    /// - 上限 = 缩放后**图片实际渲染尺寸**超出容器的部分的一半 —— 画面边缘永远不离开屏幕；
    /// - 按**累计位置**（offset + 本次位移）钳制，而不是按本次位移单独钳：
    ///   增量单独钳的话，offset 已在边界时画面能冲到两倍边界、松手再弹回 ——
    ///   上一版「放大后还能拖出屏幕」就是这两个洞叠加（洞一：按容器算上限，
    ///   没铺满容器的方向（黑边方向）可拖距离远超图片实际大小；洞二：本条）。
    private func panGesture(size: CGSize, imageSize: CGSize?) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.01 else { return }
                let total = CGSize(
                    width: offset.width + value.translation.width,
                    height: offset.height + value.translation.height
                )
                let clampedTotal = Self.clamped(total, scale: scale, container: size, imageSize: imageSize)
                dragOffset = CGSize(width: clampedTotal.width - offset.width,
                                    height: clampedTotal.height - offset.height)
            }
            .onEnded { value in
                guard scale > 1.01 else {
                    dragOffset = .zero
                    return
                }
                let total = CGSize(
                    width: offset.width + value.translation.width,
                    height: offset.height + value.translation.height
                )
                offset = Self.clamped(total, scale: scale, container: size, imageSize: imageSize)
                dragOffset = .zero
            }
    }

    /// 平移上限：`max(0, (图片渲染尺寸 × 倍率 - 容器) / 2)`，按轴独立。
    /// - 图片某方向没铺满容器（黑边方向）：该方向上限为 0，图片不离开屏幕中央；
    /// - 没有图（极端情况）：退回按容器估算。
    private static func clamped(_ value: CGSize, scale s: CGFloat, container: CGSize, imageSize: CGSize?) -> CGSize {
        var maxX = max(0, (s - 1) * container.width / 2)
        var maxY = max(0, (s - 1) * container.height / 2)
        if let img = imageSize, img.width > 1, img.height > 1 {
            let fit = min(container.width / img.width, container.height / img.height)
            maxX = max(0, (img.width * fit * s - container.width) / 2)
            maxY = max(0, (img.height * fit * s - container.height) / 2)
        }
        return CGSize(
            width: min(max(value.width, -maxX), maxX),
            height: min(max(value.height, -maxY), maxY)
        )
    }

    /// 双击放大/还原。放大时以**双击点为锚**到 2.5×：点哪儿，哪儿不动（照片 App 手感）；
    /// 点在角落时图像盖满屏幕后被边界钳住，锚点让位给边界。
    private func toggleZoom(at location: CGPoint, size: CGSize, imageSize: CGSize?) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if scale > 1.01 {
                scale = 1
                baseScale = 1
                offset = .zero
                isZoomed = false
            } else {
                let ux = location.x - size.width / 2
                let uy = location.y - size.height / 2
                offset = Self.clamped(
                    CGSize(width: ux - ux * 2.5, height: uy - uy * 2.5),
                    scale: 2.5, container: size, imageSize: imageSize
                )
                scale = 2.5
                baseScale = 2.5
                isZoomed = true
            }
        }
    }

    private func load() async {
        if image != nil { return }
        // 这张图在本页创建之后才被预热好（磁盘副本刚落好）：走 `image(for:)` 现解原图，
        // 缓存命中或后台解码完成后淡入，避免和占位缩略图之间「啪」地换一张。
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
