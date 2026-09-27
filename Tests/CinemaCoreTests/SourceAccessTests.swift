import Foundation
import Testing
@testable import CinemaCore

struct SourceAccessTests {
    private func client() -> BoundedHTTPClient {
        let config = SourceRequestRouting.withoutHTTPProxy.configuration()
        config.protocolClasses = [SourceAccessFixture.self]
        return BoundedHTTPClient(timeout: 8, configuration: config)
    }
    private func provider(_ mode: String) -> SourceProvider {
        SourceProvider(id: "wujin", name: "Fixture", endpoint: URL(string: "https://access-fixture.test/api?mode=\(mode)")!)
    }
    @Test func httpProxyBypassIsExplicitAndSystemDefaultIsPreserved() {
        let values = SourceRequestRouting.withoutHTTPProxy.configuration().connectionProxyDictionary ?? [:]
        for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] {
            #expect((values[key] as? NSNumber)?.intValue == 0)
        }
        #expect(SourceRequestRouting.system.configuration().connectionProxyDictionary == nil)
    }
    @Test func followsRealCatalogToPlaylistAndBoundedSegmentPrefix() async throws {
        let result = try await SourceAccessProbe(client: client()).check(provider: provider("good"))
        #expect(result.catalogReachable && result.playlistReachable && result.segmentReachable)
        #expect(result.passed && result.sampleBytes == 65_536)
        #expect(result.sampleTitle == "流浪地球")
        #expect(result.mediaHost == "access-fixture.test")
    }
    @Test func apiSuccessDoesNotMaskAnUnavailableVideo() async throws {
        let result = try await SourceAccessProbe(client: client()).check(provider: provider("segment-fails"))
        #expect(result.catalogReachable && result.playlistReachable)
        #expect(!result.passed && !result.segmentReachable && result.failure != nil)
    }
    @Test func htmlErrorPageIsNotAReadableVideoSegment() async throws {
        let result = try await SourceAccessProbe(client: client()).check(provider: provider("html"))
        #expect(result.playlistReachable && !result.segmentReachable && !result.passed)
    }
    @Test(arguments: ["html-bom", "json-object-bom", "json-array-bom"])
    func longTextErrorDocumentsAreNotReadableSegments(mode: String) async throws {
        let result = try await SourceAccessProbe(client: client()).check(provider: provider(mode))
        #expect(result.playlistReachable && !result.segmentReachable && !result.passed)
        #expect(result.failure?.contains("网页或接口消息") == true)
    }
    @Test(arguments: ["encrypted-angle", "encrypted-brace", "encrypted-bracket", "encrypted-readable-brace"])
    func encryptedBinaryPrefixesAreNotMistakenForTextDocuments(mode: String) async throws {
        let result = try await SourceAccessProbe(client: client()).check(provider: provider(mode))
        #expect(result.encrypted && result.segmentReachable && result.passed)
        #expect(result.sampleBytes == 4096 && result.failure == nil)
    }
    @Test func missingRepresentativeFilmIsNotAConnectivityCertification() async throws {
        let result = try await SourceAccessProbe(client: client()).check(provider: provider("unrelated"))
        #expect(result.catalogReachable && !result.passed && result.sampleTitle == nil)
    }
    @Test func cancelledChecksPropagateCancellation() async {
        let task = Task { try await SourceAccessProbe(client: client()).check(provider: provider("good")) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled check returned a report") }
        catch is CancellationError {} catch let error as URLError { #expect(error.code == .cancelled) }
        catch { Issue.record("Unexpected error: \(error)") }
    }
    @Test func cancellationDuringSegmentTransferPropagatesInsteadOfReturningAReport() async throws {
        let task = Task { try await SourceAccessProbe(client: client()).check(provider: provider("slow-segment")) }
        defer { task.cancel() }
        let started = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = SourceAccessFixture.segmentStarted.stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let value = await group.next() ?? false
            group.cancelAll()
            return value
        }
        try #require(started)
        task.cancel()
        do { _ = try await task.value; Issue.record("An in-flight cancelled check returned a report") }
        catch is CancellationError {} catch let error as URLError { #expect(error.code == .cancelled) }
        catch { Issue.record("Unexpected error: \(error)") }
    }
}

private final class SourceAccessFixture: URLProtocol {
    static let segmentStarted = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "access-fixture.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let mode = query.first { $0.name == "mode" }?.value ?? url.pathComponents.dropFirst().first ?? "good"
        var status = 200, mime = "application/json"
        let data: Data
        if url.path == "/api" {
            let row: [String: Any] = ["vod_id": "1", "vod_name": mode == "unrelated" ? "另一部电影" : "流浪地球", "vod_year": "2019", "vod_play_from": "fixture", "vod_play_url": "正片$https://access-fixture.test/\(mode)/index.m3u8"]
            data = try! JSONSerialization.data(withJSONObject: ["page": 1, "list": [row]])
        } else if url.pathExtension == "m3u8" {
            mime = "application/vnd.apple.mpegurl"
            let key = mode.hasPrefix("encrypted-") ? "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n" : ""
            data = Data(("#EXTM3U\n" + key + "#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST\n").utf8)
        } else if mode == "segment-fails" { status = 503; data = Data("unavailable".utf8) }
        else if mode == "html" || mode == "html-bom" {
            mime = "text/html"
            let bom = mode == "html-bom" ? "\u{FEFF}" : ""
            data = Data((bom + "<!doctype html><html>" + String(repeating: "upstream error ", count: 30) + "</html>").utf8)
        } else if mode == "json-object-bom" || mode == "json-array-bom" {
            let object = "{\"error\":\"" + String(repeating: "upstream error ", count: 30) + "\"}"
            data = Data(("\u{FEFF}" + (mode == "json-array-bom" ? "[" + object + "]" : object)).utf8)
        } else if mode.hasPrefix("encrypted-") {
            mime = "application/octet-stream"
            let first: UInt8 = mode == "encrypted-angle" ? 0x3C : (mode == "encrypted-brace" ? 0x7B : 0x5B)
            // AES ciphertext is opaque binary: its first byte has no text meaning.
            if mode == "encrypted-readable-brace" { data = Data(("{" + String(repeating: "G", count: 4095)).utf8) }
            else { data = Data([first, 0xFF] + (0..<4094).map { UInt8(truncatingIfNeeded: $0 * 73) }) }
        } else if mode == "slow-segment" {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp2t", "Content-Length": "200000"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 0x47, count: 188))
            Self.segmentStarted.continuation.yield(())
            // Leave the response open so cancellation occurs during body iteration.
            return
        }
        else {
            // The server deliberately ignores Range and declares a larger body.
            mime = "video/mp2t"; data = Data(repeating: 0x47, count: 200_000)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": mime, "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
