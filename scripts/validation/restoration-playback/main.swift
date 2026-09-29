import Foundation
import AppKit
import AVFoundation
import CinemaCore

@main struct RestorationPlayback {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        guard CommandLine.arguments.count >= 3 else {
            fputs("Usage: check VIDEO REPORT.json [1280x720|1920x1080]\n", stderr)
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "RestorationPlayback", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture has no video track"])
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displaySize = CGRect(origin: .zero, size: naturalSize).applying(transform).size
        let sourceWidth = Int(displaySize.width.rounded()), sourceHeight = Int(displaySize.height.rounded())
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        guard nominalFrameRate.isFinite && nominalFrameRate > 0 else {
            throw NSError(domain: "RestorationPlayback", code: 3, userInfo: [NSLocalizedDescriptionKey: "Fixture has no valid nominal frame rate"])
        }
        let frameBudgetMS = 1000.0 / Double(nominalFrameRate)
        let actualSize = "\(sourceWidth)x\(sourceHeight)"
        if CommandLine.arguments.count > 3, CommandLine.arguments[3] != actualSize {
            throw NSError(domain: "RestorationPlayback", code: 2, userInfo: [NSLocalizedDescriptionKey: "Fixture size \(actualSize) differs from requested \(CommandLine.arguments[3])"])
        }
        var checks: [[String: Any]] = [], samples: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail])
            print(passed ? "PASS" : "FAIL", name, detail)
        }
        for mode in [EnhancementMode.temporal, .restoration, .compression] {
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
            while view.diagnosticMetrics.processedFrames < 24 && view.diagnosticMetrics.fallbackReason == nil && Date() < deadline {
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            let start = player.currentTime().seconds, frameStart = view.diagnosticMetrics.processedFrames
            var latency: [Double] = [], milliseconds: [Double] = []
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 100_000_000)
                if latest.presentationTime > 0 {
                    latency.append(player.currentTime().seconds - latest.presentationTime)
                    milliseconds.append(latest.processingMS)
                }
            }
            let windowEnd = view.diagnosticMetrics
            let windowCompletedFrames = windowEnd.processedFrames - frameStart
            let mediaAdvancedSeconds = player.currentTime().seconds - start
            let completedFramesPerMediaSecond = mediaAdvancedSeconds > 0 ? Double(windowCompletedFrames) / mediaAdvancedSeconds : 0
            let sampledProcessingMeanMS = milliseconds.reduce(0,+) / Double(max(1,milliseconds.count))
            check(mode.rawValue + "_sampled_processing_fits_frame_budget", sampledProcessingMeanMS < frameBudgetMS,
                  "sampledMeanMS=\(sampledProcessingMeanMS) nominalFrameBudgetMS=\(frameBudgetMS)")
            check(mode.rawValue + "_keeps_processing_during_playback", windowEnd.processedFrames - frameStart >= 45 && windowEnd.fallbackReason == nil && player.rate == 1,
                  "frames=\(windowEnd.processedFrames - frameStart) mediaAdvanced=\(player.currentTime().seconds - start) fallback=\(windowEnd.fallbackReason ?? "none")")
            check(mode.rawValue + "_reports_actual_restoration", windowEnd.mode.contains("时域降噪") && windowEnd.outputWidth > 0 && view.diagnosticState.hasEnhancedFrame, windowEnd.mode)
            if mode.usesRestorationScaling {
                check(mode.rawValue + "_outputs_actual_3840x2160", windowEnd.outputWidth == 3840 && windowEnd.outputHeight == 2160 && view.diagnosticState.hasEnhancedFrame,
                      "input=\(actualSize) completedOutput=\(windowEnd.outputWidth)x\(windowEnd.outputHeight)")
                check(mode.rawValue + "_reports_non_ai_detail_scaling", windowEnd.mode.contains("细节缩放") && windowEnd.mode.contains("非 AI"), windowEnd.mode)
            }
            if mode == .compression {
                check("compression_reports_extra_cleanup", windowEnd.mode.contains("压缩抑噪"), windowEnd.mode)
            }
            samples.append(["mode": mode.rawValue, "source": [sourceWidth, sourceHeight], "completedFrames": windowEnd.processedFrames, "output": [windowEnd.outputWidth, windowEnd.outputHeight], "droppedTicks": windowEnd.droppedFrames,
                            "windowStartCompletedFrames": frameStart, "windowEndCompletedFrames": windowEnd.processedFrames,
                            "windowCompletedFrames": windowCompletedFrames, "mediaAdvancedSeconds": mediaAdvancedSeconds,
                            "completedFramesPerMediaSecond": completedFramesPerMediaSecond, "frameBudgetMS": frameBudgetMS,
                            "sampledProcessingMeanMS": sampledProcessingMeanMS, "sampledMetricAgeMaxSeconds": latency.max() ?? 0,
                            "note": "Window counts use current main-actor counter snapshots at both boundaries, not throttled UI callbacks and not displayed FPS. Processing mean remains sampled from throttled metrics, not throughput. Metric age includes throttled metrics publication; not physical display or perceptual AV sync."])
            player.pause()
            let target = CMTime(seconds: 2, preferredTimescale: 600)
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            configure(mode, UUID())
            let pausedDeadline = Date().addingTimeInterval(4)
            while !view.diagnosticState.hasEnhancedFrame && Date() < pausedDeadline { try await Task.sleep(nanoseconds: 30_000_000) }
            let pausedMetrics = view.diagnosticMetrics
            check(mode.rawValue + "_paused_seek_rebuilds_without_old_reference", pausedMetrics.mode.contains("参考建立中") && player.rate == 0 && abs(player.currentTime().seconds - 2) < 0.1, pausedMetrics.mode)
            let stableOutput = item.outputs.compactMap({ $0 as? AVPlayerItemVideoOutput }).first
            let comparisonPosition = player.currentTime().seconds
            configure(.original, UUID())
            // SDR retains one item-owned output to avoid AVFoundation time jumps; no processing
            // work may be submitted or displayed, including a late result from the prior mode.
            try await Task.sleep(nanoseconds: 250_000_000)
            let comparisonOutputs = item.outputs.compactMap({ $0 as? AVPlayerItemVideoOutput })
            check(mode.rawValue + "_comparison_preserves_stable_output_without_processing", stableOutput != nil && comparisonOutputs.count == 1 && comparisonOutputs.first === stableOutput && view.diagnosticState.isNativeVisible && !view.diagnosticState.hasEnhancedFrame && view.diagnosticMetrics.processedFrames == 0 && player.currentItem === item && abs(player.currentTime().seconds - comparisonPosition) < 0.02,
                  "outputs=\(comparisonOutputs.count) positionBefore=\(comparisonPosition) positionAfter=\(player.currentTime().seconds)")
            configure(mode, UUID())
            player.playImmediately(atRate: 1)
            let resumeDeadline = Date().addingTimeInterval(4)
            while view.diagnosticMetrics.processedFrames < 12 && Date() < resumeDeadline { try await Task.sleep(nanoseconds: 30_000_000) }
            let resumedMetrics = view.diagnosticMetrics
            check(mode.rawValue + "_resumes_after_comparison", resumedMetrics.processedFrames >= 12 && resumedMetrics.fallbackReason == nil && resumedMetrics.mode.contains("时域降噪"), resumedMetrics.mode)
            player.pause(); view.stop()
        }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": checks, "samples": samples, "source": ["width": sourceWidth, "height": sourceHeight, "nominalFrameRate": nominalFrameRate], "scope": "Headless real AVPlayer + CinemaVideoView on synthetic tagged SDR \(actualSize) at nominal \(nominalFrameRate) fps. Completed processing / reported completed-frame dimensions / frame routing / paused seek / original comparison. No visible screen, audible sync or long-film validation."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        if !passed { exit(1) }
    }
}
