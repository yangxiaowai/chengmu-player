import Foundation
import CFNetwork

/// This only controls HTTP/SOCKS/PAC proxy selection. VPN routing and DNS remain
/// system responsibilities; success is not a mainland-China certification.
public enum SourceRequestRouting {
    case system, withoutHTTPProxy
    func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        if self == .withoutHTTPProxy {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 0,
                kCFNetworkProxiesHTTPSEnable as String: 0,
                kCFNetworkProxiesSOCKSEnable as String: 0,
                kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
                kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0
            ]
        }
        return config
    }
}

public struct SourceAccessReport: Codable, Hashable {
    public var providerID: String
    public var checkedAt = Date()
    public var catalogReachable = false
    public var playlistReachable = false
    public var segmentReachable = false
    public var sampleTitle: String?
    public var mediaHost: String?
    public var sampleBytes = 0
    public var elapsedMS = 0
    public var failure: String?
    public var encrypted = false
    public var passed: Bool { catalogReachable && playlistReachable && segmentReachable }
    public init(providerID: String) { self.providerID = providerID }
}

public struct SourceAccessProbe {
    private let client: BoundedHTTPClient
    public init(routing: SourceRequestRouting = .withoutHTTPProxy) {
        client = BoundedHTTPClient(timeout: 8, configuration: routing.configuration())
    }
    init(client: BoundedHTTPClient) { self.client = client }
    public func check(provider: SourceProvider) async throws -> SourceAccessReport {
        try Task.checkCancellation()
        var report = SourceAccessReport(providerID: provider.id)
        let started = Date()
        let sample = ["dytt": "怪奇物语第一季", "ffzy": "怪奇物语第一季", "mdzy": "怪奇物语第一季", "ruyi": "琅琊榜"][provider.id] ?? "流浪地球"
        let service = SourceService(client: client)
        do {
            // An explicit check can also inspect a currently disabled provider.
            var target = provider; target.enabled = true
            let result = await service.search(query: sample, providers: [target])
            try Task.checkCancellation()
            guard result.failures.isEmpty else { throw AccessFailure(result.failures.joined(separator: "；")) }
            report.catalogReachable = true
            guard let title = result.titles.first(where: { CatalogGrouping.normalizedTitle($0.title) == CatalogGrouping.normalizedTitle(sample) }) else {
                throw AccessFailure("目录有响应，但未找到用于检测的《\(sample)》；媒体尚未验证")
            }
            let detail = try await service.detail(title: title, provider: target)
            guard CatalogGrouping.normalizedTitle(detail.title.title) == CatalogGrouping.normalizedTitle(sample),
                  let episode = detail.lines.first?.episodes.first else { throw SourceError.emptyDetail }
            report.sampleTitle = detail.title.title
            var playlistClient = client; playlistClient.maximumBytes = 2 * 1024 * 1024
            let info = try await HLSProbe(client: playlistClient).inspect(url: episode.url)
            report.playlistReachable = true; report.encrypted = info.encrypted
            guard let segment = info.firstSegmentURL else { throw SourceError.invalidPlaylist }
            let (data, finalURL) = try await client.get(segment, prefixBytes: 65_536)
            guard data.count >= 188 else { throw AccessFailure("分片返回的内容过短，尚不能确认媒体可读取") }
            guard !Self.isTextErrorDocument(data) else { throw AccessFailure("分片地址返回了网页或接口消息，未确认为视频数据") }
            report.segmentReachable = true; report.sampleBytes = data.count; report.mediaHost = finalURL.host
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            try Task.checkCancellation()
            report.failure = error.localizedDescription
        }
        report.elapsedMS = max(0, Int(Date().timeIntervalSince(started) * 1000))
        return report
    }
    /// Reject recognizable error documents only. Opaque bytes (including AES
    /// ciphertext) can start with punctuation; accepting them proves readability,
    /// not decoding, key availability, or the identity of the video content.
    private static func isTextErrorDocument(_ data: Data) -> Bool {
        guard let decoded = String(data: data, encoding: .utf8) else { return false }
        let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        guard text.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return false }
        let htmlStart = #"^(?:<!doctype\s+html(?:\s[^>]*)?>|<html(?:\s[^>]*)?>)"#
        if text.range(of: htmlStart, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        guard text.hasPrefix("{") || text.hasPrefix("[") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil
    }
    private struct AccessFailure: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }
}
