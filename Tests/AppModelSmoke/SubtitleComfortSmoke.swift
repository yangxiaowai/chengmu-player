import Foundation
import AVFoundation
import CinemaCore

/// Actual controller with generated local audio/SRT and unique preferences. No UI or network.
@main struct SubtitleComfortSmoke {
    struct Check: Encodable { let name: String; let passed: Bool }
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments.last!, isDirectory: true)
        let file = directory.appendingPathComponent("fixture.wav")
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let audio = try AVAudioFile(forWriting: file, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000)!
            buffer.frameLength = buffer.frameCapacity
            memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
            try audio.write(from: buffer)
        }
        let srt = directory.appendingPathComponent("fixture.srt")
        try "1\n00:00:00,000 --> 00:00:05,000\n保留字幕\nSecond line\n\n2\n00:00:10,000 --> 00:00:25,000\n跳转后的字幕\n".write(to: srt, atomically: true, encoding: .utf8)
        let invalid = directory.appendingPathComponent("invalid.srt")
        try "not a subtitle".write(to: invalid, atomically: true, encoding: .utf8)
        let suite = "CinemaSubtitleComfort.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let subtitleStore = SubtitlePreferencesStore(defaults: defaults, arguments: ["Fixture"])
        let controller = PlaybackController(preferencesStore: PlaybackPreferencesStore(defaults: defaults, arguments: ["Fixture"]), subtitlePreferencesStore: subtitleStore)
        controller.keepsDisplayAwake = false; controller.automaticAdSkipping = false
        var checks: [Check] = []
        func check(_ name: String, _ passed: Bool) { checks.append(Check(name: name, passed: passed)) }
        check("fresh_profile_defaults", controller.subtitlesVisible && controller.subtitleFontSize == 22 && controller.subtitleBackgroundEnabled && controller.subtitleVerticalOffset == 0)
        controller.open(url: file, title: "字幕回归", episode: "1")
        await waitReady(controller)
        check("local_fixture_ready", controller.player.currentItem?.status == .readyToPlay)
        controller.pause(); controller.loadSubtitles(srt)
        check("paused_import_refreshes_current_cue", controller.subtitleText == "保留字幕\nSecond line")
        controller.subtitleOffset = 2
        let item = controller.player.currentItem, intent = controller.playbackIntentID
        controller.toggleSubtitleVisibility()
        check("hide_preserves_file_selection_offset_and_pause", !controller.subtitlesVisible && controller.externalSubtitleName == "fixture.srt" && controller.selectedSubtitle == -1 && controller.subtitleOffset == 2 && !controller.playbackRequested && controller.player.currentItem === item && controller.playbackIntentID == intent)
        controller.loadSubtitles(invalid)
        check("invalid_import_retains_hidden_file_and_offset", !controller.subtitlesVisible && controller.externalSubtitleName == "fixture.srt" && controller.subtitleOffset == 2 && controller.subtitleNotice != nil)
        controller.loadSubtitles(directory.appendingPathComponent("missing.srt"))
        check("unreadable_import_retains_hidden_file_and_offset", !controller.subtitlesVisible && controller.externalSubtitleName == "fixture.srt" && controller.subtitleOffset == 2)
        controller.seek(to: 15)
        try await Task.sleep(nanoseconds: 250_000_000)
        controller.toggleSubtitleVisibility()
        check("show_after_paused_seek_refreshes_retained_cue", controller.subtitlesVisible && controller.subtitleText == "跳转后的字幕" && controller.subtitleOffset == 2 && !controller.playbackRequested)
        controller.subtitleOffset = 20
        check("paused_offset_change_refreshes_cue", controller.subtitleText.isEmpty)
        controller.subtitleOffset = 2
        controller.toggleSubtitleVisibility()
        controller.subtitleFontSize = 30; controller.subtitleBackgroundEnabled = false; controller.subtitleVerticalOffset = 75
        controller.retry(); await waitReady(controller)
        try await Task.sleep(nanoseconds: 250_000_000)
        check("retry_retains_hidden_external_offset_and_pause", !controller.subtitlesVisible && controller.externalSubtitleName == "fixture.srt" && controller.subtitleOffset == 2 && !controller.playbackRequested)
        controller.toggleSubtitleVisibility()
        check("show_after_retry_uses_retained_timeline", controller.subtitleText == "跳转后的字幕")
        controller.toggleSubtitleVisibility()
        let restored = PlaybackController(preferencesStore: PlaybackPreferencesStore(defaults: defaults, arguments: ["Fixture"]), subtitlePreferencesStore: subtitleStore)
        check("global_comfort_and_visibility_persist", !restored.subtitlesVisible && restored.subtitleFontSize == 30 && !restored.subtitleBackgroundEnabled && restored.subtitleVerticalOffset == 75)
        controller.open(url: file, title: "另一部影片", episode: "2")
        controller.pause()
        check("new_film_clears_per_film_state_preserving_global_settings", controller.externalSubtitleName == nil && controller.selectedSubtitle == -1 && controller.subtitleTracks.isEmpty && controller.subtitleOffset == 0 && controller.subtitleText.isEmpty && !controller.subtitlesVisible && controller.subtitleFontSize == 30 && !controller.subtitleBackgroundEnabled && controller.subtitleVerticalOffset == 75)
        controller.loadSubtitles(srt)
        check("successful_import_can_show_new_subtitles", controller.subtitlesVisible && controller.externalSubtitleName == "fixture.srt" && controller.subtitleOffset == 0)
        controller.selectSubtitle(-1)
        check("explicit_none_removes_subtitle_selection", controller.externalSubtitleName == nil && controller.subtitleText.isEmpty && controller.selectedSubtitle == -1)
        controller.subtitleFontSize = .nan; controller.subtitleVerticalOffset = .infinity; controller.subtitleOffset = .nan
        check("controller_rejects_nonfinite_values", controller.subtitleFontSize == 22 && controller.subtitleVerticalOffset == 0 && controller.subtitleOffset == 0)
        controller.subtitleFontSize = 100; controller.subtitleVerticalOffset = -1
        check("controller_clamps_comfort_bounds", controller.subtitleFontSize == 36 && controller.subtitleVerticalOffset == 0)
        controller.open(url: directory.appendingPathComponent("embedded.mp4"), title: "内嵌字幕", episode: "1")
        await waitTracks(controller)
        controller.pause()
        let nativeTrackNames = controller.subtitleTracks.map(\.name)
        let embeddedReady = controller.subtitleTracks.count >= 2
        check("native_fixture_exposes_language_tracks", embeddedReady)
        controller.selectSubtitle(1)
        let selectedName = controller.subtitleTracks.first(where: { $0.id == controller.selectedSubtitle })?.name
        controller.toggleSubtitleVisibility()
        let output = controller.player.currentItem?.outputs.compactMap { $0 as? AVPlayerItemLegibleOutput }.first
        check("native_hide_keeps_selected_track_and_suppressed_native_rendering", !controller.subtitlesVisible && controller.selectedSubtitle == 1 && output?.suppressesPlayerRendering == true)
        controller.retry(); await waitTracks(controller)
        check("native_retry_preserves_semantic_track_while_hidden_and_paused", embeddedReady && !controller.subtitlesVisible && !controller.playbackRequested && controller.selectedSubtitle >= 0 && controller.subtitleTracks.first(where: { $0.id == controller.selectedSubtitle })?.name == selectedName)
        controller.toggleSubtitleVisibility()
        check("native_show_keeps_track_selection", controller.subtitlesVisible && controller.selectedSubtitle >= 0 && controller.externalSubtitleName == nil)
        controller.selectSubtitle(-1); controller.retry(); await waitTracks(controller)
        check("explicit_native_none_survives_retry", controller.selectedSubtitle == -1 && controller.externalSubtitleName == nil)
        controller.player.replaceCurrentItem(with: nil); restored.player.replaceCurrentItem(with: nil)
        let passed = checks.allSatisfy(\.passed)
        let report: [String: Any] = ["passed": passed, "fixture": "generated local PCM audio, UTF-8 SRT, invalid files, and MP4 with English/Chinese mov_text tracks; actual PlaybackController", "networkUsed": false, "nativeUIVerified": false, "nativeTrackNames": nativeTrackNames, "embeddedTrackFixtureVerified": embeddedReady, "checks": checks.map { ["name": $0.name, "passed": $0.passed] }]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8))
        exit(passed ? 0 : 1)
    }
    @MainActor private static func waitReady(_ controller: PlaybackController) async {
        for _ in 0..<100 {
            if controller.player.currentItem?.status == .readyToPlay { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }
    @MainActor private static func waitTracks(_ controller: PlaybackController) async {
        for _ in 0..<100 {
            if controller.subtitleTracks.count >= 2 { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}
