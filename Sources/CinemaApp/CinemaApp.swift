import SwiftUI
import AppKit

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CinemaApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var model = AppModel()
    init() {
        if CommandLine.arguments.contains("--benchmark") {
            do {
                let result = try EnhancementPipeline.runBenchmark(frameCount: 240)
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data)
                exit(0)
            } catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
    }
    var body: some Scene {
        WindowGroup("映川") {
            ContentView(app: model).task {
                if CommandLine.arguments.contains("--validate") { PlaybackValidation.shared.start(model: model) }
                else if model.results.isEmpty { model.discover() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.playback.saveProgress() }
        }
        .defaultSize(width: 1250, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开影片…") { model.importFile() }.keyboardShortcut("o")
            }
        }
    }
}
