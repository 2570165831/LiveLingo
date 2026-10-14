import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class ChineseRecognitionTests: XCTestCase {
    private func result(_ text: String = "今天讨论二分查找。") -> ASRTranscription {
        .init(text: text, languageMode: .chinese, language: "zh", decode: .forced,
            generatedTokens: 12, policy: 1)
    }

    private func fixture(recognize: ChineseRecognitionDependencies = .unavailable,
                         target: OutputLanguage = .simplifiedChinese,
                         recording: Bool = true) async throws -> (AppModel, URL, TranscriptSegment) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChineseRecognition-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLingo-ChineseRecognition-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in throw CancellationError() }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
            chineseRecognition: recognize, backgroundServices: false, scheduledNotes: false, defaults: defaults)
        model.setReleasedOutputLanguagesForTesting([.simplifiedChinese, .english])
        let session = UUID()
        let segment = TranscriptSegment(startTime: 1, endTime: 3,
            english: "Today we discuss binary search.", chinese: "今天讨论二分查找。", sessionID: session)
        let snapshot = SessionSnapshot(sessionID: session, segments: [segment], targetLocale: target.persistedLocale)
        _ = try SessionStore(directory: directory).save(snapshot)
        if recording { try writeRecording(directory.appendingPathComponent("recording.wav"), frames: 64_000) }
        try await model.openSavedSession(directory, allowAutomaticProcessing: false)
        addTeardownBlock {
            await model.cancelChineseRecognition(segment.id)
            let processing = await model.savedProcessingTaskForTesting
            let summary = await model.summaryTaskForTesting
            await model.resetTranslationSessionForTesting()?.value
            await processing?.value
            await summary?.value
            await queue.shutdownForTesting()
            try cleanup.remove()
            // Keep synthetic course files in this invocation's worker. The
            // runner can move the entire retired worker recoverably, after
            // checking that no writer still owns it.
        }
        return (model, directory, segment)
    }

    private func writeRecording(_ path: URL, frames: Int, growing: Bool = false, rate: Double = 16_000) throws {
        let layout = WAVContextClip.Layout(formatTag: 1, channelCount: 1, sampleRate: rate,
            bitsPerSample: 16, blockAlign: 2, dataOffset: 44, dataByteCount: frames * 2)
        var header = WAVContextClip.header(layout: layout, payloadBytes: growing ? 0 : frames * 2)
        header.append(Data(repeating: 0, count: frames * 2))
        try header.write(to: path)
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < limit else { XCTFail("Expected synthetic state was not reached"); return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func testMissingRecordingDisablesActionAndKeepsOriginal() async throws {
        let (model, _, old) = try await fixture(recording: false)
        let availability = model.chineseRecognitionAvailability(for: old)
        XCTAssertFalse(availability.isAvailable)
        XCTAssertTrue(availability.reason?.contains("录音") == true)
        model.recognizeCaptionAsChinese(old.id)
        XCTAssertEqual(model.segments.first, old)
        XCTAssertNil(model.chineseRecognitionTaskForTesting(old.id))
    }

    func testSuccessPreservesOriginalAndPersistsChineseWithoutTranslation() async throws {
        let expected = result()
        let dependencies = ChineseRecognitionDependencies { audio, requestID in
            XCTAssertTrue(requestID.hasPrefix("chinese-"))
            XCTAssertEqual(try WAVContextClip.readLayout(at: audio).frameCount, 32_000)
            return expected
        }
        let (model, directory, old) = try await fixture(recognize: dependencies)
        model.recognizeCaptionAsChinese(old.id)
        XCTAssertEqual(model.chineseRecognitionState.statuses[old.id], .recognizing)
        await model.chineseRecognitionTaskForTesting(old.id)?.value
        let corrected = try XCTUnwrap(model.segments.first)
        XCTAssertEqual(model.chineseRecognitionState.statuses[old.id], .completed)
        XCTAssertEqual(corrected.english, expected.text)
        XCTAssertEqual(corrected.chinese, expected.text)
        XCTAssertEqual(corrected.sourceLanguage, "zh")
        XCTAssertTrue(corrected.canUndoChineseRecognition)
        XCTAssertEqual(corrected.inputRevision, 1)
        let disk = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertEqual(disk.segments.first, corrected)
        XCTAssertEqual(disk.revisionHistory.first?.previousSegment, old)
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("transcript-en.txt"), encoding: .utf8).contains(expected.text))
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("transcript-en.txt"), encoding: .utf8).contains(old.english))
        try await model.openSavedSession(directory, allowAutomaticProcessing: false)
        XCTAssertTrue(model.segments.first?.canUndoChineseRecognition == true)
        model.undoChineseRecognition(old.id)
        await model.synchronizeChineseRecognitionExportsForTesting()
        let restored = try XCTUnwrap(model.segments.first)
        XCTAssertEqual(restored.english, old.english)
        XCTAssertEqual(restored.chinese, old.chinese)
        XCTAssertFalse(restored.isChineseOriginal)
        XCTAssertEqual(restored.inputRevision, 2)
        XCTAssertEqual(try SessionStore(directory: directory).load()?.segments.first, restored)
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("transcript-en.txt"), encoding: .utf8).contains(old.english))
    }

    func testEnglishOutputStillKeepsManualChineseOriginal() async throws {
        let expected = result("这个 algorithm 的复杂度是 log n。")
        let (model, _, old) = try await fixture(recognize: .init { _, _ in expected }, target: .english)
        model.recognizeCaptionAsChinese(old.id)
        await model.chineseRecognitionTaskForTesting(old.id)?.value
        XCTAssertEqual(model.segments.first?.english, expected.text)
        XCTAssertEqual(model.segments.first?.chinese, expected.text)
        XCTAssertNil(model.translationTaskForTesting)
    }

    /// Replay the measured mixed-speech output against an intentionally fluent
    /// wrong English caption. The offline model receipt binds the actual audio;
    /// this test verifies replacement/undo without loading a model in XCTest.
    func testFluentWrongEnglishCaptionIsReplacedByMeasuredChineseResult() async throws {
        let recognized = "这个 algorithm 叫 binary search，数据增加一倍，只需要多做一次比较。"
        let expected = result(recognized)
        let (model, _, old) = try await fixture(recognize: .init { _, _ in expected })
        let wrong = "The algorithm works well and the result is clear."
        model.reviseCaptionForTesting(id: old.id, english: wrong)
        let before = try XCTUnwrap(model.segments.first)
        model.recognizeCaptionAsChinese(old.id)
        await model.chineseRecognitionTaskForTesting(old.id)?.value
        XCTAssertEqual(model.segments.first?.english, recognized)
        XCTAssertEqual(model.segments.first?.chineseRecognitionOriginal?.english, wrong)
        model.undoChineseRecognition(old.id)
        await model.synchronizeChineseRecognitionExportsForTesting()
        XCTAssertEqual(model.segments.first?.english, before.english)
        XCTAssertEqual(model.segments.first?.chinese, before.chinese)
    }

    func testFailureLeavesOriginalAndArchiveUntouched() async throws {
        let (model, directory, old) = try await fixture(recognize: .init { _, _ in throw QwenRuntimeError.invalidResponse })
        model.recognizeCaptionAsChinese(old.id)
        await model.chineseRecognitionTaskForTesting(old.id)?.value
        guard case .failed(let reason) = model.chineseRecognitionState.statuses[old.id] else { return XCTFail("Expected failed state") }
        XCTAssertTrue(reason.contains("原句未改"))
        XCTAssertEqual(model.segments.first, old)
        XCTAssertEqual(try SessionStore(directory: directory).load()?.segments.first, old)
    }

    func testCancelDiscardsLateSuccessAndAllowsRetry() async throws {
        var continuation: CheckedContinuation<ASRTranscription, Error>?
        let expected = result()
        var calls = 0
        let (model, _, old) = try await fixture(recognize: .init { _, _ in
            calls += 1
            if calls > 1 { return expected }
            return try await withCheckedThrowingContinuation { continuation = $0 }
        })
        model.recognizeCaptionAsChinese(old.id)
        try await eventually { continuation != nil }
        let task = model.chineseRecognitionTaskForTesting(old.id)
        model.cancelChineseRecognition(old.id)
        XCTAssertEqual(model.chineseRecognitionState.statuses[old.id], .cancelled)
        model.recognizeCaptionAsChinese(old.id)
        await model.chineseRecognitionTaskForTesting(old.id)?.value
        continuation?.resume(returning: result("迟到的旧结果。"))
        await task?.value
        XCTAssertEqual(model.segments.first?.english, expected.text)
        XCTAssertEqual(model.chineseRecognitionState.statuses[old.id], .completed)
    }

    func testSwitchingCourseDiscardsLateRecognition() async throws {
        var continuation: CheckedContinuation<ASRTranscription, Error>?
        let (model, _, old) = try await fixture(recognize: .init { _, _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        model.recognizeCaptionAsChinese(old.id)
        try await eventually { continuation != nil }
        let task = model.chineseRecognitionTaskForTesting(old.id)
        await model.resetTranslationSessionForTesting()?.value
        continuation?.resume(returning: result())
        await task?.value
        XCTAssertTrue(model.segments.isEmpty)
        XCTAssertTrue(model.chineseRecognitionState.statuses.isEmpty)
    }

    func testSourceRevisionDuringRecognitionEndsProgressAndKeepsNewSource() async throws {
        var continuation: CheckedContinuation<ASRTranscription, Error>?
        let (model, _, old) = try await fixture(recognize: .init { _, _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        model.recognizeCaptionAsChinese(old.id)
        try await eventually { continuation != nil }
        let task = model.chineseRecognitionTaskForTesting(old.id)
        model.reviseCaptionForTesting(id: old.id, english: "A later explicitly revised source.")
        continuation?.resume(returning: result())
        await task?.value
        XCTAssertEqual(model.segments.first?.english, "A later explicitly revised source.")
        guard case .failed = model.chineseRecognitionState.statuses[old.id] else { return XCTFail("Stale operation must finish its status") }
        XCTAssertNil(model.chineseRecognitionTaskForTesting(old.id))
    }

    func testStoppingLiveCourseCancelsAndJoinsRecognitionBeforeFinalSave() async throws {
        var started = false, cancelled = false
        let expected = result()
        let (model, directory, old) = try await fixture(recognize: .init { _, _ in
            started = true
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled = true; throw error }
            return expected
        })
        model.loadPresentationForTesting(phase: .recording, evidence: [old])
        model.recognizeCaptionAsChinese(old.id)
        try await eventually { started }
        await model.stopSavedCourseForTesting()
        XCTAssertTrue(cancelled)
        XCTAssertEqual(model.chineseRecognitionState.statuses[old.id], .cancelled)
        XCTAssertNil(model.chineseRecognitionTaskForTesting(old.id))
        XCTAssertEqual(model.segments.first?.english, old.english)
        XCTAssertEqual(try SessionStore(directory: directory).load()?.segments.first?.english, old.english)
    }

    func testUndoCannotMutateCaptionWhileStopping() async throws {
        let expected = result()
        let (model, _, old) = try await fixture(recognize: .init { _, _ in expected })
        model.recognizeCaptionAsChinese(old.id)
        await model.chineseRecognitionTaskForTesting(old.id)?.value
        let corrected = try XCTUnwrap(model.segments.first)
        model.loadPresentationForTesting(phase: .stopping, evidence: [corrected])
        model.undoChineseRecognition(old.id)
        XCTAssertEqual(model.segments.first, corrected)
    }

    func testMalformedMetadataAndLoopResultsAreRejected() async throws {
        for invalid in [ASRTranscription(text: "Not an explicit Chinese response."), result(String(repeating: "今天学习", count: 8))] {
            let (model, _, old) = try await fixture(recognize: .init { _, _ in invalid })
            model.recognizeCaptionAsChinese(old.id)
            await model.chineseRecognitionTaskForTesting(old.id)?.value
            XCTAssertEqual(model.segments.first, old)
            guard case .failed = model.chineseRecognitionState.statuses[old.id] else { XCTFail("Quality result must fail"); continue }
        }
    }

    func testGrowingRecordingRequiresCompleteCaptionRange() async throws {
        let (model, directory, old) = try await fixture()
        try writeRecording(directory.appendingPathComponent("recording.wav"), frames: 32_000, growing: true)
        XCTAssertFalse(model.chineseRecognitionAvailability(for: old).isAvailable)
        try writeRecording(directory.appendingPathComponent("recording.wav"), frames: 48_000, growing: true)
        XCTAssertTrue(model.chineseRecognitionAvailability(for: old).isAvailable)
    }

    func testLiveCaptionCanRecognizeAndLiveWithoutAudioIsDisabled() async throws {
        let expected = result()
        let (model, _, old) = try await fixture(recognize: .init { _, _ in expected })
        model.loadPresentationForTesting(phase: .recording, evidence: [old])
        XCTAssertTrue(model.chineseRecognitionAvailability(for: old).isAvailable)
        model.recognizeCaptionAsChinese(old.id)
        await model.chineseRecognitionTaskForTesting(old.id)?.value
        XCTAssertEqual(model.segments.first?.english, expected.text)
        XCTAssertEqual(model.phase, .recording)
        let (noAudio, _, original) = try await fixture(recording: false)
        noAudio.loadPresentationForTesting(phase: .recording, evidence: [original])
        XCTAssertFalse(noAudio.chineseRecognitionAvailability(for: original).isAvailable)
    }

    func testCloudPlaceholderDoesNotDownloadForMenuOrRecognition() async throws {
        let (model, directory, old) = try await fixture()
        let audio = directory.appendingPathComponent("recording.wav")
        try SensitiveFileIO.$datalessProbe.withValue({ $0 == audio }) {
            XCTAssertFalse(model.chineseRecognitionAvailability(for: old).isAvailable)
            XCTAssertThrowsError(try ChineseRecognitionAudio.slice(segment: old, directory: directory, ranges: []))
        }
    }

    func testFrameMetadataWinsOverWallClockAndRejectsEscapingLinks() async throws {
        let (_, directory, old) = try await fixture()
        let range = SessionAudioRange(segmentID: old.id, filePath: "recording.wav", startFrame: 8000,
            frameCount: 16_000, captureStart: 1, captureEnd: 3)
        let slice = try ChineseRecognitionAudio.slice(segment: old, directory: directory, ranges: [range])
        XCTAssertEqual(slice.frames, 8000..<24_000)
        try writeRecording(directory.appendingPathComponent("recording.wav"), frames: 8000)
        XCTAssertThrowsError(try slice.extract(to: directory))
        let link = directory.appendingPathComponent("alias.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("recording.wav"))
        var unsafe = range; unsafe.filePath = "alias.wav"
        XCTAssertThrowsError(try ChineseRecognitionAudio.slice(segment: old, directory: directory, ranges: [unsafe]))
    }

    func testSelectedAudioCannotChangeFormatOrIdentityBeforeExtraction() async throws {
        let (_, directory, old) = try await fixture()
        let recording = directory.appendingPathComponent("recording.wav")
        let slice = try ChineseRecognitionAudio.slice(segment: old, directory: directory, ranges: [])
        try writeRecording(recording, frames: 64_000, rate: 32_000)
        XCTAssertThrowsError(try slice.extract(to: directory))
        try writeRecording(recording, frames: 64_000)
        let selected = try ChineseRecognitionAudio.slice(segment: old, directory: directory, ranges: [])
        try FileManager.default.moveItem(at: recording, to: directory.appendingPathComponent("previous-recording.wav"))
        try writeRecording(recording, frames: 64_000)
        XCTAssertThrowsError(try selected.extract(to: directory))
    }

    func testRetainedExactChunkIsUsableWithoutSessionRecording() async throws {
        let (_, directory, old) = try await fixture(recording: false)
        let chunks = directory.appendingPathComponent(DurableTranscriptionJournal.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        try writeRecording(chunks.appendingPathComponent("retained.wav"), frames: 32_000)
        let record = TranscriptionWorkRecord(id: old.id, sessionID: try XCTUnwrap(old.sessionID), ordinal: 0,
            audioFile: "retained.wav", startFrame: 16_000, endFrame: 48_000, sampleRate: 16_000,
            start: old.startTime, end: old.endTime, captureStart: nil, captureEnd: nil,
            modelKey: "parakeet", fallbackModelKey: "1.7b", appleEvidence: "")
        let slice = try ChineseRecognitionAudio.slice(segment: old, directory: directory, ranges: [], retainedChunks: [record])
        XCTAssertEqual(slice.frames, 0..<32_000)
        XCTAssertEqual(slice.recording.lastPathComponent, "retained.wav")
        let other = TranscriptSegment(startTime: old.startTime, endTime: old.endTime, english: old.english)
        XCTAssertThrowsError(try ChineseRecognitionAudio.slice(segment: other, directory: directory, ranges: [], retainedChunks: [record]))
    }

    func testExplicitChineseTransportHasNoProbeOrEnglishFallbackParameters() async throws {
        let (_, directory, _) = try await fixture()
        let coordinator = ASRRequestCoordinator(transport: { request in
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "language" }?.value, "Chinese")
            XCTAssertEqual(query.first { $0.name == "model" }?.value, "1.7b")
            XCTAssertEqual(query.first { $0.name == "enhance" }?.value, "speech")
            XCTAssertNil(query.first { $0.name == "confirmed_language" })
            XCTAssertFalse(request.httpBody?.isEmpty ?? true)
            let body: [String: Any] = ["request_id": request.value(forHTTPHeaderField: "X-LiveLingo-Request-ID")!,
                "model": "1.7b", "text": "请检查这个 variable。", "language_mode": "explicit", "language": "zh",
                "decode": "forced", "generated_tokens": 10, "truncated": false, "policy": 1]
            return .init(data: try JSONSerialization.data(withJSONObject: body), status: 200)
        }, observeExit: { _ in false })
        let endpoint = ASRRuntime.Endpoint(baseURL: URL(string: "http://127.0.0.1:18765")!, token: "synthetic")
        let response = try await ASRRequestContext.$confirmedSourceLanguage.withValue("es") {
            try await coordinator.transcribe(endpoint: endpoint, audioURL: directory.appendingPathComponent("recording.wav"),
                modelKey: "1.7b", enhanceSpeech: true, language: .chinese, requestID: "explicit-chinese-test")
        }
        XCTAssertEqual(response.languageMode, .chinese)
        XCTAssertEqual(response.language, "zh")
        XCTAssertEqual(response.text, "请检查这个 variable。")
        let probes = await coordinator.languageProbeCount
        XCTAssertEqual(probes, 0)
    }

    func testExplicitResponseRequiresChineseMetadataAndLegacyBytesRemainEnglish() throws {
        let body: [String: Any] = ["language_mode": "explicit", "language": "zh", "decode": "forced",
                                  "generated_tokens": 8, "truncated": false, "policy": 1]
        for (key, value) in [("language", "en" as Any), ("language_mode", "auto" as Any),
                             ("truncated", true as Any), ("generated_tokens", 256 as Any)] {
            var invalid = body; invalid[key] = value
            XCTAssertThrowsError(try ASRTranscription.validated(text: "中文原文。",
                data: JSONSerialization.data(withJSONObject: invalid), requestedLanguage: .chinese))
        }
        let legacy = try ASRTranscription.validated(text: "An unchanged English sentence.", data: Data("{}".utf8), requestedLanguage: .english)
        XCTAssertEqual(legacy, ASRTranscription(text: "An unchanged English sentence."))
    }
}
