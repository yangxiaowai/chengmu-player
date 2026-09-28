// Headless local-media state regression; no window, network, or GPU processing.
// Compile against the existing Debug CinemaCore library:
// swiftc -parse-as-library -target arm64-apple-macos15.0 -I .build/out/Products/Debug -L .build/out/Products/Debug -lCinemaCore Sources/CinemaApp/PlaybackController.swift Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/TemporalRestorer.swift Tests/AppModelSmoke/AdCleanupStateSmoke.swift -o /tmp/ad-cleanup-state-smoke
// /tmp/ad-cleanup-state-smoke --validate
import Foundation
import AVFoundation
import CinemaCore

@main
struct AdCleanupStateSmoke {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Check: Encodable { let name: String; let passed: Bool; let detail: String }
    struct Summary: Encodable {
        let checkedAt: String
        let mode = "headless real PlaybackController with generated silent local WAV"
        let networkRequestsMade = false
        let nativeUIVerified = false
        let gpuProcessingVerified = false
        let actualSleepDeadlineElapsed = false
        let preferencesIsolated = true
        let passed: Bool
        let checks: [Check]
    }

    @MainActor static func main() async {
        guard CommandLine.arguments.contains("--validate") else {
            FileHandle.standardError.write(Data("Run with --validate to isolate playback preferences.\n".utf8))
            exit(2)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CinemaAdState-" + UUID().uuidString)
        var checks: [Check] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let media = directory.appendingPathComponent("silent-60s.wav")
            try silentWave(seconds: 60).write(to: media)
            let controller = PlaybackController()
            defer { controller.pause(); controller.cancelSleepTimer() }
            let cases: [(String, @MainActor () async throws -> String)] = [
                ("normal_editor_pause_can_resume_immediately", {
                    try await openAndPlay(controller, media)
                    controller.pause()
                    let intent = controller.playbackIntentID
                    controller.resumeAfterEditing(ifUnchanged: intent)
                    try require(controller.playbackRequested, "Normal editor completion did not restore playback intent immediately after pause")
                    try await eventually("normal editing resumes the real player") { controller.isPlaying && controller.player.rate > 0 }
                    return "An editor-owned pause restored playback intent without waiting for the published isPlaying observation to settle."
                }),
                ("normal_editor_pause_can_resume_after_settling", {
                    try await openAndPlay(controller, media)
                    controller.pause()
                    let intent = controller.playbackIntentID
                    try await eventually("editor pause settles") { !controller.isPlaying && controller.player.rate == 0 }
                    controller.resumeAfterEditing(ifUnchanged: intent)
                    try require(controller.playbackRequested, "Unchanged editor pause was not resumed")
                    try await eventually("settled editor resumes") { controller.isPlaying && controller.player.rate > 0 }
                    return "An unchanged paused intent resumes once; normal asynchronous AVPlayer observations do not block it."
                }),
                ("external_repeated_pause_invalidates_editor_resume", {
                    try await openAndPlay(controller, media)
                    controller.pause()
                    let editorIntent = controller.playbackIntentID
                    try require(!controller.playbackRequested, "Editor did not pause playback")
                    controller.pause() // Also the operation used when the sleep timer expires.
                    let externalIntent = controller.playbackIntentID
                    try require(externalIntent != editorIntent, "Repeated false assignment did not invalidate the editor token")
                    controller.resumeAfterEditing(ifUnchanged: editorIntent)
                    try require(!controller.playbackRequested && controller.player.rate == 0, "Old editor token overrode an external pause")
                    controller.pause()
                    try require(controller.playbackIntentID != externalIntent, "A second repeated pause reused its intent token")
                    return "Each pause, including false-to-false, invalidates the editor token. This tests the sleep timer's shared pause operation, not a real elapsed sleep deadline."
                }),
                ("media_failure_blocks_editor_resume", {
                    try await openAndPlay(controller, media)
                    controller.pause()
                    let intent = controller.playbackIntentID
                    guard let item = controller.player.currentItem else { throw Failure(description: "Missing local media item") }
                    // Exercise the real observer, rather than directly assigning controller.error.
                    NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item)
                    try await eventually("failed-to-end observer sets the playback error") { controller.error != nil }
                    controller.resumeAfterEditing(ifUnchanged: intent)
                    try require(!controller.playbackRequested && controller.player.rate == 0, "Editor completion resumed after media failure")
                    return "The real failed-to-end notification handler produced an error and the editor could not restart playback."
                }),
                ("failed_item_invalidates_editor_intent", {
                    controller.open(url: directory.appendingPathComponent("missing-file.wav"), title: "Failure fixture", episode: "Local")
                    controller.pause()
                    let intent = controller.playbackIntentID
                    try await eventually("missing local item fails") { controller.player.currentItem?.status == .failed && controller.error != nil }
                    try require(controller.playbackIntentID != intent, "Failed-item status did not invalidate the prior editor intent")
                    controller.resumeAfterEditing(ifUnchanged: intent)
                    try require(!controller.playbackRequested && controller.player.rate == 0, "Failed local item restarted from an obsolete editor intent")
                    return "An actual failed local AVPlayerItem changed the intent token and rejected the prior editor completion."
                }),
                ("already_requested_playback_is_not_toggled_off", {
                    try await openAndPlay(controller, media)
                    let intent = controller.playbackIntentID
                    controller.resumeAfterEditing(ifUnchanged: intent)
                    try require(controller.playbackRequested && controller.playbackIntentID == intent, "Resume operation toggled or rewrote an already-playing intent")
                    return "Calling the guarded resume while playback is already requested leaves it playing."
                }),
                ("opening_a_new_item_clears_cleanup_and_stale_intent", {
                    try await openAndPlay(controller, media)
                    controller.adCleanup = selectedCleanup()
                    controller.pause()
                    let oldIntent = controller.playbackIntentID, oldItem = controller.itemID
                    controller.open(url: media, title: "Second title", episode: "Second episode")
                    controller.pause()
                    try require(controller.itemID != oldItem, "Opening a new item reused the previous item identity")
                    try require(controller.adCleanup == AdCleanupSettings(), "New item retained advertisement or subtitle protection selections")
                    controller.resumeAfterEditing(ifUnchanged: oldIntent)
                    try require(!controller.playbackRequested && controller.player.rate == 0, "Previous item's editor completion resumed the new item")
                    return "New-item open resets all cleanup settings to defaults and an old editor token cannot resume that item."
                }),
                ("retry_preserves_cleanup_and_paused_state", {
                    try await openAndPlay(controller, media)
                    let settings = selectedCleanup()
                    controller.adCleanup = settings
                    controller.pause()
                    let intent = controller.playbackIntentID, oldItem = controller.itemID
                    controller.retry()
                    try require(controller.itemID != oldItem, "Retry did not replace the media item")
                    try require(controller.adCleanup == settings, "Retry synchronously discarded cleanup settings")
                    try require(!controller.playbackRequested && controller.player.rate == 0, "Paused retry requested playback")
                    try await eventually("retried local item becomes ready") { controller.player.currentItem?.status == .readyToPlay && !controller.isLoading }
                    try require(controller.adCleanup == settings, "Preparing a retry discarded cleanup settings")
                    controller.resumeAfterEditing(ifUnchanged: intent)
                    try require(!controller.playbackRequested && controller.player.rate == 0, "Pre-retry editor token resumed the replacement item")
                    return "Retry preserved enabled state, ad selections and custom protection regions after preparation, while retaining pause and rejecting the old editor token."
                })
            ]
            for (name, body) in cases {
                do { checks.append(Check(name: name, passed: true, detail: try await body())) }
                catch { checks.append(Check(name: name, passed: false, detail: String(describing: error))) }
                controller.pause()
            }
        } catch { checks.append(Check(name: "fixture_setup", passed: false, detail: String(describing: error))) }
        let passed = checks.count == 8 && checks.allSatisfy(\.passed)
        let summary = Summary(checkedAt: ISO8601DateFormatter().string(from: Date()), passed: passed, checks: checks)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(summary) + Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Could not encode state smoke evidence: \(error)\n".utf8))
            exit(1)
        }
        exit(passed ? 0 : 1)
    }

    @MainActor private static func openAndPlay(_ controller: PlaybackController, _ media: URL) async throws {
        controller.open(url: media, title: "Advertisement state fixture", episode: "Local")
        try await eventually("generated local WAV is ready and playing") {
            controller.player.currentItem?.status == .readyToPlay && controller.isPlaying && controller.playbackRequested
        }
        try require(controller.error == nil, "Unexpected local media error before state test")
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    @MainActor private static func eventually(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        repeat {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        } while Date() < deadline
        throw Failure(description: "Timed out: " + message)
    }
    private static func selectedCleanup() -> AdCleanupSettings {
        AdCleanupSettings(enabled: true,
                          regions: [NormalizedVideoRect(x: 0.05, y: 0.05, width: 0.15, height: 0.1)],
                          protectedRegions: [AdCleanupSettings.defaultProtection, NormalizedVideoRect(x: 0.5, y: 0.3, width: 0.4, height: 0.08)])
    }
    private static func silentWave(seconds: Int) -> Data {
        let bytes = seconds * 8_000 * 2
        var data = Data("RIFF".utf8)
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        word(UInt32(36 + bytes)); data.append(Data("WAVEfmt ".utf8))
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(8_000)); word(UInt32(16_000)); word(UInt16(2)); word(UInt16(16))
        data.append(Data("data".utf8)); word(UInt32(bytes)); data.append(Data(count: bytes))
        return data
    }
}
