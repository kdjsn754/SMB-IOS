import Foundation

/// 一台已保存的 SMB 服务器配置
struct SMBServer: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 445
    var share: String = ""
    var domain: String = ""
    var username: String = "guest"
    var lastConnected: Date?

    /// AMSMB2 只接受 smb://host[:port] 形式，共享名需要单独传入
    var baseURL: URL? {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        if port > 0, port != 445 {
            components.port = port
        }
        return components.url
    }

    var displayName: String {
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(host) · \(share)"
        }
        return name
    }

    var address: String {
        let hostPart = port == 445 || port == 0 ? host : "\(host):\(port)"
        return "\(hostPart)/\(share)"
    }

    var isValid: Bool {
        !host.isEmpty && !share.isEmpty
    }

    /// 允许用户直接粘贴 smb://192.168.1.10/Video 或 192.168.1.10:1445 这类地址
    static func normalize(host input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("smb://") {
            text = String(text.dropFirst("smb://".count))
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[text.startIndex..<slash])
        }
        if let colon = text.lastIndex(of: ":"),
           text.filter({ $0 == ":" }).count == 1,
           Int(text[text.index(after: colon)...]) != nil {
            text = String(text[text.startIndex..<colon])
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// 从用户输入的地址里猜端口，例如 192.168.1.10:1445
    static func embeddedPort(_ input: String) -> Int? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("smb://") {
            text = String(text.dropFirst("smb://".count))
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[text.startIndex..<slash])
        }
        guard let colon = text.lastIndex(of: ":"),
              text.filter({ $0 == ":" }).count == 1 else { return nil }
        return Int(text[text.index(after: colon)...])
    }
}
