// Compiled together with the real private HoverSlider; synthetic events do not
// interact with the user's window or change the user's playback history.
import Foundation
import AppKit
import AVFoundation
import CinemaCore

@main struct ArrowPlaybackIntegrationSmoke {
    struct Failure: Error { let message: String }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let media = URL(fileURLWithPath: CommandLine.arguments[1])
        let controller = PlaybackController()
        controller.volume = 0
        controller.open(url: media, title: "键盘测试", episode: "本地", resume: 200)
        controller.pause()

        func until(_ reason: String, seconds: Double = 8, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() {
                guard Date() < deadline else { throw Failure(message: "\(reason), position=\(controller.position), actual=\(controller.player.currentTime().seconds)") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try await until("local audio is ready at 200 seconds") {
            controller.player.currentItem?.status == .readyToPlay && abs(controller.player.currentTime().seconds - 200) < 0.3
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let slider = HoverSlider(value: 200, minValue: 0, maxValue: 600, target: nil, action: nil)
        slider.frame = NSRect(x: 10, y: 10, width: 800, height: 30)
        window.contentView!.addSubview(slider)
        window.makeFirstResponder(slider)
        guard window.firstResponder === slider else { throw Failure(message: "slider did not become first responder") }
        slider.target = slider; slider.action = #selector(HoverSlider.changed)
        slider.onSeek = { controller.seek(to: $0) }
        slider.onSkip = { controller.skip($0) }
        func key(_ code: UInt16, repeatKey: Bool = false) -> NSEvent {
            let character = code == 123 ? "\u{f702}" : "\u{f703}"
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, characters: character,
                                    charactersIgnoringModifiers: character, isARepeat: repeatKey, keyCode: code)!
        }
        func checkAt(_ name: String, _ expected: Double) async throws {
            try await until(name) { abs(controller.player.currentTime().seconds - expected) < 0.3 }
            guard !controller.playbackRequested, controller.player.rate == 0 else { throw Failure(message: "\(name) resumed paused playback") }
            print("PASS \(name)")
        }
        slider.keyDown(with: key(124)); try await checkAt("right_arrow_advances_10_seconds", 210)
        slider.keyDown(with: key(123)); try await checkAt("left_arrow_rewinds_10_seconds", 200)
        for _ in 0..<3 { slider.keyDown(with: key(124)) }
        try await checkAt("three_distinct_presses_accumulate_30_seconds", 230)
        for _ in 0..<4 { slider.keyDown(with: key(124, repeatKey: true)) }
        try await Task.sleep(nanoseconds: 350_000_000)
        try await checkAt("automatic_repeats_do_not_add_extra_steps", 230)
        guard slider.accessibilityPerformIncrement() else { throw Failure(message: "accessibility increment not handled") }
        try await checkAt("accessibility_increment_advances_10_seconds", 240)
        guard slider.accessibilityPerformDecrement() else { throw Failure(message: "accessibility decrement not handled") }
        try await checkAt("accessibility_decrement_rewinds_10_seconds", 230)
        controller.seek(to: 3); try await checkAt("seek_near_start", 3)
        slider.keyDown(with: key(123)); try await checkAt("left_arrow_clamps_to_start", 0)
        controller.seek(to: 200); try await checkAt("reset_for_canvas", 200)
        let presentation = PlayerPresentationController()
        let canvas = PlaybackKeyboardSurface.KeyboardView()
        canvas.bind(playback: controller, presentation: presentation)
        canvas.frame = NSRect(x: 0, y: 0, width: 900, height: 90)
        window.contentView!.addSubview(canvas); window.makeFirstResponder(canvas)
        guard window.firstResponder === canvas else { throw Failure(message: "canvas did not become first responder") }
        canvas.keyDown(with: key(124)); try await checkAt("canvas_right_arrow_advances_10_seconds", 210)
        canvas.keyDown(with: key(123)); try await checkAt("canvas_left_arrow_rewinds_10_seconds", 200)
        for _ in 0..<3 { canvas.keyDown(with: key(124)) }
        try await checkAt("canvas_three_distinct_presses_accumulate_30_seconds", 230)
        for _ in 0..<4 { canvas.keyDown(with: key(124, repeatKey: true)) }
        try await Task.sleep(nanoseconds: 350_000_000)
        try await checkAt("canvas_automatic_repeats_do_not_add_extra_steps", 230)
        canvas.detachInput()
        controller.pause()
    }
}
