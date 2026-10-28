import Foundation
import CryptoKit

public struct MediaGroup: Identifiable, Hashable {
    public let id: String
    public let sources: [MediaTitle]
    public var representative: MediaTitle {
        var value = sources[0]
        value.posterURL = sources.compactMap(\.posterURL).first
        if value.year.isEmpty { value.year = sources.first { !$0.year.isEmpty }?.year ?? "" }
        if value.summary.isEmpty { value.summary = sources.first { !$0.summary.isEmpty }?.summary ?? "" }
        return value
    }
    public init(id: String, sources: [MediaTitle]) { self.id = id; self.sources = sources }
}

public enum CatalogGrouping {
    fileprivate enum WorkKind: String, Hashable { case film, series, unknown }
    private struct Bucket: Hashable { let title: String; let year: String }
    fileprivate static func kind(_ category: String?) -> WorkKind {
        let value = normalizedTitle(category ?? "")
        // 纪录片 / 动画片 can refer to either a film or a series, so neither is decisive.
        let film: Set<String> = ["电影", "剧情片", "喜剧片", "动作片", "爱情片", "科幻片", "恐怖片", "战争片", "犯罪片", "悬疑片", "冒险片", "奇幻片", "惊悚片"]
        if film.contains(value) || value.hasSuffix("电影") { return .film }
        if value.hasSuffix("剧") || value.contains("电视剧") || value == "series" || value == "tvseries" { return .series }
        return .unknown
    }
    public static func normalizedTitle(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier:"en_US_POSIX"))
            .replacingOccurrences(of:"\\s+",with:"",options:.regularExpression)
    }
    public static func groups<S: Sequence>(_ rows: S) -> [MediaGroup] where S.Element == MediaTitle {
        var seen = Set<String>()
        let unique = rows.filter { seen.insert($0.providerID + ":" + $0.id).inserted }
        let years = Dictionary(grouping: unique.filter { $0.providerID != "wikimedia-commons" }, by: {normalizedTitle($0.title)}).mapValues { Set($0.map(\.year).filter { !$0.isEmpty }) }
        let prepared = unique.map { title -> (MediaTitle, Bucket) in
            let normalized = normalizedTitle(title.title), candidates = years[normalized] ?? []
            let year = title.year.isEmpty && candidates.count == 1 ? candidates.first! : title.year
            return (title, Bucket(title: normalized, year: year))
        }
        let kinds = Dictionary(grouping: prepared.filter { $0.0.providerID != "wikimedia-commons" }, by: { $0.1 })
            .mapValues { Set($0.map { kind($0.0.category) }.filter { $0 != .unknown }) }
        var order: [String] = [], grouped: [String:[MediaTitle]] = [:]
        for (title, bucket) in prepared {
            // A Commons file is an individual short clip, not another edition of a full work.
            var identity = title.providerID == "wikimedia-commons"
                ? "commons-short|\(title.providerID)|\(title.id)" : bucket.title + "|" + bucket.year
            // Preserve the existing ID when no conflict is known. On conflict, do not
            // guess which known class an unclassified source belongs to.
            if title.providerID != "wikimedia-commons", (kinds[bucket]?.count ?? 0) > 1 {
                identity += "|kind:" + kind(title.category).rawValue
            }
            let key = SHA256.hash(data:Data(identity.utf8)).prefix(16).map {String(format:"%02x",$0)}.joined()
            if grouped[key] == nil { order.append(key) }
            grouped[key,default:[]].append(title)
        }
        return order.map { MediaGroup(id:$0,sources:grouped[$0]!) }
    }
}

