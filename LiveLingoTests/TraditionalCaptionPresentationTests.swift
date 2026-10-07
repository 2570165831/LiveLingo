import Combine
import Foundation
import XCTest
@testable import LiveLingo

/// Authored text and tiny synthetic dictionaries only. Every model request is
/// intercepted by a request closure; no workers, audio or background services.
@MainActor
final class TraditionalCaptionPresentationTests: XCTestCase {
    private let traditionalLanguages: [(OutputLanguage, String)] = [
        (.traditionalChineseTaiwan, "頭髮在這裡。"),
        (.traditionalChineseHongKong, "頭髮在這裏。"),
    ]

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TraditionalCaption-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func dictionaries() throws -> URL {
        let directory = try temporaryDirectory()
        let files = [
            "STPhrases.txt": "头发\t頭髮\n",
            "STCharacters.txt": "头\t頭\n发\t發\n这\t這\n里\t裏\n书\t書\n学\t學\n习\t習\n译\t譯\n对\t對\n暂\t暫\n无\t無\n语\t語\n体\t體\n气\t氣\n离\t離\n后\t後\n",
            "TWVariants.txt": "裏\t裡\n",
            "HKVariants.txt": "裡\t裏\n",
            "TWPhrasesIT.txt": "# Synthetic empty dictionary\n",
            "TWPhrasesName.txt": "# Synthetic empty dictionary\n",
            "TWPhrasesOther.txt": "# Synthetic empty dictionary\n",
            // A deliberate non-idempotent chain detects double rendering.
            "TW-reviewed-phrases.txt": "甲\t乙\n乙\t丙\n",
            "LiveLingo-TW-overlay.txt": "# Synthetic empty overlay\n",
            "LiveLingo-HK-overlay.txt": "# Synthetic empty overlay\n",
        ]
        for (name, text) in files {
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return directory
    }

    private func caption(_ source: String = "The hair is here.", language: String? = nil,
                         chinese: String = "头发在这里。") -> TranscriptSegment {
        TranscriptSegment(startTime: 0, endTime: 2, english: source,
                          chinese: chinese, sourceLanguage: language)
    }

    private func fixture(converter: ChineseScriptConverter,
                         language: OutputLanguage = .simplifiedChinese,
                         translation: CaptionTranslationDependencies = .unavailable,
                         persistCreationPreference: Bool = false) throws -> (AppModel, URL) {
        let directory = try temporaryDirectory()
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.setVolatileDomain(["LiveLingo.outputLanguage": language.rawValue,
                                   "LiveLingo.modelMode": "highQuality"], forName: suite)
        if persistCreationPreference { defaults.set(language.rawValue, forKey: "LiveLingo.outputLanguage") }
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
                XCTFail("Display tests must never generate notes or start a model")
                throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: translation, notes: .unavailable,
            backgroundServices: false, scheduledNotes: false, defaults: defaults,
            chineseScriptConverter: converter)
        model.setReleasedOutputLanguagesForTesting([.simplifiedChinese, .traditionalChineseTaiwan,
                                                   .traditionalChineseHongKong])
        model.loadPresentationForTesting(phase: .idle, evidence: [], outputLanguage: language)
        addTeardownBlock {
            await model.chineseDisplayPreparationForTesting?.value
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            try cleanup.remove()
        }
        return (model, directory)
    }

    func testIdentityRenderersReturnExactBytesWithoutLoadingDictionaries() throws {
        let converter = ChineseScriptConverter(resourceDirectory: nil)
        let raw = "學習 DNA pH 7.4 e\u{0301} かな 한글 😀\n\t"
        for language in [OutputLanguage.simplifiedChinese, .english, .spanish, .french] {
            XCTAssertEqual(Data(try language.render(raw, converter: converter).utf8), Data(raw.utf8))
            XCTAssertEqual(Data(language.renderForDisplay(raw, converter: converter).utf8), Data(raw.utf8))
        }
        XCTAssertEqual(converter.debugLoadCount, 0)
        XCTAssertEqual(converter.debugCacheEntryCount, 0)
    }

    func testTraditionalDisplayWorksWhileExportGateStaysClosed() throws {
        let converter = ChineseScriptConverter(resourceDirectory: try dictionaries())
        for (language, expected) in traditionalLanguages {
            XCTAssertFalse(language.rendererIsAvailable)
            XCTAssertNil(OutputLanguage.savedRenderer(for: language.rawValue))
            XCTAssertEqual(try language.render("头发在这里。", converter: converter), expected)
        }
        XCTAssertEqual(converter.debugLoadCount, 1)
    }

