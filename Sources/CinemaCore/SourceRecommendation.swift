import Foundation

/// Evidence belongs to the resolved episode URL, not necessarily every episode in a title.
/// A missing sample means unknown, not zero quality or zero latency.
public struct SourceRecommendationCandidate: Equatable {
    public let title: MediaTitle
    public let mediaURL: URL?
    public let quality: MediaQualitySample?
    public let response: MediaResponseSample?

    public init(title: MediaTitle, mediaURL: URL?, quality: MediaQualitySample?, response: MediaResponseSample?) {
        self.title = title
        self.mediaURL = mediaURL
        self.quality = quality
        self.response = response
    }
}

public struct SourceRecommendationPage {
    public let candidates: [SourceRecommendationCandidate]
    public let remainingCount: Int
}

/// Orders only the candidates and fresh measurements supplied by the caller. This does not
/// measure startup speed, guarantee playable media, or establish a global optimum.
public enum SourceRecommendationPolicy {
    private struct Identity: Hashable { let provider: String; let title: String }

    public static func rank(_ input: [SourceRecommendationCandidate], limit: Int = 5) -> SourceRecommendationPage {
        let ordered = input.enumerated().sorted { a, b in
            let aPixels = a.element.quality?.pixelCount ?? 0
            let bPixels = b.element.quality?.pixelCount ?? 0
            let aLatency = a.element.response?.milliseconds
            let bLatency = b.element.response?.milliseconds
            // Complete evidence sorts first; an unknown field must not be mistaken for a good value.
            let aCoverage = (aPixels > 0 ? 2 : 0) + (aLatency == nil ? 0 : 1)
            let bCoverage = (bPixels > 0 ? 2 : 0) + (bLatency == nil ? 0 : 1)
            if aCoverage != bCoverage { return aCoverage > bCoverage }
            if aPixels != bPixels { return aPixels > bPixels }
            if aLatency != bLatency { return (aLatency ?? Int.max) < (bLatency ?? Int.max) }
            return a.offset < b.offset
        }
        var identities = Set<Identity>()
        let unique = ordered.compactMap { entry -> SourceRecommendationCandidate? in
            let candidate = entry.element
            let identity = Identity(provider: candidate.title.providerID, title: candidate.title.id)
            guard !identities.contains(identity) else { return nil }
            identities.insert(identity)
            return candidate
        }
        let count = min(unique.count, max(0, limit))
        return SourceRecommendationPage(candidates: Array(unique.prefix(count)), remainingCount: unique.count - count)
    }
}
