import Foundation
import CoreGraphics
import Testing
@testable import CinemaCore

struct AdCleanupTests {
    @Test func nonSquarePixelsCropAndUnknownDisplayGeometryCannotReceiveMask() {
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let presentation = CGSize(width: 1920, height: 1080)
        #expect(AdCleanupPolicy.geometryRejectionReason(bufferWidth: 1920, bufferHeight: 1080, displayBounds: full, presentationSize: presentation, cleanAperture: full, pixelAspectRatio: 1) == nil)
        #expect(AdCleanupPolicy.geometryRejectionReason(bufferWidth: 1920, bufferHeight: 1080, displayBounds: full, presentationSize: presentation, cleanAperture: full, pixelAspectRatio: 1.2) != nil)
        #expect(AdCleanupPolicy.geometryRejectionReason(bufferWidth: 1920, bufferHeight: 1080, displayBounds: full, presentationSize: presentation, cleanAperture: CGRect(x: 2, y: 0, width: 1916, height: 1080), pixelAspectRatio: 1) != nil)
        #expect(AdCleanupPolicy.geometryRejectionReason(bufferWidth: 1920, bufferHeight: 1080, displayBounds: full, presentationSize: .zero, cleanAperture: full, pixelAspectRatio: 1) != nil)
        let rotated = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        #expect(AdCleanupPolicy.geometryRejectionReason(bufferWidth: 1920, bufferHeight: 1080, displayBounds: rotated, presentationSize: CGSize(width: 1080, height: 1920), cleanAperture: full, pixelAspectRatio: 1) == nil)
        #expect(AdCleanupPolicy.geometryRejectionReason(bufferWidth: 1920, bufferHeight: 1080, displayBounds: rotated, presentationSize: presentation, cleanAperture: full, pixelAspectRatio: 1) != nil)
    }

    @Test func boundsAndNonFiniteValuesAreRejected() {
        #expect(AdCleanupPolicy.isValid(NormalizedVideoRect(x: 0, y: 0, width: 1, height: 1)))
        for region in [NormalizedVideoRect(x: -.infinity, y: 0, width: 0.1, height: 0.1), NormalizedVideoRect(x: 0, y: .nan, width: 0.1, height: 0.1), NormalizedVideoRect(x: -0.1, y: 0, width: 0.1, height: 0.1), NormalizedVideoRect(x: 0.9, y: 0, width: 0.2, height: 0.1), NormalizedVideoRect(x: 0, y: 0, width: 0, height: 1)] {
            #expect(!AdCleanupPolicy.isValid(region))
        }
    }
    @Test func topLeftDisplayCoordinatesConvertToBottomLeftPixels() throws {
        let region = NormalizedVideoRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2)
        let pixel = try #require(AdCleanupPolicy.pixelRect(region, width: 1000, height: 500))
        #expect(pixel == CGRect(x: 100, y: 300, width: 300, height: 100))
    }
    @Test func subtitleProtectionRejectsWholeRegionIncludingFourPixelMargin() {
        let protection = [NormalizedVideoRect(x: 0, y: 0.72, width: 1, height: 0.28)]
        let touching = NormalizedVideoRect(x: 0.1, y: 0.5, width: 0.2, height: 0.215)
        #expect(AdCleanupPolicy.rejectionReason(for: touching, protectedRegions: protection, width: 1000, height: 500) != nil)
        let safe = NormalizedVideoRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        #expect(AdCleanupPolicy.rejectionReason(for: safe, protectedRegions: protection, width: 1000, height: 500) == nil)
    }
    @Test func invalidProtectionFailsClosedAndLimitsAreEnforced() {
        let region = NormalizedVideoRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        #expect(AdCleanupPolicy.rejectionReason(for: region, protectedRegions: [NormalizedVideoRect(x: 0, y: .nan, width: 1, height: 0.2)], width: 1000, height: 500) != nil)
        let excess = AdCleanupSettings(enabled: true, regions: Array(repeating: region, count: 7))
        #expect(AdCleanupPolicy.evaluate(excess, width: 1000, height: 500).acceptedRects.isEmpty)
        let invalidSize = AdCleanupSettings(enabled: true, regions: [region])
        #expect(AdCleanupPolicy.evaluate(invalidSize, width: 0, height: 500).acceptedRects.isEmpty)
    }
    @Test func disabledSettingsHaveNoActiveRegionAndOverlappingProtectionRejectsRatherThanCrops() {
        let region = NormalizedVideoRect(x: 0.1, y: 0.65, width: 0.3, height: 0.2)
        #expect(!AdCleanupSettings(regions: [region]).isActive)
        let result = AdCleanupPolicy.evaluate(AdCleanupSettings(enabled: true, regions: [region]), width: 1000, height: 500)
        #expect(result.acceptedRects.isEmpty)
        #expect(result.rejectedCount == 1)
    }
}
