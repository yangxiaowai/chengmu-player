import Foundation
import AVFoundation
import CoreImage
import MetalKit
import VideoToolbox
import CinemaCore

enum EnhancementMode: String, CaseIterable, Identifiable {
    case original, temporal, restoration, clarity, upscale4K, appleAI
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "原片"
        case .temporal: return "时域降噪"
        case .restoration: return "流式修复"
        case .clarity: return "自然降噪"
        case .upscale4K: return "平滑 4K 缩放"
        case .appleAI: return "Apple AI 超分"
        }
    }
    var detail: String {
        switch self {
        case .original: return "系统硬件解码与原始画面"
        case .temporal: return "利用前帧减轻噪点，保留原始尺寸；需要 macOS 26"
        case .restoration: return "先时域降噪，支持时使用 Apple AI；再以细节保护插值放大至最高 4K"
        case .clarity: return "轻度降噪，不叠加锐化，保持原始尺寸"
        case .upscale4K: return "降噪后平滑放大至最高 4K，不增加原片没有的细节"
        case .appleAI: return "按设备与输入尺寸查询真实 AI 倍率，不支持时回退"
        }
    }
}

struct EnhancementMetrics {
    /// The surface has selected an enhanced frame for display; preference alone is not evidence.
    var isEnhancedOutput = false
    var sourceWidth = 0
    var sourceHeight = 0
    var outputWidth = 0
    var outputHeight = 0
    var mode = EnhancementMode.original.title
    var processingMS: Double = 0
    var processedFrames = 0
    var fallbackReason: String?
    var droppedFrames = 0
    var renderedFrames = 0
    var presentationTime: Double = 0
    var cleanupAppliedRegions = 0
    var cleanupRejectedRegions = 0
    var cleanupReason: String?
}

struct EnhancedFrame {
    let texture: MTLTexture
    let width: Int
    let height: Int
    let milliseconds: Double
    let mode: String
    var usedTemporalHistory = false
    var temporalResetReason: String?
    var cleanupAppliedRegions = 0
    var cleanupRejectedRegions = 0
    var cleanupReason: String?
}

enum EnhancementError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { switch self { case .unavailable(let reason): return reason } }
}

