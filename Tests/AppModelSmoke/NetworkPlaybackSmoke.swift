import Foundation
import AVFoundation
import CoreVideo
import CinemaCore

/// Headless evidence for SourceService + the real PlaybackController/AVPlayer only.
/// No SwiftUI, VideoSurface, enhancement rendering, screenshots or media files.
@main struct NetworkPlaybackSmoke {
    struct CaseSpec { let provider: String; let query: String; let catalogID: String }
    struct Sample: Codable {
        var elapsed: Double
        var controllerPosition: Double
        var playerPosition: Double
        var playing: Bool
        var buffering: Bool
        var itemStatus: String
        var presentationWidth: Int
        var presentationHeight: Int
        var decodedWidth: Int?
        var decodedHeight: Int?
    }
    struct CaseResult: Codable {
        var providerID: String
        var query: String
        var catalogID: String
        var phase = "searching"
        var passed = false
        var searchSeconds: Double?
        var searchCount: Int?
        var searchFailures: [String] = []
        var detailSeconds: Double?
        var actualTitle: String?
        var year: String?
        var line: String?
        var episode: String?
        var mediaURL: String?
        var readyAfterSeconds: Double?
        var observationSeconds: Double?
        var maxPosition: Double = 0
        var decodedFrameCount = 0
        var decodedWidth: Int?
        var decodedHeight: Int?
        var error: String?
        var itemErrorDomain: String?
        var itemErrorCode: Int?
        var itemErrorDescription: String?
        var samples: [Sample] = []
    }
    struct Report: Encodable {
        var startedAt: String
        var finishedAt: String?
        var final = false
        var passed = false
        let mode = "headless AVPlayer; no UI or GPU presentation validation"
        let catalogRequestTimeoutSeconds = 15
        let readyTimeoutSeconds = 20
        let requestedObservationSeconds = 15
        let processTimeoutSeconds = 210
        let muted = true
        let mediaFilesSaved = false
        let limitations = [
            "Uses the real SourceService and PlaybackController, but does not launch the application scene.",
            "Decoded pixel-buffer dimensions are source dimensions, not enhancement output or visible presentation proof.",
            "No SwiftUI interaction, fullscreen, keyboard, visual quality, perceived audio sync or GPU rendering was verified.",
            "Short sequential samples do not establish complete-episode reliability or general source availability.",
            "Media is streamed into AVFoundation buffers; the smoke does not save media or frame files."
        ]
        var cases: [CaseResult] = []
    }

    @MainActor static func main() async throws {
        guard CommandLine.arguments.contains("--validate"), let index = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.indices.contains(index + 1) else {
            print("Required: --validate --report /absolute/report.json"); exit(2)
        }
        let path = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let timestamp = ISO8601DateFormatter()
        var report = Report(startedAt: timestamp.string(from: Date()))
        func save() throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(report).write(to: path, options: .atomic)
        }
        func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
        try save()
        let cases = [CaseSpec(provider: "wujin", query: "流浪地球", catalogID: "25734"),
                     CaseSpec(provider: "ruyi", query: "琅琊榜", catalogID: "11751"),
                     CaseSpec(provider: "mdzy", query: "怪奇物语第一季", catalogID: "10734")]
        let service = SourceService()
        let playback = PlaybackController()
        playback.volume = 0
        playback.setRate(1)
        playback.enhancementMode = .original

