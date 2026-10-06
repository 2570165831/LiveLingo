import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class MultilingualAppModelTests: XCTestCase {
    private func fixture(_ translation: CaptionTranslationDependencies = .unavailable) throws -> (AppModel, URL) {
        let directory = URL(fileURLWithPath:
            "/Users/li/Documents/Codex/2026-09-01/ll-claude-lab/work/dd-step6/TestFixtures", isDirectory: true)
            .appendingPathComponent("MultilingualAppModel-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LiveLingo-MultilingualAppModel-\(UUID())"))
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
                XCTFail("Translation tests must not generate notes or start models")
                throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: translation, notes: .unavailable,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
        model.resetTranslationSessionForTesting()
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
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
        XCTAssertEqual(caption.chinese, original)
        XCTAssertEqual(caption.sourceLanguage, "zh")
        XCTAssertEqual(caption.translationState, .completed)
        XCTAssertNil(model.translationTaskForTesting)
        XCTAssertTrue(model.previewTranslationSource.isEmpty)
        XCTAssertTrue(model.previewChinese.isEmpty)
        XCTAssertEqual(model.previewChineseDisplay, original)
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
}
