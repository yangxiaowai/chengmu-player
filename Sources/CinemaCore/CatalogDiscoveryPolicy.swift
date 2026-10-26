import Foundation

public enum CatalogContentFilter: String, CaseIterable, Identifiable {
    case all, feature, commentary, trailer, shortDrama
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: return "全部内容"
        case .feature: return "影片与剧集"
        case .commentary: return "解说"
        case .trailer: return "预告"
        case .shortDrama: return "短剧"
        }
    }
}

/// Directory hints affect presentation only; unknown categories remain visible.
public enum CatalogDiscoveryPolicy {
    public static func matches(_ title: MediaTitle, filter: CatalogContentFilter) -> Bool {
        filter == .all || kind(title) == filter
    }

    public static func rank(_ groups: [MediaGroup], query: String) -> [MediaGroup] {
        let query = CatalogGrouping.normalizedTitle(query)
        guard !query.isEmpty else { return groups }
        let requestedKind = titleKind(query) ?? markerKinds.first { $0.markers.contains(query) }?.kind
        let querySeason = season(query)
        let scored = groups.enumerated().map { index, group in
            let score = group.sources.map { title in
                rankKey(title, query: query, querySeason: querySeason, requestedKind: requestedKind)
            }.min { $0.lexicographicallyPrecedes($1) } ?? [1, 1, 3, 5]
            return (index: index, group: group, score: score)
        }
        return scored.sorted { left, right in
            if left.score != right.score { return left.score.lexicographicallyPrecedes(right.score) }
            return left.index < right.index
        }.map(\.group)
    }

    private static let markerKinds: [(kind: CatalogContentFilter, markers: [String])] = [
        (.commentary, ["影视解说", "电影解说", "解说"]),
        (.trailer, ["预告片", "预告"]),
        (.shortDrama, ["微短剧", "短剧"])
    ]

    private static func kind(_ title: MediaTitle) -> CatalogContentFilter {
        // A title marker is more specific than a provider's broad category.
        if let marked = titleKind(CatalogGrouping.normalizedTitle(title.title)) { return marked }
        let category = CatalogGrouping.normalizedTitle(title.category ?? "")
        for entry in markerKinds where entry.markers.contains(where: { category.contains($0) }) { return entry.kind }
        return .feature
    }

    private static func titleKind(_ title: String) -> CatalogContentFilter? {
        for entry in markerKinds {
            for marker in entry.markers {
                // Delimited labels and trailing labels are positive hints. A word
                // inside a title, such as 预告犯 or 王牌解说员, is not a label.
                if title.count > marker.count && title.hasSuffix(marker) { return entry.kind }
                if title.hasPrefix(marker + ":") { return entry.kind }
                for brackets in [("【", "】"), ("[", "]"), ("(", ")"), ("（", "）")] {
                    if title.contains(brackets.0 + marker + brackets.1) { return entry.kind }
                }
            }
        }
        return nil
    }

    private static func rankKey(_ title: MediaTitle, query: String, querySeason: Season?, requestedKind: CatalogContentFilter?) -> [Int] {
        let name = CatalogGrouping.normalizedTitle(title.title)
        let titleSeason = season(name)
        let canonicalName = titleSeason?.canonical ?? name
        let canonicalQuery = querySeason?.canonical ?? query
        let relation: Int
        if canonicalName == canonicalQuery { relation = 0 }
        else if canonicalName.hasPrefix(canonicalQuery) { relation = 1 }
        else if canonicalName.contains(canonicalQuery) { relation = 2 }
        else if let querySeason, (titleSeason?.base ?? name) == querySeason.base { relation = 3 }
        else if let querySeason, (titleSeason?.base ?? name).contains(querySeason.base) { relation = 4 }
        else { relation = 5 }
        let content = kind(title)
        let kindPenalty = requestedKind.map { content == $0 ? 0 : 1 } ?? (content == .feature ? 0 : 1)
        let seasonPenalty: Int
        if let querySeason {
            seasonPenalty = titleSeason.map { $0.number == querySeason.number ? 0 : 2 } ?? 1
        } else { seasonPenalty = 0 }
        // Relevant features precede derived content for ordinary title searches.
        // Unrelated provider results stay available, after every relevant result.
        return [relation == 5 ? 1 : 0, kindPenalty, seasonPenalty, relation]
    }

    private struct Season {
        var number: Int
        var base: String
        var canonical: String
    }

    private static func season(_ name: String) -> Season? {
        let regex = try! NSRegularExpression(pattern: "第([0-9一二三四五六七八九十零两]+)季|season([0-9]+)")
        let matches = regex.matches(in: name, range: NSRange(name.startIndex..., in: name))
        guard matches.count == 1, let match = matches.first, let full = Range(match.range, in: name) else { return nil }
        let numberRange = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
        guard let range = Range(numberRange, in: name), let number = seasonNumber(String(name[range])), number > 0 else { return nil }
        return Season(number: number, base: name.replacingCharacters(in: full, with: ""), canonical: name.replacingCharacters(in: full, with: "season\(number)"))
    }

    private static func seasonNumber(_ token: String) -> Int? {
        if let number = Int(token) { return number }
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let characters = Array(token)
        if characters.count == 1 { return token == "十" ? 10 : digits[characters[0]] }
        guard let split = characters.firstIndex(of: "十"), split <= 1, characters.count <= split + 2,
              characters.lastIndex(of: "十") == split else { return nil }
        let tens = split == 0 ? 1 : digits[characters[0]]
        let units = split == characters.count - 1 ? 0 : digits[characters[split + 1]]
        guard let tens, let units, tens > 0 else { return nil }
        return tens * 10 + units
    }
}
