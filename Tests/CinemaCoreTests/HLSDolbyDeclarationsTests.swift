import Foundation
import Testing
@testable import CinemaCore

struct HLSDolbyDeclarationsTests {
    private let base = URL(string: "https://dolby-fixture.test/master/index.m3u8")!
    private func manifest(_ attributes: String, media: String = "") -> String {
        "#EXTM3U\n" + media + "#EXT-X-STREAM-INF:BANDWIDTH=1000000,\(attributes)\nvideo/index.m3u8\n"
    }
    private func declarations(_ attributes: String, media: String = "") throws -> HLSMediaDeclarations {
        try HLSProbe.declarations(text: manifest(attributes, media: media), url: base)
    }

    @Test func directDolbyVisionCodecAndExplicitHDRRangesAreDeclarations() throws {
        for codec in ["dvh1.05.06", "dvhe.05.06"] {
            let value = try declarations("CODECS=\"\(codec),ec-3\",VIDEO-RANGE=PQ")
            #expect(value.hasDolbyVision && value.hasHDRVideo)
            #expect(value.variants.first?.videoRange == "PQ")
            #expect(!value.hasAtmosDeclaration)
        }
        for range in ["PQ", "HLG"] {
            let value = try declarations("CODECS=\"hvc1.2.4.L153.b0\",VIDEO-RANGE=\(range)")
            #expect(value.hasHDRVideo && !value.hasDolbyVision)
        }
    }

    @Test func hevc4KUnknownRangeAndCodecLookalikesDoNotInventDolby() throws {
        for attributes in [
            "CODECS=\"hvc1.2.4.L153.b0\",RESOLUTION=3840x2160",
            "CODECS=\"hev1.2.4.L153.b0\",VIDEO-RANGE=SDR",
            "CODECS=\"avc1.640028\",VIDEO-RANGE=FUTURE",
            "CODECS=\"notdvh1.05.06\"",
            "CODECS=\"dvh1-invalid\""
        ] {
            let value = try declarations(attributes)
            #expect(!value.hasHDRVideo && !value.hasDolbyVision && !value.hasAtmosDeclaration)
        }
        #expect(try declarations("RESOLUTION=3840x2160").variants.first?.videoRange == nil)
    }

