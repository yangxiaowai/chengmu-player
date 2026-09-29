import SwiftUI
import AppKit
import AVFoundation
import MetalKit
import CoreImage
import CinemaCore

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let mode: EnhancementMode
    var generation: UUID = UUID()
    var cleanup: AdCleanupSettings = .init()
    var resolution: EnhancementResolution = .automatic
    var frameRate: EnhancementFrameRate = .source
    var splitComparison = false
    var permission: VideoProcessingPermission = .inspectSDRFrames
    var assessedItem: AVPlayerItem?
    /// Receives the already decoded frame for local ad recognition, so no second decoder runs.
    var onScanFrame: ((CGImage, Double) -> Void)?
    let onMetrics: (EnhancementMetrics) -> Void
    func makeNSView(context: Context) -> CinemaVideoView { CinemaVideoView() }
    func updateNSView(_ view: CinemaVideoView, context: Context) {
        view.configure(player: player, mode: mode, generation: generation, cleanup: cleanup, permission: permission, assessedItem: assessedItem, resolution: resolution, frameRate: frameRate, splitComparison: splitComparison, onMetrics: onMetrics)
        view.onScanFrame = onScanFrame
    }
    static func dismantleNSView(_ view: CinemaVideoView, coordinator: ()) { view.stop() }
}

/// What actually reaches the screen right now, for diagnostics and validation harnesses.
struct VideoSurfaceDiagnosticState: Equatable {
    var isNativeVisible = true
    var hasEnhancedFrame = false
    var isHDRSticky = false
    var lastPixelFormat: OSType = 0
    var route = "原生"
}

/// Identify this item's single reusable output across view recreation. The item owns its
/// lifetime: repeatedly removing/re-adding outputs can rewind AVFoundation to a keyframe.
private final class CinemaItemVideoOutput: AVPlayerItemVideoOutput, @unchecked Sendable {}

