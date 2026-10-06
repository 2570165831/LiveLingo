import Foundation
import XCTest
@testable import LiveLingo

final class MultilingualCaptionPresentationTests: XCTestCase {
    private func caption(_ language: String? = nil, source: String = "The water is cold.",
                         chinese: String = "水很冷。") -> TranscriptSegment {
        TranscriptSegment(startTime: 0, endTime: 2, english: source, chinese: chinese, sourceLanguage: language)
    }

    func testSimplifiedChineseNamesUseInterfaceLanguage() {
        let expected = ["zh": "中文", "yue": "粤语", "es": "西班牙语", "fr": "法语",
                        "ru": "俄语", "ar": "阿拉伯语", "ja": "日语", "ko": "韩语"]
        for (code, name) in expected {
            XCTAssertEqual(CaptionLanguageNames.name(for: code), name)
        }
    }

    func testEverySupportedNonEnglishLanguageHasAChineseName() throws {
        for language in SpokenLanguage.all where language.code != "en" {
            let name = try XCTUnwrap(CaptionLanguageNames.name(for: language.code))
            XCTAssertNotEqual(name, language.code)
            XCTAssertNotEqual(name, language.qwenLabel)
            XCTAssertTrue(name.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
        }
    }

    func testOtherInterfaceLocalesUseLocalizedNamesRatherThanAutonyms() {
        XCTAssertEqual(CaptionLanguageNames.name(for: "es", locale: Locale(identifier: "en")), "Spanish")
        for identifier in ["zh-Hant-TW", "zh-Hant-HK", "fr"] {
            let locale = Locale(identifier: identifier)
            XCTAssertEqual(CaptionLanguageNames.name(for: "ja", locale: locale),
                           locale.localizedString(forLanguageCode: "ja"))
        }
    }

    func testEnglishAndUnknownCodesHaveNoLanguageLabel() {
        for code in [nil, "en", "unsupported"] as [String?] {
            XCTAssertNil(CaptionLanguageNames.name(for: code))
            XCTAssertNil(CaptionPresentation(caption(code)).languageName)
        }
    }

    func testChineseHasOneLineAndPrefersStoredNormalizedCaption() {
        let presentation = CaptionPresentation(caption("zh", source: "這裡有兩本書。", chinese: "这里有两本书。"))
        XCTAssertEqual(presentation.languageName, "中文")
        XCTAssertTrue(presentation.isChineseOnly)
        XCTAssertEqual(presentation.textLines, ["这里有两本书。"])
        XCTAssertNil(presentation.secondaryText)
    }

    func testChineseWithoutTranslationStillHasOneNormalizedLine() {
        let presentation = CaptionPresentation(caption("zh", source: "這裡有兩本書。", chinese: ""))
        XCTAssertEqual(presentation.textLines, ["这里有两本书。"])
        XCTAssertNil(presentation.secondaryText)
    }

    func testFailedChineseDoesNotExposeTranslationFailureAsASecondLine() {
        var segment = caption("zh", source: "這裡有兩本書。")
        segment.failTranslation("synthetic failure")
        XCTAssertEqual(CaptionPresentation(segment).textLines, ["这里有两本书。"])
    }

    func testCantoneseAndOtherLanguagesKeepOriginalAndChineseLines() {
        for (code, source) in [("yue", "啲水好凍。"), ("es", "El agua está fría."), ("ja", "水は冷たい。") ] {
            let presentation = CaptionPresentation(caption(code, source: source))
            XCTAssertFalse(presentation.isChineseOnly)
            XCTAssertEqual(presentation.textLines, [source, "水很冷。"])
        }
    }

    func testSelectableCaptionTextContainsNoLabelOrAccessibilityPrefix() {
        for (code, source) in [("zh", "水很冷。"), ("yue", "啲水好凍。"), ("es", "El agua está fría.")] {
            let presentation = CaptionPresentation(caption(code, source: source))
            let selectedText = presentation.textLines.joined(separator: "\n")
            XCTAssertEqual(selectedText, code == "zh" ? "水很冷。" : source + "\n水很冷。")
            XCTAssertFalse(selectedText.contains(presentation.languageName ?? "missing-label"))
            XCTAssertFalse(selectedText.contains("语种："))
        }
    }

    func testSeparateAccessibilityLabelDoesNotChangeCaptionBody() throws {
        let presentation = CaptionPresentation(caption("es", source: "El agua está fría."))
        let name = try XCTUnwrap(presentation.languageName)
        XCTAssertEqual(CaptionLanguageNames.accessibilityLabel(for: name), "语种：西班牙语")
        XCTAssertEqual(presentation.primaryText, "El agua está fría.")
        XCTAssertEqual(presentation.secondaryText, "水很冷。")
    }

    func testExportRemainsFreeOfPresentationLabels() {
        for (code, source) in [("zh", "水很冷。"), ("yue", "啲水好凍。"), ("es", "El agua está fría.")] {
            let segment = caption(code, source: source)
            XCTAssertEqual(SessionExporter.sourceLine(segment), source)
            let lines = code == "zh" ? source : source + "\n水很冷。"
            XCTAssertEqual(SessionExporter.srtCue(segment, index: 0),
                           "1\n00:00:00,000 --> 00:00:02,000\n" + lines)
        }
    }

    func testEnglishCaptionTextAndTranslationStatesRemainUnchanged() {
        var pending = caption(chinese: "")
        var translating = pending
        translating.beginTranslation()
        var failed = pending
        failed.failTranslation("synthetic failure")
        pending.deferTranslation()
        let cases: [(TranscriptSegment, String)] = [
            (caption(), "水很冷。"), (pending, "（本段暂无译文）"),
            (translating, "（本段暂无译文）"), (failed, "（本段翻译未完成，可对照英文）"),
        ]
        for (segment, chinese) in cases {
            let presentation = CaptionPresentation(segment)
            XCTAssertNil(presentation.languageName)
            XCTAssertFalse(presentation.isChineseOnly)
            XCTAssertEqual(presentation.textLines, ["The water is cold.", chinese])
        }
    }

    func testSavedSummaryCountsChineseCantoneseAndOtherLanguagesSeparately() {
        let segments = [caption(), caption("zh"), caption("zh"), caption("yue"), caption("es")]
        XCTAssertEqual(SavedProcessingPresentation.languageSummary(segments: segments, untranscribedCount: 3),
                       "中文发言 2 段 · 其他语言 2 段 · 非英语讲话（未能可靠转写）3 段")
    }

    func testSavedSummaryOmitsEveryZeroCountItem() {
        XCTAssertEqual(SavedProcessingPresentation.languageSummary(segments: [caption("zh")]), "中文发言 1 段")
        XCTAssertEqual(SavedProcessingPresentation.languageSummary(segments: [caption("yue")]), "其他语言 1 段")
        XCTAssertEqual(SavedProcessingPresentation.languageSummary(segments: [], untranscribedCount: 1),
                       "非英语讲话（未能可靠转写）1 段")
        XCTAssertNil(SavedProcessingPresentation.languageSummary(segments: []))
    }

    func testPureEnglishSavedSummaryRemainsExactlyTheSame() {
        let state = processingState()
        XCTAssertNil(SavedProcessingPresentation.languageSummary(segments: [caption(), caption("en")]))
        XCTAssertEqual(SavedProcessingPresentation.workSummary(state, segments: [caption()]),
                       "等待转写 2 段 · 待确认或失败 1 段")
    }

    func testSavedWorkSummaryIncludesOnlyConfirmedCaptionLanguagesAndTerminalFailures() {
        let segments = [caption("zh"), caption("es")]
        XCTAssertEqual(SavedProcessingPresentation.workSummary(processingState(otherLanguageCount: 1), segments: segments),
                       "等待转写 2 段 · 待确认或失败 1 段 · 中文发言 1 段 · 其他语言 1 段 · 非英语讲话（未能可靠转写）1 段")
    }

    private func processingState(otherLanguageCount: Int = 0) -> TranscriptionProcessingState {
        .init(sessionID: UUID(), isCapturing: false, isPaused: true, activeCount: 0,
              pendingCount: 2, backlogSeconds: 4, unresolvedCount: 1, otherLanguageCount: otherLanguageCount)
    }
}

@MainActor
final class MultilingualPreviewPresentationTests: XCTestCase {
    private func model() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MultilingualPreview-\(UUID())")
        let suite = "MultilingualPreview-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
                                       observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
            XCTFail("Presentation tests must not start a language model")
            throw CancellationError()
        }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
                             backgroundServices: false, scheduledNotes: false, defaults: defaults)
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            UserDefaults.standard.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        return model
    }

    func testChineseFloatingAndClassroomPreviewUseTheSameSingleStoredLine() throws {
        let model = try model()
        let segment = TranscriptSegment(startTime: 0, endTime: 2, english: "這本書放在桌上。",
                                       chinese: "这本书在桌上。", sourceLanguage: "zh")
        model.loadPresentationForTesting(phase: .idle, evidence: [segment])
        let presentation = try XCTUnwrap(model.nonEnglishPreviewPresentation)
        XCTAssertEqual(presentation.textLines, ["这本书在桌上。"])
        XCTAssertEqual(model.previewChineseDisplay, "这本书在桌上。")
        XCTAssertFalse(model.previewChineseDisplay.hasPrefix("初译 ·"))
    }

    func testForeignFloatingAndClassroomPreviewKeepTwoLinesAndNoInitialTranslationPrefix() throws {
        let model = try model()
        for (code, source) in [("yue", "啲水好凍。"), ("es", "El agua está fría.")] {
            let segment = TranscriptSegment(startTime: 0, endTime: 2, english: source,
                                           chinese: "水很冷。", sourceLanguage: code)
            model.loadPresentationForTesting(phase: .idle, evidence: [segment])
            XCTAssertEqual(model.nonEnglishPreviewPresentation?.textLines, [source, "水很冷。"])
            XCTAssertEqual(model.previewEnglishDisplay, source)
            XCTAssertEqual(model.previewChineseDisplay, "水很冷。")
        }
    }

    func testNewLiveEnglishDoesNotInheritPreviousNonEnglishLabel() throws {
        let model = try model()
        let segment = TranscriptSegment(startTime: 0, endTime: 2, english: "水很冷。",
                                       chinese: "水很冷。", sourceLanguage: "zh")
        model.loadPresentationForTesting(phase: .idle, evidence: [segment])
        model.receiveLivePreviewForTesting("A new English sentence.", chinese: "新的英文句子。")
        XCTAssertNil(model.nonEnglishPreviewPresentation)
        XCTAssertEqual(model.previewEnglishDisplay, "A new English sentence.")
        XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
                       ? "初译 · 新的英文句子。" : "当前系统不支持初译；正式译文随后显示")
    }

    func testPureEnglishPreviewPlaceholdersAndDisabledWordingRemainUnchanged() throws {
        let model = try model()
        XCTAssertNil(model.nonEnglishPreviewPresentation)
        XCTAssertEqual(model.previewEnglishDisplay, "等待英文语音…")
        XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
                       ? "等待语音…" : "当前系统不支持初译；正式译文随后显示")
        model.previewTranslationEnabled = false
        XCTAssertEqual(model.previewChineseDisplay, "初译已关闭")
    }
}
