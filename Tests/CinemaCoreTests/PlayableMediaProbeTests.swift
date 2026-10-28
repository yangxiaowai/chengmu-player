import Foundation
import Testing
@testable import CinemaCore

struct PlayableMediaProbeTests {
    private func probe(timeout: TimeInterval = 2) -> PlayableMediaProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlayableMediaFixture.self]
        return PlayableMediaProbe(timeout: timeout, configuration: configuration)
    }

    @Test func rangeGetRecognizesMP4WithoutFileExtensionOrHead() async throws {
        let result = try await probe().inspect(url: URL(string: "https://media.fixture/play?id=42")!)
        #expect(result == .mp4)
    }
    @Test func recognizesHLSWithoutFileExtension() async throws {
        let result = try await probe().inspect(url: URL(string: "https://media.fixture/playlist?id=42")!)
        #expect(result == .hls)
    }
    @Test func recognizesPlaylistWhenUTF8CharacterCrossesPrefixBoundary() async throws {
        let result = try await probe().inspect(url: URL(string: "https://media.fixture/playlist-split-utf8")!)
        #expect(result == .hls)
    }
    @Test func rejectsErrorPagesAndInvalidContentRange() async {
        for path in ["error-page", "wrong-range", "bad-mp4", "malformed-playlist"] {
            do {
                _ = try await probe().inspect(url: URL(string: "https://media.fixture/\(path)")!)
                Issue.record("Invalid media was accepted: \(path)")
            } catch { }
        }
    }
    @Test func rejectsCredentialAndNonHTTPURLs() async {
        for value in ["file:///tmp/video.mp4", "ftp://media.fixture/file", "https://user:pass@media.fixture/video"] {
            do { _ = try await probe().inspect(url: URL(string: value)!); Issue.record("Invalid URL accepted") }
            catch { }
        }
    }
    @Test func timeoutAndCancellationAreBounded() async throws {
        let start = Date()
        do { _ = try await probe(timeout: 0.25).inspect(url: URL(string: "https://media.fixture/slow")!); Issue.record("Timeout was not enforced") }
        catch { #expect(Date().timeIntervalSince(start) < 2) }
        let task = Task { try await probe(timeout: 2).inspect(url: URL(string: "https://media.fixture/slow")!) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let cancelStart = Date()
        do { _ = try await task.value; Issue.record("Canceled probe succeeded") }
        catch { #expect(Date().timeIntervalSince(cancelStart) < 1) }
    }
}

private final class PlayableMediaFixture: URLProtocol {
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "media.fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, request.httpMethod == "GET" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let isPlaylist = url.path == "/playlist" || url.path == "/playlist-split-utf8" || url.path == "/malformed-playlist"
        let data: Data
        switch url.path {
        case "/playlist": data = Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8)
        case "/playlist-split-utf8": data = Data(("#EXTM3U\n#" + String(repeating: "a", count: 246) + "中文\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n").utf8)
        case "/malformed-playlist": data = Data("#EXTM3U\nerror\n".utf8)
        case "/error-page": data = Data("<!DOCTYPE html><html>Not authorized</html>".utf8)
        case "/bad-mp4": data = Data("xxxxftyp definitely not a valid MP4 box".utf8)
        default: data = Data([0, 0, 0, 24]) + Data("ftypisom".utf8) + Data(repeating: 0, count: 16)
        }
        let hasRange = request.value(forHTTPHeaderField: "Range") != nil
        let header: String = url.path == "/wrong-range" ? "bytes 40-\(39 + data.count)/1000" : "bytes 0-\(data.count - 1)/1000"
        let headers = ["Content-Length": String(data.count), "Content-Type": isPlaylist ? "application/vnd.apple.mpegurl" : "application/octet-stream", "Content-Range": header]
        let pending = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: url, statusCode: hasRange ? 206 : 200, httpVersion: nil, headerFields: headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        work = pending
        DispatchQueue.global().asyncAfter(deadline: .now() + (url.path == "/slow" ? 3 : 0), execute: pending)
    }
    override func stopLoading() { work?.cancel() }
}
