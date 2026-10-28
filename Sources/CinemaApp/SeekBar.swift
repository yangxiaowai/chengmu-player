import SwiftUI
import AppKit
import AVFoundation
import CinemaCore

struct SeekBar: View {
    @Binding var value: Double
    let duration: Double
    let asset: AVAsset?
    let itemID: UUID
    let isConfirmedHLS: Bool
    let visible: Bool
    let onEditing: (Bool) -> Void
    let onSeek: (Double) -> Void
    let onSkip: (Double) -> Void
    let onHover: (Bool) -> Void
    @StateObject private var preview = SeekPreviewController()
    @LegacyState private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            TimelineSlider(value: $value, duration: duration, itemID: itemID, visible: visible, onEditing: onEditing, onSeek: onSeek, onSkip: onSkip) { location in
                guard visible, let location else { dismissPreview(); return }
                hoverX = location.x
                onHover(true)
                preview.request(time: location.time, duration: duration)
            }
            .overlay(alignment: .bottomLeading) {
                if let hoverX, visible {
                    previewCard
                        .frame(width: min(220, geometry.size.width))
                        .offset(x: SeekTimelineGeometry.bubbleOrigin(at: hoverX, width: geometry.size.width, bubbleWidth: 220), y: -38)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 28)
        .onAppear { preview.configure(asset: asset, itemID: itemID, isConfirmedHLS: isConfirmedHLS) }
        .onChange(of: itemID) { _, _ in onEditing(false); dismissPreview(); preview.configure(asset: asset, itemID: itemID, isConfirmedHLS: isConfirmedHLS) }
        .onChange(of: isConfirmedHLS) { _, value in preview.configure(asset: asset, itemID: itemID, isConfirmedHLS: value) }
        .onChange(of: duration) { _, value in if !value.isFinite || value <= 0 { onEditing(false); dismissPreview() } }
        .onChange(of: visible) { _, shown in if !shown { dismissPreview() } }
        .onDisappear { onEditing(false); dismissPreview(); preview.stop() }
    }

    private var previewCard: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image = preview.image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if preview.isLoading {
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("正在加载预览").font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "film")
                        Text(preview.message ?? "等待预览").font(.system(size: 10)).multilineTextAlignment(.center)
                    }.foregroundStyle(.white.opacity(0.7)).padding(10)
                }
            }.frame(height: 124)
            HStack(spacing: 8) {
                Text(timeString(preview.requestedTime)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                Spacer(minLength: 0)
                if let actual = preview.actualTime, timeString(actual) != timeString(preview.requestedTime) {
                    Text("帧 \(timeString(actual))").font(.system(size: 9, design: .monospaced)).foregroundStyle(CinemaStyle.secondary)
                }
            }.padding(.horizontal, 10).padding(.vertical, 7)
        }
        .background(CinemaStyle.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.18)))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("进度预览 \(timeString(preview.requestedTime))")
    }

    private func dismissPreview() {
        hoverX = nil; preview.hide(); onHover(false)
    }
}

private struct TimelineSlider: NSViewRepresentable {
    @Binding var value: Double
    let duration: Double
    let itemID: UUID
    let visible: Bool
    let onEditing: (Bool) -> Void
    let onSeek: (Double) -> Void
    let onSkip: (Double) -> Void
    let onHover: (TimelineLocation?) -> Void

    func makeNSView(context: Context) -> HoverSlider {
        let view = HoverSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
        view.target = view; view.action = #selector(HoverSlider.changed)
        view.isContinuous = true
        view.trackFillColor = NSColor(CinemaStyle.accent)
        view.setAccessibilityLabel("播放进度")
        return view
    }
    func updateNSView(_ view: HoverSlider, context: Context) {
        if view.itemID != itemID { view.cancelTracking(notify: false); view.itemID = itemID }
        view.previewVisible = visible
        view.onValue = { value = $0 }; view.onSeek = onSeek; view.onSkip = onSkip
        view.onEditing = onEditing; view.onHover = onHover
        view.isEnabled = duration.isFinite && duration > 0
        if !view.isEnabled { view.cancelTracking(notify: false) }
        let maxValue = view.isEnabled ? duration : 1
        view.maxValue = maxValue
        if !view.isTrackingPointer { view.doubleValue = min(view.maxValue, max(0, value)) }
    }
    static func dismantleNSView(_ view: HoverSlider, coordinator: ()) {
        view.cancelTracking(notify: false)
        view.onHover = nil; view.onEditing = nil; view.onSeek = nil; view.onSkip = nil; view.onValue = nil
    }
}

private struct TimelineLocation { let x: CGFloat; let time: Double }

enum PlaybackArrowKeyPolicy {
    static func offset(keyCode: UInt16, isRepeat: Bool) -> Double? {
        guard !isRepeat else { return nil }
        switch keyCode { case 123: return -10; case 124: return 10; default: return nil }
    }
}

