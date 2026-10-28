import Foundation
import AVFoundation
import AppKit

private final class FailureFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    func set() { lock.withLock { failed = true } }
    var isSet: Bool { lock.withLock { failed } }
}

@main struct PreviewFrameAccuracySmoke {
    struct Failure: Error { let message: String }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let local = URL(fileURLWithPath: CommandLine.arguments[1])
        let hls = URL(string: CommandLine.arguments[2])!
        let report = URL(fileURLWithPath: CommandLine.arguments[3])
        let work = URL(fileURLWithPath: CommandLine.arguments[4], isDirectory: true)
        let relayFailure = FailureFlag()
        guard let relay = DirectHLSRelay(url: hls, onFailure: { relayFailure.set() }) else { throw Failure(message: "HLS relay unavailable") }
        defer { relay.stop() }
        let mainPlayer = AVPlayer(playerItem: AVPlayerItem(url: relay.url))
        mainPlayer.isMuted = true
        let preview = SeekPreviewController()
        var checks: [[String: Any]] = []
        func check(_ name: String, _ ok: Bool) throws {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            checks.append(["name": name, "passed": ok])
            if !ok { throw Failure(message: name) }
        }
        func wait() async throws {
            let deadline = Date().addingTimeInterval(12)
            while preview.isLoading && Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
            guard !preview.isLoading else { throw Failure(message: "preview timed out") }
        }
        func color(_ image: NSImage?) -> (Double, Double, Double)? {
            guard let image, let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                  let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else { return nil }
            return (color.redComponent, color.greenComponent, color.blueComponent)
        }
        func matches(_ name: String, _ sample: (Double, Double, Double)?) -> Bool {
            guard let (r,g,b) = sample else { return false }
            switch name {
            case "red": return r > 0.6 && g < 0.3 && b < 0.3
            case "green": return g > 0.6 && r < 0.3 && b < 0.3
            case "blue": return b > 0.6 && r < 0.3 && g < 0.3
            case "yellow": return r > 0.6 && g > 0.6 && b < 0.3
            default: return false
            }
        }
        var mainBefore = 0.0
        for (label, asset, confirmed) in [("local", AVURLAsset(url: local), false), ("hls_relay", mainPlayer.currentItem!.asset, true)] {
            if label == "hls_relay" {
                mainPlayer.play()
                let startDeadline = Date().addingTimeInterval(8)
                while mainPlayer.currentTime().seconds <= 0.05 && Date() < startDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
                try check("relay_main_player_started", mainPlayer.currentTime().seconds > 0.05)
                mainBefore = mainPlayer.currentTime().seconds
            }
            preview.configure(asset: asset, itemID: UUID(), isConfirmedHLS: confirmed)
            for (time, expected) in [(2.0, "red"), (6.0, "green"), (10.0, "blue"), (14.0, "yellow")] {
                preview.request(time: time, duration: 16)
                try await wait()
                try check("\(label)_\(expected)_content_at_\(Int(time))s", matches(expected, color(preview.image)) && abs((preview.actualTime ?? -100) - time) <= 0.45)
            }
            preview.request(time: 2, duration: 16)
            try await Task.sleep(nanoseconds: 20_000_000)
            preview.request(time: 14, duration: 16)
            try await Task.sleep(nanoseconds: 20_000_000)
            preview.request(time: 6, duration: 16)
            try await wait()
            try check("\(label)_rapid_hover_finishes_at_latest_color", matches("green", color(preview.image)) && abs((preview.actualTime ?? -100) - 6) <= 0.45)
        }
        print("main state=\(mainPlayer.currentItem?.status.rawValue ?? -1) rate=\(mainPlayer.rate) time=\(mainPlayer.currentTime().seconds) error=\(mainPlayer.currentItem?.error?.localizedDescription ?? "none")")
        try check("relay_preview_does_not_pause_main_player", mainPlayer.rate == 1 && mainPlayer.currentTime().seconds > mainBefore + 0.1)
        let marker = work.appendingPathComponent("delayed-segment-requested")
        try Data().write(to: work.appendingPathComponent("delay-enabled"))
        preview.configure(asset: mainPlayer.currentItem!.asset, itemID: UUID(), isConfirmedHLS: true)
        let beforeCancel = mainPlayer.currentTime().seconds
        preview.request(time: 14, duration: 16)
        let startedDeadline = Date().addingTimeInterval(6)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < startedDeadline { try await Task.sleep(nanoseconds: 30_000_000) }
        try check("preview_segment_request_is_in_flight_before_cancel", FileManager.default.fileExists(atPath: marker.path))
        preview.hide()
        try await Task.sleep(nanoseconds: 3_500_000_000)
        try check("canceling_preview_keeps_main_relay_playing", !relayFailure.isSet && mainPlayer.rate == 1 && mainPlayer.currentTime().seconds > beforeCancel + 0.1)
        try FileManager.default.removeItem(at: work.appendingPathComponent("delay-enabled"))
        let slowURL = hls.deletingLastPathComponent().appendingPathComponent("slow.m3u8")
        guard let slowRelay = DirectHLSRelay(url: slowURL) else { throw Failure(message: "slow HLS relay unavailable") }
        defer { slowRelay.stop() }
        preview.configure(asset: AVURLAsset(url: slowRelay.url), itemID: UUID(), isConfirmedHLS: true)
        var previewAppeared = false
        for _ in 0..<80 {
            preview.request(time: 6, duration: 16)
            if preview.image != nil { previewAppeared = true; break }
            if !preview.isLoading { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try check("slow_hls_repeated_hover_eventually_displays_correct_frame", previewAppeared && matches("green", color(preview.image)) && abs((preview.actualTime ?? -100) - 6) <= 0.45)
        preview.configure(asset: mainPlayer.currentItem!.asset, itemID: UUID(), isConfirmedHLS: true)
        var jitterProducedFrame = false, latest = 10.0
        for index in 0..<40 {
            latest = index.isMultiple(of: 2) ? 10 : 10.06
            preview.request(time: latest, duration: 16)
            try await Task.sleep(nanoseconds: 100_000_000)
            if preview.image != nil { jitterProducedFrame = true; break }
        }
        try check("hls_small_hover_jitter_displays_latest_blue_frame", jitterProducedFrame && matches("blue", color(preview.image)) && abs((preview.actualTime ?? -100) - latest) <= 0.45)
        for (endpoint, portrait) in [("opaque-mp4", false), ("opaque-rotated", true)] {
            let opaqueURL = hls.deletingLastPathComponent().appendingPathComponent(endpoint)
            let opaquePlayer = AVPlayer(playerItem: AVPlayerItem(url: opaqueURL))
            opaquePlayer.isMuted = true
            opaquePlayer.play()
            let deadline = Date().addingTimeInterval(8)
            while opaquePlayer.currentTime().seconds <= 0.05 && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            try check("\(endpoint)_main_player_started", opaquePlayer.currentTime().seconds > 0.05)
            let before = opaquePlayer.currentTime().seconds
            preview.configure(asset: opaquePlayer.currentItem!.asset, itemID: UUID(), isConfirmedHLS: false)
            preview.request(time: 6, duration: 16)
            try await wait()
            try check("\(endpoint)_correct_green_frame", matches("green", color(preview.image)) && abs((preview.actualTime ?? -100) - 6) <= 0.45)
            if portrait { try check("\(endpoint)_preserves_portrait_rotation", (preview.image?.size.height ?? 0) > (preview.image?.size.width ?? 0)) }
            try check("\(endpoint)_preview_does_not_pause_main", opaquePlayer.rate == 1 && opaquePlayer.currentTime().seconds > before + 0.1)
            opaquePlayer.pause()
        }
        preview.stop(); mainPlayer.pause()
        let result: [String: Any] = ["passed": true, "checks": checks, "scope": "Synthetic four-color local MP4 and loopback HLS through production relay; no real provider or window mouse interaction"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
    }
}
