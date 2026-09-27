import Foundation
import CryptoKit

/// Streams responses into a bounded buffer; URLSession resource timeout also bounds slow-drip responses.
struct BoundedHTTPClient {
    var timeout: TimeInterval = 15
    var maximumBytes: Int = 4 * 1024 * 1024
    func get(_ url: URL) async throws -> (Data, URL) {
        guard networkURL(url.absoluteString) != nil else { throw SourceError.invalidURL }
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Cinema/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SourceError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw SourceError.httpStatus(http.statusCode) }
        guard response.expectedContentLength <= maximumBytes else { throw SourceError.responseTooLarge }
        guard let finalURL = response.url, networkURL(finalURL.absoluteString) != nil else { throw SourceError.invalidURL }
        var data = Data()
        data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            if data.count % 16384 == 0 { try Task.checkCancellation() }
            guard data.count < maximumBytes else { throw SourceError.responseTooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, finalURL)
    }
}

public struct SourceService {
    public init() {}
    public func search(query: String, providers: [SourceProvider] = SourceProvider.defaults) async -> SearchResponse {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !Task.isCancelled else { return SearchResponse(titles: [], failures: []) }
        let enabled = Array(providers.filter(\.enabled).prefix(24))
        // Three simultaneous requests at most; indexed results retain provider order.
        var results: [(Int, [MediaTitle], String?)] = []
        await withTaskGroup(of: (Int, [MediaTitle], String?).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let provider = enabled[index]
                group.addTask {
                    do {
                        let url = try Self.requestURL(provider: provider, action: provider.searchAction == "detail" ? "detail" : "list", parameters: ["wd": query])
                        let (data, _) = try await BoundedHTTPClient().get(url)
                        return (index, try Self.parseSearch(data: data, provider: provider), nil)
                    } catch {
                        if Task.isCancelled { return (index, [], nil) }
                        return (index, [], "\(provider.name)：\(Self.safeDescription(error))")
                    }
                }
            }
            while next < min(3, enabled.count) { enqueue(next); next += 1 }
            while let result = await group.next() {
                results.append(result)
                if Task.isCancelled { group.cancelAll() }
                else if next < enabled.count { enqueue(next); next += 1 }
            }
        }
        guard !Task.isCancelled else { return SearchResponse(titles: [], failures: []) }
        let ordered = results.sorted { $0.0 < $1.0 }
        return SearchResponse(titles: ordered.flatMap { $0.1 }, failures: ordered.compactMap { $0.2 })
    }
    public func detail(title: MediaTitle, provider: SourceProvider) async throws -> MediaDetail {
        guard title.providerID == provider.id else { throw SourceError.invalidResponse }
        let url = try Self.requestURL(provider: provider, action: "detail", parameters: ["ids": title.id])
        let (data, _) = try await BoundedHTTPClient().get(url)
        return try Self.parseDetail(data: data, title: title)
    }
    public static func requestURL(provider: SourceProvider, action: String, parameters: [String: String]) throws -> URL {
        guard provider.endpoint.scheme?.lowercased() == "https", networkURL(provider.endpoint.absoluteString) != nil,
              var parts = URLComponents(url: provider.endpoint, resolvingAgainstBaseURL: false) else { throw SourceError.invalidURL }
        var items = parts.queryItems ?? []
        let replaced = Set(parameters.keys).union(["ac"])
        items.removeAll { replaced.contains($0.name) }
        items.append(URLQueryItem(name: "ac", value: action))
        items += parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        parts.queryItems = items
        guard let url = parts.url else { throw SourceError.invalidURL }
        return url
    }
    public static func parseSearch(data: Data, provider: SourceProvider) throws -> [MediaTitle] {
        try rows(data).compactMap { row in
            let id = string(row["vod_id"]), name = string(row["vod_name"])
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return MediaTitle(id: id, title: name, year: string(row["vod_year"]), posterURL: networkURL(string(row["vod_pic"])), summary: plainText(string(row["vod_content"])), providerID: provider.id, providerName: provider.name)
        }
    }
    public static func parseDetail(data: Data, title: MediaTitle) throws -> MediaDetail {
        let allRows = try rows(data)
        guard let row = allRows.first(where: { string($0["vod_id"]) == title.id }) else { throw SourceError.emptyDetail }
        // Details may reveal a different season than a stale search row. Preserve provider identity,
        // but use actual nonempty detail fields so the caller can reject mismatched media.
        var confirmedTitle = title
        let actualName = string(row["vod_name"]), actualYear = string(row["vod_year"])
        let actualSummary = plainText(string(row["vod_content"]))
        if !actualName.isEmpty { confirmedTitle.title = actualName }
        if !actualYear.isEmpty { confirmedTitle.year = actualYear }
        if let poster = networkURL(string(row["vod_pic"])) { confirmedTitle.posterURL = poster }
        if !actualSummary.isEmpty { confirmedTitle.summary = actualSummary }
        let names = string(row["vod_play_from"]).components(separatedBy: "$$$")
        let blocks = string(row["vod_play_url"]).components(separatedBy: "$$$")
        var lines: [PlaybackLine] = []
        for (lineIndex, block) in blocks.enumerated() {
            let name = lineIndex < names.count && !names[lineIndex].isEmpty ? names[lineIndex] : "未命名线路"
            // Named lines and media URLs survive provider reordering; array offsets do not.
            let duplicateName = names.filter { $0 == name }.count > 1 || name == "未命名线路"
            let disambiguator = duplicateName ? block.components(separatedBy: "#").sorted().joined(separator: "#") : ""
            let lineID = "\(title.providerID):\(title.id):\(stableDigest(name + disambiguator))"
            var seenEpisodes = Set<String>()
            let episodes: [Episode] = block.components(separatedBy: "#").compactMap { entry in
                guard let separator = entry.firstIndex(of: "$") else { return nil }
                let name = String(entry[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let url = networkURL(String(entry[entry.index(after: separator)...])),
                      !url.path.lowercased().contains("/share/"),
                      !["html", "htm"].contains(url.pathExtension.lowercased()) else { return nil }
                let number = episodeNumber(name)
                let episodeID = "\(lineID):\(stableDigest(name + "|" + url.absoluteString))"
                guard seenEpisodes.insert(episodeID).inserted else { return nil }
                return Episode(id: episodeID, name: name, url: url, number: number)
            }.sorted { a, b in
                if let x = a.number, let y = b.number, x != y { return x < y }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            guard !episodes.isEmpty else { continue }
            guard !lines.contains(where: { $0.id == lineID }) else { continue }
            lines.append(PlaybackLine(id: lineID, name: name, episodes: episodes))
        }
        guard !lines.isEmpty else { throw SourceError.emptyDetail }
        return MediaDetail(title: confirmedTitle, lines: lines)
    }
    private static func stableDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    private static func rows(_ data: Data) throws -> [[String: Any]] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let list = root["list"] as? [[String: Any]] else { throw SourceError.invalidResponse }
        if let code = root["code"], !["1", "200"].contains(string(code)) { throw SourceError.invalidResponse }
        return list
    }
    private static func string(_ value: Any?) -> String {
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
    private static func episodeNumber(_ value: String) -> Int? {
        // S01E02 should select episode 2, rather than season 1.
        for pattern in ["(?i)E(?:P)?\\s*(\\d+)", "第\\s*(\\d+)\\s*[集话期]", "(\\d+)"] {
            if let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)), let range = Range(match.range(at: 1), in: value) { return Int(value[range]) }
        }
        return nil
    }
    private static func plainText(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func safeDescription(_ error: Error) -> String {
        if let error = error as? SourceError { return error.localizedDescription }
        if let error = error as? URLError { return "网络错误（\(error.code.rawValue)）" }
        // Avoid surfacing URLs or API query tokens from arbitrary error descriptions.
        return "目录解析失败"
    }
}
