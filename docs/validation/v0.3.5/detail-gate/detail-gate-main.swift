import Foundation
import CoreImage
import CoreMedia
import Metal
import QuartzCore

@main struct DetailScalingValidation {
    static let device = MTLCreateSystemDefaultDevice()!
    static let queue = device.makeCommandQueue()!
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    static var checks: [[String: Any]] = []
    static func check(_ name: String, _ passed: Bool, _ evidence: [String: Any] = [:]) {
        checks.append(["name": name, "passed": passed, "evidence": evidence])
        print("\(passed ? "PASS" : "FAIL") \(name): \(evidence)")
    }
    static func image(width: Int, height: Int, _ value: (Int, Int) -> UInt8) -> CIImage {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let v = value(x, y), i = (y * width + x) * 4
            data[i] = v; data[i + 1] = v; data[i + 2] = v
        }}
        return CIImage(bitmapData: Data(data), bytesPerRow: width * 4, size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
    }
    static func pixels(_ image: CIImage, width: Int, height: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &data, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: colorSpace)
        return data
    }
    static func pixels(_ texture: MTLTexture) -> [UInt8] {
        pixels(CIImage(mtlTexture: texture, options: [.colorSpace: colorSpace])!, width: texture.width, height: texture.height)
    }
    static func completed(_ image: CIImage, scaler: DetailScaler, width: Int, height: Int) throws -> (MTLTexture, Double, Double) {
        let start = CACurrentMediaTime(), command = queue.makeCommandBuffer()!
        let texture = try scaler.encode(image, width: width, height: height, context: context, command: command)
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? NSError(domain: "GPU", code: 1) }
        return (texture, (CACurrentMediaTime() - start) * 1000, (command.gpuEndTime - command.gpuStartTime) * 1000)
    }
    static func texture(_ image: CIImage, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let output = device.makeTexture(descriptor: descriptor)!, command = queue.makeCommandBuffer()!
        context.render(image, to: output, commandBuffer: command, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? NSError(domain: "GPU", code: 2) }
        return output
    }
    static func baseline(_ image: CIImage, scale: Double, bspline: Bool) -> CIImage {
        if bspline {
            return image.clampedToExtent().applyingFilter("CIBicubicScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1.0, "inputB": 1.0, "inputC": 0.0]).cropped(to: CGRect(x: 0, y: 0, width: image.extent.width * scale, height: image.extent.height * scale))
        }
        return image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: CGRect(x: 0, y: 0, width: image.extent.width * scale, height: image.extent.height * scale))
    }
    static func psnr(_ actual: [UInt8], _ reference: [UInt8]) -> Double {
        precondition(actual.count == reference.count)
        var sum = 0.0
        for i in actual.indices where i % 4 != 3 { let d = Double(actual[i]) - Double(reference[i]); sum += d * d }
        let mse = sum / Double(actual.count / 4 * 3)
        return mse == 0 ? 100 : 10 * log10(255 * 255 / mse)
    }
    static func noiseMSE(_ data: [UInt8], width: Int, height: Int, mean: Int) -> Double {
        var sum = 0.0, count = 0.0
        for y in 16..<(height - 16) { for x in 16..<(width - 16) {
            let d = Double(data[(y * width + x) * 4]) - Double(mean); sum += d * d; count += 1
        }}
        return sum / count
    }
    static func quality(_ scaler: DetailScaler) throws -> [[String: Any]] {
        let w = 256, h = 128, ow = w * 2, oh = h * 2
        let step = image(width: w, height: h) { x, _ in x < w / 2 ? 64 : 192 }
        var actual = step
        var temporalUsed = false
        if #available(macOS 26.0, *) {
            let denoiser = try TemporalRestorer(width: w, height: h, context: context), id = UUID()
            _ = try denoiser.process(step, time: .zero, streamID: id)
            let result = try denoiser.process(step, time: CMTime(value: 1, timescale: 30), streamID: id)
            actual = result.image; temporalUsed = result.usedHistory
        }
        let detail = pixels(try completed(actual, scaler: scaler, width: ow, height: oh).0)
        let smooth = pixels(baseline(actual, scale: 2, bspline: true), width: ow, height: oh)
        func edge(_ p: [UInt8]) -> (Int, Int, Int) {
            let line = (ow / 2 - 16..<ow / 2 + 16).map { Int(p[((oh / 2) * ow + $0) * 4]) }
            return (line.min()!, line.max()!, line.filter { $0 > 77 && $0 < 179 }.count)
        }
        let de = edge(detail), be = edge(smooth)
        check("same post-temporal step has no overshoot", de.0 >= 63 && de.1 <= 193, ["detail_range": [de.0, de.1], "bspline_range": [be.0, be.1], "used_temporal_history": temporalUsed])
        check("step transition narrower than B-spline", de.2 < be.2, ["detail_10_90_width": de.2, "bspline_10_90_width": be.2])
        var reports: [[String: Any]] = []
        for gray in [64, 128, 192] { for amplitude in [3, 8] {
            var random: UInt64 = 0xF042 + UInt64(gray + amplitude)
            func frame() -> CIImage {
                image(width: w, height: h) { _, _ in
                    random = random &* 6364136223846793005 &+ 1442695040888963407
                    let n = Int((random >> 32) % UInt64(amplitude * 2 + 1)) - amplitude
                    return UInt8(gray + n)
                }
            }
            let raw = frame()
            var inputs: [(String, CIImage)] = [("raw_stress", raw)]
            if #available(macOS 26.0, *) {
                let denoiser = try TemporalRestorer(width: w, height: h, context: context), id = UUID()
                _ = try denoiser.process(frame(), time: .zero, streamID: id)
                var restored = raw
                for index in 1...4 { restored = try denoiser.process(frame(), time: CMTime(value: Int64(index), timescale: 30), streamID: id).image }
                inputs.append(("post_temporal", restored))
            }
            for (stage, input) in inputs {
                let dp = pixels(try completed(input, scaler: scaler, width: ow, height: oh).0)
                let bp = pixels(baseline(input, scale: 2, bspline: false), width: ow, height: oh)
                let sp = pixels(baseline(input, scale: 2, bspline: true), width: ow, height: oh)
                let dm = noiseMSE(dp, width: ow, height: oh, mean: gray), bm = noiseMSE(bp, width: ow, height: oh, mean: gray)
                let row: [String: Any] = ["stage": stage, "gray": gray, "amplitude": amplitude, "detail_mse": dm, "bilinear_mse": bm, "bspline_mse": noiseMSE(sp, width: ow, height: oh, mean: gray), "ratio": dm / max(bm, 0.001)]
                reports.append(row)
                check("\(stage) flat \(gray) ±\(amplitude) noise <= bilinear ×1.15 +0.1", dm <= bm * 1.15 + 0.1, row)
            }
        }}
        return reports
    }
    static func film(_ scaler: DetailScaler) throws -> [[String: Any]] {
        let base = URL(fileURLWithPath: ".build/restoration-lab", isDirectory: true)
        let cleanURL = base.appendingPathComponent("clean-film-24.png")
        guard let clean = CIImage(contentsOf: cleanURL) else { return [["skipped": "Optional existing film fixture missing", "path": cleanURL.path]] }
        precondition(clean.extent.size == CGSize(width: 960, height: 400))
        let truth = pixels(clean, width: 960, height: 400)
        var results: [[String: Any]] = []
        for name in ["noisy", "compressed"] {
            let url = base.appendingPathComponent("\(name)-film-24.png")
            guard let input = CIImage(contentsOf: url) else { throw NSError(domain: "film fixture", code: 1) }
            precondition(input.extent.size == CGSize(width: 480, height: 200))
            let detail = pixels(try completed(input, scaler: scaler, width: 960, height: 400).0)
            let directOriginalTexture = pixels(try texture(input, width: 480, height: 200))
            let directOriginalPixels = pixels(input, width: 480, height: 200)
            check("\(name) original render texture matches direct CI orientation", psnr(directOriginalTexture, directOriginalPixels) >= 70, ["psnr": psnr(directOriginalTexture, directOriginalPixels)])
            let baselineTexture = pixels(try texture(baseline(input, scale: 2, bspline: false), width: 960, height: 400))
            check("\(name) detail texture matches existing CI render orientation", psnr(detail, baselineTexture) >= 35, ["psnr": psnr(detail, baselineTexture)])
            let smooth = pixels(baseline(input, scale: 2, bspline: true), width: 960, height: 400)
            let linear = pixels(baseline(input, scale: 2, bspline: false), width: 960, height: 400)
            let row: [String: Any] = ["fixture": url.path, "input": [480, 200], "output": [960, 400], "detail_psnr_db": psnr(detail, truth), "bspline_psnr_db": psnr(smooth, truth), "bilinear_psnr_db": psnr(linear, truth), "scope": "Same raw degraded single input; no temporal history; RGB code-value full-frame PSNR, not native 4K reconstruction"]
            print("FILM \(row)"); results.append(row)
        }
        return results
    }
    // Additional synthetic low-contrast control; unchanged input across scaler candidates.
    // The clean reference is a continuous sinusoid sampled at output pixel centres.
    // This measures spatial modulation only, not moving texture or a clean-film reconstruction.
    static func weakTexture(_ scaler: DetailScaler) throws -> [[String: Any]] {
        let w = 256, h = 64, ow = 512, oh = 128, period = 8.0
        var rows: [[String: Any]] = []
        for gray in [64, 128, 192] { for delta in [8, 12, 16, 24, 36] {
            let amplitude = Double(delta) / 2
            let source = image(width: w, height: h) { x, _ in
                UInt8((Double(gray) + amplitude * sin(2 * .pi * (Double(x) + 0.5) / period)).rounded())
            }
            let detail = pixels(try completed(source, scaler: scaler, width: ow, height: oh).0)
            let linear = pixels(baseline(source, scale: 2, bspline: false), width: ow, height: oh)
            let smooth = pixels(baseline(source, scale: 2, bspline: true), width: ow, height: oh)
            func measures(_ data: [UInt8]) -> [String: Double] {
                var sum = 0.0, s = 0.0, c = 0.0, count = 0.0
                for x in 32..<(ow - 32) {
                    let phase = 2 * Double.pi * ((Double(x) + 0.5) / 2) / period
                    let expected = (Double(gray) + amplitude * sin(phase)).rounded()
                    let value = Double(data[((oh / 2) * ow + x) * 4])
                    sum += (value - expected) * (value - expected)
                    s += (value - Double(gray)) * sin(phase)
                    c += (value - Double(gray)) * cos(phase)
                    count += 1
                }
                return ["mse_to_analytic_reference": sum / count,
                        "modulation_ratio": 2 * sqrt(s*s + c*c) / count / amplitude]
            }
            rows.append(["gray": gray, "peak_to_peak_codes": delta, "period_source_pixels": period,
                         "detail": measures(detail), "bilinear": measures(linear), "bspline": measures(smooth)])
        }}
        return rows
    }
    static func benchmark(_ scaler: DetailScaler) throws -> [String: Any] {
        let input = image(width: 1920, height: 1080) { x, y in UInt8(32 + ((x / 32 + y / 32) % 2) * 160) }
        let first = try completed(input, scaler: scaler, width: 3840, height: 2160)
        for _ in 0..<3 { _ = try completed(input, scaler: scaler, width: 3840, height: 2160) }
        var wall: [Double] = [], gpu: [Double] = []
        for _ in 0..<60 {
            let result = try completed(input, scaler: scaler, width: 3840, height: 2160)
            wall.append(result.1); gpu.append(result.2)
        }
        func statistics(_ values: [Double]) -> [String: Double] {
            let ordered = values.sorted()
            return ["mean": values.reduce(0, +) / Double(values.count), "p50": ordered[values.count / 2], "p95": ordered[Int(Double(values.count - 1) * 0.95)], "maximum": ordered.last!]
        }
        let row: [String: Any] = ["completed_frames": wall.count, "first_ms": first.1, "wall_ms": statistics(wall), "gpu_ms": statistics(gpu), "wall_samples_ms": wall, "gpu_samples_ms": gpu, "scope": "Scaler only: encoding, input CI conversion, output allocation, completed GPU command. 3 warm-up frames after first. No decode, temporal DNR, readback or presentation in measured loop. Serialized one frame in flight."]
        check("1080p to 4K completes all 60 frames", wall.count == 60)
        print("BENCHMARK mean \(statistics(wall)["mean"]!) ms, p95 \(statistics(wall)["p95"]!) ms")
        return row
    }
    static func main() throws {
        let scaler = try DetailScaler(device: device)
        let noise = try quality(scaler), films = try film(scaler), weak = try weakTexture(scaler), timings = try benchmark(scaler)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["device": device.name, "source": CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "unknown", "checks": checks, "passed": passed, "noise": noise, "film": films, "weakTexture": weak, "weakTextureScope": "Single-frame 8-source-pixel-period grayscale sine, output-pixel-centre analytic reference; no temporal DNR. Compare matched fixtures, not a general image quality guarantee.", "benchmark": timings]
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".build/detail-scale-probe/independent-validation.json"
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        print("\(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count) passed; \(path)")
        if !passed { exit(1) }
    }
}
