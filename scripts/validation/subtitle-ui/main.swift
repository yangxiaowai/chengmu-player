import AppKit
import SwiftUI
import AVFoundation
import CinemaCore

private final class SubtitlePreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Test-host assembly only. All visible player UI and command handling come from the product.
@main
struct SubtitleComfortPreview: App {
    @NSApplicationDelegateAdaptor(SubtitlePreviewDelegate.self) private var delegate
    @StateObject private var model: AppModel
    @LegacyState private var prepared = false

    init() {
        guard CommandLine.arguments.contains("--validate") else {
            FileHandle.standardError.write(Data("Launch this isolated preview with --validate.\n".utf8))
            exit(2)
        }
        let profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("CinemaSubtitleUI-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        setenv("YINGCHUAN_PROFILE_DIRECTORY", profile.path, 1)
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("澄幕 · 字幕预览") {
            ContentView(app: model)
                .task { await prepareLocalFilm() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.playback.pause()
                    model.playback.cancelSleepTimer()
                }
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands { PlaybackCommands() }
    }

    @MainActor private func prepareLocalFilm() async {
        guard !prepared else { return }
        prepared = true
        guard let film = Bundle.main.url(forResource: "local-film", withExtension: "mp4"),
              let subtitle = Bundle.main.url(forResource: "local-film", withExtension: "srt") else { return }
        model.automaticQualityInspection = false
        model.autoNext = false
        model.playback.automaticAdSkipping = false
        model.playback.keepsDisplayAwake = false
        model.playback.subtitlesVisible = true
        model.playback.subtitleFontSize = 22
        model.playback.subtitleBackgroundEnabled = true
        model.playback.subtitleVerticalOffset = 0
        model.showPlayer = true
        model.playback.open(url: film, title: "本地影片", episode: "")
        for _ in 0..<200 {
            if model.playback.player.currentItem?.status == .readyToPlay { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        model.playback.pause()
        model.playback.seek(to: 1)
        model.playback.loadSubtitles(subtitle)
    }
}
