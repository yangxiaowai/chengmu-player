import Testing
import Foundation
@testable import CinemaCore

struct SeekTimelineGeometryTests {
    @Test func thumbCentersMapToStartMiddleAndEnd() {
        #expect(SeekTimelineGeometry.time(at: 10, width: 500, knobWidth: 20, duration: 100) == 0)
        #expect(SeekTimelineGeometry.time(at: 250, width: 500, knobWidth: 20, duration: 100) == 50)
        #expect(SeekTimelineGeometry.time(at: 490, width: 500, knobWidth: 20, duration: 100) == 100)
    }
    @Test func pointsBeyondTrackClampToMediaBounds() {
        #expect(SeekTimelineGeometry.time(at: -20, width: 500, knobWidth: 20, duration: 100) == 0)
        #expect(SeekTimelineGeometry.time(at: 550, width: 500, knobWidth: 20, duration: 100) == 100)
    }
    @Test func unknownDurationAndInvalidGeometryCannotSeek() {
        for duration in [0.0, -1, .infinity, .nan] {
            #expect(SeekTimelineGeometry.time(at: 200, width: 500, knobWidth: 20, duration: duration) == nil)
        }
        #expect(SeekTimelineGeometry.time(at: .nan, width: 500, knobWidth: 20, duration: 100) == nil)
        #expect(SeekTimelineGeometry.time(at: 10, width: 20, knobWidth: 20, duration: 100) == nil)
    }
    @Test func previewCardRemainsInsideNarrowAndWideControls() {
        #expect(SeekTimelineGeometry.bubbleOrigin(at: 0, width: 500, bubbleWidth: 220) == 0)
        #expect(SeekTimelineGeometry.bubbleOrigin(at: 500, width: 500, bubbleWidth: 220) == 280)
        #expect(SeekTimelineGeometry.bubbleOrigin(at: 250, width: 500, bubbleWidth: 220) == 140)
        #expect(SeekTimelineGeometry.bubbleOrigin(at: 20, width: 100, bubbleWidth: 220) == 0)
    }
}
