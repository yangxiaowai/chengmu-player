import Foundation
import Testing
@testable import CinemaCore

struct CatalogDiscoveryPolicyTests {
    private func title(_ id: String, _ name: String, category: String? = nil, provider: String = "a") -> MediaTitle {
        MediaTitle(id: id, title: name, year: "2024", posterURL: nil, summary: "", providerID: provider, providerName: provider, category: category)
    }
    private func group(_ id: String, _ name: String, category: String? = nil) -> MediaGroup {
        MediaGroup(id: id, sources: [title(id, name, category: category)])
    }

    @Test func unknownCategoriesRemainAvailableAndAllNeverHidesRecords() {
        let rows = [title("unknown", "沙丘", category: "未分类"), title("missing", "火线"), title("new", "谜案", category: "实验纪录影像"), title("derived", "沙丘", category: "电影解说")]
        #expect(rows.filter { CatalogDiscoveryPolicy.matches($0, filter: .all) }.map(\.id) == ["unknown", "missing", "new", "derived"])
        #expect(rows.filter { CatalogDiscoveryPolicy.matches($0, filter: .feature) }.map(\.id) == ["unknown", "missing", "new"])
    }

    @Test func categoryMetadataAndExplicitTitleMarkersSelectDerivedContent() {
        let commentary = [title("1", "沙丘", category: "电影解说"), title("2", "沙丘【影视解说】"), title("3", "电影解说：沙丘")]
        let trailers = [title("4", "沙丘", category: "预告片"), title("5", "沙丘 预告片"), title("6", "沙丘【预告】")]
        let shortDramas = [title("7", "归来", category: "爽文短剧"), title("8", "归来（短剧）")]
        #expect(commentary.allSatisfy { CatalogDiscoveryPolicy.matches($0, filter: .commentary) })
        #expect(trailers.allSatisfy { CatalogDiscoveryPolicy.matches($0, filter: .trailer) })
        #expect(shortDramas.allSatisfy { CatalogDiscoveryPolicy.matches($0, filter: .shortDrama) })
        #expect(!CatalogDiscoveryPolicy.matches(commentary[0], filter: .trailer))
        #expect(!CatalogDiscoveryPolicy.matches(shortDramas[0], filter: .feature))
    }

    @Test func incidentalWordsInsideRealTitlesDoNotHideFeatures() {
        let rows = [title("1", "预告犯"), title("2", "王牌解说员"), title("3", "短剧人生"), title("4", "解说", category: "剧情片")]
        #expect(rows.allSatisfy { CatalogDiscoveryPolicy.matches($0, filter: .feature) })
    }

    @Test func exactNormalizedTitleRanksBeforeSequelsAndDerivedTitles() {
        let groups = [group("commentary", "沙丘【影视解说】"), group("sequel", "沙丘2"), group("short", "沙丘", category: "短剧"), group("exact", "沙丘"), group("trailer", "沙丘预告片")]
        #expect(CatalogDiscoveryPolicy.rank(groups, query: " 沙 丘 ").map(\.id) == ["exact", "sequel", "short", "commentary", "trailer"])
        let english = [group("sequel", "DUNE 2"), group("exact", "ＤＵＮＥ")]
        #expect(CatalogDiscoveryPolicy.rank(english, query: " dune\n").map(\.id) == ["exact", "sequel"])
    }

    @Test func explicitChineseAndEnglishSeasonsPreferTheRequestedSeason() {
        let groups = [group("other", "火线第三季"), group("base", "火线"), group("english", "火线 Season 2"), group("chinese", "火线第二季"), group("commentary", "火线第二季【解说】")]
        #expect(CatalogDiscoveryPolicy.rank(groups, query: "火线第２季").map(\.id) == ["english", "chinese", "base", "other", "commentary"])
        #expect(CatalogDiscoveryPolicy.rank(groups, query: "火线 SEASON ２").prefix(2).map(\.id) == ["english", "chinese"])
    }

    @Test func explicitDerivedQueriesRespectTheRequestedKindAndLiteralTitle() {
        let groups = [group("feature", "沙丘"), group("trailer", "沙丘预告片"), group("commentary", "沙丘解说"), group("otherCommentary", "沙丘2解说")]
        #expect(CatalogDiscoveryPolicy.rank(groups, query: "沙丘 解说").first?.id == "commentary")
        #expect(CatalogDiscoveryPolicy.rank(groups, query: "沙丘预告片").first?.id == "trailer")
        #expect(CatalogDiscoveryPolicy.rank(groups, query: "解说").prefix(2).map(\.id) == ["commentary", "otherCommentary"])
    }

    @Test func rankingIsStablePreservesSourceRecordsAndDoesNotDeleteUnrelatedResults() {
        let first = MediaGroup(id: "first", sources: [title("a1", "沙丘", provider: "a"), title("b1", "沙 丘", provider: "b")])
        let second = group("second", "沙丘")
        let groups = [group("unrelated", "谜案"), first, second]
        let ranked = CatalogDiscoveryPolicy.rank(groups, query: "沙丘")
        #expect(ranked.map(\.id) == ["first", "second", "unrelated"])
        #expect(ranked[0] == first)
        #expect(ranked[0].sources.map(\.id) == ["a1", "b1"])
        #expect(CatalogDiscoveryPolicy.rank(groups, query: " \n ") == groups)
        #expect(CatalogDiscoveryPolicy.rank([second, first], query: "沙丘").map(\.id) == ["second", "first"])
        #expect(CatalogDiscoveryPolicy.rank([], query: "沙丘").isEmpty)
    }
}
