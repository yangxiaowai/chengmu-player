import Foundation
import AVFoundation
import CoreImage
import CoreVideo

/// Small deterministic colour checks and two real decoded frames; no enhancement benchmark.
@main struct UnspecifiedSDRSmoke {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail])
            print(passed ? "PASS" : "FAIL", name, detail)
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let report = URL(fileURLWithPath: CommandLine.arguments[2])
        let cases: [(String, String?, String?, String?, Bool)] = [
            ("unspecified_709", "ColorPrimaries#2", "ITU_R_709_2", "ITU_R_709_2", true),
            ("unspecified_srgb", "ColorPrimaries#2", "IEC_sRGB", "ITU_R_709_2", true),
            ("missing_primaries_709", nil, "ITU_R_709_2", "ITU_R_709_2", true),
            ("known_709", "ITU_R_709_2", "ITU_R_709_2", "ITU_R_709_2", true),
            ("unknown_transfer", "ITU_R_709_2", "TransferFunction#2", "ITU_R_709_2", false),
            ("missing_transfer", "ITU_R_709_2", nil, "ITU_R_709_2", false),
            ("no_colour_tags", nil, nil, nil, false),
            ("pq_unspecified", "ColorPrimaries#2", "SMPTE_ST_2084_PQ", "ITU_R_709_2", false),
            ("hlg_unspecified", "ColorPrimaries#2", "ITU_R_2100_HLG", "ITU_R_709_2", false),
            ("wide_2020", "ITU_R_2020", "ITU_R_709_2", "ITU_R_2020", false),
            ("wide_p3", "P3_D65", "IEC_sRGB", "ITU_R_709_2", false),
            ("other_primaries", "ColorPrimaries#99", "ITU_R_709_2", "ITU_R_709_2", false),
            ("unspecified_wide_matrix", "ColorPrimaries#2", "ITU_R_709_2", "ITU_R_2020", false),
        ]
        for (name, primaries, transfer, matrix, allowed) in cases {
            let buffer = try makeBuffer()
            tag(buffer, primaries: primaries, transfer: transfer, matrix: matrix)
            let decision = ColorFrameGate.decision(for: buffer)
            check(name, !decision.blocksEnhancement == allowed, String(describing: decision))
#if !UNSPECIFIED_SDR_BASELINE
            check(name + "_image_permission", (ColorFrameGate.inputImage(for: buffer) != nil) == allowed)
#endif
        }

#if !UNSPECIFIED_SDR_BASELINE
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
        for transfer in ["ITU_R_709_2", "IEC_sRGB", "Linear", "SMPTE_240M_1995"] {
            let buffer = try makeBuffer()
            tag(buffer, primaries: "ColorPrimaries#2", transfer: transfer, matrix: "ITU_R_709_2")
            let before = attachments(buffer)
            let normalized = ColorFrameGate.inputImage(for: buffer)
            let actual = normalized.map { pixels($0, context: context) }
            check(transfer + "_source_attachments_unchanged", NSDictionary(dictionary: before).isEqual(to: attachments(buffer)))
            check(transfer + "_assumption_visible", ColorFrameGate.assumptionNote(for: buffer)?.contains("709") == true)
            // Change only the test-owned reference's primaries after the normalized render finishes.
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            let expected = pixels(CIImage(cvPixelBuffer: buffer), context: context)
            let error = actual.map { maximumDifference($0, expected) } ?? 255
            check(transfer + "_render_matches_tagged_reference", error <= 1, "max channel difference=\(error)/255")
            check(transfer + "_known_has_no_assumption", ColorFrameGate.assumptionNote(for: buffer) == nil)
        }
#endif

        // The MP4 contains H.264 VUI primaries=2/transfer=1/matrix=1; AVFoundation may fill in 709.
        // The HLS uses primaries=2/transfer=13/matrix=1 and preserves missing primaries on this host.
        // A separate tagged H.264 file has the same source bars and encoder settings.
        let decoded = try await readFirstFrame(folder.appendingPathComponent("unspecified.mp4"))
        check("h264_sdr_decoded_metadata", attachment(decoded, kCVImageBufferTransferFunctionKey) == "ITU_R_709_2",
              colourSummary(decoded))
        check("h264_explicit_sdr_is_allowed", !ColorFrameGate.decision(for: decoded).blocksEnhancement)
#if !UNSPECIFIED_SDR_BASELINE
        let reference = try await readFirstFrame(folder.appendingPathComponent("reference.mp4"))
        let decodedBefore = attachments(decoded)
        let actual = ColorFrameGate.inputImage(for: decoded).map { pixels($0, context: context) }
        let expected = pixels(CIImage(cvPixelBuffer: reference), context: context)
        let difference = actual.map { maximumDifference($0, expected) } ?? 255
        check("h264_yuv_render_matches_tagged_reference", difference <= 1, "max channel difference=\(difference)/255")
        check("h264_source_attachments_unchanged", NSDictionary(dictionary: decodedBefore).isEqual(to: attachments(decoded)))
        // Exercise an actual decoded ten-bit YUV frame with the source's unspecified code point.
        // This test-owned frame is changed deliberately; the production helper must not change it.
        CVBufferSetAttachment(decoded, kCVImageBufferColorPrimariesKey, "ColorPrimaries#2" as CFString, .shouldPropagate)
        let rawTags = attachments(decoded)
        let normalizedYUV = ColorFrameGate.inputImage(for: decoded).map { pixels($0, context: context) }
        let yuvDifference = normalizedYUV.map { maximumDifference($0, expected) } ?? 255
        check("ten_bit_yuv_unspecified_render_matches_reference", yuvDifference <= 1, "max channel difference=\(yuvDifference)/255")
        check("ten_bit_yuv_unspecified_attachments_unchanged", NSDictionary(dictionary: rawTags).isEqual(to: attachments(decoded)))
        check("ten_bit_yuv_assumption_visible", ColorFrameGate.assumptionNote(for: decoded)?.contains("709") == true)
        let lostTransfer = try await readFirstFrame(folder.appendingPathComponent("unspecified-srgb.mp4"))
        check("decoder_missing_transfer_stays_native", attachment(lostTransfer, kCVImageBufferTransferFunctionKey) == nil && ColorFrameGate.decision(for: lostTransfer).blocksEnhancement,
              colourSummary(lostTransfer))
