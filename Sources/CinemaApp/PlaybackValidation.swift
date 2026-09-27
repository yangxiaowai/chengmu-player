import Foundation
import AppKit
import AVFoundation
import CinemaCore

/// Explicit diagnostic mode. The normal app never starts automated playback tests.
@MainActor
final class PlaybackValidation {
    static let shared = PlaybackValidation()
    private var started = false
    private var timer: Timer?
    private var startupTimer: Timer?
    private var startupTask: Task<Void, Never>?
    private var phase = "starting"
    private var samples: [[String: Any]] = []
    private var startTime = Date()
    private var initialMediaTime: Double?
    private var lastMediaTime = -1.0
    private var stalledSeconds = 0
    private var testDuration = 120.0
    private var reportPath = "docs/validation/playback-report.json"
    private var name = "怪奇物语"

    func start(model: AppModel) {
        guard !started else { return }; started = true
        let args = CommandLine.arguments
        func option(_ key: String) -> String? { guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }; return args[i + 1] }
        testDuration = Double(option("--seconds") ?? "120") ?? 120
        reportPath = option("--report") ?? reportPath
        name = option("--title") ?? name
        model.playback.enhancementMode = EnhancementMode(rawValue: option("--mode") ?? "upscale4K") ?? .upscale4K
        model.playback.volume = 0
        startTime = Date()
        phase = "searching"
        write(model: model, final: false, failure: nil)
        startupTimer = Timer.scheduledTimer(withTimeInterval: 75, repeats: false) { [weak self, weak model] _ in
            Task { @MainActor in
                guard let self, let model else { return }
                self.startupTask?.cancel()
                self.finish(model: model, failure: "Startup exceeded 75 seconds during \(self.phase)")
            }
        }
        startupTask = Task { [self, model] in
            let providers = model.providers.filter { option("--provider") == nil || $0.id == option("--provider") }
            let response = await model.service.search(query: name, providers: providers)
            guard !Task.isCancelled else { return }
            let catalogIDs = ["怪奇物语": "7942", "绝命毒师": "13747", "火线": "12980"]
            let requestedID = option("--catalog-id") ?? catalogIDs[name]
            let selected: MediaTitle?
            if let requestedID { selected = response.titles.first(where: { $0.id == requestedID }) }
            else { selected = response.titles.sorted(by: { $0.title < $1.title }).first }
            guard let title = selected,
                  let provider = model.providers.first(where: {$0.id == title.providerID}) else { finish(model: model, failure: "No matching catalog: \(response.failures)"); return }
            do {
                phase = "loading detail"
                write(model: model, final: false, failure: nil)
                let detail = try await model.service.detail(title: title, provider: provider)
                guard !Task.isCancelled else { return }
                guard let line = detail.lines.first, let episode = line.episodes.first else { finish(model: model, failure: "No playable episode"); return }
                model.detail = detail; model.selectedLineID = line.id
                model.play(episode)
                model.playback.resumeWhenReady(Double(option("--start-at") ?? "0") ?? 0)
                startupTimer?.invalidate(); startupTimer = nil
                phase = "playing"
                startTime = Date()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak model] _ in
                    Task { @MainActor in guard let self, let model else { return }; self.sample(model) }
                }
            } catch { finish(model: model, failure: String(describing: error)) }
        }
    }
    private func sample(_ model: AppModel) {
        let playback = model.playback, elapsed = Date().timeIntervalSince(startTime)
        if initialMediaTime == nil && playback.position > 0 { initialMediaTime = playback.position }
        if playback.position == lastMediaTime { stalledSeconds += 1 }
        lastMediaTime = playback.position
        var sample: [String: Any] = ["elapsed": elapsed, "mediaTime": playback.position, "playing": playback.isPlaying, "buffering": playback.isLoading, "error": playback.error ?? ""]
        if let m = playback.metrics {
            sample.merge(["sourceWidth":m.sourceWidth,"sourceHeight":m.sourceHeight,"outputWidth":m.outputWidth,"outputHeight":m.outputHeight,"mode":m.mode,"processingMS":m.processingMS,"processedFrames":m.processedFrames,"renderedFrames":m.renderedFrames,"droppedFrames":m.droppedFrames,"presentationTime":m.presentationTime,"fallbackReason":m.fallbackReason ?? ""]) { _, new in new }
        }
        if let log = playback.player.currentItem?.accessLog()?.events.last {
            sample["avDroppedFrames"] = log.numberOfDroppedVideoFrames; sample["avStalls"] = log.numberOfStalls; sample["observedBitrate"] = log.observedBitrate
        }
        samples.append(sample)
        if Int(elapsed) % 15 == 0 { write(model: model, final: false, failure: nil) }
        if elapsed >= testDuration || playback.error != nil { finish(model: model, failure: playback.error) }
    }
    private func finish(model: AppModel, failure: String?) {
        timer?.invalidate(); timer = nil
        startupTimer?.invalidate(); startupTimer = nil
        write(model: model, final: true, failure: failure)
        model.playback.pause()
        NSApp.terminate(nil)
    }
    private func write(model: AppModel, final: Bool, failure: String?) {
        let report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "final": final, "phase": phase, "requestedTitle": name, "playedTitle": model.playback.title, "episode": model.playback.episodeName, "requestedDurationSeconds": testDuration, "elapsedSeconds": Date().timeIntervalSince(startTime), "mediaPosition": model.playback.position, "stationarySamples": stalledSeconds, "failure": failure ?? "", "samples": samples, "limitations": ["Captures real app AVPlayer and GPU metrics, not full episode identity verification", "AVPlayer is muted in diagnostic mode; perceptual audio sync not manually verified", "Rendering timestamps do not by themselves prove visual quality or absence of artifacts"]]
        do {
            let url = URL(fileURLWithPath: reportPath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { FileHandle.standardError.write(Data("Could not write playback report: \(error)\n".utf8)) }
    }
}
