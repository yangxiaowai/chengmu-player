import Foundation
import AVFoundation
import CoreImage
import Vision
import CinemaCore

/// Owns an independent, muted decoder, used only when the playback pipeline cannot supply frames.
///
/// Playback frames are preferred (see `classify(image:time:protectedRegions:)`): they are already
/// decoded, so recognition costs no extra decode and no extra waiting. This fallback covers local
/// files and HTTP MP4, where a paused decoder can seek precisely. Ordinary HTTP HLS does not
/// reliably complete a sequence of precise seeks, so its look-ahead is limited to whichever
/// positions the decoder actually delivers and is reported as unavailable rather than guessed.
@MainActor
final class AdFrameAnalyzer {
    private(set) var lastFailure: String?
    private var asset: AVURLAsset?
    private var epoch = UUID()
    private var generator: AVAssetImageGenerator?
    private var decoder: AVPlayer?
    private var decoderItem: AVPlayerItem?
    private var output: AVPlayerItemVideoOutput?
    private var transform: CGAffineTransform?
    private var cancelOperation: (() -> Void)?
    private var activeOCR: AdOCRJob?
    private let context = CIContext(options: [.cacheIntermediates: false])
    // Shared serial queue also bounds work when a cancelled cold-start request finishes late.
    private static let imageQueue = DispatchQueue(label: "Cinema.ad-scan.vision", qos: .utility)
    private let tolerance = 0.2
    private var usesHLS: Bool { asset?.url.pathExtension.lowercased() == "m3u8" }

