import AppKit
import Foundation
import SwiftUI
import CinemaCore

@main struct MediaResponseUISmoke {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var checks: [[String: Any]] = []
        func check(_ name: String, _ value: Bool) { checks.append(["name": name, "passed": value]); print("\(value ? "PASS" : "FAIL") \(name)") }
        let app = AppModel(); app.automaticQualityInspection = false
        let providers = (1...4).map { (n: Int) -> SourceProvider in .init(id: "p\(n)", name: "来源 \(["A", "B", "C", "D"][n-1])", endpoint: URL(string: "https://fixture.invalid/p\(n)")!) }
        let titles = providers.map { MediaTitle(id: "work", title: "漫长的季节", year: "2023", posterURL: nil, summary: "比较不同来源的画质与响应，选择适合当前网络的线路，接着看喜欢的故事。", providerID: $0.id, providerName: $0.name, category: "国产剧") }
        func line(_ provider: String, name: String) -> PlaybackLine {
            .init(id: provider, name: name, episodes: (1...3).map { (n: Int) -> Episode in .init(id: "e\(n)", name: "第0\(n)集", url: URL(string: "https://fixture.invalid/\(provider)/\(n).m3u8")!, number: n) })
        }
        func detail(_ title: MediaTitle) -> MediaDetail {
            .init(title: title, lines: title.providerID == "p1" ? [line("p1", name: "主线路"), line("p2", name: "备用线路")] : [line(title.providerID, name: "主线路")])
        }
        app.providers = providers; app.detail = detail(titles[0]); app.detailSources = titles; app.selectedLineID = "p1"
        app.mediaQuality.loadDetail = { title, _ in detail(title) }
        app.mediaQuality.measureResponse = { url in
            if url.path.contains("p3") { throw URLError(.timedOut) }
            return .init(milliseconds: url.path.contains("p1") ? 180 : (url.path.contains("p2") ? 1460 : 320))
        }
        app.mediaQuality.inspect = { url in
            if url.path.contains("p4") { throw URLError(.cannotDecodeContentData) }
            return .init(width: url.path.contains("p2") ? 1280 : 1920, height: url.path.contains("p2") ? 720 : 1080, frameRate: 24)
        }
        app.mediaQuality.check(titles, providers: providers)
        app.mediaQuality.check(line: line("p2", name: "备用线路"), providerName: providers[1].name)
        let deadline = Date().addingTimeInterval(5)
        while app.mediaQuality.readingCount > 0 || app.mediaQuality.queuedCount > 0 {
            if Date() > deadline { throw NSError(domain: "ui-fixture-timeout", code: 1) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check("source_latency_ready", app.mediaQuality.responseState(for: titles[0], providers: providers)?.label == "响应 180 ms")
        check("line_latency_shared_with_source", app.mediaQuality.responseState(for: URL(string: "https://fixture.invalid/p2/1.m3u8")!)?.label == "响应 1460 ms")
        check("timeout_and_quality_are_independent", app.mediaQuality.responseState(for: titles[2], providers: providers)?.label == "响应超时" && app.mediaQuality.best(in: [titles[2]], providers: providers) != nil)
        check("missing_quality_still_has_latency", app.mediaQuality.best(in: [titles[3]], providers: providers) == nil && app.mediaQuality.responseState(for: titles[3], providers: providers)?.label == "响应 320 ms")
        let active = line("p1", name: "主线路"), alternate = line("p2", name: "备用线路")
        check("current_line_response_targets_current_episode", PlayerEpisodePanel.responseURL(for: active, currentLine: active, currentEpisodeID: "e3") == active.episodes[2].url)
        check("other_line_response_targets_matching_episode", PlayerEpisodePanel.responseURL(for: alternate, currentLine: active, currentEpisodeID: "e3") == alternate.episodes[2].url)
        var missing = alternate; missing.episodes.removeLast()
        check("missing_episode_has_no_response_target", PlayerEpisodePanel.responseURL(for: missing, currentLine: active, currentEpisodeID: "e3") == nil)
        var ambiguous = alternate; ambiguous.episodes.append(alternate.episodes[2])
        check("ambiguous_episode_has_no_response_target", PlayerEpisodePanel.responseURL(for: ambiguous, currentLine: active, currentEpisodeID: "e3") == nil)
        var wrongName = alternate; wrongName.episodes[2].name = "第03集 其他版本"
        check("same_number_different_name_has_no_response_target", PlayerEpisodePanel.responseURL(for: wrongName, currentLine: active, currentEpisodeID: "e3") == nil)
        var conflictingDuplicate = alternate; var otherVersion = alternate.episodes[2]; otherVersion.id = "other-version"; otherVersion.name = "第03集 其他版本"; conflictingDuplicate.episodes.append(otherVersion)
        check("duplicate_number_with_only_one_matching_name_is_still_ambiguous", PlayerEpisodePanel.responseURL(for: conflictingDuplicate, currentLine: active, currentEpisodeID: "e3") == nil)
        var normalizedName = alternate; normalizedName.episodes[2].name = "第3集"
        check("normalized_episode_labels_match", PlayerEpisodePanel.responseURL(for: normalizedName, currentLine: active, currentEpisodeID: "e3") == normalizedName.episodes[2].url)
        check("unknown_active_episode_has_no_response_target", PlayerEpisodePanel.responseURL(for: active, currentLine: active, currentEpisodeID: "missing") == nil)
        let unnamedNumber = Episode(id: "film", name: "正片", url: active.episodes[0].url, number: nil)
        let numberlessActive = PlaybackLine(id: "movie-a", name: "A", episodes: [unnamedNumber])
        let numberlessOther = PlaybackLine(id: "movie-b", name: "B", episodes: [Episode(id: "other", name: "正片", url: alternate.episodes[0].url, number: nil)])
        check("numberless_exact_name_can_be_matched_uniquely", PlayerEpisodePanel.responseURL(for: numberlessOther, currentLine: numberlessActive, currentEpisodeID: "film") == numberlessOther.episodes[0].url)
        var numberlessDuplicate = numberlessOther; numberlessDuplicate.episodes.append(numberlessOther.episodes[0])
        check("numberless_duplicate_name_is_not_guessed", PlayerEpisodePanel.responseURL(for: numberlessDuplicate, currentLine: numberlessActive, currentEpisodeID: "film") == nil)
        func snapshot<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat) async throws {
            let host = NSHostingView(rootView: view.frame(width: width, height: height).preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.setFrameOrigin(.init(x: -5000, y: -5000)); window.orderBack(nil)
            try await Task.sleep(nanoseconds: 400_000_000); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "snapshot", code: 1) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = bitmap.representation(using: .png, properties: [:])!; try data.write(to: destination.appendingPathComponent(name + ".png")); window.close()
            check("snapshot_\(name)", data.count > 10_000)
        }
        try await snapshot(DetailView(app: app), name: "source-response-detail", width: 900, height: 960)
        try await snapshot(DetailView(app: app), name: "source-response-standard", width: 900, height: 740)
        app.showPlayer = true; app.playback.title = titles[0].title; app.playback.episodeName = "第01集"; app.alternativeSources = titles
        try await snapshot(PlayerEpisodePanel(app: app).padding(18).background(CinemaStyle.background), name: "source-response-player-panel", width: 340, height: 900)
        check("playback_view_does_not_start_new_background_jobs", app.mediaQuality.readingCount == 0 && app.mediaQuality.queuedCount == 0)
        app.mediaQuality.cancelAll()
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks, "scope": "Actual AppModel/coordinator + production SwiftUI views with controlled quality/latency fixtures. Three offscreen native bitmap layouts, no network or physical pointer/full playback verification."], options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("source-response-ui.json"))
        if !passed { exit(1) }
    }
}
