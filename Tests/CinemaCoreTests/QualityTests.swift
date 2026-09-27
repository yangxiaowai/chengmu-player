import Testing
@testable import CinemaCore

struct QualityTests {
    @Test func testWideFrameFills4KWithoutStretching() {
        #expect(QualityPolicy.target4K(width: 1920, height: 1080) == PixelSize(width: 3840, height: 2160))
        #expect(QualityPolicy.target4K(width: 1920, height: 800) == PixelSize(width: 3840, height: 1600))
    }
    @Test func testPortraitAndExisting4KPreservePixels() {
        #expect(QualityPolicy.target4K(width: 720, height: 1280) == PixelSize(width: 1215, height: 2160))
        #expect(QualityPolicy.target4K(width: 7680, height: 4320) == PixelSize(width: 7680, height: 4320))
        #expect(QualityPolicy.target4K(width: 0, height: 1080) == PixelSize(width: 0, height: 0))
    }
    @Test func testTransientSpikeDoesNotDisableButSustainedOverloadDoes() {
        var budget = FrameBudget()
        let firstOverrun = budget.record(milliseconds: 100, framesPerSecond: 30)
        #expect(!firstOverrun)
        for _ in 0..<9 { _ = budget.record(milliseconds: 100, framesPerSecond: 30) }
        #expect(budget.shouldFallback)
        budget.reset()
        for _ in 0..<30 { _ = budget.record(milliseconds: 5, framesPerSecond: 60) }
        #expect(!budget.shouldFallback)
    }
    @Test func testPlaybackRateTightensBudget() {
        var budget = FrameBudget()
        for _ in 0..<12 { _ = budget.record(milliseconds: 20, framesPerSecond: 60) }
        #expect(budget.shouldFallback)
    }
}
