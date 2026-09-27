import Testing
@testable import CinemaCore

struct PlaybackTimecodeTests {
    @Test func acceptsSupportedFormats() throws {
        #expect(try PlaybackTimecode.seconds(from: " 90.5 ", duration: 7200) == 90.5)
        #expect(try PlaybackTimecode.seconds(from: "24:04", duration: 7200) == 1444)
        #expect(try PlaybackTimecode.seconds(from: "1:02:03.25", duration: 7200) == 3723.25)
        #expect(try PlaybackTimecode.seconds(from: "90:00", duration: 7200) == 5400)
        #expect(try PlaybackTimecode.seconds(from: "0", duration: 90) == 0)
        #expect(try PlaybackTimecode.seconds(from: "1:30", duration: 90) == 90)
    }
    @Test(arguments: ["", "-1", "+1", "NaN", "inf", "1e3", "1::2", ":20", "1:60", "1:60:00", "1:2:60", "1.5:02", "1:02:03:04", "１:２０", "1 :02", "1.", "9999999999999999999999999999999999999999"])
    func rejectsMalformedTime(input: String) {
        #expect(throws: PlaybackTimecode.Failure.invalidFormat) { try PlaybackTimecode.seconds(from: input, duration: 7200) }
    }
    @Test func rejectsBeyondDurationAndUnavailableTimeline() {
        #expect(throws: PlaybackTimecode.Failure.outOfRange) { try PlaybackTimecode.seconds(from: "91", duration: 90) }
        for duration in [0, -1, Double.nan, Double.infinity] {
            #expect(throws: PlaybackTimecode.Failure.unavailable) { try PlaybackTimecode.seconds(from: "10", duration: duration) }
        }
    }
}
