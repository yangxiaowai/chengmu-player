import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import CinemaCore

/// A serial-worker helper. Decoding ahead, media-clock scheduling and audio synchronization
/// remain the surface's responsibility. Subsequent output timestamps lie on the global 60 Hz grid.
@available(macOS 26.0, *)
final class InterpolatedFramePipelineMeasured {
    private struct Request: Equatable {
        let mode: EnhancementMode
        let resolution: EnhancementResolution
        let transform: CGAffineTransform
        let cleanup: AdCleanupSettings
        let streamID: UUID
    }
    private struct Reference {
        let image: CIImage
        let time: CMTime
        let preview: [SIMD3<Float>]
    }

    private let pipeline: EnhancementPipeline
    private(set) var interpolator: FrameInterpolatorMeasured?
    private var interpolationSize: CGSize?
    private var request: Request?
    private var reference: Reference?
    private var enhancementRevision = UUID()
    private var hasCompletedInterpolation = false
    private(set) var lastMilliseconds: Double = 0
    private(set) var lastSetupMilliseconds: Double = 0
    private(set) var lastInterpolatedFrameCount = 0
    private(set) var lastWasPriming = true
    private(set) var lastResetReason: String?

    init(pipeline: EnhancementPipeline) { self.pipeline = pipeline }

    /// Does not interrupt in-flight GPU work. Call serially and discard obsolete revision results.
    func reset() {
        request = nil
        clearReferences()
        lastMilliseconds = 0
        lastSetupMilliseconds = 0
        lastInterpolatedFrameCount = 0
        lastWasPriming = true
        lastResetReason = "播放状态改变，重建插帧参考"
    }

