import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import Metal
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

private enum FilmFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

private struct Raster {
    let width: Int
    let height: Int
    let rgba: [UInt8]
    var image: CIImage {
        CIImage(bitmapData: Data(rgba), bytesPerRow: width * 4,
                size: CGSize(width: width, height: height), format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

/// Pooled squared error includes every RGB sample, excludes alpha and keeps equal grids.
/// Temporal error compares temporal derivatives to the clean clip, not to zero motion.
private struct ErrorAccumulator {
    var spatialSSE = 0.0
    var spatialCount = 0
    var temporalSSE = 0.0
    var temporalCount = 0
    var framePSNR: [Double] = []
    private var previousOutput: [UInt8]?
    private var previousReference: [UInt8]?

    mutating func append(_ output: Raster, reference: Raster) throws {
        guard output.width == reference.width, output.height == reference.height,
              output.rgba.count == reference.rgba.count else { throw FilmFailure.invalid("Metric grids differ") }
        var frameSSE = 0.0
        let oldOutput = previousOutput, oldReference = previousReference
        for index in stride(from: 0, to: output.rgba.count, by: 4) {
            for channel in 0..<3 {
                let p = index + channel
                let residual = Double(output.rgba[p]) - Double(reference.rgba[p])
                frameSSE += residual * residual
                if let oldOutput, let oldReference {
                    let deltaError = (Double(output.rgba[p]) - Double(oldOutput[p]))
                        - (Double(reference.rgba[p]) - Double(oldReference[p]))
                    temporalSSE += deltaError * deltaError
                    temporalCount += 1
                }
            }
        }
        let count = output.width * output.height * 3
        spatialSSE += frameSSE; spatialCount += count
        framePSNR.append(Self.psnr(frameSSE / Double(count)))
        previousOutput = output.rgba; previousReference = reference.rgba
    }

    private static func psnr(_ mse: Double) -> Double { 10 * log10(255 * 255 / max(mse, 1e-12)) }
    var report: [String: Any] {
        let mse = spatialSSE / Double(max(1, spatialCount))
        let temporalMSE = temporalSSE / Double(max(1, temporalCount))
        return ["rgb_mse_8bit": mse, "rgb_psnr_db": Self.psnr(mse),
                "worst_frame_rgb_psnr_db": framePSNR.min() ?? 0,
                "temporal_derivative_error_mse_8bit": temporalMSE,
                "temporal_derivative_error_rmse_8bit": sqrt(temporalMSE),
                "frames": framePSNR.count,
                "temporal_pairs": max(0, framePSNR.count - 1)]
    }
}

private struct ModeAssessment {
    var native = ErrorAccumulator()
    var display = ErrorAccumulator()
    var completedMS: [Double] = []
    var historyFrames = 0
    var resets: [[String: Any]] = []
    var processingSizes = Set<String>()
    var report: [String: Any] {
        let sorted = completedMS.sorted()
        let warm = Array(completedMS.dropFirst())
        return ["native_480x200": native.framePSNR.isEmpty ? NSNull() : native.report as Any, "display_960x400": display.report,
                "processing_output_sizes": processingSizes.sorted(),
                "completed_processing_ms": ["mean": completedMS.reduce(0, +) / Double(max(1, completedMS.count)),
                                             "p95": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
                                             "first": completedMS.first ?? 0,
                                             "warm_mean": warm.reduce(0, +) / Double(max(1, warm.count))],
                "frames_using_history": historyFrames, "history_resets": resets]
    }
}

private final class FrameReader {
    let asset: AVURLAsset
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let transform: CGAffineTransform
    private(set) var framesDecoded = 0

    init(url: URL) async throws {
        asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw FilmFailure.invalid("No video track: \(url.path)")
        }
        transform = try await track.load(.preferredTransform)
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FilmFailure.invalid("Cannot add video reader") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FilmFailure.invalid("Cannot start video reader") }
    }

    func next() throws -> (CIImage, CMTime, CVPixelBuffer)? {
        guard let sample = output.copyNextSampleBuffer() else {
            guard reader.status == .completed else { throw reader.error ?? FilmFailure.invalid("Reader ended unexpectedly") }
            return nil
        }
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw FilmFailure.invalid("Missing decoded image") }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric else { throw FilmFailure.invalid("Missing numeric presentation timestamp") }
        var image = CIImage(cvPixelBuffer: pixel).transformed(by: transform)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        framesDecoded += 1
        return (image, time, pixel)
    }
}

