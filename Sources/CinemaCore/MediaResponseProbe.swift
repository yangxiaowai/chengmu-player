import Foundation

/// Time until valid HTTP response headers for the media address, not player startup or bandwidth.
public struct MediaResponseSample: Equatable, Sendable {
    public let milliseconds: Int
    public init(milliseconds: Int) { self.milliseconds = max(1, milliseconds) }
}

public struct MediaResponseProbe {
    private let configuration: URLSessionConfiguration
    public init(timeout: TimeInterval = 3) {
        self.init(timeout: timeout, configuration: .ephemeral)
    }
    init(timeout: TimeInterval, configuration: URLSessionConfiguration) {
        let value = configuration.copy() as! URLSessionConfiguration
        value.urlCache = nil; value.requestCachePolicy = .reloadIgnoringLocalCacheData
        value.httpShouldSetCookies = false; value.httpCookieStorage = nil
        let timeout = timeout.isFinite && timeout > 0 ? min(timeout, 3) : 3
        value.timeoutIntervalForRequest = timeout; value.timeoutIntervalForResource = timeout
        self.configuration = value
    }
    public func inspect(url: URL) async throws -> MediaResponseSample {
        try Task.checkCancellation()
        guard networkURL(url.absoluteString) != nil else { throw SourceError.invalidURL }
        return try await MediaResponseRequest().run(url: url, configuration: configuration)
    }
}

/// Stop at the response headers so body buffering/transfer does not inflate the
/// reported response time and a large media file is never deliberately downloaded.
private final class MediaResponseRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let started = ContinuousClock.now
    private var result: Result<MediaResponseSample, Error>?
    private var continuation: CheckedContinuation<MediaResponseSample, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?

    func run(url: URL, configuration: URLSessionConfiguration) async throws -> MediaResponseSample {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(with: result); return }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: configuration.timeoutIntervalForRequest)
                request.httpMethod = "HEAD"
                request.setValue("Cinema/1.0", forHTTPHeaderField: "User-Agent")
                let task = session.dataTask(with: request); self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.complete(.failure(CancellationError())) }
    }
    private func complete(_ value: Result<MediaResponseSample, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = continuation, session = session, task = task
        self.continuation = nil; self.session = nil; self.task = nil
        lock.unlock()
        task?.cancel(); session?.invalidateAndCancel(); continuation?.resume(with: value)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, let url = response.url, networkURL(url.absoluteString) != nil else {
            completionHandler(.cancel); complete(.failure(SourceError.invalidResponse)); return
        }
        guard (200...299).contains(http.statusCode) else {
            completionHandler(.cancel); complete(.failure(SourceError.httpStatus(http.statusCode))); return
        }
        let elapsed = started.duration(to: .now).components
        let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        completionHandler(.cancel)
        complete(.success(.init(milliseconds: Int(ceil(ms)))))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        complete(.failure(error ?? SourceError.invalidResponse))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, networkURL(url.absoluteString) != nil else {
            completionHandler(nil); complete(.failure(SourceError.invalidURL)); return
        }
        completionHandler(request)
    }
}
