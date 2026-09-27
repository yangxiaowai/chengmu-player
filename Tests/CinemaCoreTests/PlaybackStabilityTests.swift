import Foundation
import Testing
@testable import CinemaCore
struct PlaybackStabilityTests {
    @Test func preparationDoesNotDisappearWhenTransportIsPaused() {
        let status = PlaybackStabilityPolicy.loadingState(item: .preparing, transport: .paused, playbackRequested: true, seeking: false, hasError: false)
        #expect(status.isLoading && status.message == "正在准备媒体")
    }
    @Test func pausedReadyItemDoesNotShowStaleBuffering() {
        let status = PlaybackStabilityPolicy.loadingState(item: .ready, transport: .waiting, playbackRequested: false, seeking: false, hasError: false)
        #expect(!status.isLoading && status.message == nil)
    }
    @Test func playingAndFatalFailuresClearLoadingWhilePendingSeekHasItsOwnMessage() {
        #expect(!PlaybackStabilityPolicy.loadingState(item: .ready, transport: .playing, playbackRequested: true, seeking: false, hasError: false).isLoading)
        #expect(!PlaybackStabilityPolicy.loadingState(item: .failed, transport: .waiting, playbackRequested: true, seeking: true, hasError: true).isLoading)
        #expect(PlaybackStabilityPolicy.loadingState(item: .ready, transport: .paused, playbackRequested: false, seeking: true, hasError: false).message == "正在定位画面")
    }
    @Test func endRequiresActualEOFAndLatestSeekWithoutPendingTarget() {
        #expect(PlaybackStabilityPolicy.acceptsEnd(actualTime: 120, duration: 120, seeking: false, seekMatches: true))
        #expect(!PlaybackStabilityPolicy.acceptsEnd(actualTime: 20, duration: 120, seeking: false, seekMatches: true))
        #expect(!PlaybackStabilityPolicy.acceptsEnd(actualTime: 120, duration: 120, seeking: true, seekMatches: true))
        #expect(!PlaybackStabilityPolicy.acceptsEnd(actualTime: 120, duration: 120, seeking: false, seekMatches: false))
        #expect(!PlaybackStabilityPolicy.acceptsEnd(actualTime: .nan, duration: 120, seeking: false, seekMatches: true))
        #expect(!PlaybackStabilityPolicy.acceptsEnd(actualTime: 0, duration: 0, seeking: false, seekMatches: true))
    }
    @Test func recoveryIsSuggestedOnlyAfterContinuousFifteenSecondWait() {
        #expect(!PlaybackStabilityPolicy.shouldSuggestRecovery(isLoading: true, elapsed: 14.99))
        #expect(PlaybackStabilityPolicy.shouldSuggestRecovery(isLoading: true, elapsed: 15))
        #expect(!PlaybackStabilityPolicy.shouldSuggestRecovery(isLoading: false, elapsed: 30))
    }
}
