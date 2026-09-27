import Foundation

public struct PixelSize: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public enum QualityPolicy {
    /// Preserve the source aspect ratio. Never enlarge a frame already filling or exceeding the 4K bounds.
    public static func target4K(width: Int, height: Int) -> PixelSize {
        guard width > 0, height > 0 else { return PixelSize(width: 0, height: 0) }
        let factor = min(3840.0 / Double(width), 2160.0 / Double(height))
        guard factor > 1 else { return PixelSize(width: width, height: height) }
        return PixelSize(width: Int((Double(width) * factor).rounded()), height: Int((Double(height) * factor).rounded()))
    }
}

public struct FrameBudget: Sendable {
    public private(set) var shouldFallback = false
    public private(set) var consecutiveOverruns = 0
    public init() {}
    @discardableResult public mutating func record(milliseconds: Double, framesPerSecond: Double) -> Bool {
        let allowance = 1000 / max(1, framesPerSecond)
        if !milliseconds.isFinite || milliseconds > allowance { consecutiveOverruns += 1 }
        else { consecutiveOverruns = max(0, consecutiveOverruns - 1) }
        if consecutiveOverruns >= 10 { shouldFallback = true }
        return shouldFallback
    }
    public mutating func reset() { self = FrameBudget() }
}