        for spec in cases {
            report.cases.append(CaseResult(providerID: spec.provider, query: spec.query, catalogID: spec.catalogID))
            let slot = report.cases.count - 1
            log("START \(spec.provider) \(spec.query) catalog=\(spec.catalogID)")
            try save()
            guard let provider = SourceProvider.defaults.first(where: { $0.id == spec.provider }) else {
                report.cases[slot].phase = "failed"; report.cases[slot].error = "Provider missing from built-in catalog"; try save(); continue
            }
            let searchStarted = Date()
            let response = await service.search(query: spec.query, providers: [provider])
            report.cases[slot].searchSeconds = Date().timeIntervalSince(searchStarted)
            report.cases[slot].searchCount = response.titles.count
            report.cases[slot].searchFailures = response.failures
            guard let title = response.titles.first(where: { $0.id == spec.catalogID }) else {
                report.cases[slot].phase = "failed"; report.cases[slot].error = "Requested catalog ID absent from actual search response"; try save()
                log("FAIL \(spec.provider): search did not return requested catalog ID; \(response.failures)"); continue
            }
            report.cases[slot].phase = "detail"; try save()
            let detailStarted = Date()
            let detail: MediaDetail
            do { detail = try await service.detail(title: title, provider: provider) }
            catch {
                report.cases[slot].phase = "failed"; report.cases[slot].error = String(describing: error); try save()
                log("FAIL \(spec.provider): detail \(error)"); continue
            }
            report.cases[slot].detailSeconds = Date().timeIntervalSince(detailStarted)
            report.cases[slot].actualTitle = detail.title.title
            report.cases[slot].year = detail.title.year
            guard let line = detail.lines.first(where: { !$0.episodes.isEmpty }), let episode = line.episodes.first else {
                report.cases[slot].phase = "failed"; report.cases[slot].error = "No playable episode from actual detail response"; try save(); continue
            }
            report.cases[slot].line = line.name; report.cases[slot].episode = episode.name; report.cases[slot].mediaURL = episode.url.absoluteString
            report.cases[slot].phase = "waiting for ready"; try save()
            playback.open(url: episode.url, title: detail.title.title, episode: episode.name)
            let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            videoOutput.suppressesPlayerRendering = true
            playback.player.currentItem?.add(videoOutput)
            let openedAt = Date()
            var readyAt: Date?
            var sampledSecond = -1
            while Date().timeIntervalSince(openedAt) < 35 {
                let now = Date()
                let elapsed = now.timeIntervalSince(openedAt)
                let item = playback.player.currentItem
                if item?.status == .readyToPlay && readyAt == nil {
                    readyAt = now; report.cases[slot].readyAfterSeconds = elapsed; report.cases[slot].phase = "observing"
                    log("READY \(spec.provider) after \(String(format: "%.2f", elapsed))s")
                }
                if let readyAt, now.timeIntervalSince(readyAt) >= 15 { break }
                if readyAt == nil && elapsed >= 20 { report.cases[slot].error = "AVPlayer readiness exceeded 20 seconds"; break }
                if let error = playback.error { report.cases[slot].error = error; break }
                if let error = item?.error as NSError? {
                    report.cases[slot].error = "AVPlayerItem failed"
                    report.cases[slot].itemErrorDomain = error.domain; report.cases[slot].itemErrorCode = error.code; report.cases[slot].itemErrorDescription = error.localizedDescription
                    break
                }
                let playerTime = playback.player.currentTime()
                let position = playerTime.seconds.isFinite ? playerTime.seconds : 0
                report.cases[slot].maxPosition = max(report.cases[slot].maxPosition, position)
                if videoOutput.hasNewPixelBuffer(forItemTime: playerTime), let pixels = videoOutput.copyPixelBuffer(forItemTime: playerTime, itemTimeForDisplay: nil) {
                    report.cases[slot].decodedFrameCount += 1
                    report.cases[slot].decodedWidth = CVPixelBufferGetWidth(pixels); report.cases[slot].decodedHeight = CVPixelBufferGetHeight(pixels)
                }
                if Int(elapsed) > sampledSecond {
                    sampledSecond = Int(elapsed)
                    let size = item?.presentationSize ?? .zero
                    report.cases[slot].samples.append(Sample(elapsed: elapsed,
                        controllerPosition: playback.position.isFinite ? playback.position : 0, playerPosition: position,
                        playing: playback.isPlaying, buffering: playback.isLoading,
                        itemStatus: item?.status == .readyToPlay ? "ready" : item?.status == .failed ? "failed" : "unknown",
                        presentationWidth: size.width.isFinite ? Int(size.width) : 0, presentationHeight: size.height.isFinite ? Int(size.height) : 0,
                        decodedWidth: report.cases[slot].decodedWidth, decodedHeight: report.cases[slot].decodedHeight))
                    try save()
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            report.cases[slot].observationSeconds = readyAt.map { Date().timeIntervalSince($0) }
            if report.cases[slot].error == nil && report.cases[slot].maxPosition <= 5 { report.cases[slot].error = "Playback did not advance beyond 5 seconds" }
            if let itemError = playback.player.currentItem?.error as NSError? {
                report.cases[slot].itemErrorDomain = itemError.domain; report.cases[slot].itemErrorCode = itemError.code; report.cases[slot].itemErrorDescription = itemError.localizedDescription
            }
            report.cases[slot].passed = report.cases[slot].error == nil && readyAt != nil && report.cases[slot].maxPosition > 5
            report.cases[slot].phase = report.cases[slot].passed ? "passed" : "failed"
            playback.pause(); playback.player.replaceCurrentItem(with: nil)
            try save()
            let result = report.cases[slot]
            log("\(result.passed ? "PASS" : "FAIL") \(spec.provider) position=\(String(format: "%.2f", result.maxPosition))s decoded=\(result.decodedWidth ?? 0)x\(result.decodedHeight ?? 0) frames=\(result.decodedFrameCount) error=\(result.error ?? "none")")
        }
        report.final = true; report.finishedAt = timestamp.string(from: Date()); report.passed = report.cases.count == 3 && report.cases.allSatisfy(\.passed)
        try save()
        log("HEADLESS_NETWORK_PLAYBACK_\(report.passed ? "PASS" : "FAIL") — not UI/GPU presentation validation")
        exit(report.passed ? 0 : 1)
    }
}