private final class HoverSlider: NSSlider {
    var itemID: UUID? { didSet { if oldValue != itemID { invalidateHoverAnchor() } } }
    var previewVisible = true { didSet { if !previewVisible { invalidateHoverAnchor() } } }
    override var maxValue: Double {
        didSet { if oldValue != maxValue { invalidateHoverAnchor(notify: true) } }
    }
    var onValue: ((Double) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onSkip: ((Double) -> Void)?
    var onEditing: ((Bool) -> Void)?
    var onHover: ((TimelineLocation?) -> Void)?
    private(set) var isTrackingPointer = false
    private var pointerDownValue: Double = 0
    private var area: NSTrackingArea?
    private var resignObserver: NSObjectProtocol?
    // Keep a tiny pointer jitter from restarting preview on long timelines. The
    // displayed time and image both remain tied to this same physical anchor.
    private var hoverAnchor: TimelineLocation?
    private var anchorDuration = 0.0
    private var anchorWidth: CGFloat = 0
    private var hoverSettlement: DispatchWorkItem?
    private var hoverGeneration = UUID()

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 123, 124:
            if let amount = PlaybackArrowKeyPolicy.offset(keyCode: event.keyCode, isRepeat: event.isARepeat) { onSkip?(amount) }
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled, let onSkip else { return false }
        onSkip(10); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled, let onSkip else { return false }
        onSkip(-10); return true
    }
    // AppKit and assistive input can dispatch these responder actions directly
    // without calling keyDown; NSSlider's default is 5% of the whole duration.
    override func moveRight(_ sender: Any?) { if isEnabled { onSkip?(10) } }
    override func moveLeft(_ sender: Any?) { if isEnabled { onSkip?(-10) } }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { invalidateHoverAnchor(notify: true) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        area = next; addTrackingArea(next)
    }
    override func mouseEntered(with event: NSEvent) { updateHover(event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { updateHover(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { if !isTrackingPointer { dismissHover() } }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        invalidateHoverAnchor()
        window?.makeFirstResponder(self)
        pointerDownValue = doubleValue
        isTrackingPointer = true; onEditing?(true)
        updatePointer(event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard isTrackingPointer else { return }
        updatePointer(event)
    }
    override func mouseUp(with event: NSEvent) {
        guard isTrackingPointer else { return }
        updatePointer(event)
        isTrackingPointer = false
        onSeek?(doubleValue); onEditing?(false)
        updateHover(event.locationInWindow)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { cancelTracking() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let window {
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelTracking(); self?.dismissHover() }
            }
        }
    }
    deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }
    func cancelTracking(notify: Bool = true) {
        invalidateHoverAnchor()
        guard isTrackingPointer else { return }
        isTrackingPointer = false
        if notify {
            doubleValue = pointerDownValue; onValue?(pointerDownValue)
            onEditing?(false); onHover?(nil)
        }
    }
    private func updatePointer(_ event: NSEvent) {
        guard let location = location(for: event.locationInWindow) else { return }
        // Event-local coordinates also work for accessibility/remote pointer
        // input, whose position need not match the system's global cursor.
        invalidateHoverAnchor()
        doubleValue = location.time; onValue?(doubleValue); onHover?(location)
    }
    @objc func changed() {
        onValue?(doubleValue)
        if !isTrackingPointer { onSeek?(doubleValue) } // Keyboard and accessibility adjustments.
    }
    private func location(for windowPoint: NSPoint) -> TimelineLocation? {
        guard isEnabled, let cell = cell as? NSSliderCell else { return nil }
        let point = convert(windowPoint, from: nil)
        let bar = cell.barRect(flipped: isFlipped)
        let knob = cell.knobRect(flipped: isFlipped)
        guard let time = SeekTimelineGeometry.time(at: point.x - bar.minX, width: bar.width, knobWidth: knob.width, duration: maxValue) else { return nil }
        return TimelineLocation(x: min(bounds.maxX, max(bounds.minX, point.x)), time: time)
    }
    private func updateHover(_ windowPoint: NSPoint) {
        guard previewVisible else { invalidateHoverAnchor(); return }
        guard bounds.contains(convert(windowPoint, from: nil)), let location = location(for: windowPoint) else { dismissHover(); return }
        if let anchor = hoverAnchor, anchorDuration == maxValue, anchorWidth == bounds.width,
           abs(anchor.x - location.x) < 2 {
            // Re-emit the same anchor so a control bar that was hidden can
            // restart its preview without waiting for a larger mouse movement.
            onHover?(anchor)
            scheduleSettledHover(location, anchor: anchor)
            return
        }
        cancelHoverSettlement()
        hoverAnchor = location
        anchorDuration = maxValue; anchorWidth = bounds.width
        onHover?(location)
    }
    private func scheduleSettledHover(_ location: TimelineLocation, anchor: TimelineLocation) {
        cancelHoverSettlement()
        guard abs(location.x - anchor.x) > 0.01 else { return }
        let generation = hoverGeneration, item = itemID, duration = maxValue, width = bounds.width
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoverGeneration == generation else { return }
            self.hoverSettlement = nil
            guard self.previewVisible, self.isEnabled, !self.isTrackingPointer, self.itemID == item,
                  self.maxValue == duration, self.bounds.width == width else { self.hoverAnchor = nil; return }
            self.hoverAnchor = location
            self.onHover?(location)
        }
        hoverSettlement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    private func cancelHoverSettlement() {
        hoverGeneration = UUID(); hoverSettlement?.cancel(); hoverSettlement = nil
    }
    func invalidateHoverAnchor(notify: Bool = false) {
        let shouldNotify = notify && hoverAnchor != nil && previewVisible
        cancelHoverSettlement(); hoverAnchor = nil
        guard shouldNotify else { return }
        let generation = hoverGeneration
        // updateNSView can change the slider's range or geometry while SwiftUI
        // is updating. Deliver dismissal on the next main-queue turn instead.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.previewVisible, self.hoverGeneration == generation else { return }
            self.onHover?(nil)
        }
    }
    private func dismissHover() { invalidateHoverAnchor(); onHover?(nil) }
}