public struct SavedTitle: Codable, Hashable, Identifiable {
    public var id: String
    public var sources: [MediaTitle]
    public var addedAt: Date
    public init(group: MediaGroup, addedAt: Date = Date()) { id = group.id; sources = group.sources; self.addedAt = addedAt }
    public var group: MediaGroup? { sources.isEmpty ? nil : MediaGroup(id:id,sources:sources) }
    public func matches(_ group: MediaGroup) -> Bool {
        if id == group.id && sources == group.sources { return true }
        let savedKinds = Set(sources.map { CatalogGrouping.kind($0.category) }.filter { $0 != .unknown })
        let candidateKinds = Set(group.sources.map { CatalogGrouping.kind($0.category) }.filter { $0 != .unknown })
        guard savedKinds.count <= 1, candidateKinds.count <= 1 else { return false }
        if !savedKinds.isEmpty && !candidateKinds.isEmpty && savedKinds != candidateKinds { return false }
        if id == group.id { return true }
        // A classification conflict changes the group ID. Preserve a known-category
        // bookmark only when the same explicitly classified source is still present.
        if let savedKind = savedKinds.first, candidateKinds.contains(savedKind) {
            let savedTitles = Set(sources.map { CatalogGrouping.normalizedTitle($0.title) })
            let candidateTitles = Set(group.sources.map { CatalogGrouping.normalizedTitle($0.title) })
            let savedYears = Set(sources.map(\.year).filter { !$0.isEmpty })
            let candidateYears = Set(group.sources.map(\.year).filter { !$0.isEmpty })
            let anchors = sources.filter { CatalogGrouping.kind($0.category) == savedKind }
            if savedTitles.count == 1, savedTitles == candidateTitles, savedYears.count <= 1,
               candidateYears.count == 1, (savedYears.isEmpty || savedYears == candidateYears),
               !anchors.isEmpty, anchors.allSatisfy({ saved in group.sources.contains { $0.providerID == saved.providerID && $0.id == saved.id } }) { return true }
        }
        if savedKinds.isEmpty, !sources.isEmpty {
            let savedTitles = Set(sources.map { CatalogGrouping.normalizedTitle($0.title) })
            let candidateTitles = Set(group.sources.map { CatalogGrouping.normalizedTitle($0.title) })
            let savedYears = Set(sources.map(\.year).filter { !$0.isEmpty })
            let candidateYears = Set(group.sources.map(\.year).filter { !$0.isEmpty })
            if savedTitles.count == 1, savedTitles == candidateTitles, savedYears.count <= 1,
               candidateYears.count <= 1, (savedYears.isEmpty || savedYears == candidateYears),
               sources.allSatisfy({ saved in group.sources.contains { $0.providerID == saved.providerID && $0.id == saved.id } }) { return true }
        }
        // A known-year bookmark stays with its stored work identity when more
        // pages split previously ambiguous sources into separate groups.
        guard !sources.isEmpty, sources.allSatisfy({ $0.year.isEmpty }) else { return false }
        let savedTitles = Set(sources.map { CatalogGrouping.normalizedTitle($0.title) })
        let candidateTitles = Set(group.sources.map { CatalogGrouping.normalizedTitle($0.title) })
        let candidateYears = Set(group.sources.map(\.year).filter { !$0.isEmpty })
        guard savedTitles.count == 1, savedTitles == candidateTitles, candidateYears.count == 1 else { return false }
        // An unknown year may become known, but partial source overlap cannot
        // establish that identity after those sources have split across years.
        return sources.allSatisfy { saved in
            group.sources.contains { $0.providerID == saved.providerID && $0.id == saved.id }
        }
    }
}

public struct WatchlistStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> [SavedTitle] {
        let file = directory.appendingPathComponent("watchlist.json")
        guard FileManager.default.fileExists(atPath:file.path) else {return []}
        return try JSONDecoder().decode([SavedTitle].self,from:Data(contentsOf:file))
    }
    public func save(_ values: [SavedTitle]) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(values).write(to:directory.appendingPathComponent("watchlist.json"),options:.atomic)
    }
}

public enum ProviderCatalog {
    /// Preference selects an already grouped version; it never broadens work identity.
    public static func preferredTitle(in titles: [MediaTitle], providers: [SourceProvider], explicitID: String = "", preferredID: String) -> MediaTitle? {
        let enabled = Set(providers.filter(\.enabled).map(\.id))
        let available = titles.filter { enabled.contains($0.providerID) }
        return available.first { $0.providerID == explicitID }
            ?? available.first { $0.providerID == preferredID } ?? available.first
    }
    /// Known builtins absent from the user's saved list were deliberately removed.
    public static func merge(saved: [SourceProvider]?, knownBuiltinIDs: [String], defaults: [SourceProvider]) -> [SourceProvider] {
        guard var saved else { return defaults }
        let known = Set(knownBuiltinIDs)
        for provider in defaults where !known.contains(provider.id) {
            guard !saved.contains(where:{$0.id == provider.id || $0.endpoint == provider.endpoint}) else {continue}
            saved.append(provider)
        }
        return saved
    }
}
