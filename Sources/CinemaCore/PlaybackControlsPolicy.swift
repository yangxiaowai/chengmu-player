import Foundation

/// Decides whether playback may hide its controls after user inactivity.
public struct PlaybackControlsPolicy {
    public static let idleDelay: TimeInterval = 3

    public static func shouldHide(
        isPlaying: Bool,
        isBuffering: Bool,
        hasError: Bool,
        isInteracting: Bool,
        isActive: Bool,
        idleFor: TimeInterval
    ) -> Bool {
        isPlaying && isActive
            && !isBuffering && !hasError && !isInteracting
            && idleFor.isFinite && idleFor >= idleDelay
    }
}
