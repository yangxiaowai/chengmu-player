import Foundation

public struct SubtitleCue: Equatable {
    public let start: Double
    public let end: Double
    public let text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

public enum SubtitleParser {
    public static func parse(_ raw: String) -> [SubtitleCue] {
        let normalized = raw.replacingOccurrences(of: "\u{feff}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.contains("[Events]") { return parseASS(normalized) }
        var cues: [SubtitleCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let index = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[index].components(separatedBy: "-->")
            guard times.count == 2, let start = timestamp(times[0]), let end = timestamp(times[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]), end > start else { continue }
            let text = clean(lines.dropFirst(index + 1).joined(separator: "\n"))
            if !text.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    public static func text(at time: Double, in cues: [SubtitleCue]) -> String {
        guard time.isFinite else { return "" }
        // Sorted starts bound work for long subtitle files; overlapping cues remain visible.
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        return cues[..<low].filter { time < $0.end }.map(\.text).joined(separator: "\n")
    }

    private static func timestamp(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]), h >= 0, m >= 0, m < 60, s >= 0, s < 60 else { return nil }
        return h * 3600 + m * 60 + s
    }
    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func parseASS(_ value: String) -> [SubtitleCue] {
        var result: [SubtitleCue] = []
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var events = false
        for line in value.components(separatedBy: "\n") {
            if line.hasPrefix("[") { events = line == "[Events]"; continue }
            guard events else { continue }
            if line.hasPrefix("Format:") {
                fields = line.dropFirst(7).components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            }
            guard line.hasPrefix("Dialogue:"), let startIndex = fields.firstIndex(of: "start"), let endIndex = fields.firstIndex(of: "end"), let textIndex = fields.firstIndex(of: "text") else { continue }
            let values = line.dropFirst(9).split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false).map(String.init)
            guard values.count == fields.count, textIndex == fields.count - 1, let start = timestamp(values[startIndex]), let end = timestamp(values[endIndex]), end > start else { continue }
            let text = clean(values[textIndex])
            if !text.isEmpty { result.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        return result.sorted { $0.start < $1.start }
    }
}
