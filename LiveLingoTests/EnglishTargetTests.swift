import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class EnglishTargetTests: XCTestCase {
    func testOptionalAnnotationsPreserveDefaultBytesAndRoundTripLatinMetadata() throws {
        var segment = TranscriptSegment(startTime: 0, endTime: 1, english: "An uncertain formula.")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let baseline = try encoder.encode(segment)
        segment.updateCaptionAnnotation(targetCode: "zh-Hans", formulaUncertain: true)
        XCTAssertEqual(try encoder.encode(segment), baseline)
        XCTAssertNil(segment.captionAnnotation)
        segment.completeTranslation("【公式待核对】公式。")
        XCTAssertEqual(segment.chinese, "【公式待核对】公式。")
        XCTAssertNil(segment.captionAnnotation)
        for target in ["en", "es", "fr"] {
            var marked = TranscriptSegment(startTime: 0, endTime: 1, english: "An uncertain formula.")
            marked.updateCaptionAnnotation(targetCode: target)
            XCTAssertEqual(marked.captionAnnotation, .translationPending)
            XCTAssertEqual(marked.chinese, "")
            marked.completeTranslation("【公式待核对】Formula.", targetCode: target)
            XCTAssertEqual(marked.chinese, "Formula.")
            XCTAssertEqual(marked.captionAnnotation, .formulaNeedsReview)
            XCTAssertEqual(marked.annotationText(targetCode: target), "【公式待核对】")
            XCTAssertEqual(try JSONDecoder().decode(TranscriptSegment.self, from: encoder.encode(marked)), marked)
            marked.recordTranslationFailure(.translationRejected)
            marked.finishFailedTranslation()
            marked.updateCaptionAnnotation(targetCode: target)
            XCTAssertEqual(marked.chinese, "")
            XCTAssertEqual(marked.captionAnnotation, .translationIncomplete)
        }
    }

    func testFixedTextDefaultsToInterfaceChineseWithoutEnteringCaptionBody() {
        XCTAssertFalse(ClassroomFixedText.usesTargetLanguage)
        XCTAssertEqual(ClassroomFixedText.pendingTranslation.text(targetCode: "en"), "（本段暂无译文）")
        XCTAssertEqual(ClassroomFixedText.pendingTranslation.text(targetCode: "en", useTargetLanguage: true), "(Translation pending)")
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "水很冷。", sourceLanguage: "zh")
        XCTAssertEqual(segment.chinese, "")
        XCTAssertEqual(SessionExporter.targetLine(segment, outputLanguage: .english), "（本段暂无译文）")
    }
    private final class EnglishDefaults: UserDefaults, @unchecked Sendable {
        override func string(forKey key: String) -> String? {
            key == "LiveLingo.outputLanguage" ? "en" : super.string(forKey: key)
        }
    }

    private func englishModel(_ dependencies: CaptionTranslationDependencies = .unavailable) async throws -> (AppModel, URL) {
        let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("EnglishTarget-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ClassroomPresentation-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(EnglishDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _ in throw CancellationError() }
        let model = AppModel(reviewQueue: queue, translation: dependencies, notes: .unavailable,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
        model.setReleasedOutputLanguagesForTesting([.simplifiedChinese, .english])
        try await model.beginSavedCourseForTesting(directory: root.appendingPathComponent("course"))
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            try cleanup.remove()
            try FileManager.default.removeItem(at: root)
        }
        return (model, root)
    }

    func testEnglishReceptionDoesNotCallTranslationRepairOrApplePreparation() async throws {
        var translations = 0, adjacent = 0, repairs = 0, apple = 0
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translate = { _, _, _, _, _ in translations += 1; return "unused" }
        dependencies.translateTarget = { _, _, _, _, _, _, _ in translations += 1; return "unused" }
        dependencies.adjacent = { _, _, _, _, _, _, _, _, _ in
            adjacent += 1; return .init(previous: nil, current: nil, previousRejection: nil, currentRejection: nil)
        }
        dependencies.repair = { _ in repairs += 1; return .init(previous: nil, rejection: nil) }
        let (model, _) = try await englishModel(dependencies)
        XCTAssertEqual(model.captionTarget, .english)
        XCTAssertFalse(OutputLanguage.english.isReleased)
        XCTAssertFalse(OutputLanguage.released.contains(.english))
        model.receiveLivePreviewForTesting("The variable", chinese: "stale preview")
        XCTAssertEqual(model.previewTranslationSource, "")
        let preview = model.floatingSubtitlePresentation(mode: .bilingual)
        XCTAssertNil(preview.source)
        XCTAssertEqual(preview.translation?.text, "The variable")
        for (index, language) in [nil, "en"].enumerated() {
            model.receiveIdentifiedCaptionForTesting(.init(startTime: Double(index), endTime: Double(index + 1),
                english: "The variable stores a value.", sourceLanguage: language))
        }
        await model.translationTaskForTesting?.value
        let prepared = try await model.preparePreviewTranslationIfEligible { apple += 1 }
        XCTAssertFalse(prepared)
        XCTAssertNil(model.applePreviewLanguagePair)
        XCTAssertEqual([translations, adjacent, repairs, apple], [0, 0, 0, 0])
        XCTAssertNil(model.translationTaskForTesting)
        XCTAssertTrue(model.segments.allSatisfy { $0.hasUsableTranslation && $0.chinese == $0.english })
        XCTAssertEqual(model.recentTranslationContext(before: 1), "")
        XCTAssertEqual(model.repairTranslationContext(model.segments), "")
        for mode in FloatingSubtitleDisplayMode.allCases {
            let shown = model.floatingSubtitlePresentation(mode: mode)
            XCTAssertEqual([shown.source, shown.translation].compactMap { $0 }.count, 1)
            XCTAssertEqual((shown.source ?? shown.translation)?.text, "The variable stores a value.")
        }
    }

    private actor RequestCount {
        var count = 0
        func reply() -> String { count += 1; return "unused" }
    }

    func testEnglishRuntimePassthroughMakesNoRequestsForEitherEnglishMarker() async throws {
        let count = RequestCount()
        for language in [nil, "en"] as [String?] {
            let text = "The variable stores a value."
            let output = try await QwenTranslationClient.translate(text, modelName: "synthetic", sourceLanguage: language,
                target: .english, request: { _, _, _ in await count.reply() })
            XCTAssertEqual(output, text)
        }
        let requests = await count.count
        XCTAssertEqual(requests, 0)
    }

    func testEnglishEvidenceAndExportsAreSingleGroupAndSingleLine() throws {
        let english = TranscriptSegment(startTime: 0, endTime: 1, english: "The variable stores a value.", chinese: "The variable stores a value.")
        let foreign = TranscriptSegment(startTime: 1, endTime: 2, english: "水很冷。", chinese: "The water is cold.", sourceLanguage: "zh")
        for segment in [english, foreign] {
            let groups = LearningSourceUnit.textGroups(for: segment, target: .english)
            XCTAssertEqual(groups.map(\.language), ["en"])
            XCTAssertEqual(groups.map(\.text), [segment.chinese])
        }
        XCTAssertEqual(LearningSourceUnit.make([foreign], target: .english).map(\.id), ["en0s0"])
        XCTAssertTrue(CaptionPresentation(english, target: .english).isSourceOnly)
        XCTAssertEqual(SessionExporter.srtCue(english, index: 0, outputLanguage: .english),
            "1\n00:00:00,000 --> 00:00:01,000\nThe variable stores a value.")
        let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("EnglishExport-\(UUID())")
        try SessionExporter.export(segments: [english], sessionDirectory: root,
            summary: "## Variables\n- A variable stores a value.", createdAt: Date(timeIntervalSince1970: 0), target: .english)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("bilingual.srt"), encoding: .utf8),
            "1\n00:00:00,000 --> 00:00:01,000\nThe variable stores a value.\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("transcript-target-en.txt"), encoding: .utf8),
            "The variable stores a value.\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("summary-en.md"), encoding: .utf8),
            "## Variables\n- A variable stores a value.\n")
        XCTAssertEqual(NotesExportDocument.transcriptHeading(for: .english), "字幕（含时间戳）")
        XCTAssertEqual(NotesExportDocument.transcriptHeading(for: .simplifiedChinese), "双语字幕（含时间戳）")
    }

}
