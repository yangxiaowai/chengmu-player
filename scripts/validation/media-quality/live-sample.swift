import CinemaCore
import Foundation

/// Deliberately samples only the specified public Mux playlist and one mdzy episode.
@main
struct LiveMediaQualityValidation {
    struct Observation: Codable {
        var label: String
        var url: URL?
        var stage: String
        var elapsedSeconds: Double?
        var metadata: MediaQualitySample?
        var error: String?
        var errorDomain: String?
        var errorCode: Int?
        var query: String?
        var provider: SourceProvider?
        var configurationSource: String?
        var searchResultCount: Int?
        var catalogTitle: String?
        var catalogID: String?
        var line: String?
        var episode: String?
    }
    struct Report: Codable {
        var checkedAt = Date()
        var metadataTimeoutSeconds = 8
        var routing = "SourceService default/system routing; AVURLAsset default routing"
        var observations: [Observation]
        var boundaries = [
            "AVFoundation track metadata is attempted first; HLS may prepare a private muted AVPlayerItem, then read at most its first available video output frame if dimensions remain unavailable.",
            "The private player disables display-sleep prevention and is paused/detached on success, timeout or cancellation; no whole-movie playback/download, AVAssetReader or ffprobe is used.",
            "AVFoundation may fetch playlists and initial media bytes needed to discover track metadata.",
            "Metadata describes the track exposed by this asset load, not every HLS variant or a later player selection.",
            "This host's result does not certify mainland-China direct access, perceptual quality, continuous playback, or content identity."
        ]
    }

    static func inspect(_ url: URL, observation: inout Observation) async {
        observation.url = url
        observation.stage = "AVFoundation track metadata"
        let start = Date()
        do { observation.metadata = try await MediaQualityProbe(timeout: 8).inspect(url: url) }
        catch {
            let nsError = error as NSError
            observation.error = error.localizedDescription
            observation.errorDomain = nsError.domain
            observation.errorCode = nsError.code
        }
        observation.elapsedSeconds = Date().timeIntervalSince(start)
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { return }
        var official = Observation(label: "Mux public HLS", stage: "pending")
        await inspect(URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!, observation: &official)
        print("Mux: \(official.metadata?.summary ?? official.error ?? "unknown")")

        let query = "星际穿越"
        let defaults = UserDefaults(suiteName: "local.yingchuan.cinema")
        let saved = defaults?.data(forKey: "sourceProviders").flatMap { try? JSONDecoder().decode([SourceProvider].self, from: $0) }
        let savedProvider = saved?.first(where: { $0.id == "mdzy" })
        let provider = savedProvider ?? SourceProvider.defaults.first(where: { $0.id == "mdzy" })!
        var catalog = Observation(label: "mdzy single episode", stage: "catalog search", query: query,
                                  provider: provider, configurationSource: savedProvider == nil ? "built-in fallback" : "local.yingchuan.cinema sourceProviders")
        let service = SourceService()
        if !provider.enabled {
            catalog.error = "Configured provider is disabled; no catalog request issued"
        } else {
            let result = await service.search(query: query, providers: [provider])
            catalog.searchResultCount = result.titles.count
            if !result.failures.isEmpty {
                catalog.error = result.failures.joined(separator: "; ")
            } else if let title = result.titles.first(where: { $0.title == query }) {
                catalog.catalogTitle = title.title
                catalog.catalogID = title.id
                catalog.stage = "catalog detail"
                do {
                    let detail = try await service.detail(title: title, provider: provider)
                    catalog.catalogTitle = detail.title.title
                    guard detail.title.title == query, let line = detail.lines.first,
                          let episode = line.episodes.first else {
                        throw ValidationFailure.noMatchingEpisode
                    }
                    catalog.line = line.name
                    catalog.episode = episode.name
                    await inspect(episode.url, observation: &catalog)
                } catch {
                    catalog.error = error.localizedDescription
                    catalog.errorDomain = (error as NSError).domain
                    catalog.errorCode = (error as NSError).code
                }
            } else {
                catalog.error = "No exact-title result; no other title or provider attempted"
            }
        }
        print("mdzy: \(catalog.metadata?.summary ?? catalog.error ?? "unknown")")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Report(observations: [official, catalog])).write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
    }

    enum ValidationFailure: LocalizedError {
        case noMatchingEpisode
        var errorDescription: String? { "Detail title changed or no first episode; no additional title/line attempted" }
    }
}
