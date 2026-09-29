import Foundation
import CinemaCore

@main struct QualityPerformanceValidation {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let controller = QualityPerformanceController()
        var checks: [[String: Any]] = [], samples: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail])
            print(passed ? "PASS" : "FAIL", name, detail)
        }
        func waitUntilIdle(seconds: Double = 90) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while controller.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            if controller.isRunning {
                controller.cancel()
                throw NSError(domain: "QualityPerformanceValidation", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Benchmark did not complete before deadline"])
            }
        }
        let source = PixelSize(width: 1920, height: 1080)
        let originalStarted = controller.run(mode: .original, resolution: .source, frameRate: .source, sourceSize: source, sourceFPS: 24)
        check("original_mode_rejected_without_worker", !originalStarted && !controller.isRunning && controller.error != nil)
        let oversizedStarted = controller.run(mode: .clarity, resolution: .source, frameRate: .source,
                                             sourceSize: PixelSize(width: 5000, height: 1080), sourceFPS: 24)
        check("oversized_input_rejected_without_downsampling", !oversizedStarted && !controller.isRunning && controller.error != nil)
        var cancelledCompletion = 0
        let cancelledStarted = controller.run(mode: .clarity, resolution: .fullHD, frameRate: .source,
                                              sourceSize: source, sourceFPS: 24) { cancelledCompletion += 1 }
        let duplicateStarted = controller.run(mode: .clarity, resolution: .fullHD, frameRate: .source,
                                              sourceSize: source, sourceFPS: 24)
        check("duplicate_run_rejected", cancelledStarted && !duplicateStarted && controller.isRunning)
        controller.cancel()
        check("cancel_enters_stopping_state", controller.isCancelling)
        try await waitUntilIdle()
        check("cancel_finishes_once_without_report", cancelledCompletion == 1 && !controller.isRunning &&
              !controller.isCancelling && controller.report == nil && controller.status == "检测已取消",
              "completionCount=\(cancelledCompletion) status=\(controller.status)")

        let unsupportedStarted = controller.run(mode: .clarity, resolution: .ultraHD, frameRate: .fps60,
                                                sourceSize: source, sourceFPS: 24)
        try await waitUntilIdle()
        check("4k_fps60_explicitly_rejected", unsupportedStarted && controller.report == nil &&
              controller.error?.contains("1080p") == true, controller.error ?? "missing error")

        for (name, mode, resolution, frameRate) in [
            ("clarity_1080p_motion60", EnhancementMode.clarity, EnhancementResolution.fullHD, EnhancementFrameRate.fps60),
            ("restoration_4k_source24", EnhancementMode.restoration, EnhancementResolution.ultraHD, EnhancementFrameRate.source),
            ("compression_automatic4k_source24", EnhancementMode.compression, EnhancementResolution.automatic, EnhancementFrameRate.source),
            ("compression_1080p_motion60", EnhancementMode.compression, EnhancementResolution.fullHD, EnhancementFrameRate.fps60)
        ] {
            var completions = 0
            print("RUN", name)
            let started = controller.run(mode: mode, resolution: resolution, frameRate: frameRate,
                                         sourceSize: source, sourceFPS: 24) { completions += 1 }
            try await waitUntilIdle()
            check(name + "_completed", started && completions == 1 && controller.report != nil && controller.error == nil,
                  controller.error ?? "completionCount=\(completions)")
            guard let report = controller.report else { continue }
            if mode == .compression {
                check(name + "_reports_actual_cleanup",report.algorithm.contains("压缩抑噪") && report.algorithm.contains("时域降噪"),report.algorithm)
            }
            check(name + "_samples_and_pixels", report.completedFrames == 30 && report.warmupFrames == 3 &&
                  report.pixelsChecked && report.p95MS.isFinite && report.p95MS > 0 && report.maximumMS >= report.p95MS)
            check(name + "_source_interval_budget", abs(report.frameBudgetMS - 1000.0 / 24.0) < 0.00001)
            if frameRate == .fps60 {
                check(name + "_actual_1080p", report.outputSize == PixelSize(width: 1920, height: 1080))
                check(name + "_motion_grid", report.includesFrameInterpolation && report.frameGridValidated &&
                      report.completedOutputFrames == 75 && report.interpolatedFrames == 60 &&
                      abs(report.sampledMediaSeconds - 1.25) < 0.00001,
                      "grid=\(report.completedOutputFrames) interpolated=\(report.interpolatedFrames) sampledMediaSeconds=\(report.sampledMediaSeconds)")
            } else {
                check(name + "_actual_4k", report.outputSize == PixelSize(width: 3840, height: 2160))
                check(name + "_source_frames_only", !report.includesFrameInterpolation && report.interpolatedFrames == 0 && report.completedOutputFrames == 30)
            }
            samples.append(snapshot(name, report))
            print("RESULT", name, "meanMS=\(report.meanMS) p95MS=\(report.p95MS) budgetMS=\(report.frameBudgetMS) generated=\(report.interpolatedFrames)")
        }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = [
            "passed": passed, "checks": checks, "samples": samples,
            "scope": "Headless QualityPerformanceController on deterministic synthetic moving noisy SDR 1920x1080 at 24 source fps. Tests start/duplicate/cancel/invalid request, completed spatial + VT motion interpolation including final texture work, pixel sanity, 60 Hz timestamp grid and actual output size. Three warmup source frames, thirty measured source intervals. The complete test holds the production exclusive-processing lock so playback processing workers cannot overlap it; lock waiting, CPU fixture generation and correctness readback are excluded from timing. No AVPlayer, visible screen, decoded film, sound, AV sync or sustained real-time proof; P95 budget is reported, not asserted as a performance promise."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        if !passed { exit(1) }
    }

    static func snapshot(_ name: String, _ report: QualityPerformanceReport) -> [String: Any] {
        ["name": name, "device": report.deviceName, "operatingSystem": report.operatingSystem,
         "mode": report.mode.rawValue, "resolution": report.resolution.rawValue, "requestedFrameRate": report.requestedFrameRate.rawValue,
         "sourceSize": [report.sourceSize.width, report.sourceSize.height], "sourceFPS": report.sourceFPS,
         "assumedSourceFPS": report.assumedSourceFPS, "outputSize": [report.outputSize.width, report.outputSize.height],
         "algorithm": report.algorithm, "warmupFrames": report.warmupFrames, "completedSourceIntervals": report.completedFrames,
         "completedOutputFrames": report.completedOutputFrames, "interpolatedFrames": report.interpolatedFrames,
         "includesFrameInterpolation": report.includesFrameInterpolation, "frameGridValidated": report.frameGridValidated,
         "sampledMediaSeconds": report.sampledMediaSeconds, "meanMS": report.meanMS, "p95MS": report.p95MS,
         "maximumMS": report.maximumMS, "firstFrameMS": report.firstFrameMS, "sourceFrameBudgetMS": report.frameBudgetMS,
         "p95HeadroomMS": report.headroomMS, "overBudgetIntervals": report.overBudgetFrames,
         "shortTestFitsBudget": report.spatialFitsBudget, "pixelsChecked": report.pixelsChecked,
         "frameRateNote": report.frameRateNote, "verdict": report.verdict]
    }
}
