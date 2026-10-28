import Foundation

/// A bounded media-prefix inspection. A successful result does not prove that a full
/// video will decode or play, that any rights exist, or that network conditions remain stable.
public struct PlayableMediaProbe {
    public enum Kind: Equatable, Sendable { case hls, mp4 }
    private let timeout: TimeInterval
    private let configuration: URLSessionConfiguration
    private static let prefixLimit = 65_536

    public init(timeout: TimeInterval = 5, routing: SourceRequestRouting = .system) {
        self.init(timeout: timeout, configuration: routing.configuration())
    }
    init(timeout: TimeInterval, configuration: URLSessionConfiguration) {
        self.timeout = timeout.isFinite && timeout > 0 ? min(timeout, 5) : 5
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil
        self.configuration = config
    }

    public func inspect(url: URL) async throws -> Kind {
        try Task.checkCancellation()
        guard networkURL(url.absoluteString) != nil else { throw SourceError.invalidURL }
        let timeout = self.timeout
        return try await withThrowingTaskGroup(of: Kind.self) { group in
            group.addTask { try await inspectUnbounded(url: url) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw SourceError.invalidResponse }
            return result
        }
    }

    private func inspectUnbounded(url: URL) async throws -> Kind {
        let (data, finalURL) = try await readPrefix(url)
        // A prefix may end in the middle of a UTF-8 character. Lossy detection
        // only checks the ASCII header; HLSProbe strictly decodes the full playlist.
        let header = String(decoding: data.prefix(256), as: UTF8.self)
        if header.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).hasPrefix("#EXTM3U") {
            let client = BoundedHTTPClient(timeout: timeout, maximumBytes: 2 * 1024 * 1024, configuration: configuration)
            _ = try await HLSProbe(client: client).inspect(url: finalURL)
            return .hls
        }
        guard data.count >= 16, data[4..<8].elementsEqual("ftyp".utf8) else { throw SourceError.invalidResponse }
        let size = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size >= 16, size <= 4096, data.count >= Int(size) else { throw SourceError.invalidResponse }
        return .mp4
    }

    private func readPrefix(_ url: URL) async throws -> (Data, URL) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: PlayableMediaRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Cinema/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-\(Self.prefixLimit - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        guard http.statusCode == 200 || http.statusCode == 206 else { throw SourceError.httpStatus(http.statusCode) }
        guard let finalURL = response.url, networkURL(finalURL.absoluteString) != nil else { throw SourceError.invalidURL }
        if http.statusCode == 206 {
            guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                  range.range(of: #"^bytes\s+0-[0-9]+/(?:[0-9]+|\*)$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
                throw SourceError.invalidResponse
            }
        }
        var data = Data(); data.reserveCapacity(Self.prefixLimit)
        for try await byte in bytes {
            if data.count % 4096 == 0 { try Task.checkCancellation() }
            data.append(byte)
            if data.count == Self.prefixLimit { break }
        }
        try Task.checkCancellation()
        return (data, finalURL)
    }
}

private final class PlayableMediaRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, networkURL(url.absoluteString) != nil else { completionHandler(nil); return }
        completionHandler(request)
    }
}
