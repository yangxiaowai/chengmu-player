import Foundation
import AppKit
import CoreImage
import CoreVideo
import Metal
import CinemaCore

private let frameWidth = 960
private let frameHeight = 540
private let displayWidth = CommandLine.arguments.count > 3 ? (Int(CommandLine.arguments[3]) ?? 960) : 960
private let displayHeight = Int((Double(displayWidth) * Double(frameHeight) / Double(frameWidth)).rounded())
private var displayScale: Double { Double(displayWidth) / Double(frameWidth) }
private func coordinate(_ source: Int) -> Int { Int((Double(source) * displayScale).rounded()) }
private func displayRange(_ source: Range<Int>) -> Range<Int> { coordinate(source.lowerBound)..<coordinate(source.upperBound) }

private struct Generator {
    var seed: UInt64 = 0x4d595df4d0f33173
    mutating func uniform() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(UInt64(1) << 53)
    }
    mutating func noise() -> Double {
        // Deterministic, zero-centred, near-Gaussian noise (variance approximately one).
        var value = 0.0
        for _ in 0..<12 { value += uniform() }
        return value - 6
    }
}

private struct Fixture {
    let name: String
    let clean: [UInt8]
    let observed: [UInt8]
    var isNoise: Bool { name != "edges-subtitles-texture" }
}

private func byte(_ value: Double) -> UInt8 { UInt8(min(255, max(0, (value * 255).rounded()))) }

private func noiseFixture(_ name: String, color: [Double], chromaOnly: Bool = false, seed: UInt64) -> Fixture {
    var rng = Generator(seed: seed)
    var clean = [UInt8](repeating: 255, count: frameWidth * frameHeight * 4)
    var observed = clean
    for i in stride(from: 0, to: clean.count, by: 4) {
        let common = chromaOnly ? 0 : rng.noise() * 0.020
        for channel in 0..<3 {
            clean[i + channel] = byte(color[channel])
            observed[i + channel] = byte(color[channel] + common + rng.noise() * (chromaOnly ? 0.020 : 0.007))
        }
    }
    return Fixture(name: name, clean: clean, observed: observed)
}

private func detailFixture() -> Fixture {
    var pixels = [UInt8](repeating: 255, count: frameWidth * frameHeight * 4)
    func paint(_ x: Int, _ y: Int, _ value: Double) {
        let index = (y * frameWidth + x) * 4
        for c in 0..<3 { pixels[index + c] = byte(value) }
    }
    for y in 0..<frameHeight { for x in 0..<frameWidth { paint(x, y, 0.12) } }
    for y in 30..<210 { for x in 40..<920 { paint(x, y, x < 480 ? 0.20 : 0.70) } }
    for y in 250..<340 { for x in 80..<880 { paint(x, y, (x / 8) % 2 == 0 ? 0.35 : 0.55) } }
    // Fixed 5x7 glyphs avoid platform font rasterization differences. 5 px strokes represent
    // small burnt-in subtitle stems; ordinary soft subtitles remain outside the video pipeline.
    let glyphs = [
        ["01111","10000","10000","01110","00001","00001","11110"],
        ["10001","10001","10001","10001","10001","10001","01110"],
        ["11110","10001","10001","11110","10001","10001","11110"],
        ["11111","00100","00100","00100","00100","00100","00100"],
        ["11111","00100","00100","00100","00100","00100","11111"],
        ["11111","00100","00100","00100","00100","00100","00100"],
        ["10000","10000","10000","10000","10000","10000","11111"],
        ["11111","10000","10000","11110","10000","10000","11111"]
    ]
    for (letter, rows) in glyphs.enumerated() {
        for (row, text) in rows.enumerated() {
            for (column, bit) in text.enumerated() where bit == "1" {
                for dy in 0..<5 { for dx in 0..<5 { paint(300 + letter * 35 + column * 5 + dx, 430 + row * 5 + dy, 0.92) } }
            }
        }
    }
    return Fixture(name: "edges-subtitles-texture", clean: pixels, observed: pixels)
}

