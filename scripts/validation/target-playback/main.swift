import Foundation
import AppKit
import AVFoundation
import MetalKit
import CinemaCore

/// Visible NSWindow + real MTKView command-completion evidence. This is not a display scanout meter.
@main struct TargetPlaybackSmoke {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--diagnose-dual-player") || CommandLine.arguments.contains("--diagnose-dual-teardown") {
            try await diagnoseDualPlayer(teardown: CommandLine.arguments.contains("--diagnose-dual-teardown"))
            return
        }
        if CommandLine.arguments.contains("--diagnose-output") || CommandLine.arguments.contains("--diagnose-output-churn") {
            try await diagnoseOutput(churn: CommandLine.arguments.contains("--diagnose-output-churn"))
            return
        }
        if CommandLine.arguments.contains("--diagnose-clock") {
            try await diagnoseClock()
            return
        }
        let requestedHeight = Int(ProcessInfo.processInfo.environment["TARGET_PLAYBACK_RESOLUTION"] ?? "1080") ?? 0
        guard requestedHeight == 720 || requestedHeight == 1080 else {
            throw NSError(domain: "TargetPlaybackSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "TARGET_PLAYBACK_RESOLUTION must be 720 or 1080"])
        }
        let requestedResolution: EnhancementResolution = requestedHeight == 720 ? .hd720 : .fullHD
        let requestedWidth = requestedHeight == 720 ? 1280 : 1920
        let item = AVPlayerItem(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let player = AVPlayer(playerItem: item); player.isMuted = true
        let view = CinemaVideoView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "澄幕 · 插帧实际呈现验证"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { player.pause(); view.stop(); window.close() }
        let generation = UUID()
        var checks: [[String: Any]] = [], warmup: [[String: Any]] = [], presentations: [[String: Any]] = []
        var processingSamples: [[String: Any]] = []
        let trace = JumpTrace(phase: "warmup")
        let jumpObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped, object: item, queue: .main) { _ in
            trace.jumps.append(["phase": trace.phase, "clock": finite(player.currentTime().seconds), "wall": CACurrentMediaTime()])
        }
        defer { NotificationCenter.default.removeObserver(jumpObserver) }
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail])
            print(passed ? "PASS" : "FAIL", name, detail)
        }
        func configure(_ mode: EnhancementMode = .clarity, resolution: EnhancementResolution? = nil,
                       frameRate: EnhancementFrameRate = .fps60, split: Bool = false) {
            view.configure(player: player, mode: mode, generation: generation, permission: .inspectSDRFrames,
                           assessedItem: item, resolution: resolution ?? requestedResolution, frameRate: frameRate, splitComparison: split, onMetrics: { _ in })
        }
        func snapshot() -> [String: Any] {
            let m = view.diagnosticMetrics
            return ["clock": finite(player.currentTime().seconds), "clockValid": player.currentTime().isNumeric,
                    "player": playerState(player, item), "selectedPTS": finite(m.presentationTime),
                    "renderedFrames": m.renderedFrames, "processedFrames": m.processedFrames,
                    "drawablePresentedFrames": m.displayedFrames,
                    "reportedDrawableFPS": m.displayedFPS.map { $0 as Any } ?? NSNull(),
                    "interpolatedFrames": m.interpolatedFrames, "mode": m.mode,
                    "processingMS": finite(m.processingMS), "sourceFPS": finite(m.sourceFPS ?? 0),
                    "timing": m.timingNote ?? "", "fallback": m.fallbackReason ?? "",
                    "output": [m.outputWidth, m.outputHeight], "nativeVisible": view.diagnosticState.isNativeVisible]
        }
        configure()
        player.playImmediately(atRate: 1)
        check("real_window_hosts_metal_view", window.isVisible && view.subviews.contains { ($0 as? MTKView)?.window === window })
        let warmStart = CACurrentMediaTime(), warmDeadline = warmStart + 25
        var lastWarmSecond = -1
        var obsoleteWarmFrames = 0
        while CACurrentMediaTime() < warmDeadline {
            let m = view.diagnosticMetrics
            if m.renderedFrames >= 40, m.interpolatedFrames >= 10, m.outputWidth == requestedWidth, m.outputHeight == requestedHeight,
               m.mode.contains("60fps"), m.fallbackReason == nil { break }
            if view.diagnosticState.hasEnhancedFrame && player.currentTime().seconds - m.presentationTime > 0.3 { obsoleteWarmFrames += 1 }
            let second = Int(CACurrentMediaTime() - warmStart)
            if second != lastWarmSecond {
                lastWarmSecond = second; warmup.append(snapshot())
                print("WARM", second, m.renderedFrames, m.interpolatedFrames, "processingMS", m.processingMS,
                      "sourceFPS", m.sourceFPS ?? 0, m.timingNote ?? "", m.fallbackReason ?? "")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let ready = view.diagnosticMetrics
        check("interpolation_warms_within_25_seconds", ready.renderedFrames >= 40 && ready.interpolatedFrames >= 10 && ready.mode.contains("60fps"),
              "warmSeconds=\(CACurrentMediaTime()-warmStart) \(snapshot())")
        check("startup_does_not_show_obsolete_frames", obsoleteWarmFrames == 0, "obsolete sampled frames=\(obsoleteWarmFrames)")
        let sampleStart = CACurrentMediaTime(), startCount = ready.renderedFrames, startClock = player.currentTime().seconds
        trace.phase = "measure"
        var observedCount = startCount
        var observedProcessedCount = ready.processedFrames
        while CACurrentMediaTime() - sampleStart < 5 {
            let m = view.diagnosticMetrics
            if m.processedFrames != observedProcessedCount {
                processingSamples.append(["elapsed": CACurrentMediaTime() - sampleStart,
                                          "processedFrames": m.processedFrames, "processingMS": finite(m.processingMS),
                                          "sourceFPS": finite(m.sourceFPS ?? 0), "interpolatedFrames": m.interpolatedFrames,
                                          "timing": m.timingNote ?? ""])
                observedProcessedCount = m.processedFrames
            }
            if m.renderedFrames != observedCount {
                let completedPTS = field("lastRenderedPTS", of: view) as? Double
                presentations.append(["elapsed": CACurrentMediaTime() - sampleStart, "counter": m.renderedFrames,
                                      "pts": finite(completedPTS ?? m.presentationTime), "clock": finite(player.currentTime().seconds)])
                observedCount = m.renderedFrames
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let elapsed = CACurrentMediaTime() - sampleStart, end = view.diagnosticMetrics
        let rendered = end.renderedFrames - startCount
        let pts = presentations.compactMap { $0["pts"] as? Double }
        let lag = presentations.compactMap { row -> Double? in
            guard let clock = row["clock"] as? Double, let pts = row["pts"] as? Double else { return nil }; return clock - pts
        }
        let measuredFPS = Double(rendered) / elapsed
        let mediaAdvanced = player.currentTime().seconds - startClock
        let measurementJumps = trace.jumps.filter { $0["phase"] as? String == "measure" }.count
        check("primary_clock_advances_without_jump", mediaAdvanced >= 4.6 && mediaAdvanced <= 5.4 && measurementJumps == 0,
              "mediaSeconds=\(mediaAdvanced) TimeJumped=\(measurementJumps)")
        check("five_second_window_presents_near_60_unique_pts", rendered >= 250, "completed presentations=\(rendered) wallSeconds=\(elapsed) measuredFPS=\(measuredFPS)")
        check("presented_pts_are_strictly_increasing", pts.count >= 2 && zip(pts, pts.dropFirst()).allSatisfy { $1 > $0 })
        check("presented_pts_follow_60hz_grid", !pts.isEmpty && pts.allSatisfy { abs($0 * 60 - ($0 * 60).rounded()) < 0.0001 })
        check("completed_frame_clock_lag_is_bounded", !lag.isEmpty && (lag.max() ?? 100) < 0.14 && (lag.min() ?? -100) > -0.025,
              "min=\(lag.min() ?? 0) max=\(lag.max() ?? 0)")
        check("target_is_actual_\(requestedWidth)x\(requestedHeight)", end.outputWidth == requestedWidth && end.outputHeight == requestedHeight && end.fallbackReason == nil, "\(snapshot())")
        let windowSummary: [String: Any] = ["wallSeconds": elapsed, "mediaSeconds": mediaAdvanced,
                                          "completedPresentations": rendered, "sampledUniquePTS": pts.count, "measuredCompletedFPS": measuredFPS,
                                          "drawablePresentedFrames": end.displayedFrames - ready.displayedFrames,
                                          "measuredDrawablePresentedFPS": Double(end.displayedFrames - ready.displayedFrames) / elapsed,
                                          "reportedDrawableFPS": end.displayedFPS.map { $0 as Any } ?? NSNull(),
                                          "minClockMinusPTS": lag.min() ?? 0, "maxClockMinusPTS": lag.max() ?? 0]
        print("DRAWABLE_PRESENTED", end.displayedFrames - ready.displayedFrames,
              "measuredFPS", Double(end.displayedFrames - ready.displayedFrames) / elapsed,
              "reportedFPS", end.displayedFPS.map(String.init(describing:)) ?? "unavailable")
        trace.phase = "pause"; player.pause(); configure(split: true)
        let pauseDeadline = CACurrentMediaTime() + 6
        while !view.diagnosticState.hasEnhancedFrame && CACurrentMediaTime() < pauseDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let paused = view.diagnosticMetrics
        let current = field("currentFrame", of: view) as? EnhancedFrame
        check("paused_split_uses_same_frame_reference", player.rate == 0 && current?.originalImage != nil && !view.diagnosticState.isNativeVisible && abs(player.currentTime().seconds - paused.presentationTime) < 0.06,
              "\(snapshot())")
        let pausedPTS = paused.presentationTime, pausedCount = paused.renderedFrames
        try await Task.sleep(nanoseconds: 250_000_000)
        check("paused_split_stays_on_one_pts", view.diagnosticMetrics.presentationTime == pausedPTS && view.diagnosticMetrics.renderedFrames <= pausedCount + 1)
        trace.phase = "seek"; await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        let seekDeadline = CACurrentMediaTime() + 5
        while (abs(view.diagnosticMetrics.presentationTime - 2) > 0.06 || !view.diagnosticState.hasEnhancedFrame) && CACurrentMediaTime() < seekDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check("paused_seek_discards_future_revision", player.rate == 0 && abs(view.diagnosticMetrics.presentationTime - 2) <= 0.06 && view.diagnosticState.hasEnhancedFrame, "\(snapshot())")
        let beforeNativeClock = player.currentTime().seconds
        let stableOutput = item.outputs.compactMap { $0 as? AVPlayerItemVideoOutput }.first
        let beforeNativeJumps = trace.jumps.count
        trace.phase = "native"; configure(.original)
        try await Task.sleep(nanoseconds: 200_000_000)
        let nativeCount = view.diagnosticMetrics.renderedFrames
        try await Task.sleep(nanoseconds: 300_000_000)
        let nativeOutputs = item.outputs.compactMap { $0 as? AVPlayerItemVideoOutput }
        check("native_switch_reuses_output_and_rejects_late_results", view.diagnosticState.isNativeVisible && !view.diagnosticState.hasEnhancedFrame && nativeOutputs.count == 1 && nativeOutputs.first === stableOutput && view.diagnosticMetrics.renderedFrames == nativeCount)
        check("native_switch_preserves_position_without_time_jump", abs(player.currentTime().seconds - beforeNativeClock) < 0.03 && trace.jumps.count == beforeNativeJumps,
              "before=\(beforeNativeClock) after=\(player.currentTime().seconds) newTimeJumps=\(trace.jumps.count-beforeNativeJumps)")
        trace.phase = "4k"; configure(resolution: .ultraHD)
        player.playImmediately(atRate: 1)
        let largeDeadline = CACurrentMediaTime() + 8
        while view.diagnosticMetrics.timingNote?.contains("1080p") != true && CACurrentMediaTime() < largeDeadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let largeStart = player.currentTime().seconds
        try await Task.sleep(nanoseconds: 300_000_000)
        check("unsupported_4k60_explains_and_keeps_picture", view.diagnosticMetrics.timingNote?.contains("1080p") == true && player.currentTime().seconds > largeStart + 0.15 && (view.diagnosticState.isNativeVisible || view.diagnosticState.hasEnhancedFrame), "\(snapshot())")
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": checks, "warmup": warmup, "window": windowSummary, "presentations": presentations, "processingSamples": processingSamples, "timeJumps": trace.jumps,
                                   "requestedTarget": ["width": requestedWidth, "height": requestedHeight, "fps": 60, "mode": "clarity"],
                                   "scope": "NSWindow isVisible, MTKView, 24fps local tagged H264 and AVPlayer audio clock. GPU present-command completions and CAMetalDrawable presented callbacks are recorded separately; zero callbacks do not prove physical display presentation. Not physical display scanout or perceptual audio sync; no network or personal profile."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        if !passed { exit(1) }
    }
    static func field(_ name: String, of value: Any) -> Any? { Mirror(reflecting: value).children.first { $0.label == name }?.value }
    static func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }
    @MainActor static func playerState(_ player: AVPlayer, _ item: AVPlayerItem) -> [String: Any] {
        ["timeControlStatus": String(describing: player.timeControlStatus), "reasonForWaiting": player.reasonForWaitingToPlay?.rawValue ?? "",
         "rate": player.rate, "itemStatus": String(describing: item.status), "error": item.error?.localizedDescription ?? "",
         "clockValid": player.currentTime().isNumeric, "clockDescription": String(describing: player.currentTime()),
         "loadedTimeRanges": item.loadedTimeRanges.map { ["start": finite($0.timeRangeValue.start.seconds), "duration": finite($0.timeRangeValue.duration.seconds)] }]
    }
    @MainActor static func diagnoseClock() async throws {
        let item = AVPlayerItem(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let player = AVPlayer(playerItem: item); player.isMuted = true
        let view = CinemaVideoView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "澄幕 · 时钟对照"
        window.contentView = view; window.makeKeyAndOrderFront(nil)
        defer { player.pause(); view.stop(); window.close() }
        let generation = UUID()
        var samples: [[String: Any]] = []
        let trace = JumpTrace(phase: "source_fps")
        let jumpObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped, object: item, queue: .main) { _ in
            trace.jumps.append(["phase": trace.phase, "clock": finite(player.currentTime().seconds), "wall": CACurrentMediaTime()])
        }
        defer { NotificationCenter.default.removeObserver(jumpObserver) }
        for (name, target, seconds) in [("source_fps", EnhancementFrameRate.source, 5.0), ("fps60_after_clock_started", EnhancementFrameRate.fps60, 15.0)] {
            trace.phase = name
            view.configure(player: player, mode: .clarity, generation: generation, permission: .inspectSDRFrames,
                           assessedItem: item, resolution: .fullHD, frameRate: target, onMetrics: { _ in })
            if name == "source_fps" { player.playImmediately(atRate: 1) }
            let start = CACurrentMediaTime()
            while CACurrentMediaTime() - start < seconds {
                let m = view.diagnosticMetrics
                var row = playerState(player, item)
                row["phase"] = name; row["elapsed"] = CACurrentMediaTime() - start; row["clock"] = finite(player.currentTime().seconds)
                row["processedFrames"] = m.processedFrames; row["renderedFrames"] = m.renderedFrames
                row["interpolatedFrames"] = m.interpolatedFrames; row["selectedPTS"] = m.presentationTime
                row["fallback"] = m.fallbackReason ?? ""; row["timing"] = m.timingNote ?? ""
                row["prefetchCursor"] = field("prefetchCursor", of: view) as? Double ?? -1
                row["lastPrefetchedPTS"] = field("lastPrefetchedPTS", of: view) as? Double ?? -1
                if let queue = field("interpolationQueue", of: view) as? [(time: Double, frame: EnhancedFrame)] {
                    row["queuePTS"] = queue.map(\.time)
                }
                samples.append(row)
                print(name, String(format: "%.2f", CACurrentMediaTime() - start), row)
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        let report: [String: Any] = ["scope": "Same local tagged H264, source-fps clarity 5s then 60fps clarity 15s; no player wait policy override. Lock-screen status supplied separately by caller.", "samples": samples, "timeJumps": trace.jumps]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    @MainActor static func diagnoseOutput(churn: Bool) async throws {
        var runs: [[String: Any]] = []
        for ahead in (churn ? [0.0] : [0.0, 0.04, 0.22]) {
            let item = AVPlayerItem(url: URL(fileURLWithPath: CommandLine.arguments[1]))
            let player = AVPlayer(playerItem: item); player.isMuted = true
            let host = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 360)); host.wantsLayer = true
            let layer = AVPlayerLayer(player: player); layer.frame = host.bounds; host.layer?.addSublayer(layer)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "AVPlayerOutput +\(Int(ahead * 1000))ms"
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            let output = AVPlayerItemVideoOutput(outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: ColorFrameGate.outputPixelFormat, AVVideoAllowWideColorKey: true])
            output.suppressesPlayerRendering = false; item.add(output)
            player.playImmediately(atRate: 1)
            let readyDeadline = CACurrentMediaTime() + 3
            while player.currentTime().seconds < 0.25 && CACurrentMediaTime() < readyDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
            var jumps: [[String: Any]] = [], samples: [[String: Any]] = []
            let start = CACurrentMediaTime(), initialClock = player.currentTime().seconds
            let observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped, object: item, queue: .main) { _ in
                jumps.append(["wall": CACurrentMediaTime() - start, "clock": finite(player.currentTime().seconds)])
            }
            var lastPTS: Double?, copyCount = 0, transitions = 0, attached = true, nextChange = 0.5
            while CACurrentMediaTime() - start < 5 {
                if churn && CACurrentMediaTime() - start >= nextChange {
                    if attached { item.remove(output) } else { item.add(output) }
                    attached.toggle(); transitions += 1; nextChange += 0.5
                }
                let clock = player.currentTime().seconds
                let target = CMTime(seconds: clock + ahead, preferredTimescale: 60000)
                var presented = CMTime.invalid
                if attached && !churn && output.hasNewPixelBuffer(forItemTime: target), output.copyPixelBuffer(forItemTime: target, itemTimeForDisplay: &presented) != nil {
                    lastPTS = presented.seconds; copyCount += 1
                }
                var row = playerState(player, item)
                row["elapsed"] = CACurrentMediaTime() - start; row["clock"] = finite(player.currentTime().seconds)
                row["requestedPTS"] = finite(target.seconds); row["copiedPTS"] = lastPTS ?? -1
                row["outputAttached"] = attached; row["outputTransitions"] = transitions
                samples.append(row)
                try await Task.sleep(nanoseconds: 16_000_000)
            }
            NotificationCenter.default.removeObserver(observer)
            let advance = player.currentTime().seconds - initialClock
            let run: [String: Any] = ["lookaheadSeconds": ahead, "clockAdvance": finite(advance), "copiedFrames": copyCount,
                                    "outputTransitions": transitions, "timeJumpCount": jumps.count, "timeJumps": jumps, "samples": samples]
            runs.append(run)
            print("OUTPUT", ahead, "clockAdvance", advance, "copies", copyCount, "TimeJumped", jumps.count)
            player.pause(); if attached { item.remove(output) }; layer.player = nil; window.close()
        }
        let report: [String: Any] = ["scope": "AVPlayerLayer + one AVPlayerItemVideoOutput only; no EnhancementPipeline, FrameInterpolator, frame scheduling or playback controller. Same tagged local H264, each starts from fresh item and advances before 5s observation.", "outputChurnWithoutReads": churn, "runs": runs]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    @MainActor static func diagnoseDualPlayer(teardown: Bool) async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        var runs: [[String: Any]] = []
        for shared in [true, false] {
            let item = AVPlayerItem(asset: AVURLAsset(url: url))
            let player = AVPlayer(playerItem: item); player.isMuted = true
            func makeSecondary() -> (AVPlayerItem, AVPlayer, AVPlayerItemVideoOutput) {
                let secondItem = AVPlayerItem(asset: shared ? item.asset : AVURLAsset(url: url))
                let secondPlayer = AVPlayer(playerItem: secondItem); secondPlayer.isMuted = true
                secondPlayer.automaticallyWaitsToMinimizeStalling = false
                let secondOutput = AVPlayerItemVideoOutput(outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: ColorFrameGate.outputPixelFormat, AVVideoAllowWideColorKey: true])
                secondOutput.suppressesPlayerRendering = true; secondItem.add(secondOutput)
                return (secondItem, secondPlayer, secondOutput)
            }
            var (secondaryItem, secondary, output) = makeSecondary()
            let host = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 360)); host.wantsLayer = true
            let layer = AVPlayerLayer(player: player); layer.frame = host.bounds; host.layer?.addSublayer(layer)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = shared ? "双播放器 · 共享asset" : "双播放器 · 独立asset"
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            player.playImmediately(atRate: 1)
            let readyDeadline = CACurrentMediaTime() + 4
            while (player.currentTime().seconds < 0.25 || secondaryItem.status != .readyToPlay) && CACurrentMediaTime() < readyDeadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            var jumps: [[String: Any]] = [], samples: [[String: Any]] = []
            let start = CACurrentMediaTime(), initialClock = player.currentTime().seconds
            let observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped, object: item, queue: .main) { _ in
                jumps.append(["wall": CACurrentMediaTime() - start, "clock": finite(player.currentTime().seconds)])
            }
            var seekCount = 0, copied = 0, nextSeekAt = 0.0
            while CACurrentMediaTime() - start < 5 {
                if CACurrentMediaTime() - start >= nextSeekAt {
                    if teardown && seekCount > 0 {
                        secondary.pause(); secondaryItem.cancelPendingSeeks(); secondaryItem.remove(output)
                        secondary.replaceCurrentItem(with: nil)
                        (secondaryItem, secondary, output) = makeSecondary()
                    }
                    secondary.pause()
                    await secondary.seek(to: CMTime(seconds: player.currentTime().seconds + 0.30, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
                    secondary.playImmediately(atRate: 1)
                    seekCount += 1; nextSeekAt += 1
                }
                let now = secondary.currentTime()
                var pts = CMTime.invalid
                if output.hasNewPixelBuffer(forItemTime: now), output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: &pts) != nil { copied += 1 }
                var row = playerState(player, item)
                row["elapsed"] = CACurrentMediaTime() - start; row["clock"] = finite(player.currentTime().seconds)
                row["secondaryClock"] = finite(now.seconds); row["secondarySeekCount"] = seekCount
                samples.append(row)
                try await Task.sleep(nanoseconds: 16_000_000)
            }
            NotificationCenter.default.removeObserver(observer)
            let advance = player.currentTime().seconds - initialClock
            let run: [String: Any] = ["sharedAsset": shared, "clockAdvance": finite(advance), "secondarySeeks": seekCount,
                                    "secondaryTeardowns": teardown ? max(0, seekCount - 1) : 0, "copiedFrames": copied,
                                    "timeJumpCount": jumps.count, "timeJumps": jumps, "samples": samples]
            runs.append(run)
            print("DUAL", shared ? "shared_asset" : "fresh_asset", "clockAdvance", advance, "secondarySeeks", seekCount, "TimeJumped", jumps.count)
            player.pause(); secondary.pause(); secondaryItem.remove(output); secondary.replaceCurrentItem(with: nil); layer.player = nil; window.close()
        }
        let report: [String: Any] = ["scope": "Two AVPlayers only, primary native AVPlayerLayer with no attached output; secondary current-time output and repeated seeks. Compares shared immutable asset versus fresh AVURLAsset with same local URL; no GPU enhancement or interpolation processor.", "includesRepeatedSecondaryTeardown": teardown, "runs": runs]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}

// Mutated only on the main actor / NotificationCenter main queue.
private final class JumpTrace: @unchecked Sendable {
    var phase: String
    var jumps: [[String: Any]] = []
    init(phase: String) { self.phase = phase }
}
