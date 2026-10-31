import SwiftUI

@MainActor
struct BrowserView: View {
    @EnvironmentObject private var app: AppModel

    let server: SMBServer
    let path: String

    @StateObject private var model: BrowserModel
    @AppStorage(SettingsKey.gridLayout) private var useGrid = true
    @State private var overlay: BrowserOverlay?

    init(server: SMBServer, path: String) {
        self.server = server
        self.path = path
        _model = StateObject(wrappedValue: BrowserModel(server: server, path: path))
    }

    private var title: String {
        path == "/" ? server.share : (path as NSString).lastPathComponent
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 6)]
    }

    var body: some View {
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
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(model.items) { item in
                        cell(for: item)
                    }
                }
                .padding(8)
            }
        } else {
            List {
                ForEach(model.items) { item in
                    cell(for: item)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func cell(for item: FileItem) -> some View {
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
                    useGrid: useGrid
                )
            }
            .buttonStyle(.plain)

        case .other:
            OtherTile(item: item, useGrid: useGrid)
        }
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
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("显示方式", selection: $useGrid) {
                    Text("网格").tag(true)
                    Text("列表").tag(false)
                }
                Divider()
                Button {
                    Task { await reload() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
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
            let images = model.items.filter { $0.kind == .image }
            guard let index = images.firstIndex(where: { $0.id == item.id }) else { return }
            overlay = .images(ImagePreviewRequest(items: images, startIndex: index))
        case .video:
            overlay = .video(VideoPlayRequest(item: item))
        case .folder, .other:
            break
        }
    }
}
