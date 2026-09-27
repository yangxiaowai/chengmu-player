import Foundation
import Testing
@testable import CinemaCore

struct SourceMatchingTests {
    func title(_ name: String, id: String = "1", provider: String = "a") -> MediaTitle {
        MediaTitle(id: id, title: name, year: "2020", posterURL: nil, summary: "", providerID: provider, providerName: provider)
    }
    func episode(_ name: String, number: Int?, id: String = "1") -> Episode {
        Episode(id: id, name: name, url: URL(string: "https://video.test/\(id).m3u8")!, number: number)
    }
    @Test func exactSeasonTitleAcceptsNotationButRejectsDifferentSeasonAndUnknownSeason() {
        #expect(SourceMatching.sameSeasonTitle(title("怪奇物语 第一季"), title("怪奇物语第1季", provider: "b")))
        #expect(!SourceMatching.sameSeasonTitle(title("怪奇物语第一季"), title("怪奇物语第二季", provider: "b")))
        #expect(!SourceMatching.sameSeasonTitle(title("火线"), title("火线", provider: "b")))
        #expect(!SourceMatching.sameSeasonTitle(title("绝命毒师第一季"), title("绝命毒师第一季导演剪辑", provider: "b")))
    }
    @Test func candidatesRetainDifferentProvidersAndRemoveDuplicatesAndCurrentVersion() {
        let current = title("怪奇物语第一季")
        let other = title("怪奇物语第1季", provider: "b")
        #expect(SourceMatching.candidates(current: current, results: [current, other, other, title("怪奇物语第二季", provider: "c")]) == [other])
    }
    @Test func episodeRequiresSameNumberAndEquivalentNameAndRejectsAmbiguity() {
        let current = episode("第01集", number: 1)
        let match = episode("E01", number: 1, id: "other")
        let line = PlaybackLine(id: "b", name: "HLS", episodes: [episode("第02集", number: 2), match])
        #expect(SourceMatching.matchEpisode(current, in: line) == match)
        #expect(SourceMatching.matchEpisode(current, in: PlaybackLine(id: "bad", name: "HLS", episodes: [episode("第02集", number: 1)])) == nil)
        #expect(SourceMatching.matchEpisode(current, in: PlaybackLine(id: "dup", name: "HLS", episodes: [match, match])) == nil)
    }
    @Test func namedEpisodeMustMatchExactlyWithoutNumberGuessing() {
        let current = episode("Pilot", number: nil)
        #expect(SourceMatching.matchEpisode(current, in: PlaybackLine(id: "x", name: "HLS", episodes: [episode("Finale", number: nil)])) == nil)
        #expect(SourceMatching.matchEpisode(current, in: PlaybackLine(id: "x", name: "HLS", episodes: [episode(" pilot ", number: nil)])) != nil)
    }
}
