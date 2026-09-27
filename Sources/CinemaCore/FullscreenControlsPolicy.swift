import Foundation

/// Decides whether fullscreen playback may hide its controls after user inactivity.
public struct FullscreenControlsPolicy {
    public static let idleDelay: TimeInterval = 3

    public static func shouldHide(
        isFullscreen: Bool,
        isPlaying: Bool,
        isBuffering: Bool,
        hasError: Bool,
        isInteracting: Bool,
        isActive: Bool,
        idleFor: TimeInterval
    ) -> Bool {
        isFullscreen && isPlaying && isActive
            && !isBuffering && !hasError && !isInteracting
            && idleFor.isFinite && idleFor >= idleDelay
    }
}
