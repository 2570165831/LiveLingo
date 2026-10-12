import XCTest
@testable import LiveLingo

final class TranscriptStateTests: XCTestCase {
    func testLegacyFailureRestoresExplicitStateAndSafeDisplay() throws {
        let data = Data(#"{"id":"EA655B70-3B10-4B24-B8F0-C36BCCBCBC82","startTime":0,"endTime":3,"english":"Heat moves.","chinese":"[翻译失败：budget exhausted]"}"#.utf8)
        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        XCTAssertEqual(segment.translationState, .failed)
        XCTAssertEqual(segment.translationError, "budget exhausted")
        XCTAssertFalse(segment.hasUsableTranslation)
        XCTAssertEqual(segment.displayChinese, "（本段翻译未完成，可对照英文）")
    }

    func testFailureRoundTripDoesNotPutDiagnosticsInChineseBody() throws {
        var segment = TranscriptSegment(startTime: 2, endTime: 4, english: "Work is energy transfer.")
        segment.beginTranslation()
        XCTAssertEqual(segment.translationState, .translating)
        segment.failTranslation("worker exited")
        XCTAssertTrue(segment.chinese.isEmpty)
        let restored = try JSONDecoder().decode(TranscriptSegment.self, from: JSONEncoder().encode(segment))
        XCTAssertEqual(restored, segment)
        XCTAssertFalse(restored.displayChinese.contains("worker exited"))
    }

    func testSuccessfulRetryRetainsIdentityAndClearsFailure() throws {
        let sessionID = UUID()
        var segment = TranscriptSegment(startTime: 2, endTime: 4, english: "Work is energy transfer.",
                                        sessionID: sessionID, inputRevision: 3)
        let id = segment.id
        segment.failTranslation("timeout")
        segment.beginTranslation()
        segment.completeTranslation("功是能量的传递。")
        XCTAssertEqual(segment.id, id)
        XCTAssertEqual(segment.sessionID, sessionID)
        XCTAssertEqual(segment.inputRevision, 3)
        XCTAssertTrue(segment.hasUsableTranslation)
        XCTAssertNil(segment.translationError)
        XCTAssertEqual(segment.displayChinese, "功是能量的传递。")
    }

    func testInterruptedTranslationCanReturnToPendingWithoutLosingEnglish() {
        var segment = TranscriptSegment(startTime: 0, endTime: 2, english: "The speed is constant.")
        segment.beginTranslation()
        segment.deferTranslation()
        XCTAssertEqual(segment.translationState, .pending)
        XCTAssertEqual(segment.english, "The speed is constant.")
    }

    func testMalformedSavedTimesAreRejected() {
        let data = Data(#"{"id":"EA655B70-3B10-4B24-B8F0-C36BCCBCBC82","startTime":4,"endTime":2,"english":"text","chinese":"文字"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TranscriptSegment.self, from: data))
    }
}

// P2c: synthetic preview events only; background services and model work disabled.
@MainActor
final class VolatilePreviewRangeTests: XCTestCase {
    private func fixture() throws -> AppModel {
        let root = TestFixtureDirectory.root.appendingPathComponent("LiveLingo-P2c-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
                XCTFail("Preview range tests must not start notes or models")
                throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
        model.resetTranslationSessionForTesting()
        addTeardownBlock { @MainActor in
            try await TestTaskLifetime.stop(model, queue: queue)
            try cleanup.remove()
            // Fixture stays in the owned test worker directory for inspection.
        }
        return model
    }

    func testP2cOlderSilentChunkPreservesNewPreviewTranslationAndRange() throws {
        let model = try fixture()
        model.receiveLivePreviewForTesting("A newer synthetic preview.", start: 10, end: 12, chinese: "新的初译。")
        model.receiveLivePreviewForTesting("", start: 0, end: 10)
        XCTAssertEqual(model.volatileEnglish, "A newer synthetic preview.")
        XCTAssertEqual(model.previewTranslationSource, "A newer synthetic preview.")
        XCTAssertEqual(model.previewChinese, "新的初译。")
        // The ignored old event must also retain the range for its own later clear.
        model.receiveLivePreviewForTesting("", start: 10, end: 14)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
        XCTAssertTrue(model.previewTranslationSource.isEmpty)
        XCTAssertTrue(model.previewChinese.isEmpty)
    }

    func testP2cOlderSilenceCannotClearPreviewJustPastItsBoundary() throws {
        let model = try fixture()
        model.receiveLivePreviewForTesting("New speech starts here.", start: 10, end: 10.1, chinese: "新语音。")
        model.receiveLivePreviewForTesting("", start: 0, end: 10)
        XCTAssertEqual(model.volatileEnglish, "New speech starts here.")
        XCTAssertEqual(model.previewChinese, "新语音。",
                       "Silence ownership has no tolerance that reaches into the next chunk")
    }

    func testP2cSilentChunkClearsOnlyFullyCoveredPreview() throws {
        let model = try fixture()
        let cases: [(start: Double, end: Double, clears: Bool)] = [
            (10, 12, true), (9, 14, true), (0, 10, false), (12, 14, false),
            (11, 14, false), (9, 11, false)
        ]
        for event in cases {
            model.receiveLivePreviewForTesting("The synthetic current preview.", start: 10, end: 12, chinese: "当前初译。")
            model.receiveLivePreviewForTesting("", start: event.start, end: event.end)
            XCTAssertEqual(model.volatileEnglish, event.clears ? "" : "The synthetic current preview.")
            XCTAssertEqual(model.previewChinese, event.clears ? "" : "当前初译。")
        }
    }

    func testP2cUnknownOrInvalidSilentRangeKeepsKnownPreview() throws {
        let model = try fixture()
        let ranges: [(Double, Double)] = [(0, 0), (14, 10), (-1, 12), (.nan, 12), (0, .infinity)]
        for (start, end) in ranges {
            model.receiveLivePreviewForTesting("Keep this synthetic preview.", start: 10, end: 12, chinese: "保留初译。")
            model.receiveLivePreviewForTesting("", start: start, end: end)
            XCTAssertEqual(model.volatileEnglish, "Keep this synthetic preview.")
            XCTAssertEqual(model.previewChinese, "保留初译。")
        }
    }

    func testP2cUntimedReplacementDoesNotInheritPreviousPreviewRange() throws {
        let model = try fixture()
        model.receiveLivePreviewForTesting("The old timed preview.", start: 0, end: 2)
        model.receiveLivePreviewForTesting("A replacement with unknown timing.", chinese: "未知时间的初译。")
        model.receiveLivePreviewForTesting("", start: 0, end: 2)
        XCTAssertEqual(model.volatileEnglish, "A replacement with unknown timing.")
        XCTAssertEqual(model.previewChinese, "未知时间的初译。")
    }

    func testSilentBlocksTogetherRetireASpanningPreview() throws {
        let model = try fixture()
        model.receiveLivePreviewForTesting("A preview spanning three blocks.", start: 0, end: 30, chinese: "跨块初译。")
        for start in [0.0, 10.0] {
            model.receiveLivePreviewForTesting("", start: start, end: start + 10)
            XCTAssertEqual(model.volatileEnglish, "A preview spanning three blocks.")
            XCTAssertEqual(model.previewChinese, "跨块初译。")
        }
        model.receiveLivePreviewForTesting("", start: 20, end: 30)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
        XCTAssertTrue(model.previewChinese.isEmpty)
        XCTAssertTrue(model.previewTranslationSource.isEmpty)
    }

    func testFinalPrefixAndSilentSuffixRetireASpanningPreview() throws {
        let model = try fixture()
        model.receiveLivePreviewForTesting("Speech followed by a silent tail.", start: 0, end: 20, chinese: "尾部静音。")
        model.receiveCaptionForTesting("Confirmed speech.", start: 0, end: 10)
        XCTAssertEqual(model.volatileEnglish, "Speech followed by a silent tail.")
        model.receiveLivePreviewForTesting("", start: 10, end: 20)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
        XCTAssertTrue(model.previewChinese.isEmpty)
        XCTAssertEqual(model.segments.last?.english, "Confirmed speech.")
    }

    func testSilentSuffixThenIdentifiedFinalPrefixAlsoRetirePreview() throws {
        let model = try fixture()
        model.receiveLivePreviewForTesting("A preview with delayed confirmation.", start: 0, end: 20)
        model.receiveLivePreviewForTesting("", start: 10, end: 20)
        XCTAssertFalse(model.volatileEnglish.isEmpty)
        let result = TranscriptionCommit(id: UUID(), sessionID: model.captureHealthSessionIDForTesting,
            text: "Confirmed speech.", start: 0, end: 10, startFrame: 0, endFrame: 160_000,
            sampleRate: 16_000, hints: [], isRepair: false)
        model.receiveTranscriptionNoticeForTesting(.identifiedFinal(result))
        XCTAssertTrue(model.volatileEnglish.isEmpty)
        XCTAssertEqual(model.segments.last?.id, result.id)
    }

    func testOutOfOrderOverlappingCoverageMustFillEveryGap() throws {
        let model = try fixture()
        model.receiveLivePreviewForTesting("Keep the uncovered middle.", start: 10, end: 30, chinese: "中间仍有缺口。")
        for range in [(25.0, 35.0), (0.0, 15.0), (10.0, 15.0), (14.0, 20.0)] {
            model.receiveLivePreviewForTesting("", start: range.0, end: range.1)
            XCTAssertEqual(model.previewChinese, "中间仍有缺口。")
        }
        model.receiveLivePreviewForTesting("", start: 20, end: 25)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
        XCTAssertTrue(model.previewChinese.isEmpty)
    }

    func testEveryPreviewDeliveryResetsCoverageEvenWithIdenticalTextAndRange() throws {
        let model = try fixture()
        model.receiveLivePreviewForTesting("The same preview.", start: 0, end: 20)
        model.receiveLivePreviewForTesting("", start: 0, end: 10)
        model.receiveLivePreviewForTesting("The same preview.", start: 0, end: 20, chinese: "重新观察。")
        model.receiveLivePreviewForTesting("", start: 10, end: 20)
        XCTAssertEqual(model.volatileEnglish, "The same preview.")
        XCTAssertEqual(model.previewChinese, "重新观察。")
        model.receiveLivePreviewForTesting("", start: 0, end: 10)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
    }

    func testNewerPreviewCannotBorrowEarlierCoverageOrOldSilentBlock() throws {
        let model = try fixture()
        model.receiveLivePreviewForTesting("An old preview.", start: 0, end: 20)
        model.receiveLivePreviewForTesting("", start: 0, end: 10)
        model.receiveLivePreviewForTesting("A newer preview.", start: 10, end: 30, chinese: "新的初译。")
        model.receiveLivePreviewForTesting("", start: 0, end: 10)
        model.receiveLivePreviewForTesting("", start: 20, end: 30)
        XCTAssertEqual(model.volatileEnglish, "A newer preview.")
        XCTAssertEqual(model.previewChinese, "新的初译。")
        model.receiveLivePreviewForTesting("", start: 10, end: 20)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
    }

    func testInvalidCoverageAndEvenATinyGapCannotRetirePreview() throws {
        let model = try fixture()
        model.receiveLivePreviewForTesting("An exact interval.", start: 0, end: 20)
        model.receiveLivePreviewForTesting("", start: 0, end: 10)
        model.receiveLivePreviewForTesting("", start: 10.001, end: 20)
        for range in [(-1.0, 20.0), (Double.nan, 20.0), (0.0, Double.infinity), (20.0, 0.0)] {
            model.receiveLivePreviewForTesting("", start: range.0, end: range.1)
            XCTAssertEqual(model.volatileEnglish, "An exact interval.")
        }
        model.receiveLivePreviewForTesting("", start: 10, end: 10.001)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
    }

    func testSessionResetDoesNotCarryCoverageIntoAnotherPreview() throws {
        let model = try fixture()
        model.receiveLivePreviewForTesting("Old session preview.", start: 0, end: 20)
        model.receiveLivePreviewForTesting("", start: 0, end: 10)
        model.resetTranslationSessionForTesting()
        model.receiveLivePreviewForTesting("New session preview.", start: 0, end: 20)
        model.receiveLivePreviewForTesting("", start: 10, end: 20)
        XCTAssertEqual(model.volatileEnglish, "New session preview.")
        model.receiveLivePreviewForTesting("", start: 0, end: 10)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
    }

    func testConfirmedPrefixBeforePreviewStillCountsWhenSilentTailArrives() throws {
        let model = try fixture()
        model.receiveCaptionForTesting("Already confirmed speech.", start: 0, end: 10)
        model.receiveLivePreviewForTesting("A window including confirmed speech.", start: 0, end: 20, chinese: "含已定稿前缀。")
        model.receiveLivePreviewForTesting("", start: 10, end: 20)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
        XCTAssertTrue(model.previewChinese.isEmpty)
        XCTAssertEqual(model.segments.last?.english, "Already confirmed speech.")
    }

    func testNewPreviewKeepsConfirmedPrefixButCannotReusePriorSilence() throws {
        let model = try fixture()
        model.receiveCaptionForTesting("Already confirmed speech.", start: 0, end: 10)
        model.receiveLivePreviewForTesting("An overlapping window.", start: 0, end: 30)
        model.receiveLivePreviewForTesting("", start: 10, end: 20)
        model.receiveLivePreviewForTesting("An overlapping window.", start: 0, end: 30, chinese: "新的预览事件。")
        model.receiveLivePreviewForTesting("", start: 20, end: 30)
        XCTAssertEqual(model.volatileEnglish, "An overlapping window.")
        XCTAssertEqual(model.previewChinese, "新的预览事件。")
        model.receiveLivePreviewForTesting("", start: 10, end: 20)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
    }

    func testLateDuplicatePreviewIsRetiredFromBothCaptionReaders() throws {
        let model = try fixture()
        model.receiveIdentifiedCaptionForTesting(.init(startTime: 0, endTime: 10,
            english: "The wind stops.", chinese: "风停了。"))
        model.receiveLivePreviewForTesting("The wind stops", chinese: "旧初译。")
        model.receiveLivePreviewForTesting("The wind stops.", start: 0, end: 10)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
        XCTAssertTrue(model.captionStream.volatileEnglish.isEmpty)
        XCTAssertEqual(model.previewTranslationSource, "The wind stops.", "Keep the formal-caption fallback")
        XCTAssertTrue(model.previewChinese.isEmpty)
        model.previewTranslationEnabled = false
        let floating = model.floatingSubtitlePresentation(mode: .translationOnly)
        XCTAssertNil(floating.source)
        XCTAssertEqual(floating.translation?.text, "风停了。")
        XCTAssertEqual(model.segments.count, 1)
    }

    func testLateDuplicateIgnoresCaseWidthWhitespaceAndEdgePunctuation() throws {
        let model = try fixture()
        model.receiveCaptionForTesting("The wind, stops.", start: 0, end: 10)
        model.receiveLivePreviewForTesting("  ＴＨＥ\nｗｉｎｄ　ＳＴＯＰＳ！  ", start: 0, end: 10)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
        // Every duplicate delivery must be suppressed, not just the first one.
        model.receiveLivePreviewForTesting("the wind stops", start: 0, end: 10)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
    }

    func testLateDuplicateCanMatchMultipleTouchingFinals() throws {
        let model = try fixture()
        model.receiveCaptionForTesting("The wind stops.", start: 10, end: 20)
        model.receiveCaptionForTesting("A bell rings.", start: 0, end: 10)
        model.receiveLivePreviewForTesting("A bell rings. The wind stops.", start: 0, end: 20)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
        XCTAssertEqual(model.segments.count, 2)
    }

    func testNewTextWithOldFullyCoveredTimingRemainsVisible() throws {
        let model = try fixture()
        model.receiveCaptionForTesting("The wind stops.", start: 0, end: 10)
        model.receiveLivePreviewForTesting("A bell rings.", start: 0, end: 10, chinese: "铃响了。")
        XCTAssertEqual(model.volatileEnglish, "A bell rings.")
        XCTAssertEqual(model.captionStream.volatileEnglish, "A bell rings.")
        XCTAssertEqual(model.previewChinese, "铃响了。")
        XCTAssertEqual(model.previewTranslationSource, "A bell rings.")
        XCTAssertEqual(model.floatingSubtitlePresentation(mode: .bilingual).source?.text, "A bell rings.")
        // The conflicting old finals must not make a partial silent event
        // appear to cover this entire new delivery.
        model.receiveLivePreviewForTesting("", start: 0, end: 5)
        XCTAssertEqual(model.volatileEnglish, "A bell rings.")
        XCTAssertEqual(model.previewChinese, "铃响了。")
        model.receiveLivePreviewForTesting("", start: 5, end: 10)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
    }

    func testLatePreviewComparisonPreservesMeaningfulTextDifferences() throws {
        let model = try fixture()
        let pairs = [
            ("The wind stops.", "The wind never stops."),
            ("The wind stops.", "Stops the wind."),
            ("Now here.", "Nowhere."),
            ("The value is 1.5.", "The value is 15."),
            ("The value is .5.", "The value is 5."),
            ("The value is ,5.", "The value is 5."),
            ("The value is -1.", "The value is 1."),
            ("A resume.", "A résumé."),
            ("We re-sign.", "We resign."),
            ("We can't stop.", "We can stop.")
        ]
        for (final, preview) in pairs {
            model.resetTranslationSessionForTesting()
            model.receiveCaptionForTesting(final, start: 0, end: 10)
            model.receiveLivePreviewForTesting(preview, start: 0, end: 10)
            XCTAssertEqual(model.volatileEnglish, preview)
        }
    }

    func testMatchingWordsWithUncoveredTimeOrGapRemainVisible() throws {
        let model = try fixture()
        model.receiveCaptionForTesting("A bell rings.", start: 0, end: 10)
        model.receiveLivePreviewForTesting("A bell rings.", start: 0, end: 20)
        XCTAssertEqual(model.volatileEnglish, "A bell rings.")
        model.receiveLivePreviewForTesting("A bell rings.", start: 10, end: 20)
        XCTAssertEqual(model.volatileEnglish, "A bell rings.")
        model.receiveCaptionForTesting("The wind stops.", start: 10.001, end: 20)
        model.receiveLivePreviewForTesting("A bell rings. The wind stops.", start: 0, end: 20)
        XCTAssertEqual(model.volatileEnglish, "A bell rings. The wind stops.")
    }

    func testLatePreviewWithUnknownOrInvalidTimingRemainsVisible() throws {
        let model = try fixture()
        model.receiveCaptionForTesting("The wind stops.", start: 0, end: 10)
        for (start, end) in [(0.0, 0.0), (-1.0, 10.0), (10.0, 0.0), (.nan, 10.0), (0.0, .infinity)] {
            model.receiveLivePreviewForTesting("The wind stops.", start: start, end: end)
            XCTAssertEqual(model.volatileEnglish, "The wind stops.")
        }
    }

    func testSubsetAndPunctuationOnlyAreInsufficientEvidenceOfDuplicate() throws {
        let model = try fixture()
        model.receiveCaptionForTesting("The wind stops and a bell rings.", start: 0, end: 10)
        model.receiveLivePreviewForTesting("A bell rings.", start: 0, end: 10)
        XCTAssertEqual(model.volatileEnglish, "A bell rings.")
        model.resetTranslationSessionForTesting()
        model.receiveCaptionForTesting("...", start: 0, end: 10)
        model.receiveLivePreviewForTesting("...", start: 0, end: 10)
        XCTAssertEqual(model.volatileEnglish, "...")
    }
}
