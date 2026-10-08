import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import LiveLingo

@MainActor
final class EnglishTargetTests: XCTestCase {
    func testLegacyChineseManifestImportKeepsParentInputFingerprint() throws {
        let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("LegacyChineseFingerprint-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = try XCTUnwrap(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let segmentID = try XCTUnwrap(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        let segment = TranscriptSegment(id: segmentID, startTime: 0, endTime: 1,
            english: "The temperature is 10 °C.", chinese: "温度是 10 °C。", sessionID: sessionID)
        for locale in ["zh-Hans", "zh-Hant", "zh-Hant-TW", "zh-Hant-HK"] {
            let directory = root.appendingPathComponent(locale)
            try SessionExporter.export(segments: [segment], sessionDirectory: directory,
                summary: "## 温度\n- 温度是 10 °C。", createdAt: Date(timeIntervalSince1970: 0))
            try setLegacyManifestTarget(locale, in: directory)
            XCTAssertFalse(FileManager.default.fileExists(atPath:
                directory.appendingPathComponent(SessionStore.snapshotFileName).path))
            let loaded = try SessionStore(directory: directory, legacySessionID: sessionID).loadDetailed()
            XCTAssertEqual(loaded.origin, .legacy)
            let snapshot = try XCTUnwrap(loaded.snapshot)
            XCTAssertNil(snapshot.targetLocale, locale)
            XCTAssertEqual(try snapshot.inputFingerprint(),
                "2cd54119ac29e0e9e34a9cff9a54e2a5413b3b3a21d10a64c4934ad5e45a2cec", locale)
            let expected: OutputLanguage = locale == "zh-Hant" ? .simplifiedChinese
                : try XCTUnwrap(OutputLanguage(rawValue: locale))
            XCTAssertEqual(try OutputLanguage.savedLanguage(in: directory,
                snapshot: snapshot, origin: loaded.origin), expected, locale)
            XCTAssertEqual(try LearningNotebook(snapshot: snapshot).target, .simplifiedChinese, locale)
        }
    }

