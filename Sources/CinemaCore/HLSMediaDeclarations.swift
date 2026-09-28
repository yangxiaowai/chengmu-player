import Foundation

/// Declarations read from the outermost HLS master playlist. A declaration is evidence about
/// what a source offers, never proof that this Mac is currently decoding or rendering Dolby.
public struct HLSMediaDeclarations: Codable, Hashable, Sendable {
    public var variants: [HLSVideoDeclaration]
    public var audioRenditions: [HLSAudioRendition]
    public init(variants: [HLSVideoDeclaration] = [], audioRenditions: [HLSAudioRendition] = []) {
        self.variants = variants; self.audioRenditions = audioRenditions
    }
    public var isEmpty: Bool { variants.isEmpty && audioRenditions.isEmpty }
    public var hasHDRVideo: Bool { variants.contains { $0.isHDRVideo } }
    public var hasDolbyVision: Bool { variants.contains { $0.isDolbyVision } }
    /// True only when an E-AC-3 variant is linked to a rendition that declares JOC objects.
    public var hasAtmosDeclaration: Bool {
        variants.contains { variant in
            guard let group = variant.audioGroupID, variant.declaresEAC3 else { return false }
            return audioRenditions.contains { $0.groupID == group && $0.isJOC }
        }
    }
    /// Names of the Dolby-capable variants for user-facing explanations.
    public var dolbyVisionDescriptions: [String] { variants.filter(\.isDolbyVision).map(\.summary) }
}

public struct HLSVideoDeclaration: Codable, Hashable, Sendable {
    public var url: URL
    public var width: Int?
    public var height: Int?
    public var bandwidth: Int
    public var codecs: String?
    public var supplementalCodecs: String?
    public var videoRange: String?
    public var audioGroupID: String?
    public init(url: URL, width: Int?, height: Int?, bandwidth: Int, codecs: String?, supplementalCodecs: String?, videoRange: String?, audioGroupID: String?) {
        self.url = url; self.width = width; self.height = height; self.bandwidth = bandwidth
        self.codecs = codecs; self.supplementalCodecs = supplementalCodecs
        self.videoRange = videoRange; self.audioGroupID = audioGroupID
    }
    public var codecList: [String] {
        (codecs ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
    /// Only the E-AC-3 codec spellings Apple ships in HLS. `ec+3` and lookalikes are not accepted.
    public var declaresEAC3: Bool { codecList.contains { Self.eac3Pattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil } }
    private static let eac3Pattern = try! NSRegularExpression(pattern: "^ec-3(\\.[0-9]+)*$")
    private static let dolbyVisionPattern = try! NSRegularExpression(pattern: "^dv(h1|he)\\.[0-9]+(\\.[0-9]+)*$")
    private static func isDolbyVisionCodec(_ value: String) -> Bool {
        dolbyVisionPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
    /// PQ (HDR10/Dolby Vision) and HLG are the two ranges Apple documents for HDR playback.
    public var isHDRVideo: Bool {
        guard let range = videoRange?.uppercased() else { return false }
        return range == "PQ" || range == "HLG"
    }
    /// A direct `dvh1`/`dvhe` codec, or a supplemental Dolby Vision codec whose compatibility
    /// brand matches the declared base-layer range. Dolby Vision profiles 5 and 8 layer onto
    /// HEVC base layers, so an AVC base is never treated as Dolby Vision.
    public var isDolbyVision: Bool { dolbyVisionEvidence != nil }
    public var dolbyVisionEvidence: String? {
        if let direct = codecList.first(where: Self.isDolbyVisionCodec) { return direct }
        guard let supplemental = supplementalCodecs?.trimmingCharacters(in: .whitespaces), !supplemental.isEmpty else { return nil }
        for entry in supplemental.split(separator: ",") {
            let parts = entry.trimmingCharacters(in: .whitespaces).lowercased().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, Self.isDolbyVisionCodec(parts[0]),
                  codecList.contains(where: { $0.hasPrefix("hvc1") || $0.hasPrefix("hev1") }) else { continue }
            // The compatibility brand says which base-layer range carries the enhancement.
            guard parts[1] == "db1p" || parts[1] == "db4h" else { continue }
            let expectedRange = parts[1] == "db1p" ? "PQ" : "HLG"
            if videoRange?.uppercased() == expectedRange { return parts[0] }
        }
        return nil
    }
    public var summary: String {
        let size = width.map { "\($0)×\(height ?? 0)" } ?? "尺寸未声明"
        let range = videoRange?.uppercased() ?? "范围未声明"
        return "\(size) · \(bandwidth / 1000) kbps · \(range) · \(codecs ?? "编码未声明")"
    }
}

public struct HLSAudioRendition: Codable, Hashable, Sendable {
    public var groupID: String
    public var name: String
    public var language: String?
    public var isDefault: Bool
    public var channels: String?
    public var url: URL?
    public init(groupID: String, name: String, language: String?, isDefault: Bool, channels: String?, url: URL?) {
        self.groupID = groupID; self.name = name; self.language = language
        self.isDefault = isDefault; self.channels = channels; self.url = url
    }
    /// `CHANNELS="16/JOC"` is the only HLS spelling of a Dolby Atmos object-audio rendition.
    /// An unquoted, lowercase or malformed channel list is never treated as object audio.
    public var isJOC: Bool {
        guard let channels = channels?.trimmingCharacters(in: .whitespaces), !channels.contains("\"") else { return false }
        let parts = channels.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "JOC", let count = Int(parts[0]), (1...255).contains(count) else { return false }
        return true
    }
}

enum HLSManifestParser {
    /// Strict `KEY=VALUE` parser. Anything this pattern cannot fully consume, a duplicated
    /// attribute, an unterminated quoted value or a multi-line value is rejected instead of
    /// half-trusted. Unquoted values stop at the next `=`, so a missing closing quote fails.
    static func attributes(_ value: String) throws -> [String: String] {
        let pattern = try! NSRegularExpression(pattern: "([A-Za-z0-9-]+)=(\"[^\"]*\"|[^,=]*)")
        var result: [String: String] = [:]
        var cursor = value.startIndex
        for match in pattern.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let full = Range(match.range, in: value), let key = Range(match.range(at: 1), in: value),
                  let raw = Range(match.range(at: 2), in: value) else { throw SourceError.invalidPlaylist }
            if !value[cursor..<full.lowerBound].allSatisfy({ $0 == "," || $0 == " " }) { throw SourceError.invalidPlaylist }
            cursor = full.upperBound
            let name = String(value[key])
            guard result[name] == nil else { throw SourceError.invalidPlaylist }
            let text = String(value[raw]).trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("\"") {
                guard text.count >= 2, text.hasSuffix("\"") else { throw SourceError.invalidPlaylist }
                result[name] = String(text.dropFirst().dropLast())
            } else {
                result[name] = text
            }
        }
        guard !value[cursor...].contains(where: { $0 != "," && $0 != " " }) else { throw SourceError.invalidPlaylist }
        return result
    }
}
