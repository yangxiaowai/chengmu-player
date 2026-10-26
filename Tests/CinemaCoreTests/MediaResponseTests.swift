import Foundation
import Testing
@testable import CinemaCore

struct MediaResponseTests {
    private func probe() -> MediaResponseProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaResponseFixture.self]
        return MediaResponseProbe(timeout: 1, configuration: configuration)
    }
    @Test func includesServerDelayBeforeResponseHeaders() async throws {
        let response = try await probe().inspect(url: URL(string: "https://response.fixture/delayed-headers")!)
        #expect(response.milliseconds >= 120)
        #expect(response.milliseconds < 2000)
    }
    @Test func largeResponseCanBeStoppedAtHeadersWithoutWaitingForBody() async throws {
        let response = try await probe().inspect(url: URL(string: "https://response.fixture/large")!)
        #expect(response.milliseconds > 0)
    }
    @Test func httpFailureDoesNotBecomeASuccessfulResponse() async {
        for path in ["failure", "method-not-supported"] {
            do { _ = try await probe().inspect(url: URL(string: "https://response.fixture/\(path)")!); Issue.record("Invalid response was timed as a working source") }
            catch {}
        }
    }
    @Test func invalidAndCredentialBearingURLsAreRejected() async {
        for value in ["file:///tmp/movie.mp4", "ftp://response.fixture/movie", "https://user:secret@response.fixture/movie"] {
            do { _ = try await probe().inspect(url: URL(string: value)!); Issue.record("Invalid URL accepted") }
            catch {}
        }
    }
    @Test func cancellationDoesNotBecomeAResponseMeasurement() async {
        let task = Task { try await probe().inspect(url: URL(string: "https://response.fixture/large")!) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled request returned a latency") }
        catch is CancellationError {} catch let error as URLError { #expect(error.code == .cancelled) }
        catch { Issue.record("Unexpected cancellation error: \(error)") }
    }
}

private final class MediaResponseFixture: URLProtocol {
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "response.fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        // HEAD measures a response without transferring a media body or using Range.
        guard request.httpMethod == "HEAD", request.value(forHTTPHeaderField: "Range") == nil else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: url.path == "/failure" ? 503 : (url.path == "/method-not-supported" ? 405 : 200), httpVersion: nil, headerFields: ["Content-Length": "1000000"])!, cacheStoragePolicy: .notAllowed)
            // A completed HEAD transaction contains no body, irrespective of Content-Length.
            self.client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + (url.path == "/delayed-headers" ? 0.15 : 0), execute: work)
    }
    override func stopLoading() { pending?.cancel() }
}
