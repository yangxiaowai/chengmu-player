import Foundation
import AVFoundation
import CFNetwork
import UniformTypeIdentifiers
import Synchronization

/// Bytes received over one monotonic interval, not the source's advertised bitrate.
struct DirectTransferRateTracker {
    private var previous: (bytes: UInt64, time: TimeInterval)?
    mutating func sample(bytes: UInt64, at time: TimeInterval) -> Double? {
        guard time.isFinite, time >= 0 else { previous = nil; return nil }
        guard let prior = previous, time > prior.time, bytes >= prior.bytes else {
            previous = (bytes, time); return nil
        }
        let elapsed = time - prior.time
        guard elapsed >= 0.5 else { return nil }
        previous = (bytes, time)
        return Double(bytes - prior.bytes) / elapsed
    }
}

/// Stream ordinary, unauthenticated progressive video through a no-HTTP-proxy URLSession.
/// HLS, authenticated URLs, DRM and unsupported containers continue through AVFoundation.
private final class DirectPlaybackSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let url = request.url,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host != nil,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              HTTPCookieStorage.shared.cookies(for: url)?.isEmpty != false,
              !(original.scheme?.lowercased() == "https" && c.scheme?.lowercased() != "https") else { completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleAuthentication(challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handleAuthentication(challenge, completionHandler: completionHandler)
    }
    private func handleAuthentication(_ challenge: URLAuthenticationChallenge,
                                      completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

private enum DirectPlaybackSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0,
            kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0
        ]
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 3600
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: DirectPlaybackSessionDelegate(), delegateQueue: nil)
    }()
}

