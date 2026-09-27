import Foundation

/// Conservative matching: an explicit season and exact normalized title are required.
public enum SourceMatching {
    public static func sameSeasonTitle(_ current: MediaTitle, _ candidate: MediaTitle) -> Bool {
        guard let a = seasonTitle(current.title), let b = seasonTitle(candidate.title), a == b else { return false }
        return current.year.isEmpty || candidate.year.isEmpty || current.year == candidate.year
    }
    public static func candidates(current: MediaTitle, results: [MediaTitle]) -> [MediaTitle] {
        var seen = Set<String>()
        return results.filter {
            let key = $0.providerID + ":" + $0.id
            return !($0.providerID == current.providerID && $0.id == current.id) && sameSeasonTitle(current, $0) && seen.insert(key).inserted
        }
    }
    public static func hasExplicitSeason(_ title: MediaTitle) -> Bool { seasonTitle(title.title) != nil }
    public static func matchEpisode(_ current: Episode, in line: PlaybackLine) -> Episode? {
        let matches = line.episodes.filter {
            $0.number == current.number && episodeName($0.name) == episodeName(current.name)
        }
        return matches.count == 1 ? matches[0] : nil
    }
    private static func compact(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }
    private static func seasonTitle(_ title: String) -> String? {
        let value = compact(title)
        let regex = try! NSRegularExpression(pattern: "第([0-9一二三四五六七八九十零两]+)季|season([0-9]+)", options: .caseInsensitive)
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        guard matches.count == 1, let match = matches.first, let full = Range(match.range, in: value) else { return nil }
        let tokenRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
        guard let range = Range(tokenRange, in: value), let number = seasonNumber(String(value[range])), number > 0 else { return nil }
        return value.replacingCharacters(in: full, with: "season\(number)")
    }
    private static func seasonNumber(_ token: String) -> Int? {
        if let value = Int(token) { return value }
        let digits: [Character: Int] = ["零":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        let chars = Array(token)
        if chars.count == 1 { return token == "十" ? 10 : digits[chars[0]] }
        if let split = chars.firstIndex(of: "十"), chars.count <= 3 {
            let tens = split == 0 ? 1 : (digits[chars[0]] ?? -10)
            let units = split + 1 == chars.count ? 0 : (digits[chars[split + 1]] ?? -100)
            let number = tens * 10 + units
            return number > 0 ? number : nil
        }
        return nil
    }
    private static func episodeName(_ name: String) -> String {
        let value = compact(name)
        let regex = try! NSRegularExpression(pattern: "^(?:第0*([0-9]+)[集话]|e(?:p(?:isode)?)?0*([0-9]+)|0*([0-9]+))$", options: .caseInsensitive)
        guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return value }
        for index in 1...3 {
            if let range = Range(match.range(at: index), in: value), let number = Int(value[range]) { return "episode\(number)" }
        }
        return value
    }
}