/// Worker-owned GPU context. The surface calls this serially, with at most one in-flight video frame.
final class EnhancementPipeline {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var aiSession: AnyObject?
    private var aiKey = ""
    private var temporalSession: AnyObject?
    private var temporalKey = ""
    private var detailScaler: DetailScaler?
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw EnhancementError.unavailable("当前设备没有可用 Metal GPU")
        }
        self.device = device; self.queue = queue
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    }

    func process(_ buffer: CVPixelBuffer, mode: EnhancementMode, time: CMTime, displayTransform: CGAffineTransform = .identity, cleanup: AdCleanupSettings = .init(), streamID: UUID? = nil) throws -> EnhancedFrame {
        let start = CACurrentMediaTime()
        if let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String,
           transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
            throw EnhancementError.unavailable("HDR 增强尚未验证，使用系统原片保留色彩")
        }
        var image = CIImage(cvPixelBuffer: buffer)
        if !displayTransform.isIdentity {
            image = image.transformed(by: displayTransform)
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        let width = Int(image.extent.width.rounded()), height = Int(image.extent.height.rounded())
        var output = PixelSize(width: width, height: height)
        var label = mode.title
        var usedTemporalHistory = false
        var temporalResetReason: String?
        let usesTemporal = mode == .temporal || mode == .restoration
        if usesTemporal {
            guard #available(macOS 26.0, *) else { throw EnhancementError.unavailable("时域修复需要 macOS 26 或更新版本，已保留原片") }
            let key = "\(mode.rawValue):\(width)x\(height)"
            if temporalKey != key {
                temporalSession = nil; temporalKey = ""
                temporalSession = try TemporalRestorer(width: width, height: height, context: context)
                temporalKey = key
            }
            let restored = try (temporalSession as! TemporalRestorer).process(image, time: time, streamID: streamID)
            image = restored.image
            usedTemporalHistory = restored.usedHistory; temporalResetReason = restored.resetReason
            label = restored.usedHistory ? "时域降噪" : "原帧（时域参考建立中）"
        } else {
            // Re-entering a temporal mode must not reuse references from before an original comparison.
            temporalSession = nil; temporalKey = ""
        }
        var useScaler = mode == .appleAI
        if mode == .restoration, #available(macOS 26.0, *) {
            useScaler = VTLowLatencySuperResolutionScalerConfiguration.isSupported &&
                !VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height).isEmpty
            if !useScaler { label += " · 当前尺寸无 AI 超分倍率" }
        }
        if useScaler {
            guard #available(macOS 26.0, *) else { throw EnhancementError.unavailable("Apple AI 超分需要 macOS 26 或更新版本") }
            let key = "\(width)x\(height)"
            if aiKey != key {
                aiSession = nil; aiKey = ""
                aiSession = try AppleScaler(width: width, height: height, context: context)
                aiKey = key
            }
            let session = aiSession as! AppleScaler
            image = try session.process(image, time: time, queue: queue)
            output = PixelSize(width: Int(image.extent.width), height: Int(image.extent.height))
            label = usedTemporalHistory ? "时域降噪 + Apple AI ×\(session.factor)" : "Apple AI ×\(session.factor)"
            if usesTemporal && !usedTemporalHistory { label += "（时域参考建立中）" }
        } else if mode == .clarity || mode == .upscale4K {
            // Core Image's denoiser also sharpens by default. Keep it disabled: adding another
            // luminance sharpen amplified residual compression noise, especially in midtones.
            image = image.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.015, "inputSharpness": 0.0])
            if mode == .upscale4K {
                output = QualityPolicy.target4K(width: width, height: height)
                // Cubic B-spline (B=1, C=0) has no negative lobes: it does not add the bright/dark
                // halos that Lanczos produced around subtitle strokes and compressed edges.
                // Even scale=1 changes pixels with this kernel; preserve native 4K/larger detail.
                if output.width != width || output.height != height {
                    image = image.clampedToExtent().applyingFilter("CIBicubicScaleTransform", parameters: [
                        "inputScale": Double(output.width) / Double(width), "inputAspectRatio": 1.0,
                        "inputB": 1.0, "inputC": 0.0
                    ]).cropped(to: CGRect(x: 0, y: 0, width: output.width, height: output.height))
                }
            }
        }
        let detailTarget = QualityPolicy.target4K(width: output.width, height: output.height)
        let usesDetailScaling = mode == .restoration && detailTarget != output
        if usesDetailScaling {
            output = detailTarget
            if !useScaler { label = usedTemporalHistory ? "时域降噪" : "原帧（时域参考建立中）" }
            label += " + 细节缩放（非 AI）"
        }
        // Finish the enhanced base before cleanup. Applying patches with bounded copies
        // preserves exact pixels outside the selection, regardless of the scaling path.
        let decision = AdCleanupPolicy.evaluate(cleanup, width: output.width, height: output.height)
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: output.width, height: output.height, mipmapped: false)
        description.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let command = queue.makeCommandBuffer() else { throw EnhancementError.unavailable("GPU 画面提交失败") }
        let texture: MTLTexture
        if usesDetailScaling {
            if detailScaler == nil { detailScaler = try DetailScaler(device: device) }
            texture = try detailScaler!.encode(image, width: output.width, height: output.height, context: context, command: command)
        } else {
            guard let rendered = device.makeTexture(descriptor: description) else { throw EnhancementError.unavailable("GPU 画面缓冲分配失败") }
            texture = rendered
            context.render(image, to: texture, commandBuffer: command, bounds: CGRect(x: 0, y: 0, width: output.width, height: output.height), colorSpace: colorSpace)
        }
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw EnhancementError.unavailable(command.error?.localizedDescription ?? "GPU 帧处理失败") }
        var resultTexture = texture
        if !decision.acceptedRects.isEmpty {
            guard let cleanedTexture = device.makeTexture(descriptor: description),
                  let cleanupCommand = queue.makeCommandBuffer(),
                  let baseImage = CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace]),
                  let baseCopy = cleanupCommand.makeBlitCommandEncoder() else {
                throw EnhancementError.unavailable("局部柔化缓冲分配失败")
            }
            baseCopy.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: output.width, height: output.height, depth: 1),
                          to: cleanedTexture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            baseCopy.endEncoding()
            // Core Image retains the rendered texture's image coordinates; the rectangle origin
            // also addresses its backing texels. Keep the base immutable for overlapping selections.
            let enhanced = baseImage
            for rectangle in decision.acceptedRects {
                let patchWidth = Int(rectangle.width), patchHeight = Int(rectangle.height)
                let patchDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: patchWidth, height: patchHeight, mipmapped: false)
                patchDescription.usage = [.shaderRead, .shaderWrite, .renderTarget]
                guard let patchTexture = device.makeTexture(descriptor: patchDescription) else {
                    throw EnhancementError.unavailable("局部柔化选区缓冲分配失败")
                }
                let patch = enhanced.cropped(to: rectangle).clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(4.0, min(24.0, Double(min(rectangle.width, rectangle.height)) * 0.12))])
                    .cropped(to: rectangle)
                    .transformed(by: CGAffineTransform(translationX: -rectangle.minX, y: -rectangle.minY))
                context.render(patch, to: patchTexture, commandBuffer: cleanupCommand,
                               bounds: CGRect(x: 0, y: 0, width: patchWidth, height: patchHeight), colorSpace: colorSpace)
                guard let patchCopy = cleanupCommand.makeBlitCommandEncoder() else {
                    throw EnhancementError.unavailable("局部柔化选区提交失败")
                }
                patchCopy.copy(from: patchTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                               sourceSize: MTLSize(width: patchWidth, height: patchHeight, depth: 1),
                               to: cleanedTexture, destinationSlice: 0, destinationLevel: 0,
                               destinationOrigin: MTLOrigin(x: Int(rectangle.minX), y: Int(rectangle.minY), z: 0))
                patchCopy.endEncoding()
            }
            cleanupCommand.commit(); cleanupCommand.waitUntilCompleted()
            guard cleanupCommand.status == .completed else { throw EnhancementError.unavailable(cleanupCommand.error?.localizedDescription ?? "局部柔化处理失败") }
            resultTexture = cleanedTexture
            label += " + 局部柔化（\(decision.acceptedRects.count)框）"
        }
        return EnhancedFrame(texture: resultTexture, width: output.width, height: output.height, milliseconds: (CACurrentMediaTime() - start) * 1000, mode: label, usedTemporalHistory: usedTemporalHistory, temporalResetReason: temporalResetReason, cleanupAppliedRegions: decision.acceptedRects.count, cleanupRejectedRegions: decision.rejectedCount, cleanupReason: decision.reasons.isEmpty ? nil : decision.reasons.joined(separator: "；"))
    }

    /// Generated moving test card: real GPU command completion, not CPU submission time.
    static func runBenchmark(frameCount: Int = 60) throws -> [String: Any] {
        let pipeline = try EnhancementPipeline()
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { throw EnhancementError.unavailable("测试帧创建失败") }
        var reports: [[String: Any]] = []
        for mode in [EnhancementMode.temporal, .restoration, .clarity, .upscale4K, .appleAI] {
            var times: [Double] = []; var size = [0, 0]; var actualMode = mode.title; var failure: String?
            var sampleRange = [0, 0]
            for index in 0..<max(1, frameCount) {
                autoreleasepool {
                    let base = CIImage(color: CIColor(red: 0.08, green: 0.16, blue: 0.24)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
                    let stripe = CIImage(color: CIColor(red: 0.9, green: 0.5, blue: 0.15)).cropped(to: CGRect(x: (index * 13) % 1150, y: 180, width: 120, height: 360))
                    let checker = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 12.0])!.outputImage!.cropped(to: CGRect(x: 40, y: 40, width: 300, height: 160))
                    pipeline.context.render(stripe.composited(over: checker.composited(over: base)), to: buffer, bounds: base.extent, colorSpace: pipeline.colorSpace)
                    do {
                        let result = try pipeline.process(buffer, mode: mode, time: CMTime(value: Int64(index), timescale: 30))
                        times.append(result.milliseconds); size = [result.width, result.height]; actualMode = result.mode
                        if index == max(1, frameCount) - 1, let rendered = CIImage(mtlTexture: result.texture, options: [.colorSpace: pipeline.colorSpace]) {
                            var sample = [UInt8](repeating: 0, count: 64 * 64 * 4)
                            let thumbnail = rendered.transformed(by: CGAffineTransform(scaleX: 64 / CGFloat(result.width), y: 64 / CGFloat(result.height)))
                            pipeline.context.render(thumbnail, toBitmap: &sample, rowBytes: 64 * 4, bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBA8, colorSpace: pipeline.colorSpace)
                            let rgb = sample.enumerated().filter { $0.offset % 4 != 3 }.map { $0.element }
                            sampleRange = [Int(rgb.min() ?? 0), Int(rgb.max() ?? 0)]
                        }
                    } catch { failure = error.localizedDescription }
                }
                if failure != nil { break }
            }
            let sorted = times.sorted()
            var report: [String: Any] = ["requested_mode": mode.rawValue, "actual_mode": actualMode, "input": [1280, 720], "output": size, "completed_frames": times.count, "mean_ms": times.isEmpty ? 0 : times.reduce(0,+) / Double(times.count), "p95_ms": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]]
            report["first_frame_ms"] = times.first ?? 0
            let warm = Array(times.dropFirst())
            report["warm_mean_ms"] = warm.isEmpty ? 0 : warm.reduce(0, +) / Double(warm.count)
            report["last_frame_rgb_range"] = sampleRange
            if let failure { report["failure"] = failure }
            reports.append(report)
        }
        let rotated = try pipeline.process(buffer, mode: .clarity, time: .zero, displayTransform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 720, ty: 0))
        guard rotated.width == 720, rotated.height == 1280 else { throw EnhancementError.unavailable("旋转画面尺寸回归失败") }
        return ["scope": "Generated SDR 720p frames; completed GPU processing only. Not playback, sync, or 30-minute validation.", "device": pipeline.device.name, "results": reports, "rotation_check": ["input": [1280, 720], "output": [rotated.width, rotated.height], "passed": true]]
    }
}