@available(macOS 26.0, *)
@main
private struct FilmAssessment {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let modes = ["original", "v031_clarity", "temporal", "apple_ai", "temporal_apple_ai"]
    static let expectedFrames = 96

    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else {
                throw FilmFailure.invalid("Usage: check report.json fixture-directory")
            }
            let reportURL = URL(fileURLWithPath: CommandLine.arguments[1])
            let fixtures = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let framesURL = reportURL.deletingPathExtension().appendingPathExtension("frames")
            try FileManager.default.createDirectory(at: framesURL, withIntermediateDirectories: true)
            guard let device = MTLCreateSystemDefaultDevice() else { throw FilmFailure.invalid("No Metal device") }
            let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false,
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
            var results: [[String: Any]] = []
            var variants = ["compressed-film", "noisy-film"]
            if FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("heavy-noisy-film.mp4").path) {
                variants.append("heavy-noisy-film")
            }
            for variant in variants {
                results.append(try await assess(variant: variant, fixtures: fixtures, framesURL: framesURL, context: context))
            }
            let files = ["clean-film.mp4"] + variants.map { $0 + ".mp4" }
            var hashes: [String: String] = [:]
            for name in files {
                hashes[name] = SHA256.hash(data: try Data(contentsOf: fixtures.appendingPathComponent(name)))
                    .map { String(format: "%02x", $0) }.joined()
            }
            let report: [String: Any] = [
                "schema_version": 1, "device": device.name,
                "operating_system": ProcessInfo.processInfo.operatingSystemVersionString,
                "source": ["title": "Tears of Steel", "license": "CC BY 3.0",
                           "attribution": "(CC) Blender Foundation | mango.blender.org",
                           "license_url": "https://mango.blender.org/sharing/", "fixture_sha256": hashes,
                           "original_url": "https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov",
                           "original_excerpt_start_seconds": 62, "original_excerpt_duration_seconds": 4,
                           "audio": "omitted",
                           "generation": "720p MOV excerpt -> clean 960x400,24fps,96 frames,H.264 CRF16; compressed=clean scaled480x200 bicubic,H.264 CRF34; noisy=480x200 plus noise alls=4:allf=t+u,H.264 CRF30. Original mild-noise command did not pin a seed; hashes identify actual inputs, not guaranteed bitwise regeneration. Optional heavy-noisy=scale480x200 bicubic,noise=alls=12:allf=t+u:all_seed=7,H.264 CRF24."],
                "scope": "\(variants.count) aligned 4-second synthetic degradations of one real film excerpt; 96 frames at 24 FPS per variant. This is not a general film-quality claim, player performance test, or 4K benchmark.",
                "metric_method": [
                    "color": "Decoded SDR images explicitly rendered to 8-bit sRGB RGB; alpha excluded.",
                    "native_reference": "960x400 clean reference downsampled once with CILanczosScaleTransform to 480x200. All candidates remain native size; no candidate upscale is involved in this score.",
                    "display_reference": "Decoded clean 960x400 frame; all candidate outputs are materialized then fitted to 960x400 with the same positive cubic B-spline scale (B=1,C=0). Apple's chosen processing dimensions are recorded separately. Native-size fidelity is reported only for non-upscaling methods.",
                    "temporal": "Mean squared ((output[t]-output[t-1])-(clean[t]-clean[t-1])) over RGB and 95 aligned pairs. Lower means better temporal fidelity to the moving clean reference, not simply a static picture.",
                    "baseline": "Frozen v0.3.1 clarity: CINoiseReduction inputNoiseLevel=0.015,inputSharpness=0.0; no additional sharpening.",
                    "temporal_strength": 0.75,
                    "timing": "Synchronous processing plus completed RGBA readback at the method's processing size. Excludes decode, metric loops, common display resampling, PNG IO and player work. Sequential modes are not a randomized performance study."
                ],
                "causality": ["frame_delivery": "One degraded frame delivered to TemporalRestorer at a time; current frame is processed before the next degraded frame is decoded.",
                              "next_frames_supplied": 0, "maximum_reference_history_frames": 1,
                              "note": "The clean reference is used only for metrics and never supplied to the restorer. This harness checks the production API's sequential use; it does not audit Apple's internal implementation."],
                "results": results, "sample_frames": [24], "png_directory": framesURL.path,
                "validation_completed": true,
                "quality_acceptance": "Informational measurements only. No hard-coded requirement that the candidate must beat the original."
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
            print("Film restoration assessment completed: \(reportURL.path)")
            for result in results {
                let summaries = result["modes"] as! [String: [String: Any]]
                for mode in modes {
                    let metrics = summaries[mode]!["display_960x400"] as! [String: Any]
                    print("\(result["variant"]!) / \(mode): display PSNR \(metrics["rgb_psnr_db"]!), temporal error RMSE \(metrics["temporal_derivative_error_rmse_8bit"]!)")
                }
            }
        } catch {
            fputs("Film assessment failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func assess(variant: String, fixtures: URL, framesURL: URL, context: CIContext) async throws -> [String: Any] {
        let clean = try await FrameReader(url: fixtures.appendingPathComponent("clean-film.mp4"))
        let degraded = try await FrameReader(url: fixtures.appendingPathComponent(variant + ".mp4"))
        let restorer = try TemporalRestorer(width: 480, height: 200, context: context, strength: 0.75)
        let aiPipeline = try EnhancementPipeline()
        let combinedPipeline = try EnhancementPipeline()
        let streamID = UUID()
        var assessments = Dictionary(uniqueKeysWithValues: modes.map { ($0, ModeAssessment()) })
        var count = 0
        var firstTime: Double?
        var lastTime: Double?
        var previousPTS: Double?
        while let observed = try degraded.next() {
            guard let reference = try clean.next() else { throw FilmFailure.invalid("Reference shorter than \(variant)") }
            guard count < expectedFrames,
                  abs(observed.1.seconds - reference.1.seconds) < 0.000_01,
                  observed.0.extent.size == CGSize(width: 480, height: 200),
                  reference.0.extent.size == CGSize(width: 960, height: 400) else {
                throw FilmFailure.invalid("Fixture count, timestamp or dimensions do not match at frame \(count)")
            }
            if let previousPTS, abs(observed.1.seconds - previousPTS - 1 / 24.0) > 0.000_01 {
                throw FilmFailure.invalid("Non-24-FPS timestamp interval at frame \(count)")
            }
            previousPTS = observed.1.seconds
            firstTime = firstTime ?? observed.1.seconds; lastTime = observed.1.seconds
            try autoreleasepool {
                let cleanDisplay = raster(reference.0, context: context)
                let cleanNativeImage = reference.0.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": 0.5, "inputAspectRatio": 1.0])
                    .cropped(to: CGRect(x: 0, y: 0, width: 480, height: 200))
                let cleanNative = raster(cleanNativeImage, context: context)
                if count == 24, variant == "compressed-film" {
                    try savePNG(cleanDisplay, to: framesURL.appendingPathComponent("clean-frame024.png"))
                }
                for mode in modes {
                    let start = CACurrentMediaTime()
                    let image: CIImage
                    var usedHistory = false
                    var resetReason: String?
                    switch mode {
                    case "v031_clarity":
                        image = observed.0.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.015, "inputSharpness": 0.0])
                    case "temporal":
                        let result = try restorer.process(observed.0, time: observed.1, streamID: streamID)
                        image = result.image; usedHistory = result.usedHistory; resetReason = result.resetReason
                        guard degraded.framesDecoded == count + 1 else { throw FilmFailure.invalid("Future frame decoded before restoration") }
                    case "apple_ai", "temporal_apple_ai":
                        let pipeline = mode == "apple_ai" ? aiPipeline : combinedPipeline
                        let selected: EnhancementMode = mode == "apple_ai" ? .appleAI : .restoration
                        let result = try pipeline.process(observed.2, mode: selected, time: observed.1,
                                                          displayTransform: degraded.transform, streamID: streamID)
                        guard let rendered = CIImage(mtlTexture: result.texture, options: [.colorSpace: colorSpace]) else {
                            throw FilmFailure.invalid("Cannot read completed AI texture")
                        }
                        image = rendered; usedHistory = result.usedTemporalHistory; resetReason = result.temporalResetReason
                        guard degraded.framesDecoded == count + 1 else { throw FilmFailure.invalid("Future frame decoded before combined restoration") }
                    default: image = observed.0
                    }
                    let native = raster(image, context: context)
                    let completedMS = (CACurrentMediaTime() - start) * 1000
                    let displayImage = native.image.clampedToExtent().applyingFilter("CIBicubicScaleTransform", parameters: [
                        "inputScale": 960.0 / Double(native.width), "inputAspectRatio": 1.0, "inputB": 1.0, "inputC": 0.0
                    ]).cropped(to: CGRect(x: 0, y: 0, width: 960, height: 400))
                    let display = raster(displayImage, context: context)
                    if native.width == 480, native.height == 200 {
                        try assessments[mode]!.native.append(native, reference: cleanNative)
                    }
                    try assessments[mode]!.display.append(display, reference: cleanDisplay)
                    assessments[mode]!.processingSizes.insert("\(native.width)x\(native.height)")
                    assessments[mode]!.completedMS.append(completedMS)
                    if usedHistory { assessments[mode]!.historyFrames += 1 }
                    if let resetReason { assessments[mode]!.resets.append(["frame": count, "reason": resetReason]) }
                    if count == 24 {
                        try savePNG(display, to: framesURL.appendingPathComponent("\(variant)-\(mode)-frame024.png"))
                    }
                }
            }
            count += 1
        }
        guard try clean.next() == nil, count == expectedFrames,
              assessments["temporal"]!.historyFrames > 0 else {
            throw FilmFailure.invalid("Incomplete fixture or temporal branch never used history")
        }
        return ["variant": variant, "frames": count, "first_pts_seconds": firstTime ?? 0,
                "last_pts_seconds": lastTime ?? 0, "modes": assessments.mapValues { $0.report }]
    }

    static func raster(_ image: CIImage, context: CIContext) -> Raster {
        let width = Int(image.extent.width.rounded()), height = Int(image.extent.height.rounded())
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: image.extent, format: .RGBA8, colorSpace: colorSpace)
        return Raster(width: width, height: height, rgba: pixels)
    }

    static func savePNG(_ raster: Raster, to url: URL) throws {
        guard let provider = CGDataProvider(data: Data(raster.rgba) as CFData),
              let image = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: raster.width * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FilmFailure.invalid("PNG output allocation failed")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FilmFailure.invalid("PNG save failed") }
    }
}
