import SwiftUI

@MainActor
struct ThumbnailSettingsView: View {
    @ObservedObject private var diagnostics = ThumbnailDiagnostics.shared

    @AppStorage(SettingsKey.thumbnailsEnabled) private var thumbnailsEnabled: Bool = true
    @AppStorage(SettingsKey.videoThumbnails) private var videoThumbnails: Bool = true

    @State private var toast: String?

    var body: some View {
        SettingsDetail(title: "缩略图") {
            Section {
                Toggle("图片缩略图", isOn: $thumbnailsEnabled)
                Toggle("视频封面", isOn: $videoThumbnails)
                    .disabled(!thumbnailsEnabled)
            }

            Section {
                Button("重新加载失败的缩略图") {
                    ThumbnailStore.shared.resetFailures()
                    toast = "已重新排队"
                }

                NavigationLink {
                    ThumbnailFailureListView()
                } label: {
                    HStack {
                        Text("加载失败记录")
                        Spacer()
                        Text("\(diagnostics.entries.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toast($toast)
    }
}

/// 失败记录单独一页：列表长了也不会把设置页顶开
@MainActor
struct ThumbnailFailureListView: View {
    @ObservedObject private var diagnostics = ThumbnailDiagnostics.shared

    var body: some View {
        Group {
            if diagnostics.entries.isEmpty {
                ContentUnavailableViewCompat(title: "没有失败记录")
            } else {
                List {
                    ForEach(diagnostics.entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(entry.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .navigationTitle("加载失败记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !diagnostics.entries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清除", role: .destructive) {
                        diagnostics.clear()
                    }
                }
            }
        }
    }
}

/// iOS 16 没有 ContentUnavailableView（17+ 才有），这里做个等价占位
struct ContentUnavailableViewCompat: View {
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
