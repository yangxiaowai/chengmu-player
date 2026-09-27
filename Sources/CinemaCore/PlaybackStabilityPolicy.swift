import Foundation

public enum PlaybackPreparationState: Sendable { case absent, preparing, ready, failed }
public enum PlaybackTransportState: Sendable { case paused, waiting, playing }
public struct PlaybackLoadingState: Equatable, Sendable {
    public let isLoading: Bool
    public let message: String?
}
public enum PlaybackStabilityPolicy {
    public static func loadingState(item: PlaybackPreparationState, transport: PlaybackTransportState, playbackRequested: Bool, seeking: Bool, hasError: Bool) -> PlaybackLoadingState {
        guard !hasError, item != .absent, item != .failed else { return PlaybackLoadingState(isLoading: false, message: nil) }
        if item == .preparing { return PlaybackLoadingState(isLoading: true, message: "正在准备媒体") }
        if seeking { return PlaybackLoadingState(isLoading: true, message: "正在定位画面") }
        if playbackRequested, transport != .playing { return PlaybackLoadingState(isLoading: true, message: "正在缓冲") }
        return PlaybackLoadingState(isLoading: false, message: nil)
    }
    public static func acceptsEnd(actualTime: Double, duration: Double, seeking: Bool, seekMatches: Bool) -> Bool {
        !seeking && seekMatches && actualTime.isFinite && duration.isFinite && duration > 0 && abs(actualTime - duration) <= 0.5
    }
    public static func shouldSuggestRecovery(isLoading: Bool, elapsed: Double) -> Bool { isLoading && elapsed.isFinite && elapsed >= 15 }
}
