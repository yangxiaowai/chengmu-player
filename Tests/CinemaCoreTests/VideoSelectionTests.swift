import Foundation
import Testing
@testable import CinemaCore

struct VideoSelectionTests {
    @Test func letterboxBarsAreExcludedFromSelectionCoordinates() throws {
        let frame = VideoSelectionGeometry.fittedRect(video: CGSize(width: 1920, height: 1080), container: CGSize(width: 800, height: 600))
        #expect(frame == CGRect(x: 0, y: 75, width: 800, height: 450))
        #expect(VideoSelectionGeometry.selection(from: CGPoint(x: 200, y: 40), to: CGPoint(x: 400, y: 200), videoRect: frame) == nil)
        let region = try #require(VideoSelectionGeometry.selection(from: CGPoint(x: 200, y: 120), to: CGPoint(x: 400, y: 210), videoRect: frame))
        #expect(abs(region.x - 0.25) < 0.0001 && abs(region.y - 0.1) < 0.0001)
        #expect(abs(region.width - 0.25) < 0.0001 && abs(region.height - 0.2) < 0.0001)
    }
    @Test func reverseDragClampsToVideoEdges() throws {
        let rect = CGRect(x: 100, y: 0, width: 600, height: 600)
        let value = try #require(VideoSelectionGeometry.selection(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 40, y: -100), videoRect: rect))
        #expect(value.x == 0 && value.y == 0 && value.width == 0.5 && value.height == 0.5)
    }
    @Test func invalidGeometryAndAccidentalClicksDoNotCreateRegions() {
        #expect(VideoSelectionGeometry.fittedRect(video: .zero, container: CGSize(width: 800, height: 600)).isEmpty)
        #expect(VideoSelectionGeometry.fittedRect(video: CGSize(width: CGFloat.nan, height: 10), container: CGSize(width: 800, height: 600)).isEmpty)
        #expect(VideoSelectionGeometry.selection(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 52, y: 51), videoRect: CGRect(x: 0, y: 0, width: 800, height: 600)) == nil)
    }
    @Test func portraitFitAndRetinaPointsYieldTheSameNormalizedRegion() throws {
        let video = CGSize(width: 1080, height: 1920), container = CGSize(width: 800, height: 600)
        let frame = VideoSelectionGeometry.fittedRect(video: video, container: container)
        #expect(frame.width == 337.5 && frame.height == 600)
        let a = try #require(VideoSelectionGeometry.selection(from: CGPoint(x: frame.minX, y: 60), to: CGPoint(x: frame.midX, y: 120), videoRect: frame))
        let doubled = CGRect(x: frame.minX * 2, y: 0, width: frame.width * 2, height: frame.height * 2)
        let b = try #require(VideoSelectionGeometry.selection(from: CGPoint(x: doubled.minX, y: 120), to: CGPoint(x: doubled.midX, y: 240), videoRect: doubled))
        #expect(a == b)
    }
}
