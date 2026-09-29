#!/bin/bash
# Measures what each picture mode actually does to the frame, and what survives the display
# downscale. Guards mean luminance only; noise and ringing have a separate quality harness.
set -euo pipefail
cd "$(dirname "$0")/.."
report="${1:-docs/validation/v0.2.9/picture-modes.json}"
fixture=$(mktemp -d "${TMPDIR:-/tmp/}cinema-picture-modes.XXXXXX")
work=$(mktemp -d "${TMPDIR:-/tmp/}cinema-picture-build.XXXXXX")
trap 'rm -rf "$fixture" "$work"' EXIT
mkdir -p "$(dirname "$report")"

ffmpeg -hide_banner -loglevel error -f lavfi -i "smptebars=size=1920x1080:rate=1:duration=1" -frames:v 1 -y "$fixture/bars.png"
ffmpeg -hide_banner -loglevel error -f lavfi -i "gradients=size=1920x1080:rate=1:duration=1" -frames:v 1 -y "$fixture/gradient.png"

cat > "$work/main.swift" <<'SWIFT'
import Foundation
import AppKit
import CoreImage
import CoreVideo
import Metal
import CinemaCore

@main struct PictureModes {
    static func main() throws {
        let pipeline = try EnhancementPipeline()
        let displayPixels = 2468   // ~1234 pt video area on a 2x Retina panel
        var results: [[String: Any]] = []
        for path in CommandLine.arguments.dropFirst(2) {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            guard let source = NSImage(contentsOfFile: path), let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let width = cg.width, height = cg.height
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
            guard let buffer else { continue }
            pipeline.context.render(CIImage(cgImage: cg), to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: pipeline.colorSpace)

            /// Mean luminance and mean |horizontal neighbour difference| at a given resample width.
            func measure(_ image: CIImage, sampleWidth: Int) -> (luma: Double, acutance: Double) {
                let scale = CGFloat(sampleWidth) / image.extent.width
                let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let sampleHeight = Int(scaled.extent.height)
                var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
                pipeline.context.render(scaled, toBitmap: &pixels, rowBytes: sampleWidth * 4,
                                        bounds: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight), format: .RGBA8, colorSpace: pipeline.colorSpace)
                var luma = 0.0, edge = 0.0
                for y in 0..<sampleHeight {
                    for x in 0..<sampleWidth {
                        let index = (y * sampleWidth + x) * 4
                        let value = 0.299 * Double(pixels[index]) + 0.587 * Double(pixels[index + 1]) + 0.114 * Double(pixels[index + 2])
                        luma += value
                        if x > 0 { edge += abs(value - (0.299 * Double(pixels[index - 4]) + 0.587 * Double(pixels[index - 3]) + 0.114 * Double(pixels[index - 2]))) }
                    }
                }
                let count = Double(sampleWidth * sampleHeight)
                return (luma / count, edge / count)
            }

            for mode in [EnhancementMode.original, .clarity, .upscale4K, .appleAI] {
                guard let frame = try? pipeline.process(buffer, mode: mode, time: .zero) else { continue }
                let image = CIImage(mtlTexture: frame.texture, options: [.colorSpace: pipeline.colorSpace])!
                let full = measure(image, sampleWidth: 1920)
                let shown = measure(image, sampleWidth: displayPixels)
                let reference = mode == .original
                results.append([
                    "fixture": name, "mode": frame.mode, "outputWidth": frame.width, "outputHeight": frame.height,
                    "milliseconds": (frame.milliseconds * 10).rounded() / 10,
                    "meanLuma": (full.luma * 100).rounded() / 100,
                    "detailNative": (full.acutance * 1000).rounded() / 1000,
                    "detailAfterDisplayDownscale": (shown.acutance * 1000).rounded() / 1000,
                    "isReference": reference
                ])
            }
        }
        let output: [String: Any] = [
            "checkedAt": ISO8601DateFormatter().string(from: Date()),
            "scope": "Real EnhancementPipeline on static 1920x1080 fixtures; measures luminance, edge detail and 4K survival through the player's display downscale. Not a subjective quality claim.",
            "displaySampleWidthPixels": displayPixels,
            "results": results
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        // Fail only on colour damage: an enhanced mode must not shift mean luminance by more than 1%.
        var failures: [String] = []
        for fixture in Set(results.compactMap { $0["fixture"] as? String }) {
            let rows = results.filter { $0["fixture"] as? String == fixture }
            guard let base = rows.first(where: { $0["isReference"] as? Bool == true })?["meanLuma"] as? Double else { continue }
            for row in rows where row["isReference"] as? Bool != true {
                if let luma = row["meanLuma"] as? Double, base > 0, abs(luma - base) / base > 0.01 {
                    failures.append("\(fixture) \(row["mode"] ?? "") shifted mean luma \(base) -> \(luma)")
                }
            }
        }
        if failures.isEmpty {
            print("PASS picture modes: mean luminance stable on these clean fixtures; noise and detail quality are checked separately")
            for row in results { print("  \(row["fixture"] ?? "") \(row["mode"] ?? "") \(row["outputWidth"] ?? 0)x\(row["outputHeight"] ?? 0) luma=\(row["meanLuma"] ?? 0) detail=\(row["detailNative"] ?? 0) shown=\(row["detailAfterDisplayDownscale"] ?? 0)") }
        } else {
            failures.forEach { print("FAIL \($0)") }
            exit(1)
        }
    }
}
SWIFT

swiftc -emit-module -emit-library -module-name CinemaCore -swift-version 5 -target arm64-apple-macos15.0 Sources/CinemaCore/*.swift -o "$work/libCinemaCore.dylib" -emit-module-path "$work/CinemaCore.swiftmodule"
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -I "$work" -L "$work" -lCinemaCore -Xlinker -rpath -Xlinker "$work" Sources/CinemaApp/EnhancementPipeline.swift Sources/CinemaApp/TemporalRestorer.swift Sources/CinemaApp/DetailScaler.swift "$work/main.swift" -o "$work/check"
"$work/check" "$report" "$fixture/bars.png" "$fixture/gradient.png"
