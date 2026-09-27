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
    public static func normalizedTitle(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier:"en_US_POSIX"))
            .replacingOccurrences(of:"\\s+",with:"",options:.regularExpression)
    }
    public static func groups<S: Sequence>(_ rows: S) -> [MediaGroup] where S.Element == MediaTitle {
        var seen = Set<String>()
        let unique = rows.filter { seen.insert($0.providerID + ":" + $0.id).inserted }
        let years = Dictionary(grouping: unique, by: {normalizedTitle($0.title)}).mapValues { Set($0.map(\.year).filter { !$0.isEmpty }) }
        var order: [String] = [], grouped: [String:[MediaTitle]] = [:]
        for title in unique {
            let normalized = normalizedTitle(title.title)
            let candidates = years[normalized] ?? []
            let year = title.year.isEmpty && candidates.count == 1 ? candidates.first! : title.year
            let identity = normalized + "|" + year
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
        if id == group.id { return true }
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
