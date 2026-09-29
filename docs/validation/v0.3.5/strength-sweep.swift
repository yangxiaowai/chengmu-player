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
    static let strengths: [Float] = [0.25, 0.5, 0.75, 1.0]
    static let modes = ["original"] + strengths.map { "temporal_" + String($0) }
    static let expectedFrames = 96

    static func main() async {
        setbuf(stdout, nil)
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
                "scope": "\(variants.count) aligned 4-second synthetic degradations of one real film excerpt; 96 frames at 24 FPS per variant. Fixed-strength sweep, no learned upscaler. Not a general film-quality claim, player performance test, or 4K benchmark.",
                "metric_method": [
                    "color": "Decoded SDR images explicitly rendered to 8-bit sRGB RGB; alpha excluded.",
                    "native_reference": "960x400 clean reference downsampled once with CILanczosScaleTransform to 480x200. All candidates remain native size; no candidate upscale is involved in this score.",
                    "display_reference": "Decoded clean 960x400 frame; all candidate outputs are materialized then fitted to 960x400 with the same positive cubic B-spline scale (B=1,C=0). Apple's chosen processing dimensions are recorded separately. Native-size fidelity is reported only for non-upscaling methods.",
                    "temporal": "Mean squared ((output[t]-output[t-1])-(clean[t]-clean[t-1])) over RGB and 95 aligned pairs. Lower means better temporal fidelity to the moving clean reference, not simply a static picture.",
                    "baseline": "Unprocessed source. All four strengths use independent production TemporalRestorer sessions; strength is never changed inside a session.",
                    "temporal_strengths": strengths,
                    "timing": "Synchronous processing plus completed RGBA readback at the method's processing size. Excludes decode, metric loops, common display resampling, PNG IO and player work. Sequential modes are not a randomized performance study."
                ],
                "causality": ["frame_delivery": "One degraded frame delivered to TemporalRestorer at a time; current frame is processed before the next degraded frame is decoded.",
                              "next_frames_supplied": 0, "maximum_reference_history_frames": 1,
                              "note": "The clean reference is used only for metrics and never supplied to the restorer. This harness checks the production API's sequential use; it does not audit Apple's internal implementation."],
                "results": results, "synthetic": try assessSynthetic(context: context), "sample_frames": [24], "png_directory": framesURL.path,
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
        let restorers = try Dictionary(uniqueKeysWithValues: strengths.map { strength in
            ("temporal_" + String(strength), try TemporalRestorer(width: 480, height: 200, context: context, strength: strength))
        })
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
                    if let restorer = restorers[mode] {
                        let result = try restorer.process(observed.0, time: observed.1, streamID: streamID)
                        image = result.image; usedHistory = result.usedHistory; resetReason = result.resetReason
                        guard degraded.framesDecoded == count + 1 else { throw FilmFailure.invalid("Future frame decoded before restoration") }
                    } else { image = observed.0 }
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
              strengths.allSatisfy({ assessments["temporal_" + String($0)]!.historyFrames > 0 }) else {
            throw FilmFailure.invalid("Incomplete fixture or temporal branch never used history")
        }
        return ["variant": variant, "frames": count, "first_pts_seconds": firstTime ?? 0,
                "last_pts_seconds": lastTime ?? 0, "modes": assessments.mapValues { $0.report }]
    }


    static func assessSynthetic(context: CIContext) throws -> [[String: Any]] {
        let w = 640, h = 360
        var rows: [[String: Any]] = []
        for noisy in [false, true] {
            for strength in strengths {
                let restorer = try TemporalRestorer(width: w, height: h, context: context, strength: strength), stream = UUID()
                var frames: [[String: Any]] = [], times: [Double] = [], history = 0
                var totals = Dictionary(uniqueKeysWithValues: ["flat", "motion", "texture", "subtitle", "all"].map { ($0, 0.0) })
                var rawTotals = totals
                var minRecall = 1.0, maxLeak = 0.0
                for index in 0..<12 {
                    let source = SyntheticFixture.fixture(w: w, h: h, index: index, noisy: noisy)
                    let truth = SyntheticFixture.pixels(SyntheticFixture.fixture(w:w,h:h,index:index,noisy:false),context:context,w:w,h:h)
                    let input = SyntheticFixture.pixels(source,context:context,w:w,h:h)
                    let result = try restorer.process(source,time:CMTime(value:Int64(index),timescale:30),streamID:stream)
                    let output = SyntheticFixture.pixels(result.image,context:context,w:w,h:h)
                    if result.usedHistory {history += 1}
                    if index >= 2 {times.append(result.milliseconds)}
                    var regions:[String:Any]=[:]
                    for region in ["flat","motion","texture","subtitle","all"] {
                        let raw=SyntheticFixture.mse(input,truth,w:w,h:h,region:region)
                        let processed=SyntheticFixture.mse(output,truth,w:w,h:h,region:region)
                        regions[region]=["source_mse":raw,"processed_mse":processed]
                        if index > 0 {totals[region]! += processed;rawTotals[region]! += raw}
                    }
                    var strokes=0,preserved=0,background=0,leaked=0
                    for y in (h*4/5-4)..<(h*4/5+18) {for x in 90..<510 {
                        let offset=(y*w+x)*4
                        if truth[offset]>200 {strokes += 1;if output[offset]>180 {preserved += 1}}
                        else {background += 1;if output[offset]>180 {leaked += 1}}
                    }}
                    let recall=Double(preserved)/Double(max(1,strokes)),leak=Double(leaked)/Double(max(1,background))
                    minRecall=min(minRecall,recall);maxLeak=max(maxLeak,leak)
                    frames.append(["frame":index,"used_history":result.usedHistory,"reset_reason":result.resetReason as Any? ?? NSNull(),"regions":regions,"subtitle_recall":recall,"subtitle_background_leak":leak,"completed_ms":result.milliseconds])
                }
                let sorted=times.sorted()
                rows.append(["variant":noisy ? "synthetic_noisy_motion_texture_subtitle":"synthetic_clean_motion_texture_subtitle","strength":strength,"size":[w,h],"frames":frames,"history_frames":history,"mean_region_mse_excluding_priming":totals.mapValues{$0/11},"source_region_mse_excluding_priming":rawTotals.mapValues{$0/11},"minimum_subtitle_recall":minRecall,"maximum_subtitle_background_leak":maxLeak,"warm_mean_ms":times.reduce(0,+)/Double(times.count),"warm_p95_ms":sorted[Int(ceil(Double(sorted.count)*0.95))-1],"scope":"Copied deterministic native-restoration fixture: RGB uniform noise +/-15, moving rectangle, 3px low-contrast texture, coarse white glyph pattern moves at frame6; no guarantee for thin/color subtitles or arbitrary content. No future frames." ])
                print("Synthetic noisy=\(noisy) strength=\(strength) allMSE=\(totals["all"]!/11) recall=\(minRecall) leak=\(maxLeak)")
            }
        }
        return rows
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

private enum SyntheticFixture {
    static let color = CGColorSpace(name: CGColorSpace.sRGB)!
    static var checks: [[String: Any]] = []
    static func check(_ name: String, _ passed: Bool, _ details: [String: Any] = [:]) {
        checks.append(["name": name, "passed": passed, "details": details])
    }
    static func pixels(_ image: CIImage, context: CIContext, w: Int, h: Int) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &p, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: color)
        return p
    }
    static func fixture(w: Int, h: Int, index: Int, noisy: Bool) -> CIImage {
        var p = [UInt8](repeating: 255, count: w * h * 4), seed = UInt64(index + 76543)
        for y in 0..<h { for x in 0..<w {
            let base: [Int]
            if y > h * 4 / 5 && y < h * 4 / 5 + 12 && x > (index < 6 ? 100 : 200) && x < (index < 6 ? 400 : 500) && (x / 8) % 3 != 0 { base = [228, 228, 228] }
            else if x > w / 2 + index * 5 && x < w / 2 + index * 5 + 80 && y > h / 3 && y < h * 2 / 3 { base = [180, 180, 180] }
            else if x > w * 3 / 4 && y < h / 4 { base = (x / 3) % 2 == 0 ? [90, 90, 90] : [114, 114, 114] }
            else if x < w / 3 { base = [30, 30, 30] }
            else { base = [102, 102, 102] }
            for c in 0..<3 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                p[(y * w + x) * 4 + c] = UInt8(clamping: base[c] + (noisy ? Int((seed >> 32) % 31) - 15 : 0))
            }
        }}
        return CIImage(bitmapData: Data(p), bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: color)
    }
    static func mse(_ a: [UInt8], _ truth: [UInt8], w: Int, h: Int, region: String) -> Double {
        var sum = 0.0, count = 0
        for y in stride(from: 16, to: h - 16, by: 2) { for x in stride(from: 16, to: w - 16, by: 2) {
            let include: Bool
            switch region {
            case "flat": include = x < w / 3 - 20 && y < h * 3 / 4
            case "motion": include = x > w / 2 - 10 && x < w / 2 + 180 && y > h / 3 - 10 && y < h * 2 / 3 + 10
            case "texture": include = x > w * 3 / 4 + 16 && y < h / 4 - 16
            case "subtitle": include = x > 90 && x < 510 && y > h * 4 / 5 - 4 && y < h * 4 / 5 + 18
            default: include = true
            }
            if include { for c in 0..<3 { let d = Double(a[(y*w+x)*4+c]) - Double(truth[(y*w+x)*4+c]); sum += d*d; count += 1 } }
        }}
        return sum / Double(max(1, count))
    }
}
