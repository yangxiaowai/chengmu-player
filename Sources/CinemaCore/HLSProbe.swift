import Foundation

public struct HLSInfo: Codable, Hashable {
    public var url: URL
    public var duration: Double
    public var segmentCount: Int
    public var isComplete: Bool
    /// Playlist declarations only; they are not measured decoded dimensions.
    public var declaredWidth: Int?
    public var declaredHeight: Int?
    public var codecs: String?
    public var encrypted: Bool
    public var firstSegmentURL: URL?
    public init(url: URL, duration: Double, segmentCount: Int, isComplete: Bool, declaredWidth: Int? = nil, declaredHeight: Int? = nil, codecs: String? = nil, encrypted: Bool, firstSegmentURL: URL?) {
        self.url = url; self.duration = duration; self.segmentCount = segmentCount; self.isComplete = isComplete
        self.declaredWidth = declaredWidth; self.declaredHeight = declaredHeight; self.codecs = codecs; self.encrypted = encrypted; self.firstSegmentURL = firstSegmentURL
    }
}
public struct HLSVariant: Hashable {
    public var url: URL
    public var width: Int?
    public var height: Int?
    public var bandwidth: Int
    public var codecs: String?
}

public struct HLSProbe {
    private let client: BoundedHTTPClient
    public init(routing: SourceRequestRouting = .system) { client = BoundedHTTPClient(timeout: 12, maximumBytes: 2 * 1024 * 1024, configuration: routing.configuration()) }
    init(client: BoundedHTTPClient) { self.client = client }
    /// Basic playlist inspection only. Does not fetch media segments or certify playback.
    public func inspect(url: URL) async throws -> HLSInfo {
        var next = url
        var seen = Set<URL>()
        var selected: HLSVariant?
        for _ in 0..<5 {
            try Task.checkCancellation()
            guard seen.insert(next).inserted else { throw SourceError.playlistLoop }
            let (data, finalURL) = try await client.get(next)
            guard let text = String(data: data, encoding: .utf8) else { throw SourceError.invalidPlaylist }
            let choices = try Self.variants(text: text, url: finalURL)
            if let best = choices.first {
                selected = best; next = best.url
                continue
            }
            var info = try Self.parse(text: text, url: finalURL)
            info.declaredWidth = selected?.width; info.declaredHeight = selected?.height; info.codecs = selected?.codecs
            return info
        }
        throw SourceError.playlistDepth
    }
    public static func variants(text: String, url: URL) throws -> [HLSVariant] {
        let lines = try playlistLines(text)
        var pending: [String: String]?
        var result: [HLSVariant] = []
        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") { pending = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count))) }
            else if !line.hasPrefix("#") && !line.isEmpty, let info = pending {
                guard let variantURL = networkURL(line, relativeTo: url) else { throw SourceError.invalidPlaylist }
                let dimensions = info["RESOLUTION"]?.lowercased().split(separator: "x").compactMap { value -> Int? in
                    guard let dimension = Int(value), dimension > 0, dimension <= 16384 else { return nil }; return dimension
                } ?? []
                result.append(HLSVariant(url: variantURL, width: dimensions.count == 2 ? dimensions[0] : nil, height: dimensions.count == 2 ? dimensions[1] : nil, bandwidth: Int(info["BANDWIDTH"] ?? "") ?? 0, codecs: info["CODECS"]))
                pending = nil
            }
        }
        if pending != nil { throw SourceError.invalidPlaylist }
        return result.sorted {
            let a = ($0.width ?? 0) * ($0.height ?? 0), b = ($1.width ?? 0) * ($1.height ?? 0)
            return a == b ? $0.bandwidth > $1.bandwidth : a > b
        }
    }
    public static func parse(text: String, url: URL) throws -> HLSInfo {
        let lines = try playlistLines(text)
        var duration = 0.0, pendingDuration: Double?
        var segments = 0
        var encrypted = false, complete = false
        var firstSegment: URL?
        for line in lines.dropFirst() {
            if line.hasPrefix("#EXTINF:") {
                guard pendingDuration == nil, let value = Double(line.dropFirst(8).split(separator: ",", omittingEmptySubsequences: false).first ?? ""), value.isFinite, value >= 0 else { throw SourceError.invalidPlaylist }
                pendingDuration = value
            } else if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
                let info = attributes(String(line.dropFirst(line.firstIndex(of: ":").map { line.distance(from: line.startIndex, to: $0) + 1 } ?? 0)))
                if let method = info["METHOD"], method != "NONE" { encrypted = true }
            } else if line == "#EXT-X-ENDLIST" { complete = true }
            else if !line.isEmpty && !line.hasPrefix("#") {
                guard let segmentDuration = pendingDuration, let segmentURL = networkURL(line, relativeTo: url) else { throw SourceError.invalidPlaylist }
                if firstSegment == nil { firstSegment = segmentURL }
                segments += 1; duration += segmentDuration; pendingDuration = nil
            }
        }
        guard segments > 0, pendingDuration == nil else { throw SourceError.invalidPlaylist }
        return HLSInfo(url: url, duration: duration, segmentCount: segments, isComplete: complete, encrypted: encrypted, firstSegmentURL: firstSegment)
    }
    private static func playlistLines(_ text: String) throws -> [String] {
        let cleaned = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        let lines = cleaned.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U" else { throw SourceError.invalidPlaylist }
        return lines
    }
    private static func attributes(_ value: String) -> [String: String] {
        // Commas inside quoted CODECS and URI values must stay inside one attribute.
        let regex = try! NSRegularExpression(pattern: "([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)")
        var result: [String: String] = [:]
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            if let key = Range(match.range(at: 1), in: value), let val = Range(match.range(at: 2), in: value) {
                result[String(value[key])] = String(value[val]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return result
    }
}
