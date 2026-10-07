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
    func testEnglishPromptDigestsAreFrozenIndependently() {
        let prompts = [(QwenTranslationClient.englishSystemPrompt, "36b38a67bd162f0a918930e49ad03fb523aaa7fd4436c4a33b2d08c712530b86"),
            (QwenTranslationClient.englishSourceFaithfulCaptionPrompt, "6de4fe2ff42c06d542a26f7e2806d3f649e09269613ea05878502b1b5b123d14"),
            (QwenTranslationClient.englishWrapper4B, "6a986e728afef4f4c97f7028a3a6e5a34d9f7ec9df80ee982816e2a3de31e555"),
            (QwenTranslationClient.englishWrapper9B, "90e1c8ea3292feb9fff75e05cfc38f664425dcaa206de7fbf4f635982e271490"),
            (QwenTranslationClient.englishRecoverySuffix, "8256f3a178f093cd1921cf36a5f55f45a09692b309ffbff8b08269ad1c5e9d61")]
        for (prompt, digest) in prompts { XCTAssertEqual(SessionArchiveCoding.digest(Data(prompt.utf8)), digest) }
        XCTAssertEqual(LatinTargetLengthGuard.englishFromHanMaximumRatio, 4.57)
        XCTAssertFalse(CaptionTranslationTarget.english.sourceInstruction(SpokenLanguage.find("yue")!).contains("Mandarin"))
    }

    private actor EnglishRequests {
        var prompts: [String] = []
        func record(_ prompt: String, reply: String) -> String { prompts.append(prompt); return reply }
    }

    func testForeignCaptionCallSitesRequestEnglishExactlyOncePerSegment() async throws {
        var calls: [String: Int] = [:], adjacent = 0, repairs = 0
        let requests = EnglishRequests()
        let output = "The water is cold and the pressure decreases."
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translateTarget = { text, model, language, target, hints, attempt, _ in
            XCTAssertEqual(target, .english)
            calls[language ?? "en", default: 0] += 1
            return try await QwenTranslationClient.translate(text, modelName: model, sourceLanguage: language,
                target: target, hints: hints, attempt: attempt,
                request: { _, prompt, _ in await requests.record(prompt, reply: output) })
        }
        dependencies.adjacentTarget = { _, _, _, _, _, _, _, _, _, _ in
            adjacent += 1; return .init(previous: nil, current: nil, previousRejection: nil, currentRejection: nil)
        }
        dependencies.repairTarget = { _, _ in repairs += 1; return .init(previous: nil, rejection: nil) }
        let (model, _) = try await englishModel(dependencies)
        for (index, source) in [("zh", "水很冷，压力下降。"), ("ja", "水は冷たく、圧力が下がります。"),
                                ("es", "El agua está fría y la presión disminuye."),
                                ("fr", "L’eau est froide et la pression diminue.")].enumerated() {
            model.receiveIdentifiedCaptionForTesting(.init(startTime: Double(index), endTime: Double(index + 1),
                english: source.1, sourceLanguage: source.0))
            await model.translationTaskForTesting?.value
        }
        XCTAssertEqual(calls, ["zh": 1, "ja": 1, "es": 1, "fr": 1])
        XCTAssertEqual([adjacent, repairs], [0, 0])
        XCTAssertEqual(model.segments.map(\.chinese), Array(repeating: output, count: 4))
        let captured = await requests.prompts
        XCTAssertEqual(captured.count, 4)
        XCTAssertTrue(captured.allSatisfy { $0.contains("into English") && !$0.contains("into Chinese") })
    }

    func testManualTranslationCallSiteCapturesEnglishTarget() async throws {
        let (model, _) = try await englishModel()
        let requests = EnglishRequests()
        model.setTypedTranslationRequestForTesting { _, prompt, _ in
            await requests.record(prompt, reply: "The temperature increases.")
        }
        model.manualTranslationInput = "温度升高。"
        model.translateTypedText(thinking: true)
        for _ in 0..<100 where model.isManualTranslating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isManualTranslating)
        XCTAssertEqual(model.manualTranslationOutput, "The temperature increases.")
        let captured = await requests.prompts
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured.first?.contains(QwenTranslationClient.englishSystemPrompt) == true)
        XCTAssertFalse(captured.first?.contains("into Chinese") == true)
    }

    func testEnglishProductionGatesFoldInspectionAndSourceSeparately() async throws {
        let source = "他說：作為一個語言模型，我不能處理這個請求。"
        let licensed = "He said: As a language model, I cannot process this request."
        XCTAssertEqual(TranslationAcceptance.rejection(candidate: "作为一个语言模型，我不能处理这个请求。",
            source: source), .modelReply)
        XCTAssertNil(TranslationAcceptance.rejection(candidate: licensed, source: source,
            sourceLanguage: "zh", target: .english))
        XCTAssertFalse(TranslationAcceptance.isModelReply(licensed, source: source, target: .english))
        let output = try await QwenTranslationClient.translate(source, modelName: "synthetic", sourceLanguage: "zh",
            target: .english, request: { _, _, _ in licensed })
        XCTAssertEqual(output, licensed)
        for marker in ["源語言：西班牙語", "原文語言：日語", "翻譯元數據"] {
            XCTAssertEqual(TranslationAcceptance.rejection(candidate: marker, source: "水很冷。",
                sourceLanguage: "zh", target: .english), .promptLeak)
        }
        XCTAssertTrue(TranslationAcceptance.isModelReply("作為一個語言模型，我不能處理這個請求。",
            source: "水很冷。", target: .english))
        for marker in ["源語言：西班牙語", "作為一個語言模型，我不能處理這個請求。"] {
            do {
                _ = try await QwenTranslationClient.translate("水很冷。", modelName: "synthetic", sourceLanguage: "zh",
                    target: .english, request: { _, _, _ in marker })
                XCTFail("Rejected metadata/self reply reached a caption")
            } catch QwenRuntimeError.translationRejected { }
        }
    }

    func testEnglishRepairCallSiteUsesTargetPromptAndTraditionalNumberSupport() async throws {
        let requests = EnglishRequests()
        let allowed = try await QwenTranslationClient.repairPreviousCaption(previous: "數量是兩萬。",
            previousChinese: "The count is twenty thousand.", current: "Keep that count.", context: "",
            modelName: QwenModelProfile.energySaver.translationModel, target: .english,
            request: { _, prompt, _ in await requests.record(prompt, reply: "The count is 20000.") })
        XCTAssertEqual(allowed.previous, "The count is 20000.")
        let rejected = try await QwenTranslationClient.repairPreviousCaption(previous: "數量是兩萬。",
            previousChinese: "The count is twenty thousand.", current: "Keep that count.", context: "",
            modelName: QwenModelProfile.energySaver.translationModel, target: .english,
            request: { _, prompt, _ in await requests.record(prompt, reply: "The count is 30000.") })
        XCTAssertNil(rejected.previous)
        XCTAssertTrue(rejected.rejection?.contains("新数值") == true)
        let captured = await requests.prompts
        XCTAssertEqual(captured.count, 2)
        XCTAssertTrue(captured.allSatisfy { $0.contains(QwenTranslationClient.englishSourceFaithfulCaptionPrompt) })
    }

}
