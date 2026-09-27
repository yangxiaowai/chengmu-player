import Foundation
import Testing
@testable import CinemaCore

struct AdSkipPolicyTests {
    private let brandRect = NormalizedVideoRect(x: 0.25, y: 0.2, width: 0.5, height: 0.12)
    private let promotionRect = NormalizedVideoRect(x: 0.3, y: 0.43, width: 0.4, height: 0.08)

    private func text(_ value: String, confidence: Double = 0.5, rect: NormalizedVideoRect? = nil) -> AdRecognizedText {
        AdRecognizedText(text: value, confidence: confidence, rect: rect ?? brandRect)
    }
    private func promotion(_ value: String = "注册送彩金", rect: NormalizedVideoRect? = nil) -> AdRecognizedText {
        text(value, rect: rect ?? promotionRect)
    }
    private func frame(_ time: Double, _ classification: AdFrameClassification = .advertisement) -> AdFrameObservation {
        AdFrameObservation(time: time, classification: classification)
    }

    @Test func mainBrandWithIndependentPromotionIsAnAdvertisement() {
        #expect(AdTextClassifier.classify([text("澳门新葡京"), promotion()]) == .advertisement)
        #expect(AdTextClassifier.classify([text("新葡京", confidence: 0.3), promotion("真人视讯")]) == .advertisement)
    }

    @Test func registrationOfferRecognizedByActualOCRIsSupported() {
        #expect(AdTextClassifier.classify([text("澳门新葡京"), promotion("线上娱乐 注册即送")]) == .advertisement)
    }

    @Test func traditionalCharactersWhitespaceAndPunctuationNormalize() {
        #expect(AdTextClassifier.classify([text(" 澳 門・新 葡 京！ "), promotion("註冊送彩金")]) == .advertisement)
        #expect(AdTextClassifier.classify([text("澳門新葡京"), promotion("真 人 視 訊")]) == .advertisement)
    }

    @Test func limitedWelcomeAffixesDoNotTurnDialogueIntoBrandEvidence() {
        for value in ["澳门新葡京欢迎您", "欢迎光临澳门新葡京", "澳門新葡京娛樂城"] {
            #expect(AdTextClassifier.classify([text(value), promotion()]) == .advertisement)
        }
        #expect(AdTextClassifier.classify([text("他说自己去过澳门新葡京"), promotion()]) != .advertisement)
    }

    @Test func partialOrUnrelatedNamesAndBrandAloneDoNotQualify() {
        for value in ["澳门", "葡京", "新葡亰", "澳门新葡", "新葡京艺术展"] {
            #expect(AdTextClassifier.classify([text(value), promotion()]) != .advertisement)
        }
        #expect(AdTextClassifier.classify([text("澳门新葡京")]) == .ordinary)
        #expect(AdTextClassifier.classify([text("澳门新葡京"), promotion("这是剧情字幕")]) == .ordinary)
    }

    @Test func oneTextBoxCannotProvideBothBrandAndPromotionEvidence() {
        #expect(AdTextClassifier.classify([text("澳门新葡京注册送彩金")]) != .advertisement)
        #expect(AdTextClassifier.classify([text("澳门新葡京"), promotion(rect: brandRect)]) != .advertisement)
    }

    @Test func subtitleBandDoesNotSupplyBrandOrPromotionEvenWhenCallerOmitsProtection() {
        let caption = NormalizedVideoRect(x: 0.25, y: 0.8, width: 0.5, height: 0.08)
        #expect(AdTextClassifier.classify([text("澳门新葡京", rect: caption), promotion()]) != .advertisement)
        #expect(AdTextClassifier.classify([text("澳门新葡京"), promotion(rect: caption)]) != .advertisement)
        #expect(AdTextClassifier.classify([text("澳门新葡京"), promotion(rect: caption)], protectedRegions: []) != .advertisement)
    }

    @Test func partialSubtitleOverlapRejectsTheWholeTextBox() {
        let touching = NormalizedVideoRect(x: 0.25, y: 0.69, width: 0.5, height: 0.04)
        #expect(AdTextClassifier.classify([text("澳门新葡京", rect: touching), promotion()]) != .advertisement)
        #expect(AdTextClassifier.classify([text("澳门新葡京"), promotion(rect: touching)]) != .advertisement)
    }

    @Test func additionalProtectionExcludesEitherEvidenceBox() {
        #expect(AdTextClassifier.classify([text("澳门新葡京"), promotion()], protectedRegions: [brandRect]) != .advertisement)
        #expect(AdTextClassifier.classify([text("澳门新葡京"), promotion()], protectedRegions: [promotionRect]) != .advertisement)
    }

