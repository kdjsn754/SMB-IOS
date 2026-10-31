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
    /// 每个媒体的真实宽高比（item.id -> width/height）。缩略图加载后回填，
    /// 用来做瀑布流布局：竖屏内容完整撑满竖条、横屏内容撑满横条，不再被压成一条。
    @State private var aspects: [String: CGFloat] = [:]

    init(server: SMBServer, path: String) {
        self.server = server
        self.path = path
        _model = StateObject(wrappedValue: BrowserModel(server: server, path: path))
    }

    private var title: String {
        path == "/" ? server.share : (path as NSString).lastPathComponent
    }

    private var currentSort: BrowserSort {
        BrowserSort(rawValue: sortRaw) ?? .name
    }

    /// 文件夹永远在前，其余按用户选择的排序方式
    private var visibleItems: [FileItem] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = keyword.isEmpty
            ? model.items
            : model.items.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
        return currentSort.sorted(base)
    }

    /// 三列等宽，顶部对齐（同一行三列顶端对齐成一条线，格子高度随内容比例变化）。
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
        .toolbar { toolbarContent }
        .task { await load() }
        .fullScreenCover(item: $overlay) { item in
            switch item {
            case .images(let request):
                ImageViewerView(
                    items: request.items,
                    startIndex: request.startIndex,
                    serverID: server.id,
                    connection: app.connection(for: server)
                )
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
                    LazyVGrid(columns: gridColumns, alignment: .top, spacing: 16) {
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
            Button {
                open(item)
            } label: {
                MediaTile(
                    item: item,
                    serverID: server.id,
                    connection: app.connection(for: server),
                    useGrid: useGrid,
                    order: order,
                    aspect: aspects[item.id] ?? TileAspect.placeholder,
                    onAspectChange: { newAspect in
                        aspects[item.id] = newAspect
                    }
                )
            }
            .buttonStyle(.plain)

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
        let connection = app.connection(for: server)
        await model.load(using: connection)
        if model.errorMessage == nil {
            app.markConnected(server)
        }
    }

    private func reload() async {
        let connection = app.connection(for: server)
        await model.refresh(using: connection)
    }

    private func open(_ item: FileItem) {
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
