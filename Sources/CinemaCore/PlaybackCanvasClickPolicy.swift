import Foundation

/// A canvas single click is committed only after the system double-click window.
/// Keeping the decision separate from the timer also rejects obsolete callbacks
/// after navigation, focus changes, another click, or a drag.
public struct PlaybackCanvasClickPolicy {
    public enum Action: Equatable { case togglePlayback, toggleFullscreen }
    public struct PendingSingleClick {
        public let id: UInt64
        public let deadline: TimeInterval
    }
    public private(set) var pendingSingleClick: PendingSingleClick?
    private struct Press {
        let origin: CGPoint
        let isDoubleClick: Bool
    }
    private var press: Press?
    private var nextID: UInt64 = 0
    private let dragTolerance: CGFloat = 4

    public init() {}

    public mutating func pointerDown(button: Int, clickCount: Int, at point: CGPoint) {
        // AppKit click counts span controls. Both clicks must begin on this canvas.
        let isDoubleClick = clickCount == 2 && pendingSingleClick != nil
        cancel()
        guard button == 0, clickCount == 1 || isDoubleClick else { return }
        press = Press(origin: point, isDoubleClick: isDoubleClick)
    }

    public mutating func pointerDragged(to point: CGPoint) {
        guard let press, movedBeyondClick(from: press.origin, to: point) else { return }
        cancel()
    }

    public mutating func pointerUp(button: Int, at point: CGPoint, insideCanvas: Bool, now: TimeInterval, doubleClickInterval: TimeInterval) -> Action? {
        guard let press else { return nil }
        self.press = nil
        guard button == 0, insideCanvas, !movedBeyondClick(from: press.origin, to: point) else { cancel(); return nil }
        if press.isDoubleClick { return .toggleFullscreen }
        guard now.isFinite, doubleClickInterval.isFinite, doubleClickInterval >= 0 else { return nil }
        nextID &+= 1
        pendingSingleClick = PendingSingleClick(id: nextID, deadline: now + doubleClickInterval)
        return nil
    }

    public mutating func fireSingleClick(_ id: UInt64, now: TimeInterval) -> Action? {
        guard let pending = pendingSingleClick, pending.id == id,
              now.isFinite, now >= pending.deadline else { return nil }
        pendingSingleClick = nil
        return .togglePlayback
    }

    public mutating func cancel() { press = nil; pendingSingleClick = nil }

    private func movedBeyondClick(from origin: CGPoint, to point: CGPoint) -> Bool {
        let dx = point.x - origin.x, dy = point.y - origin.y
        return dx * dx + dy * dy > dragTolerance * dragTolerance
    }
}
