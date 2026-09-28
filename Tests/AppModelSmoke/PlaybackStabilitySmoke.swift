// Independent headless regression; run through scripts/validate-playback-stability.sh.
import Foundation
import AVFoundation
import CinemaCore

@main struct PlaybackStabilitySmoke {
    struct Check: Codable { let name: String; let passed: Bool; let detail: String }
    struct Failure: Error { let detail: String }
    @MainActor static func main() async throws {
        guard CommandLine.arguments.contains("--validate"), CommandLine.arguments.count >= 4 else { exit(2) }
        let media = URL(fileURLWithPath: CommandLine.arguments[2])
        let stalledURL = URL(string: CommandLine.arguments[3])!
        let c = PlaybackController(); c.volume = 0
        var checks: [Check] = []; var finishCount = 0
        var stage = "initial"
        c.onFinished = { finishCount += 1 }
        func check(_ name: String, _ passed: Bool, _ detail: String) { checks.append(.init(name: name, passed: passed, detail: detail)) }
        func until(_ predicate: () -> Bool, seconds: Double = 6) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate() {
                if Date() >= deadline { throw Failure(detail: "timed out at \(stage): status=\(String(describing: c.player.currentItem?.status)) error=\(c.error ?? "nil") position=\(c.position)") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func ready(_ position: Double = 20) async throws {
            stage = "ready(\(position))"
            c.open(url: media, title: "Stability", episode: "Local", resume: position)
            try await until { c.player.currentItem?.status == .readyToPlay && c.position >= position - 0.3 && c.isPlaying }
        }
        try await ready(); c.pause()
        stage = "paused stall"
        NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: c.player.currentItem)
        try await Task.sleep(nanoseconds: 100_000_000)
        check("paused_stall_has_no_spinner", !c.isLoading && c.loadingMessage == nil && !c.recoverySuggested && !c.playbackRequested, "Injected stalled notification on real paused local media; no network stall is claimed.")
        try await ready()
        stage = "first injected failure"
        let firstInterruptedItem = c.itemID
        let firstInterruptedPosition = c.position
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: c.player.currentItem)
        try await until { c.itemID != firstInterruptedItem && c.isPlaying && c.player.currentItem?.status == .readyToPlay }
        check("first_transport_failure_recovers_once", c.error == nil && c.position >= firstInterruptedPosition - 0.7 && finishCount == 0,
              "First injected interruption rebuilt the item near the previous position without advancing the episode.")
        stage = "repeated injected failure"
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: c.player.currentItem)
        try await until { c.hasPlaybackFailure }
        check("repeated_transport_failure_pauses_without_next", c.error != nil && c.player.rate == 0 && !c.isPlaying && !c.playbackRequested && !c.isLoading && finishCount == 0,
              "A second interruption in the same item lineage stops and offers explicit retry.")
        let failedItem = c.itemID
        let failedPosition = c.position
        c.error = nil
        c.togglePlayback()
        try await until { c.isPlaying && c.error == nil }
        check("dismissed_failure_play_rebuilds_item", c.itemID != failedItem && abs(c.player.currentTime().seconds - failedPosition) < 0.5, "Injected failed-to-end on ready local media, dismissed error text, then explicit Play must rebuild media at retained position.")
        check("play_on_error_explicitly_retries", c.playbackRequested && c.player.rate > 0, "Explicit Play recovers on real local media after dismissing fatal error text.")
        try await ready(30)
        stage = "new media automatic recovery"
        let distinctItem = c.itemID
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: c.player.currentItem)
        try await until { c.itemID != distinctItem && c.isPlaying && c.player.currentItem?.status == .readyToPlay }
        check("new_media_gets_its_own_recovery_budget", c.error == nil && c.position >= 29.2,
              "A separately opened item may use its own one automatic recovery.")
        try await ready(119)
        var raced = false
        let observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: c.player.currentItem, queue: .main) { _ in
            MainActor.assumeIsolated { raced = true; c.seek(to: 20) }
        }
        try await until { raced }
        try await until { abs(c.player.currentTime().seconds - 20) < 0.4 && c.player.rate > 0 }
        NotificationCenter.default.removeObserver(observer)
        check("real_eof_seek_back_rejects_old_end", finishCount == 0 && c.playbackRequested, "Real EOF observer seeks to 20 before delayed handler; no EOF notice was injected.")
        try await ready(119)
        try await until { finishCount == 1 }
        check("ordinary_eof_advances_once", !c.playbackRequested && c.player.rate == 0 && !c.isLoading, "Real terminal EOF completes once and leaves a stopped, ready controller.")
        c.togglePlayback()
        try await until { c.isPlaying && c.player.currentTime().seconds < 2 }
        check("manual_replay_after_eof", finishCount == 1 && c.playbackRequested, "Play after normal EOF seeks to zero and physically resumes.")
        c.pause(); c.seek(to: 120)
        try await Task.sleep(nanoseconds: 250_000_000)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: c.player.currentItem)
        try await Task.sleep(nanoseconds: 100_000_000)
        check("paused_terminal_notice_does_not_next", finishCount == 1 && !c.playbackRequested, "Explicit paused terminal notice does not call next; this notice is injected.")
        let resumeURL = stalledURL.deletingLastPathComponent().appendingPathComponent("resume.wav")
        c.open(url: resumeURL, title: "Pending failure", episode: "Loopback", resume: 52)
        try await Task.sleep(nanoseconds: 150_000_000)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: c.player.currentItem)
        try await Task.sleep(nanoseconds: 100_000_000)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: c.player.currentItem)
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = try await URLSession.shared.data(from: stalledURL.deletingLastPathComponent().appendingPathComponent("release"))
        c.togglePlayback()
        stage = "repeated preparation failure retry"
        try await until({ c.player.currentItem?.status == .readyToPlay && c.isPlaying && abs(c.player.currentTime().seconds - 52) < 0.5 }, seconds: 10)
        check("repeated_failure_during_preparation_preserves_resume", abs(c.player.currentTime().seconds - 52) < 0.5,
              "Two injected notices during preparation; current=\(c.player.currentTime().seconds), controller=\(c.position), error=\(c.error ?? "none").")
        try await ready(70)
        stage = "zero destination automatic recovery"
        let zeroInterruptedItem = c.itemID
        c.seek(to: 0)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: c.player.currentItem)
        try await until { c.itemID != zeroInterruptedItem && c.player.currentItem?.status == .readyToPlay && c.isPlaying }
        check("zero_destination_failure_retry", c.error == nil && c.player.currentTime().seconds < 0.5,
              "Seek to zero followed immediately by an interruption; automatic retry rebuilds at zero.")
        let waitStarted = Date()
        c.open(url: stalledURL, title: "Waiting", episode: "Loopback")
        try await Task.sleep(nanoseconds: 300_000_000)
        check("preparation_survives_paused_transport", c.isLoading && c.loadingMessage == "正在准备媒体" && !c.recoverySuggested, "Loopback server accepts requests and withholds response bytes; AVPlayer remains preparing.")
        try await until({ c.recoverySuggested }, seconds: 17)
        check("continuous_wait_suggests_manual_recovery", c.isLoading && Date().timeIntervalSince(waitStarted) >= 15 && c.player.currentItem?.status == .unknown, "Real pending loopback load exceeds 15 seconds; only suggestion, no automatic retry.")
        c.open(url: media, title: "Replacement", episode: "Local", resume: 7); c.pause()
        stage = "paused replacement"
        try await until { c.player.currentItem?.status == .readyToPlay && abs(c.player.currentTime().seconds - 7) < 0.3 && !c.isLoading }
        check("replacement_clears_wait_suggestion", !c.isLoading && c.loadingMessage == nil && !c.recoverySuggested && c.player.rate == 0,
              "Replacement ready paused item: loading=\(c.isLoading) message=\(c.loadingMessage ?? "none") suggested=\(c.recoverySuggested) rate=\(c.player.rate).")
        c.pause()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(checks), as: UTF8.self))
        exit(checks.allSatisfy(\.passed) ? 0 : 1)
    }
}