final class CinemaVideoView: NSView, MTKViewDelegate {
    private let original = AVPlayerLayer()
    private var metalView: MTKView?
    private var pipeline: EnhancementPipeline?
    // Presentation may wait for WindowServer scheduling; keep that work off the
    // completed-frame processing queue and its Core Image context.
    private var displayQueue: MTLCommandQueue?
    private var displayContext: CIContext?
    private var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private weak var assessed: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var timer: Timer?
    private let worker = DispatchQueue(label: "Cinema.enhancement", qos: .userInitiated)
    private var mode = EnhancementMode.original
    private var cleanup: AdCleanupSettings = .init()
    private var resolution: EnhancementResolution = .automatic
    private var frameRate: EnhancementFrameRate = .source
    private var splitComparison = false
    private var sourceIntervals: [Double] = []
    private var nominalFPS: Double?
    private var interpolator: AnyObject?
    private var lookahead: LookaheadVideoDecoder?
    private var lookaheadDiscontinuity: UUID?
    private var pendingSources: [(buffer: CVPixelBuffer, time: CMTime)] = []
    private var interpolationQueue: [(time: Double, frame: EnhancedFrame)] = []
    private var lastPrefetchedPTS: Double?
    private var interpolationFailure: String?
    private var interpolationStartedAt: Double?
    private var interpolationClockOrigin: Double?
    private var interpolationWasActive = false
    private var interpolationHasMotionFrames = false
    private var presentationWindowStart: Double?
    private var presentationWindowFrames = 0
    private var displayedWindowStart: Double?
    private var displayedWindowFrames = 0
    private var lastDisplayedPTS: Double?
    private var permission = VideoProcessingPermission.nativeOnly("片源尚未评估")
    private var generation = UUID()
    private var revision = UUID()
    private var busy = false
    private var rendering = false
    private var lastRenderedPTS: Double?
    private var currentFrame: EnhancedFrame?
    private var forceFrame = true
    private var fallback: String?
    private var metrics = EnhancementMetrics()
    private var budget = FrameBudget()
    private var onMetrics: (EnhancementMetrics) -> Void = { _ in }
    private var lastReport: CFTimeInterval = 0
    private var nativeFrameRate: Double = 30
    private var displayTransform = CGAffineTransform.identity
    private var geometryReady = false
    // Direction failure belongs to the item, not the current seek/enhancement generation.
    private var geometryFailure: String?
    private var lastPTS: Double?
    private var timeObserver: NSObjectProtocol?
    /// Set once real decoded frames prove HDR/Dolby; a later configuration cannot clear it for this item.
    private var hdrSticky = false
    private var route = "原生"
    private var lastPixelFormat: OSType = 0
    private var reportedSize = CGSize.zero
    private var nativeRouteToken = UUID()
    private(set) var diagnosticState = VideoSurfaceDiagnosticState()
    /// Main-actor snapshot of current counters; read-only and does not mutate or publish state.
    @MainActor var diagnosticMetrics: EnhancementMetrics { metrics }
    /// Set by the player when local ad recognition should reuse this surface's decoded frames.
    var onScanFrame: ((CGImage, Double) -> Void)?
    private var lastScanHandoff: CFTimeInterval = 0
    private var scanConversionBusy = false
    private let scanInterval: CFTimeInterval = 0.35
    private static let scanQueue = DispatchQueue(label: "Cinema.ad-scan.shared", qos: .utility)
    private let scanContext = CIContext(options: [.cacheIntermediates: false])

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        original.videoGravity = .resizeAspect
        layer?.addSublayer(original)
        do {
            let pipeline = try EnhancementPipeline()
            guard let displayQueue = pipeline.device.makeCommandQueue() else {
                throw EnhancementError.unavailable("无法创建独立的视频显示队列")
            }
            displayQueue.label = "Cinema.display"
            self.displayQueue = displayQueue
            self.displayContext = CIContext(mtlCommandQueue: displayQueue, options: [
                .cacheIntermediates: false,
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            ])
            self.pipeline = pipeline
            let view = MTKView(frame: bounds, device: pipeline.device)
            view.framebufferOnly = false; view.colorPixelFormat = .rgba16Float
            // draw(in:) writes sRGB code values. A float drawable without this tag can
            // be presented as linear light, lifting shadows even when pipeline pixels match.
            view.colorspace = pipeline.colorSpace
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            view.isPaused = true; view.enableSetNeedsDisplay = false
            view.delegate = self; view.isHidden = true
            addSubview(view); metalView = view
        } catch { fallback = error.localizedDescription }
        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        original.frame = bounds
        CATransaction.commit()
        metalView?.frame = bounds
        if currentFrame != nil { metalView?.draw() }
    }
    func configure(player: AVPlayer, mode: EnhancementMode, generation: UUID, cleanup: AdCleanupSettings = .init(),
                   permission: VideoProcessingPermission = .inspectSDRFrames, assessedItem: AVPlayerItem? = nil,
                   resolution: EnhancementResolution = .automatic, frameRate: EnhancementFrameRate = .source, splitComparison: Bool = false,
                   onMetrics: @escaping (EnhancementMetrics) -> Void) {
        self.onMetrics = onMetrics
        let playerChanged = self.player !== player
        let itemChanged = self.item !== player.currentItem
        let previousPermission = self.permission
        let sourceChanged = playerChanged || itemChanged || self.generation != generation || self.assessed !== assessedItem
        let modeChanged = self.mode != mode || self.resolution != resolution || self.frameRate != frameRate || self.splitComparison != splitComparison
        let layoutChanged = modeChanged || self.cleanup != cleanup || previousPermission != permission
        self.resolution = resolution; self.frameRate = frameRate
        if self.splitComparison != splitComparison { self.splitComparison = splitComparison; metalView?.draw() }
        self.player = player; original.player = player
        self.mode = mode; self.generation = generation; self.cleanup = cleanup
        self.permission = permission
        if sourceChanged {
            self.assessed = assessedItem
            reset()
        } else if layoutChanged {
            // A new filter can recover a failed AI session or an exceeded frame budget. Keep
            // source-level blocks intact: a mode choice cannot authorize HDR or unknown geometry.
            if modeChanged, permission == .inspectSDRFrames, route == "增强", !hdrSticky,
               geometryReady, geometryFailure == nil {
                fallback = nil
                refreshRouteMetrics()
            }
            resetFrames()
        }
        if itemChanged {
            attachItem(player.currentItem)
        } else if layoutChanged, previousPermission != permission {
            // A permission change takes effect immediately: the conversion output is removed
            // before the next frame, and any in-flight GPU result is rejected by the revision.
            switch permission {
            case .nativeOnly(let reason):
                route = "原生"; fallback = reason; detachOutput(); showNative()
            case .inspectSDRFrames:
                // Real HDR frames stay blocked by the per-frame gate even after re-authorization.
                if !hdrSticky { route = "增强"; fallback = nil; attachOutputIfPossible() }
            }
            refreshRouteMetrics(); publish(force: true)
        }
    }
    private func reset() {
        revision = UUID(); currentFrame = nil; forceFrame = true
        resetInterpolationQueue()
        fallback = (assessed?.status == .readyToPlay) ? nil : "正在评估片源色彩，暂用原生播放"
        budget.reset(); metrics = EnhancementMetrics(); metrics.sourceFPS = nominalFPS; lastPTS = nil; lastRenderedPTS = nil
        hdrSticky = false; reportedSize = .zero
        nativeRouteToken = UUID()
        original.isHidden = false; metalView?.isHidden = true
        // Reason first, then publish: publishing an empty metric set would wipe the explanation
        // the user needs to understand why softening is not applied.
        refreshRouteMetrics()
        publish(force: true)
    }
    /// Keeps the accumulated counters (HDR stickiness, measured size) for a layout-only change.
    private func resetFrames() {
        revision = UUID(); currentFrame = nil; forceFrame = true
        resetInterpolationQueue()
        budget.reset(); lastPTS = nil; lastRenderedPTS = nil
        original.isHidden = false; metalView?.isHidden = true
        publish(force: true)
    }
    private func attachItem(_ next: AVPlayerItem?) {
        detachOutput()
        if let timeObserver { NotificationCenter.default.removeObserver(timeObserver) }
        item = next
        if case .nativeOnly = permission { detachOutput() }
        nativeFrameRate = 30; nominalFPS = nil; sourceIntervals = []
        geometryFailure = nil; fallback = nil; metrics.fallbackReason = nil
        // HLS does not consistently expose AVAssetTrack before playback starts.
        // Its decoded video buffers use display orientation; file/MP4 tracks still
        // wait for preferredTransform so rotated camera clips remain correct.
        geometryReady = (next?.asset as? AVURLAsset)?.url.pathExtension.lowercased() == "m3u8"
        displayTransform = .identity
        guard let next else { return }
        Task { @MainActor [weak self, weak next] in
            guard let next else { return }
            do {
                let tracks = try await next.asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    guard let self, self.item === next else { return }
                    // HLS manifests often expose no video track before playback, which is an
                    // absence of evidence rather than an HDR source. The per-frame colour gate
                    // still protects these frames, so the item is not forced to the native layer.
                    self.nativeRouteToken = UUID()
                    self.applyAssetAssessment(first: nil, isVideoTrack: true, token: self.nativeRouteToken)
                    if !self.geometryReady {
                        let reason = "媒体没有提供可读取的视频方向轨道，暂用原片播放"
                        self.geometryFailure = reason; self.setFallback(reason)
                    }
                    return
                }
                let fps = try await track.load(.nominalFrameRate)
                let transform = try await track.load(.preferredTransform)
                let formats = try await track.load(.formatDescriptions)
                guard let self, self.item === next else { return }
                if fps > 0 { self.nativeFrameRate = Double(fps); self.nominalFPS = Double(fps); self.metrics.sourceFPS = Double(fps) }
                self.displayTransform = transform; self.geometryReady = true
                self.applyAssetAssessment(first: formats.first, isVideoTrack: track.mediaType == .video, token: self.nativeRouteToken)
            } catch {
                guard let self, self.item === next else { return }
                if !self.geometryReady {
                    let reason = "无法读取画面方向信息，暂用原片播放"
                    self.geometryFailure = reason; self.setFallback(reason)
                }
            }
        }
        timeObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped, object: next, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.hdrSticky || self.fallback != nil { return }
            self.resetFrames()
        }
    }
    private func resetInterpolationQueue() {
        interpolationQueue = []; lastPrefetchedPTS = nil
        lookahead?.stop(); lookahead = nil; pendingSources = []; lookaheadDiscontinuity = nil
        interpolationFailure = nil; interpolationStartedAt = nil; interpolationClockOrigin = nil; interpolationHasMotionFrames = false
        presentationWindowStart = nil; presentationWindowFrames = 0
        displayedWindowStart = nil; displayedWindowFrames = 0; lastDisplayedPTS = nil
        interpolationWasActive = false
    }
    private func detachOutput() {
        if let item {
            // A previous view may have left this item's reusable SDR output attached.
            // HDR revocation must remove it even before the new view has claimed it.
            for candidate in item.outputs where candidate === output || candidate is CinemaItemVideoOutput {
                item.remove(candidate)
            }
        }
        output = nil
    }
    /// The item-level gate. Runs before any enhancement output exists, so a source that cannot be
    /// verified never receives the conversion path.
    private func applyAssetAssessment(first: CMFormatDescription?, isVideoTrack: Bool, token: UUID) {
        guard token == nativeRouteToken, !hdrSticky else { return }
        if case .nativeOnly = permission {
            route = "原生"; fallback = permission.nativeReason; detachOutput(); showNative(); return
        }
        switch ColorFrameGate.assetDecision(format: first, isVideoTrack: isVideoTrack) {
        case .sdr:
            route = "增强"
            fallback = nil
            attachOutputIfPossible()
            original.isHidden = currentFrame != nil; metalView?.isHidden = currentFrame == nil
        case .hdr(let reason), .unknown(let reason):
            route = "原生"
            fallback = reason
            hdrSticky = true
            detachOutput()
            showNative()
        }
        refreshRouteMetrics(); publish(force: true)
    }
    private func attachOutputIfPossible() {
        guard let next = item, permission == .inspectSDRFrames, route == "增强", !hdrSticky,
              pipelineProcessesFrames else { return }
        // Idempotent for this view's own output: a stale reference left in `next.outputs` must not
        // stack a second full-resolution frame copy, and re-connecting must not be skipped.
        if let output, next.outputs.contains(where: { $0 === output }) { return }
        if let existing = next.outputs.compactMap({ $0 as? CinemaItemVideoOutput }).first {
            output = existing; return
        }
        output = nil
        let result = CinemaItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: ColorFrameGate.outputPixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
            // Keep source color tags instead of asking AVFoundation for an SDR conversion before
            // the per-frame gate can recognize an unexpectedly HDR/wide-gamut frame.
            AVVideoAllowWideColorKey: true
        ])
        // Keep system video available until a completed enhanced frame can be displayed.
        result.suppressesPlayerRendering = false
        next.add(result); output = result
        lastPixelFormat = ColorFrameGate.outputPixelFormat
    }
    private func showNative() {
        lookahead?.stop(); lookahead = nil; pendingSources = []; lookaheadDiscontinuity = nil
        revision = UUID(); currentFrame = nil
        original.isHidden = false; metalView?.isHidden = true
    }
    private func refreshRouteMetrics() {
        let size = item?.presentationSize ?? .zero
        if size.nonzeroSize != nil {
            reportedSize = size
            metrics.sourceWidth = Int(size.width); metrics.sourceHeight = Int(size.height)
            metrics.outputWidth = metrics.sourceWidth; metrics.outputHeight = metrics.sourceHeight
        }
        metrics.mode = route == "原生" ? "原生（杜比/HDR 保真）" : EnhancementMode.original.title
        metrics.fallbackReason = fallback
        if cleanup.isActive {
            metrics.cleanupAppliedRegions = 0
            metrics.cleanupRejectedRegions = cleanup.regions.count
            metrics.cleanupReason = route == "原生" ? "杜比/HDR 或原生播放期间不叠加柔化，选区保留" : "已切回原片，不叠加柔化，选区保留"
        }
    }
    private func publishDiagnosticState() {
        var state = VideoSurfaceDiagnosticState()
        state.isNativeVisible = !original.isHidden
        state.hasEnhancedFrame = currentFrame != nil
        state.isHDRSticky = hdrSticky
        state.lastPixelFormat = lastPixelFormat
        state.route = route
        diagnosticState = state
    }
    func stop() {
        timer?.invalidate(); timer = nil; revision = UUID()
        lookahead?.stop(); lookahead = nil; pendingSources = []; lookaheadDiscontinuity = nil
        // Leaving the view must not rewind a still-playing item. Reuse its output when
        // the view returns; the item releases it when the source itself is replaced.
        output = nil
        if let timeObserver { NotificationCenter.default.removeObserver(timeObserver) }
        timeObserver = nil; original.player = nil; player = nil
        // Reject asset-loading callbacks from this retired view as well as GPU callbacks.
        // The item still owns its reusable SDR output, but a stopped view cannot reclaim it.
        item = nil; assessed = nil; nativeRouteToken = UUID()
    }
    deinit { timer?.invalidate(); if let timeObserver { NotificationCenter.default.removeObserver(timeObserver) } }

    /// True only when the selected mode wants the pipeline and the source is allowed to use it.
    private var pipelineProcessesFrames: Bool { mode != .original }
    private var adSofteningActive: Bool { cleanup.isActive }
    private var requiresProtectedRegionGeometry: Bool { adSofteningActive || mode == .compression }

    /// Both region-based operations use displayed-video coordinates, even when ad softening is off.
    /// Validate each decoder's actual buffer before mapping those regions into its transformed image.
    private func protectedRegionGeometryRejectionReason(for buffer: CVPixelBuffer, item: AVPlayerItem) -> String? {
        let bufferWidth = CVPixelBufferGetWidth(buffer), bufferHeight = CVPixelBufferGetHeight(buffer)
        let displayBounds = CGRect(x: 0, y: 0, width: bufferWidth, height: bufferHeight).applying(displayTransform)
        var pixelRatio = 1.0
        if let attachment = CVBufferCopyAttachment(buffer, kCVImageBufferPixelAspectRatioKey, nil) {
            if let values = attachment as? [String: Any],
               let horizontal = values[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] as? NSNumber,
               let vertical = values[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] as? NSNumber,
               vertical.doubleValue > 0 { pixelRatio = horizontal.doubleValue / vertical.doubleValue }
            else { pixelRatio = .nan }
        }
        guard let reason = AdCleanupPolicy.geometryRejectionReason(bufferWidth: bufferWidth, bufferHeight: bufferHeight, displayBounds: displayBounds, presentationSize: item.presentationSize, cleanAperture: CVImageBufferGetCleanRect(buffer), pixelAspectRatio: pixelRatio) else { return nil }
        return mode == .compression
            ? reason.replacingOccurrences(of: "局部柔化", with: "压缩抑噪").replacingOccurrences(of: "柔化", with: "压缩抑噪")
            : reason
    }

    private func tick() {
        guard let player else { return }
        if item !== player.currentItem || assessed !== nil && assessed !== player.currentItem && item !== assessed {
            reset(); attachItem(player.currentItem)
        }
        guard let item else { return }
        guard route == "增强", !hdrSticky, fallback == nil else {
            refreshRouteMetrics(); publish(); return
        }
        // Keep an existing SDR output attached for this item even in original comparison.
        // No enhancement is submitted; native rendering and playback position are preserved.
        guard pipelineProcessesFrames else {
            if let output, output.hasNewPixelBuffer(forItemTime: player.currentTime()) {
                _ = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil)
            }
            showNative(); refreshRouteMetrics(); publish(); return
        }
        guard let pipeline else { setFallback("当前设备没有可用 Metal GPU"); return }
        guard geometryReady else { refreshRouteMetrics(); publish(); return }
        if requiresProtectedRegionGeometry, item.presentationSize.nonzeroSize == nil {
            let reason = mode == .compression ? "等待显示尺寸确认，压缩抑噪暂未应用" : "等待显示尺寸确认，局部柔化暂未应用"
            let changed = metrics.fallbackReason != reason
            // Waiting is recoverable. Invalidate old work without latching a permanent fallback,
            // so neither a queued interpolation nor a late worker result can display a stale mask.
            if currentFrame != nil || interpolationWasActive || !forceFrame { resetFrames() }
            refreshRouteMetrics()
            metrics.mode = "原生（等待显示尺寸）"
            metrics.fallbackReason = reason
            metrics.timingNote = reason
            if adSofteningActive {
                metrics.cleanupAppliedRegions = 0
                metrics.cleanupReason = reason
            }
            publish(force: changed); return
        }
        if #unavailable(macOS 26.0), frameRate == .fps60 { interpolationFailure = "运动插帧需要 macOS 26，当前跟随片源帧率" }
        let wantsInterpolation = frameRate == .fps60 && !splitComparison && !cleanup.isActive && player.rate == 1 && (nominalFPS ?? nativeFrameRate) < 59
        if wantsInterpolation && interpolationFailure == nil, #available(macOS 26.0, *) {
            if output == nil { attachOutputIfPossible() }
            if let output, output.hasNewPixelBuffer(forItemTime: player.currentTime()) {
                _ = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil)
            }
            tickInterpolated(player: player, item: item, pipeline: pipeline)
            return
        }
        if interpolationWasActive {
            revision = UUID(); interpolationWasActive = false; interpolationQueue = []; lastPrefetchedPTS = nil
            lookahead?.stop(); lookahead = nil; pendingSources = []; lookaheadDiscontinuity = nil
            currentFrame = nil; original.isHidden = false; metalView?.isHidden = true
            presentationWindowStart = nil; presentationWindowFrames = 0
            displayedWindowStart = nil; displayedWindowFrames = 0; lastDisplayedPTS = nil
            metrics.displayedFPS = nil; metrics.presentedFPS = nil
            interpolationStartedAt = nil; interpolationClockOrigin = nil; interpolationHasMotionFrames = false; budget.reset()
            forceFrame = true; return
        }
        metrics.timingNote = interpolationFailure ?? (cleanup.isActive && frameRate == .fps60 ? "局部柔化已启用，为保护选区与字幕边界而跟随片源帧率" : (splitComparison ? "同帧对照 · 跟随片源帧率" : (frameRate == .fps60 && player.rate != 1 ? "暂停或变速时跟随原帧" : "跟随片源帧率")))
        guard let output else {
            attachOutputIfPossible(); refreshRouteMetrics(); publish(); return
        }
        let targetTime = forceFrame ? player.currentTime() : output.itemTime(forHostTime: CACurrentMediaTime())
        guard forceFrame || output.hasNewPixelBuffer(forItemTime: targetTime) else { return }
        if busy { metrics.droppedFrames += 1; return }
        var displayed = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: targetTime, itemTimeForDisplay: &displayed) else { refreshRouteMetrics(); publish(); return }
        switch ColorFrameGate.decision(for: buffer) {
        case .sdr:
            break
        case .hdr(let reason):
            hdrSticky = true; route = "原生"; fallback = reason
            detachOutput(); showNative(); refreshRouteMetrics(); publish(force: true)
            return
        case .unknown(let reason):
            // Missing tags on one early frame must not permanently classify the entire item as
            // HDR. Keep the system layer visible and wait for another *new* decoded frame.
            forceFrame = false
            let changed = metrics.fallbackReason != reason
            if currentFrame != nil { showNative() }
            else { original.isHidden = false; metalView?.isHidden = true }
            refreshRouteMetrics()
            metrics.mode = "原生（等待色彩确认）"
            metrics.fallbackReason = reason
            publish(force: changed)
            return
        }
        if requiresProtectedRegionGeometry, let reason = protectedRegionGeometryRejectionReason(for: buffer, item: item) {
            setFallback(reason); return
        }
        forceFrame = false; busy = true
        let token = revision, requestedMode = mode, transform = displayTransform, requestedCleanup = cleanup, requestedResolution = resolution
        let pts = displayed.isNumeric ? displayed : targetTime
        // After interpolation falls back, the decoder may still offer the source anchor
        // immediately before the last generated frame. Wait for the next anchor instead
        // of briefly displaying an older picture while the audio clock keeps advancing.
        if player.rate > 0, let renderedPTS = lastRenderedPTS, pts.seconds < renderedPTS - 0.000001 {
            busy = false
            return
        }
        if let previous = lastPTS {
            let delta = pts.seconds - previous
            if delta > 0.005 && delta < 0.2 {
                sourceIntervals.append(delta); if sourceIntervals.count > 30 { sourceIntervals.removeFirst() }
                if nominalFPS == nil, sourceIntervals.count >= 12 {
                    let median = sourceIntervals.sorted()[sourceIntervals.count / 2]
                    nativeFrameRate = 1 / median
                    metrics.sourceFPS = nativeFrameRate; metrics.sourceFPSIsEstimated = true
                }
            }
        }
        lastPTS = pts.seconds
        metrics.sourceWidth = CVPixelBufferGetWidth(buffer); metrics.sourceHeight = CVPixelBufferGetHeight(buffer)
        offerScanFrame(buffer, time: pts.seconds)
        worker.async { [weak self] in
            let result: Result<EnhancedFrame, Error> = autoreleasepool { Result { try pipeline.process(buffer, mode: requestedMode, time: pts, displayTransform: transform, cleanup: requestedCleanup, streamID: token, resolution: requestedResolution) } }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                guard token == self.revision, self.item === item, self.mode == requestedMode else { return }
                switch result {
                case .failure(let error): self.setFallback(error.localizedDescription)
                case .success(let frame):
                    self.metrics.processedFrames += 1; self.metrics.processingMS = frame.milliseconds
                    let fps = self.nativeFrameRate * max(1, Double(abs(player.rate)))
                    if self.budget.record(milliseconds: frame.milliseconds, framesPerSecond: fps) {
                        self.setFallback("处理连续超出 \(Int(fps)) fps 帧预算，流畅优先回退原片（\(Int(frame.milliseconds)) ms）")
                        return
                    }
                    // Drop a result that is already far behind the audio clock instead of accumulating latency.
                    if player.rate != 0 && player.currentTime().seconds - pts.seconds > max(0.08, 2 / fps) {
                        self.metrics.droppedFrames += 1; self.publish(); return
                    }
                    let firstDisplayedFrame = self.currentFrame == nil
                    self.currentFrame = frame
                    self.metrics.outputWidth = frame.width; self.metrics.outputHeight = frame.height
                    self.metrics.cleanupAppliedRegions = frame.cleanupAppliedRegions
                    self.metrics.cleanupRejectedRegions = frame.cleanupRejectedRegions
                    self.metrics.cleanupReason = frame.cleanupReason
                    self.metrics.mode = frame.mode; self.metrics.presentationTime = pts.seconds
                    self.metrics.fallbackReason = nil
                    self.metalView?.isHidden = false; self.original.isHidden = true
                    self.metalView?.draw()
                    // Reset publishes empty metrics immediately; a paused frame may be the only result.
                    self.publish(force: firstDisplayedFrame || player.rate == 0)
                }
            }
        }
    }
    /// Decode ahead monotonically, process complete pairs, then present against the *same*
    /// AVPlayer clock as audio. Neither generated frames nor audio are delayed to hide overruns.
    @available(macOS 26.0, *)
    private func tickInterpolated(player: AVPlayer, item: AVPlayerItem, pipeline: EnhancementPipeline) {
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        if interpolationClockOrigin == nil { interpolationClockOrigin = now }
        guard item.status == .readyToPlay, player.timeControlStatus == .playing,
              now > (interpolationClockOrigin ?? now) + 0.06 else {
            metrics.timingNote = "等待播放时钟稳定后启用运动插帧"
            publish(); return
        }
        interpolationWasActive = true
        if interpolationStartedAt == nil { interpolationStartedAt = CACurrentMediaTime() }
        if let index = interpolationQueue.lastIndex(where: { $0.time <= now + 0.002 }) {
            let next = interpolationQueue[index]
            interpolationQueue.removeFirst(index + 1)
            if now - next.time < 0.09 {
                currentFrame = next.frame
                metrics.outputWidth = next.frame.width; metrics.outputHeight = next.frame.height
                metrics.mode = next.frame.mode; metrics.presentationTime = next.time
                metrics.fallbackReason = nil
                metrics.cleanupAppliedRegions = next.frame.cleanupAppliedRegions
                metrics.cleanupRejectedRegions = next.frame.cleanupRejectedRegions
                metrics.cleanupReason = next.frame.cleanupReason
                original.isHidden = true; metalView?.isHidden = false; metalView?.draw()
            }
        }
        if currentFrame != nil, now - metrics.presentationTime > 0.12 {
            // Starvation can happen on HLS when the decoder has no future frames available.
            interpolationFailure = "未来帧未及时就绪，已保留修复并跟随片源帧率"
            currentFrame = nil; original.isHidden = false; metalView?.isHidden = true
            publish(force: true); return
        }
        metrics.timingNote = currentFrame == nil ? "正在预热运动插帧，暂用原片" : "运动插帧 · 目标 60 fps · 与原音频共用时钟"
        if let actual = metrics.displayedFPS, currentFrame != nil {
            metrics.timingNote! += String(format: " · 最近呈现 %.1f fps", actual)
        }
        publish()
        // A separate muted decoder owns lookahead, keeping its buffering and seek lifecycle
        // isolated from the audible player. The original shared-clock prototype was unstable.
        if lookahead == nil { lookahead = LookaheadVideoDecoder(item: item) }
        let nextDecoded = lookahead?.next(mainTime: now)
        if lookaheadDiscontinuity != lookahead?.discontinuityID {
            lookaheadDiscontinuity = lookahead?.discontinuityID
            revision = UUID(); pendingSources = []; interpolationQueue = []
            interpolationHasMotionFrames = false; currentFrame = nil
            original.isHidden = false; metalView?.isHidden = true
            lastPrefetchedPTS = nil; lastPTS = nil
        }
        if let next = nextDecoded {
            if lastPrefetchedPTS == nil || next.time.seconds > lastPrefetchedPTS! + 0.001 {
                lastPrefetchedPTS = next.time.seconds
                pendingSources.append(next)
            }
        }
        let earliestUsefulSource = now + (interpolationHasMotionFrames ? -0.04 : 0.10)
        pendingSources.removeAll { $0.time.seconds < earliestUsefulSource }
        if pendingSources.count > 12 { pendingSources.removeFirst(pendingSources.count - 12) }
        if let error = lookahead?.lastError {
            interpolationFailure = error + "；当前跟随片源帧率"; return
        }
        if currentFrame == nil, let start = interpolationStartedAt, CACurrentMediaTime() - start > 25 {
            interpolationFailure = "运动插帧未在25秒内就绪，保留修复并跟随片源帧率"; return
        }
        guard !busy, interpolationQueue.count < 24, !pendingSources.isEmpty else { return }
        let decoded = pendingSources.removeFirst(), buffer = decoded.buffer, displayed = decoded.time
        let pts = displayed.seconds
        switch ColorFrameGate.decision(for: buffer) {
        case .sdr: break
        case .hdr(let reason):
            hdrSticky = true; route = "原生"; fallback = reason
            detachOutput(); showNative(); refreshRouteMetrics(); publish(force: true); return
        case .unknown(let reason):
            interpolationFailure = reason; return
        }
        if requiresProtectedRegionGeometry, let reason = protectedRegionGeometryRejectionReason(for: buffer, item: item) {
            // The independent lookahead decoder can differ from the main player's output.
            // Stop interpolation first; the normal path validates its own source frame next.
            interpolationFailure = reason + "；当前跟随片源帧率"
            interpolationQueue = []; showNative(); refreshRouteMetrics()
            metrics.timingNote = interpolationFailure
            publish(force: true); return
        }
        if let previous = lastPTS {
            let delta = pts - previous
            if nominalFPS == nil, delta > 0.01 && delta < 0.1 {
                sourceIntervals.append(delta); if sourceIntervals.count > 24 { sourceIntervals.removeFirst() }
                if sourceIntervals.count >= 8 {
                    nativeFrameRate = 1 / sourceIntervals.sorted()[sourceIntervals.count / 2]
                    metrics.sourceFPS = nativeFrameRate; metrics.sourceFPSIsEstimated = true
                }
            }
        }
        lastPTS = pts
        metrics.sourceWidth = CVPixelBufferGetWidth(buffer); metrics.sourceHeight = CVPixelBufferGetHeight(buffer)
        offerScanFrame(buffer, time: pts)
        let token = revision, selectedMode = mode, selectedResolution = resolution, transform = displayTransform, selectedCleanup = cleanup
        busy = true
        worker.async { [weak self] in
            guard let self else { return }
            let result: Result<([(time: Double, frame: EnhancedFrame)], Double, Int, Bool), Error> = autoreleasepool {
                Result {
                    if self.interpolator == nil { self.interpolator = InterpolatedFramePipeline(pipeline: pipeline) }
                    let interpolator = self.interpolator as! InterpolatedFramePipeline
                    let frames = try interpolator.process(buffer: buffer, time: displayed, mode: selectedMode, resolution: selectedResolution, transform: transform, cleanup: selectedCleanup, streamID: token)
                    return (frames, interpolator.lastMilliseconds, interpolator.lastInterpolatedFrameCount, interpolator.lastWasPriming)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                guard token == self.revision, self.item === item, self.frameRate == .fps60 else { return }
                switch result {
                case .failure(let error):
                    self.interpolationFailure = error.localizedDescription + "；当前跟随片源帧率"
                    self.interpolationQueue = []; self.currentFrame = nil
                    self.original.isHidden = false; self.metalView?.isHidden = true
                case .success(let batch):
                    self.metrics.processedFrames += 1; self.metrics.processingMS = batch.1
                    self.metrics.interpolatedFrames += batch.2
                    if !batch.3 && self.budget.record(milliseconds: batch.1, framesPerSecond: self.nativeFrameRate) {
                        self.interpolationFailure = selectedMode == .clarity
                            ? "完整处理持续超预算，已保留修复并跟随片源帧率；可降低目标分辨率后重试"
                            : "完整处理持续超预算，当前跟随片源帧率；可尝试 1080p + 自然降噪"
                        self.interpolationQueue = []; self.currentFrame = nil
                        self.original.isHidden = false; self.metalView?.isHidden = true
                    } else {
                        let clock = player.currentTime().seconds
                        // A reference-only frame is not a ready interpolation stream. Keep
                        // native presentation through model/first-pair warmup; otherwise its
                        // cold latency falsely trips the steady-state starvation watchdog.
                        let freshFrames = batch.0.filter { $0.time >= clock - 0.04 && $0.time <= clock + 0.4 }
                        if freshFrames.contains(where: { $0.frame.isInterpolated }) { self.interpolationHasMotionFrames = true }
                        if self.interpolationHasMotionFrames {
                            self.interpolationQueue.append(contentsOf: freshFrames)
                        }
                        self.interpolationQueue.sort { $0.time < $1.time }
                    }
                }
                self.publish(force: true)
                // Consume an already decoded pair without waiting for another timer period.
                self.tick()
            }
        }
    }
    /// Hands one already decoded frame to local ad recognition. The frame is rendered to a small
    /// still on the shared scan queue, so the enhancement worker never waits for OCR and no second
    /// decoder is opened for the same timeline position.
    private func offerScanFrame(_ buffer: CVPixelBuffer, time: Double) {
        guard let onScanFrame, !scanConversionBusy, time.isFinite, time >= 0 else { return }
        // The scanner samples every two media seconds. Avoid thumbnail conversion for frames it
        // would reject, including at faster playback rates where a wall-clock timer skips grid points.
        guard abs((time / 2).rounded() * 2 - time) <= 0.3 else { return }
        let now = CACurrentMediaTime()
        guard now - lastScanHandoff >= scanInterval else { return }
        lastScanHandoff = now; scanConversionBusy = true
        let context = scanContext
        Self.scanQueue.async { [weak self] in
            let image: CGImage? = autoreleasepool {
                let source = CIImage(cvPixelBuffer: buffer)
                let width = source.extent.width, height = source.extent.height
                guard width > 0, height > 0 else { return nil }
                let scale = min(960 / width, 540 / height, 1)
                let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                return context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: floor(scaled.extent.width), height: floor(scaled.extent.height)))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanConversionBusy = false
                if let image { onScanFrame(image, time) }
            }
        }
    }
    private func setFallback(_ reason: String) {
        let reported = adSofteningActive ? reason + "；局部柔化已停用，广告区恢复原画面" : reason
        fallback = reported; currentFrame = nil
        metrics.cleanupAppliedRegions = 0
        metrics.cleanupRejectedRegions = adSofteningActive ? cleanup.regions.count : 0
        metrics.cleanupReason = adSofteningActive ? "柔化停用，广告区恢复原画面" : nil
        original.isHidden = false; metalView?.isHidden = true
        metrics.mode = route == "原生" ? "原生（杜比/HDR 保真）" : EnhancementMode.original.title
        metrics.fallbackReason = reported
        metrics.outputWidth = metrics.sourceWidth; metrics.outputHeight = metrics.sourceHeight
        publish(force: true)
    }
    private func publish(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastReport >= 0.5 else { return }
        lastReport = now
        publishDiagnosticState()
        metrics.isEnhancedOutput = currentFrame != nil && original.isHidden && metalView?.isHidden == false
        // Publishing is deferred so SwiftUI never receives state mutations inside updateNSView.
        let value = metrics, token = revision
        DispatchQueue.main.async { [weak self] in guard let self, token == self.revision else { return }; self.onMetrics(value) }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard !rendering, let frame = currentFrame, let pipeline, let displayQueue, let displayContext,
              let drawable = view.currentDrawable, let command = displayQueue.makeCommandBuffer() else { return }
        rendering = true
        let bounds = CGRect(origin: .zero, size: view.drawableSize)
        var image = CIImage(mtlTexture: frame.texture, options: [.colorSpace: pipeline.colorSpace])!
        if splitComparison, let raw = frame.originalImage {
            let full = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            let reference = raw.transformed(by: CGAffineTransform(scaleX: CGFloat(frame.width) / raw.extent.width, y: CGFloat(frame.height) / raw.extent.height))
            let left = reference.cropped(to: CGRect(x: 0, y: 0, width: full.width / 2, height: full.height))
            let divider = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.8)).cropped(to: CGRect(x: full.width / 2, y: 0, width: 2, height: full.height))
            image = divider.composited(over: left.composited(over: image))
        }
        let scale = min(bounds.width / CGFloat(frame.width), bounds.height / CGFloat(frame.height))
        let transformed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).transformed(by: CGAffineTransform(translationX: (bounds.width - CGFloat(frame.width) * scale) / 2, y: (bounds.height - CGFloat(frame.height) * scale) / 2))
        let background = CIImage(color: .black).cropped(to: bounds)
        // EnhancedFrame textures are immutable and completed before worker handoff;
        // this independent queue therefore reads them without a cross-queue fence.
        displayContext.render(transformed.composited(over: background), to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: pipeline.colorSpace)
        let token = revision, framePTS = metrics.presentationTime
        drawable.addPresentedHandler { [weak self] presented in
            let presentedTime = presented.presentedTime
            guard presentedTime.isFinite, presentedTime > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, token == self.revision, self.lastDisplayedPTS != framePTS else { return }
                self.lastDisplayedPTS = framePTS; self.metrics.displayedFrames += 1
                if self.displayedWindowStart == nil { self.displayedWindowStart = presentedTime }
                self.displayedWindowFrames += 1
                if let start = self.displayedWindowStart, presentedTime - start >= 1 {
                    self.metrics.displayedFPS = Double(self.displayedWindowFrames) / (presentedTime - start)
                    self.displayedWindowStart = presentedTime; self.displayedWindowFrames = 0
                }
            }
        }
        command.present(drawable)
        command.addCompletedHandler { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rendering = false
                guard result.status == .completed, token == self.revision else { return }
                if self.lastRenderedPTS != framePTS {
                    self.metrics.renderedFrames += 1; self.lastRenderedPTS = framePTS
                    let now = CACurrentMediaTime()
                    if self.presentationWindowStart == nil { self.presentationWindowStart = now }
                    self.presentationWindowFrames += 1
                    if let start = self.presentationWindowStart, now - start >= 1 {
                        self.metrics.presentedFPS = Double(self.presentationWindowFrames) / (now - start)
                        self.presentationWindowStart = now; self.presentationWindowFrames = 0
                    }
                }
            }
        }
        command.commit()
    }
}

private extension CGSize {
    var nonzeroSize: CGSize? { width.isFinite && height.isFinite && width > 0 && height > 0 ? self : nil }
}
