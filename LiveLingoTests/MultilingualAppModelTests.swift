import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class MultilingualAppModelTests: XCTestCase {
    private func fixture(_ translation: CaptionTranslationDependencies = .unavailable) throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultilingualAppModel-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLingo-MultilingualAppModel-\(UUID())"
        let preferenceCleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
                XCTFail("Translation tests must not generate notes or start models")
                throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: translation, notes: .unavailable,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
        model.resetTranslationSessionForTesting()
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            try preferenceCleanup.remove()
            try FileManager.default.removeItem(at: directory)
        }
        return (model, directory)
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Synthetic task did not reach its expected state")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func testChineseCompletesWithoutQueueOrApplePreview() throws {
        let (model, _) = try fixture()
        model.receiveLivePreviewForTesting("Old preview.", chinese: "旧初译。")
        let original = "這片葉子長大了。"
        model.receiveIdentifiedCaptionForTesting(.init(startTime: 0, endTime: 2,
            english: original, sourceLanguage: "zh"), hints: [.init(kind: .formula, value: "H2O")])
        let caption = try XCTUnwrap(model.segments.first)
        XCTAssertEqual(caption.english, original)
        XCTAssertEqual(caption.chinese, "这片叶子长大了。")
        XCTAssertEqual(caption.sourceLanguage, "zh")
        XCTAssertEqual(caption.translationState, .completed)
        XCTAssertNil(model.translationTaskForTesting)
        XCTAssertTrue(model.previewTranslationSource.isEmpty)
        XCTAssertTrue(model.previewChinese.isEmpty)
        XCTAssertEqual(model.previewChineseDisplay, "这片叶子长大了。")
    }

    func testFinalEventKeepsItsSourceLanguage() throws {
        let (model, _) = try fixture()
        model.receiveTranscriptionNoticeForTesting(.final(text: "小船靠岸了。", start: 0, end: 1,
            hints: [], language: "zh"))
        XCTAssertEqual(model.segments.first?.sourceLanguage, "zh")
        XCTAssertEqual(model.segments.first?.chinese, "小船靠岸了。")
        XCTAssertNil(model.translationTaskForTesting)
    }

    func testIdentifiedFinalKeepsLanguageAndRepeatRemainsIdempotent() async throws {
        var english = 0
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translate = { _, _, _, _, _ in english += 1; return "铃响了。" }
        let (model, _) = try fixture(dependencies)
        model.receiveCaptionForTesting("A bell rings.", start: 0, end: 1)
        await model.translationTaskForTesting?.value
        let session = try XCTUnwrap(model.segments.first?.sessionID)
        let commit = TranscriptionCommit(id: UUID(), sessionID: session, text: "小船靠岸了。", start: 1, end: 2,
            startFrame: 16000, endFrame: 32000, sampleRate: 16000, hints: [], isRepair: false, language: "zh")
        model.receiveTranscriptionNoticeForTesting(.identifiedFinal(commit))
        model.receiveTranscriptionNoticeForTesting(.identifiedFinal(commit))
        XCTAssertEqual(model.segments.count, 2)
        XCTAssertEqual(model.segments.last?.sourceLanguage, "zh")
        XCTAssertEqual(model.segments.last?.chinese, commit.text)
        XCTAssertEqual(english, 1)
        XCTAssertNil(model.translationTaskForTesting)
    }

    func testCantoneseKeepsOriginalAndTranslatesToSimplifiedMandarin() async throws {
        var calls: [String] = []
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translateSource = { text, _, language, attempt, update in
            calls.append(language)
            XCTAssertEqual(text, "呢個箱入面有兩本書。")
            XCTAssertEqual(attempt, .standard)
            await update?("這個箱子裡面有兩本書。")
            return "這個箱子裡面有兩本書。"
        }
        let (model, _) = try fixture(dependencies)
        model.receiveIdentifiedCaptionForTesting(.init(startTime: 0, endTime: 2,
            english: "呢個箱入面有兩本書。", sourceLanguage: "yue"))
        await model.translationTaskForTesting?.value
        let caption = try XCTUnwrap(model.segments.first)
        XCTAssertEqual(calls, ["yue"])
        XCTAssertEqual(caption.english, "呢個箱入面有兩本書。")
        XCTAssertEqual(caption.sourceLanguage, "yue")
        XCTAssertEqual(caption.chinese, "这个箱子里面有两本书。")
        XCTAssertTrue(caption.hasUsableTranslation)
    }

    func testForeignCaptionSkipsEnglishNormalizationProtectionAndHints() async throws {
        var calls: [String] = []
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translateSource = { text, _, language, _, _ in
            calls.append(text)
            XCTAssertEqual(language, "es")
            return "三价铁离子使用 H2O。"
        }
        let (model, _) = try fixture(dependencies)
        let original = "La fórmula F E three plus usa H2O."
        model.receiveIdentifiedCaptionForTesting(.init(startTime: 0, endTime: 2,
            english: original, sourceLanguage: "es"), hints: [.init(kind: .formula, value: "O2")])
        await model.translationTaskForTesting?.value
        XCTAssertEqual(calls, [original])
        XCTAssertEqual(model.segments.first?.english, original)
        XCTAssertEqual(model.segments.first?.chinese, "三价铁离子使用 H2O。")
    }

    func testForeignRecoveryKeepsLanguageAndOriginalText() async throws {
        var attempts: [CaptionTranslationAttempt] = []
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translateSource = { text, _, language, attempt, _ in
            XCTAssertEqual(text, "啲水好凍。")
            XCTAssertEqual(language, "yue")
            attempts.append(attempt)
            return attempt == .standard ? text : "水很涼。"
        }
        let (model, _) = try fixture(dependencies)
        model.receiveIdentifiedCaptionForTesting(.init(startTime: 0, endTime: 2,
            english: "啲水好凍。", sourceLanguage: "yue"))
        await model.translationTaskForTesting?.value
        XCTAssertEqual(attempts, [.standard, .repairContent])
        XCTAssertEqual(model.segments.first?.sourceLanguage, "yue")
        XCTAssertEqual(model.segments.first?.chinese, "水很凉。")
        XCTAssertTrue(model.segments.first?.hasUsableTranslation == true)
    }

    func testForeignEchoNeverBecomesCompletedCaption() async throws {
        var attempts: [CaptionTranslationAttempt] = []
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translateSource = { text, _, _, attempt, _ in attempts.append(attempt); return text }
        let (model, _) = try fixture(dependencies)
        model.receiveIdentifiedCaptionForTesting(.init(startTime: 0, endTime: 2,
            english: "啲水好凍。", sourceLanguage: "yue"))
        await model.translationTaskForTesting?.value
        XCTAssertEqual(attempts, [.standard, .repairContent])
        XCTAssertEqual(model.segments.first?.translationState, .failed)
        XCTAssertEqual(model.segments.first?.chinese, "")
        XCTAssertEqual(model.segments.first?.english, "啲水好凍。")
    }

    func testAdjacentRepairOnlyPairsEnglishWithEnglish() async throws {
        for (previousLanguage, currentLanguage) in [(nil, nil), ("zh", nil), (nil, "zh"), ("es", nil), (nil, "es"), ("yue", nil)] as [(String?, String?)] {
            var singles = 0, adjacent = 0, foreign = 0
            var dependencies = CaptionTranslationDependencies.unavailable
            dependencies.translate = { _, _, _, _, _ in singles += 1; return "铃又响了。" }
            dependencies.translateSource = { _, _, _, _, _ in foreign += 1; return "铃又响了。" }
            dependencies.adjacent = { _, _, _, _, _, _, _, _, _ in
                adjacent += 1
                return .init(previous: nil, current: "铃又响了。", previousRejection: nil, currentRejection: nil)
            }
            let (model, _) = try fixture(dependencies)
            let previousText = previousLanguage == "zh" ? "风停了。" : (previousLanguage == "yue" ? "風停咗。" : "The wind stops.")
            let previous = TranscriptSegment(startTime: 0, endTime: 1, english: previousText,
                chinese: "风停了。", sourceLanguage: previousLanguage)
            model.loadPresentationForTesting(phase: .idle, evidence: [previous])
            model.receiveIdentifiedCaptionForTesting(.init(startTime: 1.5, endTime: 2.5,
                english: currentLanguage == "zh" ? "铃又响了。" : "A bell rings again.", sourceLanguage: currentLanguage))
            await model.translationTaskForTesting?.value
            XCTAssertEqual(adjacent, previousLanguage == nil && currentLanguage == nil ? 1 : 0)
            XCTAssertEqual(singles, previousLanguage != nil && currentLanguage == nil ? 1 : 0)
            XCTAssertEqual(foreign, currentLanguage == "es" ? 1 : 0)
            XCTAssertEqual(model.segments.first, previous)
            XCTAssertTrue(model.segments.last?.hasUsableTranslation == true)
        }
    }

    func testPreviewSkipsAllConfirmedNonEnglishSourcesButKeepsLiveEnglish() throws {
        let (model, _) = try fixture()
        for code in SpokenLanguage.all.map(\.code).filter({ $0 != "en" }) {
            let previous = TranscriptSegment(startTime: 0, endTime: 1, english: "A bell rings.")
            let last = TranscriptSegment(startTime: 1, endTime: 2, english: "合成外语原文。", sourceLanguage: code)
            model.loadPresentationForTesting(phase: .idle, evidence: [previous, last])
            XCTAssertTrue(model.previewTranslationSource.isEmpty)
            model.receiveLivePreviewForTesting("The wind stops.")
            XCTAssertEqual(model.previewTranslationSource, "The wind stops.")
            model.receiveLivePreviewForTesting("")
            XCTAssertTrue(model.previewTranslationSource.isEmpty)
        }
    }

    func testDeferredEnglishRepairKeepsMixedLanguageTopology() async throws {
        var repairCalls = 0
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.adjacent = { _, _, _, context, _, _, _, _, _ in
            XCTAssertEqual(context, "", "Non-English context must not reach the English model request")
            return .init(previous: nil, current: "风终于停了。", previousRejection: nil,
                currentRejection: nil, previousRepairDeferred: true)
        }
        dependencies.repair = { pending in
            repairCalls += 1
            XCTAssertEqual(pending.context.map(\.sourceLanguage), ["zh"])
            return .init(previous: "铃终于响了。", rejection: nil)
        }
        let (model, _) = try fixture(dependencies)
        let chinese = TranscriptSegment(startTime: 0, endTime: 1,
            english: "小船靠岸了。", chinese: "小船靠岸了。", sourceLanguage: "zh")
        let previous = TranscriptSegment(startTime: 1, endTime: 2,
            english: "A bell rings.", chinese: "铃响了。")
        model.loadPresentationForTesting(phase: .idle, evidence: [chinese, previous])
        model.receiveCaptionForTesting("The wind stops.", start: 2.5, end: 3.5)
        await model.translationTaskForTesting?.value
        XCTAssertEqual(repairCalls, 1)
        XCTAssertEqual(model.segments[0], chinese)
        XCTAssertEqual(model.segments[1].chinese, "铃终于响了。")
        XCTAssertEqual(model.segments[2].chinese, "风终于停了。")
    }

    func testCandidateRetirementChecksExplicitLanguageAndKeeps020Inference() async throws {
        for (acceptedCode, candidateCode, legacy, shouldRetire) in [
            ("yue", "zh", false, false), ("yue", "yue", false, true), ("zh", "yue", true, true)
        ] {
            let (_, directory) = try fixture()
            let session = UUID(), id = UUID(), text = "同一行文字。"
            let original = TranscriptSegment(id: id, startTime: 0, endTime: 1,
                english: text, chinese: text, sessionID: session, sourceLanguage: "zh")
            var accepted = TranscriptSegment(id: id, startTime: 0, endTime: 1,
                english: text, chinese: text, sessionID: session, inputRevision: 1, sourceLanguage: acceptedCode)
            if legacy {
                var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(accepted)) as? [String: Any])
                fields.removeValue(forKey: "sourceLanguage")
                accepted = try JSONDecoder().decode(TranscriptSegment.self,
                    from: JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
                XCTAssertEqual(accepted.sourceLanguage, "zh")
                XCTAssertFalse(accepted.hasExplicitSourceLanguage)
            }
            var snapshot = SessionSnapshot(sessionID: session)
            snapshot.inputRevision = 1
            snapshot.segments = [accepted]
            snapshot.revisionHistory = [.init(fromRevision: 0, toRevision: 1, previousSegment: original,
                replacementSegment: accepted, retainedBatches: [], reason: "合成语种确认", transcriptionCandidateText: text)]
            let journal = try DurableTranscriptionJournal(sessionDirectory: directory, sessionID: session)
            var record = TranscriptionWorkRecord(id: id, sessionID: session, ordinal: 0, audioFile: "synthetic.wav",
                startFrame: 0, endFrame: 16000, sampleRate: 16000, start: 0, end: 1,
                captureStart: nil, captureEnd: nil, modelKey: "parakeet", fallbackModelKey: "1.7b", appleEvidence: "")
            record.status = .completed
            record.text = text; record.textLanguage = "zh"
            record.candidateText = text; record.candidateLanguage = candidateCode
            record.candidateOrigin = "sameRangeRevision"
            try journal.put(record)
            let queue = DurableTranscriptionQueue(transcriber: { _, _, _, _ in
                XCTFail("Candidate reconciliation must not recognize audio or load a model")
                throw CancellationError()
            })
            try await queue.configure(directory: directory, sessionID: session, persistent: true,
                identified: true, startPaused: true, handler: { _ in })
            try queue.reconcileAcceptedCandidates(snapshot)
            let reconciled = try XCTUnwrap(queue.records.first)
            XCTAssertEqual(reconciled.candidateText == nil, shouldRetire)
            XCTAssertEqual(reconciled.candidateLanguage, shouldRetire ? nil : candidateCode)
            XCTAssertEqual(reconciled.textLanguage, shouldRetire ? accepted.sourceLanguage : "zh")
            try await queue.pause()
        }
    }

    func testSameRangeReplacementPreservesLanguageAndChineseStaysDirect() throws {
        let (model, _) = try fixture()
        let original = TranscriptSegment(startTime: 0, endTime: 1, english: "小船靠岸了。", sourceLanguage: "zh")
        model.receiveIdentifiedCaptionForTesting(original)
        model.reviseCaptionForTesting(id: original.id, english: "小船已经靠岸。")
        XCTAssertEqual(model.segments.first?.sourceLanguage, "zh")
        XCTAssertEqual(model.segments.first?.chinese, "小船已经靠岸。")
        XCTAssertEqual(model.segments.first?.inputRevision, 1)
        XCTAssertNil(model.translationTaskForTesting)
    }

    func testAcceptedCandidatePreservesLanguageAndRevisionHistory() async throws {
        for (code, text) in [("zh", "小船靠岸了。"), ("yue", "隻船泊好咗。"), ("es", "La barca llegó.")] {
            let (model, directory) = try fixture()
            var snapshot = SessionSnapshot(sessionID: UUID())
            let original = TranscriptSegment(startTime: 0, endTime: 2, english: "A boat arrives.",
                chinese: "一艘小船到了。", sessionID: snapshot.sessionID)
            snapshot.segments = [original]
            snapshot.processing.paused = true
            snapshot.processing.phase = .paused
            _ = try SessionStore(directory: directory).save(snapshot)
            model.loadPresentationForTesting(phase: .idle, evidence: [])
            try await model.openSavedSession(directory, allowAutomaticProcessing: false)
            XCTAssertEqual(model.phase, .saved(directory))
            XCTAssertEqual(model.segments, [original])
            let candidate = TranscriptionCandidate(id: original.id, sessionID: snapshot.sessionID,
                originalText: original.english, text: text, start: 0, end: 2,
                audioURL: directory.appendingPathComponent("synthetic.wav"), origin: "sameRangeRevision", language: code)
            model.receiveTranscriptionNoticeForTesting(.transcriptionCandidate(candidate))
            XCTAssertEqual(model.transcriptionCandidates.count, 1)
            model.acceptTranscriptionCandidate(original.id, editedText: text, expectedOriginal: original.english,
                expectedRevision: 0, expectedCandidate: text, expectedSession: snapshot.sessionID)
            XCTAssertTrue(model.archiveLoading)
            try await eventually { !model.archiveLoading && model.transcriptionCandidates.isEmpty }
            let saved = try XCTUnwrap(SessionStore(directory: directory).load())
            let accepted = try XCTUnwrap(saved.segments.first)
            XCTAssertEqual(accepted.sourceLanguage, code)
            XCTAssertEqual(accepted.english, text)
            XCTAssertEqual(accepted.inputRevision, 1)
            XCTAssertEqual(saved.revisionHistory.first?.previousSegment, original)
            XCTAssertEqual(saved.revisionHistory.first?.replacementSegment.sourceLanguage, code)
            XCTAssertEqual(accepted.chinese, code == "zh" ? text : "")
            XCTAssertEqual(accepted.translationState, code == "zh" ? .completed : .pending)
            XCTAssertNil(model.translationTaskForTesting)
        }
    }

    func testCandidateWithSameTextAndDifferentLanguageIsAccepted() async throws {
        let (model, directory) = try fixture()
        var snapshot = SessionSnapshot(sessionID: UUID())
        let original = TranscriptSegment(startTime: 0, endTime: 2, english: "小船靠岸了。",
            chinese: "小船靠岸了。", sessionID: snapshot.sessionID, sourceLanguage: "zh")
        snapshot.segments = [original]
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        _ = try SessionStore(directory: directory).save(snapshot)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(directory, allowAutomaticProcessing: false)
        XCTAssertEqual(model.phase, .saved(directory))
        XCTAssertEqual(model.segments, [original])
        let candidate = TranscriptionCandidate(id: original.id, sessionID: snapshot.sessionID,
            originalText: original.english, text: original.english, start: 0, end: 2,
            audioURL: directory.appendingPathComponent("synthetic.wav"), origin: "sameRangeRevision", language: "yue")
        model.receiveTranscriptionNoticeForTesting(.transcriptionCandidate(candidate))
        XCTAssertEqual(model.transcriptionCandidates.count, 1)
        model.acceptTranscriptionCandidate(original.id, editedText: candidate.text, expectedOriginal: original.english)
        XCTAssertTrue(model.archiveLoading)
        try await eventually { !model.archiveLoading && model.transcriptionCandidates.isEmpty }
        XCTAssertEqual(model.segments.first?.sourceLanguage, "yue")
        XCTAssertEqual(model.segments.first?.inputRevision, 1)
        XCTAssertEqual(model.segments.first?.translationState, .pending)
        XCTAssertEqual(model.segments.first?.chinese, "")
    }

    func testTranslateCaptionEnglishBoundaryPreservesHintsAttemptAndUpdates() async throws {
        let hints: [AuxiliaryTranslationHint] = [.init(kind: .formula, value: "H2O"),
            .init(kind: .unit, value: "mol·L⁻¹")]
        for language in [nil, "en"] as [String?] {
            for attempt in [CaptionTranslationAttempt.standard, .repairContent] {
                var calls = 0
                var updates: [String] = []
                var dependencies = CaptionTranslationDependencies.unavailable
                dependencies.translate = { text, model, receivedHints, receivedAttempt, update in
                    calls += 1
                    XCTAssertEqual(text, "Use H2O at 1 mol·L⁻¹.")
                    XCTAssertEqual(model, "english-boundary-model")
                    XCTAssertEqual(receivedHints, hints)
                    XCTAssertEqual(receivedAttempt, attempt)
                    await update?("English update bytes: H2O / mol·L⁻¹")
                    return "Boundary result bytes."
                }
                dependencies.translateSource = { _, _, _, _, _ in
                    XCTFail("nil and en must use the unchanged English dependency")
                    throw CancellationError()
                }
                let result = try await dependencies.translateCaption("Use H2O at 1 mol·L⁻¹.",
                    "english-boundary-model", hints, attempt, { updates.append($0) }, sourceLanguage: language)
                XCTAssertEqual(calls, 1)
                XCTAssertEqual(result, "Boundary result bytes.")
                XCTAssertEqual(updates, ["English update bytes: H2O / mol·L⁻¹"])
            }
        }
    }

    func testTranslateCaptionNonEnglishBoundaryPreservesLanguageAttemptAndUpdates() async throws {
        for language in SpokenLanguage.all.map(\.code).filter({ $0 != "en" }) {
            var calls = 0
            var updates: [String] = []
            var dependencies = CaptionTranslationDependencies.unavailable
            dependencies.translate = { _, _, _, _, _ in
                XCTFail("Supported non-English codes must reach the source dependency")
                throw CancellationError()
            }
            dependencies.translateSource = { text, model, code, attempt, update in
                calls += 1
                XCTAssertEqual(text, "原文：H2O / mol·L⁻¹")
                XCTAssertEqual(model, "source-boundary-model")
                XCTAssertEqual(code, language)
                XCTAssertEqual(attempt, .repairContent)
                await update?("原样回调：\(language)")
                return "原样返回：\(language)"
            }
            let result = try await dependencies.translateCaption("原文：H2O / mol·L⁻¹", "source-boundary-model",
                [.init(kind: .formula, value: "Fe3+")], .repairContent, { updates.append($0) },
                sourceLanguage: language)
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(result, "原样返回：\(language)")
            XCTAssertEqual(updates, ["原样回调：\(language)"])
        }
    }

    func testLiveSourceAdapterForwardsClientArgumentsAndUpdates() async throws {
        for attempt in [CaptionTranslationAttempt.standard, .repairContent] {
            var calls = 0
            var updates: [String] = []
            let translator = CaptionTranslationDependencies.sourceTranslator { text, model, language, hints, mappedAttempt, update in
                calls += 1
                XCTAssertEqual(text, "呢個箱入面有兩本書。")
                XCTAssertEqual(model, "source-mapping-model")
                XCTAssertEqual(language, "yue")
                XCTAssertTrue(hints.isEmpty, "The live non-English adapter must not add English hints")
                XCTAssertEqual(mappedAttempt, attempt)
                await update?("這個箱子裡面有兩本書。")
                return "Client result bytes."
            }
            let result = try await translator("呢個箱入面有兩本書。", "source-mapping-model", "yue", attempt,
                { updates.append($0) })
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(result, "Client result bytes.")
            XCTAssertEqual(updates, ["這個箱子裡面有兩本書。"])
        }
    }

    func testLiveSourceAdapterKeepsNilUpdateAndClientFailure() async throws {
        let translator = CaptionTranslationDependencies.sourceTranslator { _, _, _, _, _, update in
            XCTAssertNil(update)
            throw QwenRuntimeError.invalidResponse
        }
        do {
            _ = try await translator("La hoja crece.", "source-mapping-model", "es", .standard, nil)
            XCTFail("The live adapter must propagate a client failure")
        } catch QwenRuntimeError.invalidResponse {
            // This exact client failure must survive the adapter.
        }
    }

    func testDeferredRepairEnglishContextExcludesMixedSourcesWithoutChangingTopology() {
        let context = [
            TranscriptSegment(startTime: 0, endTime: 1, english: "The lecture starts."),
            TranscriptSegment(startTime: 1, endTime: 2, english: "小船靠岸了。", sourceLanguage: "zh"),
            TranscriptSegment(startTime: 2, endTime: 3, english: "La barca llegó.", sourceLanguage: "es"),
            TranscriptSegment(startTime: 3, endTime: 4, english: "隻船泊好咗。", sourceLanguage: "yue"),
            TranscriptSegment(startTime: 4, endTime: 5, english: "The lecture ends.", sourceLanguage: "en")
        ]
        XCTAssertEqual(DeferredCaptionRepair.englishContext(context), "The lecture starts. The lecture ends.")
        XCTAssertEqual(DeferredCaptionRepair.englishContext(Array(context[1...3])), "")
        XCTAssertEqual(DeferredCaptionRepair.englishContext([]), "")
        XCTAssertEqual(context.map(\.english), ["The lecture starts.", "小船靠岸了。", "La barca llegó.",
            "隻船泊好咗。", "The lecture ends."])
        XCTAssertEqual(context.map(\.sourceLanguage), [nil, "zh", "es", "yue", nil])
    }

    func testEditedCandidateMatchingOriginalKeepsLanguageAndDoesNotCreateRevision() async throws {
        for (text, language) in [("The reaction is fast.", nil), ("隻船泊好咗。", "yue")] as [(String, String?)] {
            let (model, directory, original) = try await step6OpenSavedOriginal(text, language: language)
            model.receiveTranscriptionNoticeForTesting(.identifiedFinal(try step6CandidateCommit(original,
                text: "La réaction est rapide.", language: "fr")))
            try await eventually { model.transcriptionCandidates.count == 1 }
            model.acceptTranscriptionCandidate(original.id, editedText: original.english,
                expectedOriginal: original.english, expectedCandidate: "La réaction est rapide.")
            try await eventually { model.transcriptionCandidates.isEmpty }
            XCTAssertNil(model.archiveError)
            XCTAssertFalse(model.archiveLoading)
            XCTAssertEqual(model.segments, [original])
            XCTAssertTrue(model.translationQueueForTesting.isEmpty)
            let saved = try XCTUnwrap(SessionStore(directory: directory).load())
            XCTAssertEqual(saved.inputRevision, 0)
            XCTAssertTrue(saved.revisionHistory.isEmpty)
            let journal = try DurableTranscriptionJournal(sessionDirectory: directory,
                sessionID: try XCTUnwrap(original.sessionID))
            let record = try XCTUnwrap(journal.record(id: original.id))
            XCTAssertNil(record.candidateText)
            XCTAssertEqual(record.textLanguage, language)
            XCTAssertEqual(record.text, text)
        }
    }

    func testEditedEnglishCandidateKeepsEnglishInArchiveJournalAndReopen() async throws {
        let (model, directory, original) = try await step6OpenSavedOriginal("The reaction is fast.")
        model.receiveTranscriptionNoticeForTesting(.identifiedFinal(try step6CandidateCommit(original,
            text: "La réaction est rapide.", language: "fr")))
        try await eventually { model.transcriptionCandidates.count == 1 }
        model.acceptTranscriptionCandidate(original.id, editedText: "The reaction is very fast.",
            expectedOriginal: original.english, expectedCandidate: "La réaction est rapide.")
        XCTAssertTrue(model.archiveLoading)
        try await eventually { !model.archiveLoading }
        XCTAssertNil(model.archiveError)
        XCTAssertTrue(model.transcriptionCandidates.isEmpty)
        XCTAssertNil(model.segments.first?.sourceLanguage)
        XCTAssertEqual(model.segments.first?.english, "The reaction is very fast.")
        XCTAssertEqual(model.translationQueueForTesting, [original.id])
        XCTAssertNil(model.translationTaskForTesting, "The saved class remains paused")
        let saved = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertNil(saved.segments.first?.sourceLanguage)
        XCTAssertEqual(saved.revisionHistory.first?.previousSegment, original)
        XCTAssertNil(saved.revisionHistory.first?.replacementSegment.sourceLanguage)
        let journal = try DurableTranscriptionJournal(sessionDirectory: directory,
            sessionID: try XCTUnwrap(original.sessionID))
        let record = try XCTUnwrap(journal.record(id: original.id))
        XCTAssertEqual(record.text, "The reaction is very fast.")
        XCTAssertNil(record.textLanguage)
        XCTAssertNil(record.candidateText)
        try await model.openSavedSession(directory, allowAutomaticProcessing: false)
        XCTAssertEqual(model.segments.first?.english, "The reaction is very fast.")
        XCTAssertNil(model.segments.first?.sourceLanguage)
        XCTAssertTrue(model.transcriptionCandidates.isEmpty)
        XCTAssertNil(model.archiveError)
    }

    func testEditedNonEnglishCandidateKeepsOriginalLanguageInArchiveJournalAndReopen() async throws {
        let (model, directory, original) = try await step6OpenSavedOriginal("隻船泊好咗。", language: "yue")
        model.receiveTranscriptionNoticeForTesting(.identifiedFinal(try step6CandidateCommit(original,
            text: "La barca llegó.", language: "es")))
        try await eventually { model.transcriptionCandidates.count == 1 }
        model.acceptTranscriptionCandidate(original.id, editedText: "隻小船泊好咗。", expectedOriginal: original.english)
        XCTAssertTrue(model.archiveLoading)
        try await eventually { !model.archiveLoading }
        XCTAssertNil(model.archiveError)
        XCTAssertTrue(model.transcriptionCandidates.isEmpty)
        XCTAssertEqual(model.segments.first?.sourceLanguage, "yue")
        XCTAssertEqual(model.segments.first?.english, "隻小船泊好咗。")
        XCTAssertEqual(model.translationQueueForTesting, [original.id])
        let saved = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertEqual(saved.revisionHistory.first?.previousSegment, original)
        XCTAssertEqual(saved.revisionHistory.first?.replacementSegment.sourceLanguage, "yue")
        let journal = try DurableTranscriptionJournal(sessionDirectory: directory,
            sessionID: try XCTUnwrap(original.sessionID))
        let record = try XCTUnwrap(journal.record(id: original.id))
        XCTAssertEqual(record.text, "隻小船泊好咗。")
        XCTAssertEqual(record.textLanguage, "yue")
        XCTAssertNil(record.candidateText)
        try await model.openSavedSession(directory, allowAutomaticProcessing: false)
        XCTAssertEqual(model.segments.first?.sourceLanguage, "yue")
        XCTAssertEqual(model.segments.first?.english, "隻小船泊好咗。")
        XCTAssertTrue(model.transcriptionCandidates.isEmpty)
        XCTAssertNil(model.archiveError)
    }

    func testUneditedSameTextCandidateAdoptsDifferentLanguageThroughProductPath() async throws {
        let text = "第三章：热力学第一定律。"
        let (model, directory, original) = try await step6OpenSavedOriginal(text, language: "zh")
        model.receiveTranscriptionNoticeForTesting(.identifiedFinal(try step6CandidateCommit(original,
            text: text, language: "yue")))
        try await eventually { model.transcriptionCandidates.count == 1 }
        XCTAssertEqual(model.transcriptionCandidates.first?.language, "yue")
        model.acceptTranscriptionCandidate(original.id, editedText: text, expectedOriginal: text,
            expectedCandidate: text, expectedSession: original.sessionID)
        XCTAssertTrue(model.archiveLoading)
        try await eventually { !model.archiveLoading }
        XCTAssertNil(model.archiveError)
        XCTAssertTrue(model.transcriptionCandidates.isEmpty)
        XCTAssertEqual(model.segments.first?.sourceLanguage, "yue")
        XCTAssertEqual(model.segments.first?.inputRevision, 1)
        XCTAssertEqual(model.translationQueueForTesting, [original.id])
        let saved = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertEqual(saved.revisionHistory.first?.previousSegment.sourceLanguage, "zh")
        XCTAssertEqual(saved.revisionHistory.first?.replacementSegment.sourceLanguage, "yue")
        let journal = try DurableTranscriptionJournal(sessionDirectory: directory,
            sessionID: try XCTUnwrap(original.sessionID))
        let record = try XCTUnwrap(journal.record(id: original.id))
        XCTAssertEqual(record.textLanguage, "yue")
        XCTAssertNil(record.candidateText)
    }

    func testPausedChineseCandidateDoesNotEnterQueueAndRendersSimplifiedTarget() async throws {
        let (model, directory, original) = try await step6OpenSavedOriginal("A boat arrives.")
        let text = "這隻小船已經靠岸了。"
        model.receiveTranscriptionNoticeForTesting(.identifiedFinal(try step6CandidateCommit(original,
            text: text, language: "zh")))
        try await eventually { model.transcriptionCandidates.count == 1 }
        model.acceptTranscriptionCandidate(original.id, editedText: text, expectedOriginal: original.english)
        XCTAssertTrue(model.archiveLoading)
        try await eventually { !model.archiveLoading }
        XCTAssertNil(model.archiveError)
        XCTAssertTrue(model.savedProcessingIsPaused)
        XCTAssertTrue(model.transcriptionCandidates.isEmpty)
        XCTAssertFalse(model.translationQueueForTesting.contains(original.id))
        XCTAssertTrue(model.translationQueueForTesting.isEmpty)
        XCTAssertNil(model.translationTaskForTesting)
        XCTAssertEqual(model.segments.first?.english, "這隻小船已經靠岸了。")
        XCTAssertEqual(model.segments.first?.chinese, "这只小船已经靠岸了。")
        XCTAssertEqual(model.segments.first?.translationState, .completed)
        let saved = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertFalse(saved.processing.pendingSegmentIDs.contains(original.id))
        XCTAssertEqual(saved.segments.first?.sourceLanguage, "zh")
        XCTAssertEqual(saved.revisionHistory.first?.replacementSegment.chinese, "这只小船已经靠岸了。")
    }

    func testIdentifiedFinalUsesTargetForChineseAndKeepsForeignSourceLanguage() async throws {
        var codes: [String] = []
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translateSource = { text, _, language, _, _ in
            codes.append(language)
            XCTAssertEqual(text, "La hoja crece.")
            return "叶子长大了。"
        }
        let (model, _) = try fixture(dependencies)
        model.receiveTranscriptionNoticeForTesting(.final(text: "這片葉子長大了。", start: 0, end: 1,
            hints: [], language: "zh"))
        let session = try XCTUnwrap(model.segments.first?.sessionID)
        XCTAssertEqual(model.segments.first?.english, "這片葉子長大了。")
        XCTAssertEqual(model.segments.first?.chinese, "这片叶子长大了。")
        XCTAssertTrue(model.translationQueueForTesting.isEmpty)
        let commit = TranscriptionCommit(id: UUID(), sessionID: session, text: "La hoja crece.", start: 1, end: 2,
            startFrame: 16000, endFrame: 32000, sampleRate: 16000, hints: [], isRepair: false, language: "es")
        model.receiveTranscriptionNoticeForTesting(.identifiedFinal(commit))
        await model.translationTaskForTesting?.value
        model.receiveTranscriptionNoticeForTesting(.identifiedFinal(commit))
        XCTAssertEqual(codes, ["es"])
        XCTAssertEqual(model.segments.count, 2)
        XCTAssertEqual(model.segments.last?.id, commit.id)
        XCTAssertEqual(model.segments.last?.sourceLanguage, "es")
        XCTAssertEqual(model.segments.last?.english, "La hoja crece.")
        XCTAssertEqual(model.segments.last?.chinese, "叶子长大了。")
    }

    func testRestoredPendingChineseDrainsWithoutCallingEitherTranslator() async throws {
        var englishCalls = 0, sourceCalls = 0
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translate = { _, _, _, _, _ in englishCalls += 1; return "错误的英文路径。" }
        dependencies.translateSource = { _, _, _, _, _ in sourceCalls += 1; return "错误的原语言路径。" }
        let (model, directory) = try fixture(dependencies)
        var snapshot = SessionSnapshot()
        let caption = TranscriptSegment(startTime: 0, endTime: 2, english: "這片葉子長大了。",
            sessionID: snapshot.sessionID, sourceLanguage: "zh")
        snapshot.segments = [caption]
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        snapshot.processing.pendingSegmentIDs = [caption.id]
        // Retained notes cover the caption so this regression only drains captions.
        var covered = caption
        covered.completeTranslation("这片叶子长大了。")
        var notebook = LearningNotebook()
        try notebook.append(evidence: [covered], note: .init(topic: "已保存的课堂过渡", points: [],
            sourceVersion: 2, noNewKnowledge: true))
        notebook.writeState(to: &snapshot)
        _ = try SessionStore(directory: directory).save(snapshot)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(directory, allowAutomaticProcessing: false)
        XCTAssertEqual(model.segments.first?.translationState, .pending)
        model.resumeSavedProcessing()
        try await eventually { model.segments.first?.hasUsableTranslation == true }
        await model.translationTaskForTesting?.value
        await model.savedProcessingTaskForTesting?.value
        XCTAssertNil(model.archiveError)
        XCTAssertEqual(englishCalls, 0)
        XCTAssertEqual(sourceCalls, 0)
        XCTAssertEqual(model.segments.first?.english, "這片葉子長大了。")
        XCTAssertEqual(model.segments.first?.chinese, "这片叶子长大了。")
        XCTAssertTrue(model.translationQueueForTesting.isEmpty)
        let saved = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertEqual(saved.segments.first?.translationState, .completed)
        XCTAssertFalse(saved.processing.pendingSegmentIDs.contains(caption.id))
    }

    func testRestoredMixedPendingRepairsReachLanguageGuardBeforeGenerating() async throws {
        let cases: [(String?, String?, String?, String?)] = [
            ("yue", nil, "yue", nil), (nil, "es", nil, "es"),
            (nil, nil, "yue", nil), (nil, nil, nil, "es")
        ]
        for (pendingPreviousLanguage, pendingCurrentLanguage, livePreviousLanguage, liveCurrentLanguage) in cases {
            var repairCalls = 0
            var dependencies = CaptionTranslationDependencies.unavailable
            dependencies.repair = { _ in
                repairCalls += 1
                return .init(previous: "不应出现的补修。", rejection: nil)
            }
            let (model, directory) = try fixture(dependencies)
            var snapshot = SessionSnapshot()
            let previous = TranscriptSegment(startTime: 0, endTime: 1, english: "A bell rings.",
                chinese: "铃响了。", sessionID: snapshot.sessionID, sourceLanguage: pendingPreviousLanguage)
            let current = TranscriptSegment(startTime: 1, endTime: 2, english: "The wind stops.",
                chinese: "风停了。", sessionID: snapshot.sessionID, sourceLanguage: pendingCurrentLanguage)
            let pending = DeferredCaptionRepair(sessionID: snapshot.sessionID, previous: previous, current: current,
                context: [], normalizedCurrent: current.english, modelName: "synthetic-repair-model")
            snapshot.segments = [
                .init(id: previous.id, startTime: 0, endTime: 1, english: previous.english,
                    chinese: previous.chinese, sessionID: snapshot.sessionID, sourceLanguage: livePreviousLanguage),
                .init(id: current.id, startTime: 1, endTime: 2, english: current.english,
                    chinese: current.chinese, sessionID: snapshot.sessionID, sourceLanguage: liveCurrentLanguage)
            ]
            XCTAssertEqual(pending.previousIndex(in: snapshot.segments, session: snapshot.sessionID), 0,
                "The job must pass topology validation so the language guard is actually reached")
            snapshot.processing.pendingCaptionRepairs = [pending]
            snapshot.processing.paused = true
            snapshot.processing.phase = .paused
            var notebook = LearningNotebook()
            try notebook.append(evidence: snapshot.segments, note: .init(topic: "已保存的课堂过渡", points: [],
                sourceVersion: 2, noNewKnowledge: true))
            notebook.writeState(to: &snapshot)
            _ = try SessionStore(directory: directory).save(snapshot)
            model.loadPresentationForTesting(phase: .idle, evidence: [])
            try await model.openSavedSession(directory, allowAutomaticProcessing: false)
            XCTAssertEqual(pending.previousIndex(in: model.segments, session: snapshot.sessionID), 0)
            model.resumeSavedProcessing()
            try await eventually { !model.savedProcessingIsPaused }
            await model.translationTaskForTesting?.value
            await model.savedProcessingTaskForTesting?.value
            XCTAssertNil(model.archiveError)
            XCTAssertEqual(repairCalls, 0)
            XCTAssertEqual(model.segments, snapshot.segments)
            XCTAssertTrue(model.translationQueueForTesting.isEmpty)
            let saved = try XCTUnwrap(SessionStore(directory: directory).load())
            XCTAssertNil(saved.processing.pendingCaptionRepairs)
            XCTAssertTrue(saved.revisionHistory.isEmpty)
        }
    }

    func testCantoneseStreamingEchoIsHiddenAndTraditionalDraftIsShownSimplified() async throws {
        let afterEcho = Step6CaptionHold<Void>()
        let afterDraft = Step6CaptionHold<String>()
        let source = "呢個箱入面有兩本書。"
        let traditional = "這個箱子裡面有兩本書。"
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translateSource = { text, _, language, _, update in
            XCTAssertEqual(language, "yue")
            XCTAssertEqual(text, source)
            await update?(text)
            _ = try await afterEcho.wait()
            await update?(traditional)
            return try await afterDraft.wait()
        }
        let (model, _) = try fixture(dependencies)
        addTeardownBlock {
            await afterEcho.finish(.failure(CancellationError()))
            await afterDraft.finish(.failure(CancellationError()))
        }
        model.receiveTranscriptionNoticeForTesting(.final(text: source, start: 0, end: 2, hints: [], language: "yue"))
        let id = try XCTUnwrap(model.segments.first?.id)
        try await eventually { afterEcho.entered }
        XCTAssertEqual(model.translatingSegmentID, id)
        XCTAssertTrue(model.streamingChinese.isEmpty, "A source echo must not become a visible streaming caption")
        XCTAssertEqual(model.segments.first?.translationState, .translating)
        afterEcho.finish(.success(()))
        try await eventually { afterDraft.entered }
        XCTAssertEqual(model.translatingSegmentID, id)
        XCTAssertEqual(model.streamingChinese, "这个箱子里面有两本书。")
        XCTAssertEqual(model.segments.first?.translationState, .translating)
        XCTAssertEqual(model.segments.first?.chinese, "", "Streaming text must stay out of the saved caption")
        XCTAssertEqual(model.segments.first?.english, source)
        afterDraft.finish(.success(traditional))
        await model.translationTaskForTesting?.value
        XCTAssertEqual(model.segments.first?.chinese, "这个箱子里面有两本书。")
        XCTAssertEqual(model.segments.first?.translationState, .completed)
    }

    func testReopenReconcilesSavedEditedRevisionBeforeReplayingInterruptedJournal() async throws {
        let sources: [(String?, String, String)] = [
            (nil, "A boat arrives.", "A small boat arrives."),
            ("yue", "隻船泊好咗。", "隻小船泊好咗。")
        ]
        for (language, originalText, acceptedText) in sources {
            for textAlreadyWritten in [false, true] {
                let (model, directory) = try fixture()
                var snapshot = SessionSnapshot(inputRevision: 1)
                let original = TranscriptSegment(startTime: 0, endTime: 2, english: originalText,
                    chinese: "小船到了。", sessionID: snapshot.sessionID, sourceLanguage: language)
                let accepted = TranscriptSegment(id: original.id, startTime: 0, endTime: 2, english: acceptedText,
                    sessionID: snapshot.sessionID, inputRevision: 1, sourceLanguage: language)
                snapshot.segments = [accepted]
                snapshot.revisionHistory = [.init(fromRevision: 0, toRevision: 1, previousSegment: original,
                    replacementSegment: accepted, retainedBatches: [], reason: "用户确认补转文字",
                    confirmedAt: Date(timeIntervalSince1970: 0),
                    transcriptionCandidateText: "La barca llegó.")]
                snapshot.processing.paused = true
                snapshot.processing.phase = .paused
                snapshot.audioFiles = [.init(relativePath: SessionWorkspace.recordingFileName,
                    sampleRate: 16000, channelCount: 1, frameCount: 32000, isFinalized: true)]
                _ = try SessionStore(directory: directory).save(snapshot)
                let journal = try DurableTranscriptionJournal(sessionDirectory: directory, sessionID: snapshot.sessionID)
                var record = TranscriptionWorkRecord(id: original.id, sessionID: snapshot.sessionID, ordinal: 0,
                    audioFile: "synthetic.wav", startFrame: 0, endFrame: 32000, sampleRate: 16000, start: 0, end: 2,
                    captureStart: nil, captureEnd: nil, modelKey: "parakeet", fallbackModelKey: "1.7b", appleEvidence: "")
                record.status = .completed
                record.text = textAlreadyWritten ? acceptedText : originalText
                record.textLanguage = language
                record.candidateText = "La barca llegó."
                record.candidateLanguage = "es"
                record.candidateOrigin = "sameRangeRevision"
                try journal.put(record)
                model.loadPresentationForTesting(phase: .idle, evidence: [])
                try await model.openSavedSession(directory, allowAutomaticProcessing: false)
                XCTAssertNil(model.archiveError)
                XCTAssertEqual(model.segments, [accepted])
                XCTAssertTrue(model.savedProcessingIsPaused)
                XCTAssertTrue(model.transcriptionCandidates.isEmpty,
                    "The journal must be reconciled before restore emits stale conflicts or candidates")
                let restored = try XCTUnwrap(model.savedTranscriptionWork.first)
                XCTAssertEqual(restored.text, acceptedText)
                XCTAssertEqual(restored.textLanguage, language)
                XCTAssertNil(restored.candidateText)
                XCTAssertEqual(restored.status, .completed)
                let persistedJournal = try DurableTranscriptionJournal(sessionDirectory: directory,
                    sessionID: snapshot.sessionID)
                XCTAssertEqual(persistedJournal.record(id: original.id), restored)
                let saved = try XCTUnwrap(SessionStore(directory: directory).load())
                XCTAssertEqual(saved.revisionHistory, snapshot.revisionHistory)
                try await model.openSavedSession(directory, allowAutomaticProcessing: false)
                XCTAssertNil(model.archiveError)
                XCTAssertEqual(model.segments, [accepted])
                XCTAssertTrue(model.transcriptionCandidates.isEmpty)
            }
        }
    }

    /// Only archive/journal setup lives here; tests deliver identifiedFinal and
    /// accept the resulting durable candidate through the production methods.
    private func step6OpenSavedOriginal(_ text: String, language: String? = nil) async throws -> (AppModel, URL, TranscriptSegment) {
        let (model, directory) = try fixture()
        var snapshot = SessionSnapshot()
        let original = TranscriptSegment(startTime: 0, endTime: 2, english: text,
            chinese: "原有译文。", sessionID: snapshot.sessionID, sourceLanguage: language)
        snapshot.segments = [original]
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        snapshot.audioFiles = [.init(relativePath: SessionWorkspace.recordingFileName,
            sampleRate: 16000, channelCount: 1, frameCount: 32000, isFinalized: true)]
        _ = try SessionStore(directory: directory).save(snapshot)
        let journal = try DurableTranscriptionJournal(sessionDirectory: directory, sessionID: snapshot.sessionID)
        var record = TranscriptionWorkRecord(id: original.id, sessionID: snapshot.sessionID, ordinal: 0,
            audioFile: "synthetic.wav", startFrame: 0, endFrame: 32000, sampleRate: 16000, start: 0, end: 2,
            captureStart: nil, captureEnd: nil, modelKey: "parakeet", fallbackModelKey: "1.7b", appleEvidence: "")
        record.status = .completed
        record.text = text
        record.textLanguage = language
        try journal.put(record)
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(directory, allowAutomaticProcessing: false)
        return (model, directory, original)
    }

    private func step6CandidateCommit(_ original: TranscriptSegment, text: String, language: String?) throws -> TranscriptionCommit {
        .init(id: original.id, sessionID: try XCTUnwrap(original.sessionID), text: text, start: 0, end: 2,
            startFrame: 0, endFrame: 32000, sampleRate: 16000, hints: [], isRepair: true, language: language)
    }
}

@MainActor
private final class Step6CaptionHold<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private(set) var entered = false

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation {
            continuation = $0
            entered = true
        }
    }

    func finish(_ result: Result<Value, Error>) {
        let held = continuation
        continuation = nil
        held?.resume(with: result)
    }
}
