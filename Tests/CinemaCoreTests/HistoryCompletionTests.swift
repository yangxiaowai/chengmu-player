import Foundation
import Testing
@testable import CinemaCore

struct HistoryCompletionTests {
    private func record(_ position: Double, _ duration: Double) -> WatchRecord {
        .init(id: "movie", title: "Movie", episode: "正片", url: URL(string: "https://example.com/movie.mp4")!, posterURL: nil, position: position, duration: duration)
    }
    @Test func completedIsAReversibleViewOfValidProgress() {
        #expect(!record(94.99, 100).isCompleted)
        #expect(record(95, 100).isCompleted)
        #expect(record(120, 100).isCompleted)
        #expect(!record(0, 100).isCompleted)
        #expect(!record(-1, 100).isCompleted)
        #expect(!record(100, 0).isCompleted)
        #expect(!record(100, -.infinity).isCompleted)
        #expect(!record(.nan, 100).isCompleted)
        #expect(!record(100, .infinity).isCompleted)
    }
    @Test func completedStatusDoesNotChangeStoredHistory() throws {
        let original = record(96, 100)
        let restored = try JSONDecoder().decode(WatchRecord.self, from: JSONEncoder().encode(original))
        #expect(restored == original)
        #expect(restored.isCompleted)
    }

    private func seriesRecord(index: Int, count: Int = 3, position: Double = 97) -> WatchRecord {
        let episodes = (1...count).map { number in
            Episode(id: "episode-\(number)", name: "第\(number)集", url: URL(string: "https://example.com/\(number).mp4")!, number: number)
        }
        let title = MediaTitle(id: "series", title: "同一部剧 第一季", year: "2026", posterURL: nil, summary: "", providerID: "p", providerName: "来源", category: "国产剧")
        let detail = MediaDetail(title: title, lines: [.init(id: "line", name: "线路", episodes: episodes)])
        let episode = episodes[index]
        return .init(id: "p:series:line:\(episode.id)", title: title.title, episode: episode.name, url: episode.url, posterURL: nil, position: position, duration: 100, mediaDetail: detail, lineID: "line", episodeID: episode.id)
    }
    @Test func finishingAnIntermediateEpisodeDoesNotCompleteTheSeries() {
        #expect(!seriesRecord(index: 0).isCompleted)
        #expect(!seriesRecord(index: 1).isCompleted)
    }
    @Test func finalEpisodeMustAlsoReachTheProgressThreshold() {
        #expect(!seriesRecord(index: 2, position: 94.99).isCompleted)
        #expect(seriesRecord(index: 2, position: 95).isCompleted)
    }
    @Test func anIncompleteLineCannotHideEpisodesAvailableOnAnotherLine() {
        var short = seriesRecord(index: 1, count: 2)
        let full = seriesRecord(index: 2).mediaDetail!.lines[0]
        short.mediaDetail!.lines.append(.init(id: "full", name: "完整线路", episodes: full.episodes))
        #expect(!short.isCompleted)
        short.mediaDetail!.lines[1].episodes = full.episodes.map { episode in
            var value = episode; value.number = nil; return value
        }
        #expect(!short.isCompleted)
    }
    @Test func unknownOrBrokenSeriesContextDoesNotClaimWholeSeriesCompletion() {
        var legacy = seriesRecord(index: 0)
        legacy.mediaDetail = nil; legacy.lineID = nil; legacy.episodeID = nil
        #expect(!legacy.isCompleted)
        legacy.title = "同一部剧"
        legacy.episode = "01"
        #expect(!legacy.isCompleted)
        var broken = seriesRecord(index: 2)
        broken.url = URL(string: "https://example.com/replaced.mp4")!
        #expect(!broken.isCompleted)
        #expect(!seriesRecord(index: 0, count: 1).isCompleted)
    }
    @Test func completedEpisodeOffersOnlyAnUnambiguousConsecutiveNextEpisode() {
        #expect(seriesRecord(index: 0).isEpisodeCompleted)
        #expect(seriesRecord(index: 0).nextEpisodeToWatch?.id == "episode-2")
        #expect(seriesRecord(index: 0, position: 40).nextEpisodeToWatch == nil)
        #expect(seriesRecord(index: 2).nextEpisodeToWatch == nil)
        var gap = seriesRecord(index: 0)
        gap.mediaDetail!.lines[0].episodes.remove(at: 1)
        #expect(gap.nextEpisodeToWatch == nil)
        gap.mediaDetail!.lines[0].episodes[0].number = nil
        gap.mediaDetail!.lines[0].episodes[1].number = nil
        gap.mediaDetail!.lines[0].episodes[0].name = "第一集"
        gap.mediaDetail!.lines[0].episodes[1].name = "第三集"
        gap.episode = "第一集"
        #expect(gap.nextEpisodeToWatch == nil)
    }
    @Test func movieContextAndOldMovieRecordsStillCompleteNormally() {
        var movie = record(97, 100)
        let metadata = MediaTitle(id: "movie", title: "电影", year: "2026", posterURL: nil, summary: "", providerID: "p", providerName: "来源", category: "剧情片")
        let episode = Episode(id: "feature", name: "正片", url: movie.url, number: nil)
        movie.mediaDetail = .init(title: metadata, lines: [.init(id: "movie-line", name: "线路", episodes: [episode])])
        movie.lineID = "movie-line"; movie.episodeID = "feature"
        #expect(movie.isCompleted)
        #expect(movie.nextEpisodeToWatch == nil)
        #expect(record(97, 100).isCompleted)
    }
}
