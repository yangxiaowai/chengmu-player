import Foundation
import AppKit
import AVFoundation
import CoreImage
import Combine

@MainActor
final class SeekPreviewController: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var requestedTime = 0.0
    @Published private(set) var actualTime: Double?
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?

    private struct Request { let id: UUID; let time: Double; let changedAt: Date }
    private struct Frame { let image: CGImage; let time: Double }
    private struct Cached { let frame: Frame; var used: UInt64 }
    private var asset: AVAsset?
    private var itemID = UUID()
    private var requestID = UUID()
    private var pending: Request?
    private var worker: Task<Void, Never>?
    private var workerID = UUID()
    private var cancelOperation: (() -> Void)?
    private var generator: AVAssetImageGenerator?
    private var decoder: AVPlayer?
    private var decoderItem: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var decoderTransform: CGAffineTransform?
    private var cache: [Int: Cached] = [:]
    private var accessCount: UInt64 = 0
    private let renderQueue = DispatchQueue(label: "Cinema.seek-preview.thumbnail", qos: .userInitiated)
    private let renderContext = CIContext(options: [.cacheIntermediates: false])
    private let tolerance = 0.45
    private let debounce = 0.15
    private var usesHLS: Bool {
        (asset as? AVURLAsset)?.url.pathExtension.lowercased() == "m3u8"
    }
    var cachedFrameCount: Int { cache.count }

    func configure(asset: AVAsset?, itemID: UUID) {
        guard self.itemID != itemID || self.asset !== asset else { return }
        stop()
        self.asset = asset; self.itemID = itemID
    }
    func request(time: Double, duration: Double) {
        guard asset != nil, time.isFinite, duration.isFinite, duration > 0 else { hide(); message = "预览暂不可用"; return }
        let target = min(max(0, time), max(0, duration - 0.05))
        requestedTime = target; image = nil; actualTime = nil; message = nil
        requestID = UUID(); pending = nil
        cancelOperation?(); cancelOperation = nil
        generator?.cancelAllCGImageGeneration()
        decoderItem?.cancelPendingSeeks(); decoder?.pause(); decoder?.cancelPendingPrerolls()
        let key = Int((target * 2).rounded())
        if var cached = cache[key], abs(cached.frame.time - target) <= tolerance {
            accessCount &+= 1; cached.used = accessCount; cache[key] = cached
            apply(cached.frame); isLoading = false; return
        }
        isLoading = true
        pending = Request(id: requestID, time: target, changedAt: Date())
        guard worker == nil else { return }
        let runID = UUID(); workerID = runID
        worker = Task { [weak self] in await self?.run(runID: runID) }
    }
    func hide() {
        requestID = UUID(); pending = nil
        worker?.cancel(); worker = nil; workerID = UUID()
        cancelOperation?(); cancelOperation = nil
        releaseBackend()
        image = nil; actualTime = nil; isLoading = false; message = nil
    }
    func stop() { hide(); asset = nil; cache.removeAll(keepingCapacity: false); accessCount = 0 }

    private func run(runID: UUID) async {
        while !Task.isCancelled, workerID == runID, let next = pending {
            let delay = max(0, debounce - Date().timeIntervalSince(next.changedAt))
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { break }
            }
            guard requestID == next.id else { continue }
            pending = nil
            let token = itemID
            var frame: Frame?
            if !usesHLS { frame = await generatedFrame(next, item: token) }
            if frame == nil, valid(next.id, item: token) { frame = await decodedFrame(next, item: token) }
            guard valid(next.id, item: token) else { continue }
            isLoading = false
            if let frame, frame.time.isFinite, abs(frame.time - next.time) <= tolerance {
                accessCount &+= 1; cache[Int((next.time * 2).rounded())] = Cached(frame: frame, used: accessCount)
                if cache.count > 48, let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key { cache.removeValue(forKey: oldest) }
                apply(frame)
            } else {
                image = nil; actualTime = nil; message = "此位置预览暂不可用"
                // A timeout must not keep a buffering decoder or a late image-generation request alive.
                releaseBackend()
            }
        }
        if workerID == runID { worker = nil }
    }
    private func valid(_ request: UUID, item: UUID) -> Bool { !Task.isCancelled && requestID == request && itemID == item && asset != nil }
    private func apply(_ frame: Frame) {
        image = NSImage(cgImage: frame.image, size: NSSize(width: frame.image.width, height: frame.image.height))
        actualTime = frame.time; message = nil
    }
    private func releaseBackend() {
        generator?.cancelAllCGImageGeneration(); generator = nil
        decoderItem?.cancelPendingSeeks(); decoder?.cancelPendingPrerolls(); decoder?.pause()
        if let videoOutput, let decoderItem { decoderItem.remove(videoOutput) }
        decoder?.replaceCurrentItem(with: nil)
        videoOutput = nil; decoderItem = nil; decoder = nil; decoderTransform = nil
    }
    private func generatedFrame(_ request: Request, item token: UUID) async -> Frame? {
        guard let asset else { return nil }
        if generator == nil {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 320, height: 180)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds: tolerance, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
            self.generator = generator
        }
        guard let generator else { return nil }
        return await withCheckedContinuation { continuation in
            let waiter = PreviewWaiter<Frame>(continuation)
            cancelOperation = { waiter.finish(nil) }
            waiter.timeout = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                generator.cancelAllCGImageGeneration(); waiter.finish(nil)
            }
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: request.time, preferredTimescale: 600))]) { [weak self] _, image, actual, result, _ in
                Task { @MainActor in
                    guard let self, self.valid(request.id, item: token), result == .succeeded, let image, actual.isNumeric,
                          abs(actual.seconds - request.time) <= self.tolerance else { waiter.finish(nil); return }
                    waiter.finish(Frame(image: image, time: actual.seconds))
                }
            }
        }
    }
    private func decodedFrame(_ request: Request, item token: UUID) async -> Frame? {
        guard let asset else { return nil }
        if decoder == nil {
            let item = AVPlayerItem(asset: asset)
            item.preferredMaximumResolution = CGSize(width: 320, height: 180)
            item.preferredForwardBufferDuration = 1
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()])
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true; player.volume = 0; player.automaticallyWaitsToMinimizeStalling = false
            decoder = player; decoderItem = item; videoOutput = output
            decoderTransform = usesHLS ? .identity : nil
        }
        guard let player = decoder, let decoderItem, let output = videoOutput else { return nil }
        let readinessDeadline = Date().addingTimeInterval(4)
        while decoderItem.status != .readyToPlay {
            guard valid(request.id, item: token), decoderItem.status != .failed, Date() < readinessDeadline else { return nil }
            do { try await Task.sleep(nanoseconds: 30_000_000) } catch { return nil }
        }
        player.pause()
        let sought: Bool? = await withCheckedContinuation { continuation in
            let waiter = PreviewWaiter<Bool>(continuation)
            cancelOperation = { waiter.finish(nil) }
            waiter.timeout = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                decoderItem.cancelPendingSeeks(); waiter.finish(nil)
            }
            player.seek(to: CMTime(seconds: request.time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { success in
                Task { @MainActor in waiter.finish(success) }
            }
        }
        guard sought == true, valid(request.id, item: token) else { return nil }
        // Some HLS decoders only supply output after starting a muted decode clock.
        player.playImmediately(atRate: 1)
        defer { player.pause() }
        let frameDeadline = Date().addingTimeInterval(2)
        while valid(request.id, item: token), Date() < frameDeadline {
            var displayTime = CMTime.invalid
            let current = player.currentTime()
            if let pixel = output.copyPixelBuffer(forItemTime: current, itemTimeForDisplay: &displayTime), displayTime.isNumeric,
               abs(displayTime.seconds - request.time) <= tolerance {
                player.pause()
                if decoderTransform == nil {
                    let loaded = await loadDisplayTransform(asset, request: request, item: token)
                    guard valid(request.id, item: token), decoder === player else { return nil }
                    decoderTransform = loaded
                }
                guard let transform = decoderTransform else { return nil }
                guard valid(request.id, item: token) else { return nil }
                let rendered = await thumbnail(pixel, transform: transform)
                guard valid(request.id, item: token), let rendered else { return nil }
                return Frame(image: rendered, time: displayTime.seconds)
            }
            if current.isNumeric, current.seconds > request.time + tolerance { return nil }
            do { try await Task.sleep(nanoseconds: 25_000_000) } catch { return nil }
        }
        return nil
    }
    private func loadDisplayTransform(_ asset: AVAsset, request: Request, item token: UUID) async -> CGAffineTransform? {
        // Loading on our own URL asset makes explicit cancellation safe for the main player's shared asset.
        let ownedAsset = (asset as? AVURLAsset).map { AVURLAsset(url: $0.url) }
        let loadingAsset = ownedAsset ?? asset
        return await withCheckedContinuation { continuation in
            let waiter = PreviewWaiter<CGAffineTransform>(continuation)
            let loader = Task { @MainActor [weak self] in
                guard let tracks = try? await loadingAsset.loadTracks(withMediaType: .video), let track = tracks.first,
                      let transform = try? await track.load(.preferredTransform), !Task.isCancelled,
                      let self, self.valid(request.id, item: token) else { waiter.finish(nil); return }
                waiter.finish(transform)
            }
            let cancel = { loader.cancel(); ownedAsset?.cancelLoading(); waiter.finish(nil) }
            cancelOperation = cancel
            waiter.timeout = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                cancel()
            }
        }
    }
    private func thumbnail(_ buffer: CVPixelBuffer, transform: CGAffineTransform) async -> CGImage? {
        let context = renderContext
        let source = CIImage(cvPixelBuffer: buffer) // Immutable image retains the decoder-owned buffer across rendering.
        return await withCheckedContinuation { continuation in
            renderQueue.async {
                autoreleasepool {
                    var image = source.transformed(by: transform)
                    image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                    guard image.extent.width > 0, image.extent.height > 0 else { continuation.resume(returning: nil); return }
                    let factor = min(320 / image.extent.width, 180 / image.extent.height, 1)
                    image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                    let bounds = CGRect(x: 0, y: 0, width: floor(image.extent.width), height: floor(image.extent.height))
                    continuation.resume(returning: context.createCGImage(image, from: bounds))
                }
            }
        }
    }
}

/// Main-actor continuation gate: cancellation, deadline and the API callback can race, but resume once.
@MainActor
private final class PreviewWaiter<Value> {
    private var continuation: CheckedContinuation<Value?, Never>?
    var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }
    func finish(_ result: Value?) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        continuation.resume(returning: result)
    }
}
