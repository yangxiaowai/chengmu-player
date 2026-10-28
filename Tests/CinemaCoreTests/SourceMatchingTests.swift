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

    @Test func movieRequiresSingleMainFeatureOrExplicitMovieCategoryAndRejectsSeries() {
        func detail(_ name: String, category: String?, episodeNames: [[String]]) -> MediaDetail {
            var value = title(name)
            value.category = category
            let lines = episodeNames.enumerated().map { index, names in
                PlaybackLine(id: "\(index)", name: "线路", episodes: names.enumerated().map { number, name in
                    episode(name, number: number + 1, id: "\(index)-\(number)")
                })
            }
            return MediaDetail(title: value, lines: lines)
        }
        #expect(SourceMatching.isConfirmedMovie(detail("星际穿越", category: "科幻片", episodeNames: [["HD"]])))
        #expect(SourceMatching.isConfirmedMovie(detail("星际穿越", category: nil, episodeNames: [["正片"], ["正片"]])))
        #expect(!SourceMatching.isConfirmedMovie(detail("无季号剧集", category: "国产剧", episodeNames: [["正片"]])))
        #expect(!SourceMatching.isConfirmedMovie(detail("无季号剧集", category: nil, episodeNames: [["第1集"]])))
        #expect(!SourceMatching.isConfirmedMovie(detail("无季号剧集", category: "剧情片", episodeNames: [["第1集", "第2集"]])))
        #expect(!SourceMatching.isConfirmedMovie(detail("某剧第一季", category: "电影", episodeNames: [["正片"]])))
        #expect(!SourceMatching.isConfirmedMovie(detail("空作品", category: "电影", episodeNames: [])))
        #expect(!SourceMatching.isConfirmedMovie(detail("示例纪录", category: "纪录片", episodeNames: [["HD"]])))
        #expect(!SourceMatching.isConfirmedMovie(detail("示例动画", category: "动画片", episodeNames: [["HD"]])))
        #expect(SourceMatching.isConfirmedMovie(detail("示例纪录", category: "纪录片", episodeNames: [["正片"]])))
        #expect(SourceMatching.isConfirmedMovie(detail("示例动画", category: "动画片", episodeNames: [["正片"]])))
    }

    @Test func movieCandidatesRequireExactTitleAndKnownMatchingYearAndExcludeSeries() {
        var current = title("星际穿越", id: "a", provider: "a")
        current.year = "2014"; current.category = "电影"
        let line = PlaybackLine(id: "a:main", name: "正片", episodes: [episode("正片", number: nil)])
        let detail = MediaDetail(title: current, lines: [line])
        var good = title(" 星际穿越 ", id: "b", provider: "b"); good.year = "2014"; good.category = "科幻片"
        var unknownYear = title("星际穿越", id: "c", provider: "c"); unknownYear.year = ""
        var remake = title("星际穿越", id: "d", provider: "d"); remake.year = "2020"
        var series = title("星际穿越", id: "e", provider: "e"); series.year = "2014"; series.category = "国产剧"
        var different = title("星际穿越解说", id: "f", provider: "f"); different.year = "2014"
        #expect(SourceMatching.sameMovieTitle(current, good))
        #expect(!SourceMatching.sameMovieTitle(current, unknownYear))
        #expect(!SourceMatching.sameMovieTitle(current, remake))
        #expect(!SourceMatching.sameMovieTitle(current, series))
        #expect(!SourceMatching.sameMovieTitle(current, different))
        #expect(SourceMatching.movieCandidates(current: detail, results: [current, good, good, unknownYear, remake, series, different]) == [good])
        var noYear = detail; noYear.title.year = ""
        #expect(SourceMatching.movieCandidates(current: noYear, results: [good]).isEmpty)
    }

    @Test func wikimediaClipsAreNeverGroupedAsOtherProvidersMoviesOrSeasons() {
        var commonMovie = title("星际穿越", id: "commons-1", provider: "wikimedia-commons")
        commonMovie.year = "2014"; commonMovie.category = "电影"
        var regularMovie = title("星际穿越", id: "other", provider: "b")
        regularMovie.year = "2014"; regularMovie.category = "电影"
        #expect(!SourceMatching.sameMovieTitle(commonMovie, regularMovie))
        #expect(!SourceMatching.sameMovieTitle(regularMovie, commonMovie))
        let episode = episode("正片", number: nil)
        let line = PlaybackLine(id: "main", name: "正片", episodes: [episode])
        #expect(!SourceMatching.isConfirmedMovie(MediaDetail(title: commonMovie, lines: [line])))
        #expect(SourceMatching.movieCandidates(current: MediaDetail(title: commonMovie, lines: [line]), results: [regularMovie]).isEmpty)
        #expect(SourceMatching.movieCandidates(current: MediaDetail(title: regularMovie, lines: [line]), results: [commonMovie]).isEmpty)
        let commonSeason = title("怪奇物语第一季", provider: "wikimedia-commons")
        let regularSeason = title("怪奇物语第一季", provider: "b")
        #expect(!SourceMatching.sameSeasonTitle(commonSeason, regularSeason))
        #expect(!SourceMatching.sameSeasonTitle(regularSeason, commonSeason))
        #expect(SourceMatching.candidates(current: commonSeason, results: [regularSeason]).isEmpty)
        #expect(SourceMatching.candidates(current: regularSeason, results: [commonSeason]).isEmpty)
    }
}
