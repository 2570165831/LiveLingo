import Foundation
import XCTest
@testable import LiveLingo

/// Exercises real AppModel draft creation/reuse and archived checkpoints.
/// The production owner supplies the agreed DEBUG clock/observation seams.
@MainActor
final class CaptionStabilityDraftTests: XCTestCase {
    private struct Request {
        let input: String
        let prefix: String
    }

    private final class Time {
        var now: TimeInterval = 100
    }

    private let response = #"{"sourceVersion":2,"topic":"小车运动","points":[{"kind":"核心结论","text":"B 车全程保持每秒两米的速度。","sourceIDs":["en0s0","en1s0"]}]}"#
    private let retainedPrefix = #"{"sourceVersion":2,"topic":"小车"#

    private static func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the isolated archive to park")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func makeModel(time: Time, notes: LearningGenerationDependencies) throws -> AppModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingo-StabilityDraft-\(UUID())", isDirectory: true)
        let suite = "LiveLingo-StabilityDraft-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("review.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
                XCTFail("Draft acceptance must not invoke review")
                throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: notes,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
        model.resetTranslationSessionForTesting()
        model.configureNoteSchedulingForTesting(now: { time.now }, sleep: { _ in
            XCTFail("Direct draft checks must not create a scheduled note task")
            throw CancellationError()
        }, allowConcurrent: true)
        addTeardownBlock {
            _ = await MainActor.run { model.resetTranslationSessionForTesting() }
            await queue.shutdownForTesting()
            UserDefaults.standard.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        return model
    }

    private func payload(_ request: Request) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.input.utf8)) as? [String: Any])
    }

    func testRetainedDraftDropsChangedDependencyButKeepsPrefixForUnrelatedRevision() async throws {
        for dependsOnEarlier in [true, false] {
            let time = Time()
            var requests: [Request] = []
            let prefix = retainedPrefix, note = response
            let model = try makeModel(time: time, notes: .init(generate: { input, _, continuation, update in
                requests.append(Request(input: input, prefix: continuation))
                if requests.count == 1 {
                    await update(prefix)
                    throw QwenRuntimeError.generationInterrupted("Synthetic retained draft")
                }
                XCTAssertEqual(requests.count, 2, "A revision must not cause unbounded retries")
                return note
            }))
            let earlier = TranscriptSegment(startTime: 0, endTime: 8,
                english: dependsOnEarlier ? "Its speed is not known yet." : "The cup is made of glass.",
                chinese: dependsOnEarlier ? "速度仍待后文说明。" : "杯子由玻璃制成。")
            let current = TranscriptSegment(startTime: 8, endTime: 16,
                english: "Cart B moves at two metres per second.", chinese: "B 车的速度为每秒两米。")
            let next = TranscriptSegment(startTime: 16, endTime: 24,
                english: "Cart B keeps this speed for the whole journey.", chinese: "B 车全程保持该速度。")
            let tail = TranscriptSegment(startTime: 24, endTime: 32,
                english: "The lecturer will discuss acceleration next.", chinese: "老师接下来会讨论加速度。")
            var notebook = LearningNotebook()
            try notebook.append(evidence: [earlier], note: .init(topic: "先前记录", points: [
                .init(kind: dependsOnEarlier ? "待确认" : "核心结论", text: earlier.chinese,
                    needsContext: dependsOnEarlier ? "速度属于哪辆车？" : nil, sourceIDs: ["en0s0"])
            ], sourceVersion: 2))
            model.loadPresentationForTesting(phase: .recording,
                evidence: [earlier, current, next, tail], notebook: notebook)

            await model.generateSummaryForTesting()
            XCTAssertEqual(requests.count, 1)
            let first = try XCTUnwrap(requests.first)
            let pending = try XCTUnwrap(try payload(first)["pendingPoints"] as? [[String: Any]])
            XCTAssertEqual(pending.isEmpty, !dependsOnEarlier,
                "The fixture must actually exercise a prior-source dependency")
            XCTAssertEqual(model.learningNotebookForTesting.batches.count, 1,
                "An interrupted draft must not commit coverage")

            model.reviseCaptionForTesting(id: earlier.id, english: "The earlier statement has been revised.")
            // Past the first failure backoff, still before the held tail's 20s deadline.
            time.now += 11
            await model.generateSummaryForTesting()

            XCTAssertEqual(requests.count, 2)
            let resumed = try XCTUnwrap(requests.last)
            XCTAssertEqual(resumed.prefix, dependsOnEarlier ? "" : prefix,
                "Only the complete dependency set may invalidate the retained prefix")
            if !dependsOnEarlier {
                XCTAssertEqual(resumed.input, first.input, "Unrelated source edits preserve frozen input")
            } else {
                XCTAssertNotEqual(resumed.input, first.input, "Stale pending evidence must leave the new input")
            }
            let batches = model.learningNotebookForTesting.batches
            XCTAssertEqual(batches.count, 1, "Only the revised old batch is retired, without duplicate new batches")
            XCTAssertEqual(Set(try XCTUnwrap(batches.first).ids), Set([current.id, next.id]))
            XCTAssertFalse(batches.flatMap(\.ids).contains(tail.id), "The live tail is still held")
            XCTAssertTrue(model.lectureSummary.contains("B 车全程保持每秒两米的速度。"))
        }
    }

    func testRestoredDraftChecksCoveredRepairDependencyAndPreservesPrefixAtBoundedAdmission() async throws {
        let time = Time()
        var requests: [Request] = []
        let note = response
        let model = try makeModel(time: time, notes: .init(generate: { input, _, prefix, _ in
            requests.append(.init(input: input, prefix: prefix))
            return note
        }))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingo-StabilityCheckpoint-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock {
            // Parking completes the isolated archive writer before its fixture is removed.
            await model.pauseSavedProcessing()
            try await Self.eventually { model.savedProcessingIsPaused }
            try await model.savedPauseTaskForTesting?.value
            await model.savedProcessingTaskForTesting?.value
            _ = await MainActor.run { model.resetTranslationSessionForTesting() }
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        var snapshot = SessionSnapshot()
        let earlier = TranscriptSegment(startTime: 0, endTime: 8,
            english: "Its speed is not known yet.", chinese: "速度仍待后文说明。", sessionID: snapshot.sessionID)
        let successor = TranscriptSegment(startTime: 8, endTime: 16,
            english: "The lecturer continues the explanation.", chinese: "老师继续讲解。", sessionID: snapshot.sessionID)
        let current = TranscriptSegment(startTime: 30, endTime: 38,
            english: "Cart B moves at two metres per second.", chinese: "B 车的速度为每秒两米。", sessionID: snapshot.sessionID)
        let next = TranscriptSegment(startTime: 40, endTime: 48,
            english: "Cart B keeps this speed for the whole journey.", chinese: "B 车全程保持该速度。", sessionID: snapshot.sessionID)
        // An untranslated, non-adjacent successor preserves the real topology:
        // next is not the live tail, but this fixture must not summarize missing translation.
        let tail = TranscriptSegment(startTime: 60, endTime: 68,
            english: "The lecturer will discuss acceleration next.", sessionID: snapshot.sessionID)
        var notebook = LearningNotebook()
        try notebook.append(evidence: [earlier], note: .init(topic: "先前记录", points: [
            .init(kind: "待确认", text: earlier.chinese, needsContext: "速度属于哪辆车？", sourceIDs: ["en0s0"])
        ], sourceVersion: 2))
        try notebook.append(evidence: [successor], note: .init(topic: "课堂过渡", points: [],
            sourceVersion: 2, noNewKnowledge: true))
        let pending = notebook.selectPendingPoints(for: [current, next])
        XCTAssertTrue(pending.flatMap(\.dependencyIDs).contains(earlier.id))
        let input = try LearningPrompts.input(evidence: [current, next], topics: notebook.topics, pending: pending)
        let modelName = model.effectiveProfile.translationModel
        var draft = LearningDraft(evidence: [current, next], model: modelName, input: input,
            text: retainedPrefix, attempts: 1, pendingTargets: pending.map(\.id),
            contextRevision: notebook.revision, dependencyIDs: [current.id, next.id, earlier.id])
        draft.freezeBinding(sessionID: snapshot.sessionID, inputRevision: snapshot.inputRevision,
            generation: snapshot.generation)
        snapshot.segments = [earlier, successor, current, next, tail]
        notebook.writeState(to: &snapshot)
        snapshot.generationCheckpoints = [draft.checkpoint(sessionID: snapshot.sessionID,
            inputRevision: snapshot.inputRevision, generation: snapshot.generation)]
        snapshot.processing.pendingCaptionRepairs = [DeferredCaptionRepair(sessionID: snapshot.sessionID,
            previous: earlier, current: successor, context: [], normalizedCurrent: successor.english,
            modelName: modelName)]
        snapshot.processing.paused = true
        snapshot.processing.phase = .paused
        _ = try SessionStore(directory: directory).save(snapshot)
        XCTAssertNotNil(LearningDraft(checkpoint: snapshot.generationCheckpoints[0], snapshot: snapshot, model: modelName),
            "The archive must contain a valid restorable checkpoint, not a silently rejected fixture")
        model.loadPresentationForTesting(phase: .idle, evidence: [])
        try await model.openSavedSession(directory, allowAutomaticProcessing: false)
        XCTAssertTrue(requests.isEmpty)

        // This direct seam explicitly unpauses; this is dependency admission, not a pause test.
        await model.generateSummaryForTesting()
        XCTAssertTrue(requests.isEmpty,
            "Stable batch evidence cannot bypass a covered-but-risky pending-question dependency")
        XCTAssertEqual(model.learningNotebookForTesting.batches.count, 2)

        time.now += 20
        await model.generateSummaryForTesting()
        XCTAssertEqual(requests.count, 1)
        let first = try XCTUnwrap(requests.first)
        XCTAssertEqual(first.prefix, retainedPrefix, "Admission delay must preserve valid continuation text")
        XCTAssertEqual(first.input, input)
        XCTAssertTrue(model.learningNotebookForTesting.batches.contains { Set($0.ids) == Set([current.id, next.id]) },
            "The unchanged checkpoint may commit once the bounded dependency hold expires")
    }
}
