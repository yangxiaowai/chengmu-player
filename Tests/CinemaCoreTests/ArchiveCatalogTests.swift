import Foundation
import Testing
@testable import CinemaCore

struct ArchiveCatalogTests {
    let provider = SourceProvider(id: "archive-org", name: "Internet Archive 开放影片", endpoint: URL(string: "https://archive.org")!)
    var title: MediaTitle { .init(id: "sample-film", title: "A Film", year: "", posterURL: nil, summary: "", providerID: provider.id, providerName: provider.name) }

    @Test func searchEscapesQueriesAndUsesOpenMovieFilter() throws {
        let url = try ArchiveCatalog.searchURL(query: "film\" AND mediatype:texts", page: 2)
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = parts.queryItems!.first(where: { $0.name == "q" })!.value!
        #expect(query.contains("collection:opensource_movies"))
        #expect(query.contains("licenseurl:*creativecommons.org*"))
        #expect(query.contains("film\\\" AND mediatype:texts"))
        #expect(parts.queryItems!.first(where: { $0.name == "page" })?.value == "2")
        #expect(throws: (any Error).self) { try ArchiveCatalog.searchURL(query: "x", page: 0) }
    }

    @Test func searchParsesOnlyValidIdentifiersAndPreservesPage() throws {
        let data = Data(#"{"response":{"numFound":60,"docs":[{"identifier":"sample-film","title":"A Film","year":1930},{"identifier":"../bad","title":"Bad"}]}}"#.utf8)
        let page = try ArchiveCatalog.parsePage(data, provider: provider, page: 2)
        #expect(page.titles.map(\.id) == ["sample-film"])
        #expect(page.page == 2 && page.pageCount == 2)
        #expect(page.titles[0].providerID == provider.id)
    }

    @Test func detailKeepsOnlyPublicDirectVideoFilesFromDeclaredOpenItem() throws {
        let data = Data(#"{"metadata":{"identifier":"sample-film","title":"A Film","mediatype":"movies","collection":["opensource_movies"],"licenseurl":"https://creativecommons.org/publicdomain/zero/1.0/"},"files":[{"name":"full movie.mp4"},{"name":"private.mp4","private":"true"},{"name":"../unsafe.mp4"},{"name":"info.txt"}]}"#.utf8)
        let detail = try ArchiveCatalog.parseDetail(data, title: title)
        #expect(detail.lines.count == 1)
        #expect(detail.lines[0].episodes[0].url.absoluteString == "https://archive.org/download/sample-film/full%20movie.mp4")
        #expect(detail.title.summary.contains("许可"))
    }

    @Test func restrictedWrongIdentityAndMissingLicenseNeverProducePlayback() {
        for data in [
            #"{"metadata":{"identifier":"sample-film","mediatype":"movies","collection":"opensource_movies","licenseurl":"https://creativecommons.org/publicdomain/zero/1.0/","access-restricted-item":"true"},"files":[{"name":"a.mp4"}]}"#,
            #"{"metadata":{"identifier":"different","mediatype":"movies","collection":"opensource_movies","licenseurl":"https://creativecommons.org/publicdomain/zero/1.0/"},"files":[{"name":"a.mp4"}]}"#,
            #"{"metadata":{"identifier":"sample-film","mediatype":"movies","collection":"opensource_movies"},"files":[{"name":"a.mp4"}]}"#
        ] {
            #expect(throws: (any Error).self) { try ArchiveCatalog.parseDetail(Data(data.utf8), title: title) }
        }
    }

    @Test func addedBuiltinMigratesWithoutUndoingRemovedAndDisabledSources() {
        let old = Array(SourceProvider.defaults.filter { $0.id != provider.id })
        var saved = Array(old.dropLast())
        saved[0].enabled = false
        let upgraded = ProviderCatalog.merge(saved: saved, knownBuiltinIDs: old.map(\.id), defaults: SourceProvider.defaults)
        #expect(upgraded.contains { $0.id == provider.id })
        #expect(upgraded.first?.enabled == false)
        #expect(!upgraded.contains { $0.id == old.last!.id })
        let removedAgain = upgraded.filter { $0.id != provider.id }
        #expect(!ProviderCatalog.merge(saved: removedAgain, knownBuiltinIDs: SourceProvider.defaults.map(\.id), defaults: SourceProvider.defaults).contains { $0.id == provider.id })
    }

    @Test func providerIsOnlyRecognizedAtItsCanonicalEndpoint() {
        #expect(ArchiveCatalog.recognizes(provider))
        let spoof = SourceProvider(id: provider.id, name: provider.name, endpoint: URL(string: "https://evil.invalid")!)
        #expect(!ArchiveCatalog.recognizes(spoof))
    }

    @Test func cancelledArchiveSearchCannotReturnStaleCandidates() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArchivePendingFixture.self]
        let service = SourceService(client: BoundedHTTPClient(timeout: 5, configuration: config))
        let task = Task { await service.search(query: "hold", providers: [provider]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.value
        #expect(result.titles.isEmpty && result.failures.isEmpty)
    }
}

private final class ArchivePendingFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { /* stays pending until the session is cancelled */ }
    override func stopLoading() {}
}