final class DirectProgressiveResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    let originalURL: URL
    let asset: AVURLAsset
    private let queue = DispatchQueue(label: "cinema.direct-resource-loader", qos: .userInitiated)
    private let lock = NSLock()
    private let receivedBytes = Atomic<UInt64>(0)
    var receivedByteCount: UInt64 { receivedBytes.load(ordering: .relaxed) }
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var invalidated = false
    private let session = DirectPlaybackSession.shared

    static func supports(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              c.host != nil, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              HTTPCookieStorage.shared.cookies(for: url)?.isEmpty != false else { return false }
        return ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }
    init?(url: URL) {
        guard Self.supports(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        originalURL = url
        components.scheme = "cinemadirect"
        guard let mapped = components.url else { return nil }
        asset = AVURLAsset(url: mapped)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }
    func stop() {
        let active = lock.withLock { () -> [Task<Void, Never>] in
            invalidated = true
            let result = Array(requests.values)
            requests.removeAll()
            return result
        }
        active.forEach { $0.cancel() }
        // This process-wide session serves other items; only this item's tasks are canceled.
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        // Never handle external references, keys or another resource as if it were the movie.
        guard request.request.url == asset.url else { return false }
        let key = ObjectIdentifier(request)
        return lock.withLock {
            guard !invalidated else { return false }
            // Register while holding the lock so a fast failure cannot finish before registration.
            // The resource loader delegate is not guaranteed to be retained by AVFoundation.
            // Retain it until the request is finished; stop() clears the dictionary and
            // cancels tasks, while normal completion removes its own dictionary entry.
            requests[key] = Task { [self] in
                do {
                    try await self.load(request)
                    await self.finish(request, error: nil)
                } catch {
                    // stop() cancels this task while AVFoundation may still be waiting for the
                    // loading request. Finish it exactly once unless AVFoundation canceled it.
                    await self.finish(request, error: error)
                }
                _ = self.lock.withLock { self.requests.removeValue(forKey: key) }
            }
            return true
        }
    }
    private func finish(_ request: AVAssetResourceLoadingRequest, error: Error?) async {
        await withCheckedContinuation { continuation in
            queue.async {
                if !request.isCancelled && !request.isFinished {
                    if let error { request.finishLoading(with: error) } else { request.finishLoading() }
                }
                continuation.resume()
            }
        }
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        lock.withLock { requests.removeValue(forKey: ObjectIdentifier(request)) }?.cancel()
    }
    private func load(_ request: AVAssetResourceLoadingRequest) async throws {
        try Task.checkCancellation()
        var outgoing = URLRequest(url: originalURL)
        outgoing.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        outgoing.setValue("Cinema-Direct/1.0", forHTTPHeaderField: "User-Agent")
        let dataRequest = request.dataRequest
        let offset: Int64 = dataRequest.map { max($0.requestedOffset, $0.currentOffset) } ?? 0
        let wanted: Int64? = dataRequest.flatMap { $0.requestsAllDataToEndOfResource ? nil : Int64($0.requestedLength) }
        if let dataRequest {
            if dataRequest.requestsAllDataToEndOfResource {
                outgoing.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            } else {
                guard let wanted, wanted > 0, offset >= 0 else { throw URLError(.badServerResponse) }
                let (end, overflow) = offset.addingReportingOverflow(wanted - 1)
                guard !overflow else { throw URLError(.badServerResponse) }
                outgoing.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            }
        }
        let (bytes, response) = try await session.bytes(for: outgoing)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let finalURL = response.url, ["http", "https"].contains(finalURL.scheme?.lowercased() ?? ""),
              finalURL.user == nil, finalURL.password == nil else { throw URLError(.badServerResponse) }
        guard http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else { throw URLError(.cannotDecodeContentData) }
        if offset > 0 && http.statusCode != 206 { throw URLError(.cannotDecodeContentData) }
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        let contentLength: Int64
        if http.statusCode == 206 {
            guard let value = contentRange else { throw URLError(.badServerResponse) }
            let prefixAndRange = value.split(separator: " ", maxSplits: 1)
            guard prefixAndRange.count == 2, prefixAndRange[0].lowercased() == "bytes" else { throw URLError(.badServerResponse) }
            let rangeAndTotal = prefixAndRange[1].split(separator: "/", omittingEmptySubsequences: false)
            guard rangeAndTotal.count == 2, let total = Int64(rangeAndTotal[1]), total > 0 else { throw URLError(.badServerResponse) }
            let bounds = rangeAndTotal[0].split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
                  start == offset, end >= start, end < total else { throw URLError(.badServerResponse) }
            let rangeLength = end - start + 1
            guard response.expectedContentLength < 0 || response.expectedContentLength == rangeLength else { throw URLError(.badServerResponse) }
            contentLength = total
        } else {
            contentLength = response.expectedContentLength
        }
        guard contentLength > 0 else { throw URLError(.badServerResponse) }
        if let info = request.contentInformationRequest {
            let mime = response.mimeType ?? ""
            guard !["text/html", "application/vnd.apple.mpegurl", "application/x-mpegurl"].contains(mime.lowercased()) else { throw URLError(.cannotDecodeContentData) }
            info.contentType = UTType(mimeType: mime)?.identifier ?? UTType.mpeg4Movie.identifier
            info.contentLength = contentLength
            info.isByteRangeAccessSupported = http.statusCode == 206 || http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        }
        guard let dataRequest else { return }
        var buffer = Data(); buffer.reserveCapacity(32 * 1024)
        var received: Int64 = 0
        // Publish only bytes already read, in small batches to avoid an atomic operation per byte.
        var pendingCount: UInt64 = 0
        defer { if pendingCount > 0 { _ = receivedBytes.wrappingAdd(pendingCount, ordering: .relaxed) } }
        for try await byte in bytes {
            try Task.checkCancellation()
            pendingCount += 1
            if pendingCount == 4096 { _ = receivedBytes.wrappingAdd(pendingCount, ordering: .relaxed); pendingCount = 0 }
            buffer.append(byte); received += 1
            if buffer.count == 32 * 1024 { dataRequest.respond(with: buffer); buffer.removeAll(keepingCapacity: true) }
            if let wanted, received >= wanted { break }
        }
        if !buffer.isEmpty { dataRequest.respond(with: buffer) }
        if let wanted, received < min(wanted, max(0, contentLength - offset)) { throw URLError(.networkConnectionLost) }
    }
}
