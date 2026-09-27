// Run without rebuilding the app bundle (uses the existing Debug CinemaCore build):
// swiftc -parse-as-library -target arm64-apple-macos15.0 -I .build/out/Products/Debug -L .build/out/Products/Debug -lCinemaCore Sources/CinemaApp/AppModel.swift Sources/CinemaApp/PlaybackController.swift Sources/CinemaApp/EnhancementPipeline.swift Tests/AppModelSmoke/ContinueHistorySmoke.swift -o .build/continue-history-smoke
// .build/continue-history-smoke --validate
import Foundation
import CinemaCore

@main struct ContinueHistorySmoke {
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.contains("--validate"), "Smoke runs require isolated diagnostic preferences")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ContinueHistorySmoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appendingPathComponent("silent-120s.wav")
        try silentWave(seconds: 120).write(to: media)
        let title = MediaTitle(id: "title", title: "Smoke", year: "2026", posterURL: nil, summary: "", providerID: "test", providerName: "Test")
        let firstEpisode = Episode(id: "first-episode", name: "第1集", url: media, number: 1)
        let savedEpisode = Episode(id: "saved-episode", name: "第1集", url: media, number: 1)
        let firstLine = PlaybackLine(id: "first-line", name: "First", episodes: [firstEpisode])
        let savedLine = PlaybackLine(id: "saved-line", name: "Saved", episodes: [savedEpisode])
        let original = MediaDetail(title: title, lines: [firstLine, savedLine])
        let record = WatchRecord(id: "test:title:saved-line:saved-episode", title: title.title, episode: savedEpisode.name, url: media, posterURL: nil, position: 37, duration: 120, mediaDetail: original, lineID: savedLine.id, episodeID: savedEpisode.id)
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            if !condition { failures.append(name); print("FAIL: \(name)") }
        }
        func model(_ name: String, detail: MediaDetail, record: WatchRecord) -> AppModel {
            setenv("YINGCHUAN_PROFILE_DIRECTORY", directory.appendingPathComponent(name).path, 1)
            let value = AppModel()
            value.detail = detail; value.history = [record]; value.selectedLineID = detail.lines.first?.id ?? ""
            value.playback.volume = 0
            return value
        }
        func reachedResume(_ value: AppModel) async -> Bool {
            for _ in 0..<80 {
                if value.playback.position >= 36.5 && value.playback.position < 45 { return true }
                if value.playback.error != nil { return false }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return false
        }

        // Same media appears on two lines; the stored line and episode must win.
        let exact = model("exact", detail: original, record: record)
        exact.continueDetail()
        check(exact.selectedLineID == "saved-line" && exact.currentEpisodeID == "saved-episode", "stored line and episode win over duplicate media on the first line")
        let exactReached = await reachedResume(exact)
        check(exactReached, "exact match resumes the stored position")
        exact.closePlayer()

        // Providers may regenerate stable IDs without changing the actual media.
        let changedEpisode = Episode(id: "regenerated", name: "第1集", url: media, number: 1)
        let changedWithinLine = MediaDetail(title: title, lines: [firstLine, PlaybackLine(id: savedLine.id, name: savedLine.name, episodes: [changedEpisode])])
        let preferredLine = model("same-line", detail: changedWithinLine, record: record)
        preferredLine.continueDetail()
        check(preferredLine.selectedLineID == "saved-line" && preferredLine.currentEpisodeID == "regenerated", "stored line remains preferred when only its episode ID changes")
        let preferredLineReached = await reachedResume(preferredLine)
        check(preferredLineReached, "same-line fallback keeps the stored position")
        preferredLine.closePlayer()

        let changed = MediaDetail(title: title, lines: [PlaybackLine(id: "new-line", name: "New", episodes: [changedEpisode])])
        let fallback = model("fallback", detail: changed, record: record)
        fallback.continueDetail()
        check(fallback.selectedLineID == "new-line" && fallback.currentEpisodeID == "regenerated", "unique safe fallback selects the regenerated identifiers")
        let fallbackReached = await reachedResume(fallback)
        check(fallbackReached, "safe fallback carries the stored position across identifier changes")

        // Removing the active history entry must not stop media or let a later save revive it.
        fallback.playback.saveProgress()
        let activeID = "test:title:new-line:regenerated"
        check(fallback.history.contains { $0.id == activeID }, "active fallback progress is saved before removal")
        let playingItem = fallback.playback.player.currentItem
        fallback.removeHistory(activeID)
        fallback.playback.position = 44
        fallback.playback.saveProgress()
        check(fallback.playback.player.currentItem === playingItem, "removing history keeps the active player item")
        check(!fallback.history.contains { $0.id == activeID }, "progress callback does not revive a removed active history entry")
        let persisted = try fallback.store.load()
        check(!persisted.contains { $0.id == activeID }, "removed history remains absent on disk")
        fallback.closePlayer()

        var legacy = record
        legacy.lineID = nil; legacy.episodeID = nil
        let ambiguous = model("ambiguous", detail: original, record: legacy)
        ambiguous.continueDetail()
        check(!ambiguous.showPlayer && ambiguous.playback.player.currentItem == nil && ambiguous.message != nil, "ambiguous fallback asks for a manual choice without starting a guessed line")
        ambiguous.closePlayer()

        // An exact ID cannot override a URL mismatch; no old position may reach changed media.
        let replacement = Episode(id: savedEpisode.id, name: savedEpisode.name, url: directory.appendingPathComponent("different.wav"), number: 1)
        let mismatch = MediaDetail(title: title, lines: [PlaybackLine(id: savedLine.id, name: savedLine.name, episodes: [replacement])])
        let unsafe = model("mismatch", detail: mismatch, record: record)
        unsafe.continueDetail()
        check(!unsafe.showPlayer && unsafe.message != nil, "changed media cannot reuse historical resume context")
        unsafe.closePlayer()

        if failures.isEmpty { print("CONTINUE_HISTORY_SMOKE_PASS: exact identity, safe fallback seek, ambiguous and changed-media rejection, active history removal persistence") }
        else { print("CONTINUE_HISTORY_SMOKE_FAILED: \(failures.count) assertions"); exit(1) }
    }

    private static func silentWave(seconds: Int) -> Data {
        let bytes = seconds * 8_000 * 2
        var data = Data("RIFF".utf8)
        func word<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        word(UInt32(36 + bytes)); data.append(Data("WAVEfmt ".utf8))
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(8_000)); word(UInt32(16_000)); word(UInt16(2)); word(UInt16(16))
        data.append(Data("data".utf8)); word(UInt32(bytes)); data.append(Data(count: bytes))
        return data
    }
}
