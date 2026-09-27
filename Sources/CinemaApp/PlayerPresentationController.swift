import SwiftUI
import AppKit
import CinemaCore

/// Owns only the current player's window and idle UI. It never intercepts input
/// or changes the AVPlayer/VideoSurface when the window enters full screen.
@MainActor
final class PlayerPresentationController: ObservableObject {
    @Published private(set) var isFullscreen = false
    @Published private(set) var controlsVisible = true
    private weak var window: NSWindow?
    private var observations: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var timer: Timer?
    private var previousMouseMovedEvents = false
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var interactions: Set<String> = []
    private var menuDepth = 0
    private var cursorWasHidden = false
    private var playing = false
    private var buffering = false
    private var hasError = false

    func attach(to next: NSWindow?) {
        guard next !== window else { return }
        detach()
        guard let next else { return }
        window = next
        previousMouseMovedEvents = next.acceptsMouseMovedEvents
        next.acceptsMouseMovedEvents = true
        setFullscreen(next.styleMask.contains(.fullScreen))
        observe(NSWindow.didEnterFullScreenNotification, object: next) { $0.syncFullscreen() }
        observe(NSWindow.didExitFullScreenNotification, object: next) { $0.syncFullscreen() }
        observe(NSWindow.didBecomeKeyNotification, object: next) { $0.activity() }
        observe(NSWindow.didResignKeyNotification, object: next) { $0.resetInteraction() }
        observe(NSWindow.willCloseNotification, object: next) { $0.detach() }
        observe(NSApplication.didResignActiveNotification) { $0.resetInteraction() }
        observe(NSApplication.didBecomeActiveNotification) { $0.activity() }
        observe(NSMenu.didBeginTrackingNotification) { owner in
            guard owner.window?.isKeyWindow == true else { return }
            owner.menuDepth += 1; owner.activity()
        }
        observe(NSMenu.didEndTrackingNotification) { owner in
            owner.menuDepth = max(0, owner.menuDepth - 1); owner.activity()
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.activity()
            return event
        }
        let tick = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateVisibility() }
        }
        timer = tick
        RunLoop.main.add(tick, forMode: .common)
    }

    func detach() {
        timer?.invalidate(); timer = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations = []
        window?.acceptsMouseMovedEvents = previousMouseMovedEvents
        window = nil
        interactions = []; menuDepth = 0
        setFullscreen(false)
    }

    func updatePlayback(isPlaying: Bool, isBuffering: Bool, hasError: Bool) {
        guard playing != isPlaying || buffering != isBuffering || self.hasError != hasError else { return }
        playing = isPlaying; buffering = isBuffering; self.hasError = hasError
        activity()
    }

    func activity() {
        lastActivity = ProcessInfo.processInfo.systemUptime
        showControls()
    }

    func interact(_ reason: String, active: Bool) {
        if active { interactions.insert(reason) } else { interactions.remove(reason) }
        activity()
    }

    func toggleFullscreen() { activity(); window?.toggleFullScreen(nil) }
    func leaveFullscreen() {
        activity()
        if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
    }

    private func syncFullscreen() { setFullscreen(window?.styleMask.contains(.fullScreen) == true) }
    private func setFullscreen(_ value: Bool) {
        guard isFullscreen != value else { activity(); return }
        isFullscreen = value
        resetInteraction()
    }
    private func resetInteraction() { interactions = []; menuDepth = 0; activity() }
    private func showControls() {
        if !controlsVisible { controlsVisible = true }
        if cursorWasHidden { NSCursor.setHiddenUntilMouseMoves(false); cursorWasHidden = false }
    }
    private func updateVisibility() {
        guard let window else { showControls(); return }
        // The style mask is authoritative, including interrupted/failed system
        // transitions for which a completion notification may not arrive.
        let actualFullscreen = window.styleMask.contains(.fullScreen)
        if isFullscreen != actualFullscreen { setFullscreen(actualFullscreen) }
        let canHide = FullscreenControlsPolicy.shouldHide(
            isFullscreen: isFullscreen, isPlaying: playing, isBuffering: buffering,
            hasError: hasError,
            isInteracting: !interactions.isEmpty || menuDepth > 0 || window.attachedSheet != nil,
            isActive: NSApp.isActive && window.isKeyWindow,
            idleFor: ProcessInfo.processInfo.systemUptime - lastActivity)
        guard canHide else { showControls(); return }
        if controlsVisible { controlsVisible = false }
        // Do not hide another screen's cursor while this window remains key.
        if window.frame.contains(NSEvent.mouseLocation) && !cursorWasHidden {
            NSCursor.setHiddenUntilMouseMoves(true); cursorWasHidden = true
        }
    }
    private func observe(_ name: Notification.Name, object: AnyObject? = nil, action: @escaping (PlayerPresentationController) -> Void) {
        observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }
}

/// An invisible window attachment, not an alternate video view. This also finds
/// windows already in full screen before a title is opened from the library.
struct PlayerWindowAttachment: NSViewRepresentable {
    let presentation: PlayerPresentationController
    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.presentation = presentation
        return view
    }
    func updateNSView(_ view: AttachmentView, context: Context) { view.presentation = presentation; view.attachLater() }
    static func dismantleNSView(_ view: AttachmentView, coordinator: ()) { view.presentation?.detach(); view.presentation = nil }
    final class AttachmentView: NSView {
        weak var presentation: PlayerPresentationController?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attachLater() }
        func attachLater() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.presentation?.attach(to: self.window)
            }
        }
    }
}
