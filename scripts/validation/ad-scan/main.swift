import Foundation
import AVFoundation
import CinemaCore
@main struct AdScanSmoke {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let hls = URL(string: CommandLine.arguments[2])!
        let report = URL(fileURLWithPath: CommandLine.arguments[3])
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") { checks.append(["name": name, "passed": passed, "detail": detail]); print(passed ? "PASS" : "FAIL", name, detail) }
#if AD_SCAN_BASELINE
        check("real_ocr_detects_inserted_advertisement", false, "No scanner exists in the baseline application")
        check("ordinary_hls_detects_inserted_advertisement", false, "No scanner exists in the baseline application")
#else
        let analyzer = AdFrameAnalyzer()
        for (name, expected) in [("advertisement", AdFrameClassification.advertisement), ("ordinary", .ordinary), ("subtitle", .ordinary), ("corner", .ordinary), ("brand", .ordinary)] {
            analyzer.configure(url: directory.appendingPathComponent(name + ".mp4"))
            let started = Date()
            let result = await analyzer.analyze(time: 1, protectedRegions: [AdCleanupSettings.defaultProtection])
            check("real_ocr_" + name, result.classification == expected, "actual=\(result.classification), PTS=\(result.time), seconds=\(Date().timeIntervalSince(started)), error=\(analyzer.lastFailure ?? "none")")
        }
        analyzer.configure(url: directory.appendingPathComponent("advertisement.mp4"))
        let protected = await analyzer.analyze(time: 1, protectedRegions: [NormalizedVideoRect(x: 0.2, y: 0.2, width: 0.65, height: 0.5)])
        check("custom_subtitle_protection_excludes_main_title", protected.classification == .ordinary)
        let local = directory.appendingPathComponent("sequence.mp4")
        for (name, url) in [("local_sequence", local), ("ordinary_hls", hls)] {
            analyzer.configure(url: url)
            var observations: [AdFrameObservation] = []
            for time in stride(from: 0.5, through: 38.5, by: 2) {
                observations.append(await analyzer.analyze(time: time, protectedRegions: [AdCleanupSettings.defaultProtection]))
            }
            let segments = AdSegmentPolicy.segments(from: observations)
            check(name + "_detects_inserted_advertisement", segments.count == 1 && segments.allSatisfy { $0.start >= 16 && $0.end < 28 }, "segments=\(segments.map { "\($0.start)-\($0.end)" }), samples=\(observations.map { "\($0.time):\($0.classification)" })")
        }
        analyzer.configure(url: hls)
        let cancelledRead = Task { @MainActor in await analyzer.analyze(time: 18, protectedRegions: []) }
        try await Task.sleep(nanoseconds: 20_000_000)
        analyzer.cancel()
        let cancelledFrame = await cancelledRead.value
        check("cancelled_frame_is_unknown", cancelledFrame.classification == .unknown)
        let controller = AdSkipController()
        controller.configure(url: local, itemID: UUID(), protectedRegions: [AdCleanupSettings.defaultProtection])
        controller.update(position: 0, duration: 40, shouldScan: true)
        let deadline = Date().addingTimeInterval(35)
        while controller.segments.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        check("controller_confirms_advertisement", controller.segments.count == 1, controller.status)
        let segmentsBefore = controller.segments
        controller.update(position: 0, duration: 40, shouldScan: false)
        let analyzedBefore = controller.analyzedFrames
        try await Task.sleep(nanoseconds: 700_000_000)
        check("pause_retains_confirmed_segments_and_stops_work", controller.segments == segmentsBefore && controller.analyzedFrames == analyzedBefore)
        controller.configure(url: directory.appendingPathComponent("ordinary.mp4"), itemID: UUID(), protectedRegions: [AdCleanupSettings.defaultProtection])
        check("item_change_clears_old_results", controller.segments.isEmpty && controller.analyzedFrames == 0)
        controller.update(position: 0, duration: 3, shouldScan: true)
        controller.stop()
        try await Task.sleep(nanoseconds: 700_000_000)
        check("stop_rejects_late_results", controller.segments.isEmpty && controller.analyzedFrames == 0)
        analyzer.configure(url: hls.deletingLastPathComponent().appendingPathComponent("missing.m3u8"))
        let failure = await analyzer.analyze(time: 1, protectedRegions: [])
        check("failed_frame_is_unknown", failure.classification == .unknown && analyzer.lastFailure != nil)
        analyzer.cancel()
#endif
        let failures = checks.filter { !($0["passed"] as! Bool) }
        let output: [String: Any] = ["passed": failures.isEmpty, "checks": checks, "scope": "Synthetic Chinese cards, local MP4 and ordinary loopback HTTP HLS; no real provider advertisement accuracy claim"]
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        if !failures.isEmpty { exit(1) }
    }
}
