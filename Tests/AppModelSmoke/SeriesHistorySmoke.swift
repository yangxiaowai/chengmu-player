import AppKit
import AVFoundation
import Foundation
import SwiftUI
import CinemaCore

@main struct SeriesHistorySmoke {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]); print("\(passed ? "PASS" : "FAIL") \(name)") }
        let app = AppModel(); app.providers = []; app.automaticQualityInspection = false; app.autoNext = false
        let title = MediaTitle(id: "series", title: "漫长的季节", year: "2023", posterURL: nil, summary: "", providerID: "local", providerName: "本地片库", category: "国产剧")
        let episodes = (1...3).map { (number: Int) -> Episode in
            Episode(id: "e\(number)", name: "第0\(number)集", url: fixtures.appendingPathComponent("\(number).mp4"), number: number)
        }
        let detail = MediaDetail(title: title, lines: [.init(id: "line", name: "主线路", episodes: episodes)])
        func record(_ index: Int, position: Double, duration: Double = 100) -> WatchRecord {
            let episode = episodes[index]
            return .init(id: "local:series:line:\(episode.id)", title: title.title, episode: episode.name, url: episode.url, posterURL: nil, position: position, duration: duration, mediaDetail: detail, lineID: "line", episodeID: episode.id)
        }
        let middle = record(0, position: 97), partial = record(1, position: 12, duration: 30), final = record(2, position: 97)
        app.history = [middle, partial]
        check("completed_middle_episode_remains_in_continue_watching", app.historyRecords(showAllEpisodes: false, unfinishedOnly: true) == [middle])
        check("all_episode_filter_uses_episode_progress", app.historyRecords(showAllEpisodes: true, unfinishedOnly: true) == [partial])
        let target = app.historyPlaybackTarget(middle, showAllEpisodes: false)
        check("continue_action_targets_next_episode_with_its_own_progress", target.id == "local:series:line:e2" && target.url == episodes[1].url && target.position == 12 && target.playbackContext?.episode.id == "e2")
        app.history = [middle]
        let fresh = app.historyPlaybackTarget(middle, showAllEpisodes: false)
        check("unwatched_next_episode_starts_at_zero", fresh.id == "local:series:line:e2" && fresh.position == 0 && fresh.duration == 0)
        check("all_episode_replay_stays_on_selected_episode", app.historyPlaybackTarget(middle, showAllEpisodes: true).episodeID == "e1" && app.historyPlaybackTarget(middle, showAllEpisodes: true).position == 0)
        check("partial_episode_continues_without_advancing", app.historyPlaybackTarget(partial, showAllEpisodes: false) == partial)
        app.history = [final, middle]
        check("final_episode_hides_work_without_resurrecting_older_episode", app.historyRecords(showAllEpisodes: false, unfinishedOnly: true).isEmpty)
        check("complete_series_restarts_from_first_episode", app.historyPlaybackTarget(final, showAllEpisodes: false).episodeID == "e1" && app.historyPlaybackTarget(final, showAllEpisodes: false).position == 0)
        var legacy = middle; legacy.mediaDetail = nil; legacy.lineID = nil; legacy.episodeID = nil
        app.history = [legacy]
        check("legacy_episode_stays_visible_without_guessing_next_episode", app.historyRecords(showAllEpisodes: false, unfinishedOnly: true) == [legacy] && app.historyPlaybackTarget(legacy, showAllEpisodes: false) == legacy)
        var gap = middle; gap.mediaDetail!.lines[0].episodes.remove(at: 1)
        check("missing_number_does_not_jump_over_episode", app.historyPlaybackTarget(gap, showAllEpisodes: false) == gap)
        var movie = final; movie.title = "深海"; movie.episode = "正片"; movie.mediaDetail = nil; movie.lineID = nil; movie.episodeID = nil
        app.history = [movie]
        check("completed_movie_is_hidden_and_replay_starts_at_zero", app.historyRecords(showAllEpisodes: false, unfinishedOnly: true).isEmpty && app.historyPlaybackTarget(movie, showAllEpisodes: false).position == 0)

        func snapshot<V: View>(_ view: V, name: String) async throws {
            let host = NSHostingView(rootView: view.padding(32).background(CinemaStyle.background).foregroundStyle(CinemaStyle.primary).preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: 1040, height: 700)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.setFrameOrigin(.init(x: -5000, y: -5000)); window.orderBack(nil)
            try await Task.sleep(nanoseconds: 400_000_000); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "snapshot", code: 1) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = bitmap.representation(using: .png, properties: [:])!
            try png.write(to: destination.appendingPathComponent(name + ".png")); window.close()
            check("snapshot_\(name)", png.count > 10_000)
        }
        app.history = [middle, partial]
        try await snapshot(HistoryView(app: app), name: "continue-next-episode")
        app.history = [final, middle]
        try await snapshot(HistoryView(app: app, unfinishedOnly: false), name: "completed-series")
        app.history = [middle, partial]
        try await snapshot(HistoryView(app: app, unfinishedOnly: false, showAllEpisodes: true), name: "individual-episodes")
        let before = app.history
        app.resumeHistory(middle, showAllEpisodes: false); app.playback.pause()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && (app.playback.player.currentItem?.status != .readyToPlay || abs(app.playback.position - 12) > 0.5) { try await Task.sleep(nanoseconds: 50_000_000) }
        check("native_resume_opens_next_local_item_and_seeks_to_saved_progress", app.currentEpisodeID == "e2" && (app.playback.player.currentItem?.asset as? AVURLAsset)?.url == episodes[1].url && app.playback.player.currentItem?.status == .readyToPlay && abs(app.playback.position - 12) < 0.5)
        check("native_resume_preserves_pause_intent", !app.playback.playbackRequested && app.playback.player.rate == 0)
        check("history_selection_does_not_delete_prior_episode", app.history.contains { $0.id == middle.id } && before.count <= app.history.count)
        app.closePlayer(); app.mediaQuality.cancelAll()

        // Detail-sheet Continue should use the same episode-aware semantics as
        // Continue Watching, rather than restarting the just-completed episode.
        let detailApp = AppModel(); detailApp.providers = []; detailApp.automaticQualityInspection = false; detailApp.autoNext = false
        detailApp.history = [middle, partial]; detailApp.detail = detail; detailApp.selectedLineID = "line"
        detailApp.continueDetail(); detailApp.playback.pause()
        let detailDeadline = Date().addingTimeInterval(10)
        while Date() < detailDeadline && (detailApp.playback.player.currentItem?.status != .readyToPlay || abs(detailApp.playback.position - 12) > 0.5) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check("detail_continue_opens_next_episode_with_its_own_progress",
              detailApp.currentEpisodeID == "e2" && (detailApp.playback.player.currentItem?.asset as? AVURLAsset)?.url == episodes[1].url &&
              detailApp.playback.player.currentItem?.status == .readyToPlay && abs(detailApp.playback.position - 12) < 0.5)
        detailApp.closePlayer()

        let replayApp = AppModel(); replayApp.providers = []; replayApp.automaticQualityInspection = false; replayApp.autoNext = false
        replayApp.history = [final]; replayApp.detail = detail; replayApp.selectedLineID = "line"
        replayApp.continueDetail(); replayApp.playback.pause()
        check("detail_completed_series_replays_from_first_episode", replayApp.currentEpisodeID == "e1" &&
              (replayApp.playback.player.currentItem?.asset as? AVURLAsset)?.url == episodes[0].url)
        replayApp.closePlayer()

        let gapApp = AppModel(); gapApp.providers = []; gapApp.automaticQualityInspection = false; gapApp.autoNext = false
        gapApp.history = [gap]; gapApp.detail = gap.mediaDetail; gapApp.selectedLineID = "line"
        gapApp.continueDetail(); gapApp.playback.pause()
        check("detail_continue_does_not_skip_missing_episode", gapApp.currentEpisodeID != "e3")
        gapApp.closePlayer()

        // The previous catalog ended at e2; today's catalog now contains e3.
        // Recheck the real current lineup instead of replaying a once-complete season.
        var previousFinal = record(1, position: 97)
        previousFinal.mediaDetail?.lines[0].episodes.removeLast()
        let savedNewEpisode = record(2, position: 12, duration: 30)
        check("old_catalog_final_episode_was_complete", previousFinal.isCompleted)
        let updatedApp = AppModel(); updatedApp.providers = []; updatedApp.automaticQualityInspection = false; updatedApp.autoNext = false
        updatedApp.history = [previousFinal, savedNewEpisode]; updatedApp.detail = detail; updatedApp.selectedLineID = "line"
        updatedApp.continueDetail(); updatedApp.playback.pause()
        let updatedDeadline = Date().addingTimeInterval(10)
        while Date() < updatedDeadline && (updatedApp.playback.player.currentItem?.status != .readyToPlay || abs(updatedApp.playback.position - 12) > 0.5) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check("updated_catalog_continues_new_episode_with_its_own_saved_position",
              updatedApp.currentEpisodeID == "e3" && updatedApp.playback.player.currentItem?.status == .readyToPlay &&
              abs(updatedApp.playback.position - 12) < 0.5)
        updatedApp.closePlayer()

        var changedNumber = detail
        changedNumber.lines[0].episodes[1].number = 4
        let renumberApp = AppModel(); renumberApp.providers = []; renumberApp.automaticQualityInspection = false
        renumberApp.history = [middle]; renumberApp.detail = changedNumber; renumberApp.selectedLineID = "line"
        renumberApp.continueDetail()
        check("updated_catalog_does_not_skip_when_next_number_changed",
              !renumberApp.showPlayer && renumberApp.currentEpisodeID.isEmpty && renumberApp.message != nil)
        renumberApp.closePlayer()

        var removedNext = detail
        removedNext.lines[0].episodes.remove(at: 1)
        let removedApp = AppModel(); removedApp.providers = []; removedApp.automaticQualityInspection = false
        removedApp.history = [middle]; removedApp.detail = removedNext; removedApp.selectedLineID = "line"
        removedApp.continueDetail()
        check("updated_catalog_does_not_skip_when_next_episode_is_missing",
              !removedApp.showPlayer && removedApp.currentEpisodeID.isEmpty && removedApp.message != nil)
        removedApp.closePlayer()
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": checks, "scope": "Actual AppModel with isolated history fixtures and local MP4s; native controller opens the next episode and restores saved progress while paused. Three native SwiftUI bitmap layouts, no physical button/fullscreen or full network playback certification."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("series-history.json"))
        if !passed { exit(1) }
    }
}
