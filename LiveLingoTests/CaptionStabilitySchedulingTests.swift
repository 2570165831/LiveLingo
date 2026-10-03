import Foundation
import XCTest
@testable import LiveLingo

@MainActor
private func captionSchedulingEventually(within timeout: Duration = .seconds(5),
                                        _ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail("Synthetic scheduling did not reach the asserted stage")
            throw CancellationError()
        }
        // Bounded failure watchdog only; never advances a business clock.
        try await Task.sleep(for: .milliseconds(2))
    }
}

/// Only note admission uses this clock. Translation queue ages remain real uptime.
/// Cancellation normally removes and throws the waiter; one selected waiter can
/// deliberately ignore cancellation until the test delivers a late success.
@MainActor
private final class CaptionSchedulingClock {
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
private final class CaptionSchedulingRepairGate {
    private var continuation: CheckedContinuation<QwenTranslationClient.PreviousRepair, Error>?
    private var result: Result<QwenTranslationClient.PreviousRepair, Error>?
    private(set) var entered = false

    func wait() async throws -> QwenTranslationClient.PreviousRepair {
        entered = true
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation {
            precondition(continuation == nil, "The fixture owns exactly one repair")
            continuation = $0
        }
    }

    func finish(_ result: Result<QwenTranslationClient.PreviousRepair, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

@MainActor
private final class CaptionSchedulingNoteProbe {
    private var responses: [String]
    private(set) var inputs: [String] = []
    private(set) var prefixes: [String] = []

    init(_ responses: [String]) { self.responses = responses }

    func generate(_ input: String, prefix: String) throws -> String {
        inputs.append(input)
        prefixes.append(prefix)
        guard !responses.isEmpty else {
            XCTFail("Unexpected extra note request: quiet captions must not repeat")
            throw QwenRuntimeError.requestFailed("Unexpected extra synthetic note request")
        }
        return responses.removeFirst()
    }
}

@MainActor
private final class CaptionSchedulingFixture {
    let clock = CaptionSchedulingClock()
    let model: AppModel
    let root: URL
    let queue: LearningReviewQueue
    let suite: String
    var repairGate: CaptionSchedulingRepairGate?
    var retainedTasks: [Task<Void, Never>] = []

    init(probe: CaptionSchedulingNoteProbe,
         translation: CaptionTranslationDependencies? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LiveLingo-CaptionScheduling-\(UUID())", isDirectory: true)
        suite = "LiveLingo-CaptionScheduling-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        queue = LearningReviewQueue(journalURL: root.appendingPathComponent("review-queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
                XCTFail("Scheduling fixtures must not invoke review models")
                throw CancellationError()
            }
        model = AppModel(reviewQueue: queue, translation: translation ?? .unavailable,
            notes: .init(generate: { input, _, prefix, _ in
                try probe.generate(input, prefix: prefix)
            }), backgroundServices: false, scheduledNotes: true, defaults: defaults)
        model.resetTranslationSessionForTesting()
        configureClock()
    }

    func configureClock() {
        model.configureNoteSchedulingForTesting(now: { [clock] in clock.now },
            sleep: { [clock] delay in try await clock.sleep(delay) }, allowConcurrent: true)
    }

    func shutdown() async throws {
        // Release every continuation first, including deliberately cancelled
        // waits. Keep the saver alive until saved-course parking has flushed.
        repairGate?.finish(.failure(CancellationError()))
        clock.shutdown()
        let owned = retainedTasks + [model.translationTaskForTesting,
            model.summaryTaskForTesting, model.summaryWakeTaskForTesting,
            model.savedProcessingTaskForTesting].compactMap { $0 }
        if case .saved(let directory) = model.phase {
            do {
                model.pauseSavedProcessing()
                // pauseSavedProcessing dispatches its park in a MainActor task.
                // The task view is transient: a quick park may finish before
                // observation, in which case require its full disk readback.
                for _ in 0..<32 { await Task.yield() }
                try await captionSchedulingEventually {
                    self.model.savedPauseTaskForTesting != nil || self.isParkedOnDisk(directory)
                }
                if let pause = model.savedPauseTaskForTesting {
                    var completion: Result<Void, Error>?
                    let observer = Task { @MainActor in
                        do { try await pause.value; completion = .success(()) }
                        catch { completion = .failure(error) }
                    }
                    do {
                        try await captionSchedulingEventually { completion != nil }
                        await observer.value
                        try XCTUnwrap(completion).get()
                    } catch {
                        observer.cancel()
                        throw error
                    }
                }
                try await captionSchedulingEventually {
                    self.isParkedOnDisk(directory) || self.model.archiveError != nil
                }
                guard isParkedOnDisk(directory), model.archiveError == nil else {
                    throw QwenRuntimeError.requestFailed("Saved fixture park/flush could not be verified")
                }
            } catch {
                // An unresolved saver may still write here. Do not reset it or
                // remove its directory; preserve the failure evidence instead.
                for task in owned { task.cancel() }
                await queue.shutdownForTesting()
                XCTFail("Saved fixture park/flush failed; preserved root: \(root.path)")
                throw error
            }
        }
        for task in owned { task.cancel() }
        model.resetTranslationSessionForTesting()
        for task in owned { await task.value }
        await queue.shutdownForTesting()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func isParkedOnDisk(_ directory: URL) -> Bool {
        guard model.savedProcessingIsPaused,
              model.savedPauseTaskForTesting == nil,
              model.savedProcessingTaskForTesting == nil,
              model.translationTaskForTesting == nil,
              model.summaryTaskForTesting == nil,
              model.summaryWakeTaskForTesting == nil,
              let snapshot = try? SessionStore(directory: directory).load(),
              snapshot.processing.paused else { return false }
        return snapshot.segments == model.segments
            && snapshot.batches == model.learningNotebookForTesting.batches
    }
}

@MainActor
final class CaptionStabilitySchedulingTests: XCTestCase {
    private static let pairNote = #"{"sourceVersion":2,"topic":"小车运动","points":[{"kind":"核心结论","text":"小车保持每秒两米的速度。","sourceIDs":["en0s0","en1s0"]}]}"#
    private static let tailNote = #"{"sourceVersion":2,"topic":"速度测量","points":[{"kind":"核心结论","text":"测速仪记录小车的速度。","sourceIDs":["en0s0"]}]}"#

    private func eventually(within timeout: Duration = .seconds(5),
                            _ condition: @escaping @MainActor () -> Bool) async throws {
        try await captionSchedulingEventually(within: timeout, condition)
    }

    private func yieldToScheduledTasks() async {
        for _ in 0..<32 { await Task.yield() }
    }

    private func fixture(_ probe: CaptionSchedulingNoteProbe,
                         translation: CaptionTranslationDependencies? = nil) throws -> CaptionSchedulingFixture {
        let value = try CaptionSchedulingFixture(probe: probe, translation: translation)
        addTeardownBlock { try await value.shutdown() }
        return value
    }

    private func captions(session: UUID? = nil) -> [TranscriptSegment] {
        [
            .init(startTime: 0, endTime: 8, english: "The cart moves at two metres per second.",
                  chinese: "小车的速度为每秒两米。", sessionID: session),
            .init(startTime: 8, endTime: 16, english: "The cart keeps this speed for the whole journey.",
                  chinese: "小车全程保持该速度。", sessionID: session),
            .init(startTime: 16, endTime: 24, english: "The speed sensor records the cart's speed.",
                  chinese: "测速仪记录小车的速度。", sessionID: session)
        ]
    }

    private func assertBatches(_ model: AppModel, evidence: [[TranscriptSegment]],
                               file: StaticString = #filePath, line: UInt = #line) {
        let batches = model.learningNotebookForTesting.batches
        XCTAssertEqual(batches.count, evidence.count, file: file, line: line)
        XCTAssertEqual(batches.map(\.ids), evidence.map { Set($0.map(\.id)) }, file: file, line: line)
        XCTAssertEqual(batches.map(\.evidence), evidence, file: file, line: line)
        XCTAssertEqual(Set(batches.map(\.id)).count, batches.count,
                       "Committed batches must have distinct identities", file: file, line: line)
    }

    private func assertInput(_ actual: String, evidence: [TranscriptSegment],
                             file: StaticString = #filePath, line: UInt = #line) throws {
        // Exact full wire payload, including every bilingual source and the
        // empty follow-up list; a mere substring check would miss mixed batches.
        XCTAssertEqual(actual, try LearningPrompts.input(evidence: evidence, topics: []), file: file, line: line)
    }

    func testStablePairCommitsThenSilentTailAutoWakesAtNextOrdinaryCycle() async throws {
        let probe = CaptionSchedulingNoteProbe([Self.pairNote, Self.tailNote])
        let f = try fixture(probe)
        let evidence = captions()
        let pair = Array(evidence.prefix(2))
        let tail = [evidence[2]]
        f.model.loadPresentationForTesting(phase: .recording, evidence: evidence)
        f.model.scheduleSummaryForTesting()
        try await eventually {
            probe.inputs.count >= 1 && f.model.summaryTaskForTesting == nil
                && f.model.summaryWakeTaskForTesting != nil && !f.clock.activeWaits.isEmpty
        }
        XCTAssertEqual(probe.inputs.count, 1)
        try assertInput(try XCTUnwrap(probe.inputs.first), evidence: pair)
        assertBatches(f.model, evidence: [pair])
        let firstBatchID = try XCTUnwrap(f.model.learningNotebookForTesting.batches.first?.id)

        // No additional caption or explicit schedule calls after first admission.
        f.clock.advance(to: 20)
        try await eventually {
            probe.inputs.count > 1 || (f.model.summaryTaskForTesting == nil
                && f.clock.activeWaits.count == 1 && f.clock.activeWaits.first?.deadline == 180)
        }
        XCTAssertEqual(probe.inputs.count, 1, "The 20-second stability limit cannot bypass the 180-second cycle")
        assertBatches(f.model, evidence: [pair])
        XCTAssertEqual(f.clock.activeWaits.map(\.deadline), [180])
        XCTAssertNotNil(f.model.summaryWakeTaskForTesting)
        f.clock.advance(to: 179)
        await yieldToScheduledTasks()
        XCTAssertEqual(probe.inputs.count, 1)

        f.clock.advance(to: 180)
        try await eventually {
            probe.inputs.count >= 2 && f.model.summaryTaskForTesting == nil
                && f.model.summaryWakeTaskForTesting == nil && f.clock.activeWaits.isEmpty
        }
        XCTAssertEqual(probe.inputs.count, 2, "A silent leftover must automatically commit once")
        try assertInput(try XCTUnwrap(probe.inputs.last), evidence: tail)
        assertBatches(f.model, evidence: [pair, tail])
        XCTAssertEqual(f.model.learningNotebookForTesting.batches.first?.id, firstBatchID)
        XCTAssertEqual(probe.prefixes, ["", ""])
        f.clock.advance(to: 1_000)
        await yieldToScheduledTasks()
        XCTAssertEqual(probe.inputs.count, 2)
        assertBatches(f.model, evidence: [pair, tail])
        XCTAssertNil(f.model.summaryTaskForTesting)
        XCTAssertNil(f.model.summaryWakeTaskForTesting)
        XCTAssertTrue(f.clock.activeWaits.isEmpty)
    }

    func testSingleLiveCaptionIsWithheldThenAutoEmitsOnceAtStabilityDeadline() async throws {
        let probe = CaptionSchedulingNoteProbe([Self.tailNote])
        let f = try fixture(probe)
        let evidence = [captions()[2]]
        f.model.loadPresentationForTesting(phase: .recording, evidence: evidence)
        f.model.scheduleSummaryForTesting()
        try await eventually { f.clock.activeWaits.count == 1 }
        XCTAssertEqual(f.clock.activeWaits.map(\.deadline), [20])
        XCTAssertNotNil(f.model.summaryWakeTaskForTesting)
        XCTAssertTrue(probe.inputs.isEmpty)
        assertBatches(f.model, evidence: [])
        f.clock.advance(to: 19)
        await yieldToScheduledTasks()
        XCTAssertTrue(probe.inputs.isEmpty)

        f.clock.advance(to: 20)
        try await eventually {
            probe.inputs.count >= 1 && f.model.summaryTaskForTesting == nil
                && f.model.summaryWakeTaskForTesting == nil && f.clock.activeWaits.isEmpty
        }
        XCTAssertEqual(probe.inputs.count, 1)
        try assertInput(try XCTUnwrap(probe.inputs.first), evidence: evidence)
        assertBatches(f.model, evidence: [evidence])
        let committedID = try XCTUnwrap(f.model.learningNotebookForTesting.batches.first?.id)
        f.clock.advance(to: 200)
        await yieldToScheduledTasks()
        f.clock.advance(to: 1_000)
        await yieldToScheduledTasks()
        XCTAssertEqual(probe.inputs.count, 1)
        XCTAssertEqual(f.model.learningNotebookForTesting.batches.map(\.id), [committedID])
        assertBatches(f.model, evidence: [evidence])
        XCTAssertNil(f.model.summaryWakeTaskForTesting)
        XCTAssertTrue(f.clock.activeWaits.isEmpty)
    }

    func testStablePairSchedulesWhileSavedDeferredRepairAndDrainRemainHeld() async throws {
        let gate = CaptionSchedulingRepairGate()
        var repairs: [DeferredCaptionRepair] = []
        var deps = CaptionTranslationDependencies.unavailable
        deps.repair = { job in
            repairs.append(job)
            return try await gate.wait()
        }
        let probe = CaptionSchedulingNoteProbe([Self.pairNote])
        let f = try fixture(probe, translation: deps)
        f.repairGate = gate
        let directory = f.root.appendingPathComponent("course", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var snapshot = SessionSnapshot()
        var evidence = captions(session: snapshot.sessionID)
        evidence.append(.init(startTime: 24, endTime: 32,
            english: "The measurement completes the speed record.", chinese: "测量完成了速度记录。",
            sessionID: snapshot.sessionID))
        let pair = Array(evidence.prefix(2))
        let pending = DeferredCaptionRepair(sessionID: snapshot.sessionID,
            previous: evidence[2], current: evidence[3], context: pair,
            normalizedCurrent: evidence[3].english, modelName: "test")
        XCTAssertEqual(pending.previousIndex(in: evidence, session: snapshot.sessionID), 2,
                       "The job must match the actual target, successor and two-caption context")
        snapshot.segments = evidence
        snapshot.processing.pendingCaptionRepairs = [pending]
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        _ = try SessionStore(directory: directory).save(snapshot)
        f.model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await f.model.openSavedSession(directory, allowAutomaticProcessing: false)
        XCTAssertTrue(repairs.isEmpty)
        XCTAssertTrue(probe.inputs.isEmpty, "Opening an archive must remain parked")
        f.configureClock()
        f.model.resumeSavedProcessing()
        try await eventually { gate.entered && f.model.savedProcessingTaskForTesting != nil }
        XCTAssertEqual(repairs, [pending])
        XCTAssertFalse(f.model.savedProcessingIsPaused)
        XCTAssertNotNil(f.model.translationTaskForTesting)
        let heldWorker = try XCTUnwrap(f.model.translationTaskForTesting)
        let heldDrain = try XCTUnwrap(f.model.savedProcessingTaskForTesting)
        f.retainedTasks += [heldWorker, heldDrain]

        // The real saved drain is now blocked on the repair worker. A .saved
        // phase must not seal C/D, and a queued repair must not globally deny A/B.
        f.model.scheduleSummaryForTesting()
        try await eventually { !probe.inputs.isEmpty && f.model.summaryTaskForTesting == nil }
        XCTAssertEqual(probe.inputs.count, 1)
        try assertInput(try XCTUnwrap(probe.inputs.first), evidence: pair)
        assertBatches(f.model, evidence: [pair])
        XCTAssertEqual(f.model.segments, evidence)
        XCTAssertEqual(repairs, [pending])
        XCTAssertNotNil(f.model.savedProcessingTaskForTesting, "Drain cannot finish while its repair is held")
        XCTAssertNotNil(f.model.translationTaskForTesting)
        XCTAssertEqual(f.clock.now, 0, "Neither C's limit nor final sealing justified first admission")

        // Use the real pause lifecycle to park this archive before releasing
        // the held worker; teardown will also resolve it on any earlier failure.
        f.model.pauseSavedProcessing()
        try await eventually { f.model.savedProcessingIsPaused }
        gate.finish(.failure(CancellationError()))
        await heldWorker.value
        try await f.model.savedPauseTaskForTesting?.value
        await heldDrain.value
        XCTAssertEqual(probe.inputs.count, 1)
        XCTAssertNil(f.model.archiveError)
        let parked = try XCTUnwrap(SessionStore(directory: directory).load())
        XCTAssertEqual(parked.processing.pendingCaptionRepairs, [pending])
        XCTAssertEqual(parked.batches.map(\.ids), [Set(pair.map(\.id))])
        XCTAssertEqual(parked.segments, evidence)
    }

    func testCoveredSuccessorDependencyRetainsDraftWakeWithoutBusyReplacementThenResumesPrefix() async throws {
        let retainedPrefix = #"{"sourceVersion":2,"topic":"小车"#
        let probe = CaptionSchedulingNoteProbe([Self.pairNote])
        let f = try fixture(probe)
        let directory = f.root.appendingPathComponent("blocked-draft", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var snapshot = SessionSnapshot()
        let a = TranscriptSegment(startTime: 0, endTime: 8,
            english: "Its speed is not known yet.", chinese: "速度仍待后文说明。", sessionID: snapshot.sessionID)
        let x = TranscriptSegment(startTime: 8, endTime: 16,
            english: "The lecturer continues the explanation.", sessionID: snapshot.sessionID)
        let b = TranscriptSegment(startTime: 30, endTime: 38,
            english: "Cart B moves at two metres per second.", chinese: "B 车的速度为每秒两米。", sessionID: snapshot.sessionID)
        let c = TranscriptSegment(startTime: 40, endTime: 48,
            english: "Cart B keeps this speed for the whole journey.", chinese: "B 车全程保持该速度。", sessionID: snapshot.sessionID)
        let tail = TranscriptSegment(startTime: 60, endTime: 68,
            english: "The lecturer will discuss acceleration next.", sessionID: snapshot.sessionID)
        var notebook = LearningNotebook()
        try notebook.append(evidence: [a], note: .init(topic: "先前记录", points: [
            .init(kind: "待确认", text: a.chinese, needsContext: "速度属于哪辆车？", sourceIDs: ["en0s0"])
        ], sourceVersion: 2))
        let oldBatches = notebook.batches
        let pendingPoints = notebook.selectPendingPoints(for: [b, c])
        XCTAssertTrue(pendingPoints.flatMap(\.dependencyIDs).contains(a.id))
        let input = try LearningPrompts.input(evidence: [b, c], topics: notebook.topics, pending: pendingPoints)
        let modelName = f.model.effectiveProfile.translationModel
        var draft = LearningDraft(evidence: [b, c], model: modelName, input: input,
            text: retainedPrefix, attempts: 1, pendingTargets: pendingPoints.map(\.id),
            contextRevision: notebook.revision, dependencyIDs: [b.id, c.id, a.id])
        draft.freezeBinding(sessionID: snapshot.sessionID, inputRevision: snapshot.inputRevision,
            generation: snapshot.generation)
        snapshot.segments = [a, x, b, c, tail]
        notebook.writeState(to: &snapshot)
        snapshot.generationCheckpoints = [draft.checkpoint(sessionID: snapshot.sessionID,
            inputRevision: snapshot.inputRevision, generation: snapshot.generation)]
        // X is an adjacent untranslated source, not a queued translation or
        // repair job. Opening without resume leaves translationQueue empty.
        snapshot.processing.pendingSegmentIDs = [x.id, tail.id]
        snapshot.processing.pendingCaptionRepairs = nil
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        XCTAssertEqual(x.translationState, .pending)
        XCTAssertFalse(x.hasUsableTranslation)
        XCTAssertEqual(x.startTime - a.endTime, 0)
        XCTAssertGreaterThan(tail.startTime - c.endTime, 2)
        XCTAssertEqual(oldBatches.map(\.ids), [Set([a.id])])
        XCTAssertNotNil(LearningDraft(checkpoint: snapshot.generationCheckpoints[0],
            snapshot: snapshot, model: modelName), "The retained checkpoint must actually restore")
        _ = try SessionStore(directory: directory).save(snapshot)
        f.model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await f.model.openSavedSession(directory, allowAutomaticProcessing: false)
        XCTAssertTrue(probe.inputs.isEmpty)
        XCTAssertNil(f.model.translationTaskForTesting)
        XCTAssertNil(f.model.savedProcessingTaskForTesting)

        // Open + direct seam unpause intentionally isolates note admission;
        // this is not a saved-course resume lifecycle test. Covered A is at
        // risk through X's pending state while B/C remain stable. There are no
        // queue/repair jobs for the wrapper's drainTranslationQueue to start,
        // so a worker cannot accidentally mask the empty-summary spin.
        await f.model.generateSummaryForTesting()
        try await eventually { f.clock.activeWaits.count == 1 }
        XCTAssertTrue(probe.inputs.isEmpty)
        XCTAssertEqual(f.clock.activeWaits.map(\.deadline), [20])
        XCTAssertEqual(f.clock.sleepRegistrationCount, 1)
        XCTAssertEqual(f.model.learningNotebookForTesting.batches, oldBatches)

        // One explicit kick exercises the real summaryTask completion wrapper.
        // Expected shape: direct blocked wake + one kick's blocked wake; allow
        // at most one transitional registration (total <= 3), then no changes.
        f.model.scheduleSummaryForTesting()
        try await eventually {
            f.clock.sleepRegistrationCount > 3 || (f.model.summaryTaskForTesting == nil
                && f.model.summaryWakeTaskForTesting != nil && f.clock.activeWaits.count == 1)
        }
        await yieldToScheduledTasks()
        let wait = try XCTUnwrap(f.clock.activeWaits.first)
        let registrations = f.clock.sleepRegistrationCount
        XCTAssertLessThanOrEqual(registrations, 3, "Blocked draft completion must not create an empty-task loop")
        XCTAssertEqual(wait.deadline, 20)
        for _ in 0..<4 { await yieldToScheduledTasks() }
        XCTAssertEqual(f.clock.sleepRegistrationCount, registrations, "Registrations must settle without moving time")
        XCTAssertEqual(f.clock.activeWaits.map(\.id), [wait.id], "The real dependency wake must remain owned")
        XCTAssertNotNil(f.model.summaryWakeTaskForTesting)
        XCTAssertNil(f.model.summaryTaskForTesting)
        XCTAssertNil(f.model.translationTaskForTesting)
        XCTAssertNil(f.model.savedProcessingTaskForTesting)
        XCTAssertTrue(probe.inputs.isEmpty)
        XCTAssertEqual(f.model.learningNotebookForTesting.batches, oldBatches)

        f.clock.advance(to: 20)
        try await eventually { !probe.inputs.isEmpty && f.model.summaryTaskForTesting == nil }
        XCTAssertEqual(probe.inputs, [input])
        XCTAssertEqual(probe.prefixes, [retainedPrefix])
        assertBatches(f.model, evidence: [[a], [b, c]])
        XCTAssertEqual(Array(f.model.learningNotebookForTesting.batches.prefix(1)), oldBatches)
        XCTAssertEqual(f.model.segments, snapshot.segments, "Admission must leave X and the tail untranslated")
        XCTAssertNil(f.model.translationTaskForTesting)
        XCTAssertNil(f.model.savedProcessingTaskForTesting)
        f.clock.advance(to: 1_000)
        await yieldToScheduledTasks()
        XCTAssertEqual(probe.inputs, [input])
        XCTAssertEqual(probe.prefixes, [retainedPrefix])
        assertBatches(f.model, evidence: [[a], [b, c]])
        XCTAssertNil(f.model.translationTaskForTesting)
        XCTAssertNil(f.model.savedProcessingTaskForTesting)
    }

    func testSameSessionWakeReplacementKeepsAbsoluteDeadlineAndRejectsOldCancelledSuccess() async throws {
        let probe = CaptionSchedulingNoteProbe([Self.tailNote])
        let f = try fixture(probe)
        let evidence = [captions()[2]]
        f.clock.retainNextCancelledWait = true
        f.model.loadPresentationForTesting(phase: .recording, evidence: evidence)
        f.model.scheduleSummaryForTesting()
        try await eventually { f.clock.activeWaits.count == 1 }
        let oldWait = try XCTUnwrap(f.clock.activeWaits.first)
        let oldWake = try XCTUnwrap(f.model.summaryWakeTaskForTesting)
        f.retainedTasks.append(oldWake)
        XCTAssertEqual(oldWait.deadline, 20)

        f.clock.advance(to: 5)
        // No reset, reload, caption event or reconfiguration: generation and
        // evidence remain unchanged. Only this timer's ownership is replaced.
        f.model.scheduleSummaryForTesting()
        try await eventually {
            f.clock.lateCancelledIDs.contains(oldWait.id) && f.clock.activeWaits.count == 1
        }
        let replacementWait = try XCTUnwrap(f.clock.activeWaits.first)
        let replacementWake = try XCTUnwrap(f.model.summaryWakeTaskForTesting)
        f.retainedTasks.append(replacementWake)
        XCTAssertNotEqual(replacementWait.id, oldWait.id)
        XCTAssertEqual(replacementWait.deadline, 20, "Replacing a wake must not slide the deadline to 25")
        XCTAssertTrue(oldWake.isCancelled)
        XCTAssertFalse(replacementWake.isCancelled)
        XCTAssertEqual(f.model.segments, evidence)
        XCTAssertTrue(probe.inputs.isEmpty)

        f.clock.advance(to: 10)
        // Successful sleep return is intentional, late relative to cancellation
        // but still before the original deadline, within the same generation.
        try f.clock.deliverLateCancelledSuccess(oldWait.id)
        await oldWake.value
        XCTAssertTrue(probe.inputs.isEmpty, "A replaced wake must not schedule a premature note")
        XCTAssertNotNil(f.model.summaryWakeTaskForTesting, "Old cleanup must not erase its replacement")
        XCTAssertFalse(replacementWake.isCancelled)
        XCTAssertEqual(f.clock.activeWaits.map(\.id), [replacementWait.id])
        XCTAssertEqual(f.clock.activeWaits.map(\.deadline), [20])
        assertBatches(f.model, evidence: [])
        f.clock.advance(to: 19)
        await yieldToScheduledTasks()
        XCTAssertTrue(probe.inputs.isEmpty)
        XCTAssertEqual(f.clock.activeWaits.map(\.id), [replacementWait.id])

        f.clock.advance(to: 20)
        await replacementWake.value
        try await eventually {
            probe.inputs.count >= 1 && f.model.summaryTaskForTesting == nil
                && f.model.summaryWakeTaskForTesting == nil && f.clock.activeWaits.isEmpty
        }
        XCTAssertEqual(probe.inputs.count, 1)
        try assertInput(try XCTUnwrap(probe.inputs.first), evidence: evidence)
        assertBatches(f.model, evidence: [evidence])
        let committedID = try XCTUnwrap(f.model.learningNotebookForTesting.batches.first?.id)
        f.clock.advance(to: 1_000)
        await yieldToScheduledTasks()
        XCTAssertEqual(probe.inputs.count, 1)
        XCTAssertEqual(probe.prefixes, [""])
        XCTAssertEqual(f.model.learningNotebookForTesting.batches.map(\.id), [committedID])
        assertBatches(f.model, evidence: [evidence])
        XCTAssertNil(f.model.summaryWakeTaskForTesting)
        XCTAssertTrue(f.clock.activeWaits.isEmpty)
        XCTAssertTrue(f.clock.lateCancelledIDs.isEmpty)
    }

    func testLateCancelledWakeCannotScheduleOrEraseNewSessionWakeWithReusedCaptionIDs() async throws {
        let probe = CaptionSchedulingNoteProbe([Self.tailNote])
        let f = try fixture(probe)
        let evidence = [captions()[2]]
        f.clock.retainNextCancelledWait = true
        f.model.loadPresentationForTesting(phase: .recording, evidence: evidence)
        f.model.scheduleSummaryForTesting()
        try await eventually { f.clock.activeWaits.count == 1 }
        let oldWait = try XCTUnwrap(f.clock.activeWaits.first)
        let oldWake = try XCTUnwrap(f.model.summaryWakeTaskForTesting)
        f.retainedTasks.append(oldWake)
        XCTAssertEqual(oldWait.deadline, 20)
        f.clock.advance(to: 5)
        f.model.resetTranslationSessionForTesting()
        f.configureClock()
        // Reuse the exact caption IDs/content, so only session/generation/wake
        // ownership can separate the old timer from this new recording.
        f.model.loadPresentationForTesting(phase: .recording, evidence: evidence)
        f.model.scheduleSummaryForTesting()
        try await eventually {
            f.clock.lateCancelledIDs.contains(oldWait.id) && f.clock.activeWaits.count == 1
        }
        let newWait = try XCTUnwrap(f.clock.activeWaits.first)
        let newWake = try XCTUnwrap(f.model.summaryWakeTaskForTesting)
        f.retainedTasks.append(newWake)
        XCTAssertNotEqual(newWait.id, oldWait.id)
        XCTAssertEqual(newWait.deadline, 25)
        XCTAssertTrue(oldWake.isCancelled)
        XCTAssertFalse(newWake.isCancelled)
        XCTAssertTrue(probe.inputs.isEmpty)

        f.clock.advance(to: 20)
        try f.clock.deliverLateCancelledSuccess(oldWait.id)
        await oldWake.value
        XCTAssertTrue(probe.inputs.isEmpty, "An old successful wake must not admit the new session early")
        XCTAssertNotNil(f.model.summaryWakeTaskForTesting, "Old cleanup must not erase the current wake owner")
        XCTAssertFalse(newWake.isCancelled)
        XCTAssertEqual(f.clock.activeWaits.map(\.id), [newWait.id])
        XCTAssertEqual(f.clock.activeWaits.map(\.deadline), [25])
        assertBatches(f.model, evidence: [])
        f.clock.advance(to: 24)
        await yieldToScheduledTasks()
        XCTAssertTrue(probe.inputs.isEmpty)

        f.clock.advance(to: 25)
        await newWake.value
        try await eventually {
            probe.inputs.count >= 1 && f.model.summaryTaskForTesting == nil
                && f.model.summaryWakeTaskForTesting == nil && f.clock.activeWaits.isEmpty
        }
        XCTAssertEqual(probe.inputs.count, 1)
        try assertInput(try XCTUnwrap(probe.inputs.first), evidence: evidence)
        assertBatches(f.model, evidence: [evidence])
        f.clock.advance(to: 1_000)
        await yieldToScheduledTasks()
        XCTAssertEqual(probe.inputs.count, 1)
        assertBatches(f.model, evidence: [evidence])
        XCTAssertNil(f.model.summaryWakeTaskForTesting)
        XCTAssertTrue(f.clock.activeWaits.isEmpty)
        XCTAssertTrue(f.clock.lateCancelledIDs.isEmpty)
    }
    func testLastRepairHandsAllEvidenceToSealedDrainWithoutSplittingFinalContext() async throws {
        let gate = CaptionSchedulingRepairGate()
        var deps = CaptionTranslationDependencies.unavailable
        deps.repair = { _ in try await gate.wait() }
        let probe = CaptionSchedulingNoteProbe([Self.pairNote])
        let f = try fixture(probe, translation: deps)
        f.repairGate = gate
        let directory = f.root.appendingPathComponent("final-course", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var snapshot = SessionSnapshot()
        let evidence = captions(session: snapshot.sessionID)
        let pending = DeferredCaptionRepair(sessionID: snapshot.sessionID,
            previous: evidence[1], current: evidence[2], context: [evidence[0]],
            normalizedCurrent: evidence[2].english, modelName: "test")
        XCTAssertEqual(pending.previousIndex(in: evidence, session: snapshot.sessionID), 1)
        snapshot.segments = evidence
        snapshot.processing.pendingCaptionRepairs = [pending]
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        _ = try SessionStore(directory: directory).save(snapshot)
        f.model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await f.model.openSavedSession(directory, allowAutomaticProcessing: false)
        f.model.resumeSavedProcessing()
        try await eventually { gate.entered && f.model.savedProcessingTaskForTesting != nil }
        let worker = try XCTUnwrap(f.model.translationTaskForTesting)
        let drain = try XCTUnwrap(f.model.savedProcessingTaskForTesting)
        f.retainedTasks += [worker, drain]
        f.model.scheduleSummaryForTesting()
        try await eventually { !f.clock.activeWaits.isEmpty }
        XCTAssertTrue(probe.inputs.isEmpty)
        gate.finish(.success(.init(previous: nil, rejection: "Retain the accepted previous caption")))
        await worker.value
        await drain.value
        try await eventually { f.model.savedProcessingTaskForTesting == nil }
        XCTAssertEqual(probe.inputs.count, 1, "The final drain must not split the stable prefix from its last clause")
        try assertInput(try XCTUnwrap(probe.inputs.first), evidence: evidence)
        assertBatches(f.model, evidence: [evidence])
        XCTAssertNil(f.model.summaryWakeTaskForTesting)
        XCTAssertEqual(f.clock.now, 0, "Final sealing does not wait for the live-tail deadline")
    }

}
