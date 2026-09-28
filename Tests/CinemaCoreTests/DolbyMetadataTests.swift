import Foundation
import Testing
@testable import CinemaCore

/// `dec3` (EC3SpecificBox) fixtures. The `real*` payloads were extracted from real encoder-produced
/// E-AC-3 elementary streams. Every other payload was generated field by field from the same
/// documented arrangement, and each constant names the single field it changes relative to
/// `atmosJOCFiveOne`:
///
///     data_rate(13) num_ind_sub(3)
///     independent substream: fscod(2) bsid(5) reserved(4) bsmod(3) asvc(1) acmod(3) lfeon(1)
///                            reserved(3) num_dep_sub(4)
///     dependent substream:   reserved(3) bsid(5) bsmod(3) acmod(3) lfeon(1) reserved(2)
///                            num_dep_sub(4) chan_loc(encoder dependent)
///     AC-3 extension flag:   1 bit, closing each independent substream
///
/// Dependent substreams are documented for completeness but never accepted, because the width of
/// their channel map is not agreed across encoders.
struct DolbyMetadataTests {
    /// Real 5.1 E-AC-3 at 384 kb/s: data_rate 384, fscod 0, bsid 16, acmod 6, lfeon 1, flag 0.
    private let realFiveOne384 = "0c00200f0000"
    /// Real 5.1 E-AC-3 at 640 kb/s: same substream layout at a higher data rate.
    private let realFiveOne640 = "1400200f0000"
    /// Real stereo E-AC-3 at 192 kb/s: acmod 0, lfeon 0, flag 0.
    private let realStereo192 = "060020040000"

    /// 192 kb/s, one 5.1 substream, AC-3 extension flag set.
    private let atmosJOCFiveOne = "060020018020"
    /// 448 kb/s 5.1 with two dependent substreams and the JOC flag set. Deliberately refused.
    private let dependentSubstreamJOC = "0e00200180840600022203000028"
    /// 384 kb/s, two independent substreams (5.1 then quad); the second one carries the flag.
    private let twoSubstreamsJOC = "0c0120018004002004"
    /// 192 kb/s mono with the flag set: a JOC extension does not require 5.1.
    private let monoJOC = "060020008020"
    /// Identical to the JOC 5.1 payload with the extension flag cleared at bit 42.
    private let flagClearFiveOne = "060020018000"
    /// Identical to the two-substream payload with the second substream's flag cleared at bit 68.
    private let flagClearTwoSubstreams = "0c0120018004002000"
    /// fscod 3 is a reserved frame size code.
    private let fscodReserved = "0600e0018020"
    /// The four reserved bits after bsid are set.
    private let reservedOne = "060020218020"
    private let reservedFifteen = "060021e18020"
    /// E-AC-3 (bsid 16) is the only framing that carries a JOC extension.
    private let bsidZero = "060000018020"
    private let bsidEight = "060010018020"
    private let bsidTen = "060014018020"
    private let bsidFifteen = "06001e018020"
    private let bsidSeventeen = "060022018020"
    private let bsidThirtyOne = "06003e018020"
    /// Valid channel modes 0 (mono) and 7 alongside the 5.1 payload.
    private let acmodZero = "060020000020"
    private let acmodSeven = "06002001c020"
    /// A dependent substream whose bsid is not E-AC-3.
    private let dependentBsidTen = "0e002001804406000230"
    /// One 5.1 substream that claims eight independent substreams.
    private let declaredEight = "060720018020"

    private func payload(_ hex: String) -> Data { Data(hex: hex) }

    @Test func realNonJOCEAC3PayloadsAreNotAtmos() {
        for value in [realFiveOne384, realFiveOne640, realStereo192] {
            #expect(!DolbyMetadata.hasAtmosEC3Configuration(payload(value)))
        }
    }

    @Test func completeExtensionFlagIdentifiesAtmosMetadata() {
        #expect(DolbyMetadata.hasAtmosEC3Configuration(payload(atmosJOCFiveOne)))
        #expect(DolbyMetadata.hasAtmosEC3Configuration(payload(twoSubstreamsJOC)))
        #expect(DolbyMetadata.hasAtmosEC3Configuration(payload(monoJOC)))
    }

