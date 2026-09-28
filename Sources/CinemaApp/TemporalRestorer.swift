import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import VideoToolbox
import QuartzCore

struct TemporalRestorationResult {
    let image: CIImage
    /// False for the first frame and every discontinuity: those frames are returned unchanged.
    let usedHistory: Bool
    let resetReason: String?
    /// Wall time through completed processing, including conversion; not a GPU-only duration.
    let milliseconds: Double
}

/// Causal SDR restoration. Call only from one serial processing worker, never the UI thread.
/// Inputs must already have display orientation and pass the caller's HDR/DRM policy.
/// Reference buffers hold source frames, not previous restored output; no future frames are used.
@available(macOS 26.0, *)
final class TemporalRestorer {
    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { if case .unavailable(let reason) = self { return reason }; return nil }
    }

    private let width: Int
    private let height: Int
    private let context: CIContext
    private let strength: Float
    private let processor = VTFrameProcessor()
    private let transfer: VTPixelTransferSession
    private let sourcePool: CVPixelBufferPool
    private let destinationPool: CVPixelBufferPool
    private let rgbBuffer: CVPixelBuffer
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var previous: VTFrameProcessorFrame?
    private var previousPreview: [SIMD3<Float>]?
    private var previousTime: CMTime?
    private var previousStreamID: UUID?
    private var pendingDiscontinuity = true

    init(width: Int, height: Int, context: CIContext, strength: Float = 0.75) throws {
        guard width > 0, height > 0, strength.isFinite, (0...1).contains(strength) else {
            throw Failure.unavailable("时域降噪尺寸或强度无效")
        }
        let format = kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarFullRange
        guard VTTemporalNoiseFilterConfiguration.isSupported,
              VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats.contains(format),
              let configuration = VTTemporalNoiseFilterConfiguration(frameWidth: width, frameHeight: height, sourcePixelFormat: format),
              (configuration.previousFrameCount ?? 0) >= 1 else {
            throw Failure.unavailable("当前设备或 \(width)×\(height) 输入不支持无损 10-bit 时域降噪")
        }
        self.width = width; self.height = height; self.context = context; self.strength = strength
        sourcePool = try Self.makePool(configuration.sourcePixelBufferAttributes, width: width, height: height, format: format)
        destinationPool = try Self.makePool(configuration.destinationPixelBufferAttributes, width: width, height: height, format: format)
        let rgbPool = try Self.makePool([kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true], width: width, height: height, format: kCVPixelFormatType_64RGBAHalf)
        rgbBuffer = try Self.allocate(rgbPool)
        var candidate: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &candidate)
        guard status == noErr, let candidate else { throw Failure.unavailable("时域降噪色彩转换器创建失败（\(status)）") }
        transfer = candidate
        do { try processor.startSession(configuration: configuration) }
        catch { VTPixelTransferSessionInvalidate(candidate); throw error }
    }

    deinit { processor.endSession(); VTPixelTransferSessionInvalidate(transfer) }

    func process(_ image: CIImage, time: CMTime, streamID: UUID?) throws -> TemporalRestorationResult {
        let start = CACurrentMediaTime()
        guard image.extent.width.isFinite, image.extent.height.isFinite,
              abs(image.extent.width - CGFloat(width)) < 0.01,
              abs(image.extent.height - CGFloat(height)) < 0.01,
              image.extent.minX == 0, image.extent.minY == 0 else {
            throw Failure.unavailable("时域降噪输入尺寸或方向已变化，需要重新创建会话")
        }
        let preview = scenePreview(image)
        var reason: String?
        if previous == nil { reason = "正在建立前帧参考" }
        else if previousStreamID != streamID { reason = "片源或播放位置变化，重建前帧参考" }
        else if !time.isNumeric || previousTime?.isNumeric != true { reason = "时间戳不可用，重建前帧参考" }
        else if let previousTime {
            let interval = CMTimeSubtract(time, previousTime).seconds
            if interval <= 0 || interval > 0.15 { reason = "帧序列不连续，重建前帧参考" }
        }
        if reason == nil, let previousPreview {
            let differences = zip(preview, previousPreview).map { pair -> Float in
                let delta = pair.0 - pair.1
                return max(abs(delta.x), abs(delta.y), abs(delta.z))
            }
            let mean = differences.reduce(0, +) / Float(max(1, differences.count))
            let changed = Float(differences.filter { $0 > 0.16 }.count) / Float(max(1, differences.count))
            // Conservative scene/motion guard. Native motion estimation handles local motion;
            // broadly different pictures should not share a temporal reference.
            if mean > 0.20 { reason = "检测到切镜，重建前帧参考" }
            else if changed >= 0.45 && mean > 0.08 { reason = "画面大范围变化，保留当前帧" }
        }
        if reason != nil { clearHistory() }

        let source = try Self.allocate(sourcePool)
        tagSDR(rgbBuffer)
        context.render(image, to: rgbBuffer, bounds: image.extent, colorSpace: colorSpace)
        let status = VTPixelTransferSessionTransferImage(transfer, from: rgbBuffer, to: source)
        guard status == noErr else { clearHistory(); throw Failure.unavailable("时域降噪 10-bit 输入转换失败（\(status)）") }
        tagSDR(source)
        guard let frame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: time.isNumeric ? time : .zero) else {
            clearHistory(); throw Failure.unavailable("时域降噪输入帧无法建立")
        }
        guard let previous else {
            remember(frame, preview: preview, time: time, streamID: streamID)
            return TemporalRestorationResult(image: image, usedHistory: false, resetReason: reason ?? "正在建立前帧参考", milliseconds: (CACurrentMediaTime() - start) * 1000)
        }
        let destination = try Self.allocate(destinationPool)
        tagSDR(destination)
        guard let output = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: time),
              let parameters = VTTemporalNoiseFilterParameters(sourceFrame: frame, nextFrames: [], previousFrames: [previous], destinationFrame: output, filterStrength: strength, hasDiscontinuity: pendingDiscontinuity) else {
            clearHistory(); throw Failure.unavailable("时域降噪参考帧参数无效")
        }
        let completion = Completion()
        processor.process(parameters: parameters) { _, error in
            completion.error = error
            completion.signal.signal()
        }
        // Buffer ownership remains here until VideoToolbox signals actual completion. This is
        // intentionally confined to the serial worker; a Metal submission alone is not completion.
        completion.signal.wait()
        if let error = completion.error { clearHistory(); throw error }
        pendingDiscontinuity = false
        remember(frame, preview: preview, time: time, streamID: streamID)
        return TemporalRestorationResult(image: CIImage(cvPixelBuffer: destination), usedHistory: true, resetReason: nil, milliseconds: (CACurrentMediaTime() - start) * 1000)
    }

    private final class Completion: @unchecked Sendable {
        let signal = DispatchSemaphore(value: 0)
        // A single completion writer and a reader ordered after semaphore.wait().
        var error: Error?
    }
    private func clearHistory() {
        previous = nil; previousPreview = nil; previousTime = nil; pendingDiscontinuity = true
    }
    private func remember(_ frame: VTFrameProcessorFrame, preview: [SIMD3<Float>], time: CMTime, streamID: UUID?) {
        previous = frame; previousPreview = preview; previousTime = time; previousStreamID = streamID
    }
    private func tagSDR(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
    private func scenePreview(_ image: CIImage) -> [SIMD3<Float>] {
        let w = 64, h = 36
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let reduced = image.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / CGFloat(width), y: CGFloat(h) / CGFloat(height)))
        context.render(reduced, toBitmap: &rgba, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: colorSpace)
        return stride(from: 0, to: rgba.count, by: 4).map { SIMD3<Float>(Float(rgba[$0]), Float(rgba[$0 + 1]), Float(rgba[$0 + 2])) / 255 }
    }
    private static func makePool(_ attributes: [String: Any], width: Int, height: Int, format: OSType) throws -> CVPixelBufferPool {
        var values = attributes
        values[kCVPixelBufferWidthKey as String] = width; values[kCVPixelBufferHeightKey as String] = height
        values[kCVPixelBufferPixelFormatTypeKey as String] = format
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, values as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw Failure.unavailable("时域降噪缓冲池分配失败（\(status)）") }
        return pool
    }
    private static func allocate(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel)
        guard status == kCVReturnSuccess, let pixel else { throw Failure.unavailable("时域降噪帧分配失败（\(status)）") }
        return pixel
    }
}
