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
    let onMetrics: (EnhancementMetrics) -> Void
    func makeNSView(context: Context) -> CinemaVideoView { CinemaVideoView() }
    func updateNSView(_ view: CinemaVideoView, context: Context) {
        view.configure(player: player, mode: mode, generation: generation, onMetrics: onMetrics)
    }
    static func dismantleNSView(_ view: CinemaVideoView, coordinator: ()) { view.stop() }
}

final class CinemaVideoView: NSView, MTKViewDelegate {
    private let original = AVPlayerLayer()
    private var metalView: MTKView?
    private var pipeline: EnhancementPipeline?
    private var player: AVPlayer?
    private weak var item: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var timer: Timer?
    private let worker = DispatchQueue(label: "Cinema.enhancement", qos: .userInitiated)
    private var mode = EnhancementMode.original
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        original.videoGravity = .resizeAspect
        layer?.addSublayer(original)
        do {
            let pipeline = try EnhancementPipeline(); self.pipeline = pipeline
            let view = MTKView(frame: bounds, device: pipeline.device)
            view.framebufferOnly = false; view.colorPixelFormat = .bgra8Unorm
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
    func configure(player: AVPlayer, mode: EnhancementMode, generation: UUID, onMetrics: @escaping (EnhancementMetrics) -> Void) {
        self.onMetrics = onMetrics
        let playerChanged = self.player !== player
        let changed = playerChanged || self.mode != mode || self.generation != generation || self.item !== player.currentItem
        self.player = player; original.player = player
        self.mode = mode; self.generation = generation
        if changed { reset() }
        if item !== player.currentItem { attachItem(player.currentItem) }
    }
    private func reset() {
        revision = UUID(); currentFrame = nil; forceFrame = true
        fallback = geometryReady ? nil : geometryFailure
        budget.reset(); metrics = EnhancementMetrics(); lastPTS = nil; lastRenderedPTS = nil
        original.isHidden = false; metalView?.isHidden = true
        if let fallback { setFallback(fallback) } else { publish(force: true) }
    }
    private func attachItem(_ next: AVPlayerItem?) {
        if let output, let item { item.remove(output) }
        if let timeObserver { NotificationCenter.default.removeObserver(timeObserver) }
        item = next
        nativeFrameRate = 30
        geometryFailure = nil; fallback = nil; metrics.fallbackReason = nil
        // HLS does not consistently expose AVAssetTrack before playback starts.
        // Its decoded video buffers use display orientation; file/MP4 tracks still
        // wait for preferredTransform so rotated camera clips remain correct.
        geometryReady = (next?.asset as? AVURLAsset)?.url.pathExtension.lowercased() == "m3u8"
        displayTransform = .identity
        guard let next else { output = nil; return }
        let result = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()])
        // Keep system video available until a completed enhanced frame can be displayed.
        result.suppressesPlayerRendering = false
        next.add(result); output = result
        Task { @MainActor [weak self, weak next] in
            guard let next else { return }
            do {
                let tracks = try await next.asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    guard let self, self.item === next else { return }
                    if !self.geometryReady {
                        let reason = "媒体没有提供可读取的视频方向轨道，暂用原片播放"
                        self.geometryFailure = reason; self.setFallback(reason)
                    }
                    return
                }
                let fps = try await track.load(.nominalFrameRate)
                let transform = try await track.load(.preferredTransform)
                guard let self, self.item === next else { return }
                if fps > 0 { self.nativeFrameRate = Double(fps) }
                self.displayTransform = transform; self.geometryReady = true
            } catch {
                guard let self, self.item === next else { return }
                if !self.geometryReady {
                    let reason = "无法读取画面方向信息，暂用原片播放"
                    self.geometryFailure = reason; self.setFallback(reason)
                }
            }
        }
        timeObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemTimeJumped, object: next, queue: .main) { [weak self] _ in self?.reset() }
    }
    func stop() {
        timer?.invalidate(); timer = nil; revision = UUID()
        if let output, let item { item.remove(output) }
        if let timeObserver { NotificationCenter.default.removeObserver(timeObserver) }
        timeObserver = nil; output = nil; original.player = nil; player = nil
    }
    deinit { timer?.invalidate(); if let timeObserver { NotificationCenter.default.removeObserver(timeObserver) } }

    private func tick() {
        guard let player else { return }
        if item !== player.currentItem { reset(); attachItem(player.currentItem) }
        guard let output, let item else { return }
        if mode == .original || fallback != nil {
            if let size = item.presentationSize.nonzeroSize {
                metrics.sourceWidth = Int(size.width); metrics.sourceHeight = Int(size.height)
                metrics.outputWidth = metrics.sourceWidth; metrics.outputHeight = metrics.sourceHeight
            }
            metrics.mode = EnhancementMode.original.title; metrics.fallbackReason = fallback
            publish(); return
        }
        guard let pipeline else { setFallback("当前设备没有可用 Metal GPU"); return }
        guard geometryReady else { return }
        let targetTime = forceFrame ? player.currentTime() : output.itemTime(forHostTime: CACurrentMediaTime())
        guard forceFrame || output.hasNewPixelBuffer(forItemTime: targetTime) else { return }
        if busy { metrics.droppedFrames += 1; return }
        var displayed = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: targetTime, itemTimeForDisplay: &displayed) else { return }
        forceFrame = false; busy = true
        let token = revision, requestedMode = mode, transform = displayTransform
        let pts = displayed.isNumeric ? displayed : targetTime
        if let previous = lastPTS {
            let delta = pts.seconds - previous
            if delta > 0.005 && delta < 0.2 { nativeFrameRate = max(nativeFrameRate, 1 / delta) }
        }
        lastPTS = pts.seconds
        metrics.sourceWidth = CVPixelBufferGetWidth(buffer); metrics.sourceHeight = CVPixelBufferGetHeight(buffer)
        worker.async { [weak self] in
            let result: Result<EnhancedFrame, Error> = autoreleasepool { Result { try pipeline.process(buffer, mode: requestedMode, time: pts, displayTransform: transform) } }
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
                    self.currentFrame = frame
                    self.metrics.outputWidth = frame.width; self.metrics.outputHeight = frame.height
                    self.metrics.mode = frame.mode; self.metrics.presentationTime = pts.seconds
                    self.metrics.fallbackReason = nil
                    self.metalView?.isHidden = false; self.original.isHidden = true
                    self.metalView?.draw(); self.publish()
                }
            }
        }
    }
    private func setFallback(_ reason: String) {
        fallback = reason; currentFrame = nil
        original.isHidden = false; metalView?.isHidden = true
        metrics.mode = EnhancementMode.original.title; metrics.fallbackReason = reason
        metrics.outputWidth = metrics.sourceWidth; metrics.outputHeight = metrics.sourceHeight
        publish(force: true)
    }
    private func publish(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - lastReport >= 0.5 else { return }
        lastReport = now
        // Publishing is deferred so SwiftUI never receives state mutations inside updateNSView.
        let value = metrics, token = revision
        DispatchQueue.main.async { [weak self] in guard let self, token == self.revision else { return }; self.onMetrics(value) }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard !rendering, let frame = currentFrame, let pipeline, let drawable = view.currentDrawable, let command = pipeline.queue.makeCommandBuffer() else { return }
        rendering = true
        let bounds = CGRect(origin: .zero, size: view.drawableSize)
        let image = CIImage(mtlTexture: frame.texture, options: [.colorSpace: pipeline.colorSpace])!
        let scale = min(bounds.width / CGFloat(frame.width), bounds.height / CGFloat(frame.height))
        let transformed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).transformed(by: CGAffineTransform(translationX: (bounds.width - CGFloat(frame.width) * scale) / 2, y: (bounds.height - CGFloat(frame.height) * scale) / 2))
        let background = CIImage(color: .black).cropped(to: bounds)
        pipeline.context.render(transformed.composited(over: background), to: drawable.texture, commandBuffer: command, bounds: bounds, colorSpace: pipeline.colorSpace)
        let token = revision, framePTS = metrics.presentationTime
        command.present(drawable)
        command.addCompletedHandler { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rendering = false
                guard result.status == .completed, token == self.revision else { return }
                if self.lastRenderedPTS != framePTS { self.metrics.renderedFrames += 1; self.lastRenderedPTS = framePTS }
            }
        }
        command.commit()
    }
}

private extension CGSize {
    var nonzeroSize: CGSize? { width > 0 && height > 0 ? self : nil }
}