    func configure(url: URL?) {
        cancel()
        lastFailure = nil
        guard let url, url.isFileURL || ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            asset = nil; lastFailure = "该媒体类型暂不支持本地广告识别"; return
        }
        asset = AVURLAsset(url: url)
    }
    func cancel() {
        epoch = UUID()
        cancelOperation?(); cancelOperation = nil
        activeOCR?.cancel(); activeOCR = nil
        generator?.cancelAllCGImageGeneration(); generator = nil
        decoderItem?.cancelPendingSeeks(); decoder?.cancelPendingPrerolls(); decoder?.pause()
        if let output, let decoderItem { decoderItem.remove(output) }
        decoder?.replaceCurrentItem(with: nil)
        output = nil; decoder = nil; decoderItem = nil; transform = nil
        asset?.cancelLoading(); asset = nil
    }
    /// Classification for a frame that the playback pipeline already decoded.
    func classify(image: CGImage, time: Double, protectedRegions: [NormalizedVideoRect]) async -> AdFrameObservation? {
        let token = epoch
        guard time.isFinite, time >= 0, asset != nil else { return nil }
        let texts = await recognize(image, token: token)
        guard valid(token), let texts else { return nil }
        let protected = [AdCleanupSettings.defaultProtection] + protectedRegions
        return AdFrameObservation(time: time, classification: AdTextClassifier.classify(texts, protectedRegions: protected))
    }

    /// True when this analyzer owns a decoder that could be replaced by shared playback frames.
    var hasIndependentDecoder: Bool { decoder != nil || generator != nil }

    func analyze(time: Double, protectedRegions: [NormalizedVideoRect]) async -> AdFrameObservation {
        let token = epoch
        lastFailure = nil
        func unknown(_ reason: String) -> AdFrameObservation {
            if epoch == token { lastFailure = reason }
            return AdFrameObservation(time: time, classification: .unknown)
        }
        guard time.isFinite, time >= 0, let asset else { return unknown("等待可分析的媒体") }
        var frame: (CGImage, Double)?
        if !usesHLS { frame = await generatedFrame(at: time, token: token) }
        if frame == nil, valid(token) { frame = await streamingFrame(at: time, asset: asset, token: token) }
        guard valid(token), let frame else { return unknown("取帧暂不可用，稍后重试") }
        guard abs(frame.1 - time) <= tolerance else { return unknown("取帧时间不匹配，保留原片") }
        let texts = await recognize(frame.0, token: token)
        guard valid(token), let texts else { return unknown("文字识别暂不可用，保留原片") }
        // The baseline subtitle band is mandatory even when callers pass no custom protection.
        let protected = [AdCleanupSettings.defaultProtection] + protectedRegions
        return AdFrameObservation(time: frame.1, classification: AdTextClassifier.classify(texts, protectedRegions: protected))
    }
    private func valid(_ token: UUID) -> Bool { !Task.isCancelled && epoch == token && asset != nil }

    private func generatedFrame(at time: Double, token: UUID) async -> (CGImage, Double)? {
        guard let asset else { return nil }
        if generator == nil {
            let value = AVAssetImageGenerator(asset: asset)
            value.maximumSize = CGSize(width: 960, height: 540)
            value.appliesPreferredTrackTransform = true
            value.requestedTimeToleranceBefore = CMTime(seconds: tolerance, preferredTimescale: 600)
            value.requestedTimeToleranceAfter = value.requestedTimeToleranceBefore
            generator = value
        }
        guard let generator else { return nil }
        return await withCheckedContinuation { continuation in
            let waiter = AdScanWaiter<(CGImage, Double)>(continuation)
            cancelOperation = { waiter.finish(nil) }
            waiter.timeout = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                generator.cancelAllCGImageGeneration(); waiter.finish(nil)
            }
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: time, preferredTimescale: 600))]) { [weak self] _, image, actual, result, _ in
                Task { @MainActor in
                    guard let self, self.valid(token), result == .succeeded, let image, actual.isNumeric,
                          abs(actual.seconds - time) <= self.tolerance else { waiter.finish(nil); return }
                    waiter.finish((image, actual.seconds))
                }
            }
        }
    }
    /// Keeps one muted decoder advancing through the look-ahead window. HLS will not complete a
    /// sequence of precise paused seeks, so the frame nearest each requested time is taken while the
    /// decoder plays instead of seeking twice per sample.
    private func streamingFrame(at time: Double, asset: AVAsset, token: UUID) async -> (CGImage, Double)? {
        if decoder == nil {
            let item = AVPlayerItem(asset: asset)
            item.preferredMaximumResolution = CGSize(width: 960, height: 540)
            item.preferredForwardBufferDuration = 6
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()])
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true; player.volume = 0; player.automaticallyWaitsToMinimizeStalling = true
            self.decoder = player; decoderItem = item; self.output = output
            transform = usesHLS ? .identity : nil
        }
        guard let player = decoder, let item = decoderItem, let output else { return nil }
        let readyDeadline = Date().addingTimeInterval(8)
        while item.status != .readyToPlay {
            guard valid(token), item.status != .failed, Date() < readyDeadline else { return nil }
            do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return nil }
        }
        let current = player.currentTime().seconds
        let farBehind = time - current > 1.5
        let rewound = current > time + tolerance
        if player.rate == 0 || farBehind || rewound {
            let target = rewound ? time : max(0, time - 0.75)
            guard await seek(player: player, item: item, to: target) == true, valid(token) else { return nil }
        }
        player.playImmediately(atRate: 1)
        let deadline = Date().addingTimeInterval(farBehind || rewound ? 6 : 3)
        var closest: (CVPixelBuffer, Double)?
        while valid(token), Date() < deadline {
            var displayed = CMTime.invalid
            let now = player.currentTime()
            if let pixel = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: &displayed), displayed.isNumeric {
                let delta = abs(displayed.seconds - time)
                if delta <= tolerance {
                    player.pause()
                    return await finish(pixel, at: displayed.seconds, asset: asset, token: token)
                }
                if displayed.seconds > time, closest == nil { closest = (pixel, displayed.seconds) }
                if displayed.seconds > time + tolerance, closest == nil { break }
            }
            do { try await Task.sleep(nanoseconds: 15_000_000) } catch { return nil }
        }
        player.pause()
        // A slightly late frame is still the requested moment; the caller re-checks the tolerance.
        if let closest { return await finish(closest.0, at: closest.1, asset: asset, token: token) }
        return nil
    }

    private func finish(_ buffer: CVPixelBuffer, at time: Double, asset: AVAsset, token: UUID) async -> (CGImage, Double)? {
        if transform == nil { transform = await loadTransform(asset, token: token) }
        guard valid(token), let transform else { return nil }
        let image = await thumbnail(buffer, transform: transform, token: token)
        guard valid(token), let image else { return nil }
        return (image, time)
    }

    private func decodedFrame(at time: Double, asset: AVAsset, token: UUID) async -> (CGImage, Double)? {
        if decoder == nil {
            let item = AVPlayerItem(asset: asset)
            item.preferredMaximumResolution = CGSize(width: 960, height: 540)
            item.preferredForwardBufferDuration = 1
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()])
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true; player.volume = 0; player.automaticallyWaitsToMinimizeStalling = false
            self.decoder = player; decoderItem = item; self.output = output
            transform = usesHLS ? .identity : nil
        }
        guard let player = decoder, let item = decoderItem, let output else { return nil }
        let deadline = Date().addingTimeInterval(6)
        while item.status != .readyToPlay {
            guard valid(token), item.status != .failed, Date() < deadline else { return nil }
            do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return nil }
        }
        // A paused HLS item stops fetching, so a precise seek sometimes never calls back. The first
        // attempt stays paused for speed; a second attempt plays the decoder so the seek can deliver
        // data. The main player is never touched either way.
        var sought: Bool? = await seek(player: player, item: item, to: time)
        if sought != true, valid(token) {
            player.playImmediately(atRate: 1)
            sought = await seek(player: player, item: item, to: time)
        }
        guard sought == true, valid(token) else { return nil }
        player.playImmediately(atRate: 1)
        defer { player.pause() }
        let frameDeadline = Date().addingTimeInterval(2.5)
        while valid(token), Date() < frameDeadline {
            var displayed = CMTime.invalid
            let current = player.currentTime()
            if let pixel = output.copyPixelBuffer(forItemTime: current, itemTimeForDisplay: &displayed), displayed.isNumeric,
               abs(displayed.seconds - time) <= tolerance {
                player.pause()
                if transform == nil {
                    transform = await loadTransform(asset, token: token)
                }
                guard valid(token), let transform else { return nil }
                let image = await thumbnail(pixel, transform: transform, token: token)
                guard valid(token), let image else { return nil }
                return (image, displayed.seconds)
            }
            if current.isNumeric, current.seconds > time + tolerance { return nil }
            do { try await Task.sleep(nanoseconds: 25_000_000) } catch { return nil }
        }
        return nil
    }
    private func seek(player: AVPlayer, item: AVPlayerItem, to time: Double) async -> Bool? {
        await withCheckedContinuation { continuation in
            let waiter = AdScanWaiter<Bool>(continuation)
            cancelOperation = { waiter.finish(nil) }
            waiter.timeout = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                item.cancelPendingSeeks(); waiter.finish(nil)
            }
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { success in
                Task { @MainActor in waiter.finish(success) }
            }
        }
    }
    private func loadTransform(_ asset: AVAsset, token: UUID) async -> CGAffineTransform? {
        await withCheckedContinuation { continuation in
            let waiter = AdScanWaiter<CGAffineTransform>(continuation)
            let task = Task { @MainActor [weak self] in
                guard let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first,
                      let transform = try? await track.load(.preferredTransform), let self, self.valid(token) else { waiter.finish(nil); return }
                waiter.finish(transform)
            }
            cancelOperation = { task.cancel(); waiter.finish(nil) }
            waiter.timeout = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                task.cancel(); waiter.finish(nil)
            }
        }
    }
    private func thumbnail(_ buffer: CVPixelBuffer, transform: CGAffineTransform, token: UUID) async -> CGImage? {
        let context = context, source = CIImage(cvPixelBuffer: buffer)
        return await withCheckedContinuation { continuation in
            let waiter = AdScanWaiter<CGImage>(continuation)
            cancelOperation = { waiter.finish(nil) }
            waiter.timeout = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
                waiter.finish(nil)
            }
            Self.imageQueue.async { [weak self] in
                let image: CGImage? = autoreleasepool {
                    var image = source.transformed(by: transform)
                    guard image.extent.width > 0, image.extent.height > 0 else { return nil }
                    image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                    let scale = min(960 / image.extent.width, 540 / image.extent.height, 1)
                    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    return context.createCGImage(image, from: CGRect(x: 0, y: 0, width: floor(image.extent.width), height: floor(image.extent.height)))
                }
                Task { @MainActor [weak self] in waiter.finish(self?.valid(token) == true ? image : nil) }
            }
        }
    }
    private func recognize(_ image: CGImage, token: UUID) async -> [AdRecognizedText]? {
        let job = AdOCRJob(); activeOCR = job
        return await withCheckedContinuation { continuation in
            let waiter = AdScanWaiter<[AdRecognizedText]>(continuation)
            cancelOperation = { job.cancel(); waiter.finish(nil) }
            waiter.timeout = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
                job.cancel(); waiter.finish(nil)
            }
            Self.imageQueue.async { [weak self] in
                let results = job.perform(image)
                Task { @MainActor [weak self] in
                    guard let self, self.valid(token) else { waiter.finish(nil); return }
                    if self.activeOCR === job { self.activeOCR = nil }
                    waiter.finish(results)
                }
            }
        }
    }
}

