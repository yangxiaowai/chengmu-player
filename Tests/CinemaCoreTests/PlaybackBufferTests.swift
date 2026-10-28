import Testing
@testable import CinemaCore

struct PlaybackBufferTests {
    @Test func reportsOnlyContiguousMediaAheadOfPlayback() {
        let snapshot = PlaybackBufferSnapshot(position: 10, ranges: [0...5, 9...13, 13...16, 20...30], targetSeconds: 12, observedBitsPerSecond: 8_000_000)
        #expect(snapshot.bufferedSeconds == 6)
        #expect(snapshot.targetProgress == 0.5)
        #expect(snapshot.observedBytesPerSecond == 1_000_000)
    }

    @Test func missingInformationRemainsUnknown() {
        let snapshot = PlaybackBufferSnapshot(position: .nan, ranges: [], targetSeconds: 0, observedBitsPerSecond: -1)
        #expect(snapshot.bufferedSeconds == nil)
        #expect(snapshot.targetProgress == nil)
        #expect(snapshot.observedBytesPerSecond == nil)
    }

    @Test func clampsProgressAndDoesNotCountDisjointRanges() {
        let snapshot = PlaybackBufferSnapshot(position: 5, ranges: [7...20], targetSeconds: 12, observedBitsPerSecond: 0)
        #expect(snapshot.bufferedSeconds == 0)
        #expect(snapshot.targetProgress == 0)
        #expect(snapshot.observedBytesPerSecond == nil)
        let full = PlaybackBufferSnapshot(position: 5, ranges: [0...30], targetSeconds: 12, observedBitsPerSecond: 1)
        #expect(full.targetProgress == 1)
    }
}