    func testCompletedAndSourceOnlyCaptionsConvertOnce() throws {
        let converter = ChineseScriptConverter(resourceDirectory: try dictionaries())
        for (language, expected) in traditionalLanguages {
            let english = caption()
            let presentation = CaptionPresentation(english, outputLanguage: language, converter: converter)
            XCTAssertFalse(presentation.isSourceOnly)
            XCTAssertEqual(presentation.primaryText, english.english)
            XCTAssertNil(presentation.languageName)
            XCTAssertEqual(CaptionPresentation.translationText(english, outputLanguage: language,
                                                               converter: converter), expected)
            for chinese in ["头发在这里。", ""] {
                let sourceOnly = caption("头发在这里。", language: "zh", chinese: chinese)
                let row = CaptionPresentation(sourceOnly, outputLanguage: language, converter: converter)
                XCTAssertTrue(row.isSourceOnly)
                XCTAssertEqual(row.primaryText, expected)
                XCTAssertEqual(row.languageName, "中文")
                XCTAssertEqual(sourceOnly.english, "头发在这里。")
                XCTAssertEqual(sourceOnly.chinese, chinese)
            }
        }
        let chain = caption("甲", language: "zh", chinese: "甲")
        XCTAssertEqual(CaptionPresentation(chain, outputLanguage: .traditionalChineseTaiwan,
                                          converter: converter).primaryText, "乙")
        XCTAssertEqual(CaptionPresentation.translationText(caption(chinese: "甲"),
            outputLanguage: .traditionalChineseTaiwan, converter: converter), "乙")
        XCTAssertEqual(try converter.convert("乙", to: .taiwan), "丙",
                       "This dictionary must expose a mistaken second conversion")
    }

    func testForeignOriginalLinesAndInterfaceLanguageNamesStayUnchanged() throws {
        let converter = ChineseScriptConverter(resourceDirectory: try dictionaries())
        for (language, expected) in traditionalLanguages {
            for (code, original, name) in [("ja", "髪は这里にあります。", "日语"),
                                            ("yue", "啲頭髮喺这里。", "粤语")] {
                let segment = caption(original, language: code)
                let row = CaptionPresentation(segment, outputLanguage: language, converter: converter)
                XCTAssertFalse(row.isSourceOnly)
                XCTAssertEqual(Data(row.primaryText.utf8), Data(original.utf8))
                XCTAssertEqual(row.languageName, name)
                XCTAssertEqual(CaptionPresentation.translationText(segment, outputLanguage: language,
                                                                   converter: converter), expected)
            }
        }
        XCTAssertEqual(CaptionPresentation.translationStatus(isTranslating: true), "翻译中…")
        XCTAssertEqual(CaptionPresentation.translationStatus(isTranslating: false), "等待翻译…")
    }

    func testFailureMarkersAreClassifiedBeforeRenderingFixedOutputText() throws {
        let converter = ChineseScriptConverter(resourceDirectory: try dictionaries())
        var failed = caption(chinese: "")
        failed.failTranslation("synthetic private diagnostic")
        var marker = caption()
        marker.chinese = "[翻译失败：synthetic private diagnostic]"
        let pending = caption(chinese: "")
        for (language, _) in traditionalLanguages {
            for segment in [failed, marker] {
                XCTAssertEqual(CaptionPresentation.translationText(segment, outputLanguage: language,
                    converter: converter), "（本段翻譯未完成，可對照英文）")
            }
            XCTAssertEqual(CaptionPresentation.translationText(pending, outputLanguage: language,
                converter: converter), "（本段暫無譯文）")
        }
        XCTAssertEqual(CaptionPresentation.translationText(failed, outputLanguage: .simplifiedChinese,
            converter: converter), "（本段翻译未完成，可对照英文）")
    }

    func testNonHanBytesSurviveRegionalCaching() throws {
        let converter = ChineseScriptConverter(resourceDirectory: try dictionaries())
        let raw = "DNA pH 7.4 CaCO₃ H₂O \\(x^2\\) $a+b$ e\u{0301} かな カナ 한글 😀\n\t"
        for region in [ChineseScriptConverter.Region.taiwan, .hongKong] {
            XCTAssertEqual(Data(try converter.convert(raw, to: region).utf8), Data(raw.utf8))
            XCTAssertEqual(Data(try converter.convert(raw, to: region).utf8), Data(raw.utf8))
            for spelling in ["café", "cafe\u{0301}"] {
                XCTAssertEqual(Data(try converter.convert(spelling, to: region).utf8), Data(spelling.utf8))
            }
        }
        XCTAssertEqual(converter.debugCacheHitCount, 2)
    }

