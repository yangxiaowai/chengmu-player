import Foundation
import Testing
@testable import CinemaCore

struct LibraryTests {
    @Test func testResumePersistsByEpisodeAndDoesNotOverwriteAnotherEpisode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(directory: directory)
        let first = WatchRecord(id: "show:1", title: "示例剧", episode: "第01集", url: URL(string: "https://example.com/1.m3u8")!, posterURL: nil, position: 127.5, duration: 3600)
        let second = WatchRecord(id: "show:2", title: "示例剧", episode: "第02集", url: URL(string: "https://example.com/2.m3u8")!, posterURL: nil, position: 15, duration: 3500)
        try store.save([first, second])
        let loaded = try LibraryStore(directory: directory).load()
        #expect(loaded.count == 2)
        #expect(loaded.first(where: {$0.id == "show:1"})?.position == 127.5)
        try store.save([])
        #expect(try store.load() == [])
    }

    @Test func testCorruptHistoryIsReportedRatherThanSilentlyDestroyed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("history.json"))
        #expect(throws: (any Error).self) { try LibraryStore(directory: directory).load() }
    }

    @Test func testSRTParsesBOMMultilineAndMixedTimestampPunctuation() {
        let text = "\u{feff}1\r\n00:01:02,300 --> 00:01:04,800\r\n你好\r\nHello\r\n\r\n2\r\n00:01:05.000 --> 00:01:06.000\r\n<b>Next</b>"
        let cues = SubtitleParser.parse(text)
        #expect(cues.count == 2)
        #expect(abs(cues[0].start - 62.3) < 0.001)
        #expect(cues[0].text == "你好\nHello")
        #expect(SubtitleParser.text(at: 64.9, in: cues) == "")
        #expect(SubtitleParser.text(at: 65.4, in: cues) == "Next")
    }

    @Test func testASSParsesCommasAndStyleOverridesWithoutShowingMarkup() {
        let text = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\\i1}Hello, world\\N你好"
        let cues = SubtitleParser.parse(text)
        #expect(cues.count == 1)
        #expect(cues[0].text == "Hello, world\n你好")
        #expect(SubtitleParser.text(at: 4, in: cues) == "")
    }

    @Test func testBadSubtitleTimesAreRejected() {
        #expect(SubtitleParser.parse("1\n00:00:03,000 --> 00:00:01,000\nbackwards").isEmpty)
    }
}

struct HistoryContextTests {
    private func episode(_ id: String, number: Int?) -> Episode {
        Episode(id: id, name: "第\(number ?? 0)集", url: URL(string: "https://example.com/\(id).m3u8")!, number: number)
    }
    @Test func historyRestoresExactSeriesLineAndEpisode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let title = MediaTitle(id: "series", title: "示例", year: "2026", posterURL: nil, summary: "", providerID: "source", providerName: "来源")
        let first = episode("one", number: 1), second = episode("two", number: 2)
        let context = MediaDetail(title: title, lines: [PlaybackLine(id: "alternate", name: "线路", episodes: [first, second])])
        let record = WatchRecord(id: "series:one", title: title.title, episode: first.name, url: first.url, posterURL: nil, position: 60, duration: 1000, mediaDetail: context, lineID: "alternate", episodeID: first.id)
        let store = LibraryStore(directory: directory)
        try store.save([record])
        let loaded = try #require(store.load().first)
        #expect(loaded.playbackContext?.detail == context)
        #expect(loaded.playbackContext?.line.id == "alternate")
        #expect(loaded.playbackContext?.episode.id == "one")
        #expect(loaded.playbackContext?.line.episodes[1].id == "two")
    }
    @Test func legacyHistoryWithoutContextStillLoads() throws {
        let json = """
        [{"id":"old","title":"旧记录","episode":"第一集","url":"https://example.com/old.m3u8","position":18,"duration":90,"updatedAt":0}]
        """
        let loaded = try JSONDecoder().decode([WatchRecord].self, from: Data(json.utf8))
        #expect(loaded[0].position == 18)
        #expect(loaded[0].playbackContext == nil)
    }
    @Test func replacedMediaOrRenamedEpisodeCannotUseOldResumePosition() {
        let current = episode("current", number: 2)
        let record = WatchRecord(id: "shared-id", title: "剧", episode: current.name, url: current.url, posterURL: nil, position: 650, duration: 1000)
        #expect(record.canResume(episode: current))
        var changedURL = current
        changedURL.url = URL(string: "https://example.com/replacement.m3u8")!
        #expect(!record.canResume(episode: changedURL))
        var changedLabel = current
        changedLabel.name = "不同集"
        #expect(!record.canResume(episode: changedLabel))
    }
    @Test func unnumberedEpisodeSwitchRequiresExactLabel() {
        let current = Episode(id: "special", name: "特别篇", url: URL(string: "https://example.com/special.m3u8")!, number: nil)
        let other = Episode(id: "other", name: "幕后花絮", url: URL(string: "https://example.com/other.m3u8")!, number: nil)
        let destination = PlaybackLine(id: "other", name: "其他", episodes: [other])
        #expect(PlaybackLinePolicy.matchEpisode(current, in: destination) == nil)
    }
    @Test func lineSwitchDoesNotMatchDifferentEpisodeOrInventMissingContext() {
        let current = episode("current", number: 2)
        let missing = PlaybackLine(id: "missing", name: "缺集", episodes: [episode("one", number: 1), episode("three", number: 3)])
        #expect(PlaybackLinePolicy.matchEpisode(current, in: missing) == nil)
        let matching = episode("another-source-id", number: 2)
        #expect(PlaybackLinePolicy.matchEpisode(current, in: PlaybackLine(id: "new", name: "新", episodes: [matching])) == matching)
        var record = WatchRecord(id: "broken", title: "", episode: "", url: current.url, posterURL: nil, position: 0, duration: 0)
        record.lineID = "absent"
        #expect(record.playbackContext == nil)
    }
}
