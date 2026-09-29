import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// A separate, inaudible decode clock. Never reads from or changes the primary AVPlayer.
/// The caller owns the startup timeout and must stop this helper on pause, seek and route changes.
@MainActor
final class LookaheadVideoDecoder {
    private let secondaryItem: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private let player: AVPlayer
    private var stopped = false
    private var started = false
    private var seekToken = UUID()
    private var lastTime: CMTime?
    private(set) var status = "等待前瞻解码就绪"
    private(set) var lastError: String?
    private(set) var isSeeking = false
    private(set) var leadSeconds: Double?
    /// The surface should discard queued frames and interpolation references when this changes.
    private(set) var discontinuityID = UUID()

    init(item: AVPlayerItem) {
        // Reuse the immutable asset (including its URL loading options), never the primary item.
        secondaryItem = AVPlayerItem(asset: item.asset)
        output = AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
            AVVideoAllowWideColorKey: true
        ])
        output.suppressesPlayerRendering = true
        secondaryItem.add(output)
        player = AVPlayer(playerItem: secondaryItem)
        player.isMuted = true
        player.volume = 0
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
    }

    func next(mainTime: Double) -> (buffer: CVPixelBuffer, time: CMTime)? {
        guard !stopped, mainTime.isFinite, mainTime >= 0 else { return nil }
        if secondaryItem.status == .failed || player.status == .failed {
            lastError = secondaryItem.error?.localizedDescription ?? player.error?.localizedDescription ?? "独立前瞻解码失败"
            status = lastError!
            return nil
        }
        guard secondaryItem.status == .readyToPlay else {
            status = "等待前瞻媒体载入"
            return nil
        }
        guard !isSeeking else { return nil }
        if !started {
            seekAhead(of: mainTime)
            return nil
        }
        let now = player.currentTime()
        guard now.isNumeric else { status = "等待前瞻解码时间"; return nil }
        let lead = now.seconds - mainTime
        leadSeconds = lead
        let duration = secondaryItem.duration
        let nearEnd = duration.isNumeric && duration.seconds - mainTime < 0.30
        if lead > 0.45 || (lead < 0.12 && !nearEnd) {
            seekAhead(of: mainTime)
            return nil
        }
        if player.rate == 0 && !nearEnd { player.playImmediately(atRate: 1) }
        guard output.hasNewPixelBuffer(forItemTime: now) else {
            status = nearEnd ? "等待片尾剩余帧" : "等待独立解码的新帧"
            return nil
        }
        var displayed = CMTime.invalid
        // Only the secondary player's present media time is requested, never a future time.
        guard let buffer = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: &displayed), displayed.isNumeric else {
            status = "前瞻帧尚未解码"
            return nil
        }
        if let lastTime, CMTimeCompare(displayed, lastTime) <= 0 { return nil }
        lastTime = displayed
        status = "独立前瞻解码中"
        return (buffer, displayed)
    }

    func cancel() { stop() }

    func stop() {
        guard !stopped else { return }
        stopped = true
        seekToken = UUID()
        discontinuityID = UUID()
        isSeeking = false
        player.pause()
        secondaryItem.cancelPendingSeeks()
        secondaryItem.remove(output)
        player.replaceCurrentItem(with: nil)
        lastTime = nil
        leadSeconds = nil
        status = "前瞻解码已停止"
    }

    private func seekAhead(of mainTime: Double) {
        let token = UUID()
        seekToken = token
        discontinuityID = UUID()
        lastTime = nil
        isSeeking = true
        status = "同步独立前瞻解码位置"
        player.pause()
        secondaryItem.cancelPendingSeeks()
        var target = mainTime + 0.30
        if secondaryItem.duration.isNumeric {
            target = min(target, max(0, secondaryItem.duration.seconds - 1.0 / 120.0))
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero,
                    toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.seekToken == token else { return }
                self.isSeeking = false
                guard finished else {
                    self.started = false
                    self.status = "前瞻定位尚未完成"
                    return
                }
                self.started = true
                self.output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
                self.player.playImmediately(atRate: 1)
                self.status = "独立前瞻解码中"
            }
        }
    }
}
