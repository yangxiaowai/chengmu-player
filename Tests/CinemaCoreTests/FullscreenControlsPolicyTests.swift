import Foundation
import Testing
@testable import CinemaCore

struct FullscreenControlsPolicyTests {
    @Test func playingFullscreenKeepsControlsUntilThreeSecondsOfInactivity() {
        #expect(!shouldHide(idleFor: 0))
        #expect(!shouldHide(idleFor: 2.999))
        #expect(shouldHide(idleFor: 3))
        #expect(shouldHide(idleFor: 300))
    }

    @Test func windowedPlaybackAlwaysKeepsControlsVisible() {
        #expect(!shouldHide(isFullscreen: false, idleFor: 300))
    }

    @Test func pausingBringsControlsBackEvenAfterLongInactivity() {
        #expect(!shouldHide(isPlaying: false, idleFor: 300))
    }

    @Test func bufferingOrPlaybackErrorKeepsRecoveryControlsVisible() {
        #expect(!shouldHide(isBuffering: true, idleFor: 300))
        #expect(!shouldHide(hasError: true, idleFor: 300))
    }

    @Test func interactingOrSwitchingAwayPreventsHidingControls() {
        #expect(!shouldHide(isInteracting: true, idleFor: 300))
        #expect(!shouldHide(isActive: false, idleFor: 300))
    }

    @Test func invalidOrReversedClockValuesFailVisible() {
        for idle in [TimeInterval.nan, .infinity, -.infinity, -1] {
            #expect(!shouldHide(idleFor: idle))
        }
    }

    private func shouldHide(
        isFullscreen: Bool = true,
        isPlaying: Bool = true,
        isBuffering: Bool = false,
        hasError: Bool = false,
        isInteracting: Bool = false,
        isActive: Bool = true,
        idleFor: TimeInterval
    ) -> Bool {
        FullscreenControlsPolicy.shouldHide(
            isFullscreen: isFullscreen,
            isPlaying: isPlaying,
            isBuffering: isBuffering,
            hasError: hasError,
            isInteracting: isInteracting,
            isActive: isActive,
            idleFor: idleFor
        )
    }
}
