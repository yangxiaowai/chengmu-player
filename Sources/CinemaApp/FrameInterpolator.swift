import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import VideoToolbox
import QuartzCore

/// Motion-compensated SDR interpolation between two decoded source frames.
/// Worker-owned: initialize, process and reset on the same serial worker. Session loading
/// can take seconds. The caller owns lookahead, audio synchronization and presentation.
@available(macOS 26.0, *)
final class FrameInterpolator {
    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let reason): return reason }
        }
    }

    private let width: Int
    private let height: Int
    private let context: CIContext
    private let processor = VTFrameProcessor()
    private let sourcePool: CVPixelBufferPool
    private let destinationPool: CVPixelBufferPool
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var precedingCurrentTime: CMTime?
    // The frame retains its pixel buffer. Reusing a completed next input as the following
    // source avoids rendering the same full-resolution SDR image twice.
    private var cachedCurrentInput: (image: CIImage, frame: VTFrameProcessorFrame)?
    private var discontinuity = true
    private(set) var lastMilliseconds: Double = 0

    init(width: Int, height: Int, context: CIContext) throws {
        guard width > 0, height > 0, width <= 8192, height <= 4320,
              VTFrameRateConversionConfiguration.isSupported,
              let configuration = VTFrameRateConversionConfiguration(
                frameWidth: width, frameHeight: height, usePrecomputedFlow: false,
                qualityPrioritization: .normal, revision: .revision1),
              configuration.supportedPixelFormats.contains(kCVPixelFormatType_64RGBAHalf) else {
            throw Failure.unavailable("当前设备或画面尺寸不支持运动补偿插帧")
        }
        self.width = width; self.height = height; self.context = context
        sourcePool = try Self.makePool(configuration.sourcePixelBufferAttributes, width: width, height: height)
        destinationPool = try Self.makePool(configuration.destinationPixelBufferAttributes, width: width, height: height)
        try processor.startSession(configuration: configuration)
    }

    deinit { processor.endSession() }

    /// Clears sequence reuse on the next submission. It does not cancel an in-flight call;
    /// the caller must discard results for an obsolete playback revision after completion.
    func reset() {
        precedingCurrentTime = nil
        cachedCurrentInput = nil
        discontinuity = true
        lastMilliseconds = 0
    }

    /// Returns independent images in the requested phase order. Each image retains its own
    /// destination pixel buffer. Inputs must already be oriented and pass the caller's SDR policy.
    /// For phase p, presentation time is previousTime + p * (currentTime - previousTime).
    func interpolate(previous: CIImage, previousTime: CMTime,
                     current: CIImage, currentTime: CMTime, phases: [Float]) throws -> [CIImage] {
        let start = CACurrentMediaTime()
        guard matches(previous), matches(current), previousTime.isNumeric, currentTime.isNumeric,
              CMTimeCompare(currentTime, previousTime) > 0,
              CMTimeSubtract(currentTime, previousTime).seconds <= 0.25,
              !phases.isEmpty, phases.count <= 8,
              phases.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }),
              zip(phases, phases.dropFirst()).allSatisfy({ $0 < $1 }) else {
            reset()
            throw Failure.unavailable("插帧输入尺寸、时间间隔或中间帧位置无效")
        }
        do {
            let continuous = !discontinuity && precedingCurrentTime.map { CMTimeCompare($0, previousTime) == 0 } == true
            let source: VTFrameProcessorFrame
            if continuous, let cachedCurrentInput, cachedCurrentInput.image === previous {
                source = cachedCurrentInput.frame
            } else {
                source = try render(previous, time: previousTime)
            }
            let next = try render(current, time: currentTime)
            let duration = CMTimeSubtract(currentTime, previousTime)
            let buffers = try phases.map { _ in try Self.allocate(destinationPool) }
            let outputs = try zip(buffers, phases).map { buffer, phase -> VTFrameProcessorFrame in
                tagSDR(buffer)
                let time = CMTimeAdd(previousTime, CMTimeMultiplyByFloat64(duration, multiplier: Double(phase)))
                guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: time) else {
                    throw Failure.unavailable("插帧输出帧创建失败")
                }
                return frame
            }
            guard let parameters = VTFrameRateConversionParameters(
                sourceFrame: source, nextFrame: next, opticalFlow: nil, interpolationPhase: phases,
                submissionMode: continuous ? .sequential : .random, destinationFrames: outputs) else {
                throw Failure.unavailable("运动补偿插帧参数创建失败")
            }
            let completion = Completion()
            processor.process(parameters: parameters) { _, error in
                completion.error = error
                completion.signal.signal()
            }
            completion.signal.wait()
            if let error = completion.error { throw error }
            precedingCurrentTime = currentTime
            cachedCurrentInput = (current, next)
            discontinuity = false
            lastMilliseconds = (CACurrentMediaTime() - start) * 1000
            return buffers.map { CIImage(cvPixelBuffer: $0) }
        } catch {
            reset()
            throw error
        }
    }

    private func matches(_ image: CIImage) -> Bool {
        image.extent.minX == 0 && image.extent.minY == 0 &&
        image.extent.width == CGFloat(width) && image.extent.height == CGFloat(height)
    }
    private func render(_ image: CIImage, time: CMTime) throws -> VTFrameProcessorFrame {
        let buffer = try Self.allocate(sourcePool)
        tagSDR(buffer)
        context.render(image, to: buffer, bounds: image.extent, colorSpace: colorSpace)
        guard let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: time) else {
            throw Failure.unavailable("插帧源帧创建失败")
        }
        return frame
    }
    private func tagSDR(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
    }
    private static func makePool(_ attributes: [String: Any], width: Int, height: Int) throws -> CVPixelBufferPool {
        var values = attributes
        values[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_64RGBAHalf
        values[kCVPixelBufferWidthKey as String] = width
        values[kCVPixelBufferHeightKey as String] = height
        values[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
        values[kCVPixelBufferMetalCompatibilityKey as String] = true
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, values as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw Failure.unavailable("插帧缓冲池分配失败（\(status)）")
        }
        return pool
    }
    private static func allocate(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw Failure.unavailable("插帧图像缓冲分配失败（\(status)）")
        }
        return buffer
    }
    private final class Completion: @unchecked Sendable {
        let signal = DispatchSemaphore(value: 0)
        var error: Error?
    }
}
