import Foundation
import XCTest
@testable import LiveLingo

// Acceptance tests for the integrated stability gate. These deliberately use
// AppModel's real saved drain, pause/park, persistence and retry paths. Opening
// a SessionSnapshot with no audio/journal is the CaptionIdentityTests fixture;
// no microphone, transcriber, model runtime or power monitor is started here.
@MainActor
private final class StabilityNoteGate {
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private(set) var entered = false

    func wait() async throws -> String {
        entered = true
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

@MainActor
private final class StabilityNoteProbe {
    let gate: StabilityNoteGate?
    let failFirst: Bool
    let response: String
    private(set) var inputs: [String] = []
    private(set) var translationRequests = 0

    init(captionCount: Int, failFirst: Bool = false, gate: StabilityNoteGate? = nil) {
        self.failFirst = failFirst
        self.gate = gate
        let sources = captionCount == 1 ? #"["en0s0"]"# : #"["en0s0","en1s0"]"#
        response = """
        {"topic":"小车运动","points":[{"kind":"核心结论","text":"B 车的速度为每秒两米。","sourceIDs":\(sources)}]}
        """
    }

    var translation: CaptionTranslationDependencies {
        .init(translate: { [self] _, _, _, _, _ in
            translationRequests += 1
            XCTFail("Usable archived captions must not be translated again")
            throw CancellationError()
        }, adjacent: { [self] _, _, _, _, _, _, _, _, _ in
            translationRequests += 1
            XCTFail("Opening/resuming usable evidence must not request adjacent translation")
            throw CancellationError()
        }, repair: { [self] _ in
            translationRequests += 1
            XCTFail("This archive contains no pending caption repair")
            throw CancellationError()
        })
    }

    func generate(_ input: String) async throws -> String {
        inputs.append(input)
        if inputs.count == 1 {
            if failFirst { throw QwenRuntimeError.invalidResponse }
            if let gate { return try await gate.wait() }
        }
        guard inputs.count <= (failFirst || gate != nil ? 2 : 1) else {
            XCTFail("Covered evidence must not start another note request")
            throw CancellationError()
        }
        return response
    }
}

@MainActor
private final class CaptionLifecycleClock {
    struct Wait {
        let id: UUID
        let deadline: TimeInterval
        let retainOnCancellation: Bool
        let continuation: CheckedContinuation<Void, Error>
        var cancelled = false
    }

    private(set) var now: TimeInterval = 0
    private var waits: [UUID: Wait] = [:]
    private var closed = false
    private(set) var sleepRegistrationCount = 0
    var retainNextCancelledWait = false

    var activeWaits: [Wait] {
        waits.values.filter { !$0.cancelled }.sorted { $0.deadline < $1.deadline }
    }
    var lateCancelledIDs: Set<UUID> {
        Set(waits.values.filter(\.cancelled).map(\.id))
    }

    func sleep(_ delay: TimeInterval) async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        precondition(delay.isFinite && delay > 0, "A note wake must have a future deadline")
        let id = UUID()
        let deadline = now + delay
        let retain = retainNextCancelledWait
        retainNextCancelledWait = false
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // onCancel may enqueue its MainActor hop before registration.
                guard !Task.isCancelled, !closed else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                sleepRegistrationCount += 1
                waits[id] = Wait(id: id, deadline: deadline,
                    retainOnCancellation: retain, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
        // If advance raced the cancellation hop, normal waits must still
        // throw. Only the explicitly adversarial waiter may return success.
        if !retain { try Task.checkCancellation() }
    }

    private func cancel(_ id: UUID) {
        guard var wait = waits[id] else { return }
        if wait.retainOnCancellation && !closed {
            wait.cancelled = true
            waits[id] = wait
        } else {
            waits.removeValue(forKey: id)
            wait.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(to instant: TimeInterval) {
        precondition(instant.isFinite && instant >= now)
        now = instant
        let due = activeWaits.filter { $0.deadline <= instant }
        for wait in due {
            waits.removeValue(forKey: wait.id)
            wait.continuation.resume()
        }
    }

    func deliverLateCancelledSuccess(_ id: UUID) throws {
        let wait = try XCTUnwrap(waits[id])
        XCTAssertTrue(wait.cancelled)
        guard wait.cancelled else { throw CancellationError() }
        waits.removeValue(forKey: id)
        wait.continuation.resume()
    }

    func shutdown() {
        closed = true
        let pending = Array(waits.values)
        waits.removeAll()
        for wait in pending { wait.continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
final class CaptionStabilityLifecycleTests: XCTestCase {
    private func eventually(within timeout: Duration = .seconds(5),
                            file: StaticString = #filePath, line: UInt = #line,
                            _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Saved note lifecycle did not reach the expected state", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func makeArchive(captionCount: Int, captureError: String? = nil,
                             failFirst: Bool = false, gate: StabilityNoteGate? = nil)
        throws -> (model: AppModel, root: URL, snapshot: SessionSnapshot, probe: StabilityNoteProbe, clock: CaptionLifecycleClock) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingo-StabilityLifecycle-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let suite = "LiveLingo-StabilityLifecycle-\(UUID())"
        let preferenceCleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        let probe = StabilityNoteProbe(captionCount: captionCount, failFirst: failFirst, gate: gate)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("review-queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
                XCTFail("Saved note lifecycle tests must not start a review")
                throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: probe.translation,
            notes: .init(generate: { input, _, _, _, _ in try await probe.generate(input) }),
            backgroundServices: false, scheduledNotes: true, defaults: defaults)
        model.resetTranslationSessionForTesting()
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        let clock = CaptionLifecycleClock()
        model.configureNoteSchedulingForTesting(now: { clock.now },
            sleep: { try await clock.sleep($0) }, allowConcurrent: false)

        addTeardownBlock { @MainActor [self] in
            clock.shutdown()
            try await cleanup(model: model, queue: queue, root: root, preferenceCleanup: preferenceCleanup, gate: gate)
        }
        var snapshot = SessionSnapshot()
        snapshot.segments = [TranscriptSegment(startTime: 0, endTime: 8,
            english: "Cart B moves at two metres per second.", chinese: "B 车的速度为每秒两米。",
            sessionID: snapshot.sessionID)]
        if captionCount == 2 {
            snapshot.segments.append(TranscriptSegment(startTime: 8, endTime: 16,
                english: "Cart B keeps this speed for the whole journey.", chinese: "B 车全程保持该速度。",
                sessionID: snapshot.sessionID))
        }
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        if let captureError { snapshot.processing.recordFailure(captureError, source: .capture) }
        _ = try SessionStore(directory: root).save(snapshot)
        XCTAssertTrue(snapshot.segments.allSatisfy(\.hasUsableTranslation))
        XCTAssertTrue(snapshot.audioFiles.isEmpty)
        XCTAssertTrue(snapshot.audioRanges.isEmpty)
        XCTAssertNil(snapshot.transcriptionJournalPath)
        return (model, root, snapshot, probe, clock)
    }

    private func park(_ model: AppModel) async throws {
        // Capture handles before pause invalidates the public task slots.
        let processing = model.savedProcessingTaskForTesting
        let translation = model.translationTaskForTesting
        let summary = model.summaryTaskForTesting
        let wake = model.summaryWakeTaskForTesting
        model.pauseSavedProcessing()
        // pauseSavedProcessing launches its own MainActor task. An already
        // paused archive must still let that task enter the flush/park path;
        // otherwise nil task slots could incorrectly look like a finished park.
        try await Task.sleep(for: .milliseconds(2))
        try await eventually { model.savedProcessingIsPaused }
        try await model.savedPauseTaskForTesting?.value
        await processing?.value
        await translation?.value
        await summary?.value
        await wake?.value
        try await eventually {
            model.savedPauseTaskForTesting == nil && model.savedProcessingTaskForTesting == nil
                && model.translationTaskForTesting == nil && model.summaryTaskForTesting == nil
                && model.summaryWakeTaskForTesting == nil
        }
    }

    private func cleanup(model: AppModel, queue: LearningReviewQueue, root: URL,
                         preferenceCleanup: TestPreferenceCleanup, gate: StabilityNoteGate?) async throws {
        let ownedTasks = [model.savedProcessingTaskForTesting, model.translationTaskForTesting,
                          model.summaryTaskForTesting, model.summaryWakeTaskForTesting].compactMap { $0 }
        let oldPause = model.savedPauseTaskForTesting
        // Also resolve a gate that has not been entered yet; a late request
        // must receive cancellation rather than leave a suspended continuation.
        gate?.finish(.failure(CancellationError()))
        var parked = true
        if case .saved = model.phase {
            do { try await park(model) }
            catch { parked = false; XCTFail("Could not park this test's saved workers: \(error)") }
        }
        let pendingPause = model.savedPauseTaskForTesting
        let translation = model.resetTranslationSessionForTesting()
        // Even a failed assertion/park must join the handles captured before
        // reset removes them from AppModel's slots. These are this fixture's
        // tasks only; no process or other test's worker is stopped.
        for task in ownedTasks { task.cancel(); await task.value }
        await translation?.value
        for pause in [oldPause, pendingPause].compactMap({ $0 }) {
            if case .failure(let error) = await pause.result {
                parked = false
                XCTFail("This fixture's pause task did not finish successfully: \(error)")
            }
        }
        await queue.shutdownForTesting()
        try preferenceCleanup.remove()
        // Do not remove the fixture while a failed park could still be writing.
        if parked, FileManager.default.fileExists(atPath: root.path) {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not remove this test's isolated fixture: \(error)") }
        }
    }

    private func assertExactCoverage(_ saved: SessionSnapshot, original: SessionSnapshot,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(saved.sessionID, original.sessionID, file: file, line: line)
        XCTAssertEqual(saved.segments, original.segments, file: file, line: line)
        XCTAssertEqual(saved.batches.count, 1, "Exactly one note batch must commit", file: file, line: line)
        XCTAssertEqual(saved.batches.first?.ids, Set(original.segments.map(\.id)), file: file, line: line)
        XCTAssertEqual(saved.batches.flatMap(\.evidence), original.segments, file: file, line: line)
        XCTAssertEqual(saved.latestEvidenceIDs, Set(original.segments.map(\.id)), file: file, line: line)
        XCTAssertTrue(saved.processing.pendingSegmentIDs.isEmpty, file: file, line: line)
        XCTAssertTrue(saved.processing.pendingBatchIDs.isEmpty, file: file, line: line)
        XCTAssertTrue(saved.generationCheckpoints.isEmpty, file: file, line: line)
        XCTAssertTrue(saved.audioFiles.isEmpty, file: file, line: line)
        XCTAssertTrue(saved.audioRanges.isEmpty, file: file, line: line)
    }

    private func assertCaptureFailure(_ saved: SessionSnapshot, _ failure: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(saved.processing.captureError, failure, file: file, line: line)
        XCTAssertEqual(saved.processing.lastError, failure, file: file, line: line)
        XCTAssertEqual(saved.processing.lastErrorSource, .capture, file: file, line: line)
    }

    func testSingleUsableArchivedCaptionDrainsOnceOnlyAfterExplicitResume() async throws {
        let fixture = try makeArchive(captionCount: 1)
        let model = fixture.model
        try await model.openSavedSession(fixture.root, allowAutomaticProcessing: false)
        XCTAssertTrue(model.savedProcessingIsPaused)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(fixture.probe.inputs.count, 0)
        XCTAssertEqual(fixture.probe.translationRequests, 0)
        XCTAssertNil(model.savedProcessingTaskForTesting)
        XCTAssertNil(model.summaryTaskForTesting)
        XCTAssertNil(model.summaryWakeTaskForTesting)

        model.resumeSavedProcessing()
        try await eventually { fixture.probe.inputs.count == 1 }
        await model.savedProcessingTaskForTesting?.value
        try await eventually {
            (try? SessionStore(directory: fixture.root).load())?.batches.count == 1
        }
        try await park(model)
        let saved = try XCTUnwrap(SessionStore(directory: fixture.root).load())
        assertExactCoverage(saved, original: fixture.snapshot)
        XCTAssertEqual(fixture.probe.inputs.count, 1, "No second caption or manual note refresh is needed")
        XCTAssertEqual(fixture.probe.translationRequests, 0)
        XCTAssertTrue(model.lectureSummary.contains("B 车的速度为每秒两米。"))
        XCTAssertNil(model.archiveError)
    }

    func testArchivedCaptureFailureSurvivesFinalDrainAndAutomaticNoteRetry() async throws {
        for captionCount in [1, 2] {
            let failure = "Synthetic archived capture interruption; no microphone was used"
            let fixture = try makeArchive(captionCount: captionCount, captureError: failure, failFirst: true)
            let model = fixture.model
            try await model.openSavedSession(fixture.root, allowAutomaticProcessing: false)
            XCTAssertEqual(fixture.probe.inputs.count, 0)
            XCTAssertEqual(fixture.probe.translationRequests, 0)
            assertCaptureFailure(try XCTUnwrap(SessionStore(directory: fixture.root).load()), failure)

            model.resumeSavedProcessing()
            try await eventually { fixture.probe.inputs.count == 1 }
            await model.savedProcessingTaskForTesting?.value
            let failed = try XCTUnwrap(SessionStore(directory: fixture.root).load())
            XCTAssertTrue(failed.batches.isEmpty, "The injected first failure must not claim evidence coverage")
            XCTAssertEqual(fixture.probe.inputs.count, 1)
            assertCaptureFailure(failed, failure)
            try await eventually { model.summaryWakeTaskForTesting != nil && fixture.clock.activeWaits.count == 1 }
            XCTAssertEqual(fixture.clock.activeWaits.map(\.deadline), [10])

            // No caption delivery, power refresh, manual summary request or
            // second resume: the final drain must arrange this wake itself.
            fixture.clock.advance(to: 10)
            try await eventually {
                fixture.probe.inputs.count == 2 && model.lectureSummary.contains("B 车的速度为每秒两米。")
            }
            await model.summaryTaskForTesting?.value
            try await park(model)
            let saved = try XCTUnwrap(SessionStore(directory: fixture.root).load())
            assertExactCoverage(saved, original: fixture.snapshot)
            assertCaptureFailure(saved, failure)
            XCTAssertEqual(fixture.probe.inputs.count, 2, "One failed attempt and one automatic successful retry")
            XCTAssertEqual(fixture.probe.inputs.first, fixture.probe.inputs.last,
                           "Retry must use precisely the same archived evidence")
            XCTAssertEqual(fixture.probe.translationRequests, 0)
            XCTAssertFalse(model.isRecording)
            XCTAssertNil(model.archiveError)
        }
    }

    func testPausedArchiveRejectsHeldNoteAndResumesExactEvidenceOnce() async throws {
        for captionCount in [1, 2] {
            for returnStaleSuccess in [false, true] {
                let gate = StabilityNoteGate()
                let failure = "Synthetic archived capture interruption retained across note cancellation"
                let fixture = try makeArchive(captionCount: captionCount, captureError: failure, gate: gate)
                let model = fixture.model
                try await model.openSavedSession(fixture.root, allowAutomaticProcessing: false)
                XCTAssertEqual(fixture.probe.inputs.count, 0)
                model.resumeSavedProcessing()
                try await eventually { gate.entered }
                let oldDrain = try XCTUnwrap(model.savedProcessingTaskForTesting)
                let oldSummary = model.summaryTaskForTesting
                XCTAssertEqual(fixture.probe.inputs.count, 1)
                XCTAssertTrue(model.learningNotebookForTesting.batches.isEmpty)

                model.pauseSavedProcessing()
                try await eventually { model.savedProcessingIsPaused }
                let parking = try XCTUnwrap(model.savedPauseTaskForTesting)
                XCTAssertTrue(oldDrain.isCancelled)
                XCTAssertTrue(model.learningNotebookForTesting.batches.isEmpty)
                XCTAssertTrue(model.lectureSummary.isEmpty)
                XCTAssertTrue(try XCTUnwrap(SessionStore(directory: fixture.root).load()).batches.isEmpty)
                // The dependency ignores cancellation while held. Exercise both
                // a thrown cancellation and a complete but stale valid response.
                gate.finish(returnStaleSuccess ? .success(fixture.probe.response) : .failure(CancellationError()))
                await oldSummary?.value
                await oldDrain.value
                try await parking.value
                try await eventually { model.savedPauseTaskForTesting == nil }
                XCTAssertNil(model.savedProcessingTaskForTesting)
                XCTAssertNil(model.summaryTaskForTesting)
                XCTAssertNil(model.summaryWakeTaskForTesting)
                let paused = try XCTUnwrap(SessionStore(directory: fixture.root).load())
                XCTAssertTrue(paused.processing.paused)
                XCTAssertEqual(paused.processing.phase, .paused)
                XCTAssertTrue(paused.batches.isEmpty, "A paused/stale response cannot commit coverage")
                XCTAssertEqual(paused.segments, fixture.snapshot.segments)
                assertCaptureFailure(paused, failure)
                XCTAssertTrue(model.learningNotebookForTesting.batches.isEmpty)
                XCTAssertTrue(model.lectureSummary.isEmpty)
                XCTAssertEqual(fixture.probe.inputs.count, 1)

                model.resumeSavedProcessing()
                try await eventually { fixture.probe.inputs.count == 2 }
                await model.savedProcessingTaskForTesting?.value
                try await eventually {
                    (try? SessionStore(directory: fixture.root).load())?.batches.count == 1
                }
                try await park(model)
                let saved = try XCTUnwrap(SessionStore(directory: fixture.root).load())
                assertExactCoverage(saved, original: fixture.snapshot)
                assertCaptureFailure(saved, failure)
                XCTAssertEqual(fixture.probe.inputs.count, 2)
                XCTAssertEqual(fixture.probe.inputs.first, fixture.probe.inputs.last)
                XCTAssertEqual(fixture.probe.translationRequests, 0)
                XCTAssertFalse(model.isRecording)
                XCTAssertNil(model.archiveError)
            }
        }
    }
}
