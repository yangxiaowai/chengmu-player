import Foundation
import Testing
@testable import CinemaCore

struct EnhancementTargetTests {
    @Test func testExplicitTargetsAndAspectRatio() {
        #expect(EnhancementResolution.fullHD.target(width: 3840, height: 2160, automatic4K: false) == PixelSize(width: 1920, height: 1080))
        #expect(EnhancementResolution.fullHD.target(width: 1280, height: 544, automatic4K: false) == PixelSize(width: 1920, height: 816))
        #expect(EnhancementResolution.fullHD.target(width: 540, height: 960, automatic4K: false) == PixelSize(width: 1080, height: 1920))
        #expect(EnhancementResolution.source.target(width: 640, height: 360, automatic4K: true) == PixelSize(width: 640, height: 360))
        #expect(EnhancementResolution.automatic.target(width: 640, height: 360, automatic4K: false) == PixelSize(width: 640, height: 360))
        #expect(EnhancementResolution.automatic.target(width: 640, height: 360, automatic4K: true) == PixelSize(width: 3840, height: 2160))
        #expect(EnhancementResolution.fullHD.target(width: 0, height: 20, automatic4K: false) == PixelSize(width: 0, height: 0))
    }
    @Test func testOldPreferencesMigrateWithoutChangingMode() throws {
        let old = try JSONDecoder().decode(PlaybackPreferences.self, from: Data(#"{"enhancement":"restoration","pipeline":"enhanced"}"#.utf8))
        #expect(old.enhancement == "restoration")
        #expect(old.targetResolution == .automatic)
        #expect(old.targetFrameRate == .source)
        var next = old
        next.setTargetResolution(.fullHD); next.setTargetFrameRate(.fps60)
        #expect(try JSONDecoder().decode(PlaybackPreferences.self, from: JSONEncoder().encode(next)) == next)
    }
    @Test func testTimingCountsCompletedTailLatencyAndHeadroom() {
        let result = ProcessingTimingSummary(samples: Array(repeating: 10, count: 18) + [30, 90], sourceFPS: 60)!
        #expect(result.p95MS == 30)
        #expect(abs(result.overBudgetRatio - 0.1) < 0.0001)
        #expect(!result.hasHeadroom)
        #expect(ProcessingTimingSummary(samples: [.nan], sourceFPS: 60) == nil)
        #expect(ProcessingTimingSummary(samples: [1], sourceFPS: 0) == nil)
    }
}
