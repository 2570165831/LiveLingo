import Foundation
import XCTest
@testable import LiveLingo

@MainActor
private final class Item7Gate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Error>?
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation = $0; entered = true }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor RejectionRequestCapture {
    var requests: [(String, String, Int)] = []
    func record(_ input: String, _ prompt: String, _ budget: Int) { requests.append((input, prompt, budget)) }
    func snapshot() -> [(String, String, Int)] { requests }
}

@MainActor
final class TranslationFailureRecoveryTests: XCTestCase {
    typealias Reason = TranscriptSegment.TranslationFailureReason
    private let source = "The room is cold."
    private let result = "房间很冷。"

    func testQuotationRetryUsesTheProductionPromptAndPreservesItsSource() async throws {
        let source = "Fuck your mother."
        for model in [QwenModelProfile.highQuality.translationModel, QwenModelProfile.energySaver.translationModel] {
            let capture = RejectionRequestCapture()
            let result = try await QwenTranslationClient.translate(source, modelName: model, attempt: .repairQuotedContent, request: { input, prompt, budget in
                await capture.record(input, prompt, budget)
                return "你妈的。"
            })
            XCTAssertEqual(result, "你妈的。")
            let requests = await capture.snapshot()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests[0].2, 320)
            XCTAssertTrue(requests[0].1.contains("including profanity and offensive language"))
            XCTAssertTrue(requests[0].1.hasSuffix(CaptionTranslationAttempt.repairQuotedContent.quotationPostscript(for: .simplifiedChinese)))
            if model == QwenModelProfile.highQuality.translationModel {
                let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(requests[0].0.utf8)) as? [String: String])
                XCTAssertEqual(payload, ["source_text_to_translate": source])
            } else { XCTAssertEqual(requests[0].0, source) }
        }
        XCTAssertEqual(CaptionTranslationAttempt.standard.quotationPostscript(for: .simplifiedChinese), "")
        XCTAssertEqual(CaptionTranslationAttempt.repairQuotedContent.quotationPostscript(for: .english), "")
        XCTAssertEqual(CaptionTranslationAttempt.repairContent.quotationPostscript(for: .simplifiedChinese), "")
    }

    func testAdjacentFailuresKeepTheSpecificAcceptanceCode() async throws {
        for (output, code) in [
            ("抱歉，我无法提供该内容的翻译。", TranslationAcceptance.Rejection.modelReply),
            ("Fuck your mother.", .sourceEcho),
            ("source_text_to_translate", .promptLeak)
        ] {
            let pair = try await QwenTranslationClient.translateAdjacent(previous: "Air is cold.", previousChinese: "空气很冷。", current: "Fuck your mother.", context: "", modelName: QwenModelProfile.highQuality.translationModel, repairPrevious: false, request: { _, _, _ in output })
            XCTAssertNil(pair.current)
            XCTAssertNotNil(pair.currentRejection)
            XCTAssertEqual(pair.currentRejectionCode, code)
        }
    }

    func testTypedRejectionCodesPersistWithoutPrivateMessages() throws {
        var segment = TranscriptSegment(startTime: 0, endTime: 1, english: source)
        for code in TranslationAcceptance.Rejection.allCases {
            segment.recordTranslationFailure(.translationRejected, rejection: code)
            segment.recordTranslationFailure(.translationRejected, rejection: code)
        }
        segment.finishFailedTranslation()
        let bytes = try encode(segment)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: bytes)
        XCTAssertEqual(decoded, segment)
        XCTAssertEqual(decoded.translationFailures.count, TranslationAcceptance.Rejection.allCases.count)
        XCTAssertTrue(decoded.translationFailures.allSatisfy { $0.count == 2 })
        XCTAssertNil(decoded.translationError)
        let future = Data(#"{"reason":"translationRejected","count":2,"rejection":"future-private-text"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(TranscriptSegment.TranslationFailure.self, from: future).rejection)
        let malformed = Data(#"{"reason":"translationRejected","count":2,"rejection":{"private":"text"}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(TranscriptSegment.TranslationFailure.self, from: malformed).rejection)
        let legacy = Data(#"{"reason":"translationRejected","count":2}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(TranscriptSegment.TranslationFailure.self, from: legacy).rejection)
        let unrelated = TranscriptSegment.TranslationFailure(reason: .processExited, count: 1, rejection: .modelReply)
        XCTAssertNil(unrelated.rejection)
    }

    func testRefusalsAreModelRepliesButQuotedInabilityRemainsLectureContent() throws {
        let refused = [
            "抱歉，我无法翻译包含不适当内容的信息。如果您有其他问题或需要帮助，请随时告诉我。",
            "抱歉，我无法提供该内容的翻译。",
            "我无法提供涉及暴力、仇恨或不当内容的信息。我的职责是提供安全、有益的帮助。",
            "I cannot translate offensive content."
        ]
        for output in refused {
            XCTAssertEqual(TranslationAcceptance.rejection(candidate: output, source: "Fuck your mother."), .modelReply)
            XCTAssertThrowsError(try TranslationAcceptance.validatedCaption(output, source: "Fuck your mother.")) { error in
                XCTAssertEqual((error as? QwenRuntimeError)?.translationRejection, .modelReply)
            }
        }
        for pair in [
            ("The chatbot says, 'I cannot translate offensive content.'", "聊天机器人说：‘我无法翻译冒犯性内容。’"),
            ("Sorry, I cannot provide a translation of this inscription.", "抱歉，我无法提供这段铭文的翻译。"),
            ("I cannot solve this equation.", "我无法解出这个方程。"),
            ("In the novel, he shouts, 'Fuck your mother.'", "在小说中，他喊道：‘去你妈的。’")
        ] {
            XCTAssertNil(TranslationAcceptance.rejection(candidate: pair.1, source: pair.0))
            XCTAssertEqual(try TranslationAcceptance.validatedCaption(pair.1, source: pair.0), pair.1)
        }
        XCTAssertThrowsError(try TranslationAcceptance.validatedCaption(String(repeating: "扩写", count: 30), source: "Hi.")) { error in
            XCTAssertEqual((error as? QwenRuntimeError)?.translationRejection, .disproportionateLength)
        }
    }

    func testTranslationLectureContentIsNeverARefusal() async throws {
        let pairs = [
            ("I cannot accurately translate this poem.", "我无法准确翻译这首诗。"),
            ("I won't go through every step of translation.", "我不会详细讲解翻译的每一个步骤。"),
            ("I can't cover transcription and translation in one lecture.", "我无法在一节课里讲完转录和翻译。"),
            ("I'm unable to translate it literally.", "我无法逐字翻译它。"),
            ("I can't be sure, but the translation of this word is roughly freedom.", "我无法确定，但这个词的翻译大致是自由。"),
            ("I'm not going to ask you to translate this on the exam.", "我不会让你们在考试中翻译这个。"),
            ("I cannot explain mRNA translation without discussing ribosomes.", "我无法在不讨论核糖体的情况下解释 mRNA 翻译。"),
            ("I'm sorry, I can't translate this idiom literally.", "抱歉，我没法直译这个习语。"),
            ("Translation stops when the ribosome reaches a stop codon.", "核糖体到达终止密码子时，翻译停止。"),
            ("Sorry, I cannot help with this request.", "对不起，我不能协助处理这类请求。"),
            ("I'm unable to assist with this request.", "我无法协助处理这类请求。"),
            ("I won't help with this request.", "我不会帮助处理这类请求。"),
            ("I cannot give you a Chinese version of this sentence.", "我无法提供这句话的译文。"),
            ("Sorry, I can't put this sentence into Chinese.", "抱歉，我无法翻译这句话。"),
            ("I won't render this sentence in Chinese.", "我不会翻译这句话。"),
            ("I cannot help you with this request.", "我不能协助处理这类请求。"),
            ("Sorry, I'm not able to assist with this request.", "抱歉，我无法协助处理这类请求。"),
            ("I failed to produce a Mandarin rendition of the line.", "我无法提供这句话的译文。"),
            ("Sorry, Alice missed 3 lectures.", "抱歉，Alice 错过了 3 节课。"),
            ("Alice scored 42 points.", "抱歉，无法翻译该内容。Alice 得了 42 分。"),
            ("Alice scored 42 points.", "对不起，我无法提供 Alice 的 42 分的翻译。")
        ]
        for (source, output) in pairs {
            XCTAssertFalse(TranslationAcceptance.isModelReply(output, source: source), source)
            XCTAssertNil(TranslationAcceptance.rejection(candidate: output, source: source), source)
            XCTAssertEqual(try TranslationAcceptance.validatedCaption(output, source: source), output)
            var requests = 0
            var deps = CaptionTranslationDependencies.unavailable
            deps.translate = { _, _, _, _, _ in requests += 1; return output }
            let (model, _) = try fixture(deps)
            model.receiveCaptionForTesting(source, start: 0, end: 1)
            await model.translationTaskForTesting?.value
            XCTAssertEqual(requests, 1, source)
            XCTAssertTrue(model.segments[0].hasUsableTranslation, source)
        }
    }

    func testWholeRefusalVariantsAndSourceContentExceptions() throws {
        for output in [
            "抱歉，无法翻译该内容。", "抱歉，此内容包含不当语言，无法提供翻译。",
            "对不起，我不便翻译这句话。", "很抱歉，我不能协助处理这类请求。",
            "我拒绝翻译这句话。", "抱歉，我无法提供该内容的翻译。",
            "抱歉。无法翻译该内容。", "抱歉，我无法为您提供该内容的翻译。",
            "很抱歉，但我不能翻译这句话。", "抱歉，我无法提供该内容的翻译。请提供其他需要翻译的内容。"
        ] {
            XCTAssertEqual(TranslationAcceptance.rejection(candidate: output, source: "Fuck your mother."), .modelReply, output)
            XCTAssertFalse(TranslationAcceptance.isModelReply(output, source: "We are discussing translation."))
        }
        for output in ["我不能翻译这首诗。", "我无法翻译 mRNA。", "抱歉，我不能提供第 42 题的翻译。",
                       "抱歉，我不能翻译该内容，Alice 得了 42 分。"] {
            XCTAssertFalse(TranslationAcceptance.isModelReply(output, source: "Alice scored 42 points."), output)
        }
    }

    func testInitialFallbackReusesExactPreviewOrMakesOneRequestOrRecordsFailure() async throws {
        for scenario in ["cached", "request", "failure", "wrong-source", "echo"] {
            var requests: [String] = []
            var deps = CaptionTranslationDependencies.unavailable
            deps.translate = { _, _, _, _, _ in throw QwenRuntimeError.translationRejected("synthetic", rejection: .sourceEcho) }
            deps.initialTranslation = { text in
                requests.append(text)
                if scenario == "failure" { throw QwenRuntimeError.runtimeUnavailable }
                return scenario == "echo" ? text : "房间很冷。"
            }
            let (model, _) = try fixture(deps)
            if scenario == "cached" { model.rememberInitialTranslation(source: source, translated: "房间很冷。") }
            if scenario == "wrong-source" { model.rememberInitialTranslation(source: "The room is warm.", translated: "房间很暖。") }
            model.receiveCaptionForTesting(source, start: 0, end: 1)
            await model.translationTaskForTesting?.value
            await model.waitForInitialTranslations()
            let segment = model.segments[0]
            XCTAssertEqual(requests, scenario == "cached" ? [] : [source], scenario)
            XCTAssertEqual(segment.translationState, .failed)
            XCTAssertEqual(segment.chinese, "")
            XCTAssertFalse(segment.hasUsableTranslation)
            var gate = CaptionNoteGate()
            let admission = gate.evaluate(.init(captions: [.init(id: segment.id, revision: segment.inputRevision,
                start: segment.startTime, end: segment.endTime, english: segment.english,
                chinese: segment.chinese, usable: segment.hasUsableTranslation)], producerDrained: true), now: 0)
            XCTAssertTrue(admission.eligible.isEmpty, "Display-only initial captions must not enter note evidence")
            XCTAssertEqual(segment.translationFailures, [.init(reason: .translationRejected, count: 2, rejection: .sourceEcho)])
            let display = ["failure", "echo"].contains(scenario) ? "（模型未翻译此句，可对照英文）" : "初译 · 房间很冷。"
            XCTAssertEqual(segment.displayChinese, display, scenario)
            XCTAssertEqual(SessionExporter.targetLine(segment), display)
            XCTAssertTrue(SessionExporter.srtCue(segment, index: 0).contains(display))
            XCTAssertEqual(CaptionPresentation.translationText(segment, outputLanguage: .simplifiedChinese), display)
            XCTAssertEqual(try JSONDecoder().decode(TranscriptSegment.self, from: encode(segment)), segment)
            XCTAssertNil(segment.withoutTranslationFailures.initialTranslationFallback)
            XCTAssertFalse(LearningSourceUnit.make([segment]).contains { $0.text.contains("房间很冷") })
            if segment.initialTranslationDisplay != nil {
                XCTAssertEqual(try SessionExporter.renderedTargetLine(segment, outputLanguage: .traditionalChineseTaiwan), "初譯 · 房間很冷。")
                let presentation = model.floatingSubtitlePresentation(mode: .translationOnly)
                XCTAssertEqual(presentation.translation?.isPreview, true)
                XCTAssertTrue(model.previewChineseDisplay.contains("初译"))
            }
        }
    }

    func testClosedRefusalSetAllowsSourceCounterpartsAndUnknownResponses() throws {
        for (source, output, language) in [
            ("No puedo traducir esta frase.", "我无法翻译这句话。", "es"),
            ("Je ne peux pas traduire cette phrase.", "我无法翻译这句话。", "fr"),
            ("I cannot help you with this request.", "我不能协助处理这类请求。", "en"),
            ("Please provide information about violent language.", "我无法提供涉及暴力、仇恨或不当内容的信息。我的职责是提供安全、有益的帮助。", "en")
        ] {
            XCTAssertFalse(TranslationAcceptance.isModelReply(output, source: source), source)
            XCTAssertNil(TranslationAcceptance.rejection(candidate: output, source: source, sourceLanguage: language), source)
            // The long information example intentionally still has its old length limit.
            if !source.contains("violent") {
                XCTAssertEqual(try TranslationAcceptance.validatedCaption(output, source: source, sourceLanguage: language), output)
            }
        }
        for output in ["对不起，该句不便处理。", "我不能翻译这首诗。", "我无法处理这个任务。",
                       "抱歉，我无法提供该内容的翻译。Alice 得了 42 分。",
                       "抱歉，我无法提供该内容的翻译。请联系老师。"] {
            XCTAssertFalse(TranslationAcceptance.isModelReply(output, source: "Fuck your mother."), output)
        }
        XCTAssertEqual(TranslationAcceptance.rejection(candidate: " 抱歉 : 我无法为您提供该内容的翻译 ! ", source: "Fuck your mother."), .modelReply)
    }

    func testBlockedInitialTranslationDoesNotOccupyFormalCaptionQueue() async throws {
        let apple = Item7Gate(), deadline = Item7Gate()
        defer { apple.release(); deadline.release() }
        var calls = 0
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { text, _, _, _, _ in
            if text == "The room is warm." { return "房间很暖。" }
            throw QwenRuntimeError.translationRejected("synthetic", rejection: .sourceEcho)
        }
        deps.initialTranslation = { _ in calls += 1; try await apple.wait(); return "房间很冷。" }
        deps.initialTranslationDeadline = { try await deadline.wait() }
        let (model, _) = try fixture(deps)
        model.receiveCaptionForTesting(source, start: 0, end: 1)
        model.receiveCaptionForTesting("The room is warm.", start: 10, end: 11)
        try await eventually { apple.entered && model.segments.count == 2 && model.segments[1].hasUsableTranslation }
        await model.translationTaskForTesting?.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.segments[1].chinese, "房间很暖。")
        XCTAssertEqual(model.segments[0].displayChinese, "（模型未翻译此句，可对照英文）")
        apple.release()
        await model.waitForInitialTranslations()
        XCTAssertEqual(model.segments[0].displayChinese, "初译 · 房间很冷。")
        XCTAssertEqual(model.segments[1].chinese, "房间很暖。")
    }

    func testInitialTimeoutDoesNotJoinAnUncooperativeProviderOrPublishLateText() async throws {
        let apple = Item7Gate(), deadline = Item7Gate()
        defer { apple.release(); deadline.release() }
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { _, _, _, _, _ in throw QwenRuntimeError.translationRejected("synthetic", rejection: .sourceEcho) }
        deps.initialTranslation = { _ in try await apple.wait(); return "房间很冷。" }
        deps.initialTranslationDeadline = { try await deadline.wait() }
        let (model, _) = try fixture(deps)
        model.receiveCaptionForTesting(source, start: 0, end: 1)
        try await eventually { apple.entered && deadline.entered }
        await model.translationTaskForTesting?.value
        deadline.release()
        var drained = false
        let drain = Task { await model.waitForInitialTranslations(); drained = true }
        try await eventually { drained }
        await drain.value
        XCTAssertEqual(model.segments[0].initialTranslationFallback?.targetCode, "zh-Hans")
        XCTAssertNil(model.segments[0].initialTranslationFallback?.text)
        apple.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.segments[0].displayChinese, "（模型未翻译此句，可对照英文）")
        XCTAssertEqual(model.segments[0].translationFailures, [.init(reason: .translationRejected, count: 2, rejection: .sourceEcho)])
    }

    func testInitialResultCannotPublishAfterRevisionOrSessionCancellation() async throws {
        for revision in [false, true] {
            let apple = Item7Gate(), deadline = Item7Gate()
            defer { apple.release(); deadline.release() }
            var deps = CaptionTranslationDependencies.unavailable
            deps.translate = { text, _, _, _, _ in
                if text == "The room is warm." { return "房间很暖。" }
                throw QwenRuntimeError.translationRejected("synthetic", rejection: .sourceEcho)
            }
            deps.initialTranslation = { _ in try await apple.wait(); return "房间很冷。" }
            deps.initialTranslationDeadline = { try await deadline.wait() }
            let (model, _) = try fixture(deps)
            model.receiveCaptionForTesting(source, start: 0, end: 1)
            try await eventually { apple.entered }
            await model.translationTaskForTesting?.value
            if revision {
                model.reviseCaptionForTesting(id: model.segments[0].id, english: "The room is warm.")
                model.drainCaptionQueueForTesting()
                await model.translationTaskForTesting?.value
            } else {
                await model.resetTranslationSessionForTesting()?.value
            }
            apple.release()
            await model.waitForInitialTranslations()
            for _ in 0..<20 { await Task.yield() }
            if revision {
                XCTAssertEqual(model.segments[0].chinese, "房间很暖。")
                XCTAssertNil(model.segments[0].initialTranslationFallback)
            } else { XCTAssertTrue(model.segments.isEmpty) }
        }
    }

    func testInitialFallbackDoesNotApplyToOtherFailuresOrTargetsAndClearsOnSuccess() throws {
        var segment = TranscriptSegment(startTime: 0, endTime: 1, english: source)
        segment.recordTranslationFailure(.translationRejected, rejection: .modelReply)
        segment.finishFailedTranslation()
        segment.recordInitialTranslationFallback(result, targetCode: "en")
        XCTAssertNil(segment.initialTranslationFallback)
        segment.recordInitialTranslationFallback(result, targetCode: "zh-Hans")
        XCTAssertEqual(SessionExporter.targetLine(segment, target: .english), source)
        XCTAssertEqual(SessionExporter.targetLine(segment, target: .spanish), ClassroomFixedText.failedAgainstSource.text(targetCode: "es"))
        for target in [CaptionTranslationTarget.english, .spanish, .french] {
            XCTAssertEqual(CaptionTranslationAttempt.recovery(for: QwenRuntimeError.translationRejected("test", rejection: .modelReply), target: target), .repairContent)
            XCTAssertFalse(CaptionTranslationAttempt.repairQuotedContent.promptSuffix(for: target).contains("including profanity"))
        }
        var plain = segment
        plain.recordTranslationFailure(.processExited)
        plain.finishFailedTranslation()
        XCTAssertNil(plain.initialTranslationDisplay)
        XCTAssertTrue(segment.sameContent(as: segment.withoutTranslationFailures))
        segment.completeTranslation(result)
        XCTAssertNil(segment.initialTranslationFallback)
        XCTAssertEqual(segment.displayChinese, result)
    }

    func testStructuredRepairFailuresKeepTheirActualSubreason() throws {
        let quote = try XCTUnwrap(TranslationAcceptance.quotedTranslationRepairPlan(
            candidate: #"把"The lamp is not on"译成法语。"#, source: #"Translate "The lamp is not on" into French."#))
        for (response, code) in [(#"{}"#, TranslationAcceptance.Rejection.jsonStructure),
                                 (#"{"q0":""}"#, .empty), (#"{"q0":"The lamp is not on"}"#, .nonChineseText),
                                 (#"{"q0":"灯亮着"}"#, .incompleteProse)] {
            XCTAssertThrowsError(try quote.applying(response)) { error in
                XCTAssertEqual((error as? QwenRuntimeError)?.translationRejection, code)
            }
        }
        let status = try XCTUnwrap(TranslationAcceptance.jsonStatusRepairPlan(
            candidate: #"她写了 {"state":"not stable"}。"#, source: #"She wrote {"state":"not stable"}."#))
        for (response, code) in [(#"{}"#, TranslationAcceptance.Rejection.jsonStructure),
                                 (#"{"0":""}"#, .empty), (#"{"0":"stable"}"#, .nonChineseText),
                                 (#"{"0":"稳定"}"#, .incompleteProse), (#"{"0":"不稳定 42"}"#, .jsonQuantity)] {
            XCTAssertThrowsError(try status.applying(response)) { error in
                XCTAssertEqual((error as? QwenRuntimeError)?.translationRejection, code)
            }
        }
    }

    func testQuotationRecoveryIsBoundedAndKeepsTheFailureCodeAfterSuccess() async throws {
        for code in [TranslationAcceptance.Rejection.modelReply, .sourceEcho, .disproportionateLength] {
            var attempts: [CaptionTranslationAttempt] = []
            var deps = CaptionTranslationDependencies.unavailable
            deps.translate = { [self] _, _, _, attempt, _ in
                attempts.append(attempt)
                if attempts.count == 1 { throw QwenRuntimeError.translationRejected("PRIVATE_ERROR_TEXT", rejection: code) }
                return result
            }
            let (model, _) = try fixture(deps)
            model.receiveCaptionForTesting(source, start: 0, end: 1)
            await model.translationTaskForTesting?.value
            XCTAssertEqual(attempts, [.standard, code == .disproportionateLength ? .repairContent : .repairQuotedContent])
            XCTAssertEqual(model.segments[0].chinese, result)
            XCTAssertFalse(model.segments[0].modelDidNotTranslate)
            XCTAssertEqual(model.segments[0].translationFailures, [.init(reason: .translationRejected, count: 1, rejection: code)])
            XCTAssertFalse(String(decoding: try encode(model.segments[0]), as: UTF8.self).contains("PRIVATE_ERROR_TEXT"))
        }
        XCTAssertTrue(CaptionTranslationAttempt.repairQuotedContent.promptSuffix.contains("including profanity and offensive language"))
        XCTAssertEqual(CaptionTranslationAttempt.standard.promptSuffix, "")
        XCTAssertEqual(CaptionTranslationAttempt.repairQuotedContent.outputTokenBudget(for: source), CaptionTranslationAttempt.repairContent.outputTokenBudget(for: source))
    }

    func testPersistentModelReplyGetsOneRetryAndTruthfulDisplays() async throws {
        var attempts: [CaptionTranslationAttempt] = []
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { _, _, _, attempt, _ in
            attempts.append(attempt)
            throw QwenRuntimeError.translationRejected("PRIVATE_MODEL_REPLY", rejection: .modelReply)
        }
        let (model, _) = try fixture(deps)
        model.receiveCaptionForTesting(source, start: 0, end: 1)
        await model.translationTaskForTesting?.value
        let segment = model.segments[0]
        XCTAssertEqual(attempts, [.standard, .repairQuotedContent])
        XCTAssertEqual(segment.translationFailures, [.init(reason: .translationRejected, count: 2, rejection: .modelReply)])
        XCTAssertEqual(segment.displayChinese, "（模型未翻译此句，可对照英文）")
        XCTAssertEqual(segment.translationFailureStatus, "模型未翻译此句")
        XCTAssertEqual(SessionExporter.targetLine(segment), segment.displayChinese)
        XCTAssertEqual(CaptionPresentation.translationText(segment, outputLanguage: .simplifiedChinese), segment.displayChinese)
        var later = segment
        later.recordTranslationFailure(.translationRejected, rejection: .disproportionateLength)
        later.finishFailedTranslation()
        XCTAssertFalse(later.modelDidNotTranslate)
        XCTAssertEqual(later.displayChinese, "（本段翻译未完成，可对照英文）")
        XCTAssertEqual(later.translationFailures.count, 2)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("item7-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture(_ dependencies: CaptionTranslationDependencies) throws -> (AppModel, URL) {
        let root = try directory()
        let suite = "LiveLingo-Item7-\(UUID())"
        let preferenceCleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        // Volatile overrides avoid changing a persistent preference domain.
        defaults.setVolatileDomain(["LiveLingo.modelMode": ModelMode.energySaver.rawValue], forName: UserDefaults.argumentDomain)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
                XCTFail("Failure recovery tests must not start a model or review")
                throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: dependencies, notes: .unavailable,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
        model.resetTranslationSessionForTesting()
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            try preferenceCleanup.remove()
        }
        return (model, root)
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        struct Timeout: Error {}
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Synthetic gate did not complete")
                throw Timeout()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func testCategoriesUseTypedErrorsAndNeverTheirMessages() {
        struct PrivateError: LocalizedError { var errorDescription: String? { "PRIVATE_ERROR_TEXT" } }
        let examples: [(Error, Reason)] = [
            (QwenRuntimeError.processExited, .processExited),
            (QwenRuntimeError.requestTimedOut, .requestTimedOut),
            (QwenRuntimeError.transcriptionTimedOut, .requestTimedOut),
            (QwenRuntimeError.outputLimitReached("PRIVATE_ERROR_TEXT"), .outputLimitReached),
            (QwenRuntimeError.translationRejected("PRIVATE_ERROR_TEXT"), .translationRejected),
            (QwenRuntimeError.runtimeUnavailable, .runtimeUnavailable),
            (QwenRuntimeError.modelUnavailable("PRIVATE_ERROR_TEXT"), .runtimeUnavailable),
            (QwenRuntimeError.serviceUnavailable, .runtimeUnavailable),
            (QwenRuntimeError.lmStudioUnavailable, .runtimeUnavailable),
            (QwenRuntimeError.invalidResponse, .invalidResponse),
            (QwenRuntimeError.generationInterrupted("PRIVATE_ERROR_TEXT"), .generationInterrupted),
            (QwenRuntimeError.requestFailed("PRIVATE_ERROR_TEXT"), .requestFailed),
            (CancellationError(), .dependencyCancelled), (URLError(.cancelled), .dependencyCancelled),
            (URLError(.timedOut), .requestTimedOut), (POSIXError(.EPIPE), .processExited),
            (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "PRIVATE_ERROR_TEXT")), .invalidResponse),
            (PrivateError(), .unknown)
        ]
        for (error, expected) in examples { XCTAssertEqual(Reason.category(for: error), expected) }
    }

    func testFailureTrailSurvivesSnapshotAndJournalWithoutDiagnosticText() throws {
        let root = try directory(), session = UUID()
        var caption = TranscriptSegment(startTime: 0, endTime: 1, english: source, sessionID: session)
        caption.beginTranslation()
        caption.recordTranslationFailure(.processExited)
        caption.recordTranslationFailure(.requestTimedOut)
        caption.recordTranslationFailure(.processExited)
        caption.finishFailedTranslation()
        let store = SessionStore(directory: root)
        let saved = try store.save(.init(sessionID: session, segments: [caption]))
        XCTAssertEqual(try store.load()?.segments, [caption])
        let bytes = try encode(caption)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["translationError"])
        XCTAssertEqual(object["chinese"] as? String, "")
        let records = try XCTUnwrap(object["translationFailures"] as? [[String: Any]])
        XCTAssertEqual(records.count, 2)
        for record in records {
            XCTAssertEqual(Set(record.keys), ["reason", "count"])
            XCTAssertNotNil(Reason(rawValue: try XCTUnwrap(record["reason"] as? String)))
            XCTAssertTrue((record["count"] as? Int ?? 0) > 0)
        }
        caption.beginTranslation()
        caption.completeTranslation(result)
        _ = try store.append(.upsertSegment(caption), expectedRevision: saved.storageRevision)
        XCTAssertEqual(try store.load()?.segments, [caption])
        XCTAssertEqual(caption.translationFailures, [.init(reason: .requestTimedOut, count: 1), .init(reason: .processExited, count: 2)])
    }

    func testEveryNewReasonIsReadableByExact020SegmentDecoder() throws {
        for reason in Reason.allCases {
            var caption = TranscriptSegment(startTime: 0, endTime: 1, english: source)
            caption.recordTranslationFailure(reason)
            caption.finishFailedTranslation()
            let bytes = try encode(caption)
            let old = try JSONDecoder().decode(Item7Legacy020.TranscriptSegment.self, from: bytes)
            XCTAssertEqual(old.translationState, .failed)
            XCTAssertEqual(old.english, source)
            XCTAssertNil(old.translationError)
            XCTAssertEqual(old.chinese, "")
            XCTAssertEqual(try JSONDecoder().decode(TranscriptSegment.self, from: bytes), caption)
            // An old build drops new fields; its revisions can still be compared.
            let rewritten = try JSONDecoder().decode(TranscriptSegment.self, from: encode(old))
            XCTAssertTrue(caption.sameContent(as: rewritten))
            caption.completeTranslation(result)
            XCTAssertEqual(try JSONDecoder().decode(Item7Legacy020.TranscriptSegment.self,
                from: encode(caption)).translationState, .completed)
        }
    }

    func testFutureReasonsMergeIntoUnknownAndInvalidCountsDegrade() throws {
        let caption = TranscriptSegment(startTime: 0, endTime: 1, english: source)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(caption)) as? [String: Any])
        object["translationFailures"] = [["reason": "FUTURE_PRIVATE_REASON", "count": 2],
                                          ["reason": "FUTURE_SECOND_REASON", "count": 3]]
        var decoded = try JSONDecoder().decode(TranscriptSegment.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.translationFailures, [.init(reason: .unknown, count: 5)])
        XCTAssertFalse(String(decoding: try encode(decoded), as: UTF8.self).contains("FUTURE_"))
        object["translationFailures"] = [["reason": "unknown", "count": Int.max]]
        decoded = try JSONDecoder().decode(TranscriptSegment.self, from: JSONSerialization.data(withJSONObject: object))
        decoded.recordTranslationFailure(.unknown)
        XCTAssertEqual(decoded.translationFailures.first?.count, Int.max)
        for invalid in [0, -1, true, "PRIVATE", 1.5] as [Any] {
            object["translationFailures"] = [["reason": "unknown", "count": invalid]]
            let degraded = try JSONDecoder().decode(TranscriptSegment.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertTrue(degraded.translationFailures.isEmpty)
            XCTAssertEqual(degraded.english, source)
        }
    }

    func testNormalEnglishEncodingMatches020ByteForByte() throws {
        let id = UUID(), session = UUID()
        var caption = TranscriptSegment(id: id, startTime: 0, endTime: 1, english: source, sessionID: session)
        var old = Item7Legacy020.TranscriptSegment(id: id, startTime: 0, endTime: 1, english: source, sessionID: session)
        XCTAssertEqual(try encode(caption), try encode(old))
        caption.beginTranslation(); old.beginTranslation()
        XCTAssertEqual(try encode(caption), try encode(old))
        caption.completeTranslation(result); old.completeTranslation(result)
        XCTAssertEqual(try encode(caption), try encode(old))
    }

    func testSuccessfulEnglishQueueUsesOneUnchangedRequestAndNoRecovery() async throws {
        var calls = 0
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { [self] text, _, hints, attempt, update in
            calls += 1
            XCTAssertEqual(text, source); XCTAssertTrue(hints.isEmpty); XCTAssertEqual(attempt, .standard)
            await update?(result)
            return result
        }
        deps.retrySleep = { _ in XCTFail("A successful caption must not back off") }
        deps.prepareRetry = { _ in XCTFail("A successful caption must not retire a worker") }
        let (model, _) = try fixture(deps)
        model.receiveCaptionForTesting(source, start: 0, end: 1)
        await model.translationTaskForTesting?.value
        let caption = try XCTUnwrap(model.segments.first)
        let old = Item7Legacy020.TranscriptSegment(id: caption.id, startTime: 0, endTime: 1,
            english: source, chinese: result, sessionID: caption.sessionID)
        XCTAssertEqual(try encode(caption), try encode(old))
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(caption.translationFailures.isEmpty)
    }

    func testRuntimeFailureBacksOffBeforeOneRetryAndPreservesRecoveredReason() async throws {
        var order: [String] = []
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { [self] _, _, _, attempt, _ in
            order.append("request")
            XCTAssertEqual(attempt, .standard)
            if order.count == 1 { throw QwenRuntimeError.processExited }
            return result
        }
        deps.retrySleep = { delay in XCTAssertEqual(delay, 1); order.append("backoff") }
        deps.prepareRetry = { _ in order.append("retirement") }
        let (model, _) = try fixture(deps)
        model.receiveCaptionForTesting(source, start: 0, end: 1)
        await model.translationTaskForTesting?.value
        XCTAssertEqual(order, ["request", "backoff", "retirement", "request"])
        XCTAssertEqual(model.segments[0].translationFailures, [.init(reason: .processExited, count: 1)])
        XCTAssertTrue(model.segments[0].hasUsableTranslation)
        XCTAssertNil(model.segments[0].translationError)
    }

    func testRepeatedTimeoutGetsOnlyOneTailRescueAfterALaterSuccess() async throws {
        var calls = 0, sleeps = 0
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { [self] text, _, _, _, _ in
            calls += 1
            if text == source { throw QwenRuntimeError.requestTimedOut }
            return "钟响了。"
        }
        deps.retrySleep = { delay in XCTAssertEqual(delay, 1); sleeps += 1 }
        let (model, _) = try fixture(deps)
        model.receiveCaptionForTesting(source, start: 0, end: 1)
        model.receiveCaptionForTesting("A bell rings.", start: 4, end: 5)
        await model.translationTaskForTesting?.value
        XCTAssertEqual(calls, 4); XCTAssertEqual(sleeps, 1)
        XCTAssertEqual(model.segments[0].translationState, .failed)
        XCTAssertEqual(model.segments[0].translationFailures, [.init(reason: .requestTimedOut, count: 3)])
        XCTAssertTrue(model.segments[1].hasUsableTranslation)
        XCTAssertTrue(model.translationQueueForTesting.isEmpty)
        XCTAssertNil(model.translationTaskForTesting)
    }

    func testMissingRuntimeIsTerminalWithoutRepeatedRestarts() async throws {
        var calls = 0
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { _, _, _, _, _ in calls += 1; throw QwenRuntimeError.runtimeUnavailable }
        deps.retrySleep = { _ in XCTFail("Missing runtime cannot be fixed by waiting") }
        deps.prepareRetry = { _ in XCTFail("Missing runtime must not repeatedly restart") }
        let (model, _) = try fixture(deps)
        model.receiveCaptionForTesting(source, start: 0, end: 1)
        await model.translationTaskForTesting?.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.segments[0].translationFailures, [.init(reason: .runtimeUnavailable, count: 1)])
        XCTAssertEqual(model.segments[0].translationState, .failed)
    }

    func testDependencyCancellationDoesNotStrandTheRemainingQueue() async throws {
        var calls = 0
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { [self] _, _, _, _, _ in
            calls += 1
            if calls == 1 { throw CancellationError() }
            return result
        }
        let (model, _) = try fixture(deps)
        model.receiveCaptionForTesting(source, start: 0, end: 1)
        model.receiveCaptionForTesting(source, start: 4, end: 5)
        await model.translationTaskForTesting?.value
        XCTAssertEqual(calls, 3)
        XCTAssertTrue(model.segments[0].hasUsableTranslation)
        XCTAssertEqual(model.segments[0].translationFailures, [.init(reason: .dependencyCancelled, count: 1)])
        XCTAssertTrue(model.segments[1].hasUsableTranslation)
        XCTAssertTrue(model.translationQueueForTesting.isEmpty)
    }

    func testTrueCancellationReturnsTheOwnedCaptionToPending() async throws {
        let gate = Item7Gate()
        defer { gate.release() }
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { _, _, _, _, _ in try await gate.wait(); try Task.checkCancellation(); return "房间很冷。" }
        let (model, _) = try fixture(deps)
        model.receiveCaptionForTesting(source, start: 0, end: 1)
        try await eventually { gate.entered }
        let task = try XCTUnwrap(model.translationTaskForTesting)
        task.cancel(); gate.release()
        await task.value
        XCTAssertEqual(model.segments[0].translationState, .pending)
        XCTAssertEqual(model.translationQueueForTesting, [model.segments[0].id])
        XCTAssertTrue(model.segments[0].translationFailures.isEmpty)
        XCTAssertTrue(model.translationEnqueuedAtForTesting.isEmpty)
        XCTAssertFalse(model.hasCaptionBacklogForTesting)
        XCTAssertNil(model.translationTaskForTesting)
    }

    func testEarlierSuccessDoesNotAuthorizeTransportRescue() async throws {
        var requests: [String] = []
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { [self] text, _, _, _, _ in
            requests.append(text)
            if text == source { throw QwenRuntimeError.processExited }
            return "钟响了。"
        }
        deps.retrySleep = { _ in }
        let (model, _) = try fixture(deps)
        model.receiveCaptionForTesting("A bell rings.", start: 0, end: 1)
        model.receiveCaptionForTesting(source, start: 4, end: 5)
        await model.translationTaskForTesting?.value
        XCTAssertEqual(requests, ["A bell rings.", source, source])
        XCTAssertEqual(model.segments[1].translationState, .failed)
        XCTAssertEqual(model.segments[1].translationFailures, [.init(reason: .processExited, count: 2)])
        XCTAssertTrue(model.translationQueueForTesting.isEmpty)
    }

    private func assertSavedTailRescue(dependencyCancellation: Bool) async throws {
        var firstCalls = 0, laterCalls = 0
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { [self] text, _, _, attempt, _ in
            XCTAssertEqual(attempt, .standard)
            if text == source {
                firstCalls += 1
                if dependencyCancellation, firstCalls == 1 { throw CancellationError() }
                if !dependencyCancellation, firstCalls <= 2 { throw QwenRuntimeError.requestTimedOut }
                return result
            }
            laterCalls += 1
            return "钟响了。"
        }
        deps.retrySleep = { _ in }
        let (model, root) = try fixture(deps)
        var snapshot = SessionSnapshot(segments: [
            .init(startTime: 0, endTime: 1, english: source),
            .init(startTime: 4, endTime: 5, english: "A bell rings.")
        ])
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        _ = try SessionStore(directory: root).save(snapshot)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(root, allowAutomaticProcessing: false)
        model.resumeSavedProcessing()
        try await eventually { model.segments.allSatisfy(\.hasUsableTranslation) }
        await model.savedProcessingTaskForTesting?.value
        XCTAssertEqual(firstCalls, dependencyCancellation ? 2 : 3)
        XCTAssertEqual(laterCalls, 1)
        XCTAssertEqual(model.segments[0].translationFailures,
            [.init(reason: dependencyCancellation ? .dependencyCancelled : .requestTimedOut,
                   count: dependencyCancellation ? 1 : 2)])
        XCTAssertTrue(model.translationQueueForTesting.isEmpty)
        XCTAssertNil(model.translationTaskForTesting)
        XCTAssertEqual(try SessionStore(directory: root).load()?.segments, model.segments)
        let exported = try String(contentsOf: root.appendingPathComponent("bilingual.jsonl"), encoding: .utf8)
        XCTAssertTrue(exported.contains(result))
        XCTAssertTrue(exported.contains("钟响了。"))
    }

    func testStopDrainRescuesTwiceFailedTransportCaptionBeforeExport() async throws {
        try await assertSavedTailRescue(dependencyCancellation: false)
    }

    func testStopDrainRescuesDependencyCancelledCaptionBeforeExport() async throws {
        try await assertSavedTailRescue(dependencyCancellation: true)
    }

    func testExplicitResumeOfFinishedDrainStartsANewBoundedRecoveryRound() async throws {
        var firstCalls = 0, laterCalls = 0
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { [self] text, _, _, _, _ in
            if text == source {
                firstCalls += 1
                if firstCalls <= 4 { throw QwenRuntimeError.processExited }
                return result
            }
            laterCalls += 1
            return "钟响了。"
        }
        deps.retrySleep = { _ in }
        let (model, root) = try fixture(deps)
        var snapshot = SessionSnapshot(segments: [
            .init(startTime: 0, endTime: 1, english: source),
            .init(startTime: 4, endTime: 5, english: "A bell rings.")
        ])
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        _ = try SessionStore(directory: root).save(snapshot)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(root, allowAutomaticProcessing: false)
        model.resumeSavedProcessing()
        try await eventually { firstCalls == 3 && model.savedProcessingTaskForTesting == nil }
        XCTAssertFalse(model.savedProcessingIsPaused)
        XCTAssertEqual(model.segments[0].translationState, .failed)
        XCTAssertEqual(model.segments[0].translationFailures, [.init(reason: .processExited, count: 3)])
        // A user-requested new drain gets the usual first retry; the previous
        // round's tail-rescue set cannot suppress it or repeatedly reopen it.
        model.resumeSavedProcessing()
        try await eventually { model.segments.allSatisfy(\.hasUsableTranslation) }
        await model.savedProcessingTaskForTesting?.value
        XCTAssertEqual(firstCalls, 5)
        XCTAssertEqual(laterCalls, 1)
        XCTAssertEqual(model.segments[0].translationFailures, [.init(reason: .processExited, count: 4)])
        XCTAssertTrue(model.translationQueueForTesting.isEmpty)
    }

    func testTailRescueExcludesModelAndAcceptanceFailures() async throws {
        for rejected in [false, true] {
            var firstCalls = 0, laterCalls = 0
            var deps = CaptionTranslationDependencies.unavailable
            deps.translate = { [self] text, _, _, _, _ in
                if text == source {
                    firstCalls += 1
                    if rejected { throw QwenRuntimeError.translationRejected("PRIVATE_REJECTION") }
                    throw QwenRuntimeError.modelUnavailable("PRIVATE_MODEL")
                }
                laterCalls += 1
                return "钟响了。"
            }
            deps.retrySleep = { _ in XCTFail("Non-transport failures must not wait for recovery") }
            let (model, _) = try fixture(deps)
            model.receiveCaptionForTesting(source, start: 0, end: 1)
            model.receiveCaptionForTesting("A bell rings.", start: 4, end: 5)
            await model.translationTaskForTesting?.value
            XCTAssertEqual(firstCalls, rejected ? 2 : 1)
            XCTAssertEqual(laterCalls, 1)
            XCTAssertEqual(model.segments[0].translationState, .failed)
            XCTAssertEqual(model.segments[0].translationFailures,
                [.init(reason: rejected ? .translationRejected : .runtimeUnavailable, count: rejected ? 2 : 1)])
            XCTAssertTrue(model.segments[1].hasUsableTranslation)
            XCTAssertTrue(model.translationQueueForTesting.isEmpty)
        }
    }

    func testDeferredRepairDependencyCancellationKeepsCaptionsAndDrainsOnce() async throws {
        var repairs = 0
        var deps = CaptionTranslationDependencies.unavailable
        deps.repair = { _ in repairs += 1; throw CancellationError() }
        deps.translate = { [self] _, _, _, _, _ in return result }
        let (model, root) = try fixture(deps)
        var snapshot = SessionSnapshot()
        let previous = TranscriptSegment(startTime: 0, endTime: 1, english: "A bell rings.", chinese: "钟响了。")
        let current = TranscriptSegment(startTime: 1, endTime: 2, english: "The wind stops.", chinese: "风停了。")
        snapshot.segments = [previous, current]
        snapshot.processing.pendingCaptionRepairs = [.init(sessionID: snapshot.sessionID,
            previous: previous, current: current, context: [], normalizedCurrent: current.english, modelName: "synthetic")]
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        _ = try SessionStore(directory: root).save(snapshot)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(root, allowAutomaticProcessing: false)
        model.resumeSavedProcessing()
        try await eventually { repairs == 1 && model.savedProcessingTaskForTesting == nil }
        XCTAssertEqual(repairs, 1)
        XCTAssertEqual(model.segments, [previous, current])
        XCTAssertTrue(model.segments.allSatisfy { $0.translationFailures.isEmpty })
        XCTAssertNil(try SessionStore(directory: root).load()?.processing.pendingCaptionRepairs)
        XCTAssertTrue(model.translationQueueForTesting.isEmpty)
        XCTAssertNil(model.translationTaskForTesting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("bilingual.jsonl").path))
    }

    func testRoutineParkResumeAndReopenPreserveFrozenEnglishArchiveBytes() async throws {
        let gate = Item7Gate()
        defer { gate.release() }
        var calls = 0
        var observedEnqueueTimes: [TimeInterval] = []
        var observedModel: AppModel?
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { [self] _, _, _, attempt, _ in
            XCTAssertEqual(attempt, .standard)
            calls += 1
            if let model = observedModel, let id = model.segments.first?.id,
               let timestamp = model.translationEnqueuedAtForTesting[id] { observedEnqueueTimes.append(timestamp) }
            if calls == 1 { try await gate.wait(); try Task.checkCancellation() }
            return result
        }
        deps.retrySleep = { _ in XCTFail("Routine parking must not trigger backoff") }
        deps.prepareRetry = { _ in XCTFail("Routine parking must not recover a failed runtime") }
        let (model, root) = try fixture(deps)
        observedModel = model
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let session = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let original = TranscriptSegment(id: id, startTime: 0, endTime: 1, english: source, sessionID: session)
        var snapshot = SessionSnapshot(sessionID: session, segments: [original], createdAt: Date(timeIntervalSince1970: 0))
        snapshot.processing.phase = .paused
        snapshot.processing.paused = true
        _ = try SessionStore(directory: root).save(snapshot)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(root, allowAutomaticProcessing: false)
        model.resumeSavedProcessing()
        try await eventually { gate.entered }
        let initialEnqueue = try XCTUnwrap(model.translationEnqueuedAtForTesting[id])
        model.pauseSavedProcessing()
        try await eventually { model.savedProcessingIsPaused }
        gate.release()
        try await model.savedPauseTaskForTesting?.value
        await model.savedProcessingTaskForTesting?.value
        XCTAssertEqual(model.segments, [original])
        XCTAssertTrue(model.translationEnqueuedAtForTesting.isEmpty)
        XCTAssertFalse(model.hasCaptionBacklogForTesting)
        XCTAssertFalse(model.captionWorkPendingForTesting)
        XCTAssertEqual(model.translationQueueForTesting, [id])
        XCTAssertEqual(try SessionStore(directory: root).load()?.segments, [original])

        try await model.openSavedSession(root, allowAutomaticProcessing: false)
        XCTAssertEqual(model.segments, [original])
        model.resumeSavedProcessing()
        try await eventually { model.segments[0].hasUsableTranslation }
        await model.savedProcessingTaskForTesting?.value
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(model.segments[0].translationFailures.isEmpty)
        XCTAssertEqual(observedEnqueueTimes.count, 2)
        XCTAssertGreaterThan(try XCTUnwrap(observedEnqueueTimes.last), initialEnqueue)
        // Literals frozen from the e1e3b03 English segment/snapshot/event format.
        let captionBytes = #"{"chinese":"房间很冷。","endTime":1,"english":"The room is cold.","id":"11111111-1111-1111-1111-111111111111","inputRevision":0,"sessionID":"22222222-2222-2222-2222-222222222222","startTime":0,"translationState":"completed"}"#
        XCTAssertEqual(try encode(model.segments[0]), Data(captionBytes.utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("bilingual.jsonl")), Data((captionBytes + "\n").utf8))
        let archive = SessionSnapshot(sessionID: session, segments: model.segments, createdAt: Date(timeIntervalSince1970: 0))
        let snapshotBytes = #"{"audioFiles":[],"audioRanges":[],"batches":[],"createdAt":0,"generation":0,"generationCheckpoints":[],"inputRevision":0,"lastJournalDigest":"0000000000000000000000000000000000000000000000000000000000000000","lastJournalSequence":0,"latestEvidenceIDs":[],"notebookLastOffered":{},"notebookRevision":0,"notebookSelectionRound":0,"processing":{"paused":false,"pendingBatchIDs":[],"pendingSegmentIDs":[],"phase":"idle","reviewPaused":true,"summaryPaused":false},"revisionHistory":[],"schemaVersion":1,"segments":["# + captionBytes + #"],"sessionID":"22222222-2222-2222-2222-222222222222","storageRevision":0,"updatedAt":0}"#
        XCTAssertEqual(try SessionArchiveCoding.encode(archive), Data(snapshotBytes.utf8))
        XCTAssertEqual(try SessionArchiveCoding.encode(SessionJournalEvent.upsertSegment(model.segments[0])),
            Data((#"{"upsertSegment":{"_0":"# + captionBytes + "}}").utf8))
    }

    func testRevisionDuringBackoffDoesNotRetryOrPublishTheObsoleteInput() async throws {
        let gate = Item7Gate()
        defer { gate.release() }
        var requests: [String] = []
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { [self] text, _, _, _, _ in
            requests.append(text)
            if text == source { throw QwenRuntimeError.processExited }
            return "钟响了。"
        }
        deps.retrySleep = { _ in try await gate.wait() }
        deps.prepareRetry = { _ in XCTFail("A superseded request must not touch the runtime") }
        let (model, _) = try fixture(deps)
        model.receiveCaptionForTesting(source, start: 0, end: 1)
        try await eventually { gate.entered }
        model.reviseCaptionForTesting(id: model.segments[0].id, english: "A bell rings.")
        gate.release()
        await model.translationTaskForTesting?.value
        XCTAssertEqual(requests, [source, "A bell rings."])
        XCTAssertEqual(model.segments[0].chinese, "钟响了。")
        XCTAssertTrue(model.segments[0].translationFailures.isEmpty)
    }

    func testReopenedInFlightSnapshotKeepsOnlyPreviouslyObservedFailures() async throws {
        var calls = 0
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { [self] _, _, _, _, _ in calls += 1; return result }
        let (model, root) = try fixture(deps)
        var caption = TranscriptSegment(startTime: 0, endTime: 1, english: source)
        caption.beginTranslation()
        caption.recordTranslationFailure(.processExited)
        var snapshot = SessionSnapshot(segments: [caption])
        snapshot.processing.phase = .paused; snapshot.processing.paused = true
        _ = try SessionStore(directory: root).save(snapshot)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(root, allowAutomaticProcessing: false)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.segments[0].translationState, .pending)
        XCTAssertEqual(model.segments[0].translationFailures,
            [.init(reason: .processExited, count: 1)])
        model.resumeSavedProcessing()
        try await eventually { model.segments[0].hasUsableTranslation }
        await model.savedProcessingTaskForTesting?.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try SessionStore(directory: root).load()?.segments, model.segments)
    }

    func testReopenedInFlightWithoutObservedFailureOnlyReturnsToPending() async throws {
        var calls = 0
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { [self] _, _, _, _, _ in calls += 1; return result }
        let (model, root) = try fixture(deps)
        var caption = TranscriptSegment(startTime: 0, endTime: 1, english: source)
        caption.beginTranslation()
        var snapshot = SessionSnapshot(segments: [caption])
        snapshot.processing.phase = .paused
        snapshot.processing.paused = true
        _ = try SessionStore(directory: root).save(snapshot)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(root, allowAutomaticProcessing: false)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.segments[0].translationState, .pending)
        XCTAssertTrue(model.segments[0].translationFailures.isEmpty)
        model.resumeSavedProcessing()
        try await eventually { model.segments[0].hasUsableTranslation }
        await model.savedProcessingTaskForTesting?.value
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(model.segments[0].translationFailures.isEmpty)
        var old = Item7Legacy020.TranscriptSegment(id: caption.id, startTime: 0, endTime: 1, english: source)
        old.completeTranslation(result)
        XCTAssertEqual(try encode(model.segments[0]), try encode(old))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("bilingual.jsonl")),
                       try encode(old) + Data("\n".utf8))
    }

    func testPauseDuringBackoffPersistsFailureAndResumesWithoutAnInfiniteRetry() async throws {
        let gate = Item7Gate()
        defer { gate.release() }
        var calls = 0
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { [self] _, _, _, _, _ in
            calls += 1
            if calls == 1 { throw QwenRuntimeError.requestTimedOut }
            return result
        }
        deps.retrySleep = { _ in try await gate.wait(); try Task.checkCancellation() }
        let (model, root) = try fixture(deps)
        var snapshot = SessionSnapshot(segments: [.init(startTime: 0, endTime: 1, english: source)])
        snapshot.processing.phase = .paused; snapshot.processing.paused = true
        _ = try SessionStore(directory: root).save(snapshot)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(root, allowAutomaticProcessing: false)
        model.resumeSavedProcessing()
        try await eventually { gate.entered }
        let persisted = try XCTUnwrap(SessionStore(directory: root).load())
        // The saver is asynchronous; wait for the first failure to reach disk.
        try await eventually { (try? SessionStore(directory: root).load())?.segments[0].translationFailures.count == 1 }
        XCTAssertEqual(persisted.sessionID, snapshot.sessionID)
        model.pauseSavedProcessing()
        try await eventually { model.savedProcessingIsPaused }
        gate.release()
        try await model.savedPauseTaskForTesting?.value
        await model.savedProcessingTaskForTesting?.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.segments[0].translationState, .pending)
        XCTAssertEqual(try SessionStore(directory: root).load()?.segments[0].translationFailures,
            [.init(reason: .requestTimedOut, count: 1)])
        model.resumeSavedProcessing()
        try await eventually { model.segments[0].hasUsableTranslation }
        await model.savedProcessingTaskForTesting?.value
        XCTAssertEqual(calls, 2)
        XCTAssertNil(model.archiveError)
    }

    private func assertOwnedWorkerRecovery(mode: String, reason: Reason) async throws {
        let root = try directory()
        let script = root.appendingPathComponent("fake-caption-worker.pl")
        try Self.fakeWorker.write(to: script, atomically: true, encoding: .utf8)
        let runtime = MLXRuntime(testConfiguration: .init(python: URL(fileURLWithPath: "/usr/bin/perl"),
            script: script, models: root, state: root, controlTimeout: 0.05))
        let modelName = "qwen3.5-4b-mlx"
        addTeardownBlock { await runtime.unload(modelName) }
        var requests = 0, sleeps = 0
        var deps = CaptionTranslationDependencies.unavailable
        deps.translate = { text, _, _, _, _ in
            requests += 1
            return try await runtime.generate(model: modelName, prompt: mode, input: text, prefix: "",
                thinking: false, purpose: "text", finalBudget: 64, timeout: 0.05,
                inactivityTimeout: 0.05, onUpdate: { _ in })
        }
        deps.retrySleep = { delay in XCTAssertEqual(delay, 1); sleeps += 1 }
        deps.prepareRetry = { _ in try await runtime.finishRetirementBeforeRetry(modelName) }
        let (model, _) = try fixture(deps)
        model.receiveCaptionForTesting(source, start: 0, end: 1)
        await model.translationTaskForTesting?.value
        XCTAssertEqual(requests, 2); XCTAssertEqual(sleeps, 1)
        XCTAssertTrue(model.segments[0].hasUsableTranslation)
        XCTAssertEqual(model.segments[0].translationFailures, [.init(reason: reason, count: 1)])
        XCTAssertNil(model.segments[0].translationError)
        let boots = try String(contentsOf: root.appendingPathComponent("boots"), encoding: .utf8)
        XCTAssertEqual(boots.split(separator: "\n").count, 2, "Exactly one replacement worker is allowed")
        await runtime.unload(modelName)
        let remaining = await runtime.resourceStates()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testOwnedCaptionProcessExitIsClassifiedAndReplacedBeforeRetry() async throws {
        try await assertOwnedWorkerRecovery(mode: "exit", reason: .processExited)
    }

    func testOwnedCaptionTimeoutReclaimsTheUnresponsiveWorkerAndRetriesOnce() async throws {
        try await assertOwnedWorkerRecovery(mode: "timeout", reason: .requestTimedOut)
    }

    // Real pipes/owned child processes, no MLX imports, network, service or GPU.
    private static let fakeWorker = #"""
    use strict;
    use warnings;
    use JSON::PP;
    $| = 1;
    my $state;
    for (my $i = 0; $i < @ARGV; $i++) { $state = $ARGV[$i + 1] if $ARGV[$i] eq '--state-directory'; }
    open(my $boots, '>>', "$state/boots") or die;
    print $boots "boot\n";
    close $boots;
    sub emit { my ($event, %fields) = @_; print encode_json({event => $event, %fields}), "\n"; }
    emit('ready', version => 2);
    my $stalled = 0;
    while (my $line = <STDIN>) {
        my $command = decode_json($line);
        my $op = $command->{op};
        if ($op eq 'generate') {
            if (!-e "$state/failed-once") {
                open(my $flag, '>', "$state/failed-once") or die;
                close $flag;
                exit 3 if $command->{prompt} eq 'exit';
                if ($command->{prompt} eq 'retirement') {
                    $SIG{TERM} = 'IGNORE';
                    close STDOUT;
                    select(undef, undef, undef, 10);
                    exit 0;
                }
                $stalled = 1;
                next;
            }
            emit('done', id => $command->{id}, text => "\x{623F}\x{95F4}\x{5F88}\x{51B7}\x{3002}");
        } elsif ($op eq 'cancel') {
            next if $stalled;
            emit('cancel', id => $command->{id}, controlID => $command->{controlID}, state => 'released');
        } elsif ($op eq 'ack') {
            emit('ack', id => $command->{id}, controlID => $command->{controlID}, state => 'released');
        } elsif ($op eq 'shutdown') {
            emit('shutdown', controlID => $command->{controlID}, state => 'released');
            exit 0;
        }
    }
    """#
}

// Exact v0.2.0 segment declarations, namespaced without changing the decoder.
private enum Item7Legacy020 {
struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    enum TranslationState: String, Codable, Sendable {
        case pending, translating, completed, failed
    }

    let id: UUID
    let sessionID: UUID?
    var inputRevision: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let english: String
    var chinese: String {
        didSet { reconcileLegacyTranslation() }
    }
    private(set) var translationState: TranslationState
    private(set) var translationError: String?

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        english: String,
        chinese: String = "",
        sessionID: UUID? = nil,
        inputRevision: Int = 0
    ) {
        self.id = id
        self.sessionID = sessionID
        self.inputRevision = max(0, inputRevision)
        self.startTime = max(0, startTime)
        self.endTime = max(startTime, endTime)
        self.english = english
        self.chinese = chinese
        self.translationState = .pending
        self.translationError = nil
        reconcileLegacyTranslation()
    }

    var hasUsableTranslation: Bool {
        translationState == .completed && !chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One rendering rule for saved transcripts, the classroom and all exports.
    /// The floating window continues to use its separate initial translation.
    var displayChinese: String {
        switch translationState {
        case .completed: return chinese
        case .failed: return "（本段翻译未完成，可对照英文）"
        case .pending, .translating: return "（本段暂无译文）"
        }
    }

    mutating func beginTranslation() {
        translationState = .translating
        translationError = nil
    }

    mutating func completeTranslation(_ text: String) {
        chinese = text
    }

    mutating func failTranslation(_ error: String) {
        chinese = ""
        translationState = .failed
        translationError = error
    }

    mutating func deferTranslation() {
        guard translationState == .translating else { return }
        translationState = .pending
    }

    // This is the only compatibility boundary that interprets the old marker.
    // New failures store diagnostics separately from translated content.
    private mutating func reconcileLegacyTranslation() {
        let text = chinese.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[翻译失败：") {
            translationState = .failed
            translationError = String(text.dropFirst("[翻译失败：".count).dropLast(text.hasSuffix("]") ? 1 : 0))
        } else {
            translationState = text.isEmpty ? .pending : .completed
            translationError = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, inputRevision, startTime, endTime, english, chinese, translationState, translationError
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sessionID = try values.decodeIfPresent(UUID.self, forKey: .sessionID)
        inputRevision = try values.decodeIfPresent(Int.self, forKey: .inputRevision) ?? 0
        startTime = try values.decode(TimeInterval.self, forKey: .startTime)
        endTime = try values.decode(TimeInterval.self, forKey: .endTime)
        guard startTime.isFinite, endTime.isFinite, startTime >= 0, endTime >= startTime, inputRevision >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .startTime, in: values,
                                                   debugDescription: "Invalid transcript time range or revision")
        }
        english = try values.decode(String.self, forKey: .english)
        chinese = try values.decodeIfPresent(String.self, forKey: .chinese) ?? ""
        translationState = .pending
        translationError = nil
        reconcileLegacyTranslation()
        if let storedState = try values.decodeIfPresent(TranslationState.self, forKey: .translationState) {
            guard storedState != .completed || hasUsableTranslation else {
                throw DecodingError.dataCorruptedError(forKey: .translationState, in: values,
                                                       debugDescription: "Completed translation has no usable content")
            }
            translationState = storedState
            translationError = try values.decodeIfPresent(String.self, forKey: .translationError)
        }
    }
}

}