private func makeBuffer(_ rgba: [UInt8]) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    guard CVPixelBufferCreate(nil, frameWidth, frameHeight, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else {
        throw NSError(domain: "PictureQuality", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pixel buffer allocation failed"])
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    let target = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<frameHeight { for x in 0..<frameWidth {
        let from = (y * frameWidth + x) * 4, to = y * rowBytes + x * 4
        target[to] = rgba[from + 2]; target[to + 1] = rgba[from + 1]; target[to + 2] = rgba[from]; target[to + 3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
    return buffer
}

private func displayed(_ frame: EnhancedFrame, pipeline: EnhancementPipeline) -> [UInt8] {
    let image = CIImage(mtlTexture: frame.texture, options: [.colorSpace: pipeline.colorSpace])!
    // Match VideoSurface's affine fit at a common requested display raster. Equal output
    // pixel grids are essential: a larger buffer cannot count as a quality improvement.
    let scaled = image.transformed(by: CGAffineTransform(scaleX: CGFloat(displayWidth) / CGFloat(frame.width), y: CGFloat(displayHeight) / CGFloat(frame.height)))
    var pixels = [UInt8](repeating: 0, count: displayWidth * displayHeight * 4)
    pipeline.context.render(scaled, toBitmap: &pixels, rowBytes: displayWidth * 4,
                            bounds: CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight), format: .RGBA8, colorSpace: pipeline.colorSpace)
    return pixels
}

private func savePNG(_ pixels: [UInt8], to url: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: displayWidth, pixelsHigh: displayHeight,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: displayWidth * 4, bitsPerPixel: 32)!
    pixels.withUnsafeBytes { source in bitmap.bitmapData!.update(from: source.bindMemory(to: UInt8.self).baseAddress!, count: pixels.count) }
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}

private func luminance(_ pixels: [UInt8], _ x: Int, _ y: Int) -> Double {
    let index = (y * displayWidth + x) * 4
    return 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
}

private func noiseMetrics(_ image: [UInt8], reference: [UInt8]) -> [String: Double] {
    var lumaSquares = 0.0, rgbSquares = 0.0, chromaSquares = 0.0, difference = 0.0, count = 0.0
    // Exclude outer pixels to avoid testing filter border policy as noise reduction.
    for y in displayRange(24..<(frameHeight - 24)) { for x in displayRange(24..<(frameWidth - 24)) {
        let i = (y * displayWidth + x) * 4
        let delta = luminance(image, x, y) - luminance(reference, x, y)
        difference += delta; lumaSquares += delta * delta
        for c in 0..<3 {
            let d = Double(image[i + c]) - Double(reference[i + c])
            rgbSquares += d * d
            chromaSquares += (d - delta) * (d - delta)
        }
        count += 1
    } }
    return ["lumaRMS": sqrt(lumaSquares / count), "rgbMSE": rgbSquares / (3 * count),
            "chromaRMS": sqrt(chromaSquares / (3 * count)), "meanLumaDrift": difference / count]
}

private func detailMetrics(_ image: [UInt8], reference: [UInt8]) -> [String: Double] {
    var row = [Double](repeating: 0, count: displayWidth)
    let rowRegion = displayRange(80..<160), lowRegion = displayRange(150..<400), highRegion = displayRange(560..<810)
    for x in 0..<displayWidth { for y in rowRegion { row[x] += luminance(image, x, y) / Double(rowRegion.count) } }
    let low = lowRegion.map { row[$0] }.reduce(0, +) / Double(lowRegion.count)
    let high = highRegion.map { row[$0] }.reduce(0, +) / Double(highRegion.count)
    let edge = displayRange(464..<496).map { row[$0] }
    let overshoot = max(0, (edge.max() ?? high) - high, low - (edge.min() ?? low))
    func crossing(_ fraction: Double) -> Double {
        let threshold = low + (high - low) * fraction
        for x in displayRange(460..<500) where row[x] >= threshold {
            let prev = row[x - 1], delta = row[x] - prev
            return Double(x - 1) + (delta > 0 ? (threshold - prev) / delta : 0)
        }
        return Double(coordinate(500))
    }
    func textureDeviation(_ pixels: [UInt8]) -> Double {
        var sum = 0.0, square = 0.0, n = 0.0
        for y in displayRange(270..<320) { for x in displayRange(96..<864) {
            let v = luminance(pixels, x, y); sum += v; square += v * v; n += 1
        } }
        return sqrt(max(0, square / n - (sum / n) * (sum / n)))
    }
    var ink = 0.0, kept = 0.0, background = 0.0, leaked = 0.0
    for y in displayRange(420..<480) { for x in displayRange(290..<585) {
        let wasInk = luminance(reference, x, y) > 150, isInk = luminance(image, x, y) > 150
        if wasInk { ink += 1; if isInk { kept += 1 } }
        else { background += 1; if isInk { leaked += 1 } }
    } }
    return ["edgeOvershootCodeValues": overshoot, "edgeWidth10to90Pixels": crossing(0.9) - crossing(0.1),
            "textureContrastRetention": textureDeviation(image) / max(0.001, textureDeviation(reference)),
            "subtitleInkRecall": kept / max(1, ink), "subtitleBackgroundLeak": leaked / max(1, background)]
}

/// A source that already reaches 4K must retain the natural-denoise pixels, not pass through
/// a second interpolation at scale=1. Compare a hard edge and fine texture at native size.
private func nativeSizeChecks(_ pipeline: EnhancementPipeline) throws -> [[String: Any]] {
    try [(3840, 2160), (4096, 2304)].map { width, height in
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                   kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw EnhancementError.unavailable("Native-size fixture allocation failed") }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 5.0,
            "inputColor0": CIColor(red: 0.2, green: 0.2, blue: 0.2),
            "inputColor1": CIColor(red: 0.8, green: 0.8, blue: 0.8)])!.outputImage!.cropped(to: bounds)
        pipeline.context.render(checker, to: buffer, bounds: bounds, colorSpace: pipeline.colorSpace)
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, pipeline.colorSpace, .shouldPropagate)
        let clarity = try pipeline.process(buffer, mode: .clarity, time: .zero)
        let scaled = try pipeline.process(buffer, mode: .upscale4K, time: .zero)
        func patch(_ frame: EnhancedFrame) -> [UInt8] {
            let image = CIImage(mtlTexture: frame.texture, options: [.colorSpace: pipeline.colorSpace])!
            var bytes = [UInt8](repeating: 0, count: 128 * 64 * 4)
            pipeline.context.render(image, toBitmap: &bytes, rowBytes: 128 * 4,
                bounds: CGRect(x: width / 2 - 64, y: height / 2 - 32, width: 128, height: 64), format: .RGBA8, colorSpace: pipeline.colorSpace)
            return bytes
        }
        let a = patch(clarity), b = patch(scaled)
        let maxDifference = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
        let passed = scaled.width == width && scaled.height == height && maxDifference == 0
        print("native \(width)x\(height): max extra interpolation difference=\(maxDifference) passed=\(passed)")
        return ["sourcePixels": [width, height], "outputPixels": [scaled.width, scaled.height],
                "maxDifferenceFromNaturalDenoise": maxDifference, "passed": passed]
    }
}

