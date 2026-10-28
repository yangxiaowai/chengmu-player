import Foundation
import Testing
@testable import CinemaCore

struct CatalogLibraryTests {
    @Test func manualSourceChoiceWinsAndDisabledPreferredSourceIsSkipped() {
        let a = SourceProvider(id: "a", name: "A", endpoint: URL(string: "https://a.test")!)
        var b = SourceProvider(id: "b", name: "B", endpoint: URL(string: "https://b.test")!)
        let rows = [title("1", provider: "a"), title("2", provider: "b")]
        #expect(ProviderCatalog.preferredTitle(in: rows, providers: [a, b], preferredID: "b")?.providerID == "b")
        #expect(ProviderCatalog.preferredTitle(in: rows, providers: [a, b], explicitID: "a", preferredID: "b")?.providerID == "a")
        b.enabled = false
        #expect(ProviderCatalog.preferredTitle(in: rows, providers: [a, b], explicitID: "b", preferredID: "b")?.providerID == "a")
        #expect(ProviderCatalog.preferredTitle(in: rows, providers: [a], preferredID: "missing")?.providerID == "a")
        #expect(ProviderCatalog.preferredTitle(in: rows, providers: [b], preferredID: "b") == nil)
    }
    private func title(_ id: String, _ name: String = "火线第一季", year: String = "2002", provider: String = "a", poster: String? = nil) -> MediaTitle {
        MediaTitle(id: id, title: name, year: year, posterURL: poster.flatMap(URL.init(string:)), summary: "", providerID: provider, providerName: provider)
    }
    @Test func mergesSourcesButNotSeasonsOrRemakes() {
        let rows = [title("1"), title("2", "火线 第一季", provider: "b"), title("3", "火线第二季"), title("4", year: "2024")]
        let groups = CatalogGrouping.groups(rows)
        #expect(groups.count == 3)
        #expect(groups.first?.sources.count == 2)
        #expect(Set(groups.map(\.id)) == Set(CatalogGrouping.groups(rows.reversed()).map(\.id)))
    }
    @Test func missingYearJoinsOnlyAnUnambiguousYear() {
        #expect(CatalogGrouping.groups([title("1",year:""),title("2",provider:"b")]).count == 1)
        let ambiguous = CatalogGrouping.groups([title("1",year:""),title("2",provider:"b"),title("3",year:"2024",provider:"c")])
        #expect(ambiguous.count == 3)
        #expect(ambiguous.allSatisfy { $0.sources.count == 1 })
    }
    @Test func conflictingFilmAndSeriesCategoriesRemainSeparate() {
        var film = title("film", "同名作品", year: "2020", provider: "film"); film.category = "剧情片"
        var series = title("series", "同名作品", year: "2020", provider: "series"); series.category = "国产剧"
        let unknown = title("unknown", "同名作品", year: "2020", provider: "unknown")
        let groups = CatalogGrouping.groups([film, series, unknown])
        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.sources.count == 1 })
        #expect(Set(groups.map(\.id)) == Set(CatalogGrouping.groups([unknown, series, film]).map(\.id)))
        #expect(CatalogGrouping.groups([film, unknown]).count == 1)
        #expect(CatalogGrouping.groups([series, unknown]).count == 1)
    }
    @Test func documentaryAndAnimationLabelsAloneDoNotAssertFilmClassification() {
        var film = title("film", "同名作品", year: "2020", provider: "film"); film.category = "电影"
        var series = title("series", "同名作品", year: "2020", provider: "series"); series.category = "电视剧"
        var doc = title("doc", "同名作品", year: "2020", provider: "doc"); doc.category = "纪录片"
        var animation = title("animation", "同名作品", year: "2020", provider: "animation"); animation.category = "动画片"
        let groups = CatalogGrouping.groups([film, series, doc, animation])
        #expect(groups.count == 3)
        #expect(groups.contains { Set($0.sources.map(\.id)) == Set(["doc", "animation"]) })
    }
    @Test func existingWatchlistFollowsItsKnownCategoryAcrossSplitAndMerge() throws {
        var film = title("film", "同名作品", year: "2020", provider: "film"); film.category = "电影"
        var series = title("series", "同名作品", year: "2020", provider: "series"); series.category = "电视剧"
        let unknown = title("unknown", "同名作品", year: "2020", provider: "unknown")
        let oldFilm = SavedTitle(group: try #require(CatalogGrouping.groups([film, unknown]).first))
        let split = CatalogGrouping.groups([film, series, unknown])
        let filmGroup = try #require(split.first { $0.sources.contains(film) })
        let seriesGroup = try #require(split.first { $0.sources.contains(series) })
        let unknownGroup = try #require(split.first { $0.sources.contains(unknown) })
        #expect(oldFilm.matches(filmGroup))
        #expect(!oldFilm.matches(seriesGroup))
        #expect(!oldFilm.matches(unknownGroup))
        let splitFilm = SavedTitle(group: filmGroup)
        #expect(splitFilm.matches(try #require(CatalogGrouping.groups([film, unknown]).first)))
        #expect(!oldFilm.matches(try #require(CatalogGrouping.groups([series]).first)))
    }
    @Test func oldBookmarkWithConflictingKnownCategoriesDoesNotFollowEitherSplit() throws {
        var film = title("film", "同名作品", year: "2020", provider: "film"); film.category = "电影"
        var series = title("series", "同名作品", year: "2020", provider: "series"); series.category = "电视剧"
        let oldID = try #require(CatalogGrouping.groups([film]).first).id
        let oldMixed = SavedTitle(group: MediaGroup(id: oldID, sources: [film, series]))
        #expect(CatalogGrouping.groups([film, series]).allSatisfy { !oldMixed.matches($0) })
        #expect(oldMixed.matches(try #require(oldMixed.group)))
    }
    @Test func unclassifiedBookmarkKeepsItsOwnSourceWhenCategoriesSplit() throws {
        let unknown = title("unknown", "同名作品", year: "2020", provider: "unknown")
        let saved = SavedTitle(group: try #require(CatalogGrouping.groups([unknown]).first))
        var film = title("film", "同名作品", year: "2020", provider: "film"); film.category = "电影"
        var series = title("series", "同名作品", year: "2020", provider: "series"); series.category = "电视剧"
        let groups = CatalogGrouping.groups([film, series, unknown])
        let unknownGroup = try #require(groups.first { $0.sources.contains(unknown) })
        #expect(saved.matches(unknownGroup))
        #expect(groups.filter { saved.matches($0) }.count == 1)
    }
    @Test func representativeUsesAvailableArtworkWithoutChangingSourceIdentity() {
        let groups = CatalogGrouping.groups([title("1"),title("2",provider:"b",poster:"https://example.test/poster.jpg"),title("1")])
        #expect(groups.count == 1)
        #expect(groups[0].sources.count == 2)
        #expect(groups[0].representative.id == "1")
        #expect(groups[0].representative.posterURL != nil)
        #expect(groups[0].sources[0].posterURL == nil)
    }
    @Test func savedKnownYearDoesNotFollowAnUnknownSourceAfterPaginationSplitsTheGroup() throws {
        let known = title("1"), unknown = title("2", year: "", provider: "b")
        let saved = SavedTitle(group: CatalogGrouping.groups([known, unknown])[0])
        let expanded = CatalogGrouping.groups([known, unknown, title("3", year: "2024", provider: "c")])
        let unknownGroup = try #require(expanded.first { $0.representative.year.isEmpty })

        #expect(expanded.filter { saved.matches($0) }.map(\.id) == [saved.id])
        // This is the same removal predicate used by the app's bookmark button.
        var watchlist = [saved]
        watchlist.removeAll { $0.matches(unknownGroup) }
        #expect(watchlist == [saved])
    }
    @Test func savedUnknownYearFollowsUnambiguousMetadataEnrichment() {
        let unknown = title("1", year: "")
        let saved = SavedTitle(group: CatalogGrouping.groups([unknown])[0])
        let enriched = CatalogGrouping.groups([title("1"), title("2", provider: "b")])[0]
        #expect(saved.id != enriched.id)
        #expect(saved.matches(enriched))
        let anotherSourceSuppliesYear = CatalogGrouping.groups([unknown, title("2", provider: "b")])[0]
        #expect(saved.matches(anotherSourceSuppliesYear))
    }
    @Test func reusedSourceIdentityDoesNotMergeKnownYearsOrDifferentSeasons() {
        let known = SavedTitle(group: CatalogGrouping.groups([title("1")])[0])
        #expect(!known.matches(CatalogGrouping.groups([title("1", year: "2024")])[0]))
        #expect(!known.matches(CatalogGrouping.groups([title("1", "火线第二季")])[0]))

        let unknown = SavedTitle(group: CatalogGrouping.groups([title("1", year: "")])[0])
        #expect(!unknown.matches(CatalogGrouping.groups([title("1", "火线第二季")])[0]))
    }
    @Test func savedUnknownSourcesDoNotFollowConflictingYearEnrichment() {
        let saved = SavedTitle(group: CatalogGrouping.groups([title("1", year: ""), title("2", year: "", provider: "b")])[0])
        let separated = CatalogGrouping.groups([title("1"), title("2", year: "2024", provider: "b")])
        #expect(separated.count == 2)
        #expect(separated.allSatisfy { !saved.matches($0) })
        #expect(saved.group.map { saved.matches($0) } == true)
    }
    @Test func watchlistRoundTripAndCorruptionIsPreserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WatchlistStore(directory: dir)
        #expect(try store.load().isEmpty)
        let record = SavedTitle(group: CatalogGrouping.groups([title("1"),title("2",provider:"b")])[0])
        try store.save([record]); #expect(try store.load() == [record])
        let file = dir.appendingPathComponent("watchlist.json")
        let broken = Data("not json".utf8); try broken.write(to:file)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try Data(contentsOf:file) == broken)
    }
    @Test func providerUpgradePreservesRemovedAndDisabledBuiltins() {
        let a = SourceProvider(id:"a",name:"A",endpoint:URL(string:"https://a.test/api")!,enabled:false)
        let b = SourceProvider(id:"b",name:"B",endpoint:URL(string:"https://b.test/api")!)
        let c = SourceProvider(id:"c",name:"C",endpoint:URL(string:"https://c.test/api")!)
        let merged = ProviderCatalog.merge(saved:[a], knownBuiltinIDs:["a","b"], defaults:[a,b,c])
        #expect(merged.map(\.id) == ["a","c"])
        #expect(merged[0].enabled == false)
        #expect(ProviderCatalog.merge(saved:[],knownBuiltinIDs:["a","b","c"],defaults:[a,b,c]).isEmpty)
    }
}
