import Foundation

/// A buffer target is a playback aid, not a percentage of the whole download.
public struct PlaybackBufferSnapshot {
    public let bufferedSeconds: Double?
    public let targetProgress: Double?
    /// AVFoundation's observed throughput is an aggregate estimate, not live link speed.
    public let observedBytesPerSecond: Double?

    public init(position: Double, ranges: [ClosedRange<Double>], targetSeconds: Double, observedBitsPerSecond: Double) {
        observedBytesPerSecond = observedBitsPerSecond.isFinite && observedBitsPerSecond > 0 ? observedBitsPerSecond / 8 : nil
        guard position.isFinite, position >= 0 else { bufferedSeconds = nil; targetProgress = nil; return }
        var end = position
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound.isFinite, range.upperBound.isFinite else { continue }
            if range.lowerBound <= end + 0.05 && range.upperBound >= position { end = max(end, range.upperBound) }
        }
        let ahead = max(0, end - position)
        bufferedSeconds = ahead
        targetProgress = targetSeconds.isFinite && targetSeconds > 0 ? min(1, ahead / targetSeconds) : nil
    }
}
