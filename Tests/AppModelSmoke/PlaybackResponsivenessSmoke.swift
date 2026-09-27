// Headless responsiveness regression using real PlaybackController + local AVPlayer.
// Link the existing Debug CinemaCore, then run with --validate to isolate preferences.
import Foundation
import AVFoundation
import Combine
import CinemaCore

@main
struct PlaybackResponsivenessSmoke {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Check: Encodable { let name: String; let passed: Bool; let detail: String }
    struct Summary: Encodable {
        let checkedAt: String
        let mode = "headless real controller and generated silent local WAV"
        let nativeUIVerified = false
        let networkRequestsMade = false
        let passed: Bool
        let checks: [Check]
    }
    @MainActor static func main() async {
        guard CommandLine.arguments.contains("--validate") else { print("--validate is required"); exit(2) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CinemaResponsiveness-" + UUID().uuidString)
        var checks: [Check] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let media = directory.appendingPathComponent("silent-120s.wav")
            try silentWave(seconds: 120).write(to: media)
            let controller = PlaybackController()
            defer { controller.pause() }
            let cases: [(String, @MainActor () async throws -> String)] = [
                ("rapid_pause_play_preserves_both_button_intents", {
                    controller.open(url: media, title: "Responsiveness", episode: "Local")
                    try await eventually("local playback starts") { controller.player.currentItem?.status == .readyToPlay && controller.isPlaying }
                    controller.togglePlayback()
                    try require(!controller.playbackRequested, "First press did not request pause")
                    let paused = snapshot(controller)
                    controller.togglePlayback()
                    try require(controller.playbackRequested, "Second press was lost before KVO settled. After first: \(paused); after second: \(snapshot(controller))")
                    try await eventually("second press actually resumes") { controller.isPlaying && controller.player.rate > 0 }
                    return "Two immediate presses from playing pause and then resume without depending on KVO latency."
                }),
                ("synchronous_skip_burst_accumulates_each_press", {
                    try await preparePaused(controller, media: media)
                    controller.skip(10); controller.skip(10); controller.skip(10)
                    try require(abs(controller.position - 50) < 0.25, "Immediate three-press target was \(controller.position), expected 50")
                    try await eventually("three skips reach 50 seconds") { abs(controller.player.currentTime().seconds - 50) < 0.25 }
                    return "Three synchronous +10-second presses from 20 seconds reach 50 seconds."
                }),
                ("yielding_skip_bursts_do_not_lose_a_press_to_old_positions", {
                    var trials = 0
                    for delay in [UInt64(0), 1_000_000, 5_000_000, 20_000_000] {
                        for _ in 0..<8 {
                            try await preparePaused(controller, media: media)
                            var positions: [Double] = []
                            for _ in 0..<3 {
                                controller.skip(10)
                                positions.append(controller.position)
                                if delay == 0 { await Task.yield() }
                                else { try await Task.sleep(nanoseconds: delay) }
                                positions.append(controller.position)
                            }
                            try await eventually("skip burst finishes seeking") {
                                abs(controller.player.currentTime().seconds - controller.position) < 0.25
                            }
                            let actual = controller.player.currentTime().seconds
                            try require(abs(actual - 50) < 0.25, "A skip was lost with \(delay) ns between presses: positions=\(positions), final media time=\(actual), expected 50")
                            trials += 1
                        }
                    }
                    return "\(trials) real-media bursts with task yields and 1/5/20 ms intervals each preserved all three +10-second requests."
                }),
                ("intent_changes_publish_without_waiting_for_KVO", {
                    try await preparePaused(controller, media: media)
                    var notifications = 0
                    let subscription = controller.objectWillChange.sink { notifications += 1 }
                    defer { subscription.cancel() }
                    controller.togglePlayback()
                    try require(controller.playbackRequested && notifications > 0, "Play intent did not publish an immediate UI invalidation")
                    let afterPlay = notifications
                    controller.togglePlayback()
                    try require(!controller.playbackRequested && notifications > afterPlay, "Pause intent did not publish an immediate UI invalidation")
                    return "Both play and pause notify SwiftUI synchronously, independently of the observed physical playback state."
                }),
                ("rapid_seek_direction_changes_keep_latest_target", {
                    try await preparePaused(controller, media: media)
                    controller.seek(to: 70)
                    await Task.yield()
                    controller.skip(-10)
                    await Task.yield()
                    controller.seek(to: 25)
                    await Task.yield()
                    controller.skip(-10)
                    try await eventually("latest seek-backward request reaches 15 seconds") { abs(controller.player.currentTime().seconds - 15) < 0.25 }
                    try await Task.sleep(nanoseconds: 30_000_000)
                    try require(abs(controller.position - 15) < 0.25, "Older forward seek overwrote the latest 15-second target: \(snapshot(controller))")
                    return "Forward seek, backward skip, absolute seek and another backward skip commit only the final 15-second destination."
                }),
                ("cancelled_seek_does_not_seed_the_next_skip", {
                    try await preparePaused(controller, media: media)
                    controller.seek(to: 90)
                    controller.cancelPendingSeek()
                    try await Task.sleep(nanoseconds: 40_000_000)
                    let actual = controller.player.currentTime().seconds
                    try require(abs(controller.position - actual) < 0.25, "Canceled target remained displayed instead of actual media time")
                    controller.skip(10)
                    let target = min(120, actual + 10)
                    try await eventually("skip after cancellation starts at actual media time") { abs(controller.player.currentTime().seconds - target) < 0.25 }
                    return "Cancel reconciles with actual media time and the next skip does not reuse a discarded target."
                }),
                ("interrupted_latest_seek_recovers_actual_position", {
                    try await preparePaused(controller, media: media)
                    controller.seek(to: 90)
                    controller.player.currentItem?.cancelPendingSeeks()
                    try await Task.sleep(nanoseconds: 40_000_000)
                    let actual = controller.player.currentTime().seconds
                    try require(abs(controller.position - actual) < 0.25, "AVPlayer-canceled latest seek left a stale requested position")
                    controller.skip(-10)
                    let target = max(0, actual - 10)
                    try await eventually("skip after AVPlayer interruption uses actual position") { abs(controller.player.currentTime().seconds - target) < 0.25 }
                    return "An interrupted latest AVPlayer seek clears its pending destination and remains responsive to the next backward skip."
                }),
                ("new_item_discards_previous_seek_state", {
                    try await preparePaused(controller, media: media)
                    controller.seek(to: 90)
                    controller.open(url: media, title: "Replacement item", episode: "New", resume: 7)
                    controller.pause()
                    try await eventually("replacement item reaches its own resume position") {
                        controller.player.currentItem?.status == .readyToPlay && abs(controller.player.currentTime().seconds - 7) < 0.25
                    }
                    controller.skip(10)
                    try await eventually("replacement skip uses seven seconds rather than old target") { abs(controller.player.currentTime().seconds - 17) < 0.25 }
                    try await Task.sleep(nanoseconds: 30_000_000)
                    try require(abs(controller.position - 17) < 0.25, "Old item's callback changed replacement position")
                    return "Opening a replacement item resets pending seek state; its own seven-second resume plus one skip reaches 17 seconds."
                })
            ]
            for (name, body) in cases {
                do { checks.append(Check(name: name, passed: true, detail: try await body())) }
                catch { checks.append(Check(name: name, passed: false, detail: String(describing: error))) }
                controller.pause()
            }
        } catch { checks.append(Check(name: "fixture_setup", passed: false, detail: String(describing: error))) }
        let passed = checks.count == 8 && checks.allSatisfy(\.passed)
        let report = Summary(checkedAt: ISO8601DateFormatter().string(from: Date()), passed: passed, checks: checks)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(report) + Data("\n".utf8))
        } catch { print(error); exit(1) }
        exit(passed ? 0 : 1)
    }
    @MainActor private static func preparePaused(_ controller: PlaybackController, media: URL) async throws {
        controller.open(url: media, title: "Skip fixture", episode: "Local", resume: 20)
        controller.pause()
        try await eventually("paused fixture is actually positioned at 20 seconds") {
            controller.player.currentItem?.status == .readyToPlay && !controller.isPlaying
                && abs(controller.player.currentTime().seconds - 20) < 0.25 && abs(controller.position - 20) < 0.25
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    @MainActor private static func snapshot(_ controller: PlaybackController) -> String {
        "requested=\(controller.playbackRequested), observedPlaying=\(controller.isPlaying), rate=\(controller.player.rate), position=\(controller.position)"
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    @MainActor private static func eventually(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        throw Failure(description: "Timed out: " + message)
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
