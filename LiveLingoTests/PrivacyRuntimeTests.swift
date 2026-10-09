import AppKit
import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class PrivacyRuntimeTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-Privacy-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testP01LiveOnlyNotesDoNotRetainCheckpoints() async throws {
        let directory = try root()
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        addTeardownBlock { try cleanup.remove(defaults) }
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled, generate: { _, _, _, _, _ in throw CancellationError() })
        addTeardownBlock { await queue.shutdownForTesting() }
        var observed: [Bool] = []
        let model = AppModel(reviewQueue: queue,
            notes: .init(generate: { _, _, _, _, _ in
                observed.append(MLXRequestContext.retainsCheckpoint)
                return #"{"sourceVersion":2,"topic":"合成知识","points":[{"kind":"核心结论","text":"合成测试中能量保持守恒。","sourceIDs":["zh0s0","zh1s0"]}]}"#
            }), backgroundServices: false, scheduledNotes: false, defaults: defaults)
        model.selectedStorageMode = .liveOnly
        model.loadPresentationForTesting(phase: .recording, evidence: [
            .init(startTime: 0, endTime: 8, english: "合成测试中能量保持守恒。", chinese: "合成测试中能量保持守恒。", sourceLanguage: "zh"),
            .init(startTime: 8, endTime: 16, english: "合成系统的总能量不会改变。", chinese: "合成系统的总能量不会改变。", sourceLanguage: "zh")
        ])
        model.configureNoteSchedulingForTesting(now: { 1_000 }, sleep: { _ in throw CancellationError() })
        await model.generateSummaryForTesting()
        XCTAssertEqual(observed, [false])
        XCTAssertFalse(model.lectureSummary.isEmpty)
        model.selectedStorageMode = .saveSession
        model.loadPresentationForTesting(phase: .recording, evidence: [
            .init(startTime: 0, endTime: 8, english: "合成测试中能量保持守恒。", chinese: "合成测试中能量保持守恒。", sourceLanguage: "zh"),
            .init(startTime: 8, endTime: 16, english: "合成系统的总能量不会改变。", chinese: "合成系统的总能量不会改变。", sourceLanguage: "zh")
        ])
        await model.generateSummaryForTesting()
        XCTAssertEqual(observed, [false, true], "Saved courses keep resumable checkpoint behavior")
    }

    func testP03ReviewFailuresDoNotEchoPlainTextPathsOrDomains() throws {
        let marker = "SYNTHETIC_PRIVATE_CONTENT"
        for error in [
            QwenRuntimeError.requestFailed(marker) as Error,
            QwenRuntimeError.modelUnavailable(marker),
            NSError(domain: marker, code: 7, userInfo: [NSLocalizedDescriptionKey: marker]),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                userInfo: [NSFilePathErrorKey: "/synthetic/" + marker])
        ] {
            let failure = ReviewFailure.classify(error, defaultStage: .generation)
            XCTAssertFalse(failure.description.contains(marker))
            XCTAssertFalse(failure.logLine.contains(marker))
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(failure.description), as: UTF8.self).contains(marker))
        }
        XCTAssertFalse(ReviewFailure.sanitized(marker).contains(marker))
    }

    func testP03WorkerMetadataRejectsArbitraryDetailAndIdentifiers() throws {
        let marker = "SYNTHETIC_PRIVATE_CONTENT"
        let known = try XCTUnwrap(ReviewFailure.parseWorkerMessage(
            "review failure stage=schema code=missing_field field=note.points[0].text detail=" + marker))
        XCTAssertEqual(known.code, "missing_field")
        XCTAssertEqual(known.field, "note.points[0].text")
        XCTAssertFalse(known.description.contains(marker))
        let arbitrary = try XCTUnwrap(ReviewFailure.parseWorkerMessage(
            "review failure stage=generation code=\(marker) field=\(marker) detail=\(marker)"))
        XCTAssertFalse(arbitrary.logLine.contains(marker))
        XCTAssertFalse(arbitrary.description.contains(marker))
    }

    func testP03RecordingDiagnosticsKeepCountsAndHashWithoutCandidateOrError() throws {
        let directory = try root()
        let marker = "SYNTHETIC_PRIVATE_CONTENT"
        RecordingDiagnostics.append(recordingURL: directory.appendingPathComponent("recording.wav"),
            event: "transcription_missing", start: 1, end: 2, detail: marker, candidate: marker, reason: .error)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("transcription-issues.jsonl"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(marker))
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(row["detail"])
        XCTAssertNil(row["candidate"])
        XCTAssertEqual(row["candidateBytes"] as? Int, marker.utf8.count)
        XCTAssertEqual((row["candidateSHA256"] as? String)?.count, 64)
    }

    func testP04DefaultReviewSnapshotContainsMetadataOnly() throws {
        let directory = try root()
        let marker = "SYNTHETIC_PRIVATE_CONTENT"
        let store = ReviewDiagnosticsStore(directory: directory, policy: .standard)
        let snapshot = ReviewDiagnosticSnapshot(createdAt: "2026-01-01T00:00:00Z", jobID: UUID().uuidString,
            batch: 0, batchCount: 1, stage: "decode", code: "invalid_json", detail: marker,
            inputBytes: marker.utf8.count, responseBytes: marker.utf8.count, prefixBytes: 0,
            input: marker, finalResponse: marker)
        let url = try XCTUnwrap(store.write(snapshot))
        let bytes = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(marker))
        let record = try JSONDecoder().decode(ReviewDiagnosticSnapshot.self, from: bytes)
        XCTAssertNil(record.input)
        XCTAssertNil(record.finalResponse)
        XCTAssertEqual(record.inputBytes, marker.utf8.count)
        XCTAssertEqual(record.responseBytes, marker.utf8.count)
        XCTAssertEqual(record.inputOmitted, true)
        XCTAssertEqual(record.responseOmitted, true)
    }

    func testP04ContentSnapshotsRequireExplicitDebuggingPolicy() throws {
        let directory = try root()
        var policy = ReviewDiagnosticsPolicy.standard
        policy.includesContent = true
        let store = ReviewDiagnosticsStore(directory: directory, policy: policy)
        let snapshot = ReviewDiagnosticSnapshot(createdAt: "2026-01-01T00:00:00Z", jobID: UUID().uuidString,
            batch: 0, batchCount: 1, stage: "decode", code: "invalid_json", detail: "",
            inputBytes: 15, responseBytes: 16, prefixBytes: 0,
            input: "Synthetic input", finalResponse: "Synthetic answer")
        let record = try JSONDecoder().decode(ReviewDiagnosticSnapshot.self,
            from: Data(contentsOf: try XCTUnwrap(store.write(snapshot))))
        XCTAssertEqual(record.input, "Synthetic input")
        XCTAssertEqual(record.finalResponse, "Synthetic answer")
        XCTAssertEqual(record.inputSHA256?.count, 64)
        XCTAssertEqual(record.responseSHA256?.count, 64)
        XCTAssertFalse(ReviewDiagnosticsPolicy.standard.includesContent)
    }

    func testP02ApplicationExitClearsLiveOnlyFilesAndContent() async throws {
        let directory = try SessionWorkspace.makeTemporarySessionDirectory()
        defer { try? SessionWorkspace.discardTemporarySession(directory) }
        try Data("Synthetic recording".utf8).write(to: directory.appendingPathComponent("recording.wav"))
        let queueRoot = try root()
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        addTeardownBlock { try cleanup.remove(defaults) }
        let queue = LearningReviewQueue(journalURL: queueRoot.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled, generate: { _, _, _, _, _ in throw CancellationError() })
        addTeardownBlock { await queue.shutdownForTesting() }
        let model = AppModel(reviewQueue: queue, backgroundServices: false, defaults: defaults)
        model.beginLiveOnlyCourseForTesting(directory: directory)
        model.loadPresentationForTesting(phase: .recording, evidence: [
            .init(startTime: 0, endTime: 1, english: "Synthetic private content", chinese: "合成内容")
        ], preview: "Synthetic preview")
        let exited = await model.prepareForApplicationExit()
        XCTAssertTrue(exited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(model.segments.isEmpty)
        XCTAssertTrue(model.volatileEnglish.isEmpty)
        XCTAssertTrue(model.lectureSummary.isEmpty)
    }

    func testP02TerminationWaitsForCleanupAndRejectsFailedCleanup() async throws {
        for allowed in [true, false] {
            let delegate = AppLifecycleDelegate()
            var gate: CheckedContinuation<Void, Never>?
            var reply: Bool?
            delegate.cleanupForTesting = {
                await withCheckedContinuation { gate = $0 }
                return allowed
            }
            delegate.replyForTesting = { reply = $0 }
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while gate == nil, ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertNotNil(gate)
            XCTAssertNil(reply)
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            gate?.resume()
            while reply == nil, ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertEqual(reply, allowed)
        }
    }

    func testP02ApplicationExitPreservesSavedCourseAndPausesWriters() async throws {
        let directory = try root()
        let bytes = Data("Synthetic saved recording".utf8)
        let recording = directory.appendingPathComponent("recording.wav")
        try bytes.write(to: recording)
        let queueRoot = try root()
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        addTeardownBlock { try cleanup.remove(defaults) }
        let queue = LearningReviewQueue(journalURL: queueRoot.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled, generate: { _, _, _, _, _ in throw CancellationError() })
        addTeardownBlock { await queue.shutdownForTesting() }
        let model = AppModel(reviewQueue: queue, backgroundServices: false, defaults: defaults)
        try await model.beginSavedCourseForTesting(directory: directory)
        model.receiveIdentifiedCaptionForTesting(.init(startTime: 0, endTime: 1,
            english: "合成已保存课堂。", chinese: "合成已保存课堂。", sourceLanguage: "zh"))
        let exited = await model.prepareForApplicationExit()
        XCTAssertTrue(exited)
        XCTAssertEqual(try Data(contentsOf: recording), bytes)
        let snapshot = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertTrue(snapshot.processing.paused)
        XCTAssertEqual(snapshot.segments.count, 1)
        XCTAssertEqual(snapshot.segments.first?.english, "合成已保存课堂。")
    }

    func testP02VolatileQueueReleasesBodyWhileSavedQueueKeepsRecovery() async throws {
        for persistent in [false, true] {
            let directory = try root(), sessionID = UUID()
            let journal = try DurableTranscriptionJournal(sessionDirectory: directory, sessionID: sessionID)
            var record = TranscriptionWorkRecord(id: UUID(), sessionID: sessionID, ordinal: 0,
                audioFile: "synthetic.wav", startFrame: 0, endFrame: 16_000, sampleRate: 16_000,
                start: 0, end: 1, captureStart: nil, captureEnd: nil, modelKey: "synthetic",
                fallbackModelKey: nil, appleEvidence: "Synthetic preview")
            record.status = .completed
            record.text = "Synthetic transcription"
            record.candidateText = "Synthetic candidate"
            try journal.put(record)
            let queue = DurableTranscriptionQueue { _, _, _ in
                XCTFail("The completed synthetic work must never load a model")
                throw CancellationError()
            }
            try await queue.configure(directory: directory, sessionID: sessionID,
                persistent: persistent, identified: true) { _ in }
            await queue.cancel()
            queue.discardVolatileContentAfterCancellation()
            XCTAssertEqual(queue.records.count, persistent ? 1 : 0)
            XCTAssertEqual(queue.state == nil, !persistent)
        }
    }
}
