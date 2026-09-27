import Foundation
import Testing
@testable import CinemaCore

struct PlaybackCanvasClickPolicyTests {
    private let point = CGPoint(x: 80, y: 60)

    @Test func aSingleClickWaitsForDoubleClickWindowAndTogglesOnlyOnce() throws {
        var policy = PlaybackCanvasClickPolicy()
        policy.pointerDown(button: 0, clickCount: 1, at: point)
        #expect(policy.pointerUp(button: 0, at: point, insideCanvas: true, now: 10, doubleClickInterval: 0.5) == nil)
        let pending = try #require(policy.pendingSingleClick)
        #expect(policy.fireSingleClick(pending.id, now: 10.49) == nil)
        #expect(policy.fireSingleClick(pending.id, now: 10.5) == .togglePlayback)
        #expect(policy.fireSingleClick(pending.id, now: 11) == nil)
    }

    @Test func doubleClickSwitchesFullscreenWithoutPausing() throws {
        var policy = singleClick()
        let pending = try #require(policy.pendingSingleClick)
        policy.pointerDown(button: 0, clickCount: 2, at: point)
        #expect(policy.fireSingleClick(pending.id, now: 11) == nil)
        #expect(policy.pointerUp(button: 0, at: point, insideCanvas: true, now: 10.2, doubleClickInterval: 0.5) == .toggleFullscreen)
        #expect(policy.pendingSingleClick == nil)
        #expect(policy.fireSingleClick(pending.id, now: 12) == nil)
    }

    @Test func aThirdClickDoesNotAddPlaybackOrFullscreenActions() {
        var policy = singleClick()
        policy.pointerDown(button: 0, clickCount: 2, at: point)
        #expect(policy.pointerUp(button: 0, at: point, insideCanvas: true, now: 10.2, doubleClickInterval: 0.5) == .toggleFullscreen)
        policy.pointerDown(button: 0, clickCount: 3, at: point)
        #expect(policy.pointerUp(button: 0, at: point, insideCanvas: true, now: 10.3, doubleClickInterval: 0.5) == nil)
        #expect(policy.pendingSingleClick == nil)
    }

    @Test(arguments: [1, 2]) func secondaryButtonsCannotTogglePlaybackOrFullscreen(button: Int) throws {
        var policy = singleClick()
        let pending = try #require(policy.pendingSingleClick)
        policy.pointerDown(button: button, clickCount: 2, at: point)
        #expect(policy.pointerUp(button: button, at: point, insideCanvas: true, now: 10.2, doubleClickInterval: 0.5) == nil)
        #expect(policy.fireSingleClick(pending.id, now: 11) == nil)
    }

    @Test func draggingAwayAndBackIsNotAClick() {
        var policy = PlaybackCanvasClickPolicy()
        policy.pointerDown(button: 0, clickCount: 1, at: point)
        policy.pointerDragged(to: CGPoint(x: 90, y: 60))
        policy.pointerDragged(to: point)
        #expect(policy.pointerUp(button: 0, at: point, insideCanvas: true, now: 10, doubleClickInterval: 0.5) == nil)
        #expect(policy.pendingSingleClick == nil)
    }

    @Test func draggingTheSecondClickDoesNotToggleFullscreen() throws {
        var policy = singleClick()
        let pending = try #require(policy.pendingSingleClick)
        policy.pointerDown(button: 0, clickCount: 2, at: point)
        policy.pointerDragged(to: CGPoint(x: 95, y: 60))
        #expect(policy.pointerUp(button: 0, at: point, insideCanvas: true, now: 10.2, doubleClickInterval: 0.5) == nil)
        #expect(policy.fireSingleClick(pending.id, now: 11) == nil)
    }

    @Test func releaseOutsideCanvasCannotTogglePlayback() {
        var policy = PlaybackCanvasClickPolicy()
        policy.pointerDown(button: 0, clickCount: 1, at: point)
        #expect(policy.pointerUp(button: 0, at: point, insideCanvas: false, now: 10, doubleClickInterval: 0.5) == nil)
        #expect(policy.pendingSingleClick == nil)
    }

    @Test func releaseMovementIsCheckedEvenWithoutDragEvents() {
        var policy = PlaybackCanvasClickPolicy()
        policy.pointerDown(button: 0, clickCount: 1, at: point)
        #expect(policy.pointerUp(button: 0, at: CGPoint(x: 80, y: 70), insideCanvas: true, now: 10, doubleClickInterval: 0.5) == nil)
        #expect(policy.pendingSingleClick == nil)
    }

    @Test func smallPointerJitterStillCountsAsASingleClick() throws {
        var policy = PlaybackCanvasClickPolicy()
        policy.pointerDown(button: 0, clickCount: 1, at: point)
        policy.pointerDragged(to: CGPoint(x: 81, y: 60))
        _ = policy.pointerUp(button: 0, at: CGPoint(x: 81, y: 61), insideCanvas: true, now: 10, doubleClickInterval: 0.5)
        let pending = try #require(policy.pendingSingleClick)
        #expect(policy.fireSingleClick(pending.id, now: 10.5) == .togglePlayback)
    }

    @Test func leavingOrDeactivatingTheCanvasCancelsPendingAndPressedClicks() throws {
        var policy = singleClick()
        let pending = try #require(policy.pendingSingleClick)
        policy.cancel()
        #expect(policy.fireSingleClick(pending.id, now: 11) == nil)
        policy.pointerDown(button: 0, clickCount: 1, at: point)
        policy.cancel()
        #expect(policy.pointerUp(button: 0, at: point, insideCanvas: true, now: 12, doubleClickInterval: 0.5) == nil)
        #expect(policy.pendingSingleClick == nil)
    }

    @Test func aStaleTimerCannotTogglePlaybackForANewerClick() throws {
        var policy = singleClick()
        let old = try #require(policy.pendingSingleClick)
        policy.cancel()
        policy.pointerDown(button: 0, clickCount: 1, at: point)
        _ = policy.pointerUp(button: 0, at: point, insideCanvas: true, now: 20, doubleClickInterval: 0.5)
        let current = try #require(policy.pendingSingleClick)
        #expect(policy.fireSingleClick(old.id, now: 21) == nil)
        #expect(policy.fireSingleClick(current.id, now: 21) == .togglePlayback)
    }

    @Test func aClickSequenceStartedOnAnotherControlCannotToggleFullscreen() {
        var policy = PlaybackCanvasClickPolicy()
        policy.pointerDown(button: 0, clickCount: 2, at: point)
        #expect(policy.pointerUp(button: 0, at: point, insideCanvas: true, now: 10, doubleClickInterval: 0.5) == nil)
        #expect(policy.pendingSingleClick == nil)
    }

    private func singleClick() -> PlaybackCanvasClickPolicy {
        var policy = PlaybackCanvasClickPolicy()
        policy.pointerDown(button: 0, clickCount: 1, at: point)
        _ = policy.pointerUp(button: 0, at: point, insideCanvas: true, now: 10, doubleClickInterval: 0.5)
        return policy
    }
}
