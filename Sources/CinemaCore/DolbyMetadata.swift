import Foundation

/// Pure parsing of Dolby signalling bytes. Nothing here proves that media is
/// currently decoded, selected or rendered as Dolby; it only reads the evidence.
public enum DolbyMetadata {
    /// E-AC-3 specific box (`dec3`) as stored in `kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms`.
    /// Returns true only when the whole payload parses under an unambiguous field arrangement and the
    /// AC-3 extension flag reports a JOC (Atmos) bitstream. The reserved fields must be zero and the
    /// framing must be E-AC-3, so a plain 5.1 or stereo E-AC-3 track, a channel count, a 4K
    /// resolution or a stream name never qualifies on its own.
    ///
    /// Deliberately conservative: the width of the dependent-substream channel map is not agreed
    /// across encoders, so a payload that declares dependent substreams is never claimed here even
    /// when it is genuine. Callers therefore pair it with the HLS `CHANNELS="…/JOC"` declaration and
    /// CoreAudio's Atmos channel-layout tags, and report which evidence they actually saw.
    public static func hasAtmosEC3Configuration<Payload: Collection>(_ payload: Payload) -> Bool where Payload.Element == UInt8 {
        let bytes = Array(payload)
        // data_rate(13) num_ind_sub(3), then at least one independent substream.
        guard bytes.count >= 5 else { return false }
        var reader = BitReader(bytes: bytes)
        guard reader.skip(13), let count = reader.read(3) else { return false }
        for _ in 0...Int(count) {
            // fscod(2) bsid(5) reserved(4) bsmod(3) asvc(1) acmod(3) lfeon(1) reserved(3) num_dep_sub(4)
            guard let fscod = reader.read(2), let bsid = reader.read(5), let reserved = reader.read(4),
                  reader.skip(3), reader.skip(1), let acmod = reader.read(3), reader.skip(1),
                  let trailingReserved = reader.read(3), let dependentCount = reader.read(4) else { return false }
            // 3 is a reserved frame size code, only E-AC-3 (bsid 16) carries a JOC extension,
            // acmod above 7 is reserved, and the reserved bits must be zero.
            guard fscod <= 2, bsid == 16, acmod < 8, reserved == 0, trailingReserved == 0 else { return false }
            // Dependent substreams carry an encoder-dependent channel map of uncertain width.
            guard dependentCount == 0 else { return false }
            guard let extensionFlag = reader.read(1) else { return false }
            if extensionFlag == 1 { return true }
        }
        return false
    }

    /// Dolby Vision configuration box (`dvcC`/`dvvC`). A box that is too short or
    /// reports anything other than DV major version 1 is not trusted.
    public static func hasDolbyVisionConfiguration<Payload: Collection>(_ payload: Payload) -> Bool where Payload.Element == UInt8 {
        dolbyVisionProfile(payload) != nil
    }

    /// DV major version, profile, level and the RPU/EL/blending flags, or nil when invalid.
    public static func dolbyVisionProfile<Payload: Collection>(_ payload: Payload) -> DolbyVisionConfiguration? where Payload.Element == UInt8 {
        let bytes = Array(payload)
        guard bytes.count >= 4 else { return nil }
        // dv_version_major(8) dv_version_minor(8) dv_profile(7) dv_level(6)
        // rpu_present(1) el_present(1) bl_present(1) dv_bl_signal_compatibility_id(4)
        let major = bytes[0], minor = bytes[1]
        let profile = bytes[2] >> 1
        let level = ((UInt16(bytes[2] & 0x01) << 5) | UInt16(bytes[3] >> 3))
        let flags = bytes[3] & 0x07
        let compatibility = bytes.count >= 5 ? (bytes[4] >> 4) : 0
        guard major == 1, profile > 0, profile <= 9, level <= 13 else { return nil }
        return DolbyVisionConfiguration(majorVersion: Int(major), minorVersion: Int(minor), profile: Int(profile),
                                        level: Int(level), rpuPresent: flags & 0x04 != 0, enhancementLayerPresent: flags & 0x02 != 0,
                                        baseLayerPresent: flags & 0x01 != 0, compatibilityID: Int(compatibility))
    }
}

public struct DolbyVisionConfiguration: Hashable, Sendable {
    public let majorVersion: Int
    public let minorVersion: Int
    public let profile: Int
    public let level: Int
    public let rpuPresent: Bool
    public let enhancementLayerPresent: Bool
    public let baseLayerPresent: Bool
    public let compatibilityID: Int
    public init(majorVersion: Int, minorVersion: Int, profile: Int, level: Int, rpuPresent: Bool, enhancementLayerPresent: Bool, baseLayerPresent: Bool, compatibilityID: Int) {
        self.majorVersion = majorVersion; self.minorVersion = minorVersion; self.profile = profile; self.level = level
        self.rpuPresent = rpuPresent; self.enhancementLayerPresent = enhancementLayerPresent
        self.baseLayerPresent = baseLayerPresent; self.compatibilityID = compatibilityID
    }
    /// 5 and 8 are the HLS/single-layer profiles Apple documents for native playback.
    public var isSingleLayerCompatible: Bool { profile == 5 || profile == 8 }
}

/// Most-significant-bit-first reader that never reads past the payload.
struct BitReader {
    private let bytes: [UInt8]
    private var position = 0
    init(bytes: [UInt8]) { self.bytes = bytes }
    var bitsRemaining: Int { bytes.count * 8 - position }
    mutating func read(_ count: Int) -> UInt32? {
        guard count >= 0, count <= 32, bitsRemaining >= count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<count {
            let byte = bytes[position >> 3]
            let bit = (byte >> (7 - UInt8(position & 7))) & 1
            value = (value << 1) | UInt32(bit)
            position += 1
        }
        return value
    }
    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, bitsRemaining >= count else { return false }
        position += count
        return true
    }
}
