import Foundation

/// Internet Archive's open-movie metadata is supplied by uploaders; it is not a rights certification.
enum ArchiveCatalog {
    static let identifier = "archive-org"
    static let endpoint = URL(string: "https://archive.org")!
    static let pageSize = 30
    static let notice = "影片许可由上传者标注，版权及所在地区可用性请自行核实。"

    static func recognizes(_ provider: SourceProvider) -> Bool {
        provider.id == identifier && provider.endpoint == endpoint
    }

    static func searchURL(query: String, page: Int) throws -> URL {
        guard (1...10_000).contains(page) else { throw SourceError.invalidPage }
        let input = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var search = "mediatype:movies AND collection:opensource_movies AND licenseurl:*creativecommons.org*"
        if !input.isEmpty { search += " AND title:\"\(input)\"" }
        var components = URLComponents(string: "https://archive.org/advancedsearch.php")!
        components.queryItems = [URLQueryItem(name: "q", value: search),
                                 URLQueryItem(name: "fl[]", value: "identifier"),
                                 URLQueryItem(name: "fl[]", value: "title"),
                                 URLQueryItem(name: "fl[]", value: "year"),
                                 URLQueryItem(name: "rows", value: String(pageSize)),
                                 URLQueryItem(name: "page", value: String(page)),
                                 URLQueryItem(name: "output", value: "json")]
        guard let url = components.url else { throw SourceError.invalidURL }
        return url
    }

    static func metadataURL(id: String) throws -> URL {
        guard safeIdentifier(id) else { throw SourceError.invalidURL }
        return URL(string: "https://archive.org/metadata/\(id)")!
    }

    static func parsePage(_ data: Data, provider: SourceProvider, page: Int) throws -> CatalogPage {
        guard page >= 1, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let total = response["numFound"] as? Int, total >= 0,
              let docs = response["docs"] as? [[String: Any]], docs.count <= pageSize else { throw SourceError.invalidResponse }
        var seen = Set<String>()
        let titles: [MediaTitle] = docs.compactMap { doc in
            guard let id = doc["identifier"] as? String, safeIdentifier(id), seen.insert(id).inserted,
                  let title = doc["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let year = (doc["year"] as? NSNumber)?.stringValue ?? (doc["year"] as? String ?? "")
            let poster = URL(string: "https://archive.org/services/img/\(id)")
            return MediaTitle(id: id, title: title, year: year, posterURL: poster, summary: notice,
                              providerID: provider.id, providerName: provider.name, category: "开放影片")
        }
        return CatalogPage(providerID: provider.id, titles: titles, categories: [], page: page,
                           pageCount: max(1, total / pageSize + (total % pageSize == 0 ? 0 : 1)), total: total)
    }

    static func parseDetail(_ data: Data, title: MediaTitle) throws -> MediaDetail {
        guard safeIdentifier(title.id), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metadata = root["metadata"] as? [String: Any], metadata["identifier"] as? String == title.id,
              metadata["mediatype"] as? String == "movies", !restricted(root), !restricted(metadata),
              collectionIncludesOpenMovies(metadata["collection"]), validLicense(metadata["licenseurl"]),
              let files = root["files"] as? [[String: Any]] else { throw SourceError.emptyDetail }
        var names = Set<String>()
        let lines: [PlaybackLine] = files.prefix(500).compactMap { file in
            guard !restricted(file), let name = file["name"] as? String, safeFilename(name),
                  ["mp4", "m4v", "mov"].contains((name as NSString).pathExtension.lowercased()),
                  names.insert(name).inserted,
                  let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))),
                  let url = URL(string: "https://archive.org/download/\(title.id)/\(encoded)") else { return nil }
            let id = "\(identifier):\(title.id):\(encoded)"
            return PlaybackLine(id: id, name: name, episodes: [Episode(id: id, name: "正片", url: url, number: nil)])
        }
        guard !lines.isEmpty else { throw SourceError.emptyDetail }
        var actual = title
        if let name = metadata["title"] as? String, !name.isEmpty { actual.title = name }
        actual.summary = notice
        return MediaDetail(title: actual, lines: lines)
    }

    private static func safeIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 100 && id != "." && id != ".." &&
        id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
    }
    private static func safeFilename(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 240 && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private static func collectionIncludesOpenMovies(_ value: Any?) -> Bool {
        (value as? String) == "opensource_movies" || (value as? [String])?.contains("opensource_movies") == true
    }
    private static func validLicense(_ value: Any?) -> Bool {
        guard let text = value as? String, let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              ["creativecommons.org", "www.creativecommons.org"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return false }
        return url.path.hasPrefix("/licenses/") || url.path.hasPrefix("/publicdomain/")
    }
    private static func restricted(_ fields: [String: Any]) -> Bool {
        for key in ["private", "access-restricted-item", "access_restricted_item"] {
            guard let value = fields[key], !(value is NSNull) else { continue }
            if let value = value as? Bool { if value { return true }; continue }
            if let value = value as? NSNumber { if value.intValue != 0 { return true }; continue }
            if let value = value as? String, !["", "0", "false", "no"].contains(value.lowercased()) { return true }
        }
        return false
    }
}
