import AppKit
import SwiftUI
import CinemaCore

@main struct QualityDiscoverySmoke {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let app = AppModel()
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)") }
        func wait() async throws {
            let deadline = Date().addingTimeInterval(6)
            while (app.mediaQuality.readingCount > 0 || app.mediaQuality.queuedCount > 0), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            check("queue_finishes", app.mediaQuality.readingCount == 0 && app.mediaQuality.queuedCount == 0)
        }
        let providers = [SourceProvider(id: "demo-a", name: "演示来源 A", endpoint: URL(string: "https://fixture.invalid/a")!, enabled: true),
                         SourceProvider(id: "demo-b", name: "演示来源 B", endpoint: URL(string: "https://fixture.invalid/b")!, enabled: true)]
        app.providers = providers
        let films = [("星际穿越", "2014"), ("流浪地球2", "2023"), ("漫长的季节", "2023"), ("庆余年第二季", "2024"), ("怪奇物语第一季", "2016"), ("绝命毒师第一季", "2008"), ("火线第一季", "2002"), ("盗梦空间", "2010"), ("琅琊榜", "2015")]
        func poster(_ index: Int) -> URL? {
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/catalog-preview-artwork/\(index).jpg")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let summaries = ["一群探险者穿越虫洞，寻找人类的未来。在浩瀚星海间，一次跨越时间与距离的告别，也成为回家的约定。", "太阳危机降临，人类携手寻找新的家园。", "几位旧友在漫长岁月里重逢，一段往事逐渐浮现。"]
        var titles = films.enumerated().map { index, value in
            MediaTitle(id: "\(index)", title: value.0, year: value.1, posterURL: poster(index), summary: summaries[index % summaries.count], providerID: "demo-a", providerName: "演示来源 A")
        }
        titles.append(MediaTitle(id: "wide", title: "星际穿越", year: "2014", posterURL: poster(0), summary: titles[0].summary, providerID: "demo-b", providerName: "演示来源 B"))
        titles.append(MediaTitle(id: "unknown", title: "海边的曼彻斯特", year: "2016", posterURL: nil, summary: "一段回乡之旅，重新面对生活与亲情。", providerID: "demo-a", providerName: "演示来源 A"))
        func fixtureDetail(_ title: MediaTitle) -> MediaDetail {
            let movie = ["0", "1", "7", "wide"].contains(title.id)
            return .init(title: title, lines: [.init(id: "main", name: "主线路", episodes: (1...(movie ? 1 : 12)).map { .init(id: String($0), name: movie ? "正片" : "第\(String(format: "%02d", $0))集", url: URL(string: "https://fixture.invalid/media/\(title.id).mp4")!, number: $0) }),
                                       .init(id: "backup", name: "备用线路", episodes: [.init(id: "1", name: movie ? "正片" : "第01集", url: URL(string: "https://fixture.invalid/media/backup-\(title.id).mp4")!, number: 1)])])
        }
        var inspections = 0
        app.mediaQuality.loadDetail = { title, _ in fixtureDetail(title) }
        app.mediaQuality.measureResponse = { _ in .init(milliseconds: 180) }
        app.mediaQuality.inspect = { url in
            inspections += 1
            try await Task.sleep(nanoseconds: 20_000_000)
            let id = url.deletingPathExtension().lastPathComponent
            if id == "unknown" { throw NSError(domain: "示例读取超时", code: 1) }
            if id == "wide" { return .init(width: 3840, height: 1600, frameRate: 23.976, codec: "hvc1", estimatedBitrate: 7_500_000) }
            return .init(width: id == "2" ? 1280 : 1920, height: id == "2" ? 720 : 1080, frameRate: 24, codec: "avc1", estimatedBitrate: 3_200_000)
        }
        app.results = titles
        app.searchLabel = "为你发现"
        app.automaticQualityInspection = false
        app.inspectVisibleQuality(app.groups[0])
        check("automatic_off_does_not_start_visible_probe", inspections == 0)
        app.mediaQuality.check(titles, providers: providers, force: true)
        try await wait()
        check("manual_read_works_with_automatic_off", inspections == titles.count)
        let recommendations = app.sourceRecommendations(titles)
        check("source_recommendations_use_measured_quality", recommendations.candidates.first?.title.id == "wide")
        check("source_recommendations_show_five_and_preserve_more", recommendations.candidates.count == 5 && recommendations.remainingCount == titles.count - 5)
        let expandedRecommendations = app.sourceRecommendations(titles, limit: Int.max)
        check("source_recommendations_expand_without_losing_sources", expandedRecommendations.candidates.count == titles.count && expandedRecommendations.remainingCount == 0)
        app.detailPresented = true; app.detailSources = [titles[0]]
        app.results = [titles[0], titles.first(where: { $0.id == "wide" })!, titles[1]]
        app.mergeMoreDetailSources()
        check("more_pages_add_only_matching_title", Set(app.detailSources.map(\.id)) == Set(["0", "wide"]))
        let yearKnown = MediaTitle(id: "year-a", title: "同名影片", year: "2020", posterURL: nil, summary: "", providerID: "demo-a", providerName: "A")
        let yearUnknown = MediaTitle(id: "year-b", title: "同名影片", year: "", posterURL: nil, summary: "", providerID: "demo-b", providerName: "B")
        let otherYear = MediaTitle(id: "year-c", title: "同名影片", year: "2022", posterURL: nil, summary: "", providerID: "demo-b", providerName: "B")
        app.detailSources = [yearKnown]; app.results = [yearKnown, yearUnknown]; app.mergeMoreDetailSources()
        app.results = [yearKnown, yearUnknown, otherYear]; app.mergeMoreDetailSources()
        check("ambiguous_year_does_not_remain_in_previous_group", app.detailSources == [yearKnown])
        app.detailSources = [yearKnown, yearUnknown]; app.select(yearUnknown)
        app.results = [yearKnown, yearUnknown, otherYear]; app.mergeMoreDetailSources()
        check("more_pages_respect_selected_source_while_detail_loads", app.detailSources == [yearUnknown])
        app.dismissDetail(); app.detailPresented = true
        let corrected = MediaTitle(id: yearKnown.id, title: "另一部电影", year: "2022", posterURL: nil, summary: "", providerID: yearKnown.providerID, providerName: yearKnown.providerName)
        app.detailSources = [yearKnown]; app.results = [yearKnown, yearUnknown]
        app.mergeMoreDetailSources(confirmed: corrected)
        check("confirmed_detail_metadata_overrides_stale_search_row", app.detailSources == [corrected])
        let disabled = (0..<5).map { MediaTitle(id: "disabled-\($0)", title: "示例", year: "", posterURL: nil, summary: "", providerID: "disabled", providerName: "停用") }
        let enabled = MediaTitle(id: "enabled", title: "示例", year: "", posterURL: nil, summary: "", providerID: "demo-a", providerName: "可用")
        check("enabled_unknown_sources_precede_disabled_sources", app.sourceRecommendations(disabled + [enabled]).candidates.first?.title.id == "enabled")
        app.detailSources = [titles[0]]; app.results = [titles[1]]; app.query = "其他作品"
        var detailQuery = ""
        app.detailPageSearch = { query, _, _ in
            detailQuery = query
            return [ProviderPageResult(providerID: "demo-b", page: CatalogPage(providerID: "demo-b", titles: [titles.first(where: { $0.id == "wide" })!], categories: [], page: 1, pageCount: 1, total: 1), error: nil)]
        }
        app.searchMoreDetailSources()
        let searchDeadline = Date().addingTimeInterval(3)
        while app.detailMoreSearching, Date() < searchDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        check("more_search_uses_current_work_not_old_query", detailQuery == titles[0].title && Set(app.detailSources.map(\.id)) == Set(["0", "wide"]))
        app.dismissDetail(); app.detailPresented = true; app.detailSources = [titles[0]]
        app.detailPageSearch = { _, _, _ in
            try? await Task.sleep(nanoseconds: 300_000_000)
            return [ProviderPageResult(providerID: "demo-b", page: CatalogPage(providerID: "demo-b", titles: [titles.first(where: { $0.id == "wide" })!], categories: [], page: 1, pageCount: 1, total: 1), error: nil)]
        }
        app.searchMoreDetailSources(); await Task.yield(); app.dismissDetail()
        try await Task.sleep(nanoseconds: 100_000_000)
        check("late_more_search_cannot_reopen_closed_detail", !app.detailPresented && app.detailSources.isEmpty && !app.detailMoreSearching)
        app.detailPresented = false; app.detailSources = []; app.results = titles
        app.catalogSort = .resolution
        let best = app.filteredGroups.first.flatMap { app.mediaQuality.best(in: $0.sources, providers: providers) }
        check("group_resolution_sort_uses_best_actual_source", best?.providerName == "演示来源 B" && best?.sample.width == 3840)
        let count = inspections
        app.showPlayer = true
        app.mediaQuality.check([titles[0]], providers: providers, force: true)
        check("playing_view_blocks_background_probe_submission", inspections == count && app.mediaQuality.readingCount == 0)
        app.showPlayer = false
        var modified = providers; modified[0].endpoint = URL(string: "https://fixture.invalid/changed")!
        app.providers = modified
        check("endpoint_change_does_not_reuse_title_result", app.mediaQuality.state(for: titles[0], providers: modified) == nil)
        app.providers = providers
        app.automaticQualityInspection = true
        var pendingBenchmarkRead: CheckedContinuation<MediaQualitySample, Never>?
        let originalInspector = app.mediaQuality.inspect
        app.mediaQuality.inspect = { _ in await withCheckedContinuation { pendingBenchmarkRead = $0 } }
        let pending = MediaTitle(id: "benchmark-pending", title: "Benchmark pending", year: "2026", posterURL: nil, summary: "", providerID: "demo-a", providerName: "演示来源 A")
        app.mediaQuality.check([pending], providers: providers, force: true)
        let pendingDeadline = Date().addingTimeInterval(3)
        while pendingBenchmarkRead == nil, Date() < pendingDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let started = app.playback.performance.run(mode: .clarity, resolution: .source, frameRate: .source, sourceSize: .init(width: 64, height: 64), sourceFPS: 24)
        check("performance_test_cancels_background_metadata", started && pendingBenchmarkRead != nil && app.mediaQuality.readingCount == 0 && app.mediaQuality.queuedCount == 0)
        pendingBenchmarkRead?.resume(returning: .init(width: 320, height: 180))
        app.playback.performance.cancel()
        let performanceDeadline = Date().addingTimeInterval(8)
        while app.playback.performance.isRunning, Date() < performanceDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        check("cancelled_metadata_does_not_reappear_after_self_test", !app.playback.performance.isRunning && app.mediaQuality.state(for: pending, providers: providers) == nil)
        app.mediaQuality.inspect = originalInspector

        func snapshot<V: View>(_ view: V, size: NSSize, name: String) async throws {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            window.orderBack(nil)
            try await Task.sleep(nanoseconds: 600_000_000)
            hosting.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw NSError(domain: "snapshot", code: 1) }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "snapshot", code: 2) }
            try png.write(to: destination.appendingPathComponent(name + ".png"))
            check("native_snapshot_\(name)", bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0 && png.count > 10_000)
            window.close()
        }
        try await snapshot(ContentView(app: app), size: NSSize(width: 1280, height: 900), name: "home-1280")
        try await snapshot(ContentView(app: app), size: NSSize(width: 1040, height: 760), name: "home-minimum")
        app.watchlist = app.groups.prefix(6).map { SavedTitle(group: $0) }
        app.section = .watchlist
        try await snapshot(ContentView(app: app), size: NSSize(width: 1280, height: 900), name: "watchlist-1280")
        app.history = [WatchRecord(id: "demo-history", title: "星际穿越", episode: "正片", url: URL(string: "https://fixture.invalid/history.mp4")!, posterURL: poster(0), position: 1260, duration: 10200)]
        app.section = .history
        try await snapshot(ContentView(app: app), size: NSSize(width: 1280, height: 900), name: "history-1280")
        app.section = .sources
        try await snapshot(ContentView(app: app), size: NSSize(width: 1280, height: 900), name: "sources-1280")
        app.section = .quality
        try await snapshot(ContentView(app: app), size: NSSize(width: 1280, height: 900), name: "quality-1280")
        app.section = .discover
        app.query = "星际穿越"; app.results = titles.filter { $0.title == "星际穿越" }; app.searchLabel = "“星际穿越”的搜索结果"
        try await snapshot(ContentView(app: app), size: NSSize(width: 1280, height: 900), name: "search-1280")
        app.detail = fixtureDetail(titles[0]); app.detailSources = titles.filter { $0.title == "星际穿越" }; app.selectedLineID = "main"
        try await snapshot(DetailView(app: app), size: NSSize(width: 900, height: 740), name: "detail-900")
        app.detailSources = (0..<7).map { index in
            MediaTitle(id: "fixture-source-\(index)", title: "星际穿越", year: "2014", posterURL: nil, summary: "", providerID: "demo-a", providerName: "演示来源 \(index + 1)")
        }
        try await snapshot(DetailView(app: app), size: NSSize(width: 900, height: 740), name: "detail-more-sources")
        app.showPlayer = true
        app.playback.player.isMuted = true
        app.playback.selectEnhancementMode(.original)
        app.playback.open(url: URL(fileURLWithPath: CommandLine.arguments[2]), title: "本地影片", episode: "")
        let readyDeadline = Date().addingTimeInterval(5)
        while app.playback.duration <= 0, Date() < readyDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        app.playback.pause()
        check("local_player_fixture_ready", app.playback.duration > 0 && app.playback.error == nil)
        try await snapshot(ContentView(app: app), size: NSSize(width: 1280, height: 900), name: "player-1280")
        app.playback.player.replaceCurrentItem(with: nil)
        app.showPlayer = false
        app.mediaQuality.cancelAll()
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": checks, "scope": "Real AppModel/controller wiring and native SwiftUI bitmap snapshots. Offline injected metadata; film names, providers, descriptions and quality values are demo fixtures, not live-source verification. Optional publicly supplied cover images cached in .build/catalog-preview-artwork are used only for UI previews; production UI uses source-supplied covers. No pointer interaction or native display-window proof."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("quality-discovery.json"))
        if !passed { exit(1) }
    }
}
