import Foundation

@main struct SourceValidation {
    static func main() async {
        let provider = SourceProvider.defaults[0]
        let service = SourceService()
        let series: [(String, [String])] = [("怪奇物语", ["7942", "7943", "7944", "7945", "72633"]), ("绝命毒师", ["13747", "13748", "13749", "13750", "13751"]), ("火线", ["12980", "12982", "12984", "12988", "12990"])]
        var seasons: [[String: Any]] = []
        var work: [(String, String, String, Episode)] = []
        for (name, ids) in series {
            let search = await service.search(query: name, providers: [provider])
            for id in ids {
                do {
                    let title = search.titles.first { $0.id == id } ?? MediaTitle(id: id, title: name, year: "", posterURL: nil, summary: "", providerID: provider.id, providerName: provider.name)
                    let detail = try await service.detail(title: title, provider: provider)
                    guard let line = detail.lines.first else { continue }
                    seasons.append(["series": name, "catalog_id": id, "catalog_title": title.title, "line": line.name, "episodes": line.episodes.count])
                    work += line.episodes.map { (name, id, line.name, $0) }
                } catch { seasons.append(["series": name, "catalog_id": id, "error": safeError(error)]) }
            }
        }
        var results: [[String: Any]] = []
        await withTaskGroup(of: (Int, [String: Any]).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                let entry = work[index]
                group.addTask {
                    var result: [String: Any] = ["series": entry.0, "catalog_id": entry.1, "line": entry.2, "episode": entry.3.name, "episode_number": entry.3.number as Any]
                    do {
                        let info = try await HLSProbe().inspect(url: entry.3.url)
                        result["status"] = "valid_playlist"
                        result["duration_seconds"] = info.duration
                        result["segments"] = info.segmentCount
                        result["endlist"] = info.isComplete
                        result["encrypted"] = info.encrypted
                        result["declared_width"] = info.declaredWidth as Any
                        result["declared_height"] = info.declaredHeight as Any
                    } catch { result["status"] = "failed"; result["error"] = safeError(error) }
                    return (index, result)
                }
            }
            while next < min(3, work.count) { enqueue(next); next += 1 }
            var indexed: [(Int, [String: Any])] = []
            while let result = await group.next() {
                indexed.append(result)
                if indexed.count % 20 == 0 { print("Checked \(indexed.count)/\(work.count) playlists") }
                if next < work.count { enqueue(next); next += 1 }
            }
            results = indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        let valid = results.filter { ($0["status"] as? String) == "valid_playlist" }.count
        let report: [String: Any] = ["checked_at": ISO8601DateFormatter().string(from: Date()), "provider_id": provider.id, "endpoint": provider.endpoint.absoluteString,
            "validation": "Basic bounded master/media HLS requests only, no media segment download", "request_timeout_seconds": 12, "response_limit_bytes": 2097152, "maximum_parallel_requests": 3,
            "expected_episodes_from_prior_catalog": 164, "episodes_checked": results.count, "valid_playlists": valid, "failed_playlists": results.count - valid,
            "full_playback_verified": false, "decoded_dimensions_verified": false, "content_identity_verified": false,
            "limits": ["Manifest reachability is not proof of complete, distinct, correctly labelled episodes", "Resolution declarations can disagree with decoded pixels", "No segments or encryption keys requested; no player/seek/audio/continuous playback testing", "Availability can change; no content licensing conclusion"], "seasons": seasons, "episodes": results]
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: "docs/validation/source-report.json"), options: .atomic)
            print("Result: \(valid)/\(results.count) valid playlists; report saved")
        } catch { print("Report failed: \(error)"); exit(1) }
    }
    static func safeError(_ error: Error) -> String {
        if let source = error as? SourceError { return source.localizedDescription }
        if let url = error as? URLError { return "Network error \(url.code.rawValue)" }
        return "Source parse failure"
    }
}
