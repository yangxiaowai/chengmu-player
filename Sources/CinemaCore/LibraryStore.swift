import Foundation

public struct WatchRecord: Codable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var episode: String
    public var url: URL
    public var posterURL: URL?
    public var position: Double
    public var duration: Double
    public var updatedAt: Date
    public var mediaDetail: MediaDetail?
    public var lineID: String?
    public var episodeID: String?

    public init(id: String, title: String, episode: String, url: URL, posterURL: URL?, position: Double, duration: Double, updatedAt: Date = Date(), mediaDetail: MediaDetail? = nil, lineID: String? = nil, episodeID: String? = nil) {
        self.id = id; self.title = title; self.episode = episode; self.url = url
        self.posterURL = posterURL; self.position = position; self.duration = duration; self.updatedAt = updatedAt
        self.mediaDetail = mediaDetail; self.lineID = lineID; self.episodeID = episodeID
    }

    /// Old records can play their saved URL, but cannot invent series or episode context.
    public var playbackContext: HistoryPlaybackContext? {
        guard let detail = mediaDetail, let lineID, let episodeID,
              let line = detail.lines.first(where: { $0.id == lineID }),
              let episode = line.episodes.first(where: { $0.id == episodeID }),
              canResume(episode: episode) else { return nil }
        return HistoryPlaybackContext(detail: detail, line: line, episode: episode)
    }
    public func canResume(episode candidate: Episode) -> Bool {
        url == candidate.url && episode == candidate.name
    }
    public var progress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
}

public struct LibraryStore {
    public let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("YingChuan", isDirectory: true)
    }
    public func load() throws -> [WatchRecord] {
        let url = directory.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([WatchRecord].self, from: Data(contentsOf: url))
    }
    public func save(_ records: [WatchRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: directory.appendingPathComponent("history.json"), options: .atomic)
    }
}

public struct HistoryPlaybackContext: Equatable {
    public let detail: MediaDetail
    public let line: PlaybackLine
    public let episode: Episode
}

public enum PlaybackLinePolicy {
    public static func matchEpisode(_ current: Episode, in destination: PlaybackLine) -> Episode? {
        if let number = current.number { return destination.episodes.first { $0.number == number } }
        return destination.episodes.first { $0.name == current.name }
    }
}
