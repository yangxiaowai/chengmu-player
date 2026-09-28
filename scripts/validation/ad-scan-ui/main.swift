import SwiftUI
import AppKit
import Darwin
import CinemaCore

/// Isolated manual acceptance shell. All player behavior is supplied by production source files.
final class AdSkipQADelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
enum AdSkipQABootstrap {
    @MainActor static func main() {
        let bundle = Bundle.main
        precondition(bundle.bundleIdentifier == "local.yingchuan.adskipnativeqa", "QA must have its own native bundle identity")
        let expectedProfile = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("ad-skip-ui-profile", isDirectory: true).path
        if let configured = ProcessInfo.processInfo.environment["YINGCHUAN_PROFILE_DIRECTORY"] {
            precondition(configured == expectedProfile, "QA must not inherit a user library directory")
        }
        // The plist supplies this for LaunchServices; explicitly set the same isolated value
        // before constructing AppModel for native launchers that omit LSEnvironment.
        setenv("YINGCHUAN_PROFILE_DIRECTORY", expectedProfile, 1)
        AdSkipQAApp.main()
    }
}

struct AdSkipQAApp: App {
    @NSApplicationDelegateAdaptor(AdSkipQADelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("映川 · 广告跳过隔离验收") {
            AdSkipQAView(model: model)
        }
        .defaultSize(width: 1250, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands { PlaybackCommands() }
    }
}

private struct AdSkipQAView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var playback: PlaybackController
    @LegacyState private var didOpen = false
    @LegacyState private var fullscreen = false
    init(model: AppModel) { self.model = model; playback = model.playback }
    private var fixture: URL { Bundle.main.resourceURL!.appendingPathComponent("ad-skip-fixture.mp4") }
    private var subtitle: URL { Bundle.main.resourceURL!.appendingPathComponent("ad-skip-fixture.srt") }
    var body: some View {
        VStack(spacing: 0) {
            if !fullscreen {
                HStack(spacing: 12) {
                    Text("隔离验收 · 本地合成片 · 广告 16–28 秒")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Text(String(format: "%.1f / %.1f 秒", playback.position, playback.duration))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                    Button("从头慢放") { openFixture(playing: true) }
                    Button("暂停") { playback.pause() }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color(red: 0.12, green: 0.10, blue: 0.20))
            }
            PlayerView(app: model, playback: playback)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard !didOpen else { return }
            didOpen = true
            model.providers = []; model.autoNext = false
            playback.onProgress = nil; playback.onFinished = nil
            openFixture(playing: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullscreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullscreen = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in playback.pause(); playback.adSkip.stop() }
    }
    private func openFixture(playing: Bool) {
        precondition(FileManager.default.fileExists(atPath: fixture.path), "Build the synthetic fixture first")
        model.showPlayer = true
        playback.open(url: fixture, title: "本地广告跳过验收", episode: "正常剧情 → 广告 → 正常剧情")
        playback.pause()
        playback.volume = 0
        playback.rate = 0.5
        playback.pipelineProcessesFrames = true
        playback.enhancementMode = .upscale4K
        playback.automaticAdSkipping = true
        playback.loadSubtitles(subtitle)
        playback.seek(to: 0)
        if playing { playback.togglePlayback() }
    }
}
