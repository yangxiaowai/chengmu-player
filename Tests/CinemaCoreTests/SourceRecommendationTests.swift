import Foundation
import Testing
@testable import CinemaCore

struct SourceRecommendationTests {
    private func item(_ id: String, provider: String = "p", width: Int? = nil, height: Int? = nil,
                      latency: Int? = nil, url: String? = nil) -> SourceRecommendationCandidate {
        let title = MediaTitle(id: id, title: "示例", year: "", posterURL: nil, summary: "", providerID: provider, providerName: provider)
        let quality = width.flatMap { w in height.map { MediaQualitySample(width: w, height: $0) } }
        return SourceRecommendationCandidate(title: title, mediaURL: url.flatMap(URL.init(string:)), quality: quality,
                                             response: latency.map(MediaResponseSample.init(milliseconds:)))
    }

    @Test func measuredQualityThenLatencyDeterminesOrder() {
        let values = [item("slow1080", width: 1920, height: 1080, latency: 400),
                      item("fast720", width: 1280, height: 720, latency: 20),
                      item("fast1080", width: 1920, height: 1080, latency: 50),
                      item("4k", width: 3840, height: 2160, latency: 800)]
        let page = SourceRecommendationPolicy.rank(values)
        #expect(page.candidates.map(\.title.id) == ["4k", "fast1080", "slow1080", "fast720"])
        #expect(page.remainingCount == 0)
    }

    @Test func unknownMeasurementsStayAvailableAndNeverLookMeasured() {
        let values = [item("unknown"), item("fastOnly", latency: 3),
                      item("qualityOnly", width: 3840, height: 2160),
                      item("both", width: 640, height: 360, latency: 1000),
                      item("invalid", width: 0, height: 1080, latency: 40)]
        let page = SourceRecommendationPolicy.rank(values)
        #expect(page.candidates.map(\.title.id) == ["both", "qualityOnly", "fastOnly", "invalid", "unknown"])
        #expect(page.candidates[1].response == nil)
        #expect(page.candidates[2].quality == nil)
    }

    @Test func tiesAreStableAndDefaultShowsFiveWithTheRestAccessible() {
        let values = (0..<8).map { item("\($0)", width: 1920, height: 1080, latency: 50) }
        let first = SourceRecommendationPolicy.rank(values)
        #expect(first.candidates.map(\.title.id) == ["0", "1", "2", "3", "4"])
        #expect(first.remainingCount == 3)
        let expanded = SourceRecommendationPolicy.rank(values, limit: 20)
        #expect(expanded.candidates.map(\.title.id) == (0..<8).map(String.init))
        #expect(expanded.remainingCount == 0)
        #expect(SourceRecommendationPolicy.rank(values, limit: -1).candidates.isEmpty)
    }

    @Test func duplicateTitleIsRemovedButSharedSampleURLRetainsDistinctSources() {
        let values = [item("same", latency: 30), item("same", width: 1920, height: 1080, latency: 60),
                      item("sharedA", provider: "a", width: 1280, height: 720, latency: 100, url: "https://x.test/video.m3u8?token=1"),
                      item("sharedB", provider: "b", width: 1920, height: 1080, latency: 200, url: "https://x.test/video.m3u8?token=1"),
                      item("differentToken", provider: "c", latency: 100, url: "https://x.test/video.m3u8?token=2")]
        let page = SourceRecommendationPolicy.rank(values)
        #expect(page.candidates.map(\.title.id) == ["same", "sharedB", "sharedA", "differentToken"])
        #expect(page.candidates[0].quality?.width == 1920)
    }
}
