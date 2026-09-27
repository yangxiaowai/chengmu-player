import Foundation
import Testing
@testable import CinemaCore

struct SourceTests {
    let provider = SourceProvider(id: "fixture", name: "Fixture", endpoint: URL(string: "https://catalog.example/api?token=abc")!, enabled: true)
    var title: MediaTitle { MediaTitle(id: "42", title: "Test", year: "2020", posterURL: nil, summary: "", providerID: "fixture", providerName: "Fixture") }

    @Test func testStableIdentitySurvivesLineAndEpisodeReorderingButNotMediaReplacement() throws {
        let first = Data(#"{"list":[{"vod_id":42,"vod_play_from":"HLS$$$backup","vod_play_url":"E02$https://a.test/2.m3u8#E01$https://a.test/1.m3u8$$$E01$https://b.test/1.m3u8"}]}"#.utf8)
        let reordered = Data(#"{"list":[{"vod_id":42,"vod_play_from":"backup$$$HLS","vod_play_url":"E01$https://b.test/1.m3u8$$$E01$https://a.test/1.m3u8#E02$https://a.test/2.m3u8#E03$https://a.test/3.m3u8"}]}"#.utf8)
        let a = try SourceService.parseDetail(data: first, title: title).lines[0]
        let b = try SourceService.parseDetail(data: reordered, title: title).lines[1]
        #expect(a.id == b.id)
        #expect(a.episodes[0].id == b.episodes[0].id)
        #expect(a.episodes[1].id == b.episodes[1].id)
        let replacement = Data(#"{"list":[{"vod_id":42,"vod_play_from":"HLS","vod_play_url":"E01$https://a.test/other-cut.m3u8"}]}"#.utf8)
        let changed = try SourceService.parseDetail(data: replacement, title: title).lines[0].episodes[0]
        #expect(changed.id != a.episodes[0].id)
    }

    @Test func testMultipleLinesPreserveAlignmentAndSortEpisodesWithoutRenumberingGaps() throws {
        let data = Data(#"{"list":[{"vod_id":42,"vod_name":"Test","vod_play_from":"empty$$$HLS$$$backup","vod_play_url":"$$$第10集$https://a.test/10.m3u8#第2集$https://a.test/2.m3u8#第1集$javascript:bad#第4集$https://a.test/4.m3u8$$$E01$https://b.test/1.m3u8"}]}"#.utf8)
        let detail = try SourceService.parseDetail(data: data, title: title)
        #expect(detail.lines.map(\.name) == ["HLS", "backup"])
        #expect(detail.lines[0].episodes.map(\.number) == [2, 4, 10])
        #expect(detail.lines[0].episodes[0].url.absoluteString == "https://a.test/2.m3u8")
        #expect(detail.lines[1].episodes[0].number == 1)
    }

    @Test func testHTMLSharePagesAreNotPlayableEpisodeLines() throws {
        let data = Data(#"{"list":[{"vod_id":42,"vod_play_from":"web$$$hls","vod_play_url":"E01$https://video.test/share/abc$$$E01$https://video.test/media/index.m3u8"}]}"#.utf8)
        let detail = try SourceService.parseDetail(data: data, title: title)
        #expect(detail.lines.map(\.name) == ["hls"])
    }

    @Test func testSearchPreservesProviderAndHandlesMixedIDsAndHTMLSummary() throws {
        let data = Data(#"{"list":[{"vod_id":42,"vod_name":"Test","vod_year":2020,"vod_pic":"https://a.test/poster.jpg","vod_content":"<p>Hello &amp; world</p>"},{"vod_id":"43","vod_name":"Other"},{"vod_id":44,"vod_name":""}]}"#.utf8)
        let titles = try SourceService.parseSearch(data: data, provider: provider)
        #expect(titles.map(\.id) == ["42", "43"])
        #expect(titles.first?.summary == "Hello & world")
        #expect(titles.first?.providerID == "fixture")
    }

    @Test func testProviderErrorPayloadDoesNotPretendToBeEmptyCatalog() {
        #expect(throws: (any Error).self) { try SourceService.parseSearch(data: Data(#"{"code":0,"msg":"request denied","list":[]}"#.utf8), provider: provider) }
    }

    @Test func testProviderEndpointRejectsCredentialsAndNonHTTPS() {
        for address in ["http://catalog.test/api", "https://user:secret@catalog.test/api", "file:///tmp/catalog.json"] {
            let invalid = SourceProvider(id: "bad", name: "bad", endpoint: URL(string: address)!)
            #expect(throws: (any Error).self) { try SourceService.requestURL(provider: invalid, action: "list", parameters: [:]) }
        }
    }

    @Test func detailUsesActualCatalogTitleToRejectChangedSeasonAndFallsBackOnEmptyFields() throws {
        let searched = MediaTitle(id: "42", title: "怪奇物语第一季", year: "2016", posterURL: URL(string: "https://a.test/poster.jpg"), summary: "Search description", providerID: "fixture", providerName: "Fixture")
        let changed = Data(#"{"list":[{"vod_id":42,"vod_name":"怪奇物语第二季","vod_year":"2017","vod_play_from":"hls","vod_play_url":"E01$https://a.test/1.m3u8"}]}"#.utf8)
        let actual = try SourceService.parseDetail(data: changed, title: searched)
        #expect(actual.title.title == "怪奇物语第二季")
        #expect(actual.title.year == "2017")
        #expect(!SourceMatching.sameSeasonTitle(searched, actual.title))
        #expect(actual.title.id == "42")
        #expect(actual.title.providerID == "fixture")
        let blank = Data(#"{"list":[{"vod_id":42,"vod_name":"","vod_year":"","vod_pic":"","vod_content":"","vod_play_from":"hls","vod_play_url":"E01$https://a.test/1.m3u8"}]}"#.utf8)
        #expect(try SourceService.parseDetail(data: blank, title: searched).title == searched)
        let wrongID = Data(#"{"list":[{"vod_id":43,"vod_name":"怪奇物语第一季","vod_play_from":"hls","vod_play_url":"E01$https://a.test/1.m3u8"}]}"#.utf8)
        #expect(throws: (any Error).self) { try SourceService.parseDetail(data: wrongID, title: searched) }
    }

    @Test func testQueryUsesURLComponentsWithoutLosingExistingParameters() throws {
        let url = try SourceService.requestURL(provider: provider, action: "list", parameters: ["wd": "怪奇 & + 物语"])
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.first { $0.name == "wd" }?.value == "怪奇 & + 物语")
        #expect(items.first { $0.name == "token" }?.value == "abc")
    }

    @Test func testHLSRelativeSegmentsAndEncryptionAndDuration() throws {
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:9.5,\n../segments/one.ts\n#EXTINF:8.25,\ntwo.ts\n#EXT-X-ENDLIST"
        let info = try HLSProbe.parse(text: text, url: URL(string: "https://video.test/season/index.m3u8")!)
        #expect(abs(info.duration - 17.75) <= 0.001)
        #expect(info.segmentCount == 2)
        #expect(info.firstSegmentURL?.absoluteString == "https://video.test/segments/one.ts")
        #expect(info.encrypted)
        #expect(info.isComplete)
    }

    @Test func testHLSRejectsHTMLAndMetadataOnly() {
        #expect(throws: (any Error).self) { try HLSProbe.parse(text: "<html>error</html>", url: URL(string: "https://a.test/x")!) }
        #expect(throws: (any Error).self) { try HLSProbe.parse(text: "#EXTM3U\n#EXT-X-VERSION:3", url: URL(string: "https://a.test/x")!) }
    }

    @Test func testMasterSelectsHighestResolutionAndResolvesRelativeVariant() throws {
        let variants = try HLSProbe.variants(text: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\nsmall/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080,CODECS=\"avc1.640028,mp4a.40.2\"\n../hd/index.m3u8", url: URL(string: "https://a.test/master/index.m3u8")!)
        #expect(variants.first?.url.absoluteString == "https://a.test/hd/index.m3u8")
        #expect(variants.first?.width == 1920)
        #expect(variants.first?.codecs == "avc1.640028,mp4a.40.2")
    }
}
