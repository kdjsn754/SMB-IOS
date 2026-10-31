import SwiftUI
import UIKit

@MainActor
struct ImageViewerView: View {
    let items: [FileItem]
    let serverID: UUID
    let connection: SMBConnection

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var chromeVisible = true

    init(items: [FileItem], startIndex: Int, serverID: UUID, connection: SMBConnection) {
        self.items = items
        self.serverID = serverID
        self.connection = connection
        let safeIndex = items.isEmpty ? 0 : min(max(0, startIndex), items.count - 1)
        _index = State(initialValue: safeIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    ZoomableImageView(
                        item: item,
                        serverID: serverID,
                        connection: connection,
                        // 只加载当前这一页：分页容器会把所有页都建出来，
                        // 不加限制的话打开一张图就会把整个目录的原图全下一遍。
                        isActive: offset == index
                    )
                    .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if chromeVisible {
                chrome
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!chromeVisible)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                chromeVisible.toggle()
            }
        }
    }

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
                scale = min(max(1, baseScale * value), 6)
            }
            .onEnded { _ in
                if scale <= 1.02 {
                    withAnimation(.easeOut(duration: 0.2)) {
                        scale = 1
                        baseScale = 1
                        offset = .zero
                    }
                } else {
                    baseScale = scale
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
            } else {
                scale = 2.5
                baseScale = 2.5
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
