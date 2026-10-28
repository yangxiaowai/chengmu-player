import AppKit
import CinemaCore
import Foundation

@main
struct HistoryGroupingSmoke {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count >= 2 else { exit(2) }
        _ = NSApplication.shared
        let app = AppModel()
        var checks: [[String: Any]] = []
        func check(_ name: String, _ condition: Bool) {
            checks.append(["name": name, "passed": condition])
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        func record(_ id: String, provider: String, title: String = "同名作品", year: String = "2020",
                    category: String?, position: Double = 20, mediaID: String? = nil) -> WatchRecord {
            let url = URL(fileURLWithPath: "/tmp/chengmu-history-grouping.mp4")
            let mediaTitle = MediaTitle(id: mediaID ?? id, title: title, year: year, posterURL: nil,
                                        summary: "", providerID: provider, providerName: provider, category: category)
            let episode = Episode(id: "ep", name: "正片", url: url, number: nil)
            let line = PlaybackLine(id: "main", name: "正片", episodes: [episode])
            return WatchRecord(id: id, title: title, episode: episode.name, url: url, posterURL: nil,
                               position: position, duration: 100, mediaDetail: .init(title: mediaTitle, lines: [line]),
                               lineID: line.id, episodeID: episode.id)
        }

        let film = record("film", provider: "a", category: "电影")
        let filmAlternative = record("film-alt", provider: "b", category: "电影")
        let series = record("series", provider: "c", category: "电视剧")
        let unknown = record("unknown", provider: "d", category: nil)
        app.history = [film, filmAlternative]
        check("same_film_from_multiple_sources_is_one_work", app.latestHistory.map(\.id) == ["film"])

        app.history = [film, series]
        check("same_title_and_year_film_and_series_remain_separate", app.latestHistory.map(\.id) == ["film", "series"])

        app.history = [film, series, unknown]
        check("unknown_classification_does_not_merge_conflicting_types", app.latestHistory.map(\.id) == ["film", "series", "unknown"])

        let newer = record("newer", provider: "b", year: "2022", category: "电影")
        app.history = [film, newer]
        check("same_title_different_year_remains_separate", app.latestHistory.map(\.id) == ["film", "newer"])

        let clip = record("clip", provider: "wikimedia-commons", year: "", category: "开放短视频")
        let unknownYearFilm = record("unknown-year-film", provider: "a", year: "", category: "电影")
        app.history = [unknownYearFilm, clip]
        check("commons_short_does_not_hide_same_named_film", app.latestHistory.map(\.id) == ["unknown-year-film", "clip"])

        let finishedFilm = record("finished-film", provider: "a", category: "电影", position: 100)
        app.history = [finishedFilm, series]
        check("completed_film_does_not_hide_unfinished_series", app.historyRecords(showAllEpisodes: false, unfinishedOnly: true).map(\.id) == ["series"])

        let oldURL = URL(fileURLWithPath: "/tmp/old-episode.mp4")
        let oldA = WatchRecord(id: "old-a", title: "旧记录", episode: "正片", url: oldURL, posterURL: nil, position: 10, duration: 100)
        let oldB = WatchRecord(id: "old-b", title: "旧记录", episode: "正片", url: oldURL, posterURL: nil, position: 20, duration: 100)
        app.history = [oldA, oldB]
        check("legacy_records_without_context_remain_independently_accessible", app.latestHistory.map(\.id) == ["old-a", "old-b"])

        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": checks,
            "scope": "Headless AppModel with synthetic records; no user history, network, playback, or native UI interaction."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        exit(passed ? 0 : 1)
    }
}
