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

    @MainActor static func main() async {
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
            ("long_video_hover_jitter_keeps_one_honest_anchor", {
                let f = Fixture(); f.view.maxValue = 7200
                f.view.mouseEntered(with: try f.event(.mouseEntered, fraction: 0.5))
                f.view.mouseMoved(with: try f.event(.mouseMoved, fraction: 0.501))
                try require(f.record.hovers.count == 2 && f.record.hovers.allSatisfy { abs(($0 ?? -1) - 3600) < 0.001 },
                            "A subpoint jitter on a long video replaced the preview anchor")
                f.view.mouseMoved(with: try f.event(.mouseMoved, fraction: 0.51))
                try require(f.record.hovers.count == 3 && abs((f.record.hovers[2] ?? -1) - 3672) < 0.001,
                            "Meaningful movement did not update the preview target")
                f.view.mouseExited(with: try f.event(.mouseExited, fraction: 1.1))
                f.view.mouseEntered(with: try f.event(.mouseEntered, fraction: 0.501))
                try require(f.record.hovers.count == 5 && abs((f.record.hovers[4] ?? -1) - 3607.2) < 0.001,
                            "A new hover did not start a fresh anchor")
                // Re-emitting the anchor permits the SwiftUI layer to hide and
                // then resume the preview without a larger physical movement.
                f.view.mouseMoved(with: try f.event(.mouseMoved, fraction: 0.501))
                try require(f.record.hovers.count == 6 && abs((f.record.hovers[5] ?? -1) - 3607.2) < 0.001,
                            "An unchanged pointer did not re-emit its preview anchor")
                f.view.maxValue = 3600
                let samePoint = try f.event(.mouseMoved, fraction: 0.501)
                f.view.mouseMoved(with: samePoint)
                try require(abs((f.record.hovers.last! ?? -1) - 1803.6) < 0.001,
                            "A changed duration reused a stale time")
                f.view.frame.size.width += 100
                // The offscreen cell may not repaint its cached bar rectangle;
                // a subpoint move still demonstrates the anchor is invalidated.
                f.view.mouseMoved(with: try f.event(.mouseMoved, fraction: 0.502))
                try require(abs((f.record.hovers.last! ?? -1) - 1807.2) < 0.001,
                            "A resized timeline reused a stale anchor")
                f.view.maxValue = 7200
                f.view.mouseDown(with: try f.event(.leftMouseDown, fraction: 0.5))
                f.view.mouseDragged(with: try f.event(.leftMouseDragged, fraction: 0.501))
                f.view.mouseUp(with: try f.event(.leftMouseUp, fraction: 0.501))
                try require(f.record.seeks.count == 1 && abs(f.record.seeks[0] - 3607.2) < 0.001,
                            "Tiny physical movement incorrectly changed the precision of committed seeking")
                return "Small physical motion retains a matching time anchor, while a larger move or re-entry updates it."
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
        do {
            let f = Fixture(); f.view.maxValue = 7200
            f.view.mouseEntered(with: try f.event(.mouseEntered, fraction: 0.5))
            f.view.mouseMoved(with: try f.event(.mouseMoved, fraction: 0.5038))
            try require(abs((f.record.hovers.last! ?? -1) - 3600) < 0.001, "Subpoint jitter should initially retain the old anchor")
            try await Task.sleep(nanoseconds: 600_000_000)
            try require(abs((f.record.hovers.last! ?? -1) - 3627.36) < 0.001, "A settled pointer must eventually select its true time")
            checks.append(.init(name: "long_video_settled_pointer_selects_exact_time", passed: true,
                                detail: "A sub-2pt move is initially stabilized, then resolves to the pointer's true timestamp after it stops."))
        } catch {
            checks.append(.init(name: "long_video_settled_pointer_selects_exact_time", passed: false, detail: String(describing: error)))
        }
        let cancelledSettlements: [(String, @MainActor (Fixture) throws -> Void)] = [
            ("exit", { f in f.view.mouseExited(with: try f.event(.mouseExited, fraction: 1.1)) }),
            ("hidden", { f in f.view.previewVisible = false }),
            ("item_change", { f in f.view.itemID = UUID() }),
            ("duration_change", { f in f.view.maxValue = 3600 }),
            ("width_change", { f in f.view.frame.size.width += 100 }),
            ("disabled", { f in f.view.isEnabled = false }),
            ("drag", { f in f.view.mouseDown(with: try f.event(.leftMouseDown, fraction: 0.7)) }),
            ("large_move", { f in f.view.mouseMoved(with: try f.event(.mouseMoved, fraction: 0.7)) })
        ]
        for (name, action) in cancelledSettlements {
            do {
                let f = Fixture(); f.view.maxValue = 7200
                f.view.mouseEntered(with: try f.event(.mouseEntered, fraction: 0.5))
                f.view.mouseMoved(with: try f.event(.mouseMoved, fraction: 0.5038))
                try action(f)
                let count = f.record.hovers.count
                try await Task.sleep(nanoseconds: 500_000_000)
                if name == "duration_change" || name == "width_change" {
                    try require(f.record.hovers.count == count + 1 && f.record.hovers.last! == nil,
                                "A layout change must dismiss the old preview without restoring the old hover")
                } else {
                    try require(f.record.hovers.count == count, "A delayed hover escaped after \(name)")
                }
                if name == "drag" {
                    f.view.mouseUp(with: try f.event(.leftMouseUp, fraction: 0.701))
                    try require(f.record.seeks.count == 1 && abs(f.record.seeks[0] - 5047.2) < 0.001,
                                "Cancelling a hover affected the precise drag target")
                }
                checks.append(.init(name: "settlement_cancelled_\(name)", passed: true,
                                    detail: "No old hover callback fires after \(name)."))
            } catch {
                checks.append(.init(name: "settlement_cancelled_\(name)", passed: false, detail: String(describing: error)))
            }
        }
        let layoutChanges: [(String, @MainActor (Fixture) -> Void)] = [
            ("duration", { f in f.view.maxValue = 3600 }),
            ("width", { f in f.view.frame.size.width += 100 })
        ]
        for (name, change) in layoutChanges {
            do {
                let f = Fixture(); f.view.maxValue = 7200
                f.view.mouseEntered(with: try f.event(.mouseEntered, fraction: 0.5))
                f.view.mouseMoved(with: try f.event(.mouseMoved, fraction: 0.5038))
                let before = f.record.hovers.count
                change(f)
                try require(f.record.hovers.count == before, "Layout invalidation synchronously changed SwiftUI state")
                try await Task.sleep(nanoseconds: 100_000_000)
                try require(f.record.hovers.count == before + 1 && f.record.hovers.last! == nil,
                            "A changed \(name) did not dismiss the old preview without pointer motion")
                let afterDismissal = f.record.hovers.count
                try await Task.sleep(nanoseconds: 450_000_000)
                try require(f.record.hovers.count == afterDismissal, "An old delayed hover reopened the preview")
                f.view.mouseMoved(with: try f.event(.mouseMoved, fraction: 0.7))
                try require(f.record.hovers.last! != nil, "A fresh hover did not restart the preview")
                checks.append(.init(name: "layout_change_dismisses_preview_\(name)", passed: true,
                                    detail: "A changed \(name) asynchronously dismisses the old preview and permits a fresh hover."))
            } catch {
                checks.append(.init(name: "layout_change_dismisses_preview_\(name)", passed: false, detail: String(describing: error)))
            }
        }
        for replaceItem in [false, true] {
            let name = replaceItem ? "item_change" : "new_hover"
            do {
                let f = Fixture(); f.view.maxValue = 7200
                f.view.mouseEntered(with: try f.event(.mouseEntered, fraction: 0.5))
                f.view.maxValue = 3600 // queues an asynchronous stale-preview dismissal
                if replaceItem { f.view.itemID = UUID() }
                f.view.mouseMoved(with: try f.event(.mouseMoved, fraction: 0.7))
                let count = f.record.hovers.count
                try require(abs((f.record.hovers.last! ?? -1) - 2520) < 0.001, "Fresh hover was not reported")
                try await Task.sleep(nanoseconds: 100_000_000)
                try require(f.record.hovers.count == count && abs((f.record.hovers.last! ?? -1) - 2520) < 0.001,
                            "A stale queued dismissal hid the replacement hover")
                checks.append(.init(name: "old_dismissal_does_not_hide_\(name)", passed: true,
                                    detail: "The invalidation generation protects a later \(name)."))
            } catch {
                checks.append(.init(name: "old_dismissal_does_not_hide_\(name)", passed: false, detail: String(describing: error)))
            }
        }
        let passed = checks.count == 11 + cancelledSettlements.count + layoutChanges.count && checks.allSatisfy(\.passed)
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
