import Foundation

public enum EnhancementResolution: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic, source, hd720, fullHD, quadHD, ultraHD
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: return "自动（按修复模式）"
        case .source: return "跟随片源"
        case .hd720: return "720p"
        case .fullHD: return "1080p"
        case .quadHD: return "1440p"
        case .ultraHD: return "4K / 2160p"
        }
    }
    /// Explicit targets may downsample. The automatic case preserves historical mode behaviour.
    public func target(width: Int, height: Int, automatic4K: Bool) -> PixelSize {
        guard width > 0, height > 0 else { return PixelSize(width: 0, height: 0) }
        if self == .source { return PixelSize(width: width, height: height) }
        if self == .automatic {
            return automatic4K ? QualityPolicy.target4K(width: width, height: height) : PixelSize(width: width, height: height)
        }
        let long: Double
        switch self { case .hd720: long = 1280; case .fullHD: long = 1920; case .quadHD: long = 2560; default: long = 3840 }
        // The same pixel budget applies to portrait video, with swapped bounds.
        let bounds = width >= height ? (long, long * 9 / 16) : (long * 9 / 16, long)
        let scale = min(bounds.0 / Double(width), bounds.1 / Double(height))
        return PixelSize(width: max(2, Int((Double(width) * scale / 2).rounded()) * 2),
                         height: max(2, Int((Double(height) * scale / 2).rounded()) * 2))
    }
}

public enum EnhancementFrameRate: String, CaseIterable, Identifiable, Codable, Sendable {
    case source, fps60
    public var id: String { rawValue }
    public var title: String { self == .source ? "跟随片源" : "60 fps（运动插帧）" }
}

/// A short completed-compute test, never a promise of sustained on-screen playback rate.
public struct ProcessingTimingSummary: Equatable, Sendable {
    public let meanMS: Double
    public let p95MS: Double
    public let budgetMS: Double
    public let overBudgetRatio: Double
    public var headroomMS: Double { budgetMS - p95MS }
    public var hasHeadroom: Bool { p95MS <= budgetMS * 0.8 }
    public init?(samples: [Double], sourceFPS: Double) {
        guard !samples.isEmpty, samples.allSatisfy({ $0.isFinite && $0 >= 0 }), sourceFPS.isFinite, sourceFPS > 0 else { return nil }
        let ordered = samples.sorted()
        meanMS = samples.reduce(0, +) / Double(samples.count)
        p95MS = ordered[max(0, Int(ceil(Double(samples.count) * 0.95)) - 1)]
        let budget = 1000 / sourceFPS
        budgetMS = budget
        overBudgetRatio = Double(samples.filter { $0 > budget }.count) / Double(samples.count)
    }
}
