import SwiftUI

@MainActor
struct BrowserView: View {
    @EnvironmentObject private var app: AppModel

    let server: SMBServer
    let path: String

    @StateObject private var model: BrowserModel
    @AppStorage(SettingsKey.gridLayout) private var useGrid = true
    @AppStorage(SettingsKey.sortOrder) private var sortRaw = BrowserSort.name.rawValue
    @State private var overlay: BrowserOverlay?
    @State private var showSearch = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// 整目录缩略图预载：进目录后把文件夹里**所有**媒体文件的缩略图都拉完（含屏幕外的），
    /// 只在离开目录 / 刷新 / 换排序时取消重建。屏幕上格子的请求通过优先级层插到它前面。
    @State private var thumbnailPrefetch: Task<Void, Never>?
    /// 看图的缩放转场命名空间：缩略图（起点）与全屏页（终点）共用同一个命名空间才配得上
    @Namespace private var zoomNamespace

    init(server: SMBServer, path: String) {
        self.server = server
        self.path = path
        _model = StateObject(wrappedValue: BrowserModel(server: server, path: path))
    }

    /// 排序 + 搜索之后的结果缓存（引用类型，不参与 SwiftUI 观察）
    @State private var listCache = DisplayListCache()

    private var title: String {
        path == "/" ? server.share : (path as NSString).lastPathComponent
    }

    private var currentSort: BrowserSort {
        BrowserSort(rawValue: sortRaw) ?? .name
    }

