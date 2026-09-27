// Concatenated after the real private HoverSlider by scripts/validate-seek-bar.sh.
// Synthetic NSEvents are delivered directly to an unshown local view. No window
// is ordered front, activated, or controlled through the user's desktop.
@main
struct SeekBarInteractionSmoke {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Check: Encodable { let name: String; let passed: Bool; let detail: String }
    struct Summary: Encodable {
        let checkedAt: String
        let mode = "headless AppKit: real HoverSlider with direct synthetic NSEvents"
        let userUIControlled = false
        let physicalPointerDeliveryVerified = false
        let previewRenderingVerified = false
        let passed: Bool
        let checks: [Check]
    }
    @MainActor private final class Recorder {
        var values: [Double] = []
        var seeks: [Double] = []
        var editing: [Bool] = []
        var hovers: [Double?] = []
    }
    @MainActor private struct Fixture {
        let window: NSWindow
        let view: HoverSlider
        let record: Recorder
        init(enabled: Bool = true) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 80), styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            view = HoverSlider(value: 20, minValue: 0, maxValue: 100, target: nil, action: nil)
            view.frame = NSRect(x: 20, y: 20, width: 480, height: 28)
            view.isEnabled = enabled; view.isContinuous = true
            view.target = view; view.action = #selector(HoverSlider.changed)
            record = Recorder()
            let record = record
            view.onValue = { record.values.append($0) }
            view.onSeek = { record.seeks.append($0) }
            view.onEditing = { record.editing.append($0) }
            view.onHover = { record.hovers.append($0?.time) }
            window.contentView?.addSubview(view)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func event(_ type: NSEvent.EventType, fraction: Double) throws -> NSEvent {
            guard let cell = view.cell as? NSSliderCell else { throw Failure(description: "Missing real NSSliderCell") }
            let bar = cell.barRect(flipped: view.isFlipped), knob = cell.knobRect(flipped: view.isFlipped)
            try require(bar.width > knob.width && knob.width > 0, "Invalid native slider geometry: bar=\(bar), knob=\(knob)")
            // The expected time is independently fixed by each test (50, 75, etc).
            // Position an event along the native thumb's allowed center travel.
            let local = NSPoint(x: bar.minX + knob.width / 2 + fraction * (bar.width - knob.width), y: view.bounds.midY)
            let location = view.convert(local, to: nil)
            let event: NSEvent?
            if type == .mouseEntered || type == .mouseExited {
                event = NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)
            } else {
                event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
            }
            guard let event else { throw Failure(description: "Could not create local test event") }
            return event
        }
        func beginAndDrag() throws {
            view.mouseDown(with: try event(.leftMouseDown, fraction: 0.5))
            view.mouseDragged(with: try event(.leftMouseDragged, fraction: 0.75))
            try require(abs(view.doubleValue - 75) < 0.0001, "Real drag did not update candidate value to 75")
            try require(record.seeks.isEmpty, "Pointer movement committed before mouseUp")
        }
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        let cases: [(String, @MainActor () throws -> String)] = [
            ("cancel_restores_value_and_ignores_late_mouse_up", {
                let f = Fixture()
                try f.beginAndDrag()
                f.view.cancelTracking()
                try require(!f.view.isTrackingPointer && abs(f.view.doubleValue - 20) < 0.0001, "Cancel retained the dragged 75-second candidate instead of original 20")
                try require(f.record.values.last == 20, "Cancel did not restore the SwiftUI binding through onValue")
                try require(f.record.editing == [true, false] && f.record.hovers.last! == nil, "Cancel left editing or preview active")
                f.view.mouseUp(with: try f.event(.leftMouseUp, fraction: 0.9))
                try require(f.record.seeks.isEmpty && f.view.doubleValue == 20, "Late mouseUp committed a canceled drag")
                return "A 20→50→75 drag cancels back to 20 in both native value and binding, with no late commit."
            }),
            ("mouse_up_commits_final_event_exactly_once", {
                let f = Fixture()
                try f.beginAndDrag()
                f.view.mouseUp(with: try f.event(.leftMouseUp, fraction: 0.8))
                try require(f.record.seeks.count == 1 && abs(f.record.seeks[0] - 80) < 0.0001, "MouseUp did not commit exactly the final event's 80-second target")
                try require(f.record.editing == [true, false] && !f.view.isTrackingPointer, "Finished drag retained editing state")
                f.view.mouseUp(with: try f.event(.leftMouseUp, fraction: 0.9))
                try require(f.record.seeks.count == 1, "Duplicate mouseUp committed twice")
                return "Down and drag publish candidates only; release commits its own 80-second position exactly once."
            }),
            ("disabled_slider_ignores_all_pointer_events", {
                let f = Fixture(enabled: false)
                f.view.mouseDown(with: try f.event(.leftMouseDown, fraction: 0.5))
                f.view.mouseDragged(with: try f.event(.leftMouseDragged, fraction: 0.75))
                f.view.mouseUp(with: try f.event(.leftMouseUp, fraction: 0.8))
                try require(f.record.values.isEmpty && f.record.seeks.isEmpty && f.record.editing.isEmpty, "Disabled slider published input or a seek")
                try require(f.view.doubleValue == 20 && !f.view.isTrackingPointer, "Disabled slider changed native value or entered tracking")
                return "Disabled mouseDown/drag/up neither change value nor commit a seek."
            }),
            ("window_resignation_restores_cancelled_drag", {
                let f = Fixture()
                try f.beginAndDrag()
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: f.window)
                try require(!f.view.isTrackingPointer && f.view.doubleValue == 20 && f.record.values.last == 20, "Actual window-resignation observer failed to restore the canceled value")
                try require(f.record.editing == [true, false] && f.record.seeks.isEmpty, "Window resignation committed or left editing active")
                return "The real didResignKey observer cancels and restores without a seek."
            }),
            ("detaching_the_view_ends_tracking_without_commit", {
                let f = Fixture()
                try f.beginAndDrag()
                f.view.removeFromSuperview()
                try require(!f.view.isTrackingPointer && f.view.doubleValue == 20, "Removing the view did not cancel and restore its drag")
                try require(f.record.editing == [true, false] && f.record.seeks.isEmpty, "Detaching the view left an edit or committed a seek")
                return "Removing the unshown test view exercises viewWillMove cancellation and editing cleanup."
            }),
            ("silent_item_invalidation_does_not_restore_old_value", {
                let f = Fixture()
                try f.beginAndDrag()
                let callbacks = f.record.values.count
                f.view.cancelTracking(notify: false) // updateNSView uses this before replacing itemID/value.
                f.view.itemID = UUID(); f.view.doubleValue = 7
                f.view.mouseUp(with: try f.event(.leftMouseUp, fraction: 0.9))
                try require(f.record.values.count == callbacks && f.record.seeks.isEmpty && f.view.doubleValue == 7, "Silent item invalidation wrote the previous item's value or accepted its mouseUp")
                return "Silent cancellation does not write an old value into a replacement item's binding and ignores the previous release."
            }),
            ("pure_hover_does_not_change_value_or_seek", {
                let f = Fixture()
                f.view.mouseEntered(with: try f.event(.mouseEntered, fraction: 0.5))
                f.view.mouseMoved(with: try f.event(.mouseMoved, fraction: 0.75))
                try require(f.record.hovers.count == 2 && abs((f.record.hovers[0] ?? -1) - 50) < 0.0001 && abs((f.record.hovers[1] ?? -1) - 75) < 0.0001, "Entered/moved hover did not report the event-local 50/75-second positions")
                try require(f.view.doubleValue == 20 && f.record.values.isEmpty && f.record.seeks.isEmpty && f.record.editing.isEmpty, "Hover changed playback candidate, committed seek, or began editing")
                f.view.mouseExited(with: try f.event(.mouseExited, fraction: 1.1))
                try require(f.record.hovers.last! == nil && f.view.doubleValue == 20, "Mouse exit did not dismiss hover independently of the value")
                return "Entered/moved report 50/75-second previews; native value stays 20 and no value, seek or editing callback fires."
            })
        ]
        var checks: [Check] = []
        for (name, body) in cases {
            do { checks.append(Check(name: name, passed: true, detail: try body())) }
            catch { checks.append(Check(name: name, passed: false, detail: String(describing: error))) }
        }
        let passed = checks.count == 7 && checks.allSatisfy(\.passed)
        let summary = Summary(checkedAt: ISO8601DateFormatter().string(from: Date()), passed: passed, checks: checks)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(summary) + Data("\n".utf8))
        } catch { print(error); exit(1) }
        exit(passed ? 0 : 1)
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
}