@available(macOS 26.0, *)
private final class AppleScaler {
    let factor: Float
    private let processor = VTFrameProcessor()
    private let source: CVPixelBuffer
    private let destination: CVPixelBuffer
    private let context: CIContext
    init(width: Int, height: Int, context: CIContext) throws {
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported,
              let factor = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height).max() else {
            throw EnhancementError.unavailable("Apple AI 不支持当前 \(width)×\(height) 输入；没有可用倍率，回退原片")
        }
        self.factor = factor; self.context = context
        let config = VTLowLatencySuperResolutionScalerConfiguration(frameWidth: width, frameHeight: height, scaleFactor: factor)
        func allocate(_ attrs: [String: Any], width: Int, height: Int) throws -> CVPixelBuffer {
            var values = attrs
            values[kCVPixelBufferWidthKey as String] = width; values[kCVPixelBufferHeightKey as String] = height
            values[kCVPixelBufferIOSurfacePropertiesKey as String] = [:]
            values[kCVPixelBufferMetalCompatibilityKey as String] = true
            var pool: CVPixelBufferPool?; var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreate(nil, nil, values as CFDictionary, &pool) == kCVReturnSuccess, let pool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw EnhancementError.unavailable("Apple AI 帧缓冲分配失败") }
            return pixel
        }
        source = try allocate(config.sourcePixelBufferAttributes, width: width, height: height)
        destination = try allocate(config.destinationPixelBufferAttributes, width: Int(Float(width) * factor), height: Int(Float(height) * factor))
        try processor.startSession(configuration: config)
    }
    deinit { processor.endSession() }
    func process(_ image: CIImage, time: CMTime, queue: MTLCommandQueue) throws -> CIImage {
        context.render(image, to: source, bounds: image.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        guard let input = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: time), let output = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: time), let command = queue.makeCommandBuffer() else { throw EnhancementError.unavailable("Apple AI IOSurface 帧创建失败") }
        let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: input, destinationFrame: output)
        processor.process(with: command, parameters: parameters)
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw EnhancementError.unavailable(command.error?.localizedDescription ?? "Apple AI 帧处理失败") }
        return CIImage(cvPixelBuffer: destination)
    }
}
