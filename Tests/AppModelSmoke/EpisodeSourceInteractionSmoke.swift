import Foundation
import AVFoundation
import CinemaCore

@main
struct EpisodeSourceInteractionSmoke {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Check: Encodable { let name: String; let passed: Bool; let detail: String }
    @MainActor static func main() async {
        guard CommandLine.arguments.contains("--validate") else { exit(2) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CinemaEpisodeSource-" + UUID().uuidString)
        var checks: [Check] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let media = directory.appendingPathComponent("silent.wav")
            try silentWave(seconds: 120).write(to: media)
            setenv("YINGCHUAN_PROFILE_DIRECTORY", directory.appendingPathComponent("profile").path, 1)
            let app = AppModel()
            app.playback.volume = 0
            defer { app.closePlayer() }
            let original = detail(provider: "a", media: media)
            app.resume(record(original, episodeIndex: 1, position: 20))
            app.playback.pause()
            try await eventually("original paused media is ready at 20 seconds") {
                app.playback.player.currentItem?.status == .readyToPlay && abs(app.playback.position - 20) < 0.3
            }
            app.switchLine("a:alternate")
            do {
                try require(!app.playback.playbackRequested, "Switching a line unexpectedly requested playback from paused state")
                try await eventually("replacement is paused at the retained position") {
                    app.playback.player.currentItem?.status == .readyToPlay && !app.playback.isPlaying && abs(app.playback.player.currentTime().seconds - 20) < 0.3
                }
                checks.append(Check(name: "paused_line_switch_preserves_intent_and_position", passed: true, detail: "Paused line switch remains paused and seeks to 20 seconds."))
            } catch { checks.append(Check(name: "paused_line_switch_preserves_intent_and_position", passed: false, detail: String(describing: error))) }
            app.closePlayer()

            func check(_ name: String, _ body: @MainActor () async throws -> String) async {
                do { checks.append(Check(name: name, passed: true, detail: try await body())) }
                catch { checks.append(Check(name: name, passed: false, detail: String(describing: error))) }
            }
            let alternative = detail(provider: "b", media: media)
            let third = detail(provider: "c", media: media)
            await check("adjacent_episodes_follow_context_and_stop_at_boundaries") {
                let value = fixture(directory: directory, original: original)
                defer { value.closePlayer() }
                try require(value.canPlayPrevious && value.canPlayNext, "Middle episode must expose both adjacent controls")
                value.previousEpisode()
                try require(value.currentEpisodeID == "a:main:1" && !value.canPlayPrevious && value.canPlayNext, "Previous must play episode 1 and disable the lower boundary")
                let firstItem = value.playback.itemID
                value.previousEpisode()
                try require(value.playback.itemID == firstItem, "Previous at first episode replaced the item")
                value.nextEpisode(); value.nextEpisode()
                try require(value.currentEpisodeID == "a:main:3" && value.canPlayPrevious && !value.canPlayNext, "Two next actions must reach episode 3 and disable the upper boundary")
                let lastItem = value.playback.itemID
                value.nextEpisode()
                try require(value.playback.itemID == lastItem, "Next at final episode replaced the item")
                return "1 ← 2 → 3 selects actual adjacent records; both ends remain no-ops."
            }
            await check("gaps_and_unrelated_detail_cannot_select_adjacent_episodes") {
                let gap = detail(provider: "a", media: media, numbers: [1, 3])
                let value = fixture(directory: directory, original: gap)
                defer { value.closePlayer() }
                let last = value.playback.itemID
                try require(!value.canPlayPrevious, "Episode 3 must not expose episode 1 as previous")
                value.previousEpisode()
                try require(value.playback.itemID == last && value.message != nil, "Gap traversal must preserve playback and explain the gap")
                value.resume(record(gap, episodeIndex: 0))
                let first = value.playback.itemID
                try require(!value.canPlayNext, "Episode 1 must not expose episode 3 as next")
                value.nextEpisode()
                try require(value.playback.itemID == first, "Forward gap traversal replaced the item")
                value.detail = alternative
                try require(!value.canPlayNext && !value.canPlayPrevious, "Unrelated detail cannot supply adjacent episodes for the current record")
                value.nextEpisode(); value.previousEpisode()
                try require(value.playback.itemID == first, "Unrelated detail switched playback")
                return "Both numbered gaps and mismatched record/detail identities refuse navigation."
            }
            await check("cancel_search_rejects_noncooperative_late_results") {
                let gate = Deferred<SearchResponse>()
                let requests = AlternativeSourceRequests(search: { _, _ in await gate.wait() })
                let value = fixture(directory: directory, original: original, requests: requests)
                defer { value.closePlayer() }
                let item = value.playback.itemID
                value.findAlternativeSources()
                try await eventually("search has entered") { gate.entered }
                try require(value.alternativeStage == .searching, "Search phase is not visible")
                value.cancelAlternativeSelection()
                gate.finish(SearchResponse(titles: [alternative.title], failures: []))
                await settle()
                try require(!value.alternativesLoading && value.alternativeStage == nil && value.alternativeSources.isEmpty, "Late search response resurrected a canceled operation")
                try require(value.playback.itemID == item && !value.playback.playbackRequested, "Search cancellation disturbed current playback")
                return "A search continuation deliberately completes after cancellation; results and loading stay cleared."
            }
            await check("cancel_detail_preserves_candidates_and_rejects_late_switch") {
                let gate = Deferred<MediaDetail>()
                let requests = AlternativeSourceRequests(detail: { _, _ in await gate.wait() }, inspect: { _ in })
                let value = fixture(directory: directory, original: original, requests: requests)
                defer { value.closePlayer() }
                value.alternativeSources = [alternative.title]
                let item = value.playback.itemID
                value.switchAlternativeSource(alternative.title)
                try await eventually("detail has entered") { gate.entered }
                try require(value.alternativeStage == .loadingDetail(provider: "b"), "Detail stage must name the selected source")
                value.cancelAlternativeSelection()
                try require(value.alternativeSources == [alternative.title], "Cancel discarded reusable candidates")
                gate.finish(alternative)
                await settle()
                try require(value.playback.itemID == item && value.detail == original && value.currentEpisodeID == "a:main:2", "Late detail switched the actual current item or context")
                try require(!value.alternativesLoading && value.alternativeStage == nil, "Canceled detail left stale loading")
                return "Cancel retains the candidate list and current item/context even after a late successful detail."
            }
            await check("cancel_playlist_preserves_item_after_late_success") {
                let gate = Deferred<Void>()
                let requests = AlternativeSourceRequests(detail: { _, _ in alternative }, inspect: { _ in await gate.wait() })
                let value = fixture(directory: directory, original: original, requests: requests)
                defer { value.closePlayer() }
                value.alternativeSources = [alternative.title]
                let item = value.playback.itemID
                value.switchAlternativeSource(alternative.title)
                try await eventually("playlist has entered") { gate.entered }
                try require(value.alternativeStage == .checkingPlaylist(provider: "b", line: "main"), "Playlist stage must name the source and line")
                value.cancelAlternativeSelection()
                gate.finish(())
                await settle()
                try require(value.playback.itemID == item && value.detail == original && !value.playback.playbackRequested, "Late playlist success switched or resumed the canceled item")
                try require(value.alternativeSources == [alternative.title] && !value.alternativesLoading, "Playlist cancellation discarded candidates or retained loading")
                return "Late successful playlist completion cannot commit a canceled source choice."
            }
            await check("new_choice_supersedes_old_detail_without_late_overwrite") {
                let old = Deferred<MediaDetail>()
                let requests = AlternativeSourceRequests(detail: { title, _ in
                    if title.providerID == "b" { return await old.wait() }
                    return third
                }, inspect: { _ in })
                let value = fixture(directory: directory, original: original, requests: requests)
                defer { value.closePlayer() }
                value.switchAlternativeSource(alternative.title)
                try await eventually("first choice has entered") { old.entered }
                value.switchAlternativeSource(third.title)
                try await eventually("replacement choice commits") { value.detail?.title.providerID == "c" && !value.alternativesLoading }
                let item = value.playback.itemID
                old.finish(alternative)
                await settle()
                try require(value.playback.itemID == item && value.detail?.title.providerID == "c" && value.currentEpisodeID == "c:main:2", "Late older choice replaced the newer selected source")
                return "The second source choice commits once; delayed first-source detail cannot overwrite it."
            }
            await check("pause_during_source_check_wins_and_latest_position_is_retained") {
                let gate = Deferred<Void>()
                let requests = AlternativeSourceRequests(detail: { _, _ in alternative }, inspect: { _ in await gate.wait() })
                let value = fixture(directory: directory, original: original, requests: requests, paused: false)
                defer { value.closePlayer() }
                try await eventually("initial media is playing") { value.playback.isPlaying }
                value.switchAlternativeSource(alternative.title)
                try await eventually("check has entered") { gate.entered }
                value.playback.pause(); value.playback.seek(to: 31)
                try await eventually("original media paused at the new position") { abs(value.playback.player.currentTime().seconds - 31) < 0.3 }
                gate.finish(())
                try await eventually("replacement ready at latest paused position") {
                    value.detail?.title.providerID == "b" && value.playback.player.currentItem?.status == .readyToPlay
                        && abs(value.playback.player.currentTime().seconds - 31) < 0.3
                }
                try require(!value.playback.playbackRequested && value.playback.player.rate == 0, "Async source completion overrode a later pause")
                return "Pause and seek to 31 seconds during verification survive replacement of the real AVPlayer item."
            }
            await check("play_during_source_check_is_not_replaced_by_old_pause_intent") {
                let gate = Deferred<Void>()
                let requests = AlternativeSourceRequests(detail: { _, _ in alternative }, inspect: { _ in await gate.wait() })
                let value = fixture(directory: directory, original: original, requests: requests)
                defer { value.closePlayer() }
                value.switchAlternativeSource(alternative.title)
                try await eventually("check has entered") { gate.entered }
                value.playback.togglePlayback()
                gate.finish(())
                try await eventually("replacement plays after latest play request") {
                    value.detail?.title.providerID == "b" && value.playback.playbackRequested && value.playback.isPlaying && value.playback.player.rate > 0
                }
                return "A play request made during verification wins over the paused state at verification start."
            }
            await check("wrong_season_missing_episode_and_probe_failure_preserve_playback") {
                var wrongSeason = alternative
                wrongSeason.title.title = "测试剧第二季"
                let missing = detail(provider: "b", media: media, numbers: [1, 3])
                for (name, response, failsProbe) in [("season", wrongSeason, false), ("missing", missing, false), ("probe", alternative, true)] {
                    let requests = AlternativeSourceRequests(detail: { _, _ in response }, inspect: { _ in
                        if failsProbe { throw SourceError.invalidPlaylist }
                    })
                    let value = fixture(directory: directory, original: original, requests: requests)
                    value.alternativeSources = [alternative.title]
                    let item = value.playback.itemID
                    value.switchAlternativeSource(alternative.title)
                    try await eventually("rejection finishes: " + name) { !value.alternativesLoading }
                    try require(value.playback.itemID == item && value.detail == original, "Rejected \(name) changed active playback")
                    try require(value.alternativeStage == nil && value.alternativeNotice != nil && value.alternativeSources == [alternative.title], "Rejected \(name) lost retry candidates or left loading")
                    value.closePlayer()
                }
                return "Wrong season, absent current episode, and failed media inspection all preserve the real item and reusable candidates."
            }
            await check("leaving_player_cancels_pending_source_commit") {
                let gate = Deferred<Void>()
                let requests = AlternativeSourceRequests(detail: { _, _ in alternative }, inspect: { _ in await gate.wait() })
                let value = fixture(directory: directory, original: original, requests: requests)
                defer { value.closePlayer() }
                let item = value.playback.itemID
                value.switchAlternativeSource(alternative.title)
                try await eventually("check has entered") { gate.entered }
                value.closePlayer()
                gate.finish(())
                await settle()
                try require(!value.showPlayer && value.playback.itemID == item && !value.playback.playbackRequested, "Late response reopened or resumed playback after leaving")
                try require(value.alternativeStage == nil && !value.alternativesLoading, "Leaving player left a busy source operation")
                return "Closing the player invalidates a pending playlist check and refuses its eventual success."
            }
        } catch { checks.append(Check(name: "fixture_setup", passed: false, detail: String(describing: error))) }
        let passed = !checks.isEmpty && checks.allSatisfy(\.passed)
        let report: [String: Any] = ["checkedAt": ISO8601DateFormatter().string(from: Date()), "passed": passed,
            "networkRequestsMade": false, "nativeUIVerified": false,
            "mode": "Headless AppModel + real AVPlayer with generated local WAV; injected async source fixtures",
            "checks": checks.map { ["name": $0.name, "passed": $0.passed, "detail": $0.detail] }]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        exit(passed ? 0 : 1)
    }
    @MainActor static func fixture(directory: URL, original: MediaDetail, requests: AlternativeSourceRequests = .init(), paused: Bool = true) -> AppModel {
        setenv("YINGCHUAN_PROFILE_DIRECTORY", directory.appendingPathComponent(UUID().uuidString).path, 1)
        let value = AppModel(alternativeRequests: requests)
        value.providers = ["a", "b", "c"].map { SourceProvider(id: $0, name: $0, endpoint: URL(string: "https://fixture.invalid/" + $0)!) }
        value.playback.volume = 0
        value.resume(record(original, episodeIndex: 1, position: 20))
        if paused { value.playback.pause() }
        return value
    }
    static func settle() async { try? await Task.sleep(nanoseconds: 100_000_000) }
    static func detail(provider: String, media: URL, numbers: [Int] = [1, 2, 3]) -> MediaDetail {
        let title = MediaTitle(id: "show", title: "测试剧第一季", year: "2026", posterURL: nil, summary: "", providerID: provider, providerName: provider)
        let lines = ["main", "alternate"].map { suffix in
            PlaybackLine(id: provider + ":" + suffix, name: suffix, episodes: numbers.map { number in
                Episode(id: "\(provider):\(suffix):\(number)", name: "第\(number)集", url: media, number: number)
            })
        }
        return MediaDetail(title: title, lines: lines)
    }
    static func record(_ detail: MediaDetail, episodeIndex: Int, position: Double = 0) -> WatchRecord {
        let line = detail.lines[0], episode = line.episodes[episodeIndex]
        return WatchRecord(id: "\(detail.title.providerID):\(detail.title.id):\(line.id):\(episode.id)", title: detail.title.title, episode: episode.name, url: episode.url, posterURL: nil, position: position, duration: 120, mediaDetail: detail, lineID: line.id, episodeID: episode.id)
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    @MainActor static func eventually(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < deadline
        throw Failure(description: "Timed out: " + message)
    }
    static func silentWave(seconds: Int) -> Data {
        let bytes = seconds * 8_000 * 2
        var data = Data("RIFF".utf8)
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        word(UInt32(36 + bytes)); data.append(Data("WAVEfmt ".utf8))
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(8_000)); word(UInt32(16_000)); word(UInt16(2)); word(UInt16(16))
        data.append(Data("data".utf8)); word(UInt32(bytes)); data.append(Data(count: bytes))
        return data
    }
}

/// A deliberately non-cooperative source dependency: cancellation does not finish
/// this continuation, so the model must refuse its explicitly released late value.
@MainActor
private final class Deferred<Value> {
    private var continuation: CheckedContinuation<Value, Never>?
    private(set) var entered = false
    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
        }
    }
    func finish(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
