import Foundation
import AVFoundation
import IOKit.pwr_mgt
import CinemaCore

@main struct DisplaySleepSmoke {
    struct Check: Codable { let name: String; let passed: Bool; let detail: String }
    @MainActor static func main() async throws {
        let media = URL(fileURLWithPath: CommandLine.arguments[1])
        let report = URL(fileURLWithPath: CommandLine.arguments[2])
        let controller = PlaybackController()
        controller.volume = 0
        controller.automaticAdSkipping = false
        var checks: [Check] = []
        func assertions() throws -> [[String: Any]] {
            var value: Unmanaged<CFDictionary>?
            guard IOPMCopyAssertionsByProcess(&value) == kIOReturnSuccess, let dictionary = value?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else {
                throw NSError(domain: "DisplaySleepValidation", code: 1)
            }
            return (dictionary[NSNumber(value: getpid())] ?? []).filter {
                ($0[kIOPMAssertionNameKey] as? String) == "Chengmu video playback" &&
                ($0[kIOPMAssertionTypeKey] as? String) == kIOPMAssertionTypePreventUserIdleDisplaySleep &&
                ($0[kIOPMAssertionLevelKey] as? Int) == kIOPMAssertionLevelOn
            }
        }
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(.init(name: name, passed: passed, detail: detail))
            print("\(passed ? "PASS" : "FAIL") \(name) \(detail)")
        }
        func wait(_ predicate: () -> Bool, seconds: Double = 8) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            check("media_condition_reached", predicate())
        }
        check("idle_has_no_owned_display_assertion", try assertions().isEmpty)
        controller.open(url: media, title: "Sleep validation", episode: "Local")
        try await wait { controller.isPlaying && controller.position > 0.1 }
        check("playing_holds_one_native_display_assertion", try assertions().count == 1)
        controller.selectEnhancementMode(.clarity)
        controller.seek(to: 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterSeek = try assertions()
        check("mode_and_seek_keep_one_assertion", afterSeek.count == 1)
        controller.keepsDisplayAwake = false
        check("preference_off_releases_during_playback", try assertions().isEmpty)
        try await Task.sleep(nanoseconds: 100_000_000)
        check("callbacks_respect_disabled_preference", try assertions().isEmpty)
        controller.keepsDisplayAwake = true
        check("preference_on_reacquires_during_playback", try assertions().count == 1)
        controller.pause()
        check("pause_releases_immediately", try assertions().isEmpty)
        controller.keepsDisplayAwake = false
        controller.keepsDisplayAwake = true
        check("preference_toggle_while_paused_does_not_acquire", try assertions().isEmpty)
        try await Task.sleep(nanoseconds: 200_000_000)
        check("late_callbacks_do_not_reacquire_after_pause", try assertions().isEmpty)
        controller.togglePlayback()
        try await wait { controller.isPlaying }
        check("resume_reacquires", try assertions().count == 1)
        // Exercise a real controller's stall/recovery notifications, not a network claim.
        NotificationCenter.default.post(name: .AVPlayerItemPlaybackStalled, object: controller.player.currentItem)
        try await Task.sleep(nanoseconds: 100_000_000)
        check("transient_stall_does_not_drop_assertion", try assertions().count == 1)
        controller.seek(to: 7.7)
        try await wait { !controller.playbackRequested && !controller.isPlaying }
        check("natural_end_releases", try assertions().isEmpty)
        controller.open(url: URL(fileURLWithPath: "/missing/chengmu-fixture.mp4"), title: "Missing", episode: "Missing")
        try await wait { controller.hasPlaybackFailure }
        check("failed_item_releases", try assertions().isEmpty)
        controller.pause()
        var temporaryOwner: PlaybackDisplaySleepGuard? = PlaybackDisplaySleepGuard()
        temporaryOwner?.update(shouldPreventSleep: true)
        temporaryOwner?.update(shouldPreventSleep: true)
        check("repeated_requests_own_one_assertion", try assertions().count == 1)
        temporaryOwner = nil
        check("owner_deinit_releases_native_assertion", try assertions().isEmpty)
        let passed = checks.allSatisfy(\.passed)
        struct Report: Encodable { let passed: Bool; let checks: [Check]; let scope: String }
        let data = try JSONEncoder().encode(Report(passed: passed, checks: checks, scope: "Real AVPlayer/controller and IOPMCopyAssertionsByProcess on local tagged video. Native power assertion ownership/release, not a timed physical display-dimming observation. Stall is an injected notification on a playing local item."))
        try data.write(to: report)
        if !passed { exit(1) }
    }
}
