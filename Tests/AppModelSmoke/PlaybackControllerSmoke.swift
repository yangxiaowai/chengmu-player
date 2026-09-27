// Run without rebuilding the app bundle (uses the existing Debug CinemaCore build):
// swiftc -parse-as-library -target arm64-apple-macos15.0 -I .build/out/Products/Debug -L .build/out/Products/Debug -lCinemaCore Sources/CinemaApp/PlaybackController.swift Sources/CinemaApp/EnhancementPipeline.swift Tests/AppModelSmoke/PlaybackControllerSmoke.swift -o .build/playback-controller-smoke
// .build/playback-controller-smoke --validate
import Foundation
import AppKit
import CinemaCore

@main struct ControllerSmoke {
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.contains("--validate"))
        let controller = PlaybackController()
        precondition(controller.volume == 0.8 && controller.rate == 1)
        controller.volume = 0.37
        controller.toggleMute()
        precondition(controller.volume == 0)
        controller.toggleMute()
        precondition(abs(controller.volume - 0.37) < 0.0001)
        controller.volume = 4
        precondition(controller.volume == 1 && controller.player.volume == 1)
        controller.volume = .nan
        precondition(controller.volume == 0.8 && controller.player.volume == 0.8)
        controller.setRate(.infinity)
        precondition(controller.rate == 1)
        controller.setRate(1.5)
        controller.enhancementMode = .clarity
        controller.scheduleSleepTimer(minutes: 15)
        precondition(controller.sleepRemainingSeconds == 900)
        controller.cancelSleepTimer()
        precondition(controller.sleepRemainingSeconds == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CinemaControllerSmoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = directory.appendingPathComponent("invalid.srt")
        try "not subtitles".write(to: invalid, atomically: true, encoding: .utf8)
        controller.loadSubtitles(invalid)
        precondition(controller.subtitleNotice != nil && controller.error == nil)
        let subtitle = directory.appendingPathComponent("test.srt")
        try "1\n00:00:01,000 --> 00:01:30,000\nSmoke subtitle\n".write(to: subtitle, atomically: true, encoding: .utf8)
        controller.open(url: directory.appendingPathComponent("missing-local.mov"), title: "Smoke", episode: "Local")
        controller.loadSubtitles(subtitle)
        precondition(controller.externalSubtitleName == "test.srt" && controller.subtitleNotice == nil)
        controller.subtitleOffset = 1.5
        controller.position = 30
        controller.retry()
        precondition(controller.externalSubtitleName == "test.srt" && controller.subtitleOffset == 1.5)
        precondition(controller.rate == 1.5 && controller.volume == 0.8 && controller.enhancementMode == .clarity)
        controller.pause()
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            if !condition { failures.append(name); print("FAIL: \(name)") }
        }
        func waitUntil(_ predicate: () -> Bool) async -> Bool {
            for _ in 0..<80 {
                if predicate() { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }
        let media = directory.appendingPathComponent("silent-120s.wav")
        try silentWave(seconds: 120).write(to: media)
        controller.open(url: media, title: "Retry Smoke", episode: "Local", resume: 37)
        controller.volume = 0.37
        controller.loadSubtitles(subtitle)
        controller.subtitleOffset = 1.5
        let initiallyReady = await waitUntil { controller.position >= 36.5 && controller.player.currentItem?.status == .readyToPlay }
        check(initiallyReady, "local media reaches the initial saved position")
        controller.pause()
        let pausedPosition = controller.position
        controller.retry()
        check(controller.player.rate == 0, "paused retry does not start playback synchronously")
        let retriedReady = await waitUntil { controller.player.currentItem?.status == .readyToPlay && controller.position >= pausedPosition - 0.2 }
        check(retriedReady, "retry prepares and seeks the same media")
        try await Task.sleep(nanoseconds: 700_000_000)
        check(controller.player.rate == 0 && !controller.isPlaying, "paused retry stays paused after media becomes ready")
        check(abs(controller.position - pausedPosition) < 0.25, "paused retry preserves the exact position without advancing")
        check(controller.subtitleText == "Smoke subtitle" && controller.externalSubtitleName == "test.srt" && controller.subtitleOffset == 1.5, "retry preserves active subtitle cues and offset")
        check(controller.rate == 1.5 && abs(controller.volume - 0.37) < 0.0001, "retry preserves current speed and volume")
        controller.pause()

        // A retry during preparation must not discard an unapplied resume seek.
        controller.open(url: media, title: "Pending Retry", episode: "Local", resume: 52)
        controller.pause()
        controller.retry()
        let pendingReached = await waitUntil { controller.player.currentItem?.status == .readyToPlay && abs(controller.position - 52) < 0.25 }
        check(pendingReached && controller.player.rate == 0, "retry while preparing preserves pending position and paused state")
        controller.pause()

        // The real failed-item handler clears playback intent and sets a fatal error.
        // Recreate that public error state on playable local media to verify recovery.
        controller.error = "Simulated fatal media transport error"
        controller.retry()
        let errorRecovered = await waitUntil { controller.isPlaying && controller.position > 52.2 }
        check(errorRecovered && controller.error == nil, "fatal-error retry resumes playback even after failure cleared playback intent")
        controller.pause()
        if failures.isEmpty { print("CONTROLLER_SMOKE_PASS: validated preferences, mute restore, timer cancel, nonfatal subtitle notice, paused retry position/subtitles/preferences, pending seek preservation, fatal-error retry playback") }
        else { print("CONTROLLER_SMOKE_FAILED: \(failures.count) assertions"); exit(1) }
    }

    private static func silentWave(seconds: Int) -> Data {
        let bytes = seconds * 8_000 * 2
        var data = Data("RIFF".utf8)
        func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        word(UInt32(36 + bytes)); data.append(Data("WAVEfmt ".utf8))
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(8_000)); word(UInt32(16_000)); word(UInt16(2)); word(UInt16(16))
        data.append(Data("data".utf8)); word(UInt32(bytes)); data.append(Data(count: bytes))
        return data
    }
}
