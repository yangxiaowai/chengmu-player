import Foundation
import CFNetwork
import Darwin

/// Narrow HLS relay: unsigned same-origin HTTP playlists only. Everything else stays
/// on AVPlayer's normal network path; this is not a general-purpose HTTP proxy.
final class DirectHLSRelay: @unchecked Sendable {
    private final class Delegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            // Relative playlist URLs are resolved against the original response. Avoid
            // rewriting against an unverified redirect destination.
            completionHandler(nil)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }
    private let lock = NSLock()
    private let token = UUID().uuidString + UUID().uuidString
    private let onFailure: @Sendable () -> Void
    private var listener: Int32 = -1
    private var connections: Set<Int32> = []
    private var tasks: [Int32: Task<Void, Never>] = [:]
    private var targets: [String: URL] = [:]
    private var targetIDs: [URL: String] = [:]
    private var stopped = false
    private let slots = DispatchSemaphore(value: 8)
    private(set) var url: URL!
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: 0, kCFNetworkProxiesHTTPSEnable as String: 0, kCFNetworkProxiesSOCKSEnable as String: 0, kCFNetworkProxiesProxyAutoConfigEnable as String: 0, kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0]
        c.timeoutIntervalForRequest = 8; c.timeoutIntervalForResource = 3600
        c.httpShouldSetCookies = false; c.httpCookieStorage = nil; c.urlCredentialStorage = nil; c.urlCache = nil
        return URLSession(configuration: c, delegate: Delegate(), delegateQueue: nil)
    }()

    static func supports(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""), c.host != nil,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              HTTPCookieStorage.shared.cookies(for: url)?.isEmpty != false else { return false }
        return url.pathExtension.lowercased() == "m3u8"
    }
    private static func allowed(_ url: URL, relativeTo base: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: base, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == b.scheme?.lowercased(), c.host?.lowercased() == b.host?.lowercased(),
              c.port == b.port, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              HTTPCookieStorage.shared.cookies(for: url)?.isEmpty != false else { return false }
        return true
    }
    enum RelayError: Error { case unsupported, invalidResponse }
    static func rewritePlaylist(_ content: String, base: URL, map: (URL) throws -> String) throws -> String {
        guard content.utf8.count <= 2_000_000, content.hasPrefix("#EXTM3U") else { throw RelayError.unsupported }
        let regex = try NSRegularExpression(pattern: "URI=\\\"([^\\\"]+)\\\"")
        func mapped(_ text: String, playlist: Bool) throws -> String {
            guard let target = URL(string: text, relativeTo: base)?.absoluteURL, allowed(target, relativeTo: base),
                  (playlist ? target.pathExtension.lowercased() == "m3u8" : ["ts", "m4s", "mp4", "m4a", "aac", "vtt", "webvtt"].contains(target.pathExtension.lowercased())) else { throw RelayError.unsupported }
            return try map(target)
        }
        var output: [String] = []
        var expectsVariant = false
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") || line.hasPrefix("#EXT-X-CONTENT-STEERING:") || line.hasPrefix("#EXT-X-DEFINE:") { throw RelayError.unsupported }
            if line.hasPrefix("#") {
                let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
                if raw.uppercased().contains("URI=") {
                    guard matches.count == 1, ["#EXT-X-MEDIA:", "#EXT-X-MAP:", "#EXT-X-I-FRAME-STREAM-INF:"].contains(where: line.hasPrefix),
                          let valueRange = Range(matches[0].range(at: 1), in: raw) else { throw RelayError.unsupported }
                    var changed = raw; changed.replaceSubrange(valueRange, with: try mapped(String(raw[valueRange]), playlist: !line.hasPrefix("#EXT-X-MAP:")))
                    output.append(changed)
                } else { output.append(raw); if line.hasPrefix("#EXT-X-STREAM-INF:") { expectsVariant = true } }
            } else if line.isEmpty { output.append(raw) }
            else { output.append(try mapped(line, playlist: expectsVariant)); expectsVariant = false }
        }
        guard !expectsVariant else { throw RelayError.unsupported }
        return output.joined(separator: "\n")
    }

    init?(url source: URL, onFailure: @escaping @Sendable () -> Void = {}) {
        guard Self.supports(source) else { return nil }
        self.onFailure = onFailure
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = 0; address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0, listen(fd, 16) == 0 else { close(fd); return nil }
        var actual = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard named == 0 else { close(fd); return nil }
        listener = fd
        guard let root = try? register(source) else { close(fd); return nil }
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: actual.sin_port))\(root)")!
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop(fd) }
    }
    private func register(_ target: URL) throws -> String {
        try lock.withLock {
            if let id = targetIDs[target] { return "/\(token)/\(id)" }
            guard !stopped, targets.count < 4096 else { throw RelayError.unsupported }
            let id = UUID().uuidString + (target.pathExtension.lowercased() == "m3u8" ? ".m3u8" : ".bin")
            targets[id] = target; targetIDs[target] = id
            return "/\(token)/\(id)"
        }
    }
    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            guard slots.wait(timeout: .now()) == .success else { close(client); continue }
            var flag: Int32 = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            lock.lock()
            if stopped { lock.unlock(); close(client); slots.signal(); break }
            connections.insert(client)
            let task = Task { [self] in await handle(client) }
            tasks[client] = task
            lock.unlock()
        }
    }
    func stop() {
        lock.lock(); if stopped { lock.unlock(); return }; stopped = true
        let server = listener; listener = -1; let active = Array(connections); let running = Array(tasks.values)
        targets.removeAll(); targetIDs.removeAll(); lock.unlock()
        if server >= 0 { shutdown(server, SHUT_RDWR); close(server) }
        for fd in active { shutdown(fd, SHUT_RDWR) }
        running.forEach { $0.cancel() }; session.invalidateAndCancel()
    }
    deinit { stop() }
    private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let pointer = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(fd, pointer.advanced(by: offset), raw.count - offset, 0)
                if count <= 0 { return false }; offset += count
            }
            return true
        }
    }
    private func sendAsync(_ fd: Int32, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: self.sendAll(fd, data)) }
        }
    }
    private func readHeader(_ fd: Int32) -> Data? {
        var request = Data(); var chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while request.count < 16384, request.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let count = recv(fd, &chunk, chunk.count, 0); if count <= 0 { return nil }
            request.append(contentsOf: chunk[0..<count])
        }
        return request.range(of: Data("\r\n\r\n".utf8)) == nil ? nil : request
    }
    private func clientConnected(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let result = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return result > 0 || (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
    }
    private func reply(_ fd: Int32, _ status: Int, headers: [String: String] = [:]) async -> Bool {
        var lines = ["HTTP/1.1 \(status) \(status == 200 ? "OK" : status == 206 ? "Partial Content" : "Bad Gateway")", "Connection: close"]
        lines += headers.map { "\($0.key): \($0.value)" }
        return await sendAsync(fd, Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
    }
    private func handle(_ fd: Int32) async {
        defer {
            lock.withLock { connections.remove(fd); tasks.removeValue(forKey: fd) }
            close(fd); slots.signal()
        }
        let request: Data? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: self.readHeader(fd)) }
        }
        guard let request, let text = String(data: request, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\r\n"), parts = lines[0].split(separator: " ")
        guard parts.count == 3, parts[0] == "GET" else { _ = await reply(fd, 502); return }
        let path = String(parts[1]).split(separator: "/", omittingEmptySubsequences: true)
        guard path.count == 2, path[0] == token else { _ = await reply(fd, 502); return }
        let target = lock.withLock { targets[String(path[1])] }
        guard let target else { _ = await reply(fd, 502); return }
        let rangeLine = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
        let range = rangeLine.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if let range, range.range(of: "^bytes=[0-9]+-[0-9]*$", options: .regularExpression) == nil { _ = await reply(fd, 502); return }
        var outgoing = URLRequest(url: target); outgoing.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        outgoing.setValue("Cinema-HLS-Direct/1.0", forHTTPHeaderField: "User-Agent")
        if let range { outgoing.setValue(range, forHTTPHeaderField: "Range") }
        var started = false
        do {
            let (bytes, response) = try await session.bytes(for: outgoing)
            guard let http = response as? HTTPURLResponse, http.statusCode == (range == nil ? 200 : 206),
                  response.url == target, http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else { throw RelayError.invalidResponse }
            if let range {
                let start = String(range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)[0])
                guard let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
                      let match = contentRange.range(of: "^bytes [0-9]+-[0-9]+/[0-9]+$", options: [.regularExpression, .caseInsensitive]), match == contentRange.startIndex..<contentRange.endIndex else { throw RelayError.invalidResponse }
                let components = contentRange.dropFirst(6).split(separator: "/")
                let bounds = components[0].split(separator: "-")
                let requestedBounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                let requestedEnd = requestedBounds.count == 2 && !requestedBounds[1].isEmpty ? Int64(requestedBounds[1]) : nil
                guard components.count == 2, bounds.count == 2, let actualStart = Int64(bounds[0]), let actualEnd = Int64(bounds[1]), let total = Int64(components[1]),
                      actualStart == Int64(start), actualEnd >= actualStart, actualEnd < total, requestedEnd.map({ actualEnd <= $0 }) ?? true,
                      response.expectedContentLength == actualEnd - actualStart + 1 else { throw RelayError.invalidResponse }
            }
            if target.pathExtension.lowercased() == "m3u8" {
                guard range == nil else { throw RelayError.invalidResponse }
                var data = Data()
                for try await byte in bytes { if data.count >= 2_000_000 { throw RelayError.unsupported }; data.append(byte) }
                guard let text = String(data: data, encoding: .utf8) else { throw RelayError.unsupported }
                let rewritten = try Self.rewritePlaylist(text, base: target) { try self.register($0) }
                let body = Data(rewritten.utf8)
                started = true
                if await reply(fd, 200, headers: ["Content-Type": "application/vnd.apple.mpegurl", "Content-Length": "\(body.count)"]) { _ = await sendAsync(fd, body) }
            } else {
                guard !["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"].contains(response.mimeType?.lowercased() ?? "") else { throw RelayError.unsupported }
                guard response.expectedContentLength >= 0 else { throw RelayError.invalidResponse }
                var iterator = bytes.makeAsyncIterator(), buffer = Data()
                let prefixLength = min(16, response.expectedContentLength)
                while Int64(buffer.count) < prefixLength, let byte = try await iterator.next() { buffer.append(byte) }
                var received = Int64(buffer.count)
                guard !buffer.starts(with: Data("#EXTM3U".utf8)) else { throw RelayError.unsupported }
                var headers = ["Content-Type": response.mimeType ?? "application/octet-stream", "Content-Length": "\(response.expectedContentLength)"]
                if let value = http.value(forHTTPHeaderField: "Content-Range") { headers["Content-Range"] = value }
                if let value = http.value(forHTTPHeaderField: "Accept-Ranges") { headers["Accept-Ranges"] = value }
                started = true
                guard await reply(fd, http.statusCode, headers: headers) else { return }
                buffer.reserveCapacity(32768)
                while let byte = try await iterator.next() {
                    try Task.checkCancellation(); buffer.append(byte); received += 1
                    if buffer.count >= 32768 { guard await sendAsync(fd, buffer) else { return }; buffer.removeAll(keepingCapacity: true) }
                }
                if !buffer.isEmpty { _ = await sendAsync(fd, buffer) }
                guard received == response.expectedContentLength else { throw RelayError.invalidResponse }
            }
        } catch {
            let connected = clientConnected(fd)
            if !started { _ = await reply(fd, 502) }
            if connected && !Task.isCancelled && !lock.withLock({ stopped }) { onFailure() }
        }
    }
}