/// Cancellation may arrive from MainActor while Vision is busy on its worker queue.
private final class AdOCRJob: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRecognizeTextRequest?
    func cancel() {
        lock.lock(); cancelled = true; let value = request; lock.unlock()
        value?.cancel()
    }
    func perform(_ image: CGImage) -> [AdRecognizedText]? {
        autoreleasepool {
            let value = VNRecognizeTextRequest()
            value.revision = VNRecognizeTextRequestRevision3
            value.recognitionLevel = .accurate
            value.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            value.usesLanguageCorrection = false
            value.minimumTextHeight = 0.025
            value.preferBackgroundProcessing = true
            lock.lock()
            guard !cancelled else { lock.unlock(); return nil }
            request = value; lock.unlock()
            defer { lock.lock(); request = nil; lock.unlock() }
            do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([value]) } catch { return nil }
            lock.lock(); let shouldDiscard = cancelled; lock.unlock()
            guard !shouldDiscard else { return nil }
            return (value.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return AdRecognizedText(text: text.string, confidence: Double(text.confidence), rect: NormalizedVideoRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
            }
        }
    }
}

@MainActor
private final class AdScanWaiter<Value> {
    private var continuation: CheckedContinuation<Value?, Never>?
    var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }
    func finish(_ value: Value?) {
        guard let continuation else { return }
        self.continuation = nil; timeout?.cancel(); timeout = nil
        continuation.resume(returning: value)
    }
}
