import Foundation
import AVFoundation
import Combine
import CinemaCore

// Real local Vision + AVPlayer. No injected detections, user defaults, history, or UI.
@main struct AdSkipPlaybackSmoke {
    struct Failure: Error { let message: String }
    struct Check: Codable { let name: String; let passed: Bool; let detail: String }
    @MainActor static func main() async {
        guard CommandLine.arguments.count >= 4, CommandLine.arguments.contains("--validate") else { exit(2) }
        let media = URL(fileURLWithPath: CommandLine.arguments[1])
        let subtitles = URL(fileURLWithPath: CommandLine.arguments[2])
        var checks: [Check] = []
        let controller = PlaybackController()
        controller.volume = 0; controller.player.isMuted = true
        defer { controller.pause(); controller.adSkip.stop() }
        do {
            // Warm Vision explicitly: cold-model timing is recorded by the separate scanner probe.
            let warm = AdFrameAnalyzer(); warm.configure(url: media)
            let evidence = await warm.analyze(time: 20, protectedRegions: [AdCleanupSettings.defaultProtection])
            warm.cancel()
            try require(evidence.classification == .advertisement, "The actual fixture OCR did not recognize the inserted card")
            controller.setRate(0.5)
            controller.open(url: media, title: "广告识别隔离验收", episode: "40s synthetic")
            try await eventually("real OCR identifies a closed upcoming segment", timeout: 45) { !controller.adSkip.segments.isEmpty }
            controller.pause()
            let segment = try required(controller.adSkip.segments.first, "No detected interval")
            try require(segment.start >= 16 && segment.end < 28 && segment.end - segment.start >= 4, "Interval escaped synthetic ad boundaries: \(segment)")
            let paused = controller.position
            try await sleep(0.5)
            try require(!controller.playbackRequested && abs(controller.position - paused) < 0.2 && controller.adSkipNotice == nil, "Background detection moved paused playback")
            checks.append(Check(name: "real_ocr_closes_bounded_ad_interval_without_moving_paused_player", passed: true, detail: "Detected \(segment.start)–\(segment.end)s inside actual 16–28s test insert; pause remained at \(paused)s."))

            controller.loadSubtitles(subtitles)
            controller.seek(to: 0)
            try await eventually("rewind") { abs(controller.player.currentTime().seconds) < 0.2 }
            controller.setRate(2); controller.togglePlayback()
            try await eventually("automatic skip is committed", timeout: 25) { controller.adSkipNotice != nil }
            let event = try required(controller.adSkipNotice, "Missing undo event")
            try require(event.returnPosition >= segment.start && event.returnPosition < segment.end - 1, "Skipped before entering confirmed ad or too late")
            try require(controller.player.currentTime().seconds >= segment.end - 0.2, "Main AVPlayer did not seek to confirmed end")
            try require(controller.playbackRequested, "Automatic skip changed playback intent")
            checks.append(Check(name: "main_player_automatically_skips_confirmed_insert", passed: true, detail: "Actual AVPlayer moved from \(event.returnPosition)s to >=\(segment.end)s, preserving requested play."))

            try await eventually("original timeline subtitle after insert", timeout: 6) { controller.position > 28.2 && controller.subtitleText.contains("正常剧情字幕：广告后") }
            checks.append(Check(name: "external_subtitles_keep_original_media_timeline", passed: true, detail: "At \(controller.position)s the original post-28s subtitle cue is visible; no subtitle retiming or media cutting."))

            controller.undoAdSkip()
            try await eventually("undo returns and pauses") { !controller.playbackRequested && abs(controller.player.currentTime().seconds - event.returnPosition) < 0.25 }
            try require(controller.adSkipNotice == nil, "Undo event was not consumed")
            controller.setRate(1); controller.togglePlayback()
            try await sleep(1.1)
            try require(controller.player.currentTime().seconds < segment.end - 1 && controller.adSkipNotice == nil, "Undo immediately looped into another skip")
            controller.pause()
            checks.append(Check(name: "undo_restores_position_pauses_and_prevents_repeat_skip", passed: true, detail: "Returned to \(event.returnPosition)s; after explicit resume remained inside the ad without another jump."))

            try await identifiedFresh(controller, media: media)
            let newSegment = try required(controller.adSkip.segments.first, "Fresh detection missing")
            controller.seek(to: newSegment.start + 1)
            try await eventually("explicit scrub enters ad") { abs(controller.player.currentTime().seconds - newSegment.start - 1) < 0.25 }
            controller.togglePlayback(); try await sleep(1)
            try require(controller.position < newSegment.end - 1 && controller.adSkipNotice == nil, "Explicit manual review was skipped")
            controller.pause()
            checks.append(Check(name: "manual_seek_into_identified_ad_is_respected", passed: true, detail: "Explicit scrub into the interval could play without automatic re-skipping."))

            try await identifiedFresh(controller, media: media)
            controller.automaticAdSkipping = false
            let disabledSegment = try required(controller.adSkip.segments.first, "Detection missing before disable")
            controller.seek(to: disabledSegment.start - 0.4)
            try await eventually("seek before disabled segment") { abs(controller.player.currentTime().seconds - disabledSegment.start + 0.4) < 0.25 }
            controller.togglePlayback(); try await sleep(1.3)
            try require(controller.position > disabledSegment.start && controller.position < disabledSegment.end - 1 && controller.adSkipNotice == nil, "Disabled setting still skipped")
            controller.pause()
            checks.append(Check(name: "disabled_mode_does_not_skip", passed: true, detail: "Crossed the known start with automatic skipping off and remained in the content."))

            controller.automaticAdSkipping = true
            for action in ["pause", "disable", "manual_seek"] {
                try await identifiedFresh(controller, media: media)
                let racingSegment = try required(controller.adSkip.segments.first, "No interval for intervention check")
                controller.seek(to: racingSegment.start - 0.35)
                try await eventually("position before racing interval") { abs(controller.player.currentTime().seconds - racingSegment.start + 0.35) < 0.2 }
                var intervened = false
                // Observe the requested target, then enqueue a real user action while AVPlayer is seeking.
                let observation = controller.$position.sink { value in
                    guard !intervened, abs(value - racingSegment.end) < 0.001 else { return }
                    intervened = true
                    Task { @MainActor in
                        if action == "pause" { controller.pause() }
                        else if action == "disable" { controller.automaticAdSkipping = false }
                        else { controller.seek(to: 5) }
                    }
                }
                controller.togglePlayback()
                try await eventually("automatic seek intervention scheduled", timeout: 5) { intervened }
                try await sleep(0.8)
                observation.cancel()
                try require(controller.adSkipNotice == nil, "Canceled automatic seek committed a late undo notice: \(action)")
                if action == "pause" {
                    try require(!controller.playbackRequested && controller.player.rate == 0, "Late seek resumed after Pause")
                } else if action == "disable" {
                    try require(!controller.automaticAdSkipping && controller.playbackRequested, "Disabling lost the user's playback intent")
                } else {
                    try require(controller.player.currentTime().seconds >= 5 && controller.player.currentTime().seconds < 7, "Automatic seek overrode the newer manual target")
                }
                controller.pause(); controller.automaticAdSkipping = true
                checks.append(Check(name: "inflight_automatic_seek_respects_\(action)", passed: true, detail: "Queued intervention at automatic target publication; no stale undo callback or overridden latest intent."))
            }
            controller.open(url: media, title: "Replacement", episode: "new identity")
            controller.pause()
            try require(controller.adSkip.segments.isEmpty && controller.adSkipNotice == nil, "Replacement inherited old intervals or undo state")
            let freshID = controller.itemID
            try await sleep(0.7)
            try require(controller.itemID == freshID && controller.adSkip.segments.isEmpty && !controller.playbackRequested, "Late scanner work changed the paused replacement")
            checks.append(Check(name: "replacement_discards_detection_and_late_results", passed: true, detail: "New item, even using the same URL, clears intervals and stays paused after callbacks settle."))
        } catch { checks.append(Check(name: "playback_integration", passed: false, detail: String(describing: error))) }
        controller.pause(); controller.adSkip.stop()
        let passed = checks.count == 10 && checks.allSatisfy(\.passed)
        let value: [String: Any] = ["checkedAt": ISO8601DateFormatter().string(from: Date()), "passed": passed,
            "mode": "real Vision OCR and real AVPlayer on isolated synthetic MP4 with audio and external subtitles",
            "nativeUIVerified": false, "realWorldAdAccuracyVerified": false, "networkRequestsMade": false,
            "checks": checks.map { ["name": $0.name, "passed": $0.passed, "detail": $0.detail] as [String: Any] }]
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        exit(passed ? 0 : 1)
    }
    @MainActor static func identifiedFresh(_ controller: PlaybackController, media: URL) async throws {
        controller.setRate(0.5)
        controller.open(url: media, title: "Fresh detection", episode: "same fixture")
        try await eventually("new item detected independently", timeout: 35) { !controller.adSkip.segments.isEmpty }
        controller.pause(); controller.setRate(1)
    }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    static func required<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw Failure(message: message) }; return value }
    static func sleep(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
    @MainActor static func eventually(_ message: String, timeout: Double = 8, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return }; try await sleep(0.04) }
        throw Failure(message: message + " timed out")
    }
}
