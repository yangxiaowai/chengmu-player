import Foundation
import AppKit
import AVFoundation
import CinemaCore

@main struct RestorationPlayback {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks: [[String: Any]] = [], samples: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail])
            print(passed ? "PASS" : "FAIL", name, detail)
        }
        for mode in [EnhancementMode.temporal, .restoration] {
            let item = AVPlayerItem(url: url), generation = UUID()
            let player = AVPlayer(playerItem: item); player.isMuted = true
            let view = CinemaVideoView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
            var latest = EnhancementMetrics()
            func configure(_ requested: EnhancementMode, _ token: UUID = generation) {
                view.configure(player: player, mode: requested, generation: token, permission: .inspectSDRFrames, assessedItem: item, onMetrics: { latest = $0 })
            }
            configure(mode)
            player.playImmediately(atRate: 1)
            let deadline = Date().addingTimeInterval(10)
            while latest.processedFrames < 24 && latest.fallbackReason == nil && Date() < deadline {
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            let start = player.currentTime().seconds, frameStart = latest.processedFrames
            var latency: [Double] = [], milliseconds: [Double] = []
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if latest.presentationTime > 0 {
                    latency.append(player.currentTime().seconds - latest.presentationTime)
                    milliseconds.append(latest.processingMS)
                }
            }
            check(mode.rawValue + "_keeps_processing_during_playback", latest.processedFrames - frameStart >= 45 && latest.fallbackReason == nil && player.rate == 1,
                  "frames=\(latest.processedFrames - frameStart) mediaAdvanced=\(player.currentTime().seconds - start) fallback=\(latest.fallbackReason ?? "none")")
            check(mode.rawValue + "_reports_actual_restoration", latest.mode.contains("时域降噪") && latest.outputWidth > 0 && view.diagnosticState.hasEnhancedFrame, latest.mode)
            samples.append(["mode": mode.rawValue, "completedFrames": latest.processedFrames, "output": [latest.outputWidth, latest.outputHeight], "droppedTicks": latest.droppedFrames,
                            "sampledProcessingMeanMS": milliseconds.reduce(0,+) / Double(max(1,milliseconds.count)), "sampledMetricAgeMaxSeconds": latency.max() ?? 0,
                            "note": "Metric age includes throttled metrics publication; not physical display or perceptual AV sync."])
            player.pause()
            let target = CMTime(seconds: 2, preferredTimescale: 600)
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            configure(mode, UUID())
            let pausedDeadline = Date().addingTimeInterval(4)
            while !view.diagnosticState.hasEnhancedFrame && Date() < pausedDeadline { try await Task.sleep(nanoseconds: 30_000_000) }
            check(mode.rawValue + "_paused_seek_rebuilds_without_old_reference", latest.mode.contains("参考建立中") && player.rate == 0 && abs(player.currentTime().seconds - 2) < 0.1, latest.mode)
            configure(.original, UUID())
            // The surface detaches on its next 60 Hz tick; configure already restores the native layer.
            let comparisonDeadline = Date().addingTimeInterval(1)
            while !item.outputs.compactMap({ $0 as? AVPlayerItemVideoOutput }).isEmpty && Date() < comparisonDeadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            check(mode.rawValue + "_comparison_detaches_processing", item.outputs.compactMap({ $0 as? AVPlayerItemVideoOutput }).isEmpty && view.diagnosticState.isNativeVisible && player.currentItem === item)
            configure(mode, UUID())
            player.playImmediately(atRate: 1)
            let resumeDeadline = Date().addingTimeInterval(4)
            while latest.processedFrames < 12 && Date() < resumeDeadline { try await Task.sleep(nanoseconds: 30_000_000) }
            check(mode.rawValue + "_resumes_after_comparison", latest.processedFrames >= 12 && latest.fallbackReason == nil && latest.mode.contains("时域降噪"), latest.mode)
            player.pause(); view.stop()
        }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": checks, "samples": samples, "scope": "Headless real AVPlayer + CinemaVideoView on synthetic tagged SDR720p24. Completed processing / frame routing / paused seek / original comparison. No visible screen, audible sync or long-film validation."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        if !passed { exit(1) }
    }
}
