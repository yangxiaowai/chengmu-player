import Foundation
import Testing
@testable import CinemaCore

struct SubtitlePreferencesTests {
    @Test func olderProfilesReceiveComfortDefaults() throws {
        let old = try JSONDecoder().decode(SubtitlePreferences.self, from: Data("{}".utf8))
        #expect(old.visible && old.backgroundEnabled)
        #expect(old.fontSize == 22 && old.verticalOffset == 0)
        let partial = try JSONDecoder().decode(SubtitlePreferences.self, from: Data(#"{"visible":false,"fontSize":100,"verticalOffset":-5}"#.utf8))
        #expect(!partial.visible && partial.backgroundEnabled)
        #expect(partial.fontSize == 36 && partial.verticalOffset == 0)
    }
    @Test func clampsBoundsAndRejectsNonfiniteValues() {
        #expect(SubtitlePreferences(fontSize: -2, verticalOffset: 300).fontSize == 18)
        #expect(SubtitlePreferences(fontSize: -2, verticalOffset: 300).verticalOffset == 120)
        #expect(SubtitlePreferences(fontSize: .nan, verticalOffset: .infinity).fontSize == 22)
        #expect(SubtitlePreferences(fontSize: .infinity, verticalOffset: .nan).verticalOffset == 0)
    }
    @Test func dedicatedStorePreservesPlaybackPreferencesAndDiagnosticIsolation() throws {
        let suite = "CinemaSubtitlePreferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = Data(#"{"volume":0.37,"rate":1.5}"#.utf8)
        defaults.set(legacy, forKey: "playbackPreferences.v1")
        let daily = SubtitlePreferencesStore(defaults: defaults, arguments: ["Cinema"])
        #expect(daily.load() == SubtitlePreferences())
        let chosen = SubtitlePreferences(visible: false, fontSize: 30, backgroundEnabled: false, verticalOffset: 75)
        daily.save(chosen)
        #expect(daily.load() == chosen)
        #expect(defaults.data(forKey: "playbackPreferences.v1") == legacy)
        for flag in ["--validate", "--benchmark"] {
            let diagnostic = SubtitlePreferencesStore(defaults: defaults, arguments: ["Cinema", flag])
            #expect(diagnostic.load() == SubtitlePreferences())
            diagnostic.save(SubtitlePreferences(fontSize: 18))
            #expect(daily.load() == chosen)
        }
    }
}
