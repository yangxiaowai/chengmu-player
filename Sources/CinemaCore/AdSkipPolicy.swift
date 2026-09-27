import Foundation

public struct AdRecognizedText: Sendable {
    public let text: String
    public let confidence: Double
    public let rect: NormalizedVideoRect
    public init(text: String, confidence: Double, rect: NormalizedVideoRect) {
        self.text = text; self.confidence = confidence; self.rect = rect
    }
}

public enum AdFrameClassification: String, Codable, Sendable {
    case advertisement, ordinary, unknown
}

public struct AdFrameObservation: Sendable {
    public let time: Double
    public let classification: AdFrameClassification
    public init(time: Double, classification: AdFrameClassification) {
        self.time = time; self.classification = classification
    }
}

public struct AdSkipSegment: Identifiable, Equatable, Sendable {
    public let start: Double
    public let end: Double
    public var id: String { "\(start):\(end)" }
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public enum AdTextClassifier {
    public static func classify(_ texts: [AdRecognizedText], protectedRegions: [NormalizedVideoRect] = [AdCleanupSettings.defaultProtection]) -> AdFrameClassification {
        // The built-in subtitle band cannot be disabled by an empty/custom protection list.
        let protection = [AdCleanupSettings.defaultProtection] + protectedRegions
        guard protection.allSatisfy(AdCleanupPolicy.isValid), texts.allSatisfy({
            AdCleanupPolicy.isValid($0.rect) && $0.confidence.isFinite && (0...1).contains($0.confidence)
        }) else { return .unknown }
        let usable = texts.filter { value in
            value.confidence >= 0.3 && !protection.contains { overlaps(value.rect, $0) }
        }
        for brand in usable where isBrand(normalize(brand.text)) && isMainTitle(brand.rect) {
            if usable.contains(where: { candidate in
                !overlaps(brand.rect, candidate.rect) && isPromotion(normalize(candidate.text))
            }) { return .advertisement }
        }
        return .ordinary
    }

    private static func isMainTitle(_ rect: NormalizedVideoRect) -> Bool {
        let centerX = rect.x + rect.width / 2, centerY = rect.y + rect.height / 2
        return rect.width >= 0.15 && rect.height >= 0.04 &&
            (0.15...0.85).contains(centerX) && (0.12...0.65).contains(centerY)
    }

    private static func isBrand(_ value: String) -> Bool {
        var name = value
        for prefix in ["欢迎光临", "欢迎来到"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }
        // Accept common title affixes, while rejecting dialogue containing the brand.
        for suffix in ["欢迎您", "欢迎光临", "娱乐城", "娱乐场"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name == "澳门新葡京" || name == "新葡京"
    }

    private static func isPromotion(_ value: String) -> Bool {
        ["注册送", "注册即送", "充值", "投注", "彩金", "首存", "真人视讯", "百家乐", "博彩", "开户送", "免费试玩"].contains { value.contains($0) }
    }

    private static let simplified: [Character: Character] = [
        "門": "门", "註": "注", "冊": "册", "視": "视", "訊": "讯", "娛": "娱", "樂": "乐",
        "歡": "欢", "臨": "临", "來": "来", "場": "场", "贈": "赠", "開": "开", "戶": "户",
        "費": "费", "試": "试", "體": "体", "驗": "验", "線": "线"
    ]
    private static func normalize(_ value: String) -> String {
        let canonical = value.precomposedStringWithCompatibilityMapping
        let stripped = canonical.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(stripped)).map { simplified[$0] ?? $0 }.reduce(into: "") { $0.append($1) }
    }

    private static func overlaps(_ a: NormalizedVideoRect, _ b: NormalizedVideoRect) -> Bool {
        // Treat touching protection edges conservatively, without cropping OCR boxes.
        a.x <= b.x + b.width && b.x <= a.x + a.width &&
            a.y <= b.y + b.height && b.y <= a.y + a.height
    }
}

public enum AdSegmentPolicy {
    public static func segments(from observations: [AdFrameObservation]) -> [AdSkipSegment] {
        // Sorting/deduplicating would manufacture continuity from stale or repeated decoder frames.
        var previous: Double?
        for observation in observations {
            guard observation.time.isFinite, observation.time >= 0,
                  previous.map({ observation.time > $0 }) ?? true else { return [] }
            previous = observation.time
        }
        var result: [AdSkipSegment] = []
        var first: Double?, last: Double?, count = 0
        previous = nil
        for observation in observations {
            if let previous, observation.time - previous > 2.5 {
                first = nil; last = nil; count = 0
            }
            switch observation.classification {
            case .advertisement:
                if first == nil { first = observation.time }
                last = observation.time
                count += 1
            case .ordinary:
                if let first, let last, count >= 3, (4...90).contains(last - first) {
                    result.append(AdSkipSegment(start: first, end: last))
                }
                first = nil; last = nil; count = 0
            case .unknown:
                first = nil; last = nil; count = 0
            }
            previous = observation.time
        }
        return result
    }

    public static func target(at position: Double, in segments: [AdSkipSegment], ignored: [AdSkipSegment] = [], isPlaying: Bool, isBusy: Bool) -> AdSkipSegment? {
        guard isPlaying, !isBusy, position.isFinite, position >= 0,
              ignored.allSatisfy(isValidInterval) else { return nil }
        return segments.first { segment in
            isValidInterval(segment) && segment.end - segment.start <= 90 &&
                position >= segment.start && position < segment.end && segment.end - position >= 1 &&
                !ignored.contains { $0.start < segment.end && segment.start < $0.end }
        }
    }

    private static func isValidInterval(_ segment: AdSkipSegment) -> Bool {
        segment.start.isFinite && segment.end.isFinite && segment.start >= 0 && segment.end > segment.start
    }
}
