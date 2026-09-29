import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import CinemaCore

/// What the current source allows the GPU enhancement path to do. A permission is granted per
/// item, never globally: the same view can be reconfigured when the episode changes.
enum VideoProcessingPermission: Equatable {
    /// Only SDR frames may be inspected and processed; anything else stays on the native layer.
    case inspectSDRFrames
    /// The whole item stays on the system's native playback layer.
    case nativeOnly(String)

    var nativeReason: String? { if case .nativeOnly(let reason) = self { return reason }; return nil }
}

/// Why a decoded frame cannot enter the SDR enhancement path.
enum ColorFrameGate {
    enum Decision: Equatable {
        case sdr
        /// Valid HDR/Dolby frames: they must never pass through the SDR enhancement pipeline.
        case hdr(String)
        /// Unreadable or unknown signalling. Treated as HDR so nothing is silently converted.
        case unknown(String)
        var blocksEnhancement: Bool { self != .sdr }
        var reason: String? { switch self { case .sdr: return nil; case .hdr(let value), .unknown(let value): return value } }
    }

    /// Pixel formats the surface is allowed to request. 10-bit biplanar video range keeps BT.709
    /// precision and leaves the wide-gamut conversion to the GPU.
    static let outputPixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    static func decision(for buffer: CVPixelBuffer) -> Decision {
        let type = CVPixelBufferGetPixelFormatType(buffer)
        guard type == outputPixelFormat || type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || type == kCVPixelFormatType_32BGRA else {
            return .unknown("解码帧格式未验证（\(fourCC(type))），保留原片播放")
        }
        let transfer = attachment(buffer, kCVImageBufferTransferFunctionKey)
        let primaries = attachment(buffer, kCVImageBufferColorPrimariesKey)
        let matrix = attachment(buffer, kCVImageBufferYCbCrMatrixKey)
        let sdrPrimaries: Set<String> = ["ITU_R_709_2", "SMPTE_C", "EBU_3213_E"]
        if let transfer, ["SMPTE_ST_2084_PQ", "ITU_R_2100_HLG", "SMPTE_ST_428_1", "ITU_R_2020"].contains(transfer) {
            return .hdr("片源为 HDR（\(transfer)），使用系统原生杜比/HDR 呈现")
        }
        if let primaries, primaries.contains("2020") || primaries.contains("P3") {
            return .hdr("片源色域为 \(primaries)，超出 SDR 增强范围，保留原片色彩")
        }
        if let matrix, matrix.contains("2020") || matrix.contains("P3") {
            return .hdr("片源色彩矩阵为 \(matrix)，超出 SDR 增强范围，保留原片色彩")
        }
        if CVBufferCopyAttachment(buffer, kCVImageBufferLogTransferFunctionKey, nil) != nil {
            return .unknown("片源使用 Log 传输函数，保留原片色彩")
        }
        guard let transfer else {
            return .unknown("片源未标记传输函数，保留原片色彩")
        }
        guard ["ITU_R_709_2", "SMPTE_240M_1995", "LINEAR", "SRGB", "IEC_SRGB"].contains(transfer) else {
            return .unknown("片源传输函数未验证（\(transfer)），保留原片色彩")
        }
        if let primaries, !sdrPrimaries.contains(primaries) {
            guard primaries == "COLORPRIMARIES#2" else {
                return .unknown("片源色域未确认（\(primaries)），保留原片色彩")
            }
        }
        if hasUnspecifiedPrimaries(buffer) {
            // Code point 2 means unspecified, not HDR. Only an explicit SDR curve permits this
            // compatibility interpretation; it is reported to the viewer rather than called native 709.
            // YCbCr conversion still uses the buffer's matrix, so never guess an unknown matrix.
            if type != kCVPixelFormatType_32BGRA,
               !["ITU_R_709_2", "ITU_R_601_4", "SMPTE_240M_1995"].contains(matrix ?? "") {
                return .unknown("片源色彩矩阵未确认，保留原片色彩")
            }
            guard assumedColorSpace(for: buffer) != nil else {
                return .unknown("无法建立 SDR 色彩解释，保留原片色彩")
            }
        }
        return .sdr
    }