    @Test func theSamePayloadWithTheFlagClearedIsNotAtmos() {
        for value in [flagClearFiveOne, flagClearTwoSubstreams] {
            #expect(!DolbyMetadata.hasAtmosEC3Configuration(payload(value)))
        }
    }

    @Test func everyTruncatedPrefixIsRejected() {
        for value in [atmosJOCFiveOne, dependentSubstreamJOC, twoSubstreamsJOC] {
            let bytes = Array(payload(value))
            for length in 0..<bytes.count {
                #expect(!DolbyMetadata.hasAtmosEC3Configuration(Data(bytes.prefix(length))))
            }
        }
    }

    @Test func trailingBoxPaddingAndSlicedPayloadsDoNotChangeTheResult() {
        #expect(DolbyMetadata.hasAtmosEC3Configuration(payload(atmosJOCFiveOne) + Data([0xff, 0xff, 0x00])))
        #expect(DolbyMetadata.hasAtmosEC3Configuration((Data([0xff]) + payload(atmosJOCFiveOne)).dropFirst()))
        // A full box header would shift every field and must not be read as a payload.
        #expect(!DolbyMetadata.hasAtmosEC3Configuration(Data([0, 0, 0, 15, 0x64, 0x65, 0x63, 0x33]) + payload(atmosJOCFiveOne)))
    }

    @Test func dependentSubstreamChannelMapsAreNeverClaimed() {
        // A JOC flag behind an encoder-dependent channel map is not enough evidence on its own.
        #expect(!DolbyMetadata.hasAtmosEC3Configuration(payload(dependentSubstreamJOC)))
        #expect(!DolbyMetadata.hasAtmosEC3Configuration(payload(dependentBsidTen)))
    }

    @Test func theDeclaredSubstreamCountIsAnUpperBound() {
        // `num_ind_sub` only bounds how many substreams the reader may inspect. A payload that
        // declares eight but closes with a complete JOC-flagged 5.1 substream is still E-AC-3
        // with a JOC extension, so it qualifies; the unreadable tail is never used.
        #expect(DolbyMetadata.hasAtmosEC3Configuration(payload(declaredEight)))
        // One substream that declares two is rejected: the second one cannot be parsed at all.
        #expect(!DolbyMetadata.hasAtmosEC3Configuration(Data(payload(twoSubstreamsJOC).prefix(6))))
    }

    @Test func unsupportedFramingBitstreamIdentifiersAndReservedBitsDoNotQualify() {
        for value in [fscodReserved, reservedOne, reservedFifteen,
                      bsidZero, bsidEight, bsidTen, bsidFifteen, bsidSeventeen, bsidThirtyOne] {
            #expect(!DolbyMetadata.hasAtmosEC3Configuration(payload(value)))
        }
        for value in [acmodZero, acmodSeven] {
            #expect(DolbyMetadata.hasAtmosEC3Configuration(payload(value)))
        }
    }

    @Test func invalidDolbyVisionConfigurationBoxesAreRejected() {
        let profile5 = Data([0x01, 0x00, 0x0a, 0x0c])
        #expect(DolbyMetadata.dolbyVisionProfile(profile5)?.profile == 5)
        #expect(DolbyMetadata.dolbyVisionProfile(profile5)?.isSingleLayerCompatible == true)
        #expect(DolbyMetadata.dolbyVisionProfile(Data([0x01, 0x00, 0x10, 0x1c]))?.profile == 8)
        for value in [Data(), Data([0x01]), Data([0x01, 0x00, 0x0a]), Data([0x02, 0x00, 0x0a, 0x0c]),
                      Data([0x01, 0x00, 0x00, 0x0c]), Data([0x01, 0x00, 0x14, 0x0c]), Data([0x01, 0x00, 0x0a, 0x70])] {
            #expect(!DolbyMetadata.hasDolbyVisionConfiguration(value))
        }
    }
}

private extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0); index = next
        }
        self.init(bytes)
    }
}