#endif
        if CommandLine.arguments.count > 3, let url = URL(string: CommandLine.arguments[3]) {
            let hls = try await readHLSFrame(url)
            let hlsPrimaries = attachment(hls, kCVImageBufferColorPrimariesKey)?.uppercased()
            check("hls_has_unspecified_primaries_and_sdr_transfer", (hlsPrimaries == nil || hlsPrimaries == "COLORPRIMARIES#2") && attachment(hls, kCVImageBufferTransferFunctionKey) == "IEC_sRGB",
                  colourSummary(hls))
            check("hls_explicit_sdr_is_allowed", !ColorFrameGate.decision(for: hls).blocksEnhancement)
#if !UNSPECIFIED_SDR_BASELINE
            let hlsBefore = attachments(hls)
            let hlsReference = try await readHLSFrame(url.deletingLastPathComponent().appendingPathComponent("reference.m3u8"))
            let hlsExpected = pixels(CIImage(cvPixelBuffer: hlsReference), context: context)
            let hlsActual = ColorFrameGate.inputImage(for: hls).map { pixels($0, context: context) }
            let hlsDifference = hlsActual.map { maximumDifference($0, hlsExpected) } ?? 255
            check("hls_yuv_render_matches_tagged_reference", hlsDifference <= 1, "max channel difference=\(hlsDifference)/255")
            check("hls_source_attachments_unchanged", NSDictionary(dictionary: hlsBefore).isEqual(to: attachments(hls)))
#endif
        }
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let data = try JSONSerialization.data(withJSONObject: ["passed": passed, "scope": "synthetic gates, small Core Image renders, one local H264 MP4 frame and one localhost HLS frame", "checks": checks], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: report)
        exit(passed ? 0 : 1)
    }

    static func tag(_ buffer: CVPixelBuffer, primaries: String?, transfer: String?, matrix: String?) {
        for (key, value) in [(kCVImageBufferColorPrimariesKey, primaries), (kCVImageBufferTransferFunctionKey, transfer), (kCVImageBufferYCbCrMatrixKey, matrix)] {
            if let value { CVBufferSetAttachment(buffer, key, value as CFString, .shouldPropagate) }
            else { CVBufferRemoveAttachment(buffer, key) }
        }
    }
    static func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> String? { CVBufferCopyAttachment(buffer, key, nil) as? String }
    static func attachments(_ buffer: CVPixelBuffer) -> [String: Any] { CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] ?? [:] }
    static func colourSummary(_ buffer: CVPixelBuffer) -> String {
        "primaries=\(attachment(buffer, kCVImageBufferColorPrimariesKey) ?? "nil") transfer=\(attachment(buffer, kCVImageBufferTransferFunctionKey) ?? "nil") matrix=\(attachment(buffer, kCVImageBufferYCbCrMatrixKey) ?? "nil") pixelFormat=\(CVPixelBufferGetPixelFormatType(buffer))"
    }
    static func makeBuffer() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &result) == kCVReturnSuccess, let result else { throw failure("buffer creation") }
        CVPixelBufferLockBaseAddress(result, [])
        let pointer = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(result)
        for y in 0..<32 { for x in 0..<32 {
            let p = pointer.advanced(by: y * stride + x * 4)
            p[0] = UInt8(x * 7); p[1] = UInt8(y * 7); p[2] = UInt8((x + y) * 3); p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }
    static func pixels(_ image: CIImage, context: CIContext) -> [UInt8] {
        let bounds = image.extent.integral
        let width = Int(bounds.width), height = Int(bounds.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return bytes
    }
    static func maximumDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return 255 }
        return zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }
    static func readFirstFrame(_ url: URL) async throws -> CVPixelBuffer {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw failure("no track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: ColorFrameGate.outputPixelFormat, AVVideoAllowWideColorKey: true])
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else { throw failure("decode failed: \(String(describing: reader.error))") }
        reader.cancelReading()
        return buffer
    }
    @MainActor static func readHLSFrame(_ url: URL) async throws -> CVPixelBuffer {
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, AVVideoAllowWideColorKey: true])
        item.add(output)
        let player = AVPlayer(playerItem: item); player.isMuted = true
        defer { player.pause(); item.remove(output) }
        player.playImmediately(atRate: 1)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            var time = CMTime.invalid
            if let frame = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: &time) { return frame }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw failure("HLS frame timeout: \(String(describing: item.error))")
    }
    static func failure(_ text: String) -> Error { NSError(domain: "UnspecifiedSDRSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