    /// 当前排序 + 搜索之后的列表。
    ///
    /// **结果带缓存**：`body` 里要读它三次（网格 / 列表 / 预载），而点一下格子、
    /// `overlay` 一翻就会让整页重算。每次重排几百项（`localizedStandardCompare`
    /// 是代价最高的一类比较）正好压在「点开文件」那一帧的转场上，掉帧就掉在这里。
    /// 缓存键 = 目录代次 + 排序方式 + 关键词，三者都不变就直接复用上次的数组。
    private var visibleItems: [FileItem] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "\(model.revision)|\(sortRaw)|\(keyword)"
        return listCache.value(for: key) {
            let base = keyword.isEmpty
                ? model.items
                : model.items.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
            return currentSort.sorted(base)
        }
    }

    /// 三列等宽、列内顶部对齐。每个格子的缩略图展示框高度固定（见 `TileAspect.box`），
    /// 所以同一行三列的图片顶端成一条线、下面的文字也齐平。
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showSearch {
                searchBar
            }

            Group {
                if model.isLoading && model.items.isEmpty {
                    ProgressView("正在读取目录…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let message = model.errorMessage, model.items.isEmpty {
                    errorState(message)
                } else if model.items.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // 首页把导航栏藏了（自己做标题），这里必须显式显示，否则没有返回按钮
        .toolbar(.visible, for: .navigationBar)
        .toolbar { toolbarContent }
        .task { await load() }
        // 操作轨迹：只记「离开这一页」这一个点，够用来判断进程消失时人在哪一层
        .onDisappear {
            DiagnosticsStore.shared.note("离开目录 \(title)")
            // 离开目录就停掉整目录预载，别在后台白拉别的文件夹
            thumbnailPrefetch?.cancel()
        }
        .onChange(of: useGrid) { grid in
            DiagnosticsStore.shared.note(grid ? "切换网格视图" : "切换列表视图")
        }
        .onChange(of: sortRaw) { _ in
            DiagnosticsStore.shared.note("切换排序 \(currentSort.title)")
            // 换排序 = 显示顺序变了：按新顺序重排预载优先级（已缓存的会在 store 里秒回）
            startThumbnailPrefetch()
        }
        .fullScreenCover(item: $overlay, onDismiss: {
            // 退出动画收尾时手指已经回到格子上，这一下别让它变成「又点开一张图」。
            //
            // 这里**不能**写 `@State`：退出看图那一刻整页正在从转场里恢复，
            // 任何一个 `@State` 变化都会让 `BrowserView` 的 body 连同 `LazyVGrid`
            // 里所有可见格子重算一遍，正好压在系统恢复手势的时间点上 ——
            // 用户感受到的就是「退出后要等一下才能右滑返回」。
            // 所以时间戳存在 model 上（普通属性，不是 `@Published`，不触发刷新）。
            model.noteViewerDismissed()
            // 顺带把「右滑返回」立刻恢复：模态呈现期间系统会把它关掉，退出后要等半秒才认手
            // （用户 1.3.4 实测：这段时间里滚动、点文件夹都正常，只有 pop 手势没反应）。
            // 见 `PopGestureEnabler`。
            PopGestureEnabler.enableAfterModalDismiss()
            // 看图时停掉的整目录缩略图预载，等退出转场结束再接回去。
            // 延时 0.4 秒：退出缩回格子那几十帧里不要有任何后台读取抢 SMB / CPU。
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard overlay == nil else { return }
                startThumbnailPrefetch()
            }
        }) { item in
            switch item {
            case .images(let request):
                ImageViewerView(
                    items: request.items,
                    startIndex: request.startIndex,
                    serverID: server.id,
                    connection: app.connection(for: server),
                    zoomNamespace: zoomNamespace
                )
                // 缩放转场的终点（`.zoomDestination`）挪进了 `ImageViewerView` 自己身上：
                // 那里的 id 由页内 `index` 直接算出，不受这里 `@State` 传播时序影响。
                // 透传背景（`clearPresentationBackground`）也一起搬过去了，保持那条链的顺序。
            case .video(let request):
                VideoPlayerView(
                    item: request.item,
                    serverID: server.id,
                    connection: app.connection(for: server)
                )
            }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if useGrid {
            ScrollView {
                if visibleItems.isEmpty {
                    noMatchState
                } else {
                    LazyVGrid(columns: gridColumns, alignment: .center, spacing: 16) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            cell(for: item, order: index)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
            }
        } else {
            List {
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    cell(for: item, order: index)
                        .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .overlay {
                if visibleItems.isEmpty {
                    noMatchState
                }
            }
        }
    }

    @ViewBuilder
    private func cell(for item: FileItem, order: Int) -> some View {
        switch item.kind {
        case .folder:
            NavigationLink {
                BrowserView(server: server, path: item.path)
            } label: {
                FolderTile(item: item, useGrid: useGrid)
            }
            .buttonStyle(.plain)

        case .image, .video:
            // 不用 `Button`：它在滚动容器里会把「横向拖动但没滚动」也判成点击，
            // 于是「右滑返回」很容易变成「把这张图点开」。
            // 也不用自己写的拖动识别器（1.3.3 试过，会把整页的滚动和右滑返回一起吞掉），
            // 只留系统点击：它自带 ~10pt 位移容差，真滑动不会触发。见 `TileTap`。
            MediaTile(
                item: item,
                serverID: server.id,
                connection: app.connection(for: server),
                useGrid: useGrid,
                order: order,
                zoomNamespace: zoomNamespace
            )
            .tileTap { open(item) }
            .accessibilityAddTraits(.isButton)

        case .other:
            OtherTile(item: item, useGrid: useGrid)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索当前文件夹", text: $query)
                .font(.system(size: 15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private var noMatchState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(query.isEmpty ? "没有可显示的项目" : "没有找到「\(query)」")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("这个文件夹是空的")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            Button("重试") {
                Task { await reload() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                DiagnosticsStore.shared.note(showSearch ? "关闭搜索" : "打开搜索")
                withAnimation(.easeInOut(duration: 0.18)) {
                    showSearch.toggle()
                    if showSearch {
                        searchFocused = true
                    } else {
                        query = ""
                    }
                }
            } label: {
                Image(systemName: showSearch ? "xmark" : "magnifyingglass")
            }

            Menu {
                Picker("排序方式", selection: $sortRaw) {
                    ForEach(BrowserSort.allCases) { option in
                        Label(option.title, systemImage: option.icon).tag(option.rawValue)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }

            Menu {
                Picker("显示方式", selection: $useGrid) {
                    Text("网格视图").tag(true)
                    Text("列表视图").tag(false)
                }
                Divider()
                Button {
                    Task { await reload() }
                } label: {
                    Label("刷新目录", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - 行为

    private func load() async {
        // 记一步轨迹：万一「点导航栏就退出」再次出现，能对上最后一步在做什么
        DiagnosticsStore.shared.note("读取目录 \(path)")
        let connection = app.connection(for: server)
        await model.load(using: connection)
        if model.errorMessage == nil {
            app.markConnected(server)
            // 目录读完了：把整个文件夹的缩略图都排进队列（含屏幕外的），
            // 屏幕上的格子有自己的前台请求，永远排在预载前面
            startThumbnailPrefetch()
        }
    }

    private func reload() async {
        DiagnosticsStore.shared.note("刷新目录 \(path)")
        let connection = app.connection(for: server)
        await model.refresh(using: connection)
        if model.errorMessage == nil {
            startThumbnailPrefetch()
        }
    }

    /// 整目录缩略图预载：按当前排序把文件夹里所有媒体文件过一遍。
    ///
    /// - 已在内存/磁盘缓存里的在 `ThumbnailStore` 内部秒回（磁盘命中不进闸门、零流量）；
    /// - 需要远端读取的以**后台优先级**进闸门：屏幕上格子的前台请求随时插队；
    /// - 排序用 `model.items` 而不是 `visibleItems`：搜索过滤时预载范围不变，
    ///   依旧是整个文件夹（用户要求「当前打开目录内的都加载完」）；
    /// - 离开目录 / 刷新 / 换排序时任务被取消，`CancellationBox` 连底层 SMB 传输一起掐断。
    private func startThumbnailPrefetch() {
        thumbnailPrefetch?.cancel()
        let connection = app.connection(for: server)
        let serverID = server.id
        let items = currentSort.sorted(model.items)
        thumbnailPrefetch = Task {
            for (index, item) in items.enumerated() {
                if Task.isCancelled { return }
                _ = await ThumbnailStore.shared.thumbnail(
                    for: item,
                    serverID: serverID,
                    connection: connection,
                    order: index,
                    isPrefetch: true
                )
            }
        }
    }

    private func open(_ item: FileItem) {
        // 刚退出全屏看图的一小段时间内不认点击（见 `BrowserModel.noteViewerDismissed`）
        guard model.canOpenViewer else { return }

        // 点开文件之前先把「整目录缩略图预载」停掉。
        // `SMBConnection` 是 actor，同一时刻只跑一个读请求：预载还在逐个拉几十个文件的
        // 封面时，刚点开的这张原图只能排在它们后面 —— 转场已经把缩略图放大到全屏了，
        // 原图却还在队尾等，用户看到的就是「点开之后要糊一会儿才清晰」。
        // 退出看图时再重启（见 `fullScreenCover` 的 `onDismiss`）。
        thumbnailPrefetch?.cancel()
        thumbnailPrefetch = nil

        switch item.kind {
        case .image:
            let images = visibleItems.filter { $0.kind == .image }
            guard let index = images.firstIndex(where: { $0.id == item.id }) else { return }
            overlay = .images(ImagePreviewRequest(items: images, startIndex: index))
        case .video:
            overlay = .video(VideoPlayRequest(item: item))
        case .folder, .other:
            break
        }
    }
}

/// 目录列表「排序 + 搜索」的结果缓存。
///
/// 故意做成引用类型而不是 `@State` 值：只在 `visibleItems` 计算属性里读，
/// 不参与 SwiftUI 的依赖追踪；键没变就是一个数组引用直接返回，零重排。
@MainActor
private final class DisplayListCache {
    private var key: String?
    private var items: [FileItem] = []

    func value(for key: String, build: () -> [FileItem]) -> [FileItem] {
        if key == self.key { return items }
        let built = build()
        self.key = key
        self.items = built
        return built
    }
}
