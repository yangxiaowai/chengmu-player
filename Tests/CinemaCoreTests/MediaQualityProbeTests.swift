import Foundation
import Testing
@testable import CinemaCore

struct MediaQualityProbeTests {
    @Test func exactDimensionsAndMetadataAreDisplayed() {
        let sample = MediaQualitySample(width: 640, height: 360, frameRate: 24,
                                        codec: "avc1", estimatedBitrate: 1_500_000)
        #expect(sample.dimensionsLabel == "640×360")
        #expect(sample.resolutionLabel == "360p · 640×360")
        #expect(sample.pixelCount == 230_400)
        #expect(sample.summary.contains("24 fps"))
        #expect(sample.summary.contains("avc1"))
        #expect(sample.summary.contains("1.5 Mbps"))
    }

    @Test func cinemaAndPortraitFramesDoNotClaimStandardProgressiveLabels() {
        #expect(MediaQualitySample(width: 3840, height: 1600).resolutionLabel == "3840×1600")
        #expect(MediaQualitySample(width: 1080, height: 1920).resolutionLabel == "1080×1920")
        #expect(MediaQualitySample(width: 3840, height: 2160).resolutionLabel == "2160p · 3840×2160")
        #expect(MediaQualitySample(width: 4096, height: 2160).resolutionLabel == "4096×2160")
    }

    @Test func invalidValuesCannotBecomeQualityClaims() throws {
        for dimensions in [(0, 1080), (-1, 1080), (16_385, 1080), (1920, Int.max)] {
            let value = MediaQualitySample(width: dimensions.0, height: dimensions.1,
                                           frameRate: .infinity, estimatedBitrate: -.infinity)
            #expect(value.pixelCount == 0)
            #expect(value.resolutionLabel == "尺寸未知")
            #expect(value.frameRate == nil)
            #expect(value.estimatedBitrate == nil)
        }
        #expect(MediaQualitySample(width: 1920, height: 1080, frameRate: 0).frameRate == nil)
        #expect(MediaQualitySample(width: 1920, height: 1080, frameRate: 0).summary.contains("帧率未读到"))
        #expect(MediaQualitySample(width: 1920, height: 1080, frameRate: .nan).frameRate == nil)
        #expect(MediaQualitySample(width: 1920, height: 1080, codec: "  ").codec == nil)
        let decoded = try JSONDecoder().decode(MediaQualitySample.self,
            from: Data(#"{"width":-1,"height":1080,"frameRate":0}"#.utf8))
        #expect(decoded.pixelCount == 0)
        #expect(decoded.frameRate == nil)
    }

    @Test func samplesRoundTripAndFractionalFrameRatesRemainVisible() throws {
        let value = MediaQualitySample(width: 1920, height: 1080, frameRate: 23.976,
                                       codec: "hvc1", estimatedBitrate: 8_000_000)
        #expect(value.summary.contains("23.976 fps"))
        #expect(try JSONDecoder().decode(MediaQualitySample.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func evidenceIsVisibleAndLegacySamplesDecodeAsTrackMetadata() throws {
        let legacy = try JSONDecoder().decode(MediaQualitySample.self,
            from: Data(#"{"width":640,"height":360,"frameRate":24}"#.utf8))
        #expect(legacy.evidence == .track)
        #expect(legacy.summary.contains("轨道读取"))
        let frame = MediaQualitySample(width: 640, height: 360, evidence: .firstFrame)
        #expect(frame.summary.contains("首帧读取"))
        #expect(try JSONDecoder().decode(MediaQualitySample.self, from: JSONEncoder().encode(frame)) == frame)
    }

    @Test func unsupportedAndMalformedURLsFail() async {
        for url in [URL(string: "ftp://example.com/video.mp4")!, URL(string: "https:/video.mp4")!,
                    URL(string: "https://user:secret@example.com/video.mp4")!] {
            do {
                _ = try await MediaQualityProbe().inspect(url: url)
                Issue.record("Invalid URL was accepted")
            } catch { }
        }
    }
}
