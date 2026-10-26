import AppKit
import Foundation
import SwiftUI
import CinemaCore

@main struct ViewingNeedsSmoke {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)") }
        let app = AppModel(); app.automaticQualityInspection = false; app.providers = []
        app.query = "星际穿越"; app.search()
        let deadline = Date().addingTimeInterval(3)
        while app.searching, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        check("empty_provider_search_finishes_without_network", !app.searching)
        let a = SourceProvider(id: "a", name: "片库 A", endpoint: URL(string: "https://fixture.invalid/a")!)
        let b = SourceProvider(id: "b", name: "片库 B", endpoint: URL(string: "https://fixture.invalid/b")!)
        app.providers = [a, b]
        func title(_ id: String, _ name: String, _ category: String?, provider: SourceProvider = a) -> MediaTitle {
            .init(id: id, title: name, year: "2014", posterURL: nil, summary: "", providerID: provider.id, providerName: provider.name, category: category)
        }
        let main = title("main", "星际穿越", "科幻片")
        let sameNameCommentary = title("same-name", "星际穿越", "电影解说", provider: b)
        let commentary = title("commentary", "星际穿越[电影解说]", "电影解说")
        let trailer = title("trailer", "星际穿越预告片", "预告片")
        let short = title("short", "星际穿越之总裁归来", "短剧")
        let other = title("other", "流浪地球", "科幻片")
        let unknown = title("unknown", "深海", nil)
        app.results = [commentary, short, other, main, sameNameCommentary, trailer, unknown]
        let originalGroupID = app.groups.first { $0.sources.contains(main) }!.id
        check("submitted_query_ranks_exact_work_before_derived_content", app.filteredGroups.first?.sources.contains(main) == true)
        app.query = "流浪地球"
        check("editing_search_field_does_not_reorder_existing_results", app.filteredGroups.first?.sources.contains(main) == true)
        app.filterContent = .feature
        let selectedMain = app.filteredGroups.first { $0.sources.contains(main) }
        check("content_filter_prunes_sources_without_changing_group_identity", selectedMain?.sources == [main] && selectedMain?.id == originalGroupID)
        check("unclassified_records_remain_when_hiding_derived_content", app.filteredGroups.contains { $0.sources.contains(unknown) })
        app.filterProviderID = "b"
        check("provider_and_content_filters_apply_to_same_source", app.filteredGroups.isEmpty)
        app.filterContent = .commentary; app.filterYear = "2014"
        check("provider_year_content_filters_compose", app.filteredGroups.count == 1 && app.filteredGroups[0].sources == [sameNameCommentary])
        app.catalogSort = .title; app.resetCatalogFilters()
        check("reset_filters_preserves_catalog_and_restores_default_order", app.filterContent == .all && app.filterProviderID.isEmpty && app.filterYear.isEmpty && app.catalogSort == .relevance && app.results.count == 7)
        let originalRows = app.results
        var unknownYear = main; unknownYear.year = ""
        var knownYear = sameNameCommentary; knownYear.year = "2024"
        app.watchlist = [SavedTitle(group: CatalogGrouping.groups([unknownYear])[0])]
        app.results = [unknownYear, knownYear]
        app.filterProviderID = a.id
        check("unknown_year_bookmark_matches_filtered_original_source", app.filteredGroups.first.map(app.isSaved) == true)
        app.filterProviderID = b.id
        check("unknown_year_bookmark_matches_filtered_new_year_source", app.filteredGroups.first.map(app.isSaved) == true)
        if let group = app.filteredGroups.first { app.toggleSaved(group) }
        check("filtered_bookmark_toggle_removes_instead_of_duplicating", app.watchlist.isEmpty)
        app.watchlist = []; app.results = originalRows; app.resetCatalogFilters()
        func record(_ id: String, _ episode: String, _ position: Double, _ duration: Double, title: String = "漫长的季节") -> WatchRecord {
            let metadata = MediaTitle(id: title, title: title, year: "2023", posterURL: nil, summary: "", providerID: a.id, providerName: a.name)
            return .init(id: id, title: title, episode: episode, url: URL(string: "https://fixture.invalid/\(id).mp4")!, posterURL: nil, position: position, duration: duration, mediaDetail: .init(title: metadata, lines: []))
        }
        var completed = record("latest", "第02集", 97, 100)
        let older = record("older", "第01集", 40, 100)
        let firstEpisode = Episode(id: "e1", name: older.episode, url: older.url, number: 1)
        let lastEpisode = Episode(id: "e2", name: completed.episode, url: completed.url, number: 2)
        completed.mediaDetail!.lines = [.init(id: "history-line", name: "线路", episodes: [firstEpisode, lastEpisode])]
        completed.lineID = "history-line"; completed.episodeID = "e2"
        let unknownDuration = record("unknown", "正片", 30, 0, title: "深海")
        app.history = [completed, older, unknownDuration]
        check("unfinished_latest_view_does_not_resurrect_old_episode", app.historyRecords(showAllEpisodes: false, unfinishedOnly: true) == [unknownDuration])
        check("all_episode_view_can_show_older_unfinished_record", app.historyRecords(showAllEpisodes: true, unfinishedOnly: true) == [older, unknownDuration])
        check("all_history_remains_available_and_unmodified", app.historyRecords(showAllEpisodes: true, unfinishedOnly: false) == [completed, older, unknownDuration] && app.history.count == 3)

        func snapshot<V: View>(_ view: V, name: String, size: NSSize) async throws {
            let host = NSHostingView(rootView: view); host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.setFrameOrigin(.init(x: -5000, y: -5000)); window.orderBack(nil)
            try await Task.sleep(nanoseconds: 400_000_000); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "snapshot", code: 1) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = bitmap.representation(using: .png, properties: [:])!
            try png.write(to: destination.appendingPathComponent(name + ".png")); window.close()
            check("snapshot_\(name)", png.count > 10_000)
        }
        app.query = "星际穿越"; app.filterContent = .feature
        try await snapshot(ContentView(app: app), name: "discovery-filter-1280", size: .init(width: 1280, height: 900))
        try await snapshot(ContentView(app: app), name: "discovery-filter-1040", size: .init(width: 1040, height: 760))
        app.section = .history
        try await snapshot(ContentView(app: app), name: "unfinished-history-1280", size: .init(width: 1280, height: 900))
        try await snapshot(HistoryView(app: app, unfinishedOnly: false).padding(32).background(CinemaStyle.background).foregroundStyle(CinemaStyle.primary).preferredColorScheme(.dark), name: "all-history-900", size: .init(width: 900, height: 700))
        app.showPlayer = true
        app.playback.title = "本地影片"
        app.playback.subtitleText = "每一次出发，都是为了回家。\nEvery journey begins with a reason to return."
        app.playback.subtitlesVisible = true; app.playback.subtitleFontSize = 36
        app.playback.subtitleVerticalOffset = 120; app.playback.subtitleBackgroundEnabled = true
        try await snapshot(ContentView(app: app), name: "subtitle-large-lift-1040", size: .init(width: 1040, height: 680))
        app.playback.subtitleFontSize = 22; app.playback.subtitleVerticalOffset = 0; app.playback.subtitleBackgroundEnabled = false
        try await snapshot(ContentView(app: app), name: "subtitle-no-background-1280", size: .init(width: 1280, height: 900))
        app.showPlayer = false
        app.mediaQuality.cancelAll()
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": checks, "scope": "Real AppModel with zero-provider search, offline catalog/history fixtures and native SwiftUI bitmap snapshots. Subtitle images inject plain text into actual PlayerView without a video item to check layout only. No network request, decoded-video comparison, physical mouse/keyboard or fullscreen acceptance."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("viewing-needs.json"))
        if !passed { exit(1) }
    }
}