    func testCacheKeysIncludeRegionAndUseBoundedLeastRecentEviction() throws {
        let converter = ChineseScriptConverter(resourceDirectory: try dictionaries(),
                                               cacheEntryLimit: 2, cacheByteLimit: 1_000)
        XCTAssertEqual(try converter.convert("这里", to: .taiwan), "這裡")
        XCTAssertEqual(try converter.convert("这里", to: .hongKong), "這裏")
        XCTAssertEqual(converter.debugCacheEntryCount, 2)
        XCTAssertEqual(converter.debugCacheByteCount, 24)
        _ = try converter.convert("这里", to: .taiwan)
        XCTAssertEqual(converter.debugCacheHitCount, 1)
        _ = try converter.convert("头发", to: .taiwan)
        XCTAssertEqual(converter.debugCacheEntryCount, 2)
        _ = try converter.convert("这里", to: .taiwan)
        XCTAssertEqual(converter.debugCacheHitCount, 2)
        _ = try converter.convert("这里", to: .hongKong)
        XCTAssertEqual(converter.debugCacheHitCount, 2, "The oldest regional entry was evicted")
        XCTAssertEqual(converter.debugCacheEntryCount, 2)
        XCTAssertLessThanOrEqual(converter.debugCacheByteCount, 1_000)
    }

    func testUtf8PayloadLimitIncludesBothInputAndOutputAndBypassesLargeEntries() throws {
        let converter = ChineseScriptConverter(resourceDirectory: try dictionaries(),
                                               cacheEntryLimit: 8, cacheByteLimit: 12)
        for text in ["这", "里", "头"] { _ = try converter.convert(text, to: .taiwan) }
        XCTAssertEqual(converter.debugCacheEntryCount, 2)
        XCTAssertEqual(converter.debugCacheByteCount, 12)
        _ = try converter.convert("这里", to: .taiwan)
        XCTAssertEqual(converter.debugCacheEntryCount, 1)
        XCTAssertEqual(converter.debugCacheByteCount, 12)
        for text in ["1234567890", String(repeating: "头发", count: 20)] {
            _ = try converter.convert(text, to: .taiwan)
            XCTAssertEqual(converter.debugCacheEntryCount, 1)
            XCTAssertEqual(converter.debugCacheByteCount, 12)
        }
        _ = try converter.convert("这里", to: .taiwan)
        XCTAssertEqual(converter.debugCacheHitCount, 1, "Large inputs must not evict useful captions")
        for limits in [(0, 12), (8, 0)] {
            let disabled = ChineseScriptConverter(resourceDirectory: try dictionaries(),
                cacheEntryLimit: limits.0, cacheByteLimit: limits.1)
            XCTAssertEqual(try disabled.convert("这里", to: .taiwan), "這裡")
            XCTAssertEqual(disabled.debugCacheEntryCount, 0)
            XCTAssertEqual(disabled.debugCacheByteCount, 0)
        }
    }

