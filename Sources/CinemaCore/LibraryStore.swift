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
    /// Completion of this media item, independently of its place in a series.
    public var isEpisodeCompleted: Bool {
        duration.isFinite && duration > 0 && position.isFinite && position >= duration * 0.95
    }
    /// Completion of the saved work/season, not merely the episode most recently watched.
    /// This uses the known catalog, not a claim that an airing series has officially ended.
    public var isCompleted: Bool {
        guard isEpisodeCompleted else { return false }
        guard let context = playbackContext else {
            // Old direct-file/movie records remain useful. A missing or broken series
            // context must never turn one finished episode into a completed season.
            return mediaDetail == nil && Int(episode.trimmingCharacters(in: .whitespacesAndNewlines)) == nil && !Self.hasEpisodeLabel(episode) && !Self.hasEpisodeLabel(title)
        }
        let episodes = context.line.episodes
        guard episodes.last?.id == context.episode.id else { return false }
        let category = context.detail.title.category ?? ""
        let episodicCategory = category.hasSuffix("剧") || category.contains("电视剧") || category.contains("连续剧") || category.contains("动漫") || category.contains("综艺")
        if episodes.count == 1, episodicCategory || Self.hasEpisodeLabel(context.episode.name) { return false }
        // A truncated selected line must not hide later episodes on another line.
        if context.detail.lines.contains(where: { $0.episodes.count > episodes.count }) { return false }
        if let number = context.episode.number, episodes.count > 1 {
            if context.detail.lines.contains(where: { $0.episodes.contains { ($0.number ?? 0) > number } }) { return false }
        }
        return true
    }
    /// Only offer a known next item after this episode finished; do not skip numbered gaps.
    public var nextEpisodeToWatch: Episode? {
        guard isEpisodeCompleted, let context = playbackContext,
              let index = context.line.episodes.firstIndex(where: { $0.id == context.episode.id }),
              context.line.episodes.indices.contains(index + 1) else { return nil }
        let next = context.line.episodes[index + 1]
        switch (context.episode.number, next.number) {
        case let (current?, number?) where current >= 0 && current < Int.max && number == current + 1: return next
        default: return nil
        }
    }
    private static func hasEpisodeLabel(_ value: String) -> Bool {
        value.range(of: "第\\s*[0-9一二三四五六七八九十百零两]+\\s*[集话期季]|(?i)\\b(?:s\\d+\\s*)?e(?:p)?\\s*\\d+\\b", options: .regularExpression) != nil
    }
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
