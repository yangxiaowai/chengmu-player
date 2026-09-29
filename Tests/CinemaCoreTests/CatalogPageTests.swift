import Foundation
import Testing
@testable import CinemaCore

struct CatalogPageTests {
    let provider = SourceProvider(id: "fixture", name: "Fixture", endpoint: URL(string: "https://catalog.example/api")!)

    @Test func searchCategorySurvivesPersistence() throws {
        let data = Data(#"{"list":[{"vod_id":42,"vod_name":"Test","type_name":"国产剧"}]}"#.utf8)
        let titles = try SourceService.parseSearch(data: data, provider: provider)
        let encoded = try JSONEncoder().encode(titles[0])
        let value = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        #expect(value["category"] as? String == "国产剧")
    }

    @Test func legacyHistoryWithoutCategoryStillDecodes() throws {
        let data = Data(#"{"id":"42","title":"Old","year":"2020","summary":"","providerID":"fixture","providerName":"Fixture"}"#.utf8)
        #expect(try JSONDecoder().decode(MediaTitle.self, from: data).category == nil)
    }

    @Test func mixedStringAndNumericPaginationPreservesProviderCategories() throws {
        let data = Data(#"{"code":1,"page":"2","pagecount":4,"total":"62","limit":"20","list":[{"vod_id":42,"vod_name":"A","type_name":"国产剧"}],"class":[{"type_id":13,"type_name":"国产剧","type_pid":"2"},{"type_id":"13","type_name":"duplicate"},{"type_id":2,"type_name":"连续剧","type_pid":0}]}"#.utf8)
        let page = try SourceService.parsePage(data: data, provider: provider, requestedPage: 2)
        #expect(page.providerID == "fixture")
        #expect(page.page == 2 && page.pageCount == 4 && page.total == 62 && page.hasMore)
        #expect(page.categories.map(\.id) == ["13", "2"])
        #expect(page.categories.first?.providerID == "fixture")
        #expect(page.categories.first?.parentID == "2")
        #expect(page.categories.last?.parentID == nil)
        #expect(page.titles.first?.category == "国产剧")
    }

    @Test func emptyResultsStopPaginationAndMissingMetadataDoesNotInventMorePages() throws {
        let empty = Data(#"{"page":1,"pagecount":0,"total":0,"list":[]}"#.utf8)
        let page = try SourceService.parsePage(data: empty, provider: provider)
        #expect(page.titles.isEmpty && page.pageCount == 1 && !page.hasMore)
        let missing = Data(#"{"list":[{"vod_id":1,"vod_name":"A"}]}"#.utf8)
        let noMetadata = try SourceService.parsePage(data: missing, provider: provider, requestedPage: 3)
        #expect(noMetadata.page == 3 && !noMetadata.hasMore)
        let inferred = Data(#"{"page":2,"total":41,"limit":20,"list":[]}"#.utf8)
        #expect(try SourceService.parsePage(data: inferred, provider: provider, requestedPage: 2).pageCount == 3)
    }

    @Test func successfulExplicitlyEmptyNullListIsNotAProviderFailure() throws {
        // Actual Ruyi empty search response: code 1, zero total/pages, list null.
        for json in [#"{"code":1,"page":1,"pagecount":0,"limit":20,"total":0,"list":null}"#,
                     #"{"code":"200","page":"1","pagecount":"0","total":"0","list":null}"#] {
            let data = Data(json.utf8)
            let page = try SourceService.parsePage(data: data, provider: provider)
            #expect(page.titles.isEmpty && page.total == 0 && page.pageCount == 1 && !page.hasMore)
            #expect(try SourceService.parseSearch(data: data, provider: provider).isEmpty)
        }
    }

    @Test func nullListWithoutExplicitSuccessfulEmptyMetadataRemainsInvalid() {
        for json in [#"{"code":0,"pagecount":0,"total":0,"list":null}"#,
                     #"{"code":1,"pagecount":1,"total":1,"list":null}"#,
                     #"{"code":1,"pagecount":0,"list":null}"#,
                     #"{"code":1,"total":0,"list":null}"#,
                     #"{"pagecount":0,"total":0,"list":null}"#,
                     #"{"code":1,"pagecount":0,"total":0}"#] {
            #expect(throws: (any Error).self) {
                try SourceService.parsePage(data: Data(json.utf8), provider: provider)
            }
        }
    }

    @Test func ignoredPageAndMalformedPaginationAreErrorsRatherThanRepeatedFirstPage() {
        for json in [#"{"page":1,"pagecount":3,"list":[]}"#,
                     #"{"page":2,"pagecount":-1,"list":[]}"#,
                     #"{"page":2,"total":"NaN","list":[]}"#,
                     #"{"page":2,"pagecount":0,"list":[{"vod_id":1,"vod_name":"A"}]}"#] {
            #expect(throws: (any Error).self) {
                try SourceService.parsePage(data: Data(json.utf8), provider: provider, requestedPage: 2)
            }
        }
        #expect(throws: (any Error).self) {
            try SourceService.requestURL(provider: provider, action: "list", parameters: ["pg": "0"])
        }
        let url = try? SourceService.requestURL(provider: provider, action: "detail", parameters: ["pg": "2", "t": "26"])
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        #expect(items?.first { $0.name == "pg" }?.value == "2")
        #expect(items?.first { $0.name == "t" }?.value == "26")
    }

    @Test func searchPagesKeepsProviderErrorsSeparateAndSkipsDisabledAndDuplicateIDs() async {
        let one = SourceProvider(id: "one", name: "One", endpoint: URL(string: "http://invalid.test/api")!)
        let two = SourceProvider(id: "two", name: "Two", endpoint: URL(string: "http://invalid.test/api")!)
        let disabled = SourceProvider(id: "disabled", name: "Disabled", endpoint: URL(string: "http://invalid.test/api")!, enabled: false)
        let result = await SourceService().searchPages(query: "a", providers: [one, disabled, two, one], pages: ["one": 3, "two": 0])
        #expect(result.map(\.providerID) == ["one", "two"])
        #expect(result.allSatisfy { $0.page == nil && $0.error != nil })
        #expect(result[1].error?.contains("页码") == true)
        #expect(await SourceService().searchPages(query: "  ", providers: [one]).isEmpty)
    }

    @Test(arguments: ["category-http-error", "category-malformed"])
    func browsePreservesSuccessfulDetailPageWhenOptionalCategoriesFail(mode: String) async throws {
        let page = try await fixtureService().browse(provider: fixtureProvider(mode: mode))
        #expect(page.titles.map(\.title) == ["Available title"])
        #expect(page.page == 1 && page.pageCount == 3 && page.total == 41)
        #expect(page.categories.isEmpty)
    }

    @Test func browseKeepsSuccessfulOptionalCategories() async throws {
        let page = try await fixtureService().browse(provider: fixtureProvider(mode: "success"))
        #expect(page.titles.map(\.title) == ["Available title"])
        #expect(page.categories.map(\.name) == ["国产剧"])
        #expect(page.pageCount == 3 && page.total == 41)
    }

    @Test func browseDoesNotSuppressPrimaryRequestFailure() async {
        do {
            _ = try await fixtureService().browse(provider: fixtureProvider(mode: "primary-http-error"))
            Issue.record("Primary directory failure must remain an error")
        } catch SourceError.httpStatus(let status) {
            #expect(status == 503)
        } catch {
            Issue.record("Expected HTTP 503, received \(error)")
        }
    }

    @Test func browseDoesNotSuppressOptionalRequestCancellation() async {
        do {
            _ = try await fixtureService().browse(provider: fixtureProvider(mode: "category-cancelled"))
            Issue.record("Cancelled browsing must not return the already fetched page")
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        } catch is CancellationError {
            // Either cancellation representation must continue to the caller.
        } catch {
            Issue.record("Expected cancellation, received \(error)")
        }
    }

    private func fixtureService() -> SourceService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogFixtureURLProtocol.self]
        return SourceService(client: BoundedHTTPClient(configuration: configuration))
    }

    private func fixtureProvider(mode: String) -> SourceProvider {
        SourceProvider(id: "fixture", name: "Fixture", endpoint: URL(string: "https://browse-fixture.test/api?mode=\(mode)")!)
    }
}

/// Intercepts only this fixture host; no global registration or mutable shared handler.
private final class CatalogFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "browse-fixture.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let action = query.first { $0.name == "ac" }?.value
        let mode = query.first { $0.name == "mode" }?.value
        if action == "list", mode == "category-cancelled" {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let status = (action == "detail" && mode == "primary-http-error") ||
                     (action == "list" && mode == "category-http-error") ? 503 : 200
        let body: String
        if action == "detail" {
            body = #"{"code":1,"page":1,"pagecount":3,"total":41,"limit":20,"list":[{"vod_id":1,"vod_name":"Available title","type_name":"国产剧"}]}"#
        } else if mode == "category-malformed" {
            body = #"{"code":1,"list":"invalid"}"#
        } else {
            body = #"{"code":1,"page":1,"pagecount":3,"total":41,"limit":20,"list":[],"class":[{"type_id":13,"type_name":"国产剧","type_pid":2}]}"#
        }
        let data = Data(body.utf8)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json", "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
