import AppKit
import Combine
import Foundation
import CinemaCore

// Environment fixtures only: no application activation, window ordering,
// accessibility operations, or synthetic pointer/keyboard events.
private final class VisibilityApplication: NSApplication {
    override var isActive: Bool { true }
}

private final class VisibilityWindow: NSWindow {
    var fullscreenFixture = false
    override var isKeyWindow: Bool { true }
    override var styleMask: NSWindow.StyleMask {
        get { fullscreenFixture ? super.styleMask.union(.fullScreen) : super.styleMask.subtracting(.fullScreen) }
        set { super.styleMask = newValue.subtracting(.fullScreen) }
    }
}

@MainActor
private final class VisibilityFixture {
    let mode: String
    let window: VisibilityWindow
    let controller = PlayerPresentationController()
    private var observation: AnyCancellable?
    private(set) var hiddenTransitions = 0
    private(set) var cleanupCallbacks = 0

    init(fullscreen: Bool) {
        mode = fullscreen ? "fullscreen" : "windowed"
        window = VisibilityWindow(contentRect: NSRect(x: -100_000, y: -100_000, width: 640, height: 480), styleMask: .borderless, backing: .buffered, defer: true)
        window.fullscreenFixture = fullscreen
        window.isReleasedWhenClosed = false
        controller.attach(to: window)
        controller.updatePlayback(isPlaying: true, isBuffering: false, hasError: false)
        observation = controller.$controlsVisible.removeDuplicates().sink { [weak self] visible in
            guard !visible, let self else { return }
            self.hiddenTransitions += 1
            // @Published emits before assigning. Queue exactly the cleanup that
            // SeekBar.onChange(visible: false) sends after SwiftUI updates.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cleanupCallbacks += 1
                self.controller.interact("seek-preview", active: false)
            }
        }
    }
    var safeEnvironment: Bool { !window.isVisible && !window.frame.contains(NSEvent.mouseLocation) }
    func stop() { observation?.cancel(); observation = nil; controller.detach() }
}

@main
struct ControlVisibilitySmoke {
    struct Check: Encodable { let name: String; let passed: Bool; let detail: String }

    @MainActor static func main() {
        guard CommandLine.arguments.contains("--validate") else { exit(2) }
        let application = VisibilityApplication.shared
        application.setActivationPolicy(.prohibited)
        guard NSApp === application, application is VisibilityApplication else {
            print("Test application was not installed; cannot evaluate the real controller timer.")
            exit(2)
        }
        Task { @MainActor in await run() }
        // Unlike an async-main process, explicitly service the real AppKit timer
        // without calling NSApplication.run or displaying a window.
        RunLoop.main.run(until: .distantFuture)
    }

    @MainActor private static func run() async {
        let fixtures = [VisibilityFixture(fullscreen: false), VisibilityFixture(fullscreen: true)]
        var checks: [Check] = []
        func check(_ fixture: VisibilityFixture, _ name: String, _ condition: Bool, _ detail: String) {
            checks.append(Check(name: fixture.mode + ":" + name, passed: condition, detail: detail))
        }
        guard fixtures.allSatisfy(\.safeEnvironment) else {
            fixtures.forEach { $0.stop() }
            report([Check(name: "isolated_environment", passed: false, detail: "A fixture was visible or intersected the actual cursor; no timing cases executed.")])
        }
        // The user-visible three-second idle contract stays the same even when
        // the policy type is renamed from fullscreen-only to general playback.
        let delay: TimeInterval = 3
        await sleep(delay + 0.65)
        for fixture in fixtures {
            check(fixture, "idle_hide_survives_preview_cleanup",
                  fixture.hiddenTransitions > 0 && fixture.cleanupCallbacks > 0 && !fixture.controller.controlsVisible,
                  "After \(delay + 0.65)s: hidden transitions=\(fixture.hiddenTransitions), queued cleanup callbacks=\(fixture.cleanupCallbacks), visible=\(fixture.controller.controlsVisible). The real controller timer and published visibility drive the cleanup loop.")
        }

        // Duplicate clear callbacks occur during layout/item cleanup and must
        // not look like actual pointer movement or restart the idle deadline.
        fixtures.forEach { $0.controller.activity() }
        let deadline = ProcessInfo.processInfo.systemUptime + delay + 0.65
        while ProcessInfo.processInfo.systemUptime < deadline {
            fixtures.forEach { $0.controller.interact("seek-preview", active: false) }
            await sleep(0.15)
        }
        for fixture in fixtures {
            check(fixture, "duplicate_inactive_callbacks_do_not_postpone_hide", !fixture.controller.controlsVisible,
                  "Repeated public interact(false) calls every 150ms did not count as user activity; visible=\(fixture.controller.controlsVisible).")
        }

        fixtures.forEach { $0.controller.interact("controls", active: true) }
        await sleep(delay + 0.4)
        for fixture in fixtures {
            check(fixture, "active_hover_keeps_controls_visible", fixture.controller.controlsVisible,
                  "An actual active controls interaction blocks hiding past the idle deadline.")
        }
        fixtures.forEach { $0.controller.interact("controls", active: false) }
        await sleep(0.35)
        for fixture in fixtures {
            check(fixture, "real_hover_exit_starts_fresh_visible_interval", fixture.controller.controlsVisible,
                  "A real active-to-inactive transition keeps controls visible during the new idle interval.")
        }
        await sleep(delay + 0.25)
        for fixture in fixtures {
            check(fixture, "real_hover_exit_eventually_hides_again", !fixture.controller.controlsVisible,
                  "After the fresh idle interval the controls remain hidden despite the preview cleanup callback.")
        }
        fixtures.forEach { $0.controller.updatePlayback(isPlaying: false, isBuffering: false, hasError: false) }
        await sleep(0.3)
        for fixture in fixtures {
            check(fixture, "pause_reveals_controls", fixture.controller.controlsVisible,
                  "A real playback-state update immediately reveals controls and the next timer tick keeps them visible.")
        }
        fixtures.forEach { $0.stop() }
        report(checks)
    }
    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    private static func report(_ checks: [Check]) -> Never {
        let passed = !checks.isEmpty && checks.allSatisfy(\.passed)
        let report: [String: Any] = [
            "checkedAt": ISO8601DateFormatter().string(from: Date()), "passed": passed,
            "mode": "Real PlayerPresentationController, public methods, published visibility, and actual idle Timer; test-only offscreen AppKit environment flags",
            "sourceReference": ProcessInfo.processInfo.environment["CINEMA_VISIBILITY_SOURCE"] ?? "working-tree",
            "nativeUIVerified": false, "userUIControlled": false, "inputEventsInjected": false,
            "checks": checks.map { ["name": $0.name, "passed": $0.passed, "detail": $0.detail] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        exit(passed ? 0 : 1)
    }
}
