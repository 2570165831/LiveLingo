import XCTest
import AVFoundation
@testable import LiveLingo

private actor AdjacentRequestProbe {
    enum Response: Sendable {
        case text(String), failure(QwenRuntimeError), cancelled
        case cancelThenText(String), cancelThenFailure(QwenRuntimeError)
        case held(CaptionIdentityGate<String>)
    }
    struct Request: Sendable {
        let input: String
        let prompt: String
        let budget: Int
    }
    private var responses: [Response]
    private(set) var requests: [Request] = []

    init(_ responses: [Response]) { self.responses = responses }

    func request(_ input: String, _ prompt: String, _ budget: Int) async throws -> String {
        requests.append(.init(input: input, prompt: prompt, budget: budget))
        guard !responses.isEmpty else { throw QwenRuntimeError.requestFailed("Unexpected extra generation") }
        switch responses.removeFirst() {
        case .text(let value): return value
        case .failure(let error): throw error
        case .held(let gate): return try await gate.wait()
        case .cancelled: throw CancellationError()
        case .cancelThenText(let value):
            withUnsafeCurrentTask { $0?.cancel() }
            return value
        case .cancelThenFailure(let error):
            withUnsafeCurrentTask { $0?.cancel() }
            throw error
        }
    }
}

private actor RepairOrderProbe {
    private(set) var inputs: [String] = []
    func request(_ input: String, _ prompt: String, _ budget: Int) throws -> String {
        inputs.append(input)
        if let data = input.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let target = json["target_translate_only"] as? String {
            return target.contains("absorbs") ? "系统吸收了热能。" : "它的温度随之升高。"
        }
        return input.contains("temperature") ? "温度随之升高。" : "容器慢慢膨胀。"
    }
}

private func captionSource(in input: String, mode: ModelMode) throws -> String {
    if mode == .energySaver { return input }
    XCTAssertEqual(mode, .highQuality)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: String])
    XCTAssertEqual(Set(object.keys), ["source_text_to_translate"])
    return try XCTUnwrap(object["source_text_to_translate"])
}

