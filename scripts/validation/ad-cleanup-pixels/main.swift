import Foundation
import AVFoundation
import CoreImage
import CinemaCore

let pipeline = try EnhancementPipeline()
var buffer: CVPixelBuffer?
let width = 320, height = 180
CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
let extent = CGRect(x: 0, y: 0, width: width, height: height)
let checker = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputWidth": 4.0, "inputColor0": CIColor(red: 0.05, green: 0.08, blue: 0.12), "inputColor1": CIColor(red: 0.9, green: 0.85, blue: 0.7)])!.outputImage!.cropped(to: extent)
let caption = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 55, y: 10, width: 210, height: 12))
let source = caption.composited(over: checker)
pipeline.context.render(source, to: buffer!, bounds: extent, colorSpace: pipeline.colorSpace)
CVBufferSetAttachment(buffer!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
CVBufferSetAttachment(buffer!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
let region = NormalizedVideoRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
let settings = AdCleanupSettings(enabled: true, regions: [region])
func bytes(_ frame: EnhancedFrame) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
    let image = CIImage(mtlTexture: frame.texture, options: [.colorSpace: pipeline.colorSpace])!.oriented(.downMirrored)
    pipeline.context.render(image, toBitmap: &output, rowBytes: frame.width * 4, bounds: CGRect(x: 0, y: 0, width: frame.width, height: frame.height), format: .RGBA8, colorSpace: pipeline.colorSpace)
    return output
}
var cases: [[String: Any]] = []
for (mode, transform) in [(EnhancementMode.original, CGAffineTransform.identity), (.clarity, .identity), (.upscale4K, .identity), (.original, CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0))] {
    let baseline = try pipeline.process(buffer!, mode: mode, time: .zero, displayTransform: transform)
    let cleaned = try pipeline.process(buffer!, mode: mode, time: .zero, displayTransform: transform, cleanup: settings)
    let original = bytes(baseline), changed = bytes(cleaned)
    let rectangle = AdCleanupPolicy.pixelRect(region, width: baseline.width, height: baseline.height)!
    var insideChanges = 0, outsideChanges = 0, protectedChanges = 0, outsideMaximumDifference = 0
    var outsideBounds = CGRect.null
    let protected = AdCleanupPolicy.pixelRect(AdCleanupSettings.defaultProtection, width: baseline.width, height: baseline.height)!
    for y in 0..<baseline.height {
        for x in 0..<baseline.width {
            let index = (y * baseline.width + x) * 4
            guard original[index..<index+4] != changed[index..<index+4] else { continue }
            let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
            if rectangle.contains(point) { insideChanges += 1 } else {
                outsideChanges += 1
                outsideBounds = outsideBounds.union(CGRect(x: x, y: y, width: 1, height: 1))
                for channel in 0..<4 { outsideMaximumDifference = max(outsideMaximumDifference, abs(Int(original[index + channel]) - Int(changed[index + channel]))) }
            }
            if protected.contains(point) { protectedChanges += 1 }
        }
    }
    if outsideChanges > 0 {
        let diagnostic = "\(mode.rawValue) \(baseline.width)x\(baseline.height) outside=\(outsideChanges) maxDelta=\(outsideMaximumDifference) bounds=\(outsideBounds) protected=\(protectedChanges)\n"
        FileHandle.standardError.write(Data(diagnostic.utf8))
    }
    assert(insideChanges > 0, "No real blur inside selected region")
    assert(outsideChanges == 0, "Cleanup changed pixels outside selection: \(outsideChanges)")
    assert(protectedChanges == 0, "Cleanup changed subtitle pixels")
    assert(cleaned.cleanupAppliedRegions == 1)
    let disabled = try pipeline.process(buffer!, mode: mode, time: .zero, displayTransform: transform, cleanup: AdCleanupSettings(regions: [region]))
    assert(bytes(disabled) == original, "Disabled cleanup differs from baseline")
    let conflict = AdCleanupSettings(enabled: true, regions: [NormalizedVideoRect(x: 0.1, y: 0.65, width: 0.3, height: 0.25)])
    let rejected = try pipeline.process(buffer!, mode: mode, time: .zero, displayTransform: transform, cleanup: conflict)
    assert(bytes(rejected) == original && rejected.cleanupAppliedRegions == 0 && rejected.cleanupRejectedRegions == 1, "Conflicting region must be rejected completely")
    let invalid = AdCleanupSettings(enabled: true, regions: [region], protectedRegions: [NormalizedVideoRect(x: 0, y: .nan, width: 1, height: 0.1)])
    let closed = try pipeline.process(buffer!, mode: mode, time: .zero, displayTransform: transform, cleanup: invalid)
    assert(bytes(closed) == original && closed.cleanupAppliedRegions == 0, "Invalid protection must fail closed")
    cases.append(["mode": mode.rawValue, "rotated": !transform.isIdentity, "output": [baseline.width, baseline.height], "inside_changed_pixels": insideChanges, "outside_changed_pixels": outsideChanges, "outside_maximum_channel_difference": outsideMaximumDifference, "protected_changed_pixels": protectedChanges, "disabled_equals_baseline": true, "whole_conflict_rejected": true, "invalid_protection_fail_closed": true, "processing_ms": cleaned.milliseconds])
}
// Hold selected pixels fixed and change every surrounding pixel: the blur must not sample outside its crop.
let sampleRect = AdCleanupPolicy.pixelRect(region, width: width, height: height)!
func samplingFixture(_ color: CIColor) throws -> [UInt8] {
    let outside = CIImage(color: color).cropped(to: extent)
    let fixedPatch = checker.cropped(to: sampleRect)
    pipeline.context.render(fixedPatch.composited(over: outside), to: buffer!, bounds: extent, colorSpace: pipeline.colorSpace)
    return bytes(try pipeline.process(buffer!, mode: .original, time: .zero, cleanup: settings))
}
let redOutside = try samplingFixture(CIColor(red: 1, green: 0, blue: 0))
let blueOutside = try samplingFixture(CIColor(red: 0, green: 0, blue: 1))
var samplingDifferences = 0
for y in Int(sampleRect.minY)..<Int(sampleRect.maxY) {
    for x in Int(sampleRect.minX)..<Int(sampleRect.maxX) {
        let offset = (y * width + x) * 4
        if redOutside[offset..<offset+4] != blueOutside[offset..<offset+4] { samplingDifferences += 1 }
    }
}
assert(samplingDifferences == 0, "Blur sampled pixels outside selected rectangle")
// An asymmetric patch catches a source import or destination blit that flips Y. The selected
// rectangle is deliberately off-centre, with red below blue in Core Image coordinates.
let splitY = sampleRect.midY
let redHalf = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: sampleRect.minX, y: sampleRect.minY, width: sampleRect.width, height: splitY - sampleRect.minY))
let blueHalf = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: sampleRect.minX, y: splitY, width: sampleRect.width, height: sampleRect.maxY - splitY))
let asymmetric = blueHalf.composited(over: redHalf.composited(over: checker))
pipeline.context.render(asymmetric, to: buffer!, bounds: extent, colorSpace: pipeline.colorSpace)
let asymmetricResult = bytes(try pipeline.process(buffer!, mode: .original, time: .zero, cleanup: settings))
let sampleX = Int(sampleRect.midX), lowerY = Int(sampleRect.minY + sampleRect.height * 0.2), upperY = Int(sampleRect.minY + sampleRect.height * 0.8)
let lowerOffset = (lowerY * width + sampleX) * 4, upperOffset = (upperY * width + sampleX) * 4
assert(Int(asymmetricResult[lowerOffset]) > Int(asymmetricResult[lowerOffset + 2]) + 100, "Selected lower red pixels flipped vertically")
assert(Int(asymmetricResult[upperOffset + 2]) > Int(asymmetricResult[upperOffset]) + 100, "Selected upper blue pixels flipped vertically")
// Every patch samples the same immutable base. In overlaps the last selection wins, exactly
// matching that selection rendered alone; it must not blur an already softened earlier patch.
let secondRegion = NormalizedVideoRect(x: 0.3, y: 0.2, width: 0.25, height: 0.25)
let secondRect = AdCleanupPolicy.pixelRect(secondRegion, width: width, height: height)!
let multiBase = bytes(try pipeline.process(buffer!, mode: .original, time: .zero))
let firstOnly = asymmetricResult
let secondOnly = bytes(try pipeline.process(buffer!, mode: .original, time: .zero, cleanup: AdCleanupSettings(enabled: true, regions: [secondRegion])))
let forward = bytes(try pipeline.process(buffer!, mode: .original, time: .zero, cleanup: AdCleanupSettings(enabled: true, regions: [region, secondRegion])))
let reverse = bytes(try pipeline.process(buffer!, mode: .original, time: .zero, cleanup: AdCleanupSettings(enabled: true, regions: [secondRegion, region])))
var forwardMismatches = 0, reverseMismatches = 0
for y in 0..<height { for x in 0..<width {
    let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), offset = (y * width + x) * 4
    let expectedForward = secondRect.contains(point) ? secondOnly : sampleRect.contains(point) ? firstOnly : multiBase
    let expectedReverse = sampleRect.contains(point) ? firstOnly : secondRect.contains(point) ? secondOnly : multiBase
    if forward[offset..<offset+4] != expectedForward[offset..<offset+4] { forwardMismatches += 1 }
    if reverse[offset..<offset+4] != expectedReverse[offset..<offset+4] { reverseMismatches += 1 }
} }
assert(forwardMismatches == 0 && reverseMismatches == 0, "Multiple regions sampled a mutated base or wrote outside their union")
var samples: [Double] = []
for index in 0..<60 { samples.append(try pipeline.process(buffer!, mode: .original, time: CMTime(value: Int64(index), timescale: 30), cleanup: settings).milliseconds) }
let report: [String: Any] = ["version": "0.3.2", "device": pipeline.device.name, "scope": "Synthetic SDR checkerboard, caption blocks, asymmetric red/blue selection and overlapping selections; exact RGBA8 GPU output comparisons. Not OCR, background reconstruction, or network playback validation", "display_geometry_policy": "Full clean aperture, square pixels, and transformed/presentation aspect agreement required; otherwise cleanup falls back", "sampling_isolation_changed_pixels": samplingDifferences, "asymmetric_selection_orientation_preserved": true, "overlapping_forward_mismatched_pixels": forwardMismatches, "overlapping_reverse_mismatched_pixels": reverseMismatches, "texture_readback_coordinates": "MTL texture readback is downMirrored into Core Image bottom-left coordinates before comparison", "cases": cases, "original_cleanup_60_frames_mean_ms": samples.reduce(0,+) / Double(samples.count), "passed": true]
print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
