import Foundation
import Testing
@testable import CinemaCore

struct PlaybackPreferencesTests {
    @Test func invalidValuesCannotReachPlayback() {
        let clamped = PlaybackPreferences(volume: 4, rate: -10, enhancement: "unknown", lastAudibleVolume: -1)
        #expect(clamped.volume == 1)
        #expect(clamped.rate == 0.5)
        #expect(clamped.enhancement == "upscale4K")
        #expect(clamped.lastAudibleVolume == 1)
        let nonfinite = PlaybackPreferences(volume: .nan, rate: .infinity, lastAudibleVolume: .nan)
        #expect(nonfinite.volume == 0.8)
        #expect(nonfinite.rate == 1)
    }

    @Test func unmutingRestoresLastAudibleVolumeAfterMultipleChanges() {
        var preferences = PlaybackPreferences(volume: 0.35)
        preferences.toggleMute()
        #expect(preferences.volume == 0)
        preferences.toggleMute()
        #expect(preferences.volume == 0.35)
        preferences.setVolume(0.62)
        preferences.setVolume(0)
        preferences.toggleMute()
        #expect(preferences.volume == 0.62)
    }

    @Test func preferencesSurviveReloadIncludingMutedVolume() throws {
        let suite = "CinemaPlaybackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPreferencesStore(defaults: defaults, arguments: ["Cinema"])
        var preferences = PlaybackPreferences(volume: 0.37, rate: 1.5, enhancement: "clarity")
        preferences.toggleMute()
        store.save(preferences)
        var restored = PlaybackPreferencesStore(defaults: defaults, arguments: ["Cinema"]).load()
        #expect(restored.volume == 0)
        #expect(restored.rate == 1.5)
        #expect(restored.enhancement == "clarity")
        restored.toggleMute()
        #expect(restored.volume == 0.37)
    }

    @Test func diagnosticSessionsNeitherReadNorWriteDailyPreferences() throws {
        let suite = "CinemaPlaybackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let daily = PlaybackPreferencesStore(defaults: defaults, arguments: ["Cinema"])
        daily.save(PlaybackPreferences(volume: 0.42, rate: 1.5, enhancement: "clarity"))
        for flag in ["--validate", "--benchmark"] {
            let isolated = PlaybackPreferencesStore(defaults: defaults, arguments: ["Cinema", flag])
            #expect(isolated.load().volume == 0.8)
            #expect(isolated.load().rate == 1)
            isolated.save(PlaybackPreferences(volume: 0, rate: 2, enhancement: "original"))
            #expect(daily.load().volume == 0.42)
            #expect(daily.load().rate == 1.5)
            #expect(daily.load().enhancement == "clarity")
        }
    }

    @Test func decodingValidatesOutOfRangeStoredValues() throws {
        let data = Data(#"{"volume":-9,"rate":100,"enhancement":"missing","lastAudibleVolume":0.27}"#.utf8)
        var decoded = try JSONDecoder().decode(PlaybackPreferences.self, from: data)
        #expect(decoded.volume == 0)
        #expect(decoded.rate == 2)
        #expect(decoded.enhancement == "upscale4K")
        decoded.toggleMute()
        #expect(decoded.volume == 0.27)
    }

    @Test func timerRoundsRemainingTimeUpAndExpiresOnlyOnce() {
        let now = Date(timeIntervalSince1970: 10_000)
        var timer = PlaybackSleepTimer()
        let scheduled = timer.schedule(minutes: 15, now: now)
        #expect(scheduled)
        #expect(timer.remainingSeconds(at: now.addingTimeInterval(0.2)) == 900)
        #expect(timer.remainingSeconds(at: now.addingTimeInterval(899.2)) == 1)
        let early = timer.consumeExpiration(at: now.addingTimeInterval(899.9))
        #expect(!early)
        let expired = timer.consumeExpiration(at: now.addingTimeInterval(900))
        #expect(expired)
        #expect(timer.remainingSeconds(at: now.addingTimeInterval(901)) == nil)
        let duplicate = timer.consumeExpiration(at: now.addingTimeInterval(901))
        #expect(!duplicate)
    }

    @Test func timerReplacementCancellationAndDelayedWakeCannotLeakOldDeadline() {
        let now = Date(timeIntervalSince1970: 10_000)
        var timer = PlaybackSleepTimer()
        let initial = timer.schedule(minutes: 15, now: now)
        #expect(initial)
        let replaced = timer.schedule(minutes: 30, now: now.addingTimeInterval(20))
        #expect(replaced)
        let oldDeadline = timer.consumeExpiration(at: now.addingTimeInterval(901))
        #expect(!oldDeadline)
        let invalid = timer.schedule(minutes: -1, now: now)
        #expect(!invalid)
        #expect(timer.remainingSeconds(at: now.addingTimeInterval(20)) == 1800)
        timer.cancel()
        let cancelled = timer.consumeExpiration(at: now.addingTimeInterval(5000))
        #expect(!cancelled)
        let hour = timer.schedule(minutes: 60, now: now)
        #expect(hour)
        let delayed = timer.consumeExpiration(at: now.addingTimeInterval(7200))
        #expect(delayed)
        let longest = timer.schedule(minutes: 90, now: now)
        #expect(longest)
        #expect(timer.remainingSeconds(at: now) == 5400)
    }
}