    func testConcurrentCacheMissesPreserveBothBoundsAndLoadOnce() throws {
        let converter = ChineseScriptConverter(resourceDirectory: try dictionaries(),
                                               cacheEntryLimit: 3, cacheByteLimit: 128)
        let results = TraditionalCaptionConcurrentResults()
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            do {
                let text = try converter.convert("头发在这里 \(index)。",
                    to: index.isMultiple(of: 2) ? .taiwan : .hongKong)
                results.record(index, text)
            } catch { results.record(index, "FAIL") }
        }
        let values = results.snapshot()
        XCTAssertEqual(values.count, 40)
        for index in 0..<40 {
            XCTAssertEqual(values[index], index.isMultiple(of: 2)
                ? "頭髮在這裡 \(index)。" : "頭髮在這裏 \(index)。")
        }
        XCTAssertEqual(converter.debugLoadCount, 1)
        XCTAssertLessThanOrEqual(converter.debugCacheEntryCount, 3)
        XCTAssertLessThanOrEqual(converter.debugCacheByteCount, 128)
    }

    func testDefaultPresentationDoesNotLoadOrPublishWhileReadingDisplays() throws {
        let converter = ChineseScriptConverter(resourceDirectory: nil)
        let (model, _) = try fixture(converter: converter)
        let chinese = caption("這本書放在桌上。", language: "zh", chinese: "这本书在桌上。")
        model.loadPresentationForTesting(phase: .recording, evidence: [chinese])
        var publications = 0
        let observation = model.objectWillChange.sink { _ in publications += 1 }
        for _ in 0..<4 {
            XCTAssertEqual(model.previewChineseDisplay, "这本书放在桌上。")
            for mode in [FloatingSubtitleDisplayMode.bilingual, .sourceOnly, .translationOnly] {
                _ = model.floatingSubtitlePresentation(mode: mode)
            }
            _ = CaptionPresentation(chinese, outputLanguage: model.captionDisplayLanguage, converter: converter)
        }
        withExtendedLifetime(observation) {}
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(converter.debugLoadCount, 0)
        XCTAssertNil(model.chineseDisplayPreparationForTesting)
        XCTAssertNil(model.chineseDisplayNotice)
    }

    func testConfirmedPreviewAndEveryFloatingModeUseConvertedBodiesOnly() async throws {
        let converter = ChineseScriptConverter(resourceDirectory: try dictionaries())
        for (language, expected) in traditionalLanguages {
            let (model, _) = try fixture(converter: converter, language: language)
            await model.chineseDisplayPreparationForTesting?.value
            XCTAssertTrue(model.chineseDisplayReady)
            for (code, source) in [("zh", "头发在这里。"), ("ja", "髪は这里にあります。"),
                                    ("yue", "啲頭髮喺这里。")] {
                let segment = caption(source, language: code)
                model.loadPresentationForTesting(phase: .recording, evidence: [segment])
                XCTAssertEqual(model.previewEnglishDisplay, source)
                XCTAssertEqual(model.previewChineseDisplay, expected)
                let bilingual = model.floatingSubtitlePresentation(mode: .bilingual)
                XCTAssertEqual(bilingual.translation?.text, expected)
                XCTAssertEqual(bilingual.source?.text, code == "zh" ? nil : source)
                let sourceOnly = model.floatingSubtitlePresentation(mode: .sourceOnly)
                XCTAssertEqual(sourceOnly.source?.text, code == "zh" ? expected : source)
                XCTAssertNil(sourceOnly.translation)
                let translationOnly = model.floatingSubtitlePresentation(mode: .translationOnly)
                XCTAssertNil(translationOnly.source)
                XCTAssertEqual(translationOnly.translation?.text, expected)
                XCTAssertEqual(model.segments.first?.chinese, "头发在这里。")
            }
            model.previewTranslationEnabled = false
            model.loadPresentationForTesting(phase: .recording, evidence: [caption()])
            XCTAssertEqual(model.previewChineseDisplay, "初译已关闭")
            XCTAssertEqual(model.floatingSubtitlePresentation(mode: .translationOnly).translation?.text, expected,
                           "Confirmed English translation remains available with initial preview disabled")
        }
    }

    func testVolatilePreviewConvertsContentButKeepsItsInterfacePrefix() async throws {
        let converter = ChineseScriptConverter(resourceDirectory: try dictionaries())
        for (language, expected) in traditionalLanguages {
            let (model, _) = try fixture(converter: converter, language: language)
            await model.chineseDisplayPreparationForTesting?.value
            model.previewTranslationEnabled = true
            model.receiveLivePreviewForTesting("The hair is here.", chinese: "头发在这里。")
            let preview = model.supportsPreviewTranslation ? "初译 · \(expected)" : "当前系统不支持初译；正式译文随后显示"
            XCTAssertEqual(model.previewChineseDisplay, preview)
            let floating = model.floatingSubtitlePresentation(mode: .bilingual)
            XCTAssertEqual(floating.source?.text, "The hair is here.")
            XCTAssertEqual(floating.translation?.text, preview)
            XCTAssertEqual(model.previewChinese, "头发在这里。")
        }
    }

    func testMissingResourcesFallBackAndPublishASeparateDisplayNotice() async throws {
        let converter = ChineseScriptConverter(resourceDirectory: nil)
        let (model, _) = try fixture(converter: converter, language: .traditionalChineseTaiwan)
        XCTAssertEqual(model.captionDisplayLanguage, .simplifiedChinese)
        await model.chineseDisplayPreparationForTesting?.value
        model.loadPresentationForTesting(phase: .recording,
            evidence: [caption("头发在这里。", language: "zh")])
        XCTAssertFalse(model.chineseDisplayReady)
        XCTAssertEqual(model.outputLanguage, .traditionalChineseTaiwan)
        XCTAssertEqual(model.captionDisplayLanguage, .simplifiedChinese)
        XCTAssertEqual(model.chineseDisplayNotice, "繁体转换字典缺失；当前显示简体底稿。")
        XCTAssertEqual(model.previewChineseDisplay, "头发在这里。")
        XCTAssertEqual(OutputLanguage.traditionalChineseTaiwan.renderForDisplay("头发在这里。",
            converter: converter), "头发在这里。")
        XCTAssertEqual(converter.debugLoadCount, 1)
        XCTAssertEqual(converter.debugCacheEntryCount, 0)
        XCTAssertNil(model.translationTaskForTesting)
    }

    func testMalformedResourcesProduceFallbackNoticeWithoutChangingGenerationTarget() async throws {
        let directory = try dictionaries()
        try "not a dictionary row".write(to: directory.appendingPathComponent("STPhrases.txt"),
                                       atomically: true, encoding: .utf8)
        let converter = ChineseScriptConverter(resourceDirectory: directory)
        let (model, _) = try fixture(converter: converter, language: .traditionalChineseHongKong)
        await model.chineseDisplayPreparationForTesting?.value
        XCTAssertEqual(model.captionTarget, .simplifiedChinese)
        XCTAssertEqual(model.captionDisplayLanguage, .simplifiedChinese)
        XCTAssertEqual(model.chineseDisplayNotice, "繁体转换字典无法读取：STPhrases.txt；当前显示简体底稿。")
        XCTAssertEqual(OutputLanguage.traditionalChineseHongKong.renderForDisplay("这里", converter: converter), "这里")
    }

    func testStalePreparationCannotPublishAfterChangingBackToSimplified() async throws {
        let converter = ChineseScriptConverter(resourceDirectory: nil)
        let (model, _) = try fixture(converter: converter, language: .traditionalChineseTaiwan)
        let pending = model.chineseDisplayPreparationForTesting
        model.loadPresentationForTesting(phase: .idle, evidence: [], outputLanguage: .simplifiedChinese)
        await pending?.value
        XCTAssertEqual(model.captionDisplayLanguage, .simplifiedChinese)
        XCTAssertFalse(model.chineseDisplayReady)
        XCTAssertNil(model.chineseDisplayNotice)
        XCTAssertNil(model.chineseDisplayPreparationForTesting)
    }

    func testChinesePolicySwitchDoesNotRewriteTheCourseStamp() async throws {
        XCTAssertTrue(ChineseOutputDefaults.fixedTextFollowsDisplayLanguage)
        XCTAssertTrue(ChineseOutputDefaults.jsonlKeepsSimplifiedDraft)
        XCTAssertTrue(ChineseOutputDefaults.canSwitchDisplay(from: .simplifiedChinese, to: .traditionalChineseTaiwan))
        XCTAssertTrue(ChineseOutputDefaults.canSwitchDisplay(from: .traditionalChineseTaiwan, to: .traditionalChineseHongKong))
        XCTAssertFalse(ChineseOutputDefaults.canSwitchDisplay(from: .english, to: .traditionalChineseTaiwan))
        let converter = ChineseScriptConverter(resourceDirectory: try dictionaries())
        let (model, directory) = try fixture(converter: converter, language: .traditionalChineseTaiwan,
                                           persistCreationPreference: true)
        await model.chineseDisplayPreparationForTesting?.value
        try await model.beginSavedCourseForTesting(directory: directory)
        let before = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertEqual(before.targetLocale, "zh-Hant-TW")
        model.loadPresentationForTesting(phase: .recording, evidence: [], outputLanguage: .traditionalChineseHongKong)
        try await model.flushSavedCourseForTesting()
        let after = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertEqual(after.targetLocale, before.targetLocale)
        XCTAssertEqual(model.captionTarget, .simplifiedChinese)
        XCTAssertEqual(model.captionDisplayLanguage, .traditionalChineseHongKong)
    }

    func testInjectedStreamingDraftIsConvertedWithoutMutatingStoredDraft() async throws {
        let converter = ChineseScriptConverter(resourceDirectory: try dictionaries())
        for (language, expected) in traditionalLanguages {
            var app: AppModel?
            var updates = 0
            var dependencies = CaptionTranslationDependencies.unavailable
            dependencies.translateTarget = { _, _, _, target, _, _, update in
                XCTAssertEqual(target, .simplifiedChinese)
                await update?("头发在这里。")
                let model = try XCTUnwrap(app)
                updates += 1
                XCTAssertEqual(model.streamingChinese, "头发在这里。")
                XCTAssertEqual(model.captionDisplayLanguage.renderForDisplay(model.streamingChinese,
                    converter: converter), expected)
                return "头发在这里。"
            }
            let (model, _) = try fixture(converter: converter, language: language, translation: dependencies)
            app = model
            await model.chineseDisplayPreparationForTesting?.value
            model.receiveCaptionForTesting("The hair is here.", start: 0, end: 2)
            await model.translationTaskForTesting?.value
            XCTAssertEqual(updates, 1)
            XCTAssertEqual(model.segments.first?.chinese, "头发在这里。")
            XCTAssertTrue(model.segments.first?.hasUsableTranslation == true)
        }
    }

    private struct CapturedLesson: Equatable {
        let requests: [TraditionalCaptionWireRequests.Request]
        let originals: [String]
        let drafts: [String]
    }

    private func captureLesson(_ language: OutputLanguage) async throws -> CapturedLesson {
        let requests = TraditionalCaptionWireRequests()
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translateTarget = { text, model, sourceLanguage, target, hints, attempt, _ in
            XCTAssertEqual(target, .simplifiedChinese)
            return try await QwenTranslationClient.translate(text, modelName: model,
                sourceLanguage: sourceLanguage, target: target, hints: hints, attempt: attempt,
                request: { input, prompt, budget in
                    await requests.record(input: input, prompt: prompt, budget: budget, model: model)
                })
        }
        dependencies.adjacentTarget = { _, _, _, _, _, _, _, _, _, _ in
            XCTFail("These spaced multilingual samples must not schedule adjacent repair")
            throw CancellationError()
        }
        dependencies.repairTarget = { _, _ in
            XCTFail("These complete samples must not schedule deferred repair")
            throw CancellationError()
        }
        dependencies.prepareRetry = { _ in
            XCTFail("Request doubles must not reach worker retirement")
            throw CancellationError()
        }
        dependencies.retrySleep = { _ in
            XCTFail("Valid synthetic captions must not retry")
            throw CancellationError()
        }
        let converter = ChineseScriptConverter(resourceDirectory: try dictionaries())
        let (model, directory) = try fixture(converter: converter, language: language, translation: dependencies)
        await model.chineseDisplayPreparationForTesting?.value
        try await model.beginSavedCourseForTesting(directory: directory)
        let samples: [(String?, String)] = [(nil, "The hair is here."), ("zh", "这本书放在桌上。"),
                                           ("yue", "啲頭髮喺呢度。"), ("ja", "髪はここにあります。")]
        for (index, sample) in samples.enumerated() {
            model.receiveIdentifiedCaptionForTesting(TranscriptSegment(startTime: Double(index * 10),
                endTime: Double(index * 10 + 2), english: sample.1, sourceLanguage: sample.0))
            await model.translationTaskForTesting?.value
        }
        XCTAssertTrue(model.segments.allSatisfy(\.hasUsableTranslation))
        XCTAssertEqual(model.segments.map(\.chinese),
                       ["头发在这里。", "这本书放在桌上。", "头发在这里。", "头发在这里。"])
        try await model.flushSavedCourseForTesting()
        let captured = await requests.snapshot()
        XCTAssertEqual(captured.count, 3, "Chinese pass-through emits no model request")
        if language == .simplifiedChinese { XCTAssertEqual(converter.debugLoadCount, 0) }
        return CapturedLesson(requests: captured, originals: model.segments.map(\.english),
                              drafts: model.segments.map(\.chinese))
    }

    func testTraditionalCoursesSendByteIdenticalInjectedRequestsAndKeepSimplifiedDrafts() async throws {
        let baseline = try await captureLesson(.simplifiedChinese)
        for (language, _) in traditionalLanguages {
            let traditional = try await captureLesson(language)
            XCTAssertEqual(traditional, baseline)
        }
    }
}

private final class TraditionalCaptionConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: String] = [:]
    func record(_ index: Int, _ text: String) { lock.withLock { values[index] = text } }
    func snapshot() -> [Int: String] { lock.withLock { values } }
}

private actor TraditionalCaptionWireRequests {
    struct Request: Equatable, Sendable {
        let input: Data
        let systemPrompt: Data
        let outputBudget: Int
        let model: String
    }
    private var requests: [Request] = []
    func record(input: String, prompt: String, budget: Int, model: String) -> String {
        requests.append(Request(input: Data(input.utf8), systemPrompt: Data(prompt.utf8),
                                outputBudget: budget, model: model))
        return "头发在这里。"
    }
    func snapshot() -> [Request] { requests }
}