    func testLegacyChinesePausedNotebookSourcesRestoreThroughApp() async throws {
        for locale in ["zh-Hans", "zh-Hant", "zh-Hant-TW", "zh-Hant-HK"] {
            let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
                .appendingPathComponent("LegacyChineseRecovery-\(UUID())")
            let directory = root.appendingPathComponent("course")
            let evidence = [TranscriptSegment(startTime: 0, endTime: 1,
                english: "The temperature is 10 °C.", chinese: "温度是 10 °C。")]
            var book = LearningNotebook()
            try book.append(evidence: evidence, note: LearningNote(topic: "温度", points: [
                .init(kind: "核心结论", text: "温度是 10 °C。", sourceIDs: ["zh0s0"])
            ], sourceVersion: 2, noNewKnowledge: false))
            try SessionExporter.export(segments: evidence, sessionDirectory: directory,
                summary: book.markdown(), createdAt: Date(timeIntervalSince1970: 0))
            try setLegacyManifestTarget(locale, in: directory)
            let job = try LearningReviewQueue.prepareJob(directory: directory,
                batches: book.batches, original: book.markdown())
            let journal = root.appendingPathComponent("queue.json")
            try JSONEncoder().encode(LearningReviewQueue.Journal(jobs: [job], userPaused: true,
                version: LearningReviewQueue.journalVersion)).write(to: journal)
            let queue = LearningReviewQueue(journalURL: journal, observeSleep: false,
                diagnostics: .disabled) { _, _, _, _, _ in
                XCTFail("A paused legacy queue must not generate")
                throw CancellationError()
            }
            let suite = "LiveLingo-Test-\(UUID())"
            let cleanup = try TestPreferenceCleanup(suite: suite)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
                backgroundServices: false, scheduledNotes: false, defaults: defaults)
            // Isolate legacy notebook recovery after release; production GUI
            // release rejection is covered without this override elsewhere.
            model.setReleasedOutputLanguagesForTesting([.simplifiedChinese, .traditionalChineseTaiwan, .traditionalChineseHongKong])
            addTeardownBlock {
                await model.resetTranslationSessionForTesting()?.value
                await queue.shutdownForTesting()
                try cleanup.remove()
                try FileManager.default.removeItem(at: root)
            }
            let loaded = try SessionStore(directory: directory).loadDetailed()
            let snapshot = try XCTUnwrap(loaded.snapshot)
            let before = try Data(contentsOf: journal)
            let recovered = try queue.restorableLegacyNotebook(for: directory, snapshot: snapshot)
            XCTAssertEqual(recovered?.batches, book.batches, locale)
            XCTAssertEqual(try Data(contentsOf: journal), before, "Read-only recovery changed progress: \(locale)")
            try await model.openSavedSession(directory, allowAutomaticProcessing: false)
            XCTAssertEqual(model.learningNotebookForTesting.batches, book.batches, locale)
            XCTAssertEqual(model.learningNotebookForTesting.target, .simplifiedChinese, locale)
            XCTAssertEqual(model.outputLanguage.rawValue, locale == "zh-Hant" ? "zh-Hans" : locale)
            XCTAssertTrue(model.archiveNotice?.contains("已恢复旧队列记录的笔记批次与来源") == true, locale)
            XCTAssertFalse(model.lectureSummary.isEmpty, locale)
            XCTAssertTrue(queue.userPaused, locale)
            let saved = try JSONDecoder().decode(LearningReviewQueue.Journal.self,
                from: Data(contentsOf: journal))
            XCTAssertNil(saved.jobs.first?.targetLocale, locale)
            XCTAssertEqual(saved.jobs.first?.next, 0, locale)
            XCTAssertEqual(saved.jobs.first?.reports, [], locale)
        }
    }

    // Regional manifests are synthetic: their renderer remains unreleased.
    // Exercise the supported storage path without claiming a regional export.
    private func setLegacyManifestTarget(_ locale: String, in directory: URL) throws {
        let manifest = directory.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        object["targetLocale"] = locale
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifest)
    }

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

    private func englishModel(_ dependencies: CaptionTranslationDependencies = .unavailable,
                              notes: LearningGenerationDependencies = .unavailable) async throws -> (AppModel, URL) {
        let root = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("EnglishTarget-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "ClassroomPresentation-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(EnglishDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in throw CancellationError() }
        let model = AppModel(reviewQueue: queue, translation: dependencies, notes: notes,
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

    func testEnglishCaptionsUseOwnedNonactivatingPanelWithOneVisibleRow() async throws {
        let (model, _) = try await englishModel()
        let suite = "EnglishTargetPanel-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { try cleanup.remove() }
        let preferences = FloatingSubtitlePreferences(store: defaults)
        model.receiveLivePreviewForTesting("A variable stores a value.")
        let controller = FloatingSubtitleWindowController(defaults: defaults)
        let panel = controller.prepareWindow(model: model)
        defer { controller.close() }
        let host = try XCTUnwrap(panel.contentView as? NSHostingView<AnyView>)
        var heights: [FloatingSubtitleDisplayMode: CGFloat] = [:]
        for mode in FloatingSubtitleDisplayMode.allCases {
            preferences.displayMode = mode
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            let caption = model.floatingSubtitlePresentation(mode: mode)
            XCTAssertEqual([caption.source, caption.translation].compactMap { $0 }.count, 1)
            XCTAssertEqual((caption.source ?? caption.translation)?.text, "A variable stores a value.")
            XCTAssertEqual(host.bounds.size, host.fittingSize)
            XCTAssertEqual(panel.contentMinSize, host.fittingSize)
            XCTAssertEqual(panel.contentMaxSize, host.fittingSize)
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(panel.isKeyWindow)
            heights[mode] = host.bounds.height
        }
        XCTAssertEqual(heights[.bilingual], heights[.translationOnly])
        XCTAssertLessThan(try XCTUnwrap(heights[.sourceOnly]), try XCTUnwrap(heights[.bilingual]))
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
        XCTAssertEqual(LatinTargetLengthGuard.englishFromHanMaximumRatio, 3.84)
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
    func testEnglishNoteGenerationCallSiteBindsEnglishEvidenceAndKeepsInternalKinds() async throws {
        var calls = 0
        var notes = LearningGenerationDependencies.unavailable
        notes.generate = { input, _, prefix, prompt, _ in
            calls += 1
            XCTAssertEqual(prompt, LearningPrompts.generateEnglish)
            XCTAssertEqual(prefix, "")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
            let evidence = try XCTUnwrap(json["evidence"] as? [[String: Any]])
            XCTAssertEqual(evidence.map { $0["language"] as? String }, Array(repeating: "en", count: evidence.count))
            let points = evidence.map { unit in ["kind": "例子", "text": unit["text"] as! String,
                "sourceIDs": [unit["id"] as! String]] as [String: Any] }
            return String(decoding: try JSONSerialization.data(withJSONObject:
                ["sourceVersion": 2, "topic": "Variables", "points": points, "noNewKnowledge": false],
                options: [.sortedKeys]), as: UTF8.self)
        }
        let (model, _) = try await englishModel(notes: notes)
        model.receiveIdentifiedCaptionForTesting(.init(startTime: 0, endTime: 1,
            english: "A variable stores a value.", sourceLanguage: "en"))
        model.receiveIdentifiedCaptionForTesting(.init(startTime: 1, endTime: 2,
            english: "Each variable has a name.", sourceLanguage: "en"))
        await model.generateSummaryForTesting()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.learningNotebookForTesting.target, .english)
        let point = try XCTUnwrap(model.learningNotebookForTesting.batches.first?.note.points.first)
        XCTAssertEqual(point.kind, "例子")
        XCTAssertEqual(point.referenceState, .linked)
        XCTAssertEqual(point.sourceIDs, ["en0s0"])
        XCTAssertEqual(point.sources?.map(\.quote), ["A variable stores a value."])
        XCTAssertTrue(model.lectureSummary.contains("**Example**: A variable stores a value."))
        XCTAssertFalse(model.lectureSummary.contains("**例子**"))
        model.exportIncludesReviewAdvice = false
        model.exportScope = .latest
        let exported = try XCTUnwrap(model.notesExportSnapshot())
        XCTAssertEqual(exported.target, .english)
        XCTAssertEqual(exported.className, "实时课堂")
        XCTAssertEqual(exported.coverageLine, "已整理 2 / 2 段已翻译内容")
        XCTAssertEqual(exported.scopeDetail, model.latestSummaryScope)
        XCTAssertTrue(NotesExportDocument.markdown(exported).contains("**Example**: A variable stores a value."))
        model.exportScope = .wholeLesson
        XCTAssertEqual(try XCTUnwrap(model.notesExportSnapshot()).scopeDetail, model.summaryCoverageStatus)
    }

    private actor HeldManualRequest {
        var continuation: CheckedContinuation<String, Never>?
        func reply() async -> String { await withCheckedContinuation { continuation = $0 } }
        var entered: Bool { continuation != nil }
        func finish() { continuation?.resume(returning: "The temperature increases."); continuation = nil }
    }

    private func observingNotes(_ observe: @escaping @MainActor @Sendable (String?) -> Void)
        -> LearningGenerationDependencies {
        .init(generate: { _, _, _, prompt, _ in
            observe(prompt)
            return #"{"sourceVersion":2,"topic":"Variables","points":[{"kind":"例子","text":"A variable stores a value.","sourceIDs":["en0s0"]}],"noNewKnowledge":false}"#
        })
    }

    func testRequiredGenerationDependencyForwardsEnglishPromptThroughApp() async throws {
        var prompts: [String?] = []
        let (model, _) = try await englishModel(notes: observingNotes { prompts.append($0) })
        model.receiveIdentifiedCaptionForTesting(.init(startTime: 0, endTime: 1, english: "A variable stores a value."))
        model.receiveIdentifiedCaptionForTesting(.init(startTime: 1, endTime: 2, english: "Each variable has a name."))
        await model.generateSummaryForTesting()
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts.first ?? nil, LearningPrompts.generateEnglish)
        XCTAssertEqual(model.learningNotebookForTesting.batches.first?.note.points.first?.referenceState, .linked)
    }

    func testSavedEnglishAdmissionBypassesQueueWhileManualTranslationIsInFlight() async throws {
        let (model, root) = try await englishModel()
        let held = HeldManualRequest()
        model.setTypedTranslationRequestForTesting { _, _, _ in
            await held.reply()
        }
        model.manualTranslationInput = "温度升高。"
        model.translateTypedText()
        for _ in 0..<100 {
            if await held.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let entered = await held.entered
        XCTAssertTrue(entered)
        let pending = [nil, "en"].enumerated().map { index, language in
            TranscriptSegment(startTime: Double(index), endTime: Double(index + 1),
                english: "The variable stores a value.", sourceLanguage: language)
        }
        model.loadPresentationForTesting(phase: .saved(root.appendingPathComponent("course")), evidence: pending)
        // This is the exact admission method used by resumeSavedProcessing;
        // keep the drain out of the pre-fix case so a busy loop cannot hang XCTest.
        model.restorePendingCaptionWorkForTesting()
        XCTAssertTrue(model.translationQueueForTesting.isEmpty)
        XCTAssertTrue(model.translationEnqueuedAtForTesting.isEmpty)
        XCTAssertTrue(model.segments.allSatisfy { $0.hasUsableTranslation && $0.chinese == $0.english })
        XCTAssertNil(model.translationTaskForTesting)
        await held.finish()
        for _ in 0..<100 where model.isManualTranslating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isManualTranslating)
    }

    func testSavedResumeStaysResponsiveDuringHeldManualRequestAndSkipsEnglishWorkers() async throws {
        var translations = 0, repairs = 0, adjacent = 0, apple = 0
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translateTarget = { _, _, _, _, _, _, _ in translations += 1; return "unused" }
        dependencies.adjacentTarget = { _, _, _, _, _, _, _, _, _, _ in
            adjacent += 1; return .init(previous: nil, current: nil, previousRejection: nil, currentRejection: nil)
        }
        dependencies.repairTarget = { _, _ in repairs += 1; return .init(previous: nil, rejection: nil) }
        let (model, root) = try await englishModel(dependencies)
        let directory = root.appendingPathComponent("held-resume")
        let pending = [nil, "en"].enumerated().map { index, language in
            TranscriptSegment(startTime: Double(index), endTime: Double(index + 1),
                english: "A variable stores a value.", sourceLanguage: language)
        }
        try SessionStore(directory: directory).save(SessionSnapshot(segments: pending, targetLocale: "en"))
        model.loadPresentationForTesting(phase: .saved(root.appendingPathComponent("course")), evidence: [])
        try await model.openSavedSession(directory, allowAutomaticProcessing: false)
        let held = HeldManualRequest()
        model.setTypedTranslationRequestForTesting { _, _, _ in await held.reply() }
        model.manualTranslationInput = "温度升高。"
        model.translateTypedText()
        for _ in 0..<100 {
            if await held.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let entered = await held.entered
        XCTAssertTrue(entered)
        model.resumeSavedProcessing()
        for _ in 0..<100 where model.segments.contains(where: { !$0.hasUsableTranslation }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let prepared = try await model.preparePreviewTranslationIfEligible { apple += 1 }
        XCTAssertFalse(prepared)
        XCTAssertTrue(model.isManualTranslating)
        XCTAssertTrue(model.translationQueueForTesting.isEmpty)
        XCTAssertTrue(model.translationEnqueuedAtForTesting.isEmpty)
        XCTAssertTrue(model.segments.allSatisfy { $0.hasUsableTranslation && $0.chinese == $0.english })
        XCTAssertEqual([translations, repairs, adjacent, apple], [0, 0, 0, 0])
        await held.finish()
        for _ in 0..<100 where model.isManualTranslating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isManualTranslating)
        await model.savedProcessingTaskForTesting?.value
    }

    func testLegacyEnglishImportBindsNotebookAndDraftToManifestTarget() async throws {
        let (model, root) = try await englishModel()
        let directory = root.appendingPathComponent("legacy")
        let evidence = [TranscriptSegment(startTime: 0, endTime: 1,
            english: "The variable stores a value.", chinese: "The variable stores a value.")]
        try SessionExporter.export(segments: evidence, sessionDirectory: directory,
            summary: "## Variables\nA variable stores a value.", target: .english)
        let loaded = try SessionStore(directory: directory).loadDetailed()
        XCTAssertEqual(loaded.origin, .legacy)
        let snapshot = try XCTUnwrap(loaded.snapshot)
        XCTAssertEqual(snapshot.targetLocale, "en")
        let notebook = try LearningNotebook(snapshot: snapshot)
        XCTAssertEqual(notebook.target, .english)
        let draft = LearningDraft(evidence: snapshot.segments, model: "synthetic",
            input: try LearningPrompts.input(evidence: snapshot.segments, topics: [], target: .english),
            target: .english, systemPrompt: LearningPrompts.generateEnglish)
        XCTAssertTrue(draft.matches(snapshot: snapshot, model: "synthetic", systemPrompt: draft.systemPrompt))
        model.loadPresentationForTesting(phase: .saved(root.appendingPathComponent("course")), evidence: [])
        try await model.openSavedSession(directory, allowAutomaticProcessing: false)
        guard case .saved(let opened) = model.phase else { return XCTFail("Legacy course was not opened") }
        XCTAssertEqual(opened, directory)
        XCTAssertEqual(model.outputLanguage, .english)
        XCTAssertEqual(model.learningNotebookForTesting.target, .english)
    }

    func testLegacyEnglishRebuildPersistsTargetAndCommitsGeneratedNotesAfterReopen() async throws {
        var calls = 0
        var notes = LearningGenerationDependencies.unavailable
        notes.generate = { _, _, _, prompt, _ in
            calls += 1
            XCTAssertEqual(prompt, LearningPrompts.generateEnglish)
            return #"{"sourceVersion":2,"topic":"Variables","points":[{"kind":"例子","text":"A variable stores a value.","sourceIDs":["en0s0"]}],"noNewKnowledge":false}"#
        }
        let (model, root) = try await englishModel(notes: notes)
        let directory = root.appendingPathComponent("legacy-rebuild")
        try SessionExporter.export(segments: [.init(startTime: 0, endTime: 1,
            english: "A variable stores a value.", chinese: "A variable stores a value.")],
            sessionDirectory: directory, summary: "## Variables\nPreserved old notes.", target: .english)
        model.loadPresentationForTesting(phase: .saved(root.appendingPathComponent("course")), evidence: [])
        try await model.openSavedSession(directory, allowAutomaticProcessing: false)
        model.rebuildSavedNotes()
        for _ in 0..<200 where model.learningNotebookForTesting.batches.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.savedProcessingTaskForTesting?.value
        try await model.flushSavedCourseForTesting()
        XCTAssertEqual(calls, 1, "status=\(model.summaryStatus); error=\(model.archiveError ?? "none"); legacy=\(model.legacyProvenanceUnavailable)")
        XCTAssertEqual(model.learningNotebookForTesting.batches.count, 1)
        let saved = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertEqual(saved.targetLocale, "en")
        try await model.openSavedSession(directory, allowAutomaticProcessing: false)
        XCTAssertEqual(model.outputLanguage, .english)
        XCTAssertEqual(model.learningNotebookForTesting.target, .english)
        XCTAssertEqual(model.learningNotebookForTesting.batches.count, 1)
        XCTAssertTrue(model.lectureSummary.contains("**Example**: A variable stores a value."))
    }

    func testExplicitEnglishFormulaAnnotationSurvivesRevisionAndSavedResume() async throws {
        let (model, root) = try await englishModel()
        let original = TranscriptSegment(startTime: 0, endTime: 1,
            english: "The formula is [Formula transcription uncertain].")
        model.receiveIdentifiedCaptionForTesting(original)
        XCTAssertEqual(model.segments.first?.captionAnnotation, .formulaNeedsReview)
        model.reviseCaptionForTesting(id: original.id,
            english: "The new formula is [Formula transcription uncertain].")
        XCTAssertEqual(model.segments.first?.captionAnnotation, .formulaNeedsReview)
        let directory = root.appendingPathComponent("pending-formula")
        try SessionStore(directory: directory).save(SessionSnapshot(segments: [original], targetLocale: "en"))
        model.loadPresentationForTesting(phase: .saved(root.appendingPathComponent("course")), evidence: model.segments)
        try await model.openSavedSession(directory, allowAutomaticProcessing: false)
        model.resumeSavedProcessing()
        for _ in 0..<100 where model.segments.first?.hasUsableTranslation != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.savedProcessingTaskForTesting?.value
        XCTAssertEqual(model.segments.first?.captionAnnotation, .formulaNeedsReview)
        XCTAssertEqual(model.segments.first?.chinese, original.english)
    }

}
