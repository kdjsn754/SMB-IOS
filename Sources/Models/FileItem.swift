import Foundation

enum MediaKind: Equatable {
    case folder
    case image
    case video
    case other

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff"
    ]

    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "ts", "m2ts", "webm", "3gp", "rmvb"
    ]
}

/// 远端目录中的一项
struct FileItem: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    var id: String { path }

    var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    var kind: MediaKind {
        if isDirectory { return .folder }
        if MediaKind.imageExtensions.contains(fileExtension) { return .image }
        if MediaKind.videoExtensions.contains(fileExtension) { return .video }
        return .other
    }

    var isMedia: Bool {
        kind == .image || kind == .video
    }

    init(name: String, path: String, isDirectory: Bool, size: Int64, modified: Date?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
    }

    init?<Value>(dictionary: [URLResourceKey: Value], parentPath: String) {
        guard let name = dictionary[.nameKey] as? String, !name.isEmpty else { return nil }
        if name == "." || name == ".." { return nil }
        let parent = parentPath.hasSuffix("/") ? String(parentPath.dropLast()) : parentPath
        self.name = name
        self.path = parent.isEmpty ? "/\(name)" : "\(parent)/\(name)"

        let resourceType = dictionary[.fileResourceTypeKey] as? URLFileResourceType
        let directoryFlag = dictionary[.isDirectoryKey] as? Bool
        self.isDirectory = directoryFlag ?? (resourceType == .directory)

        if let number = dictionary[.fileSizeKey] as? NSNumber {
            self.size = number.int64Value
        } else if let value = dictionary[.fileSizeKey] as? Int64 {
            self.size = value
        } else {
            self.size = 0
        }

        self.modified = dictionary[.contentModificationDateKey] as? Date
    }
}
