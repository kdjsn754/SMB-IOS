import SwiftUI
import UIKit

/// 全屏看图。
///
/// 分页不用 `TabView(.page)`：它的翻页手势是 UIKit 内部 pan，
/// 会和外层「下拉退出」的 `DragGesture` 互相抢（要么翻不了页，要么拖不动退）。
/// 这里用 `HStack + offset` 自己算位移，一个手势同时处理「横向翻页 / 纵向下拉退出」。
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
    /// 手势过程中的实时位移
    @State private var drag: CGSize = .zero

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

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let height = max(proxy.size.height, 1)

                ZStack {
                    // 往下拖时背景逐渐透明，能看见下面被遮住的目录页，明确「松手就退出」
                    Color.black.opacity(1 - pullProgress * 0.92)

                    HStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                            ZoomableImageView(
                                item: item,
                                serverID: serverID,
                                connection: connection,
                                // 只加载当前这一页：分页容器会把所有页都建出来，
                                // 不加限制的话打开一张图就会把整个目录的原图全下一遍。
                                isActive: offset == index,
                                isZoomed: $isZoomed
                            )
                            .frame(width: width, height: height)
                        }
                    }
                    // 内层给 HStack 真实宽度，外层固定成屏幕宽度并左对齐，offset 才从左上角算起
                    .frame(width: width * CGFloat(max(items.count, 1)), alignment: .leading)
                    .frame(width: width, height: height, alignment: .leading)
                    .offset(x: -CGFloat(index) * width + drag.width, y: drag.height)
                    .scaleEffect(1 - pullProgress * 0.14)
                    .animation(.spring(response: 0.3, dampingFraction: 0.88), value: index)
                }
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .gesture(pagingGesture(width: width))
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        chromeVisible.toggle()
                    }
                }
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

    // MARK: - 手势

    private func pagingGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isZoomed else { return }
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
                guard !isZoomed else { return }
                let dx = value.translation.width
                let dy = value.translation.height

                if abs(dy) > abs(dx) {
                    // 位移超过 130pt，或者甩得够快，就退出
                    if dy > 130 || value.predictedEndTranslation.height > 320 {
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
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
