import Foundation
import AVFoundation
import CinemaCore

@main struct DirectPlaybackSmoke {
    struct Failure: Error { let message: String }
    @MainActor static func main() async throws {
        let base = URL(string: CommandLine.arguments[1])!
        let local = URL(fileURLWithPath: CommandLine.arguments[2])
        let controller = PlaybackController()
        controller.volume = 0
        var checks: [[String: Any]] = []
        func check(_ name: String, _ condition: Bool) throws {
            checks.append(["name": name, "passed": condition])
            FileHandle.standardError.write(Data("\(condition ? "PASS" : "FAIL") \(name)\n".utf8))
            if !condition { throw Failure(message: name) }
        }
        func until(_ name: String, seconds: Double = 10, _ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate() {
                guard Date() < deadline else { throw Failure(message: "timeout: \(name), status=\(controller.player.currentItem?.status.rawValue ?? -1), route=\(controller.mediaNetworkRoute), error=\(controller.error ?? "none")") }
                try await Task.sleep(nanoseconds: 30_000_000)
            }
        }
        func scheme() -> String? { (controller.player.currentItem?.asset as? AVURLAsset)?.url.scheme }
        let good = base.appendingPathComponent("good.mp4")
        controller.open(url: good, title: "Good", episode: "Fixture")
        try check("eligible_mp4_uses_direct_loader", scheme() == "cinemadirect")
        try check("direct_route_is_preparing", controller.mediaNetworkRoute == "直连准备中")
        try await until("direct play") { controller.isPlaying && controller.position > 0.5 }
        try check("direct_route_identifies_http_proxy_exclusion", controller.mediaNetworkRoute == "排除 HTTP 代理的文件直连")
        var meter = DirectTransferRateTracker()
        try check("initial_rate_is_unknown", meter.sample(bytes: 0, at: 10) == nil)
        try check("too_short_rate_window_is_unknown", meter.sample(bytes: 1024, at: 10.1) == nil)
        try check("rate_counts_actual_bytes", meter.sample(bytes: 8192, at: 12) == 4096)
        try check("stall_reports_zero", meter.sample(bytes: 8192, at: 13) == 0)
        try check("counter_reset_is_unknown", meter.sample(bytes: 0, at: 14) == nil)
        let throttled = base.appendingPathComponent("throttle.mp4")
        let pauseMarker = local.deletingLastPathComponent().appendingPathComponent("throttle-paused")
        defer { try? FileManager.default.removeItem(at: pauseMarker) }
        let rateLoader = DirectProgressiveResourceLoader(url: throttled)!
        let ratePlayer = AVPlayer(playerItem: AVPlayerItem(asset: rateLoader.asset))
        ratePlayer.isMuted = true; ratePlayer.play()
        try await until("throttled media bytes arrive", seconds: 8) { rateLoader.receivedByteCount >= 32768 }
        FileManager.default.createFile(atPath: pauseMarker.path, contents: Data())
        try await Task.sleep(nanoseconds: 700_000_000)
        var liveMeter = DirectTransferRateTracker()
        let stalledBytes = rateLoader.receivedByteCount
        _ = liveMeter.sample(bytes: stalledBytes, at: ProcessInfo.processInfo.systemUptime)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let stalledRate = liveMeter.sample(bytes: rateLoader.receivedByteCount, at: ProcessInfo.processInfo.systemUptime)
        try check("real_throttled_transfer_stall_measures_zero", stalledRate == 0)
        try FileManager.default.removeItem(at: pauseMarker)
        try await until("throttled transfer resumes", seconds: 8) { rateLoader.receivedByteCount > stalledBytes + 32768 }
        try await Task.sleep(nanoseconds: 600_000_000)
        let resumedRate = liveMeter.sample(bytes: rateLoader.receivedByteCount, at: ProcessInfo.processInfo.systemUptime)
        try check("real_throttled_transfer_resumes_with_measured_rate", resumedRate.map { $0 > 0 } == true)
        ratePlayer.pause(); ratePlayer.replaceCurrentItem(with: nil); rateLoader.stop()
        FileManager.default.createFile(atPath: pauseMarker.path, contents: Data())
        controller.open(url: throttled, title: "Waiting transfer", episode: "Fixture")
        try await until("direct buffer speed is sampled", seconds: 5) { controller.isLoading && controller.directDownloadSpeed != nil }
        try check("direct_buffer_stall_displays_measured_zero", controller.directDownloadSpeed == 0)
        controller.open(url: local, title: "Replacement", episode: "Fixture", resume: 2)
        controller.pause()
        try await until("replacement ready after stalled transfer") { controller.player.currentItem?.status == .readyToPlay }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        try check("old_transfer_rate_never_leaks_to_new_item", controller.directDownloadSpeed == nil && controller.mediaNetworkRoute == "本地文件")
        try FileManager.default.removeItem(at: pauseMarker)
        controller.open(url: good, title: "Good resumed", episode: "Fixture")
        try check("new_direct_item_starts_with_unknown_speed", controller.directDownloadSpeed == nil)
        try await until("direct resumes after rate check") { controller.isPlaying && controller.position > 0.5 }
        let preview = SeekPreviewController()
        preview.configure(asset: controller.player.currentItem?.asset, itemID: controller.itemID)
        let beforePreview = controller.player.currentTime().seconds
        preview.request(time: 3, duration: 10)
        try await until("preview of direct item", seconds: 12) { !preview.isLoading }
        try check("direct_item_preview_has_correct_frame_without_stopping_playback", preview.image != nil && abs((preview.actualTime ?? -100) - 3) <= 0.45 && controller.playbackRequested && controller.player.currentTime().seconds > beforePreview)
        preview.stop()
        controller.pause(); controller.seek(to: 5)
        try await until("direct seek") { abs(controller.player.currentTime().seconds - 5) < 0.3 }
        try check("direct_seek_preserves_pause", !controller.playbackRequested && scheme() == "cinemadirect")
        let denied = base.appendingPathComponent("denied.mp4")
        controller.open(url: denied, title: "Denied", episode: "Fixture", resume: 5)
        controller.pause()
        try await until("failed direct falls back") { scheme() == "http" && controller.player.currentItem?.status == .readyToPlay && abs(controller.player.currentTime().seconds - 5) < 0.3 }
        try check("direct_failure_falls_back_preserving_pause_and_resume", !controller.playbackRequested && controller.player.rate == 0 && controller.mediaNetworkRoute == "系统网络")
        let query = URL(string: good.absoluteString + "?token=signed")!
        controller.open(url: query, title: "Signed", episode: "Fixture")
        try check("signed_url_stays_native", scheme() == "http" && controller.mediaNetworkRoute == "系统网络")
        controller.open(url: base.appendingPathComponent("playlist.m3u8"), title: "HLS", episode: "Fixture")
        try check("hls_stays_native", scheme() == "http" && controller.mediaNetworkRoute == "系统网络")
        let redirect = base.appendingPathComponent("redirect.mp4")
        controller.open(url: redirect, title: "Signed redirect", episode: "Fixture", resume: 2)
        controller.pause()
        try await until("signed redirect returns to system route") { scheme() == "http" && controller.player.currentItem?.status == .readyToPlay }
        try check("signed_redirect_stays_system_route", !controller.playbackRequested)
        let basic = base.appendingPathComponent("basic.mp4")
        controller.open(url: basic, title: "Basic challenge", episode: "Fixture", resume: 2)
        controller.pause()
        try await until("HTTP Basic challenge returns to system route") { scheme() == "http" && controller.player.currentItem?.status == .readyToPlay }
        try check("basic_auth_challenge_falls_back_without_resuming", !controller.playbackRequested)
        let invalidRange = base.appendingPathComponent("bad-range.mp4")
        controller.open(url: invalidRange, title: "Invalid range", episode: "Fixture", resume: 2)
        controller.pause()
        try await until("invalid content range returns to system route") { scheme() == "http" && controller.player.currentItem?.status == .readyToPlay }
        try check("invalid_content_range_falls_back", !controller.playbackRequested)
        let port = base.port!
        let cookieTarget = URL(string: "http://localhost:\(port)/good.mp4")!
        let cookie = HTTPCookie(properties: [.domain: "localhost", .path: "/", .name: "CinemaFixture_\(UUID().uuidString)", .value: "fixture", .discard: "TRUE"])!
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        try check("cookie_fixture_is_present", HTTPCookieStorage.shared.cookies(for: cookieTarget)?.contains(cookie) == true)
        let cookieRedirect = base.appendingPathComponent("cookie-redirect.mp4")
        controller.open(url: cookieRedirect, title: "Cookie redirect", episode: "Fixture", resume: 2)
        controller.pause()
        try await until("cookie redirect returns to system route") { scheme() == "http" && controller.player.currentItem?.status == .readyToPlay }
        try check("cross_host_cookie_redirect_stays_system_route", !controller.playbackRequested)
        let timeout = base.appendingPathComponent("slow.mp4")
        controller.open(url: timeout, title: "Slow", episode: "Fixture", resume: 3)
        controller.pause()
        try await until("timeout returns to system route", seconds: 12) { scheme() == "http" && controller.player.currentItem?.status == .readyToPlay && abs(controller.player.currentTime().seconds - 3) < 0.3 }
        try check("timeout_preserves_pause", !controller.playbackRequested && controller.player.rate == 0)
        controller.open(url: timeout, title: "Slow old", episode: "Fixture")
        controller.open(url: local, title: "New local", episode: "Fixture", resume: 2)
        controller.pause()
        try await until("replacement local ready") { scheme() == "file" && controller.player.currentItem?.status == .readyToPlay }
        try await Task.sleep(nanoseconds: 7_000_000_000)
        try check("superseded_direct_timeout_does_not_replace_new_item", scheme() == "file" && !controller.playbackRequested)
        let slowLoader = DirectProgressiveResourceLoader(url: timeout)!
        let goodLoader = DirectProgressiveResourceLoader(url: good)!
        let slowPlayer = AVPlayer(playerItem: AVPlayerItem(asset: slowLoader.asset))
        let goodPlayer = AVPlayer(playerItem: AVPlayerItem(asset: goodLoader.asset))
        slowPlayer.isMuted = true; goodPlayer.isMuted = true
        slowPlayer.play(); goodPlayer.play()
        try await Task.sleep(nanoseconds: 100_000_000)
        slowPlayer.replaceCurrentItem(with: nil); slowLoader.stop()
        try await until("other loader survives cancellation", seconds: 12) { goodPlayer.currentItem?.status == .readyToPlay && goodPlayer.currentTime().seconds > 0.2 }
        try check("shared_session_cancels_only_its_own_loader", goodPlayer.rate > 0)
        goodPlayer.pause(); goodPlayer.replaceCurrentItem(with: nil); goodLoader.stop()
        let startedMarker = local.deletingLastPathComponent().appendingPathComponent("slow-started")
        try? FileManager.default.removeItem(at: startedMarker)
        var releasingLoader: DirectProgressiveResourceLoader? = DirectProgressiveResourceLoader(url: timeout)!
        weak var weakLoader = releasingLoader
        let releasingPlayer = AVPlayer(playerItem: AVPlayerItem(asset: releasingLoader!.asset))
        releasingPlayer.isMuted = true; releasingPlayer.play()
        try await until("slow direct request entered server") { FileManager.default.fileExists(atPath: startedMarker.path) }
        releasingPlayer.replaceCurrentItem(with: nil)
        releasingLoader?.stop(); releasingLoader = nil
        try await until("canceled loader is released", seconds: 8) { weakLoader == nil }
        try check("canceled_loading_request_finishes_and_loader_releases", weakLoader == nil)
        let stressURL = ProcessInfo.processInfo.environment["CINEMA_NATIVE_STRESS"] == "1" ? URL(string: timeout.absoluteString + "?native=1")! : timeout
        let count = Int(ProcessInfo.processInfo.environment["CINEMA_STRESS_COUNT"] ?? "60") ?? 60
        let gap = UInt64(ProcessInfo.processInfo.environment["CINEMA_STRESS_GAP_MS"] ?? "0") ?? 0
        for _ in 0..<count {
            controller.open(url: stressURL, title: "Rapid replacement", episode: "Fixture")
            if gap > 0 { try await Task.sleep(nanoseconds: gap * 1_000_000) }
        }
        controller.open(url: local, title: "Final local", episode: "Fixture", resume: 2)
        controller.pause()
        try await until("final item survives rapid replacements", seconds: 30) { scheme() == "file" && controller.player.currentItem?.status == .readyToPlay }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try check("rapid_start_stop_preserves_final_item", scheme() == "file" && !controller.playbackRequested && controller.mediaNetworkRoute == "本地文件")
        controller.pause()
        let result: [String: Any] = ["passed": true, "scope": "Local HTTP and real AVPlayer, injected direct-denied/slow responses, not system proxy or real-world playback", "checks": checks]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(json + Data("\n".utf8))
    }
}
