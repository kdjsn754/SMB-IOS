import Foundation

struct ImagePreviewRequest: Identifiable {
    let id = UUID()
    let items: [FileItem]
    let startIndex: Int
}

struct VideoPlayRequest: Identifiable {
    let id = UUID()
    let item: FileItem
    /// 同目录的视频（按目录页当前排序）。播放页用它做「上一个 / 下一个」。
    var playlist: [FileItem] = []
}

enum BrowserOverlay: Identifiable {
    case images(ImagePreviewRequest)
    case video(VideoPlayRequest)

    var id: String {
        switch self {
        case .images(let request):
            return "images-\(request.id.uuidString)"
        case .video(let request):
            return "video-\(request.id.uuidString)"
        }
    }
}
