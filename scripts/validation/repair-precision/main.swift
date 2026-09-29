import Foundation
import CoreVideo
import CoreImage
import CoreMedia
import Metal
import CinemaCore

/// Production-path readback: a tagged 10-bit SDR ramp must not become 8-bit
/// between decoding and display. No HDR claim or physical display measurement.
@main struct RepairPrecisionValidation {
    static var checks: [[String: Any]] = []
    static func check(_ name: String, _ passed: Bool, _ evidence: [String: Any] = [:]) {
        checks.append(["name": name, "passed": passed, "evidence": evidence])
        print("\(passed ? "PASS" : "FAIL") \(name): \(evidence)")
    }
    static func ramp() throws -> CVPixelBuffer {
        var candidate: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, 1024, 64, ColorFrameGate.outputPixelFormat,
                                  attributes as CFDictionary, &candidate) == kCVReturnSuccess,
              let buffer = candidate else { throw NSError(domain: "ramp", code: 1) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) == 2,
              CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) >= 1024 * 2,
              CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) >= 1024 * 2,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw NSError(domain: "ramp-layout", code: 1)
        }
        var lumaLevels = Set<UInt16>(), neutralChroma = true, paddingIsZero = true
        for plane in 0..<2 {
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                for x in 0..<1024 {
                    row[x] = UInt16(plane == 0 ? 64 + x * 876 / 1023 : 512) << 6
                    let code = row[x] >> 6
                    if plane == 0 { lumaLevels.insert(code) } else { neutralChroma = neutralChroma && code == 512 }
                    paddingIsZero = paddingIsZero && row[x] & 63 == 0
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        check("fixture uses legal 10-bit video range and neutral chroma",
              lumaLevels.min() == 64 && lumaLevels.max() == 940 && lumaLevels.count == 877 && neutralChroma && paddingIsZero,
              ["minimum_luma_code": Int(lumaLevels.min() ?? 0), "maximum_luma_code": Int(lumaLevels.max() ?? 0),
               "distinct_luma_codes": lumaLevels.count, "chroma_code": 512, "low_six_bits_zero": paddingIsZero])
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }
    // Non-primary-only values also expose accidental linear/sRGB reinterpretation.
    static let patchRGB: [[Float]] = [[0.83, 0.13, 0.07], [0.09, 0.79, 0.18], [0.11, 0.21, 0.91], [0.18, 0.18, 0.18]]
    static func colorPatches() throws -> CVPixelBuffer {
        let buffer = try ramp()
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw NSError(domain: "color-lock", code: 1) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        // BT.709 non-linear R'G'B' -> video-range Y'CbCr; tags remain explicitly SDR sRGB.
        let codes: [[UInt16]] = patchRGB.map { rgb in
            let red = Double(rgb[0]), green = Double(rgb[1]), blue = Double(rgb[2])
            let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            return [UInt16((64 + 876 * luma).rounded()),
                    UInt16((512 + 896 * (blue - luma) / (2 * (1 - 0.0722))).rounded()),
                    UInt16((512 + 896 * (red - luma) / (2 * (1 - 0.2126))).rounded())]
        }
        for plane in 0..<2 {
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            for y in 0..<height {
                let row = base.advanced(by: y * bytes).assumingMemoryBound(to: UInt16.self)
                for x in 0..<1024 {
                    let patch = x / 256
                    row[x] = codes[patch][plane == 0 ? 0 : 1 + x % 2] << 6
                }
            }
        }
        check("color fixture codes stay within 10-bit video range", codes.allSatisfy {
            (64...940).contains(Int($0[0])) && (64...960).contains(Int($0[1])) && (64...960).contains(Int($0[2]))
        }, ["y_cb_cr_codes": codes.map { $0.map(Int.init) }])
        return buffer
    }
    static func pixel(_ image: CIImage, x: Int, y: Int, pipeline: EnhancementPipeline) -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        pipeline.context.render(image, toBitmap: &values, rowBytes: 16,
                                bounds: CGRect(x: x, y: y, width: 1, height: 1),
                                format: .RGBAf, colorSpace: pipeline.colorSpace)
        return values
    }
    static func patchSamples(_ image: CIImage, pipeline: EnhancementPipeline) -> [[Float]] {
        (0..<4).map { index in
            pixel(image, x: Int(image.extent.width * CGFloat(2 * index + 1) / 8),
                  y: Int(image.extent.height / 2), pipeline: pipeline)
        }
    }
    static func measureColors(_ name: String, image: CIImage, reference: CIImage, pipeline: EnhancementPipeline) {
        let values = patchSamples(image, pipeline: pipeline), truth = patchSamples(reference, pipeline: pipeline)
        let errors = zip(values, truth).flatMap { observed, expected in
            (0..<3).map { Double(observed[$0] - expected[$0]) }
        }
        let rms = sqrt(errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count))
        let maximum = errors.map(abs).max() ?? .infinity
        check("\(name) preserves independent RGB channels and sRGB code values",
              rms < 0.5 / 1023 && maximum <= 1 / 1023,
              ["rgb_rms": rms, "maximum_rgb_error": maximum, "observed_rgba": values, "reference_rgba": truth])
        check("\(name) has opaque finite alpha", values.allSatisfy {
            $0.allSatisfy(\.isFinite) && abs($0[3] - 1) <= 0.0001
        }, ["alpha": values.map { $0[3] }])
    }
    static func row(_ image: CIImage, pipeline: EnhancementPipeline) -> [Float] {
        let width = Int(image.extent.width)
        var values = [Float](repeating: 0, count: width * 4)
        pipeline.context.render(image, toBitmap: &values, rowBytes: width * 16,
                                bounds: CGRect(x: 0, y: 32, width: width, height: 1),
                                format: .RGBAf, colorSpace: pipeline.colorSpace)
        return stride(from: 0, to: values.count, by: 4).map { values[$0] }
    }
    static func measure(_ name: String, image: CIImage, reference: CIImage, pipeline: EnhancementPipeline) {
        let values = row(image, pipeline: pipeline), truth = row(reference, pipeline: pipeline)
        let levels = Set(values.map { Int(($0 * 65535).rounded()) }).count
        let rms = sqrt(zip(values, truth).reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) } / Double(values.count))
        let monotonic = zip(values, values.dropFirst()).allSatisfy { $1 >= $0 - 0.0001 }
        check("\(name) preserves more than 8-bit gradation", levels > 500, ["distinct_levels": levels])
        check("\(name) code-value RMS below half one 10-bit step", rms < 0.5 / 1023, ["rms": rms])
        check("\(name) remains monotonic and SDR bounded", monotonic && values.allSatisfy { $0 >= -0.0001 && $0 <= 1.0001 })
    }
    static func main() throws {
        let pipeline = try EnhancementPipeline(), buffer = try ramp()
        check("10-bit SDR fixture allowed", ColorFrameGate.decision(for: buffer) == .sdr)
        let source = ColorFrameGate.inputImage(for: buffer)!
        let sourceValues = row(source, pipeline: pipeline)
        let sourceLevels = Set(sourceValues.map { Int(($0 * 65535).rounded()) }).count
        check("fixture really has more than 8-bit precision", sourceLevels > 800, ["distinct_levels": sourceLevels])
        let sourceRangeError = sourceValues.enumerated().map { index, value in
            abs(Double(value) - Double(index * 876 / 1023) / 876)
        }.max() ?? .infinity
        check("legal video range decodes to expected full-range SDR codes", sourceRangeError <= 1 / 1023,
              ["maximum_code_error": sourceRangeError, "black": sourceValues.first ?? -1, "white": sourceValues.last ?? -1])
        let frame = try pipeline.process(buffer, mode: .original, time: .zero)
        measure("production SDR render", image: CIImage(mtlTexture: frame.texture, options: [.colorSpace: pipeline.colorSpace])!, reference: source, pipeline: pipeline)
        let command = pipeline.queue.makeCommandBuffer()!
        let scaler = try DetailScaler(device: pipeline.device)
        let texture = try scaler.encode(source, width: 2048, height: 128, context: pipeline.context, command: command)
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? NSError(domain: "GPU", code: 2) }
        let scaled = source.clampedToExtent().transformed(by: CGAffineTransform(scaleX: 2, y: 2))
            .cropped(to: CGRect(x: 0, y: 0, width: 2048, height: 128))
        measure("detail scaling", image: CIImage(mtlTexture: texture, options: [.colorSpace: pipeline.colorSpace])!, reference: scaled, pipeline: pipeline)
        let colorBuffer = try colorPatches()
        check("independent color fixture allowed as SDR", ColorFrameGate.decision(for: colorBuffer) == .sdr)
        let colorSource = ColorFrameGate.inputImage(for: colorBuffer)!
        let sourceColors = patchSamples(colorSource, pipeline: pipeline)
        let fixtureError = zip(sourceColors, patchRGB).flatMap { observed, expected in
            (0..<3).map { abs(Double(observed[$0] - expected[$0])) }
        }.max() ?? .infinity
        check("10-bit YCbCr fixture decodes to intended independent sRGB colors", fixtureError < 3 / 1023,
              ["maximum_rgb_error": fixtureError, "decoded_rgba": sourceColors, "intended_rgb": patchRGB])
        check("decoded color fixture has opaque alpha", sourceColors.allSatisfy { abs($0[3] - 1) <= 0.0001 })
        let colorFrame = try pipeline.process(colorBuffer, mode: .original, time: CMTime(value: 1, timescale: 24))
        measureColors("production SDR color render", image: CIImage(mtlTexture: colorFrame.texture, options: [.colorSpace: pipeline.colorSpace])!, reference: colorSource, pipeline: pipeline)
        let colorCommand = pipeline.queue.makeCommandBuffer()!
        let colorTexture = try scaler.encode(colorSource, width: 2048, height: 128, context: pipeline.context, command: colorCommand)
        colorCommand.commit(); colorCommand.waitUntilCompleted()
        guard colorCommand.status == .completed else { throw colorCommand.error ?? NSError(domain: "GPU-color", code: 2) }
        measureColors("detail scaling color render", image: CIImage(mtlTexture: colorTexture, options: [.colorSpace: pipeline.colorSpace])!, reference: colorSource, pipeline: pipeline)
        let failed = checks.filter { $0["passed"] as? Bool != true }
        let report: [String: Any] = ["passed": failed.isEmpty, "checks": checks, "device": pipeline.device.name,
            "scope": "Tagged 10-bit SDR synthetic ramp and independent RGB/gray color patches; production spatial output and DetailScaler GPU readback, including opaque alpha and sRGB roundtrip. Not HDR, panel bit depth, temporal/FRC precision or end-to-end playback."]
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/repair-precision.json"
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        print("Precision: \(checks.count-failed.count)/\(checks.count); \(path)")
        if !failed.isEmpty { exit(1) }
    }
}