    @Test func supplementalDolbyVisionRequiresMatchingBaseRangeAndCompatibilityBrand() throws {
        for (suffix, range) in [("db1p", "PQ"), ("db4h", "HLG")] {
            let value = try declarations("CODECS=\"hvc1.2.4.L153.b0\",SUPPLEMENTAL-CODECS=\"dvh1.08.07/\(suffix)\",VIDEO-RANGE=\(range)")
            #expect(value.hasDolbyVision && value.hasHDRVideo)
            #expect(value.variants.first?.supplementalCodecs == "dvh1.08.07/\(suffix)")
        }
        for attributes in [
            "CODECS=\"hvc1.2.4.L153.b0\",SUPPLEMENTAL-CODECS=\"dvh1.08.07/db4h\",VIDEO-RANGE=PQ",
            "CODECS=\"hvc1.2.4.L153.b0\",SUPPLEMENTAL-CODECS=\"dvh1.08.07/db1p\",VIDEO-RANGE=HLG",
            "CODECS=\"hvc1.2.4.L153.b0\",SUPPLEMENTAL-CODECS=\"dvh1.08.07\",VIDEO-RANGE=PQ",
            "CODECS=\"hvc1.2.4.L153.b0\",SUPPLEMENTAL-CODECS=\"dvh1.08.07/db1p\"",
            "CODECS=\"avc1.640028\",SUPPLEMENTAL-CODECS=\"dvh1.08.07/db1p\",VIDEO-RANGE=PQ",
            "CODECS=\"hvc1.2.4.L153.b0\",SUPPLEMENTAL-CODECS=\"hvc1.2.4.L153.b0/cdm4\",VIDEO-RANGE=PQ"
        ] { #expect(try !declarations(attributes).hasDolbyVision) }
    }

    @Test func linkedEAC3RenditionWithJOCIsAnAtmosDeclaration() throws {
        let audio = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"spatial\",NAME=\"English, Original\",LANGUAGE=\"en\",URI=\"../audio/en.m3u8?x=a,b\",CHANNELS=\"16/JOC\",DEFAULT=YES\n"
        let value = try declarations("CODECS=\"avc1.640028,ec-3\",AUDIO=\"spatial\"", media: audio)
        #expect(value.hasAtmosDeclaration)
        let rendition = try #require(value.audioRenditions.first)
        #expect(rendition.name == "English, Original" && rendition.language == "en" && rendition.isDefault)
        #expect(rendition.url?.absoluteString == "https://dolby-fixture.test/audio/en.m3u8?x=a,b")
        #expect(rendition.channels == "16/JOC")
        #expect(value.variants.first?.audioGroupID == "spatial")
    }

    @Test func multichannelEAC3NamesAndMalformedJOCNeverInventAtmos() throws {
        for channels in ["6", "8", "16/joc", "16/NOTJOC", "16/JOC-extra", "0/JOC", "-1/JOC", "NaN/JOC", "16.0/JOC", "JOC", "/JOC", "256/JOC"] {
            let audio = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"Dolby Atmos\",CHANNELS=\"\(channels)\"\n"
            #expect(try !declarations("CODECS=\"ec-3\",AUDIO=\"a\"", media: audio).hasAtmosDeclaration)
        }
        for codecs in ["mp4a.40.2", "ac-3", "ec+3", "notec-3", ""] {
            let audio = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"English\",CHANNELS=\"16/JOC\"\n"
            #expect(try !declarations("CODECS=\"\(codecs)\",AUDIO=\"a\"", media: audio).hasAtmosDeclaration)
        }
    }

    @Test func unrelatedAudioGroupsAndSubtitleRenditionsDoNotLeakAtmos() throws {
        let audio = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"unused\",NAME=\"English\",CHANNELS=\"16/JOC\"\n"
        #expect(try !declarations("CODECS=\"ec-3\",AUDIO=\"other\"", media: audio).hasAtmosDeclaration)
        #expect(try !declarations("CODECS=\"ec-3\"", media: audio).hasAtmosDeclaration)
        let subtitle = "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"a\",NAME=\"Text\",CHANNELS=\"16/JOC\"\n"
        let value = try declarations("CODECS=\"ec-3\",AUDIO=\"a\"", media: subtitle)
        #expect(value.audioRenditions.isEmpty && !value.hasAtmosDeclaration)
    }

    @Test func missingAudioURIAndDefaultArePreservedWithoutInventedDefaults() throws {
        let audio = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"In-band\",CHANNELS=\"2\"\n"
        let rendition = try #require(declarations("CODECS=\"mp4a.40.2\",AUDIO=\"a\"", media: audio).audioRenditions.first)
        #expect(rendition.url == nil && rendition.language == nil && !rendition.isDefault)
    }

    @Test func malformedOrDuplicatedAttributesCannotTurnIntoTrustedDeclarations() {
        for attributes in [
            "CODECS=\"hvc1.2.4.L153.b0\",CODECS=\"dvh1.05.06\"",
            "CODECS=\"dvh1.05.06,VIDEO-RANGE=PQ",
            "VIDEO-RANGE=SDR,VIDEO-RANGE=PQ"
        ] { #expect(throws: (any Error).self) { try declarations(attributes) } }
        for media in [
            "#EXT-X-MEDIA:TYPE=AUDIO,NAME=\"English\",CHANNELS=\"16/JOC\"\n",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"English\",URI=\"file:///etc/passwd\"\n",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"English\",CHANNELS=\"2\",CHANNELS=\"16/JOC\"\n"
        ] { #expect(throws: (any Error).self) { try declarations("CODECS=\"ec-3\",AUDIO=\"a\"", media: media) } }
    }

    @Test func leafPlaylistContainsNoAssumedVideoOrAudioDeclarations() throws {
        let text = "#EXTM3U\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST\n"
        let declarations = try HLSProbe.declarations(text: text, url: base)
        #expect(declarations.variants.isEmpty && declarations.audioRenditions.isEmpty)
        #expect(!declarations.hasHDRVideo && !declarations.hasDolbyVision && !declarations.hasAtmosDeclaration)
        #expect(try HLSProbe.parse(text: text, url: base).declarations == nil)
    }

    @Test func oldHLSInfoJSONDecodesWithoutDeclarationsAndNewValuesRoundTrip() throws {
        let old = Data(#"{"url":"https://example.test/index.m3u8","duration":6,"segmentCount":1,"isComplete":true,"encrypted":false,"firstSegmentURL":"https://example.test/segment.ts"}"#.utf8)
        var info = try JSONDecoder().decode(HLSInfo.self, from: old)
        #expect(info.declarations == nil && info.declaredWidth == nil && info.codecs == nil)
        info.declarations = try declarations("CODECS=\"dvh1.05.06\",VIDEO-RANGE=PQ")
        #expect(try JSONDecoder().decode(HLSInfo.self, from: JSONEncoder().encode(info)) == info)
    }

    @Test func inspectorKeepsOuterMixedMasterDeclarationsWhileFollowingSDRProbeBranch() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DolbyManifestFixture.self]
        let probe = HLSProbe(client: BoundedHTTPClient(timeout: 2, configuration: config))
        let result = try await probe.inspect(url: URL(string: "https://dolby-manifest.test/master.m3u8")!)
        #expect(result.url.path == "/leaf.m3u8" && result.codecs == "avc1.640028")
        let outer = try #require(result.declarations)
        #expect(outer.variants.count == 2 && outer.hasHDRVideo && outer.hasDolbyVision && outer.hasAtmosDeclaration)
        #expect(outer.variants.first?.videoRange == "SDR")
        #expect(outer.audioRenditions.first?.groupID == "atmos")
    }
}

private final class DolbyManifestFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "dolby-manifest.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let text: String
        switch url.path {
        case "/master.m3u8":
            text = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"atmos\",NAME=\"English\",CHANNELS=\"16/JOC\"\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=3840x2160,CODECS=\"hvc1.2.4.L153.b0\",VIDEO-RANGE=SDR\nnested.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1920x1080,CODECS=\"dvh1.05.06,ec-3\",VIDEO-RANGE=PQ,AUDIO=\"atmos\"\nunvisited-dolby.m3u8\n"
        case "/nested.m3u8":
            text = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"atmos\",NAME=\"Stereo\",CHANNELS=\"2\"\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1920x1080,CODECS=\"avc1.640028\",VIDEO-RANGE=SDR\nleaf.m3u8\n"
        case "/leaf.m3u8": text = "#EXTM3U\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST\n"
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/vnd.apple.mpegurl"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
