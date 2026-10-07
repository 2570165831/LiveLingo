import Foundation
import XCTest
@testable import LiveLingo

// Existing lifecycle APIs plus the agreed DEBUG clock/task/notebook hooks.
// Freeze note time without changing the default 20-second hold or tail rules.
// Final publication uses a no-audio archive handoff, not a synthetic live seal.
// Short real-clock polling deadlines are watchdogs, not business-clock waits.
@MainActor
private final class PublicationGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private(set) var entered = false
    var resolved: Bool { result != nil }

    func wait() async throws -> Value {
        precondition(!entered, "A publication gate has exactly one consumer")
        entered = true
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

private actor InlinePublicationRequests {
    private let current: String
    private let repair: PublicationGate<String>
    private(set) var count = 0

    init(current: String, repair: PublicationGate<String>) {
        self.current = current
        self.repair = repair
    }

    func request() async throws -> String {
        count += 1
        if count == 1 { return current }
        guard count == 2 else {
            XCTFail("Only one optional previous repair is allowed")
            throw CancellationError()
        }
        return try await repair.wait()
    }
}

@MainActor
private final class PublicationSummaryInvocation {
    private(set) var finished = false
    private(set) var task: Task<Void, Never>?

    init(model: AppModel) {
        task = Task { @MainActor [self] in
            defer { finished = true }
            await model.generateSummaryForTesting()
        }
    }

}

@MainActor
final class CaptionStabilityPublicationTests: XCTestCase {
    private let previousEnglish = "The system absorbs thermal energy."
    private let currentEnglish = "and its temperature rises."
    private let originalChinese = "系统吸收热能。"
    private let repairedChinese = "系统吸收了热能。"
    private let currentChinese = "温度随之升高。"
    private let note = #"{"topic":"热能与温度","points":[{"kind":"核心结论","text":"系统吸收热能，温度随之升高。","sourceIDs":["en0s0","en1s0"]}]}"#
    private var releases: [@MainActor () -> Void] = []
    private var invocations: [PublicationSummaryInvocation] = []
    private var retainedTasks: [Task<Void, Never>] = []
    private var fixtures: [(model: AppModel, queue: LearningReviewQueue, root: URL, preferenceCleanup: TestPreferenceCleanup)] = []
    private var completedArchives: Set<URL> = []
    private var teardownRegistered = false

    private func eventually(_ message: String,
                            _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail(message)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func gate<Value: Sendable>() -> PublicationGate<Value> {
        registerTeardown()
        let gate = PublicationGate<Value>()
        releases.append { gate.finish(.failure(CancellationError())) }
        return gate
    }

    private func summarize(_ model: AppModel) -> PublicationSummaryInvocation {
        registerTeardown()
        let invocation = PublicationSummaryInvocation(model: model)
        invocations.append(invocation)
        return invocation
    }

    private func registerTeardown() {
        guard !teardownRegistered else { return }
        teardownRegistered = true
        addTeardownBlock { @MainActor [self] in try await cleanUpFixtures() }
    }

    private func join<Failure: Error>(_ task: Task<Void, Failure>, _ message: String) async throws {
        var result: Result<Void, Failure>?
        let observer = Task { @MainActor in result = await task.result }
        defer { observer.cancel() }
        try await eventually(message) { result != nil }
        await observer.value // The completion marker proves this await cannot remain parked.
        try XCTUnwrap(result).get()
    }

    private func cleanUpFixtures() async throws {
        // One teardown owns ordering across every fixture, including both
        // terminal outcomes: release ALL continuations before any task join.
        for release in releases { release() }
        var tasks = retainedTasks + invocations.compactMap(\.task)
        for fixture in fixtures {
            if let task = fixture.model.savedProcessingTaskForTesting { tasks.append(task) }
            if let task = fixture.model.summaryTaskForTesting { tasks.append(task) }
            if let task = fixture.model.summaryWakeTaskForTesting { tasks.append(task) }
            if let oldWorker = fixture.model.resetTranslationSessionForTesting() { tasks.append(oldWorker) }
        }
        for task in tasks { task.cancel() }
        // A timeout fails teardown and preserves the directories; it must not
        // turn into an unbounded await or removal while a task is still writing.
        for task in tasks { try await join(task, "An owned publication task did not terminate during teardown") }
        for fixture in fixtures {
            let shutdown = Task { @MainActor in await fixture.queue.shutdownForTesting() }
            try await join(shutdown, "The isolated review queue did not shut down")
            try fixture.preferenceCleanup.remove()
            // A completed archive has also observed its final persisted state.
            // Preserve an interrupted archive for inspection rather than race
            // an unexposed SessionSaveCoordinator writer with directory removal.
            if completedArchives.contains(fixture.root), FileManager.default.fileExists(atPath: fixture.root.path) {
                try FileManager.default.removeItem(at: fixture.root)
            }
        }
        releases.removeAll()
        retainedTasks.removeAll()
        invocations.removeAll()
        fixtures.removeAll()
    }

    private func makeModel(_ translation: CaptionTranslationDependencies,
                           notes: LearningGenerationDependencies) throws -> AppModel {
        registerTeardown()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingo-Publication-\(UUID())", isDirectory: true)
        let suite = "LiveLingo-Publication-\(UUID())"
        let preferenceCleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
                XCTFail("Publication tests must never launch a review")
                throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: translation, notes: notes,
                             backgroundServices: false, scheduledNotes: false, defaults: defaults)
        model.resetTranslationSessionForTesting()
        model.configureNoteSchedulingForTesting(now: { 100 }, sleep: { _ in throw CancellationError() })
        fixtures.append((model, queue, root, preferenceCleanup))
        return model
    }

    private func resumeArchivedCaptions(_ model: AppModel) async throws -> (URL, Task<Void, Never>) {
        let root = try XCTUnwrap(fixtures.first { $0.model === model }?.root)
        let captions = model.segments
        let identity = try XCTUnwrap(captions.first?.sessionID)
        XCTAssertTrue(captions.allSatisfy { $0.sessionID == identity })
        XCTAssertNil(model.translationTaskForTesting, "The optional repair must terminate before archiving")
        XCTAssertTrue(model.learningNotebookForTesting.batches.isEmpty)
        var snapshot = SessionSnapshot(sessionID: identity,
            inputRevision: captions.map(\.inputRevision).max() ?? 0, segments: captions)
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try SessionStore(directory: root).save(snapshot)
        XCTAssertTrue(snapshot.audioFiles.isEmpty)
        // reset/load sets a busy presentation phase; explicitly leave it before
        // openSavedSession so this existing API cannot silently ignore the open.
        model.loadPresentationForTesting(phase: .idle, evidence: captions)
        try await model.openSavedSession(root, allowAutomaticProcessing: false)
        XCTAssertEqual(model.phase, .saved(root))
        XCTAssertEqual(model.segments, captions)
        XCTAssertTrue(model.savedProcessingIsPaused)
        XCTAssertNil(model.savedProcessingTaskForTesting)
        model.resumeSavedProcessing()
        try await eventually("The no-audio archive did not start its real saved-processing task") {
            model.savedProcessingTaskForTesting != nil || model.archiveError != nil
        }
        XCTAssertNil(model.archiveError)
        let task = try XCTUnwrap(model.savedProcessingTaskForTesting)
        retainedTasks.append(task)
        return (root, task)
    }

    private func finishArchivedCaptions(_ model: AppModel, root: URL,
                                        task: Task<Void, Never>) async throws {
        try await join(task, "The real saved-processing task did not finish after the note gate resolved")
        XCTAssertNil(model.savedProcessingTaskForTesting)
        XCTAssertNil(model.translationTaskForTesting)
        XCTAssertNil(model.archiveError)
        // startSavedDrain persists its completed phase after its final flush.
        // Observe that write too before allowing teardown to remove the fixture.
        try await eventually("The completed saved-processing state did not reach the isolated archive") {
            (try? SessionStore(directory: root).load())?.processing.phase == .completed
        }
        let saved = try XCTUnwrap(SessionStore(directory: root).load())
        XCTAssertEqual(saved.segments, model.segments)
        XCTAssertEqual(saved.batches.count, 1)
        XCTAssertEqual(saved.batches.first?.evidence, model.segments)
        XCTAssertTrue((saved.processing.pendingCaptionRepairs ?? []).isEmpty)
        XCTAssertTrue(saved.audioFiles.isEmpty)
        completedArchives.insert(root)
    }

    private func receivePrevious(_ model: AppModel) async throws {
        model.receiveCaptionForTesting(previousEnglish, start: 0, end: 10)
        try await eventually("The first synthetic caption did not finish") {
            model.translationTaskForTesting == nil
        }
        XCTAssertEqual(model.segments.map(\.chinese), [originalChinese])
    }

    private func sourceUnits(_ input: String) throws -> [LearningSourceUnit] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let evidence = try XCTUnwrap(object["evidence"] as? [[String: Any]])
        return try evidence.map {
            LearningSourceUnit(id: try XCTUnwrap($0["id"] as? String),
                               index: try XCTUnwrap($0["index"] as? Int),
                               language: try XCTUnwrap($0["language"] as? String),
                               text: try XCTUnwrap($0["text"] as? String))
        }
    }

    func testCurrentCaptionIsReadableBeforeInlinePreviousRepairReturns() async throws {
        let repair: PublicationGate<String> = gate()
        let requests = InlinePublicationRequests(current: currentChinese, repair: repair)
        var ordinaryCalls = 0
        var summaryCalls = 0
        let model = try makeModel(.init(translate: { [self] _, _, _, _, _ in
            ordinaryCalls += 1
            return originalChinese
        }, adjacent: { previous, chinese, current, context, name, shouldRepair, hints, update, _ in
            XCTAssertTrue(shouldRepair)
            // Exercise the real adjacent client's validation/publication order;
            // only its generation requests are replaced with synthetic replies.
            return try await QwenTranslationClient.translateAdjacent(previous: previous,
                previousChinese: chinese, current: current, context: context, modelName: name,
                repairPrevious: shouldRepair, currentHints: hints, onCurrent: update,
                request: { _, _, _ in try await requests.request() })
        }), notes: .init(generate: { _, _, _, _ in
            summaryCalls += 1
            XCTFail("A publication-only fixture must not generate notes")
            throw CancellationError()
        }))
        try await receivePrevious(model)
        let previousID = try XCTUnwrap(model.segments.first?.id)
        model.receiveCaptionForTesting(currentEnglish, start: 10, end: 18)
        try await eventually("The inline repair did not reach its gate") { repair.entered }
        let currentID = try XCTUnwrap(model.segments.last?.id)

        XCTAssertFalse(repair.resolved)
        XCTAssertEqual(model.streamingChinese, currentChinese,
                       "Validated current text must be readable while the optional repair is held")
        XCTAssertEqual(model.segments.first?.chinese, originalChinese)
        let heldRequestCount = await requests.count
        XCTAssertEqual(heldRequestCount, 2)
        XCTAssertEqual(ordinaryCalls, 1)
        XCTAssertEqual(summaryCalls, 0)

        repair.finish(.success(repairedChinese))
        try await eventually("The inline translation worker did not finish") {
            model.translationTaskForTesting == nil
        }
        XCTAssertEqual(model.segments.map(\.id), [previousID, currentID])
        XCTAssertEqual(model.segments.map(\.english), [previousEnglish, currentEnglish])
        XCTAssertEqual(model.segments.map(\.chinese), [repairedChinese, currentChinese])
        XCTAssertTrue(model.segments.allSatisfy(\.hasUsableTranslation))
        XCTAssertTrue(model.streamingChinese.isEmpty)
        let finalRequestCount = await requests.count
        XCTAssertEqual(finalRequestCount, 2, "Publishing the current caption must not add a generation")
        XCTAssertEqual(ordinaryCalls, 1)
    }

    func testWithinHoldRepairProducesOnlyOneSummaryUsingRepairedEvidence() async throws {
        let repair: PublicationGate<QwenTranslationClient.PreviousRepair> = gate()
        let generatedNote: PublicationGate<String> = gate()
        var inputs: [String] = []
        var ordinaryCalls = 0
        var adjacentCalls = 0
        var repairCalls = 0
        var archiveHandoff = false
        let model = try makeModel(.init(translate: { [self] _, _, _, _, _ in
            ordinaryCalls += 1
            return originalChinese
        }, adjacent: { [self] _, _, _, _, _, shouldRepair, _, _, _ in
            adjacentCalls += 1
            XCTAssertTrue(shouldRepair)
            return .init(previous: nil, current: currentChinese, previousRejection: nil,
                         currentRejection: nil, previousRepairDeferred: true)
        }, repair: { pending in
            repairCalls += 1
            XCTAssertEqual(pending.previous.english, self.previousEnglish)
            XCTAssertEqual(pending.current.english, self.currentEnglish)
            return try await repair.wait()
        }), notes: .init(generate: { [self] input, _, _, _ in
            inputs.append(input)
            // Let an erroneous live request finish so the no-request assertions
            // catch it instead of leaving a failed fixture indefinitely parked.
            if !archiveHandoff { return note }
            if generatedNote.entered {
                XCTFail("Unexpected repeated summary generation")
                throw CancellationError()
            }
            return try await generatedNote.wait()
        }))
        try await receivePrevious(model)
        model.receiveCaptionForTesting(currentEnglish, start: 10, end: 18)
        try await eventually("The deferred repair did not reach its gate") { repair.entered }
        let captionIDs = model.segments.map(\.id)
        XCTAssertEqual(model.segments.map(\.chinese), [originalChinese, currentChinese])
        XCTAssertTrue(model.segments.allSatisfy(\.hasUsableTranslation),
                      "Deferring the previous repair must not hold back the completed current caption")

        let beforeRepair = summarize(model)
        try await eventually("The held-evidence summary attempt did not return") { beforeRepair.finished }
        XCTAssertTrue(inputs.isEmpty, "The forced testing entry must honor the unresolved repair hold")
        XCTAssertTrue(model.reviewBatchChoices.isEmpty, "Do not publish a batch that the imminent repair will retire")
        XCTAssertTrue(model.lectureSummary.isEmpty)
        XCTAssertFalse(repair.resolved)

        // Note time stays at 100 throughout: this repair is within the default
        // hold even if CI scheduling or real archive I/O takes a long time.
        repair.finish(.success(.init(previous: repairedChinese, rejection: nil)))
        try await eventually("The within-hold repair did not finish") {
            model.translationTaskForTesting == nil
        }
        XCTAssertEqual(model.segments.map(\.id), captionIDs)
        XCTAssertEqual(model.segments.map(\.chinese), [repairedChinese, currentChinese])
        let stillLive = summarize(model)
        try await eventually("The still-held live tail probe did not return") { stillLive.finished }
        XCTAssertTrue(inputs.isEmpty, "Repairing A does not seal tail B or bypass the initial two-caption rule")
        XCTAssertTrue(model.learningNotebookForTesting.batches.isEmpty)

        // This handoff preserves A/B and their revisions but deliberately does
        // not claim coverage of stopping the original live capture in place.
        archiveHandoff = true
        let (root, processing) = try await resumeArchivedCaptions(model)
        try await eventually("Archived repaired evidence never reached note generation") { generatedNote.entered }
        XCTAssertNotNil(model.savedProcessingTaskForTesting, "The real archive drain must remain in flight at the note gate")
        XCTAssertEqual(inputs.count, 1, "A repair inside the hold must not generate and then redo a summary")
        XCTAssertEqual(try sourceUnits(XCTUnwrap(inputs.last)), LearningSourceUnit.make(model.segments),
                       "The note request must freeze the repaired Chinese and unchanged original English")
        XCTAssertTrue(model.reviewBatchChoices.isEmpty, "A held note response must not publish coverage")
        generatedNote.finish(.success(note))
        try await finishArchivedCaptions(model, root: root, task: processing)
        XCTAssertEqual(model.reviewBatchChoices.count, 1)
        XCTAssertEqual(model.learningNotebookForTesting.batches.count, 1)
        XCTAssertEqual(model.learningNotebookForTesting.batches.first?.evidence, model.segments,
                       "The committed batch must retain exactly the repaired evidence snapshot")
        XCTAssertTrue(model.lectureSummary.contains("系统吸收热能，温度随之升高。"))
        let batchID = try XCTUnwrap(model.reviewBatchChoices.first?.id)

        let repeated = summarize(model)
        try await eventually("The already-covered summary probe did not finish") { repeated.finished }
        XCTAssertEqual(inputs.count, 1, "Rechecking already-covered evidence must not regenerate it")
        XCTAssertEqual(model.reviewBatchChoices.map(\.id), [batchID])
        XCTAssertEqual(ordinaryCalls, 1)
        XCTAssertEqual(adjacentCalls, 1)
        XCTAssertEqual(repairCalls, 1)
    }

    func testFailedOrRejectedPreviousRepairReleasesSummaryWithoutRetranslating() async throws {
        let outcomes: [(String, Result<QwenTranslationClient.PreviousRepair, Error>)] = [
            ("runtime failure", .failure(QwenRuntimeError.requestTimedOut)),
            ("rejected repair", .success(.init(previous: nil, rejection: "合成补修被拒绝")))
        ]
        for (label, outcome) in outcomes {
            let repair: PublicationGate<QwenTranslationClient.PreviousRepair> = gate()
            let generatedNote: PublicationGate<String> = gate()
            var ordinaryCalls = 0
            var adjacentCalls = 0
            var repairCalls = 0
            var inputs: [String] = []
            var archiveHandoff = false
            let model = try makeModel(.init(translate: { [self] _, _, _, _, _ in
                ordinaryCalls += 1
                return originalChinese
            }, adjacent: { [self] _, _, _, _, _, _, _, _, _ in
                adjacentCalls += 1
                return .init(previous: nil, current: currentChinese, previousRejection: nil,
                             currentRejection: nil, previousRepairDeferred: true)
            }, repair: { _ in
                repairCalls += 1
                return try await repair.wait()
            }), notes: .init(generate: { [self] input, _, _, _ in
                inputs.append(input)
                // Expose an early generation rather than parking the fixture
                // forever if production fails to honor the unresolved risk.
                if !archiveHandoff { return note }
                if generatedNote.entered {
                    XCTFail("A terminal optional repair must not cause a second note request: \(label)")
                    throw CancellationError()
                }
                return try await generatedNote.wait()
            }))
            try await receivePrevious(model)
            model.receiveCaptionForTesting(currentEnglish, start: 10, end: 18)
            try await eventually("The terminal-repair fixture did not reach its gate: \(label)") { repair.entered }
            let before = model.segments
            XCTAssertTrue(before.allSatisfy(\.hasUsableTranslation))
            XCTAssertEqual(before.map(\.chinese), [originalChinese, currentChinese])

            let heldSummary = summarize(model)
            try await eventually("The held summary attempt did not return: \(label)") { heldSummary.finished }
            XCTAssertTrue(inputs.isEmpty, "Summary evidence must wait until the repair reaches a terminal outcome: \(label)")
            XCTAssertTrue(model.reviewBatchChoices.isEmpty, label)
            repair.finish(outcome)
            try await eventually("Optional repair did not terminate: \(label)") {
                model.translationTaskForTesting == nil
            }
            // A runtime failure and a nil/rejection result both preserve the
            // entire accepted caption snapshot; neither is task cancellation.
            XCTAssertEqual(model.segments, before, label)
            let stillLive = summarize(model)
            try await eventually("The terminal-repair live tail probe did not return: \(label)") { stillLive.finished }
            XCTAssertTrue(inputs.isEmpty, "Terminal repair does not force-seal the remaining live tail: \(label)")
            XCTAssertTrue(model.learningNotebookForTesting.batches.isEmpty, label)

            archiveHandoff = true
            let (root, processing) = try await resumeArchivedCaptions(model)
            try await eventually("Terminal repaired captions did not reach the archive drain: \(label)") { generatedNote.entered }
            XCTAssertNotNil(model.savedProcessingTaskForTesting, label)
            XCTAssertEqual(inputs.count, 1, label)
            XCTAssertEqual(try sourceUnits(XCTUnwrap(inputs.first)), LearningSourceUnit.make(before), label)
            generatedNote.finish(.success(note))
            try await finishArchivedCaptions(model, root: root, task: processing)
            XCTAssertEqual(model.reviewBatchChoices.count, 1, label)
            XCTAssertEqual(model.learningNotebookForTesting.batches.count, 1, label)
            XCTAssertEqual(model.learningNotebookForTesting.batches.first?.evidence, before, label)
            XCTAssertTrue(model.lectureSummary.contains("系统吸收热能，温度随之升高。"), label)

            let repeated = summarize(model)
            try await eventually("The coverage probe did not finish: \(label)") { repeated.finished }
            XCTAssertEqual(inputs.count, 1, label)
            XCTAssertEqual(ordinaryCalls, 1, "A failed previous repair must not restart ordinary translation: \(label)")
            XCTAssertEqual(adjacentCalls, 1, "A rejected previous repair must not restart the current caption: \(label)")
            XCTAssertEqual(repairCalls, 1, "Terminal optional repair must leave the pending queue: \(label)")
            XCTAssertEqual(model.segments, before, label)
        }
    }
}
