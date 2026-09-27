import Foundation
import CoreGraphics

/// Coordinates of the displayed video, independent of letterboxing, with the origin at its top left.
public struct NormalizedVideoRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct AdCleanupSettings: Equatable, Sendable {
    public static let defaultProtection = NormalizedVideoRect(x: 0, y: 0.72, width: 1, height: 0.28)
    public var enabled: Bool
    public var regions: [NormalizedVideoRect]
    public var protectedRegions: [NormalizedVideoRect]
    public init(enabled: Bool = false, regions: [NormalizedVideoRect] = [], protectedRegions: [NormalizedVideoRect] = [Self.defaultProtection]) {
        self.enabled = enabled; self.regions = regions; self.protectedRegions = protectedRegions
    }
    public var isActive: Bool { enabled && !regions.isEmpty }
}

public struct AdCleanupDecision {
    public let acceptedRects: [CGRect]
    public let rejectedCount: Int
    public let reasons: [String]
}

public enum AdCleanupPolicy {
    public static let maxAdRegions = 6
    /// One default subtitle band and up to six additional protection rectangles.
    public static let maxProtectedRegions = 7
    public static func isValid(_ region: NormalizedVideoRect) -> Bool {
        [region.x, region.y, region.width, region.height].allSatisfy { $0.isFinite } &&
        region.x >= 0 && region.y >= 0 && region.width > 0 && region.height > 0 &&
        region.x + region.width <= 1 && region.y + region.height <= 1
    }
    /// Snap inward to complete pixels so no pixel outside the selected rectangle is changed.
    public static func pixelRect(_ region: NormalizedVideoRect, width: Int, height: Int) -> CGRect? {
        guard isValid(region), width > 0, height > 0 else { return nil }
        func precise(_ value: Double) -> Double {
            let nearest = value.rounded()
            return abs(value - nearest) <= value.ulp * 8 ? nearest : value
        }
        let x = ceil(precise(region.x * Double(width))), right = floor(precise((region.x + region.width) * Double(width)))
        let bottom = ceil(precise((1 - region.y - region.height) * Double(height)))
        let top = floor(precise((1 - region.y) * Double(height)))
        guard right > x, top > bottom else { return nil }
        return CGRect(x: x, y: bottom, width: right - x, height: top - bottom)
    }
    public static func rejectionReason(for region: NormalizedVideoRect, protectedRegions: [NormalizedVideoRect], width: Int, height: Int) -> String? {
        guard isValid(region) else { return "广告框越界或坐标无效" }
        guard width > 0, height > 0 else { return "等待有效画面尺寸" }
        guard protectedRegions.count <= maxProtectedRegions else { return "字幕保护框数量超过上限" }
        guard protectedRegions.allSatisfy(isValid) else { return "字幕保护框无效，柔化已停用" }
        guard pixelRect(region, width: width, height: height) != nil else { return "广告框小于一个有效像素" }
        let target = CGRect(x: region.x * Double(width), y: (1 - region.y - region.height) * Double(height), width: region.width * Double(width), height: region.height * Double(height))
        for protection in protectedRegions {
            // Expand the actual normalized protection area before checking the integer target.
            let protected = CGRect(x: protection.x * Double(width), y: (1 - protection.y - protection.height) * Double(height), width: protection.width * Double(width), height: protection.height * Double(height)).insetBy(dx: -4, dy: -4)
            if target.intersects(protected) { return "与字幕保护区重叠，整框不应用" }
        }
        return nil
    }
    /// The overlay and GPU must describe the same visible frame before a cleanup mask is applied.
    public static func geometryRejectionReason(bufferWidth: Int, bufferHeight: Int, displayBounds: CGRect, presentationSize: CGSize, cleanAperture: CGRect, pixelAspectRatio: Double) -> String? {
        guard bufferWidth > 0, bufferHeight > 0, presentationSize.width.isFinite, presentationSize.height.isFinite,
              presentationSize.width > 0, presentationSize.height > 0,
              displayBounds.width.isFinite, displayBounds.height.isFinite, displayBounds.width > 0, displayBounds.height > 0 else { return "等待有效显示几何，柔化暂未应用" }
        guard pixelAspectRatio.isFinite, abs(pixelAspectRatio - 1) < 0.00001 else { return "特殊像素比例暂不支持，局部柔化停用" }
        let full = CGRect(x: 0, y: 0, width: bufferWidth, height: bufferHeight)
        guard [cleanAperture.minX, cleanAperture.minY, cleanAperture.width, cleanAperture.height].allSatisfy({ $0.isFinite }),
              abs(cleanAperture.minX - full.minX) < 0.01, abs(cleanAperture.minY - full.minY) < 0.01,
              abs(cleanAperture.width - full.width) < 0.01, abs(cleanAperture.height - full.height) < 0.01 else { return "特殊画面裁切暂不支持，局部柔化停用" }
        let outputAspect = displayBounds.width / displayBounds.height
        let shownAspect = presentationSize.width / presentationSize.height
        guard abs(outputAspect / shownAspect - 1) <= 0.001 else { return "显示比例与处理画面不一致，局部柔化停用" }
        return nil
    }
    public static func evaluate(_ settings: AdCleanupSettings, width: Int, height: Int) -> AdCleanupDecision {
        guard settings.isActive else { return AdCleanupDecision(acceptedRects: [], rejectedCount: 0, reasons: []) }
        guard settings.regions.count <= maxAdRegions else { return AdCleanupDecision(acceptedRects: [], rejectedCount: settings.regions.count, reasons: ["广告框数量超过六个，柔化已停用"]) }
        var accepted: [CGRect] = [], reasons: [String] = []
        for region in settings.regions {
            if let reason = rejectionReason(for: region, protectedRegions: settings.protectedRegions, width: width, height: height) { reasons.append(reason) }
            else if let rectangle = pixelRect(region, width: width, height: height) { accepted.append(rectangle) }
        }
        return AdCleanupDecision(acceptedRects: accepted, rejectedCount: reasons.count, reasons: Array(Set(reasons)).sorted())
    }
}