@main struct PictureQuality {
    static func main() throws {
        guard (240...3840).contains(displayWidth), displayWidth % 16 == 0 else {
            print("displayWidth must be a multiple of 16 in 240...3840"); exit(2)
        }
        let reportURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let artifacts = reportURL.deletingPathExtension().appendingPathExtension("frames")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let pipeline = try EnhancementPipeline()
        let fixtures = [noiseFixture("dark-luma-noise", color: [0.10, 0.10, 0.10], seed: 101),
                        noiseFixture("midgray-luma-noise", color: [0.42, 0.42, 0.42], seed: 102),
                        noiseFixture("color-chroma-noise", color: [0.25, 0.40, 0.55], chromaOnly: true, seed: 103), detailFixture()]
        var results: [[String: Any]] = [], failures: [String] = []
        for fixture in fixtures {
            let clean = try makeBuffer(fixture.clean), observed = try makeBuffer(fixture.observed)
            let reference = displayed(try pipeline.process(clean, mode: .original, time: .zero), pipeline: pipeline)
            try savePNG(reference, to: artifacts.appendingPathComponent("\(fixture.name)-clean.png"))
            var originalMetrics: [String: Double] = [:]
            for mode in [EnhancementMode.original, .clarity, .upscale4K] {
                let frame = try pipeline.process(observed, mode: mode, time: .zero)
                let pixels = displayed(frame, pipeline: pipeline)
                let metrics = fixture.isNoise ? noiseMetrics(pixels, reference: reference) : detailMetrics(pixels, reference: reference)
                let filename = "\(fixture.name)-\(mode.rawValue).png"
                try savePNG(pixels, to: artifacts.appendingPathComponent(filename))
                if mode == .original { originalMetrics = metrics }
                var checks: [String: Bool] = [:]
                if mode != .original {
                    if fixture.isNoise {
                        checks["noise_not_amplified"] = metrics["rgbMSE"]! <= originalMetrics["rgbMSE"]! * 1.02
                        checks["luma_noise_not_amplified"] = metrics["lumaRMS"]! <= originalMetrics["lumaRMS"]! * 1.02
                        checks["noise_reduced"] = metrics["rgbMSE"]! <= originalMetrics["rgbMSE"]! * 0.98
                        checks["mean_luma_preserved"] = abs(metrics["meanLumaDrift"]! - originalMetrics["meanLumaDrift"]!) <= 1.0
                    } else {
                        checks["ringing_bounded"] = metrics["edgeOvershootCodeValues"]! <= originalMetrics["edgeOvershootCodeValues"]! + 3
                        checks["edge_width_preserved"] = metrics["edgeWidth10to90Pixels"]! <= originalMetrics["edgeWidth10to90Pixels"]! + 1.5 * displayScale
                        checks["texture_contrast_preserved"] = (0.85...1.10).contains(metrics["textureContrastRetention"]!)
                        checks["subtitle_strokes_preserved"] = metrics["subtitleInkRecall"]! >= 0.98 && metrics["subtitleBackgroundLeak"]! <= 0.005
                    }
                }
                for (check, passed) in checks where !passed { failures.append("\(fixture.name) / \(mode.rawValue): \(check)") }
                results.append(["fixture": fixture.name, "mode": mode.rawValue, "actualMode": frame.mode,
                                "sourcePixels": [frameWidth, frameHeight], "processingOutputPixels": [frame.width, frame.height],
                                "comparedDisplayPixels": [displayWidth, displayHeight], "metrics": metrics, "checks": checks, "png": filename])
                print("\(fixture.name) \(mode.rawValue): \(metrics.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.4f", $0.value))" }.joined(separator: " "))")
            }
        }
        let nativeChecks = try nativeSizeChecks(pipeline)
        for check in nativeChecks where check["passed"] as? Bool != true { failures.append("Native 4K/larger source received additional interpolation: \(check["sourcePixels"]!)") }
        let report: [String: Any] = ["checkedAt": ISO8601DateFormatter().string(from: Date()), "device": pipeline.device.name,
            "pipelineSource": CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "unspecified",
            "sourcePixels": [frameWidth, frameHeight], "displayPixels": [displayWidth, displayHeight],
            "scope": "Actual GPU EnhancementPipeline; deterministic synthetic SDR noise, known clean reference, hard edges, 8-pixel stripes and burnt-in subtitle glyphs at the same display raster. Does not prove quality on real films, HDR, temporal stability or native AVPlayer display equivalence.",
            "thresholdRationale": "Require 2% MSE reduction on fixed noisy flat fields; allow at most 2% noise amplification tolerance, 1 code-value mean drift, 3 code-value edge overshoot, 1.5 source-pixel additional edge width (scaled to the display raster), 85-110% texture contrast, >=98% subtitle ink recall and <=0.5% false ink. All spatial ROIs scale with the display raster. Engineering regression bounds for these fixtures, not universal perceptual scores.",
            "artifactDirectory": artifacts.path, "results": results, "nativeSizeChecks": nativeChecks, "failures": failures, "passed": failures.isEmpty]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
        if failures.isEmpty { print("PASS picture quality: noise reduced, edges and subtitle strokes retained") }
        else { failures.forEach { print("FAIL \($0)") }; exit(1) }
    }
}
