import Foundation
import Testing
@testable import CinemaCore

private actor PageCollector {
    var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
    func snapshot() -> [String] { ids }
}

struct IncrementalSearchTests {
    private func fixture() -> (SourceService, [SourceProvider]) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IncrementalSearchProtocol.self]
        let service = SourceService(client: BoundedHTTPClient(configuration: configuration))
        return (service, [
            SourceProvider(id: "slow", name: "Slow", endpoint: URL(string: "https://slow.search-fixture.test/api")!),
            SourceProvider(id: "fast", name: "Fast", endpoint: URL(string: "https://fast.search-fixture.test/api")!)
        ])
    }

    @Test func fastPageIsDeliveredBeforeSlowProviderCompletes() async throws {
        let (service, sources) = fixture(), collector = PageCollector()
        let task = Task {
            await service.searchPages(query: "fixture", providers: sources, onPage: { result in await collector.add(result.providerID) })
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await collector.snapshot() == ["fast"])
        let final = await task.value
        #expect(final.map(\.providerID) == ["slow", "fast"])
        #expect(Set(await collector.snapshot()) == Set(["fast", "slow"]))
    }

    @Test func cancellationDoesNotDeliverLatePages() async throws {
        let (service, sources) = fixture(), collector = PageCollector()
        let task = Task {
            await service.searchPages(query: "fixture", providers: sources, onPage: { result in await collector.add(result.providerID) })
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        let final = await task.value
        try await Task.sleep(nanoseconds: 1_100_000_000)
        #expect(final.isEmpty)
        #expect(await collector.snapshot() == ["fast"])
    }
}

private final class IncrementalSearchProtocol: URLProtocol {
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".search-fixture.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let delay = url.host?.hasPrefix("slow.") == true ? 1.0 : 0.03
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let body = Data(#"{"code":1,"page":1,"pagecount":1,"total":1,"list":[{"vod_id":1,"vod_name":"fixture"}]}"#.utf8)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json", "Content-Length": String(body.count)])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }
    override func stopLoading() { pending?.cancel() }
}
