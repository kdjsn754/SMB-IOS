import SwiftUI
import UIKit

/// 全屏看图。
///
/// 分页不用 `TabView(.page)`：它的翻页手势是 UIKit 内部 pan，
/// 会和外层「下拉退出」的 `DragGesture` 互相抢（要么翻不了页，要么拖不动退）。
/// 这里用 `HStack + offset` 自己算位移，一个手势同时处理「横向翻页 / 纵向下拉退出」。
///
/// 为什么不用系统自带的下滑退出：`fullScreenCover` 的呈现方式是 `fullScreen`，
/// 系统只给 `sheet`（pageSheet/formSheet）配交互式下滑，而 sheet 顶部会留出一条
/// 露出底层的缝、也拿不到全屏，做看图不合适。所以手势自己做，但**位移只走图层**
/// （offset / scaleEffect），并且用 `PageStack` 把图片内容按「不可变”隔离掉，
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
                        // 先压成屏幕大小（内容仍是三页总宽、左对齐、不裁剪），
                        // 之后的 offset / scaleEffect 才是以「屏幕中心」为锚点的图层变换；
                        // 顺序不能反：scaleEffect 挂在宽条上会绕整条的中间缩放，画面会往一边飘。
                        .frame(width: width, height: height, alignment: .leading)
                        .offset(
                            x: -CGFloat(index - pageRange.lowerBound) * width + drag.width,
                            y: drag.height
                        )
                        .scaleEffect(1 - pullProgress * 0.14)
                        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: index)
                        .contentShape(Rectangle())
                        .gesture(pagingGesture(width: width, height: height))
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
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) {
            chromeVisible.toggle()
        }
    }

    // MARK: - 手势

    private func pagingGesture(width: CGFloat, height: CGFloat) -> some Gesture {
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
                        startDismiss(height: height)
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

    /// 松手后的退出：先把画面顺着甩出去（单独一段动画），动画走完再真正关掉，
    /// 直接 `dismiss()` 会让整个页面「啪」地消失，看起来像卡了一下。
    private func startDismiss(height: CGFloat) {
        guard !isDismissing else { return }
        isDismissing = true
        withAnimation(.easeOut(duration: 0.24)) {
            drag = CGSize(width: 0, height: max(height * 0.95, drag.height))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            dismiss()
        }
    }

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

/// 三张页面的横向堆叠。
///
/// 单独抽出来并实现 `Equatable`，配合 `.equatable()` 使用：外层拖动时
/// `drag` 每帧都在变、`body` 每帧都会重算，但只要这里的入参没变，
/// SwiftUI 就会跳过它的 `body`，里面的 `Image` 一帧都不重建。
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
        HStack(spacing: 0) {
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
            }
        }
        // 给 HStack 真实总宽度，外层再压成屏幕宽度并左对齐，offset 才能从左上角算起
        .frame(width: width * CGFloat(range.count), alignment: .leading)
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
    @State private var isLoading = false
    @State private var failed = false

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(scale)
                        .offset(x: offset.width + dragOffset.width, y: offset.height + dragOffset.height)
                        // 只有放大之后才接管拖动（未放大时的拖动归外层，用来翻页和下拉退出）
                        .gesture(panGesture, including: scale > 1.01 ? .all : .none)
                        .simultaneousGesture(magnificationGesture)
                        .onTapGesture(count: 2) { toggleZoom() }
                } else if isLoading {
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
                } else {
                    Color.clear
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: isActive) {
            guard isActive else { return }
            await load()
        }
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
        isLoading = true
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
            image = loaded
        } else {
            failed = true
        }
    }
}