@MainActor
private final class CaptionIdentityGate<Value: Sendable> {
    var continuation: CheckedContinuation<Value, Error>?
    var entered = false

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation {
            continuation = $0
            entered = true
        }
    }

    func finish(_ result: Result<Value, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

@MainActor
final class CaptionIdentityTests: XCTestCase {
    private func eventually(within timeout: Duration = .seconds(5),
                            _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("等待测试任务到达指定阶段超时")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func makeModel(_ translation: CaptionTranslationDependencies,
                           notes: LearningGenerationDependencies? = nil,
                           scheduledNotes: Bool? = nil) throws -> AppModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingo-CaptionIdentity-\(UUID())", isDirectory: true)
        let suite = "LiveLingo-CaptionIdentity-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
                XCTFail("字幕生命周期测试不能发起复查")
                throw CancellationError()
            }
        addTeardownBlock {
            await queue.shutdownForTesting()
            UserDefaults.standard.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        let model = AppModel(reviewQueue: queue, translation: translation,
                             notes: notes, backgroundServices: false,
                             scheduledNotes: scheduledNotes, defaults: preferences)
        model.resetTranslationSessionForTesting()
        return model
    }

    func testCaptionQueueFormatsSpokenQuantitiesWithoutChangingOriginalEnglish() async throws {
        for (original, normalized, chinese) in [
            ("Meet at ten past two and add fifty parts per million.",
             "Meet at 2:10 and add 50 ppm.", "在 2:10 集合，并添加 50 ppm。"),
            ("Set the odds at ten to eight.", "Set the odds at 10:8.", "将赔率设为 10:8。"),
            ("The ratio is one to eight and a half.", "The ratio is 1:8.5.", "比例是 1:8.5。"),
            ("If the determinant is zero, the columns are not linearly independent.",
             "If the determinant is zero, the columns are linearly dependent.",
             "如果行列式为零，则列向量线性相关。"),
            ("The columns are not not linearly independent.",
             "The columns are linearly independent.", "列向量线性无关。")
        ] {
            var inputs: [String] = []
            let model = try makeModel(.init(translate: { input, _, _, _, _ in
                inputs.append(input)
                return chinese
            }, adjacent: { _, _, _, _, _, _, _, _, _ in
                XCTFail("An isolated first caption must not request adjacent repair")
                throw CancellationError()
            }))
            model.receiveCaptionForTesting(original, start: 0, end: 8)
            await model.translationTaskForTesting?.value
            XCTAssertEqual(inputs, [normalized],
                           "The real caption queue must apply formatting before generation, once")
            let caption = try XCTUnwrap(model.segments.first)
            XCTAssertEqual(model.segments.count, 1)
            XCTAssertEqual(caption.english, original, "The original transcript remains the evidence")
            XCTAssertEqual(caption.chinese, chinese)
            XCTAssertTrue(caption.hasUsableTranslation)
        }
    }

    func testCaptureFailuresRetryFinalNotesWithoutAnotherCaptionOrPowerPoll() async throws {
        for failure in ["合成麦克风恢复次数已达上限", "合成电脑进入休眠"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-CaptureNotes-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256_000))
            pcm.frameLength = pcm.frameCapacity
            pcm.floatChannelData![0].initialize(repeating: 0, count: Int(pcm.frameLength))
            let audio = try AVAudioFile(forWriting: root.appendingPathComponent("recording.wav"), settings: format.settings)
            try audio.write(from: pcm)
            var calls = 0
            let model = try makeModel(.unavailable, notes: .init(generate: { _, _, _, _ in
                calls += 1
                if calls == 1 { throw QwenRuntimeError.invalidResponse }
                return #"{"topic":"小车运动","points":[{"kind":"核心结论","text":"B 车全程保持每秒两米的速度。","sourceIDs":["en0s0","en1s0"]}]}"#
            }), scheduledNotes: true)
            let evidence = [
                TranscriptSegment(startTime: 0, endTime: 8, english: "Cart B moves at two metres per second.", chinese: "B 车的速度为每秒两米。"),
                TranscriptSegment(startTime: 8, endTime: 16, english: "Cart B keeps this speed for the whole journey.", chinese: "B 车全程保持该速度。")
            ]
            model.loadPresentationForTesting(phase: .recording, evidence: evidence)
            try await model.stopCaptureForTesting(directory: root, failure: failure)
            await model.savedProcessingTaskForTesting?.value
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(model.errorMessage?.contains("后面的内容不会再录") == true)
            try await eventually(within: .seconds(15)) { model.lectureSummary.contains("B 车全程保持每秒两米的速度。") }
            XCTAssertEqual(calls, 2)
            try await eventually {
                (try? SessionStore(directory: root).load()?.batches.count) == 1
            }
            let saved = try XCTUnwrap(SessionStore(directory: root).load())
            XCTAssertEqual(saved.processing.captureError, failure)
            XCTAssertEqual(Set(saved.batches.flatMap(\.ids)), Set(evidence.map(\.id)))
            XCTAssertEqual(saved.segments.map(\.english), evidence.map(\.english))
            model.resetTranslationSessionForTesting()
        }
    }

    func testAdjacentTargetKeepsAuxiliaryHintsSeparateFromTranscript() async throws {
        let hints: [AuxiliaryTranslationHint] = [.init(kind: .formula, value: "H2O"),
                                                .init(kind: .unit, value: "2 mL")]
        let source = "Add 2 mL H2O to sample A."
        var adjacentCalls = 0
        let model = try makeModel(.init(
            translate: { _, _, _, _, _ in "准备好样品。" },
            adjacent: { _, _, current, _, _, _, receivedHints, _, shouldDefer in
                adjacentCalls += 1
                XCTAssertEqual(current, source)
                XCTAssertEqual(receivedHints, [.init(kind: .unit, value: "2 mL")])
                XCTAssertFalse(current.contains("Primary ASR transcript"))
                XCTAssertFalse(current.contains("Auxiliary token hints"))
                return .init(previous: nil, current: "向样品 A 加入 2 mL H2O。",
                             previousRejection: nil, currentRejection: nil)
            }))
        model.receiveIdentifiedCaptionForTesting(.init(startTime: 0, endTime: 8,
                                                      english: "Prepare the sample."))
        await model.translationTaskForTesting?.value
        model.receiveIdentifiedCaptionForTesting(.init(startTime: 8, endTime: 16, english: source), hints: hints)
        await model.translationTaskForTesting?.value
        XCTAssertEqual(adjacentCalls, 1)
        XCTAssertEqual(model.segments.last?.english, source)
        XCTAssertEqual(model.segments.last?.chinese, "向样品 A 加入 2 mL H2O。")
    }

    func testMalformedFormulaOutputIsRejectedAndRetryMustRestoreEveryTerm() async throws {
        for retrySucceeds in [false, true] {
            var calls = 0
            let broken = "比较 ZnQCHEM0QXZ 和 ZXQCHEM1QXZ。"
            let model = try makeModel(.init(translate: { text, _, _, _, update in
                calls += 1
                XCTAssertEqual(text, "Compare ZXQCHEM0QXZ with ZXQCHEM1QXZ.")
                await update?(broken)
                return calls == 2 && retrySucceeds ? "比较 ZXQCHEM0QXZ 和 ZXQCHEM1QXZ。" : broken
            }, adjacent: { _, _, _, _, _, _, _, _, shouldDefer in throw CancellationError() }))
            let caption = TranscriptSegment(startTime: 0, endTime: 8,
                                            english: "Compare Na⁺ with Cl⁻.")
            model.receiveIdentifiedCaptionForTesting(caption)
            await model.translationTaskForTesting?.value
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(model.segments[0].english, caption.english)
            XCTAssertFalse(model.segments[0].chinese.contains("CHEM"))
            XCTAssertFalse(model.streamingChinese.contains("CHEM"))
            if retrySucceeds {
                XCTAssertEqual(model.segments[0].chinese, "比较 Na⁺ 和 Cl⁻。")
                XCTAssertEqual(model.segments[0].translationState, .completed)
            } else {
                XCTAssertFalse(model.segments[0].hasUsableTranslation)
            }
        }
    }

    func testNamedCaptionKeepsItsOriginalSpellingThroughCommit() async throws {
        var calls = 0
        let model = try makeModel(.init(translate: { text, _, _, _, update in
            calls += 1
            XCTAssertEqual(text, #"Call it "ZXQCHEM0QXZ"."#)
            let output = "称它为 ZXQCHEM0QXZ。"
            await update?(output)
            return output
        }, adjacent: { _, _, _, _, _, _, _, _, shouldDefer in throw CancellationError() }))
        let source = #"Call it "S N two"."#
        model.receiveCaptionForTesting(source, start: 0, end: 8)
        await model.translationTaskForTesting?.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.segments[0].english, source)
        XCTAssertEqual(model.segments[0].chinese, "称它为 S N two。")
        XCTAssertTrue(model.segments[0].hasUsableTranslation)
    }

    func testNamingOmissionUsesContentRecoveryBeforeCommit() async throws {
        var attempts: [CaptionTranslationAttempt] = []
        let model = try makeModel(.init(translate: { text, _, _, attempt, _ in
            attempts.append(attempt)
            XCTAssertEqual(text, #"Call it "ZXQCHEM0QXZ"."#)
            return attempts.count == 1 ? #""ZXQCHEM0QXZ"。"# : "称其为 ZXQCHEM0QXZ。"
        }, adjacent: { _, _, _, _, _, _, _, _, shouldDefer in throw CancellationError() }))
        model.receiveCaptionForTesting(#"Call it "N two"."#, start: 0, end: 8)
        await model.translationTaskForTesting?.value
        XCTAssertEqual(attempts, [.standard, .repairContent])
        XCTAssertEqual(model.segments[0].chinese, "称其为 N two。")
        XCTAssertTrue(model.segments[0].hasUsableTranslation)
    }

    func testRejectedLengthNeverBecomesACompletedCaptionAfterRetry() async throws {
        for firstIsRuntimeFailure in [false, true] {
            var calls = 0
            let model = try makeModel(.init(translate: { _, _, _, _, _ in
                calls += 1
                if calls == 1 && firstIsRuntimeFailure { throw QwenRuntimeError.invalidResponse }
                return String(repeating: "这是其他段落的内容。", count: 60)
            }, adjacent: { _, _, _, _, _, _, _, _, shouldDefer in throw CancellationError() }))
            let source = "The temperature increases when we add thermal energy."
            model.receiveCaptionForTesting(source, start: 0, end: 8)
            await model.translationTaskForTesting?.value
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(model.segments.first?.english, source)
            XCTAssertFalse(model.segments[0].hasUsableTranslation,
                           "A failed recovery must retain the English, not commit known implausible Chinese")
            XCTAssertTrue(model.segments[0].chinese.isEmpty)
        }
    }

    func testShortCaptionRunawayNeverCompletesAfterRecovery() async throws {
        for firstIsRuntimeFailure in [false, true] {
            var calls = 0
            let model = try makeModel(.init(translate: { _, _, _, _, _ in
                calls += 1
                if calls == 1 && firstIsRuntimeFailure { throw QwenRuntimeError.invalidResponse }
                return String(repeating: "这是别的段落的内容。", count: 8)
            }, adjacent: { _, _, _, _, _, _, _, _, shouldDefer in throw CancellationError() }))
            model.receiveCaptionForTesting("No net force.", start: 0, end: 8)
            await model.translationTaskForTesting?.value
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(model.segments[0].english, "No net force.")
            XCTAssertFalse(model.segments[0].hasUsableTranslation)
            XCTAssertTrue(model.segments[0].chinese.isEmpty)
        }
    }

    func testShortAdjacentTargetsKeepIndependentLengthChecks() async throws {
        let unrelated = String(repeating: "这是别的段落的内容。", count: 8)
        for (badCurrent, badPrevious) in [(true, false), (false, true), (true, true)] {
            let probe = AdjacentRequestProbe([
                .text(badCurrent ? unrelated : "所以速率保持不变。"),
                .text(badPrevious ? unrelated : "合力为零。")
            ])
            let pair = try await QwenTranslationClient.translateAdjacent(
                previous: "Net force is zero.", previousChinese: "合力是零。",
                current: "so speed is constant.", context: "", modelName: "test",
                request: { try await probe.request($0, $1, $2) })
            XCTAssertEqual(pair.current, badCurrent ? nil : "所以速率保持不变。")
            XCTAssertEqual(pair.previous, badPrevious ? nil : "合力为零。")
            XCTAssertEqual(pair.currentRejection != nil, badCurrent)
        }
    }

    func testRecoveryChangesOnlyWhatTheFailureRequiresAndPreservesFormulas() async throws {
        let failures: [(QwenRuntimeError, CaptionTranslationAttempt?)] = [
            (.translationRejected("wrong output"), .repairContent),
            (.outputLimitReached("budget"), .expandedBudget),
            (.generationInterrupted("worker exited"), .standard),
            (.requestTimedOut, .standard),
            (.invalidResponse, .standard),
            (.modelUnavailable("missing"), nil),
            (.requestFailed("unclassified worker failure"), .standard)
        ]
        for (failure, recovery) in failures {
            var attempts: [CaptionTranslationAttempt] = []
            let model = try makeModel(.init(translate: { text, _, _, attempt, _ in
                attempts.append(attempt)
                XCTAssertEqual(text, "Compare ZXQCHEM0QXZ with ZXQCHEM1QXZ.")
                if attempts.count == 1 { throw failure }
                return "比较 ZXQCHEM0QXZ 和 ZXQCHEM1QXZ。"
            }, adjacent: { _, _, _, _, _, _, _, _, shouldDefer in throw CancellationError() }))
            model.receiveCaptionForTesting("Compare Na⁺ with Cl⁻.", start: 0, end: 8)
            await model.translationTaskForTesting?.value
            XCTAssertEqual(attempts, recovery.map { [.standard, $0] } ?? [.standard])
            XCTAssertEqual(model.segments[0].hasUsableTranslation, recovery != nil)
            if recovery != nil { XCTAssertEqual(model.segments[0].chinese, "比较 Na⁺ 和 Cl⁻。") }
            else { XCTAssertEqual(model.segments[0].english, "Compare Na⁺ with Cl⁻.") }
        }
    }

    func testContentRecoveryIsBoundedAndDoesNotRepeatAfterAnotherRejection() async throws {
        var attempts: [CaptionTranslationAttempt] = []
        let model = try makeModel(.init(translate: { _, _, _, attempt, _ in
            attempts.append(attempt)
            throw QwenRuntimeError.translationRejected("still incomplete")
        }, adjacent: { _, _, _, _, _, _, _, _, shouldDefer in throw CancellationError() }))
        model.receiveCaptionForTesting("The system gains energy.", start: 0, end: 8)
        await model.translationTaskForTesting?.value
        XCTAssertEqual(attempts, [.standard, .repairContent])
        XCTAssertFalse(model.segments[0].hasUsableTranslation)
        XCTAssertEqual(model.segments[0].english, "The system gains energy.")
    }

    func testRejectedAdjacentCurrentKeepsValidPreviousRepairDuringRecovery() async throws {
        var calls = 0
        let model = try makeModel(.init(translate: { _, _, _, attempt, _ in
            calls += 1
            if calls == 1 { return "之前的译文。" }
            XCTAssertEqual(attempt, .repairContent)
            throw QwenRuntimeError.translationRejected("still invalid")
        }, adjacent: { _, _, _, _, _, _, _, _, shouldDefer in
            .init(previous: "根据后文修正的前句。", current: nil,
                  previousRejection: nil, currentRejection: "当前句未翻译")
        }))
        model.receiveCaptionForTesting("The first statement concerns thermal energy.", start: 0, end: 8)
        await model.translationTaskForTesting?.value
        model.receiveCaptionForTesting("The second statement concerns the temperature.", start: 8, end: 16)
        await model.translationTaskForTesting?.value
        XCTAssertEqual(model.segments[0].chinese, "根据后文修正的前句。")
        XCTAssertTrue(model.segments[0].hasUsableTranslation)
        XCTAssertFalse(model.segments[1].hasUsableTranslation)
        XCTAssertEqual(calls, 2)
    }

    func testQueuedCurrentCaptionsRunBeforePreviousRepairs() async throws {
        for mode in [ModelMode.energySaver, .highQuality] {
            let probe = RepairOrderProbe()
            let model = try makeModel(.init(translate: { _, _, _, _, _ in "系统吸收热能。" },
                adjacent: { previous, chinese, current, context, name, repair, hints, onCurrent, shouldDefer in
                    try await QwenTranslationClient.translateAdjacent(previous: previous,
                        previousChinese: chinese, current: current, context: context, modelName: name,
                        repairPrevious: repair, currentHints: hints, onCurrent: onCurrent, deferRepair: shouldDefer,
                        request: { try await probe.request($0, $1, $2) })
                }, repair: { pending in
                    try await QwenTranslationClient.repairPreviousCaption(previous: pending.previous.english,
                        previousChinese: pending.previous.chinese, current: pending.normalizedCurrent,
                        context: pending.context.map(\.english).joined(separator: " "), modelName: pending.modelName,
                        request: { try await probe.request($0, $1, $2) })
                }))
            model.selectedMode = mode
            model.receiveCaptionForTesting("The system absorbs thermal energy.", start: 0, end: 10)
            await model.translationTaskForTesting?.value
            model.receiveCaptionForTesting("and its temperature rises.", start: 10, end: 20)
            model.receiveCaptionForTesting("and the container expands slowly.", start: 20, end: 28)
            await model.translationTaskForTesting?.value
            let inputs = await probe.inputs
            XCTAssertEqual(inputs.count, 4, "Prioritizing captions must retain both repairs without extra generation")
            XCTAssertEqual(try captionSource(in: XCTUnwrap(inputs.first), mode: mode), "and its temperature rises.")
            XCTAssertEqual(try captionSource(in: XCTUnwrap(inputs.dropFirst().first), mode: mode), "and the container expands slowly.",
                           "An already queued caption must not wait for optional previous repair")
            XCTAssertTrue(model.segments.allSatisfy(\.hasUsableTranslation))
            XCTAssertEqual(model.segments.map(\.chinese), ["系统吸收了热能。", "它的温度随之升高。", "容器慢慢膨胀。"])
        }
    }

    func testCaptionArrivingDuringTranslationPrecedesOptionalRepair() async throws {
        for mode in [ModelMode.energySaver, .highQuality] {
            let gate = CaptionIdentityGate<String>()
            addTeardownBlock { await gate.finish(.failure(CancellationError())) }
            let probe = AdjacentRequestProbe([.held(gate), .text("容器慢慢膨胀。"),
                                              .text("系统吸收了热能。"), .text("它的温度随之升高。")])
            let model = try makeModel(.init(translate: { _, _, _, _, _ in "系统吸收热能。" },
                adjacent: { previous, chinese, current, context, name, repair, hints, update, shouldDefer in
                    try await QwenTranslationClient.translateAdjacent(previous: previous,
                        previousChinese: chinese, current: current, context: context, modelName: name,
                        repairPrevious: repair, currentHints: hints, onCurrent: update, deferRepair: shouldDefer,
                        request: { try await probe.request($0, $1, $2) })
                }, repair: { pending in
                    try await QwenTranslationClient.repairPreviousCaption(previous: pending.previous.english,
                        previousChinese: pending.previous.chinese, current: pending.normalizedCurrent,
                        context: pending.context.map(\.english).joined(separator: " "), modelName: pending.modelName,
                        request: { try await probe.request($0, $1, $2) })
                }))
            model.selectedMode = mode
            model.receiveCaptionForTesting("The system absorbs thermal energy.", start: 0, end: 10)
            await model.translationTaskForTesting?.value
            model.receiveCaptionForTesting("and its temperature rises.", start: 10, end: 20)
            try await eventually { gate.entered }
            model.receiveCaptionForTesting("and the container expands slowly.", start: 20, end: 28)
            gate.finish(.success("温度随之升高。"))
            await model.translationTaskForTesting?.value
            let requests = await probe.requests
            XCTAssertEqual(requests.count, 4)
            XCTAssertEqual(try captionSource(in: requests[1].input, mode: mode), "and the container expands slowly.")
            XCTAssertEqual(model.segments.map(\.chinese), ["系统吸收了热能。", "它的温度随之升高。", "容器慢慢膨胀。"])
        }
    }

    func testDeferredRepairFailureDoesNotRepeatCompletedCaptions() async throws {
        var ordinaryCalls = 0
        var currentCalls = 0
        var repairs = 0
        let model = try makeModel(.init(translate: { _, _, _, _, _ in
            ordinaryCalls += 1
            return "系统吸收热能。"
        }, adjacent: { _, _, current, _, _, _, _, _, shouldDefer in
            currentCalls += 1
            return .init(previous: nil, current: current.contains("temperature") ? "温度随之升高。" : "容器慢慢膨胀。",
                         previousRejection: nil, currentRejection: nil, previousRepairDeferred: shouldDefer?() == true)
        }, repair: { _ in
            repairs += 1
            throw QwenRuntimeError.requestTimedOut
        }))
        model.receiveCaptionForTesting("The system absorbs thermal energy.", start: 0, end: 10)
        await model.translationTaskForTesting?.value
        model.receiveCaptionForTesting("and its temperature rises.", start: 10, end: 20)
        model.receiveCaptionForTesting("and the container expands slowly.", start: 20, end: 28)
        await model.translationTaskForTesting?.value
        XCTAssertEqual(ordinaryCalls, 1)
        XCTAssertEqual(currentCalls, 2)
        XCTAssertEqual(repairs, 2)
        XCTAssertEqual(model.segments.map(\.chinese), ["系统吸收热能。", "温度随之升高。", "容器慢慢膨胀。"])
    }

    func testDeferredRepairCannotOverwriteChangedInputOrEnterNewSession() async throws {
        for change in ["previous", "current", "session"] {
            let gate = CaptionIdentityGate<QwenTranslationClient.PreviousRepair>()
            addTeardownBlock { await gate.finish(.failure(CancellationError())) }
            var repairCalls = 0
            let model = try makeModel(.init(translate: { _, _, _, _, _ in "有效的译文。" },
                adjacent: { _, _, _, _, _, _, _, _, shouldDefer in
                    .init(previous: nil, current: "有效的当前译文。", previousRejection: nil,
                          currentRejection: nil, previousRepairDeferred: shouldDefer?() == true)
                }, repair: { _ in
                    repairCalls += 1
                    if repairCalls == 1 { return try await gate.wait() }
                    return .init(previous: nil, rejection: nil)
                }))
            model.receiveCaptionForTesting("The system absorbs thermal energy.", start: 0, end: 10)
            await model.translationTaskForTesting?.value
            model.receiveCaptionForTesting("and its temperature rises.", start: 10, end: 20)
            model.receiveCaptionForTesting("and the container expands slowly.", start: 20, end: 28)
            try await eventually { gate.entered }
            XCTAssertTrue(model.segments.allSatisfy(\.hasUsableTranslation),
                          "Every queued current caption must finish before the held repair starts")
            XCTAssertEqual(repairCalls, 1, "Only one repair may run at a time")
            let old = model.translationTaskForTesting
            if change == "session" {
                model.resetTranslationSessionForTesting()
                model.receiveCaptionForTesting("A new lecture starts here.", start: 0, end: 8)
            } else {
                model.reviseCaptionForTesting(id: model.segments[change == "previous" ? 0 : 1].id,
                    english: "The revised statement describes cooling.")
            }
            gate.finish(.success(.init(previous: "失效的补修结果。", rejection: nil)))
            await old?.value
            await model.translationTaskForTesting?.value
            XCTAssertFalse(model.segments.contains { $0.chinese.contains("失效") }, change)
            XCTAssertTrue(model.segments.allSatisfy(\.hasUsableTranslation), change)
            if change == "session" { XCTAssertEqual(model.segments.count, 1); XCTAssertEqual(repairCalls, 1) }
        }
    }

    func testDeferredRepairSurvivesPauseAndReopenWithoutRetranslatingCurrent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-DeferredRepair-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var snapshot = SessionSnapshot()
        let previous = TranscriptSegment(startTime: 0, endTime: 10,
            english: "The system absorbs thermal energy.", chinese: "系统吸收热能。", sessionID: snapshot.sessionID)
        let current = TranscriptSegment(startTime: 10, endTime: 20,
            english: "and its temperature rises.", chinese: "温度随之升高。", sessionID: snapshot.sessionID)
        snapshot.segments = [previous, current]
        let pending = DeferredCaptionRepair(sessionID: snapshot.sessionID, previous: previous, current: current,
            context: [], normalizedCurrent: current.english, modelName: "test")
        snapshot.processing.pendingCaptionRepairs = [pending]
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        _ = try SessionStore(directory: root).save(snapshot)
        let gate = CaptionIdentityGate<QwenTranslationClient.PreviousRepair>()
        addTeardownBlock { await gate.finish(.failure(CancellationError())) }
        var repairCalls = 0
        var deps = CaptionTranslationDependencies.unavailable
        deps.repair = { _ in repairCalls += 1; return try await gate.wait() }
        let model = try makeModel(deps)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(root, allowAutomaticProcessing: false)
        XCTAssertEqual(repairCalls, 0, "Opening an archive must not start a model")
        model.resumeSavedProcessing()
        try await eventually { gate.entered }
        let old = model.translationTaskForTesting
        model.pauseSavedProcessing()
        try await eventually { model.savedProcessingIsPaused }
        gate.finish(.success(.init(previous: "取消后的旧结果。", rejection: nil)))
        await old?.value
        try await model.savedPauseTaskForTesting?.value
        await model.savedProcessingTaskForTesting?.value
        XCTAssertNil(model.archiveError)
        try await eventually { (try? SessionStore(directory: root).load())?.processing.paused == true }
        let paused = try XCTUnwrap(SessionStore(directory: root).load())
        XCTAssertEqual(paused.processing.pendingCaptionRepairs, [pending])
        XCTAssertEqual(paused.segments.map(\.chinese), [previous.chinese, current.chinese])
        // The old app must finish parking before a new app owns the same
        // directory. A paused flag alone is not a completed disk flush.
        model.resetTranslationSessionForTesting()
        var resumedCalls = 0
        var resumedDeps = CaptionTranslationDependencies.unavailable
        resumedDeps.repair = { restored in
            resumedCalls += 1
            XCTAssertEqual(restored, pending)
            return .init(previous: "系统吸收了热能。", rejection: nil)
        }
        let resumed = try makeModel(resumedDeps)
        resumed.loadPresentationForTesting(phase: .idle, evidence: [])
        try await resumed.openSavedSession(root, allowAutomaticProcessing: false)
        XCTAssertEqual(resumedCalls, 0)
        XCTAssertFalse(resumed.isRecording)
        resumed.resumeSavedProcessing()
        try await eventually { resumed.segments.first?.chinese == "系统吸收了热能。" }
        await resumed.translationTaskForTesting?.value
        await resumed.savedProcessingTaskForTesting?.value
        XCTAssertNil(resumed.archiveError)
        let saved = try XCTUnwrap(SessionStore(directory: root).load())
        XCTAssertEqual(resumedCalls, 1)
        XCTAssertNil(saved.processing.pendingCaptionRepairs)
        XCTAssertEqual(saved.segments[1], current, "The completed current caption must not be generated again")
        XCTAssertEqual(saved.revisionHistory.last?.previousSegment, previous)
        XCTAssertEqual(saved.segments[0].chinese, "系统吸收了热能。")
        XCTAssertFalse(resumed.isRecording)
    }

    func testDeferredRepairSkipsChangedContextBeforeGenerating() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-StaleRepair-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var snapshot = SessionSnapshot()
        let context = TranscriptSegment(startTime: 0, endTime: 8, english: "The context describes heating.",
            chinese: "背景是加热。", sessionID: snapshot.sessionID)
        let previous = TranscriptSegment(startTime: 8, endTime: 18, english: "The system absorbs thermal energy.",
            chinese: "系统吸收热能。", sessionID: snapshot.sessionID)
        let current = TranscriptSegment(startTime: 18, endTime: 28, english: "and its temperature rises.",
            chinese: "温度随之升高。", sessionID: snapshot.sessionID)
        let pending = DeferredCaptionRepair(sessionID: snapshot.sessionID, previous: previous, current: current,
            context: [context], normalizedCurrent: current.english, modelName: "test")
        let changedContext = TranscriptSegment(id: context.id, startTime: context.startTime,
            endTime: context.endTime, english: "The context describes cooling.",
            chinese: "背景是冷却。", sessionID: snapshot.sessionID)
        snapshot.segments = [changedContext, previous, current]
        snapshot.processing.pendingCaptionRepairs = [pending]
        snapshot.processing.paused = true
        _ = try SessionStore(directory: root).save(snapshot)
        var repairCalls = 0
        var deps = CaptionTranslationDependencies.unavailable
        deps.repair = { _ in repairCalls += 1; return .init(previous: "失效结果。", rejection: nil) }
        let model = try makeModel(deps)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(root, allowAutomaticProcessing: false)
        model.resumeSavedProcessing()
        try await eventually { !model.savedProcessingIsPaused }
        await model.translationTaskForTesting?.value
        await model.savedProcessingTaskForTesting?.value
        XCTAssertEqual(repairCalls, 0)
        XCTAssertEqual(model.segments, snapshot.segments)
        XCTAssertNil(try SessionStore(directory: root).load()?.processing.pendingCaptionRepairs)
    }

    func testLegacyArchiveHasNoDeferredRepairAndDuplicateJobsAreRejected() throws {
        var snapshot = SessionSnapshot()
        let previous = TranscriptSegment(startTime: 0, endTime: 10, english: "The system absorbs thermal energy.",
            chinese: "系统吸收热能。", sessionID: snapshot.sessionID)
        let current = TranscriptSegment(startTime: 10, endTime: 20, english: "and its temperature rises.",
            chinese: "温度随之升高。", sessionID: snapshot.sessionID)
        snapshot.segments = [previous, current]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        var processing = try XCTUnwrap(json["processing"] as? [String: Any])
        processing.removeValue(forKey: "pendingCaptionRepairs")
        json["processing"] = processing
        let legacy = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.processing.pendingCaptionRepairs)
        try legacy.validate()
        let pending = DeferredCaptionRepair(sessionID: snapshot.sessionID, previous: previous, current: current,
            context: [], normalizedCurrent: current.english, modelName: "test")
        snapshot.processing.pendingCaptionRepairs = [pending, pending]
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.processing.pendingCaptionRepairs = [.init(sessionID: UUID(), previous: previous, current: current,
            context: [], normalizedCurrent: current.english, modelName: "test")]
        XCTAssertThrowsError(try snapshot.validate())
    }

    func testAcceptedCurrentAppearsWhilePreviousRepairIsSuspended() async throws {
        let gate = CaptionIdentityGate<String>()
        addTeardownBlock { await gate.finish(.failure(CancellationError())) }
        let probe = AdjacentRequestProbe([.text("温度随之升高。"), .held(gate)])
        let model = try makeModel(.init(translate: { _, _, _, _, _ in "系统吸收热能。" },
            adjacent: { previous, chinese, current, context, name, repair, hints, onCurrent, shouldDefer in
                try await QwenTranslationClient.translateAdjacent(previous: previous,
                    previousChinese: chinese, current: current, context: context, modelName: name,
                    repairPrevious: repair, currentHints: hints, onCurrent: onCurrent, deferRepair: shouldDefer,
                    request: { try await probe.request($0, $1, $2) })
            }))
        model.receiveCaptionForTesting("The system absorbs thermal energy.", start: 0, end: 10)
        await model.translationTaskForTesting?.value
        model.receiveCaptionForTesting("and its temperature rises.", start: 10, end: 18)
        try await eventually { gate.entered }
        XCTAssertEqual(model.streamingChinese, "温度随之升高。",
                       "The accepted current caption must be readable before optional previous repair returns")
        XCTAssertEqual(model.translatingSegmentID, model.segments[1].id)
        XCTAssertFalse(model.segments[1].hasUsableTranslation, "Preview must not bypass the final identity checks")
        XCTAssertTrue(model.segments[1].chinese.isEmpty)
        gate.finish(.success("系统吸收了热能。"))
        await model.translationTaskForTesting?.value
        XCTAssertEqual(model.segments[0].chinese, "系统吸收了热能。")
        XCTAssertEqual(model.segments[1].chinese, "温度随之升高。")
        XCTAssertTrue(model.streamingChinese.isEmpty)
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 2, "Publishing a preview must not add another model request")
    }

    func testPreviousRepairFailureDoesNotRetranslateCompletedCurrent() async throws {
        let failures: [QwenRuntimeError] = [
            .outputLimitReached("repair budget"), .generationInterrupted("repair worker exited"),
            .requestTimedOut, .invalidResponse, .requestFailed("repair transport failure")
        ]
        for failure in failures {
            let probe = AdjacentRequestProbe([.text("温度随之升高。"), .failure(failure)])
            var ordinaryCalls = 0
            let model = try makeModel(.init(translate: { _, _, _, _, _ in
                ordinaryCalls += 1
                return ordinaryCalls == 1 ? "系统吸收热能。" : "重算后的另一份译文。"
            }, adjacent: { previous, chinese, current, context, name, repair, hints, onCurrent, shouldDefer in
                XCTAssertTrue(repair)
                return try await QwenTranslationClient.translateAdjacent(previous: previous,
                    previousChinese: chinese, current: current, context: context, modelName: name,
                    repairPrevious: repair, currentHints: hints, onCurrent: onCurrent, deferRepair: shouldDefer,
                    request: { try await probe.request($0, $1, $2) })
            }))
            model.receiveCaptionForTesting("The system absorbs thermal energy.", start: 0, end: 10)
            await model.translationTaskForTesting?.value
            model.receiveCaptionForTesting("and its temperature rises.", start: 10, end: 18)
            await model.translationTaskForTesting?.value
            let requests = await probe.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(ordinaryCalls, 1, "A previous repair failure must not retranslate a valid current sentence")
            XCTAssertEqual(model.segments[0].chinese, "系统吸收热能。")
            XCTAssertEqual(model.segments[1].chinese, "温度随之升高。")
            XCTAssertTrue(model.segments.allSatisfy(\.hasUsableTranslation))
        }
    }

    func testRejectedCurrentIsNotPublishedWhileRepairWaits() async throws {
        for raw in ["Compare Na⁺ with Cl⁻.", "比较 ZXQCHEM0QXZ。", String(repeating: "无关的其他段落。", count: 60)] {
            let gate = CaptionIdentityGate<String>()
            addTeardownBlock { await gate.finish(.failure(CancellationError())) }
            let probe = AdjacentRequestProbe([.text(raw), .held(gate)])
            var updates: [String] = []
            let task = Task {
                try await QwenTranslationClient.translateAdjacent(
                    previous: "Prepare the sample.", previousChinese: "准备样品。",
                    current: "Compare Na⁺ with Cl⁻.", context: "", modelName: "test",
                    onCurrent: { updates.append($0) }, request: { try await probe.request($0, $1, $2) })
            }
            try await eventually { gate.entered }
            XCTAssertTrue(updates.isEmpty)
            gate.finish(.success("准备好样品。"))
            let result = try await task.value
            XCTAssertNil(result.current)
            XCTAssertTrue(updates.isEmpty)
        }
    }

    func testAdjacentPreviewIsClearedWhenEitherInputChanges() async throws {
        for revisePrevious in [false, true] {
            let gate = CaptionIdentityGate<QwenTranslationClient.AdjacentTranslation>()
            addTeardownBlock { await gate.finish(.failure(CancellationError())) }
            var oldUpdate: CaptionTranslationDependencies.Update?
            var pairCalls = 0
            let model = try makeModel(.init(translate: { text, _, _, _, _ in
                text.contains("revised") ? "修订后的译文。" : "系统吸收热能。"
            }, adjacent: { _, _, _, _, _, _, _, onCurrent, shouldDefer in
                pairCalls += 1
                if pairCalls == 1 {
                    oldUpdate = onCurrent
                    await onCurrent?("温度随之升高。")
                    return try await gate.wait()
                }
                return .init(previous: nil, current: "采用新原文的译文。", previousRejection: nil, currentRejection: nil)
            }))
            model.receiveCaptionForTesting("The system absorbs thermal energy.", start: 0, end: 10)
            await model.translationTaskForTesting?.value
            model.receiveCaptionForTesting("and its temperature rises.", start: 10, end: 18)
            try await eventually { gate.entered }
            XCTAssertEqual(model.streamingChinese, "温度随之升高。")
            let changedID = model.segments[revisePrevious ? 0 : 1].id
            model.reviseCaptionForTesting(id: changedID, english: "The revised system loses thermal energy.")
            XCTAssertTrue(model.streamingChinese.isEmpty, "Previously visible text must vanish as soon as its input changes")
            await oldUpdate?("失效回调不能重新显示。")
            XCTAssertTrue(model.streamingChinese.isEmpty)
            gate.finish(.success(.init(previous: "失效的前句。", current: "失效的当前句。", previousRejection: nil, currentRejection: nil)))
            await model.translationTaskForTesting?.value
            XCTAssertEqual(pairCalls, 2)
            XCTAssertEqual(model.segments[1].chinese, "采用新原文的译文。")
            XCTAssertFalse(model.segments.contains { $0.chinese.contains("失效") })
        }
    }

    func testOldAdjacentPreviewCannotEnterNewSession() async throws {
        let gate = CaptionIdentityGate<QwenTranslationClient.AdjacentTranslation>()
        addTeardownBlock { await gate.finish(.failure(CancellationError())) }
        var update: CaptionTranslationDependencies.Update?
        let model = try makeModel(.init(translate: { text, _, _, _, _ in
            text.contains("new session") ? "新课堂的译文。" : "原课堂的前句。"
        }, adjacent: { _, _, _, _, _, _, _, onCurrent, shouldDefer in
            update = onCurrent
            await onCurrent?("原课堂正在预览的译文。")
            return try await gate.wait()
        }))
        model.receiveCaptionForTesting("The previous lecture describes thermal energy.", start: 0, end: 10)
        await model.translationTaskForTesting?.value
        model.receiveCaptionForTesting("and the temperature increases.", start: 10, end: 18)
        try await eventually { gate.entered }
        XCTAssertFalse(model.streamingChinese.isEmpty)
        let oldTask = model.resetTranslationSessionForTesting()
        model.receiveCaptionForTesting("The new session has a different topic.", start: 0, end: 8)
        await model.translationTaskForTesting?.value
        await update?("旧课堂的迟到预览。")
        XCTAssertTrue(model.streamingChinese.isEmpty)
        gate.finish(.success(.init(previous: nil, current: "旧课堂的最终结果。", previousRejection: nil, currentRejection: nil)))
        await oldTask?.value
        XCTAssertEqual(model.segments.count, 1)
        XCTAssertEqual(model.segments[0].chinese, "新课堂的译文。")
    }

    func testCancellationDuringPublicationDoesNotStartRepair() async throws {
        let probe = AdjacentRequestProbe([.text("温度随之升高。"), .text("不应生成的前句修复。")])
        var published = 0
        let task = Task {
            try await QwenTranslationClient.translateAdjacent(
                previous: "The system absorbs thermal energy.", previousChinese: "系统吸收热能。",
                current: "and its temperature rises.", context: "", modelName: "test",
                onCurrent: { _ in published += 1; withUnsafeCurrentTask { $0?.cancel() } },
                request: { try await probe.request($0, $1, $2) })
        }
        do { _ = try await task.value; XCTFail("Cancellation during publication must propagate") }
        catch is CancellationError { }
        XCTAssertEqual(published, 1)
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testPreviousRepairWithoutMappableTailSkipsUnusedGeneration() async throws {
        let probe = AdjacentRequestProbe([.text("它使物体转向。"), .text("力指向中心。")])
        let pair = try await QwenTranslationClient.translateAdjacent(
            previous: "The force acts toward the center.", previousChinese: "先说明方向。力指向中心。",
            current: "and it turns the object.", context: "", modelName: "test",
            request: { try await probe.request($0, $1, $2) })
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1, "Do not generate a repair that cannot replace the stable Chinese prefix")
        XCTAssertEqual(pair.current, "它使物体转向。")
        XCTAssertNil(pair.previous)
        XCTAssertNil(pair.currentRejection)
    }

    func testAdjacentCancellationAlwaysPropagatesFromPreviousRepair() async throws {
        let responses: [AdjacentRequestProbe.Response] = [
            .cancelled, .cancelThenText("力指向中心。"), .cancelThenFailure(.invalidResponse)
        ]
        for response in responses {
            let probe = AdjacentRequestProbe([.text("它使物体转向。"), response])
            let task = Task {
                try await QwenTranslationClient.translateAdjacent(
                    previous: "The force acts toward the center.", previousChinese: "力指向中心。",
                    current: "and it turns the object.", context: "", modelName: "test",
                    request: { try await probe.request($0, $1, $2) })
            }
            do {
                _ = try await task.value
                XCTFail("A dependency that returns after cancellation must not turn the pair into a success")
            } catch is CancellationError { }
            catch { XCTFail("Cancellation must take precedence over a repair error: \(error)") }
            let requests = await probe.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testAdjacentSuccessfulTailRepairRetainsStablePrefixAndRequestShape() async throws {
        let probe = AdjacentRequestProbe([.text("指向中心。"), .text("力指向中心。")])
        let pair = try await QwenTranslationClient.translateAdjacent(
            previous: "Check the direction. The force acts.", previousChinese: "先检查方向。力起作用。",
            current: "toward the center.", context: "Earlier context.", modelName: "test",
            request: { try await probe.request($0, $1, $2) })
        XCTAssertEqual(pair.previous, "先检查方向。力指向中心。")
        XCTAssertEqual(pair.current, "指向中心。")
        XCTAssertNil(pair.previousRejection)
        XCTAssertNil(pair.currentRejection)
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].input, "toward the center.")
        XCTAssertEqual(requests.map(\.budget), [160, 320])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(requests[1].input.utf8)) as? [String: String])
        XCTAssertEqual(json["target_translate_only"], "The force acts.")
        XCTAssertTrue(json["context_before_do_not_translate"]?.contains("Check the direction.") == true)
        XCTAssertEqual(json["context_after_do_not_translate"], "toward the center.")
        XCTAssertTrue(requests[1].prompt.contains("Translate ONLY target_translate_only"))
    }

    func testAdjacentCurrentValidationRemainsIndependentOfRepairOutcome() async throws {
        for repair in [AdjacentRequestProbe.Response.text("力指向中心。"), .failure(.invalidResponse)] {
            let probe = AdjacentRequestProbe([.text("and it turns the object."), repair])
            let pair = try await QwenTranslationClient.translateAdjacent(
                previous: "The force acts toward the center.", previousChinese: "力起作用。",
                current: "and it turns the object.", context: "", modelName: "test",
                request: { try await probe.request($0, $1, $2) })
            XCTAssertNil(pair.current)
            XCTAssertNotNil(pair.currentRejection)
            switch repair {
            case .text:
                XCTAssertEqual(pair.previous, "力指向中心。")
                XCTAssertNil(pair.previousRejection)
            default:
                XCTAssertNil(pair.previous)
                XCTAssertNotNil(pair.previousRejection)
            }
        }
    }

    func testAdjacentLeakedWrapperRejectsCurrentButPreservesPreviousRepair() async throws {
        for leak in [#"{"source_text_to_translate":"它使物体转向。"}"#,
                     "SOURCE_TEXT_TO_TRANSLATE: 它使物体转向。"] {
            let probe = AdjacentRequestProbe([.text(leak), .text("力指向中心。")])
            var published = 0
            let pair = try await QwenTranslationClient.translateAdjacent(
                previous: "The force acts toward the center.", previousChinese: "力起作用。",
                current: "and it turns the object.", context: "",
                modelName: QwenModelProfile.highQuality.translationModel,
                onCurrent: { _ in published += 1 },
                request: { try await probe.request($0, $1, $2) })
            XCTAssertNil(pair.current)
            XCTAssertTrue(pair.currentRejection?.contains("输入包装字段") == true)
            XCTAssertEqual(pair.previous, "力指向中心。")
            XCTAssertNil(pair.previousRejection)
            XCTAssertEqual(published, 0)
            let requests = await probe.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testCancelledWrapperRejectionDoesNotStartPreviousRepair() async throws {
        let probe = AdjacentRequestProbe([
            .cancelThenText(#"{"source_text_to_translate":"它使物体转向。"}"#),
            .text("不应生成的前句。")])
        let task = Task {
            try await QwenTranslationClient.translateAdjacent(
                previous: "The force acts toward the center.", previousChinese: "力起作用。",
                current: "and it turns the object.", context: "",
                modelName: QwenModelProfile.highQuality.translationModel,
                request: { try await probe.request($0, $1, $2) })
        }
        do { _ = try await task.value; XCTFail("Cancellation must precede content recovery") }
        catch is CancellationError { }
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testAdjacentRejectedFormulaOrOverlongRepairKeepsValidCurrent() async throws {
        let previous = "Compare the Na⁺ ions with the Cl⁻ ions in the solution."
        XCTAssertGreaterThanOrEqual(previous.count, TranslationLengthGuard.minimumEnglishCount)
        for output in ["Na⁺ 仍在溶液中。", String(repeating: "这是来自其他段落的内容。", count: 60) + "Na⁺ 和 Cl⁻。"] {
            let probe = AdjacentRequestProbe([.text("然后搅拌溶液。"), .text(output)])
            let pair = try await QwenTranslationClient.translateAdjacent(
                previous: previous, previousChinese: "比较溶液中的 Na⁺ 和 Cl⁻ 离子。",
                current: "Then stir the solution.", context: "", modelName: "test",
                request: { try await probe.request($0, $1, $2) })
            XCTAssertEqual(pair.current, "然后搅拌溶液。")
            XCTAssertNil(pair.previous)
        }
    }

    func testAdjacentCurrentFailureDoesNotStartOptionalRepair() async throws {
        let probe = AdjacentRequestProbe([.failure(.outputLimitReached("current budget"))])
        do {
            _ = try await QwenTranslationClient.translateAdjacent(
                previous: "The force acts toward the center.", previousChinese: "力起作用。",
                current: "and it turns the object.", context: "", modelName: "test",
                request: { try await probe.request($0, $1, $2) })
            XCTFail("Current generation failure must reach the existing recovery policy")
        } catch QwenRuntimeError.outputLimitReached(let reason) { XCTAssertEqual(reason, "current budget") }
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testAdjacentWithoutRepairRestoresFormulasAndKeepsHintsSeparate() async throws {
        let probe = AdjacentRequestProbe([.text("向样品 A 加入 2 mL ZXQCHEM0QXZ。")])
        var published: [String] = []
        let pair = try await QwenTranslationClient.translateAdjacent(
            previous: "Prepare the sample.", previousChinese: "准备样品。",
            current: "Add 2 mL H2O to sample A.", context: "Do not include this earlier sentence.",
            modelName: QwenModelProfile.highQuality.translationModel, repairPrevious: false,
            currentHints: [.init(kind: .formula, value: "H2O"), .init(kind: .unit, value: "2 mL")],
            onCurrent: { published.append($0) },
            request: { try await probe.request($0, $1, $2) })
        XCTAssertEqual(pair.current, "向样品 A 加入 2 mL H2O。")
        XCTAssertEqual(published, ["向样品 A 加入 2 mL H2O。"])
        XCTAssertNil(pair.previous)
        XCTAssertNil(pair.currentRejection)
        let requests = await probe.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].input.contains("Add 2 mL ZXQCHEM0QXZ to sample A."))
        XCTAssertFalse(requests[0].input.contains("H2O"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(requests[0].input.utf8)) as? [String: Any])
        XCTAssertEqual(payload["source_text_to_translate"] as? String, "Add 2 mL ZXQCHEM0QXZ to sample A.")
        XCTAssertEqual(payload["auxiliary_token_hints"] as? [String], ["- unit: 2 mL"])
        XCTAssertFalse(requests[0].input.contains("earlier sentence"))
        XCTAssertEqual(requests[0].budget, 168)
    }

    func testSummaryCommitSurvivesUnrelatedRevisionButRejectsDependencyRevision() async throws {
        for dependsOnEarlier in [false, true] {
            let gate = CaptionIdentityGate<String>()
            addTeardownBlock { await gate.finish(.failure(CancellationError())) }
            var calls = 0
            let model = try makeModel(.unavailable, notes: .init(generate: { _, _, _, update in
                calls += 1
                await update("{\"topic\":")
                return try await gate.wait()
            }))
            let earlier = TranscriptSegment(startTime: 0, endTime: 8,
                english: dependsOnEarlier ? "Its speed is not known yet." : "The cup is made of glass.",
                chinese: dependsOnEarlier ? "速度仍待后文说明。" : "杯子由玻璃制成。")
            let current = TranscriptSegment(startTime: 8, endTime: 16,
                english: "Cart B moves at two metres per second.", chinese: "B 车的速度为每秒两米。")
            let next = TranscriptSegment(startTime: 16, endTime: 24,
                english: "Cart B keeps this speed for the whole journey.", chinese: "B 车全程保持该速度。")
            var notebook = LearningNotebook()
            try notebook.append(evidence: [earlier], note: .init(topic: "先前记录", points: [
                .init(kind: dependsOnEarlier ? "待确认" : "核心结论", text: earlier.chinese,
                      needsContext: dependsOnEarlier ? "速度属于哪辆车？" : nil, sourceIDs: ["en0s0"])
            ], sourceVersion: 2))
            model.loadPresentationForTesting(phase: .saved(FileManager.default.temporaryDirectory),
                evidence: [earlier, current, next], notebook: notebook)
            let task = Task { await model.generateSummaryForTesting() }
            try await eventually { gate.entered }
            model.reviseCaptionForTesting(id: earlier.id, english: "The earlier statement has been revised.")
            gate.finish(.success(#"{"topic":"小车运动","points":[{"kind":"核心结论","text":"B 车全程保持每秒两米的速度。","sourceIDs":["en0s0","en1s0"]}]}"#))
            await task.value
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(model.lectureSummary.contains("B 车全程保持每秒两米的速度。"), !dependsOnEarlier)
        }
    }

    func testAdjacentRepairFollowsCaptionIdentityAfterEarlierInsertion() async throws {
        let gate = CaptionIdentityGate<QwenTranslationClient.AdjacentTranslation>()
        addTeardownBlock { await gate.finish(.failure(CancellationError())) }
        let first = TranscriptSegment(startTime: 10, endTime: 20,
                                      english: "The pressure changes when we heat the gas.")
        let current = TranscriptSegment(startTime: 20, endTime: 28,
                                        english: "The temperature also changes during heating.")
        let earlier = TranscriptSegment(startTime: 0, endTime: 8,
                                        english: "This earlier sentence was recovered later.")
        let model = try makeModel(.init(
            translate: { text, _, _, _, _ in text.contains("earlier") ? "较早补转的译文。" : "先前句子的译文。" },
            adjacent: { _, _, _, _, _, _, _, onCurrent, shouldDefer in
                await onCurrent?("加热时温度也发生变化。")
                return try await gate.wait()
            }))
        model.receiveIdentifiedCaptionForTesting(first)
        await model.translationTaskForTesting?.value
        model.receiveIdentifiedCaptionForTesting(current)
        try await eventually { gate.entered }
        model.receiveIdentifiedCaptionForTesting(earlier)
        XCTAssertEqual(model.streamingChinese, "加热时温度也发生变化。")
        XCTAssertEqual(model.translatingSegmentID, current.id)
        gate.finish(.success(.init(previous: "加热使气体压力发生变化。", current: "加热时温度也发生变化。",
                                  previousRejection: nil, currentRejection: nil)))
        await model.translationTaskForTesting?.value
        XCTAssertEqual(model.segments.map(\.id), [earlier.id, first.id, current.id])
        XCTAssertEqual(model.segments[0].chinese, "较早补转的译文。")
        XCTAssertEqual(model.segments[1].chinese, "加热使气体压力发生变化。")
        XCTAssertEqual(model.segments[2].chinese, "加热时温度也发生变化。")
        XCTAssertEqual(model.segments[0].inputRevision, 0)
        XCTAssertEqual(model.segments[1].inputRevision, 1)
    }

    func testOriginalRevisionRejectsOldStreamingAndCompletedTranslation() async throws {
        let gate = CaptionIdentityGate<String>()
        addTeardownBlock { await gate.finish(.failure(CancellationError())) }
        var oldUpdate: CaptionTranslationDependencies.Update?
        let model = try makeModel(.init(translate: { text, _, _, _, update in
            if text.contains("revised") { return "确认修订后的译文。" }
            oldUpdate = update
            return try await gate.wait()
        }, adjacent: { _, _, _, _, _, _, _, _, shouldDefer in throw CancellationError() }))
        let caption = TranscriptSegment(startTime: 0, endTime: 8,
                                        english: "The original sentence says that pressure increases.")
        model.receiveIdentifiedCaptionForTesting(caption)
        try await eventually { gate.entered }
        model.reviseCaptionForTesting(id: caption.id,
            english: "The revised sentence says that pressure decreases.")
        await oldUpdate?("这是已经失效的流式译文。")
        XCTAssertEqual(model.streamingChinese, "")
        gate.finish(.success("旧原文已经完成的译文。"))
        await model.translationTaskForTesting?.value
        XCTAssertEqual(model.segments.count, 1)
        XCTAssertEqual(model.segments[0].chinese, "确认修订后的译文。")
        XCTAssertEqual(model.segments[0].inputRevision, 1)
        XCTAssertEqual(model.segments[0].translationState, .completed)
    }

    func testRevisionDuringBothRetryPathsRejectsObsoleteResults() async throws {
        for firstFails in [false, true] {
            let gate = CaptionIdentityGate<String>()
            addTeardownBlock { await gate.finish(.failure(CancellationError())) }
            var calls = 0
            let model = try makeModel(.init(translate: { text, _, _, _, _ in
                calls += 1
                if text.contains("revised") { return "新原文对应的译文。" }
                if calls == 1 {
                    if firstFails { throw QwenRuntimeError.invalidResponse }
                    return String(repeating: "这是过长的中文译文。", count: 60)
                }
                return try await gate.wait()
            }, adjacent: { _, _, _, _, _, _, _, _, shouldDefer in throw CancellationError() }))
            let caption = TranscriptSegment(startTime: 0, endTime: 8,
                english: "The system gains energy and its temperature increases.")
            model.receiveIdentifiedCaptionForTesting(caption)
            try await eventually { gate.entered }
            model.reviseCaptionForTesting(id: caption.id,
                english: "The revised system loses energy and its temperature decreases.")
            gate.finish(.success("旧原文重试得到的译文。"))
            await model.translationTaskForTesting?.value
            XCTAssertEqual(calls, 3)
            XCTAssertEqual(model.segments.first?.chinese, "新原文对应的译文。")
            XCTAssertEqual(model.segments.first?.translationState, .completed)
        }
    }

    func testPreviousRevisionInvalidatesAdjacentRequestAndRetranslatesCurrent() async throws {
        let gate = CaptionIdentityGate<QwenTranslationClient.AdjacentTranslation>()
        addTeardownBlock { await gate.finish(.failure(CancellationError())) }
        var pairCalls = 0
        let model = try makeModel(.init(translate: { text, _, _, _, _ in
            text.contains("revised") ? "确认后的前句译文。" : "前句原有译文。"
        }, adjacent: { _, _, _, _, _, _, _, _, shouldDefer in
            pairCalls += 1
            if pairCalls == 1 { return try await gate.wait() }
            return .init(previous: nil, current: "根据新上下文翻译当前句。",
                         previousRejection: nil, currentRejection: nil)
        }))
        let first = TranscriptSegment(startTime: 0, endTime: 10,
                                      english: "The original sentence describes an increase.")
        let second = TranscriptSegment(startTime: 10, endTime: 18,
                                       english: "This change follows the described condition.")
        model.receiveIdentifiedCaptionForTesting(first)
        await model.translationTaskForTesting?.value
        model.receiveIdentifiedCaptionForTesting(second)
        try await eventually { gate.entered }
        model.reviseCaptionForTesting(id: first.id,
                                      english: "The revised sentence describes a decrease.")
        gate.finish(.success(.init(previous: "已失效的前句修复。", current: "已失效的当前句译文。",
                                  previousRejection: nil, currentRejection: nil)))
        await model.translationTaskForTesting?.value
        XCTAssertEqual(pairCalls, 2)
        XCTAssertEqual(model.segments[0].chinese, "确认后的前句译文。")
        XCTAssertEqual(model.segments[1].chinese, "根据新上下文翻译当前句。")
    }

    func testSavedPauseWaitsForOldWorkerBeforeResume() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingo-SavedPause-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let identity = UUID()
        let caption = TranscriptSegment(startTime: 0, endTime: 8,
            english: "A single saved sentence waits for translation.", sessionID: identity)
        var snapshot = SessionSnapshot(sessionID: identity)
        snapshot.segments = [caption]
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        snapshot.processing.pendingSegmentIDs = [caption.id]
        _ = try SessionStore(directory: root).save(snapshot)
        let gate = CaptionIdentityGate<String>()
        addTeardownBlock { await gate.finish(.failure(CancellationError())) }
        var calls = 0
        let model = try makeModel(.init(translate: { _, _, _, _, _ in
            calls += 1
            if calls == 1 { return try await gate.wait() }
            return "恢复后完成的译文。"
        }, adjacent: { _, _, _, _, _, _, _, _, shouldDefer in throw CancellationError() }))
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(root)
        XCTAssertTrue(model.savedProcessingIsPaused)
        model.resumeSavedProcessing()
        try await eventually { gate.entered }
        model.pauseSavedProcessing()
        try await eventually { model.savedProcessingIsPaused }
        model.resumeSavedProcessing()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(calls, 1, "恢复必须等待已取消的请求实际退出")
        gate.finish(.success("暂停前的失效结果。"))
        try await eventually { model.segments.first?.chinese == "恢复后完成的译文。" }
        await model.savedProcessingTaskForTesting?.value
        XCTAssertEqual(calls, 2)
        let restored = try XCTUnwrap(SessionStore(directory: root).load())
        XCTAssertEqual(restored.segments.first?.chinese, "恢复后完成的译文。")
    }

    func testSavedPauseClearsAdjacentPreviewWithoutPersistingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-PreviewPause-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var snapshot = SessionSnapshot()
        let previous = TranscriptSegment(startTime: 0, endTime: 10,
            english: "The system absorbs thermal energy.", chinese: "系统吸收热能。", sessionID: snapshot.sessionID)
        let current = TranscriptSegment(startTime: 10, endTime: 18,
            english: "and its temperature rises.", sessionID: snapshot.sessionID)
        snapshot.segments = [previous, current]
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        snapshot.processing.pendingSegmentIDs = [current.id]
        _ = try SessionStore(directory: root).save(snapshot)
        let gate = CaptionIdentityGate<QwenTranslationClient.AdjacentTranslation>()
        addTeardownBlock { await gate.finish(.failure(CancellationError())) }
        var update: CaptionTranslationDependencies.Update?
        let model = try makeModel(.init(translate: { _, _, _, _, _ in
            XCTFail("A cancelled preview must not cause a new translation")
            throw CancellationError()
        }, adjacent: { _, _, _, _, _, _, _, onCurrent, shouldDefer in
            update = onCurrent
            await onCurrent?("温度随之升高。")
            return try await gate.wait()
        }))
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(root)
        model.resumeSavedProcessing()
        try await eventually { gate.entered }
        XCTAssertEqual(model.streamingChinese, "温度随之升高。")
        let pending = model.translationTaskForTesting
        model.pauseSavedProcessing()
        try await eventually { model.savedProcessingIsPaused }
        XCTAssertTrue(model.streamingChinese.isEmpty)
        await update?("暂停后的迟到预览。")
        XCTAssertTrue(model.streamingChinese.isEmpty)
        gate.finish(.success(.init(previous: nil, current: "温度随之升高。", previousRejection: nil, currentRejection: nil)))
        await pending?.value
        try await eventually { model.segments[1].translationState == .pending }
        await model.savedProcessingTaskForTesting?.value
        let restored = try XCTUnwrap(SessionStore(directory: root).load())
        XCTAssertEqual(restored.segments[0].chinese, "系统吸收热能。")
        XCTAssertTrue(restored.segments[1].chinese.isEmpty)
        XCTAssertFalse(restored.segments[1].hasUsableTranslation)
    }

    func testSavedWriteRetryRebuildsExportsAndRetainsCaptureInterruption() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingo-SavedWriteRetry-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var snapshot = SessionSnapshot()
        snapshot.segments = [TranscriptSegment(startTime: 0, endTime: 8,
            english: "Saved text before the capture interruption.", chinese: "采集中断前保存的正文。",
            sessionID: snapshot.sessionID)]
        snapshot.processing.paused = true
        snapshot.processing.recordFailure("Capture ended at frame 1024", source: .capture)
        snapshot.processing.recordFailure("Earlier readable export failed", source: .storage)
        _ = try SessionStore(directory: root).save(snapshot)
        let model = try makeModel(.unavailable)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(root)
        let blocker = root.appendingPathComponent("transcript-en.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        model.retrySavedSessionWrite()
        try await eventually { !model.archiveLoading }
        XCTAssertNotNil(model.archiveError)
        XCTAssertTrue(model.savedProcessingIsPaused)
        let blocked = try XCTUnwrap(SessionStore(directory: root).load())
        XCTAssertEqual(blocked.processing.captureError, "Capture ended at frame 1024")
        // Remove only the synthetic obstruction created immediately above.
        try FileManager.default.removeItem(at: blocker)
        model.retrySavedSessionWrite()
        try await eventually { !model.archiveLoading }
        let restored = try XCTUnwrap(SessionStore(directory: root).load())
        XCTAssertEqual(restored.processing.lastErrorSource, .capture)
        XCTAssertEqual(restored.processing.lastError, "Capture ended at frame 1024")
        XCTAssertEqual(model.archiveError, "Capture ended at frame 1024")
        XCTAssertTrue(restored.processing.paused)
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8),
                       snapshot.segments[0].english + "\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("transcript-zh-Hans.txt"), encoding: .utf8),
                       snapshot.segments[0].chinese + "\n")
    }
}