    @Test func smallWatermarksAndCornerBrandsDoNotQualify() {
        let small = NormalizedVideoRect(x: 0.4, y: 0.2, width: 0.14, height: 0.039)
        let corners = [
            NormalizedVideoRect(x: 0, y: 0, width: 0.16, height: 0.05),
            NormalizedVideoRect(x: 0.84, y: 0, width: 0.16, height: 0.05),
            NormalizedVideoRect(x: 0, y: 0.6, width: 0.16, height: 0.05),
            NormalizedVideoRect(x: 0.84, y: 0.6, width: 0.16, height: 0.05)
        ]
        for rect in [small] + corners {
            #expect(AdTextClassifier.classify([text("澳门新葡京", rect: rect), promotion()]) != .advertisement)
        }
        #expect(AdTextClassifier.classify([text("澳门新葡京", rect: .init(x: 0.4, y: 0.2, width: 0.15, height: 0.04)), promotion()]) == .advertisement)
    }

    @Test func lowConfidenceCannotTriggerAndMalformedConfidenceIsUnknown() {
        #expect(AdTextClassifier.classify([text("澳门新葡京", confidence: 0.299), promotion()]) != .advertisement)
        for confidence in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            #expect(AdTextClassifier.classify([text("澳门新葡京", confidence: confidence), promotion()]) == .unknown)
        }
    }

    @Test func invalidTextOrProtectionGeometryIsUnknown() {
        for rect in [
            NormalizedVideoRect(x: .nan, y: 0.2, width: 0.3, height: 0.1),
            NormalizedVideoRect(x: 0.2, y: 0.2, width: .infinity, height: 0.1),
            NormalizedVideoRect(x: -0.1, y: 0.2, width: 0.3, height: 0.1),
            NormalizedVideoRect(x: 0.8, y: 0.2, width: 0.3, height: 0.1),
            NormalizedVideoRect(x: 0.2, y: 0.2, width: 0, height: 0.1)
        ] {
            #expect(AdTextClassifier.classify([text("澳门新葡京", rect: rect), promotion()]) == .unknown)
            #expect(AdTextClassifier.classify([text("澳门新葡京"), promotion()], protectedRegions: [rect]) == .unknown)
        }
    }

    @Test func emptySuccessfulOCRIsOrdinary() {
        #expect(AdTextClassifier.classify([]) == .ordinary)
    }

    @Test func threeConfirmedFramesClosedByOrdinaryUseOnlyConfirmedInterior() {
        let result = AdSegmentPolicy.segments(from: [frame(10), frame(12), frame(14), frame(16, .ordinary)])
        #expect(result == [AdSkipSegment(start: 10, end: 14)])
    }

    @Test func twoFramesOrInsufficientSpanAreNotEnough() {
        #expect(AdSegmentPolicy.segments(from: [frame(10), frame(12), frame(14, .ordinary)]).isEmpty)
        #expect(AdSegmentPolicy.segments(from: [frame(10), frame(11), frame(12), frame(13, .ordinary)]).isEmpty)
    }

    @Test func unclosedRunAndUnknownEndingCannotManufactureAnEnd() {
        #expect(AdSegmentPolicy.segments(from: [frame(10), frame(12), frame(14)]).isEmpty)
        #expect(AdSegmentPolicy.segments(from: [frame(10), frame(12), frame(14), frame(16, .unknown)]).isEmpty)
        #expect(AdSegmentPolicy.segments(from: [frame(10), frame(12), frame(14), frame(16, .unknown), frame(18, .ordinary)]).isEmpty)
    }

    @Test func unknownInsideRunPreventsBridgingAcrossUnobservedContent() {
        #expect(AdSegmentPolicy.segments(from: [frame(10), frame(12), frame(14, .unknown), frame(16), frame(18), frame(20, .ordinary)]).isEmpty)
        #expect(AdSegmentPolicy.segments(from: [frame(10), frame(12), frame(14, .unknown), frame(16), frame(18), frame(20), frame(22, .ordinary)]) == [AdSkipSegment(start: 16, end: 20)])
    }

    @Test func longSamplingGapDiscardsRunIncludingWhenNextFrameIsOrdinary() {
        #expect(AdSegmentPolicy.segments(from: [frame(10), frame(12), frame(15), frame(17), frame(19, .ordinary)]).isEmpty)
        #expect(AdSegmentPolicy.segments(from: [frame(10), frame(12), frame(14), frame(17, .ordinary)]).isEmpty)
        #expect(AdSegmentPolicy.segments(from: [frame(10), frame(12), frame(15), frame(17), frame(19), frame(21, .ordinary)]) == [AdSkipSegment(start: 15, end: 19)])
    }

    @Test func maximumSamplingGapIsAcceptedWithoutExpandingEdges() {
        #expect(AdSegmentPolicy.segments(from: [frame(10), frame(12.5), frame(15), frame(17.5, .ordinary)]) == [AdSkipSegment(start: 10, end: 15)])
    }

    @Test func ordinaryFrameSplitsTwoIndependentAdRuns() {
        let result = AdSegmentPolicy.segments(from: [frame(0, .ordinary), frame(2), frame(4), frame(6), frame(8, .ordinary), frame(10), frame(12), frame(14), frame(16, .ordinary)])
        #expect(result == [AdSkipSegment(start: 2, end: 6), AdSkipSegment(start: 10, end: 14)])
    }

    @Test func segmentOverNinetySecondsIsRejectedAsAWhole() {
        let accepted = stride(from: 0.0, through: 90.0, by: 2).map { frame($0) } + [frame(92, .ordinary)]
        let rejected = stride(from: 0.0, through: 92.0, by: 2).map { frame($0) } + [frame(94, .ordinary)]
        #expect(AdSegmentPolicy.segments(from: accepted) == [AdSkipSegment(start: 0, end: 90)])
        #expect(AdSegmentPolicy.segments(from: rejected).isEmpty)
    }

    @Test func invalidOrUnorderedTimesRejectTheBatchWithoutSorting() {
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            #expect(AdSegmentPolicy.segments(from: [frame(invalid), frame(10), frame(12), frame(14), frame(16, .ordinary)]).isEmpty)
        }
        #expect(AdSegmentPolicy.segments(from: [frame(10), frame(14), frame(12), frame(16, .ordinary)]).isEmpty)
        #expect(AdSegmentPolicy.segments(from: [frame(10), frame(12), frame(12), frame(14), frame(16, .ordinary)]).isEmpty)
        #expect(AdSegmentPolicy.segments(from: []).isEmpty)
    }

    @Test func skipOnlyInsideConfirmedSegmentWithAtLeastOneSecondRemaining() {
        let segment = AdSkipSegment(start: 10, end: 14)
        #expect(AdSegmentPolicy.target(at: 9.99, in: [segment], isPlaying: true, isBusy: false) == nil)
        #expect(AdSegmentPolicy.target(at: 10, in: [segment], isPlaying: true, isBusy: false) == segment)
        #expect(AdSegmentPolicy.target(at: 13, in: [segment], isPlaying: true, isBusy: false) == segment)
        #expect(AdSegmentPolicy.target(at: 13.001, in: [segment], isPlaying: true, isBusy: false) == nil)
        #expect(AdSegmentPolicy.target(at: 14, in: [segment], isPlaying: true, isBusy: false) == nil)
    }

    @Test func pausedOrBusyPlaybackNeverSkips() {
        let segments = [AdSkipSegment(start: 10, end: 14)]
        #expect(AdSegmentPolicy.target(at: 11, in: segments, isPlaying: false, isBusy: false) == nil)
        #expect(AdSegmentPolicy.target(at: 11, in: segments, isPlaying: true, isBusy: true) == nil)
    }

    @Test func anyIgnoredOverlapPreventsJumpingButAdjacentSegmentsDoNot() {
        let segment = AdSkipSegment(start: 10, end: 14)
        for ignored in [AdSkipSegment(start: 10, end: 14), AdSkipSegment(start: 8, end: 11), AdSkipSegment(start: 13, end: 18), AdSkipSegment(start: 11, end: 12)] {
            #expect(AdSegmentPolicy.target(at: 10, in: [segment], ignored: [ignored], isPlaying: true, isBusy: false) == nil)
        }
        #expect(AdSegmentPolicy.target(at: 10, in: [segment], ignored: [AdSkipSegment(start: 6, end: 10), AdSkipSegment(start: 14, end: 18)], isPlaying: true, isBusy: false) == segment)
    }

    @Test func malformedSeekInputsNeverProduceATarget() {
        let good = AdSkipSegment(start: 10, end: 14)
        for position in [Double.nan, .infinity, -.infinity, -1] {
            #expect(AdSegmentPolicy.target(at: position, in: [good], isPlaying: true, isBusy: false) == nil)
        }
        for bad in [AdSkipSegment(start: .nan, end: 14), AdSkipSegment(start: 10, end: .infinity), AdSkipSegment(start: -1, end: 14), AdSkipSegment(start: 14, end: 10), AdSkipSegment(start: 10, end: 10), AdSkipSegment(start: 0, end: 100)] {
            #expect(AdSegmentPolicy.target(at: 11, in: [bad], isPlaying: true, isBusy: false) == nil)
        }
    }
}