    /// A missing/unspecified primaries tag is an assumption, never proof of the original gamut.
    static func assumptionNote(for buffer: CVPixelBuffer) -> String? {
        decision(for: buffer) == .sdr && hasUnspecifiedPrimaries(buffer) ? "色域未指定，按 SDR BT.709 原色处理" : nil
    }

    /// Do not rewrite attachments on the AVPlayer-owned buffer. Override only Core Image's input
    /// RGB colour space; its YCbCr decoding continues to use the verified original matrix/range.
    /// Preserve the declared transfer curve (e.g. sRGB), instead of assigning BT.709 gamma to it.
    static func inputImage(for buffer: CVPixelBuffer) -> CIImage? {
        guard decision(for: buffer) == .sdr else { return nil }
        guard hasUnspecifiedPrimaries(buffer) else { return CIImage(cvPixelBuffer: buffer) }
        guard let colorSpace = assumedColorSpace(for: buffer) else { return nil }
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: colorSpace])
    }

    private static func hasUnspecifiedPrimaries(_ buffer: CVPixelBuffer) -> Bool {
        let primaries = attachment(buffer, kCVImageBufferColorPrimariesKey)
        return primaries == nil || primaries == "COLORPRIMARIES#2"
    }

    private static func assumedColorSpace(for buffer: CVPixelBuffer) -> CGColorSpace? {
        guard let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) else { return nil }
        // Build a separate dictionary: inherited ICC/CGColorSpace entries must not override the
        // explicit compatibility interpretation. The original pixel buffer remains untouched.
        let tags: [String: Any] = [
            kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey as String: transfer,
            kCVImageBufferYCbCrMatrixKey as String: CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) ?? kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ]
        return CVImageBufferCreateColorSpaceFromAttachments(tags as CFDictionary)?.takeRetainedValue()
    }

    /// Whether an assessed asset already carries Dolby Vision or HDR signalling. This runs before
    /// any enhancement output is attached, so an unverified item never receives an SDR processing path.
    static func assetDecision(format: CMFormatDescription?, isVideoTrack: Bool = true) -> Decision {
        guard isVideoTrack else { return .unknown("当前轨道不是视频轨道") }
        guard let format else { return .sdr }
        switch CMFormatDescriptionGetMediaSubType(format) {
        case kCMVideoCodecType_DolbyVisionHEVC:
            return .hdr("片源为 Dolby Vision（dvh1），使用系统原生呈现")
        default: break
        }
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        if let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] {
            for name in ["dvcC", "dvvC"] where atoms[name] is Data {
                return .hdr("片源携带 Dolby Vision 配置（\(name)），使用系统原生呈现")
            }
        }
        if let transfer = extensionValue(format, kCMFormatDescriptionExtension_TransferFunction) {
            if transfer.contains("2084") || transfer.contains("2100_HLG") || transfer.contains("428") {
                return .hdr("片源为 HDR（\(transfer)），使用系统原生呈现")
            }
        }
        if let primaries = extensionValue(format, kCMFormatDescriptionExtension_ColorPrimaries), primaries.contains("2020") {
            return .hdr("片源色域为 \(primaries)，保留原片色彩")
        }
        // HEVC without explicit signalling may still be SDR-compatible Dolby Vision, so it stays native.
        if CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC,
           extensionValue(format, kCMFormatDescriptionExtension_TransferFunction) == nil {
            return .unknown("HEVC 片源缺少色彩标记，保留原生播放")
        }
        return .sdr
    }

    private static func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> String? {
        (CVBufferCopyAttachment(buffer, key, nil) as? String)?.uppercased()
    }
    private static func extensionValue(_ format: CMFormatDescription, _ key: CFString) -> String? {
        guard let value = CMFormatDescriptionGetExtension(format, extensionKey: key) else { return nil }
        return String(describing: value).uppercased()
    }
    private static func fourCC(_ value: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", value)
    }
}
