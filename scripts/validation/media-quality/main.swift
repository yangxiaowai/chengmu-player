import AVFoundation
import Foundation

@main
struct MediaQualityValidation {
    struct Receipt: Codable {
        var checkedAt = Date()
        var checks: [String] = []
        var samples: [String: MediaQualitySample] = [:]
        var elapsedSeconds: [String: Double] = [:]
        var failures: [String: String] = [:]
    }

    static func main() async throws {
        var receipt = Receipt()
        let sample = MediaQualitySample(width: 640, height: 360, frameRate: 24,
                                        codec: "avc1", estimatedBitrate: 1_500_000)
        precondition(sample.dimensionsLabel == "640×360")
        precondition(sample.resolutionLabel == "360p · 640×360")
        precondition(sample.pixelCount == 230_400)
        precondition(sample.summary.contains("24 fps"))
        precondition(sample.summary.contains("1.5 Mbps"))
        precondition(MediaQualitySample(width: 3840, height: 1600).resolutionLabel == "3840×1600")
        precondition(MediaQualitySample(width: 1080, height: 1920).resolutionLabel == "1080×1920")
        for dimensions in [(0, 1080), (-1, 1080), (16_385, 1080), (1920, Int.max)] {
            let value = MediaQualitySample(width: dimensions.0, height: dimensions.1,
                                           frameRate: .infinity, estimatedBitrate: -.infinity)
            precondition(value.pixelCount == 0 && value.frameRate == nil && value.estimatedBitrate == nil)
            precondition(value.resolutionLabel == "尺寸未知")
        }
        let decoded = try JSONDecoder().decode(MediaQualitySample.self,
            from: Data(#"{"width":-1,"height":1080,"frameRate":0}"#.utf8))
        precondition(decoded.pixelCount == 0 && decoded.frameRate == nil)
        precondition(decoded.evidence == .track)
        precondition(MediaQualitySample(width: 640, height: 360, evidence: .firstFrame).summary.contains("首帧读取"))
        print("PASS: sample labels, conservative classification, invalid values, Codable")
        receipt.checks.append("sample labels, conservative classification, invalid values, Codable")
        guard CommandLine.arguments.count == 4,
              let baseURL = URL(string: CommandLine.arguments[2]) else { return }
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for (name, width, height) in [("landscape.mp4", 640, 360), ("portrait-rotation.mp4", 360, 640),
                                      ("claimed-4K.mp4", 640, 360)] {
            let value = try await MediaQualityProbe().inspect(url: fixtures.appendingPathComponent(name))
            precondition(value.width == width && value.height == height, "Unexpected orientation: \(value)")
            precondition(abs((value.frameRate ?? 0) - 24) < 0.01)
            precondition(value.codec == "avc1")
            precondition((value.estimatedBitrate ?? 0) > 0)
            receipt.samples[name] = value
            receipt.checks.append("local metadata \(name)")
        }
        let httpSample = try await MediaQualityProbe().inspect(url: baseURL.appendingPathComponent("landscape.mp4"))
        precondition(httpSample.width == 640 && httpSample.height == 360)
        receipt.samples["http-landscape.mp4"] = httpSample
        receipt.checks.append("HTTP metadata")
        let hlsURL = baseURL.appendingPathComponent("local.m3u8")
        let unpreparedHLSTracks = try await AVURLAsset(url: hlsURL).loadTracks(withMediaType: .video)
        precondition(unpreparedHLSTracks.isEmpty, "Fixture did not force HLS preparation fallback")
        let hlsSample = try await MediaQualityProbe().inspect(url: hlsURL)
        precondition(hlsSample.width == 640 && hlsSample.height == 360)
        receipt.samples["http-local.m3u8"] = hlsSample
        receipt.checks.append("local HTTP HLS prepared-item or first-frame fallback")

        for (name, url) in [("invalid-scheme", URL(string: "ftp://localhost/video.mp4")!),
                            ("invalid-host", URL(string: "https:/video.mp4")!),
                            ("credentials", URL(string: "https://user:secret@localhost/video.mp4")!),
                            ("bad-file", fixtures.appendingPathComponent("bad.mp4")),
                            ("audio-only", fixtures.appendingPathComponent("audio-only.m4a"))] {
            var failed = false
            do { _ = try await MediaQualityProbe(timeout: 1).inspect(url: url) }
            catch { failed = true; receipt.failures[name] = error.localizedDescription }
            precondition(failed, "Expected metadata failure for \(name)")
            receipt.checks.append("rejected \(name)")
        }

        let timeoutStarted = Date()
        var timedOut = false
        do { _ = try await MediaQualityProbe(timeout: 0.4).inspect(url: baseURL.appendingPathComponent("hang-timeout.mp4")) }
        catch {
            timedOut = true
            receipt.failures["timeout"] = error.localizedDescription
        }
        let timeoutElapsed = Date().timeIntervalSince(timeoutStarted)
        precondition(timedOut && timeoutElapsed >= 0.35 && timeoutElapsed < 2,
                     "Timeout did not bound the entire read: \(timeoutElapsed)")
        receipt.elapsedSeconds["timeout"] = timeoutElapsed
        receipt.checks.append("stalled HTTP timeout returns within 2 seconds")

        let cancellationStarted = Date()
        let task = Task { try await MediaQualityProbe().inspect(url: baseURL.appendingPathComponent("hang-cancel.mp4")) }
        try await Task.sleep(nanoseconds: 250_000_000)
        task.cancel()
        var cancelled = false
        do { _ = try await task.value }
        catch is CancellationError { cancelled = true }
        let cancellationElapsed = Date().timeIntervalSince(cancellationStarted)
        precondition(cancelled && cancellationElapsed < 2, "Cancellation did not promptly terminate AVFoundation")
        receipt.elapsedSeconds["cancellation"] = cancellationElapsed
        receipt.checks.append("stalled HTTP cancellation returns CancellationError within 2 seconds")

        let hlsTimeoutStarted = Date()
        var hlsTimedOut = false
        do { _ = try await MediaQualityProbe(timeout: 1.2).inspect(url: baseURL.appendingPathComponent("stall-timeout.m3u8")) }
        catch { hlsTimedOut = true; receipt.failures["HLS-timeout"] = error.localizedDescription }
        let hlsTimeoutElapsed = Date().timeIntervalSince(hlsTimeoutStarted)
        precondition(hlsTimedOut && hlsTimeoutElapsed >= 1.1 && hlsTimeoutElapsed < 2)
        receipt.elapsedSeconds["HLS-timeout"] = hlsTimeoutElapsed
        receipt.checks.append("stalled HLS media timeout releases prepared private player within 2 seconds")

        let hlsCancelStarted = Date()
        let hlsTask = Task { try await MediaQualityProbe().inspect(url: baseURL.appendingPathComponent("stall-cancel.m3u8")) }
        try await Task.sleep(nanoseconds: 350_000_000)
        hlsTask.cancel()
        var hlsCancelled = false
        do { _ = try await hlsTask.value }
        catch is CancellationError { hlsCancelled = true }
        let hlsCancelElapsed = Date().timeIntervalSince(hlsCancelStarted)
        precondition(hlsCancelled && hlsCancelElapsed < 2)
        receipt.elapsedSeconds["HLS-cancellation"] = hlsCancelElapsed
        receipt.checks.append("stalled HLS media cancellation releases prepared private player within 2 seconds")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
        print("PASS: \(receipt.checks.count) metadata checks; timeout \(timeoutElapsed)s, cancellation \(cancellationElapsed)s")
    }
}
