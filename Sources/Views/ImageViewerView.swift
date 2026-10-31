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
/// 系统只给 `sheet`（pageSheet/formSheet）配交互式下滑，而 sheet 顶部会留出一条
/// 露出底层的缝、也拿不到全屏，做看图不合适。所以手势自己做，但**位移只走图层**
/// （offset / scaleEffect），并且用 `PageStack` 把图片内容按「不可变」隔离掉，
/// 拖动时不会重建页面树，手感和系统一样跟手。
@MainActor
struct ImageViewerView: View {
    let items: [FileItem]
    let serverID: UUID
    let connection: SMBConnection

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var chromeVisible = true
    /// 当前页是否处于放大状态：放大时手势交给页内的 pan（移动画面），外层不做翻页/退出
    @State private var isZoomed = false
    /// 手势过程中的实时位移（只影响图层，不触发图片内容重建）
    @State private var drag: CGSize = .zero
    /// 松手后正在收尾退出，期间忽略新手势
    @State private var isDismissing = false

    init(items: [FileItem], startIndex: Int, serverID: UUID, connection: SMBConnection) {
        self.items = items
        self.serverID = serverID
        self.connection = connection
        let safeIndex = items.isEmpty ? 0 : min(max(0, startIndex), items.count - 1)
        _index = State(initialValue: safeIndex)
    }

    /// 下拉退出的进度 0…1：背景变透明、画面缩小、顶部栏淡出都跟着它
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

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let height = max(proxy.size.height, 1)

                ZStack {
                    // 往下拖时背景逐渐透明，能看见下面被遮住的目录页，明确「松手就退出」
                    Color.black
                        .opacity(max(0, 1 - pullProgress * 1.1))
                        .ignoresSafeArea()

                    if items.isEmpty {
                        Color.clear
                    } else {
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
                        .contentShape(Rectangle())
                        .gesture(pagingGesture(width: width))
                        .onTapGesture { toggleChrome() }
                    }
                }
                .frame(width: width, height: height)
            }
            .ignoresSafeArea()

            // 浮层留在安全区内，不跟着画面全屏铺（否则按钮会压到状态栏）
            if chromeVisible && pullProgress < 0.1 {
                chrome
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(1 - pullProgress * 6)
                    .allowsHitTesting(pullProgress < 0.02)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!chromeVisible || pullProgress > 0.05)
        .onChange(of: index) { _ in
            // 换页时把上一页的放大状态清掉，否则新一页的翻页手势会被误判成「正在放大」
            isZoomed = false
        }
        .task(id: index) {
            // 翻页动画落定后，把前后两张的原图读进磁盘缓存。
            // 这样下一次左右滑是「本地直接出图」，不会先糊一片（缩略图占位）再慢慢变清晰。
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await prefetchNeighbors()
        }
    }

    /// 预热前后两页：已经缓存过的直接跳过，没缓存过的按顺序读进磁盘缓存。
    /// 用户很快又划走时任务会被取消，`CancellationBox` 会把底层 SMB 传输一起掐掉，
    /// 不会在后台白读几十兆。
    private func prefetchNeighbors() async {
        for offset in [index + 1, index - 1] {
            guard !Task.isCancelled, items.indices.contains(offset) else { continue }
            let item = items[offset]
            let url = CacheManager.shared.mediaURL(serverID: serverID, item: item, suffix: "jpg")
            if FileManager.default.fileExists(atPath: url.path) { continue }

            let box = CancellationBox()
            await withTaskCancellationHandler {
                _ = await MediaStore.shared.image(
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
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible.toggle()
        }
    }

    // MARK: - 手势

    private func pagingGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isZoomed, !isDismissing else { return }
                let dx = value.translation.width
                let dy = value.translation.height

                if abs(dy) > abs(dx) {
                    // 纵向：只在往下时跟手（往上没有退出语义，别让画面乱飘）
                    drag = CGSize(width: dx * 0.18, height: max(0, dy))
                } else {
                    // 横向：首尾页加阻尼，像系统那样拖到头有回弹感
                    var x = dx
                    if (index == 0 && dx > 0) || (index == items.count - 1 && dx < 0) {
                        x *= 0.32
                    }
                    drag = CGSize(width: x, height: 0)
                }
            }
            .onEnded { value in
                guard !isZoomed, !isDismissing else { return }
                let dx = value.translation.width
                let dy = value.translation.height

                if abs(dy) > abs(dx) {
                    // 位移超过 130pt，或者甩得够快，就退出
                    if dy > 130 || value.predictedEndTranslation.height > 320 {
                        // 退出只动一次：画面现在停在哪就留在哪，交给系统把整张全屏页
                        // 顺着滑下去（coverVertical），两段动画接力会变成
                        // 「图片先下去、黑底再跟一次」。
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

    // MARK: - 顶部/底部浮层

    private var chrome: some View {
        VStack {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Spacer()

                if items.count > 1 {
                    Text("\(index + 1) / \(items.count)")
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
                Text(items[safe: index]?.name ?? "")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let item = items[safe: index], item.size > 0 {
                    Text(Format.bytes(item.size))
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
    @State private var isLoading = false
    @State private var failed = false

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                // 底层：缩略图（有就先铺，原图淡入后淡出）
                if let placeholder {
                    filled(placeholder, size: size)
                        .opacity(image == nil ? 1 : 0)
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
        .onAppear {
            if placeholder == nil {
                placeholder = ThumbnailStore.shared.cachedThumbnail(for: item, serverID: serverID)
            }
        }
        .task(id: isActive) {
            guard isActive else { return }
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
        // 已经有缩略图铺底就不要再转圈，否则会在缩略图上盖一个加载指示器
        if placeholder == nil {
            if let cached = ThumbnailStore.shared.cachedThumbnail(for: item, serverID: serverID) {
                placeholder = cached
            } else {
                isLoading = true
            }
        }
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
