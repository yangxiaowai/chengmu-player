import Foundation
import Combine
import AVFoundation
import CoreImage
import CoreVideo
import Metal
import QuartzCore
import CinemaCore

/// Completed processing work on a synthetic clip, never a claim about displayed FPS or audio sync.
struct QualityPerformanceReport {
    let testedAt: Date
    let deviceName: String
    let operatingSystem: String
    let mode: EnhancementMode
    let resolution: EnhancementResolution
    let requestedFrameRate: EnhancementFrameRate
    let sourceSize: PixelSize
    let sourceFPS: Double
    let assumedSourceFPS: Bool
    let outputSize: PixelSize
    let algorithm: String
    let warmupFrames: Int
    let completedFrames: Int
    let meanMS: Double
    let p95MS: Double
    let maximumMS: Double
    let frameBudgetMS: Double
    let overBudgetFrames: Int
    let pixelsChecked: Bool
    let includesFrameInterpolation: Bool
    let completedOutputFrames: Int
    let interpolatedFrames: Int
    let frameGridValidated: Bool
    let sampledMediaSeconds: Double
    let firstFrameMS: Double
    let frameRateNote: String

    var headroomMS: Double { frameBudgetMS - p95MS }
    var spatialFitsBudget: Bool { p95MS < frameBudgetMS }
    var verdict: String {
        let scope = includesFrameInterpolation ? "空间处理与插帧" : "空间处理"
        return spatialFitsBudget ? "\(scope)短测低于源帧预算" : "当前\(scope)超过源帧预算"
    }
    var configurationLabel: String {
        "\(mode.title) · \(resolution.title) · \(requestedFrameRate.title)"
    }
    var sourceLabel: String {
        "合成 SDR \(sourceSize.width)×\(sourceSize.height) · \(String(format: "%.2f", sourceFPS)) fps\(assumedSourceFPS ? "（测试假设）" : "")"
    }

    /// Nearest-rank percentile; the samples are completed GPU work, not command submission times.
    static func percentile95(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }
}

