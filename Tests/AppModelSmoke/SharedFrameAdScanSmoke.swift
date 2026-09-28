import Foundation
import AppKit
import AVFoundation
import CoreImage
import CinemaCore

/// Verifies the shared-frame contract for local ad recognition on a synthetic local MP4:
/// the production enhancement surface hands out a frame it already decoded, that frame is
/// classified by the same OCR pipeline the scanner uses, the scanner accepts a supplied frame
/// instead of opening its own decoder, and it refuses frames while scanning is disabled.
///
/// Real AVPlayer, real Vision OCR, real `CinemaVideoView`. No injected detections, no media
/// library, no network, and no claim about provider advertisement accuracy.
@main struct SharedFrameAdScanSmoke {
    @MainActor static func main() async {
        guard CommandLine.arguments.count >= 3, CommandLine.arguments.contains("--validate") else { exit(2) }
        let media = URL(fileURLWithPath: CommandLine.arguments[1])
        let report = URL(fileURLWithPath: CommandLine.arguments[2])
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail]); print(passed ? "PASS" : "FAIL", name, detail)
        }
        _ = NSApplication.shared

        // 1. The enhancement surface supplies the frame that recognition will classify.
        let item = AVPlayerItem(url: media)
        let player = AVPlayer(playerItem: item); player.isMuted = true; player.volume = 0
        let view = CinemaVideoView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        var latest = EnhancementMetrics()
        var offered = 0
        var shared: (CGImage, Double)?
        view.onScanFrame = { image, time in
            offered += 1
            if shared == nil { shared = (image, time) }
        }
        view.configure(player: player, mode: .clarity, generation: UUID(), cleanup: .init(),
                       permission: .inspectSDRFrames, assessedItem: item, onMetrics: { latest = $0 })
        player.playImmediately(atRate: 1)
        let frameDeadline = Date().addingTimeInterval(20)
        while (shared == nil || latest.processedFrames == 0), Date() < frameDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        player.pause()
        check("enhancement_supplies_a_frame_it_already_decoded", latest.processedFrames > 0 && offered > 0,
              "enhanced=" + String(latest.processedFrames) + " offered=" + String(offered))

        // 2. That frame goes through the same classifier the independent decoder uses.
        if let (image, time) = shared {
            let probe = AdFrameAnalyzer()
            probe.configure(url: media)
            let observation = await probe.classify(image: image, time: time, protectedRegions: [AdCleanupSettings.defaultProtection])
            probe.cancel()
            check("shared_frame_is_classified_without_a_second_decode", observation != nil,
                  "time=" + String(time) + " class=" + String(describing: observation?.classification))
        } else {
            check("shared_frame_is_classified_without_a_second_decode", false, "the surface never offered a frame")
        }
        view.onScanFrame = nil
        view.stop(); player.replaceCurrentItem(with: nil)

        // 3. The scanner routes a supplied frame through its own recognition path.
        let controller = AdSkipController()
        controller.configure(url: media, itemID: UUID(), protectedRegions: [AdCleanupSettings.defaultProtection])
        controller.update(position: 18, duration: 40, shouldScan: true)
        let accepted = controller.harvest(image: blankImage(), time: 18)
        check("scanner_accepts_a_shared_frame", accepted && controller.isUsingSharedFrames,
              "accepted=" + String(accepted) + " source=" + controller.frameSource)
        let analyzedBefore = controller.analyzedFrames
        let deadline = Date().addingTimeInterval(12)
        while controller.analyzedFrames == analyzedBefore, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        check("shared_frame_becomes_recorded_evidence", controller.analyzedFrames > analyzedBefore,
              "analyzed=" + String(controller.analyzedFrames))

        // 4. Nothing is harvested while scanning is disabled.
        controller.update(position: 18, duration: 40, shouldScan: false)
        check("disabled_scanning_refuses_shared_frames", !controller.harvest(image: blankImage(), time: 20))
        controller.stop()
        controller.configure(url: nil, itemID: UUID(), protectedRegions: [])

        // Recognition of the current playback frame must not abandon future samples. Otherwise
        // the inserted ad can only be confirmed after the viewer has already watched it.
        let lookAhead = AdSkipController()
        lookAhead.configure(url: media, itemID: UUID(), protectedRegions: [])
        lookAhead.update(position: 0.2, duration: 40, shouldScan: true)
        let sharedAccepted = lookAhead.harvest(image: blankImage(), time: 2)
        let advanceDeadline = Date().addingTimeInterval(9)
        while lookAhead.analyzedFrames < 3, Date() < advanceDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let advanced = sharedAccepted && lookAhead.analyzedFrames >= 3
        check("shared_current_frame_keeps_future_lookahead_active", advanced,
              "accepted=" + String(sharedAccepted) + " analyzed=" + String(lookAhead.analyzedFrames)
                + " status=" + lookAhead.status)
        if advanced {
            let segmentDeadline = Date().addingTimeInterval(40)
            while lookAhead.segments.isEmpty, Date() < segmentDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            check("future_insert_is_found_before_playback_reaches_it",
                  lookAhead.segments.contains(where: { $0.start >= 14 && $0.start <= 18 && $0.end >= 26 && $0.end <= 30 }),
                  "position=0.2 segments=" + String(describing: lookAhead.segments))
        } else {
            check("future_insert_is_found_before_playback_reaches_it", false, "lookahead was cancelled by shared frame")
        }
        lookAhead.stop()

        // The complete production path must still skip while the enhancement view is attached.
        let playback = PlaybackController()
        playback.volume = 0; playback.player.isMuted = true
        playback.setRate(2)
        playback.open(url: media, title: "同步增强与识别", episode: "合成插播")
        let combinedView = CinemaVideoView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        var combinedMetrics = EnhancementMetrics()
        var handoffs = 0
        var acceptedHandoffs = 0
        combinedView.onScanFrame = { image, time in
            handoffs += 1
            if playback.harvestScanFrame(image, time: time) { acceptedHandoffs += 1 }
        }
        combinedView.configure(player: playback.player, mode: playback.surfaceMode, generation: playback.generation,
                               permission: playback.videoPermission, assessedItem: playback.player.currentItem,
                               onMetrics: { combinedMetrics = $0 })
        let skipDeadline = Date().addingTimeInterval(25)
        while playback.adSkipNotice == nil, Date() < skipDeadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let event = playback.adSkipNotice
        check("enhancement_and_scan_run_together", combinedMetrics.processedFrames > 0 && acceptedHandoffs > 0,
              "enhanced=" + String(combinedMetrics.processedFrames) + " offered=" + String(handoffs)
                + " accepted=" + String(acceptedHandoffs))
        check("combined_player_skips_insert_before_it_ends",
              event.map { $0.returnPosition >= 16 && $0.returnPosition < 25 && playback.player.currentTime().seconds >= 25.8 } ?? false,
              "return=" + String(describing: event?.returnPosition) + " position=" + String(playback.player.currentTime().seconds)
                + " scan=" + playback.adSkip.status + " analyzed=" + String(playback.adSkip.analyzedFrames)
                + " segments=" + String(describing: playback.adSkip.segments))
        playback.pause(); playback.adSkip.stop(); combinedView.onScanFrame = nil; combinedView.stop()

        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let output: [String: Any] = ["passed": passed, "checkedAt": ISO8601DateFormatter().string(from: Date()),
            "scope": "Real AVPlayer, Vision OCR, PlaybackController and CinemaVideoView on a synthetic local MP4; checks shared-frame handoff, early lookahead and automatic skip with enhancement active.",
            "checks": checks]
        try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        exit(passed ? 0 : 1)
    }

    /// A blank still is enough: the check is whether the scanner routes a supplied frame through
    /// its own recognition path instead of starting a decoder.
    static func blankImage() -> CGImage {
        let context = CIContext()
        let image = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        return context.createCGImage(image, from: image.extent)!
    }
}
