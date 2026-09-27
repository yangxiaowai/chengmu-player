import Foundation

public struct MediaTitle: Codable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var year: String
    public var posterURL: URL?
    public var summary: String
    public var providerID: String
    public var providerName: String
    public init(id: String, title: String, year: String, posterURL: URL?, summary: String, providerID: String, providerName: String) {
        self.id = id; self.title = title; self.year = year; self.posterURL = posterURL; self.summary = summary; self.providerID = providerID; self.providerName = providerName
    }
}
public struct Episode: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var url: URL
    public var number: Int?
    public init(id: String, name: String, url: URL, number: Int?) { self.id = id; self.name = name; self.url = url; self.number = number }
}
public struct PlaybackLine: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var episodes: [Episode]
    public init(id: String, name: String, episodes: [Episode]) { self.id = id; self.name = name; self.episodes = episodes }
}
public struct MediaDetail: Codable, Hashable {
    public var title: MediaTitle
    public var lines: [PlaybackLine]
    public init(title: MediaTitle, lines: [PlaybackLine]) { self.title = title; self.lines = lines }
}
public struct SourceProvider: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var endpoint: URL
    public var enabled: Bool
    public var searchAction: String?
    public init(id: String, name: String, endpoint: URL, enabled: Bool = true, searchAction: String? = nil) { self.id = id; self.name = name; self.endpoint = endpoint; self.enabled = enabled; self.searchAction = searchAction }
    public static let defaults = [
        SourceProvider(id: "dytt", name: "电影天堂目录", endpoint: URL(string: "https://caiji.dyttzyapi.com/api.php/provide/vod")!),
        SourceProvider(id: "ffzy", name: "非凡目录", endpoint: URL(string: "https://ffzy5.tv/api.php/provide/vod")!, searchAction: "detail")
    ]
}
public struct SearchResponse {
    public var titles: [MediaTitle]
    public var failures: [String]
    public init(titles: [MediaTitle], failures: [String]) { self.titles = titles; self.failures = failures }
}
public enum SourceError: LocalizedError {
    case invalidURL, invalidResponse, httpStatus(Int), responseTooLarge, emptyDetail, invalidPlaylist, playlistLoop, playlistDepth
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "仅支持有效的 HTTP/HTTPS 网络地址"
        case .invalidResponse: return "来源返回了无效的目录数据"
        case .httpStatus(let code): return "来源请求失败（HTTP \(code)）"
        case .responseTooLarge: return "来源响应超过大小上限"
        case .emptyDetail: return "未找到可用剧集线路"
        case .invalidPlaylist: return "地址未返回有效的 HLS 播放清单"
        case .playlistLoop: return "HLS 主清单循环引用"
        case .playlistDepth: return "HLS 主清单嵌套超过上限"
        }
    }
}

func networkURL(_ value: String, relativeTo base: URL? = nil) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
          let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
    return url
}