@MainActor
final class QualityPerformanceController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "尚未检测"
    @Published private(set) var report: QualityPerformanceReport?
    @Published private(set) var error: String?
    private let worker = DispatchQueue(label: "Cinema.quality-benchmark", qos: .userInitiated)
    private var cancellation: QualityBenchmarkCancellation?
    private var runID: UUID?

    /// Returns false if no test started. Completion runs on the main actor after the worker exits,
    /// including cancellation, so the playback controller can safely restore its captured intent.
    @discardableResult
    func run(mode: EnhancementMode, resolution: EnhancementResolution, frameRate: EnhancementFrameRate,
             sourceSize: PixelSize, sourceFPS: Double, completion: (() -> Void)? = nil) -> Bool {
        guard !isRunning else { return false }
        guard mode != .original else {
            error = "请先选择一种画面处理模式；原片由系统直接播放。"
            return false
        }
        let size = sourceSize.width > 0 && sourceSize.height > 0 ? sourceSize : PixelSize(width: 1280, height: 720)
        guard size.width >= 64, size.height >= 64, size.width <= 3840, size.height <= 3840,
              Int64(size.width) * Int64(size.height) <= 3840 * 2160 else {
            error = "合成自检支持 64 像素至 4K 的输入，当前尺寸超出范围；不会缩小输入后冒充原尺寸测试。"
            return false
        }
        let assumedFPS = !sourceFPS.isFinite || sourceFPS <= 0 || sourceFPS > 240
        let fps = assumedFPS ? 24.0 : sourceFPS
        let request = QualityBenchmarkRequest(mode: mode, resolution: resolution, frameRate: frameRate,
                                              sourceSize: size, sourceFPS: fps, assumedSourceFPS: assumedFPS)
        let token = UUID(), flag = QualityBenchmarkCancellation()
        runID = token; cancellation = flag
        isRunning = true; isCancelling = false; progress = 0; error = nil; report = nil
        status = "准备固定运动与噪声样本…"
        worker.async { [weak self] in
            let result: Result<QualityPerformanceReport, Error> = Result {
                try Self.perform(request, cancellation: flag) { fraction, label in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.runID == token, !self.isCancelling else { return }
                        self.progress = fraction; self.status = label
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.runID == token else { return }
                self.isRunning = false; self.isCancelling = false; self.cancellation = nil; self.runID = nil
                if flag.isCancelled {
                    self.status = "检测已取消"
                } else {
                    switch result {
                    case .success(let report):
                        self.report = report; self.progress = 1; self.status = "检测完成"
                    case .failure(let error):
                        self.error = error.localizedDescription; self.status = "检测未完成"
                    }
                }
                completion?()
            }
        }
        return true
    }

    func cancel() {
        guard isRunning else { return }
        isCancelling = true; status = "正在等待当前帧完成…"
        cancellation?.cancel()
    }

    nonisolated private static func perform(_ request: QualityBenchmarkRequest, cancellation: QualityBenchmarkCancellation,
                                           progress: @escaping (Double, String) -> Void) throws -> QualityPerformanceReport {
        progress(0, "等待播放处理结束，准备独占自检…")
        return try EnhancementPipeline.withExclusiveProcessing {
            try cancellation.check()
            progress(0, "准备固定运动与噪声样本…")
            return try performExclusive(request, cancellation: cancellation, progress: progress)
        }
    }

    /// Serializes the whole measured run with playback workers; lock waiting is not processing time.
    nonisolated private static func performExclusive(_ request: QualityBenchmarkRequest, cancellation: QualityBenchmarkCancellation,
                                                    progress: @escaping (Double, String) -> Void) throws -> QualityPerformanceReport {
        try cancellation.check()
        let pipeline = try EnhancementPipeline()
        let buffer = try makeBuffer(request.sourceSize)
        let warmupCount = 3, sampleCount = 30, totalCount = warmupCount + sampleCount
        let stream = UUID()
        // One invocation consumes one decoded source frame and may generate multiple outputs.
        // Comparing the entire source interval against 1/60 would misstate the required throughput.
        let budget = 1000.0 / request.sourceFPS
        let interpolates = request.frameRate == .fps60 && request.sourceFPS < 60
        let execute: (CVPixelBuffer, CMTime) throws -> QualityBenchmarkBatch
        if interpolates {
            let target = request.resolution.target(width: request.sourceSize.width, height: request.sourceSize.height,
                                                   automatic4K: request.mode.automaticallyTargets4K)
            guard max(target.width, target.height) <= 1920, target.width * target.height <= 1920 * 1080 else {
                throw EnhancementError.unavailable("60 fps 插帧自检目前限 1080p 以内，请选择 1080p 预设；不会暗中降低目标尺寸。")
            }
            guard request.sourceFPS >= 8 else {
                throw EnhancementError.unavailable("当前片源帧率低于 8 fps，超出实时插帧的连续时间窗口；请跟随片源帧率。")
            }
            if #available(macOS 26.0, *) {
                let interpolation = InterpolatedFramePipeline(pipeline: pipeline)
                execute = { buffer, time in
                    let frames = try interpolation.process(buffer: buffer, time: time, mode: request.mode,
                                                           resolution: request.resolution, transform: .identity,
                                                           cleanup: .init(), streamID: stream)
                    return QualityBenchmarkBatch(frames: frames, interpolated: interpolation.lastInterpolatedFrameCount)
                }
            } else {
                throw EnhancementError.unavailable("运动插帧自检需要 macOS 26 或更新版本。")
            }
        } else {
            execute = { buffer, time in
                let frame = try pipeline.process(buffer, mode: request.mode, time: time,
                                                 streamID: stream, resolution: request.resolution)
                return QualityBenchmarkBatch(frames: [(time.seconds, frame)], interpolated: 0)
            }
        }
        var times: [Double] = [], outputSize = request.sourceSize, algorithm = ""
        var checkedFrames = 0, outputFrames = 0, interpolatedFrames = 0
        var previousOutputTime: Double?, firstFrameMS = 0.0
        for index in 0..<totalCount {
            try cancellation.check()
            try autoreleasepool {
                // CPU fixture generation and correctness readback are outside the timer.
                // The full spatial + interpolation path, including final texture completion, is inside.
                try fillFixture(buffer, frame: index)
                try cancellation.check()
                // CMTime(seconds:) truncates some binary floating-point products (26/24 became
                // 64999/60000). Round the fixed fixture onto its rational source timeline.
                let value = CMTimeValue((Double(index) * 60_000 / request.sourceFPS).rounded())
                let time = CMTime(value: value, timescale: 60_000)
                let start = CACurrentMediaTime()
                let batch = try execute(buffer, time)
                let completedMS = (CACurrentMediaTime() - start) * 1000
                guard completedMS.isFinite, completedMS > 0, !batch.frames.isEmpty else {
                    throw QualityBenchmarkError.invalidOutput
                }
                if index == 0 { firstFrameMS = completedMS }
                for output in batch.frames {
                    let frame = output.frame
                    guard frame.width > 0, frame.height > 0,
                          frame.texture.width == frame.width, frame.texture.height == frame.height else {
                        throw QualityBenchmarkError.invalidOutput
                    }
                    outputSize = PixelSize(width: frame.width, height: frame.height)
                    // Keep the interpolation description when the last output is a source-grid anchor.
                    if algorithm.isEmpty || batch.interpolated == 0 || frame.mode.contains("运动补偿") { algorithm = frame.mode }
                    if index > 0 && interpolates {
                        guard abs(output.time * 60 - (output.time * 60).rounded()) < 0.00001,
                              previousOutputTime.map({ abs(output.time - $0 - 1.0 / 60.0) < 0.00001 }) ?? true else {
                            throw QualityBenchmarkError.invalidFrameGrid
                        }
                    }
                    previousOutputTime = output.time
                    if index == warmupCount - 1 || index == totalCount - 1 {
                        try verifyPixels(frame, pipeline: pipeline); checkedFrames += 1
                    }
                }
                if index >= warmupCount {
                    times.append(completedMS)
                    outputFrames += batch.frames.count
                    interpolatedFrames += batch.interpolated
                }
            }
            let label = index < warmupCount
                ? "预热 \(index + 1)/\(warmupCount)"
                : "\(interpolates ? "空间处理与插帧" : "完整空间处理")采样 \(index - warmupCount + 1)/\(sampleCount)"
            progress(Double(index + 1) / Double(totalCount), label)
        }
        try cancellation.check()
        if interpolates && interpolatedFrames == 0 { throw QualityBenchmarkError.invalidFrameGrid }
        let note = interpolates
            ? "按源帧间隔统计空间处理与运动插帧总耗时；60 Hz 格点已检查，未验证屏幕呈现。"
            : (request.frameRate == .fps60 ? "片源已达到或超过 60 fps，本次保留源帧率，不生成中间帧。" : "跟随片源帧率，本次仅测空间处理。")
        return QualityPerformanceReport(testedAt: Date(), deviceName: pipeline.device.name,
                                        operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                                        mode: request.mode, resolution: request.resolution, requestedFrameRate: request.frameRate,
                                        sourceSize: request.sourceSize, sourceFPS: request.sourceFPS, assumedSourceFPS: request.assumedSourceFPS,
                                        outputSize: outputSize, algorithm: algorithm, warmupFrames: warmupCount, completedFrames: times.count,
                                        meanMS: times.reduce(0, +) / Double(times.count), p95MS: QualityPerformanceReport.percentile95(times),
                                        maximumMS: times.max() ?? 0, frameBudgetMS: budget,
                                        overBudgetFrames: times.filter { $0 >= budget }.count, pixelsChecked: checkedFrames >= 2,
                                        includesFrameInterpolation: interpolates, completedOutputFrames: outputFrames,
                                        interpolatedFrames: interpolatedFrames, frameGridValidated: interpolates,
                                        sampledMediaSeconds: Double(sampleCount) / request.sourceFPS,
                                        firstFrameMS: firstFrameMS, frameRateNote: note)
    }

    nonisolated private static func makeBuffer(_ size: PixelSize) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        let status = CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw QualityBenchmarkError.bufferUnavailable }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, srgb, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return buffer
    }

    nonisolated private static func fillFixture(_ buffer: CVPixelBuffer, frame: Int) throws {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw QualityBenchmarkError.bufferUnavailable }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw QualityBenchmarkError.bufferUnavailable }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        let movingX = (frame * 3) % max(1, width - width / 5)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let hash = UInt32(truncatingIfNeeded: x &* 73_856_093) ^ UInt32(truncatingIfNeeded: y &* 19_349_663) ^ UInt32(truncatingIfNeeded: (frame + 7) &* 83_492_791)
                let noise = Int((hash &* 1_664_525 &+ 1_013_904_223) % 7) - 3
                let moving = x >= movingX && x < movingX + width / 5 && y > height / 3 && y < height * 2 / 3
                let grid = ((x / 16 + y / 16) % 2) * 10
                let value = moving ? 190 : 48 + x * 96 / max(1, width - 1) + grid
                row[x * 4] = UInt8(clamping: value + noise + 12)
                row[x * 4 + 1] = UInt8(clamping: value + noise)
                row[x * 4 + 2] = UInt8(clamping: value + noise - 8)
                row[x * 4 + 3] = 255
            }
        }
    }

    nonisolated private static func verifyPixels(_ frame: EnhancedFrame, pipeline: EnhancementPipeline) throws {
        guard let image = CIImage(mtlTexture: frame.texture, options: [.colorSpace: pipeline.colorSpace]) else {
            throw QualityBenchmarkError.invalidOutput
        }
        let size = 16
        let thumbnail = image.transformed(by: CGAffineTransform(scaleX: Double(size) / Double(frame.width), y: Double(size) / Double(frame.height)))
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { bytes in
            pipeline.context.render(thumbnail, toBitmap: bytes.baseAddress!, rowBytes: size * 4,
                                    bounds: CGRect(x: 0, y: 0, width: size, height: size), format: .RGBA8, colorSpace: pipeline.colorSpace)
        }
        var low: UInt8 = 255, high: UInt8 = 0, opaque = true
        for index in stride(from: 0, to: pixels.count, by: 4) {
            low = min(low, pixels[index]); high = max(high, pixels[index])
            opaque = opaque && pixels[index + 3] >= 254
        }
        guard opaque, high > low, Int(high) - Int(low) > 12, high > 24, low < 230 else {
            throw QualityBenchmarkError.invalidOutput
        }
    }
}

private struct QualityBenchmarkBatch {
    let frames: [(time: Double, frame: EnhancedFrame)]
    let interpolated: Int
}

private struct QualityBenchmarkRequest {
    let mode: EnhancementMode
    let resolution: EnhancementResolution
    let frameRate: EnhancementFrameRate
    let sourceSize: PixelSize
    let sourceFPS: Double
    let assumedSourceFPS: Bool
}

private enum QualityBenchmarkError: LocalizedError {
    case bufferUnavailable, invalidOutput, invalidFrameGrid
    var errorDescription: String? {
        switch self {
        case .bufferUnavailable: return "无法创建本机检测图像缓冲。"
        case .invalidOutput: return "处理输出未通过尺寸或像素检查，本次不生成性能结论。"
        case .invalidFrameGrid: return "插帧输出未通过 60 Hz 时间格点连续性或生成数量检查，本次不生成性能结论。"
        }
    }
}

private final class QualityBenchmarkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { if isCancelled { throw CancellationError() } }
}
