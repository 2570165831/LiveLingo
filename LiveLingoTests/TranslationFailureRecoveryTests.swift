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

@MainActor
final class TranslationFailureRecoveryTests: XCTestCase {
    typealias Reason = TranscriptSegment.TranslationFailureReason
    private let source = "The room is cold."
    private let result = "房间很冷。"

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
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LiveLingo-Item7-\(UUID())"))
        // Volatile overrides avoid changing a persistent preference domain.
        defaults.setVolatileDomain(["LiveLingo.modelMode": ModelMode.energySaver.rawValue], forName: UserDefaults.argumentDomain)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
                XCTFail("Failure recovery tests must not start a model or review")
                throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: dependencies, notes: .unavailable,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
        model.resetTranslationSessionForTesting()
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
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
            (CancellationError(), .cancelled), (URLError(.cancelled), .cancelled),
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

    func testFutureReasonsMergeIntoUnknownAndInvalidCountsAreRejected() throws {
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
            XCTAssertThrowsError(try JSONDecoder().decode(TranscriptSegment.self,
                from: JSONSerialization.data(withJSONObject: object)))
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

    func testRepeatedTimeoutStopsAfterTwoAttemptsAndLaterCaptionStillCompletes() async throws {
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
        XCTAssertEqual(calls, 3); XCTAssertEqual(sleeps, 1)
        XCTAssertEqual(model.segments[0].translationState, .failed)
        XCTAssertEqual(model.segments[0].translationFailures, [.init(reason: .requestTimedOut, count: 2)])
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
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.segments[0].translationState, .failed)
        XCTAssertEqual(model.segments[0].translationFailures, [.init(reason: .cancelled, count: 1)])
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
        XCTAssertEqual(model.segments[0].translationFailures, [.init(reason: .cancelled, count: 1)])
        XCTAssertNil(model.translationTaskForTesting)
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

    func testInterruptedSnapshotReopensWithoutStartingWorkAndKeepsReason() async throws {
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
            [.init(reason: .processExited, count: 1), .init(reason: .interrupted, count: 1)])
        model.resumeSavedProcessing()
        try await eventually { model.segments[0].hasUsableTranslation }
        await model.savedProcessingTaskForTesting?.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try SessionStore(directory: root).load()?.segments, model.segments)
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
            [.init(reason: .requestTimedOut, count: 1), .init(reason: .cancelled, count: 1)])
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

    func testCancellingRetryWaitLeavesTerminationToTheExistingOwner() async throws {
        let root = try directory(), modelName = "qwen3.5-4b-mlx"
        let script = root.appendingPathComponent("fake-caption-worker.pl")
        try Self.fakeWorker.write(to: script, atomically: true, encoding: .utf8)
        let runtime = MLXRuntime(testConfiguration: .init(python: URL(fileURLWithPath: "/usr/bin/perl"),
            script: script, models: root, state: root, controlTimeout: 1))
        addTeardownBlock { try? await runtime.finishRetirementBeforeRetry(modelName); await runtime.unload(modelName) }
        do {
            _ = try await runtime.generate(model: modelName, prompt: "retirement", input: "", prefix: "",
                thinking: false, purpose: "text", finalBudget: 64, timeout: 5, onUpdate: { _ in })
            XCTFail("The fake worker must close its output")
        } catch QwenRuntimeError.processExited {}
        let waiter = Task { try await runtime.finishRetirementBeforeRetry(modelName) }
        waiter.cancel()
        do { try await waiter.value; XCTFail("A cancelled retry must stop waiting") }
        catch is CancellationError {}
        let retiring = await runtime.resourceStates()[modelName]
        XCTAssertTrue(retiring?.retiring == true, "Cancelling the waiter must not terminate the process itself")
        try await runtime.finishRetirementBeforeRetry(modelName)
        let remaining = await runtime.resourceStates()
        XCTAssertTrue(remaining.isEmpty)
        let boots = try String(contentsOf: root.appendingPathComponent("boots"), encoding: .utf8)
        XCTAssertEqual(boots.split(separator: "\n").count, 1, "Cancellation must not start a replacement model")
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