    func process(buffer: CVPixelBuffer, time: CMTime, mode: EnhancementMode,
                 resolution: EnhancementResolution, transform: CGAffineTransform,
                 cleanup: AdCleanupSettings, streamID: UUID) throws -> [(time: Double, frame: EnhancedFrame)] {
        try EnhancementPipeline.withExclusiveProcessing {
            try processExclusively(buffer: buffer, time: time, mode: mode, resolution: resolution, transform: transform, cleanup: cleanup, streamID: streamID)
        }
    }
    private func processExclusively(buffer: CVPixelBuffer, time: CMTime, mode: EnhancementMode, resolution: EnhancementResolution, transform: CGAffineTransform, cleanup: AdCleanupSettings, streamID: UUID) throws -> [(time: Double, frame: EnhancedFrame)] {
        let start = CACurrentMediaTime()
        lastSetupMilliseconds = 0
        lastInterpolatedFrameCount = 0
        lastWasPriming = false
        lastResetReason = nil
        defer { lastMilliseconds = max(0, (CACurrentMediaTime() - start) * 1000 - lastSetupMilliseconds) }
        guard time.isNumeric, time.seconds >= 0 else {
            reset()
            throw EnhancementError.unavailable("插帧需要有效的视频时间戳")
        }
        let nextRequest = Request(mode: mode, resolution: resolution, transform: transform, cleanup: cleanup, streamID: streamID)
        if request != nextRequest {
            clearReferences()
            request = nextRequest
            lastResetReason = "片源或画面设置改变，重建插帧参考"
        }
        if let reference {
            let interval = CMTimeSubtract(time, reference.time).seconds
            if interval <= 0 || interval > 0.15 {
                clearReferences()
                lastResetReason = "视频时间不连续，重建插帧参考"
            }
        }
        do {
            var current = try pipeline.process(buffer, mode: mode, time: time, displayTransform: transform,
                                               cleanup: cleanup, streamID: enhancementRevision, resolution: resolution)
            guard current.width > 0, current.height > 0, max(current.width, current.height) <= 1920,
                  current.width * current.height <= 1920 * 1080 else {
                throw EnhancementError.unavailable("实时运动补偿插帧目前限制为1080p，请选择1080p输出")
            }
            let size = CGSize(width: current.width, height: current.height)
            if interpolationSize != size || interpolator == nil {
                clearReferences(resetEnhancement: false)
                interpolator = nil
                interpolationSize = nil
                let loading = CACurrentMediaTime()
                interpolator = try FrameInterpolatorMeasured(width: current.width, height: current.height, context: pipeline.context)
                lastSetupMilliseconds = (CACurrentMediaTime() - loading) * 1000
                interpolationSize = size
                lastResetReason = "正在建立运动补偿插帧会话"
            }
            guard let image = CIImage(mtlTexture: current.texture, options: [.colorSpace: pipeline.colorSpace]) else {
                throw EnhancementError.unavailable("插帧增强纹理读取失败")
            }
            let preview = scenePreview(image)
            let previous = reference
            reference = Reference(image: image, time: time, preview: preview)
            guard let previous else {
                lastWasPriming = true
                current = tagged(current, milliseconds: max(0, (CACurrentMediaTime() - start) * 1000 - lastSetupMilliseconds), suffix: " · 插帧参考建立中")
                // The one priming frame can be off-grid. The surface must not count it as 60 fps.
                return [(time.seconds, current)]
            }
            if changedScene(previous.preview, preview) {
                interpolator?.reset()
                hasCompletedInterpolation = false
                lastWasPriming = true
                lastResetReason = "检测到切镜或大范围变化，保留源帧且暂停跨镜头插帧"
                // Preserve the new reference but never synthesize a transition between scenes.
                // Off-grid source anchors are omitted rather than mixed into a 72 fps stream.
                if let aligned = alignedGridTime(time.seconds) {
                    return [(aligned, tagged(current, milliseconds: (CACurrentMediaTime() - start) * 1000, suffix: " · 切镜保护（源帧）"))]
                }
                return []
            }

            let firstIndex = Int64(floor(previous.time.seconds * 60 + 0.000001)) + 1
            let lastIndex = Int64(floor(time.seconds * 60 + 0.000001))
            guard firstIndex <= lastIndex else { return [] }
            let interval = time.seconds - previous.time.seconds
            var targetTimes: [Double] = []
            var phases: [Float] = []
            var includeCurrent: Double?
            for index in firstIndex...lastIndex {
                let target = Double(index) / 60
                if abs(target - time.seconds) <= 0.000001 { includeCurrent = target }
                else if target > previous.time.seconds && target < time.seconds {
                    targetTimes.append(target)
                    phases.append(Float((target - previous.time.seconds) / interval))
                }
            }
            var result: [(time: Double, frame: EnhancedFrame)] = []
            if !phases.isEmpty {
                lastWasPriming = !hasCompletedInterpolation
                let images = try interpolator!.interpolate(previous: previous.image, previousTime: previous.time,
                                                          current: image, currentTime: time, phases: phases)
                guard let command = pipeline.queue.makeCommandBuffer() else {
                    throw EnhancementError.unavailable("插帧输出提交失败")
                }
                for (index, intermediate) in images.enumerated() {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: current.width, height: current.height, mipmapped: false)
                    descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                    guard let texture = pipeline.device.makeTexture(descriptor: descriptor) else {
                        throw EnhancementError.unavailable("插帧输出纹理分配失败")
                    }
                    pipeline.context.render(intermediate, to: texture, commandBuffer: command,
                                            bounds: CGRect(x: 0, y: 0, width: current.width, height: current.height), colorSpace: pipeline.colorSpace)
                    let frame = EnhancedFrame(texture: texture, width: current.width, height: current.height,
                                              milliseconds: 0, mode: current.mode + " · 运动补偿60fps",
                                              usedTemporalHistory: current.usedTemporalHistory,
                                              temporalResetReason: current.temporalResetReason,
                                              cleanupAppliedRegions: current.cleanupAppliedRegions,
                                              cleanupRejectedRegions: current.cleanupRejectedRegions,
                                              cleanupReason: current.cleanupReason)
                    result.append((targetTimes[index], frame))
                }
                command.commit(); command.waitUntilCompleted()
                guard command.status == .completed else {
                    throw EnhancementError.unavailable(command.error?.localizedDescription ?? "插帧纹理处理失败")
                }
                hasCompletedInterpolation = true
                lastInterpolatedFrameCount = images.count
            }
            let milliseconds = max(0, (CACurrentMediaTime() - start) * 1000 - lastSetupMilliseconds)
            result = result.map { ($0.time, tagged($0.frame, milliseconds: milliseconds)) }
            if let includeCurrent {
                result.append((includeCurrent, tagged(current, milliseconds: milliseconds, suffix: " · 60fps源帧落点")))
            }
            return result
        } catch {
            reset()
            throw error
        }
    }

    private func clearReferences(resetEnhancement: Bool = true) {
        reference = nil
        interpolator?.reset()
        hasCompletedInterpolation = false
        if resetEnhancement { enhancementRevision = UUID() }
    }
    private func alignedGridTime(_ seconds: Double) -> Double? {
        let nearest = (seconds * 60).rounded() / 60
        return abs(nearest - seconds) <= 0.000001 ? nearest : nil
    }
    private func tagged(_ frame: EnhancedFrame, milliseconds: Double, suffix: String = "") -> EnhancedFrame {
        EnhancedFrame(originalImage: frame.originalImage, texture: frame.texture, width: frame.width, height: frame.height,
                      milliseconds: milliseconds, mode: frame.mode + suffix,
                      usedTemporalHistory: frame.usedTemporalHistory, temporalResetReason: frame.temporalResetReason,
                      cleanupAppliedRegions: frame.cleanupAppliedRegions, cleanupRejectedRegions: frame.cleanupRejectedRegions,
                      cleanupReason: frame.cleanupReason)
    }
    private func scenePreview(_ image: CIImage) -> [SIMD3<Float>] {
        let width = 64, height = 36
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let reduced = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / image.extent.width, y: CGFloat(height) / image.extent.height))
        pipeline.context.render(reduced, toBitmap: &bytes, rowBytes: width * 4,
                                bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: pipeline.colorSpace)
        return stride(from: 0, to: bytes.count, by: 4).map { SIMD3<Float>(Float(bytes[$0]), Float(bytes[$0 + 1]), Float(bytes[$0 + 2])) / 255 }
    }
    private func changedScene(_ previous: [SIMD3<Float>], _ current: [SIMD3<Float>]) -> Bool {
        let differences = zip(previous, current).map { pair -> Float in
            let difference = pair.0 - pair.1
            return max(abs(difference.x), abs(difference.y), abs(difference.z))
        }
        let mean = differences.reduce(0, +) / Float(max(1, differences.count))
        let changed = Float(differences.filter { $0 > 0.16 }.count) / Float(max(1, differences.count))
        return mean > 0.20 || (changed >= 0.45 && mean > 0.08)
    }
}
