import Foundation
import Testing
@testable import LiveLingo

/// Every disk operation is restricted to a newly allocated synthetic course.
struct SessionPersistenceTests {
    @Test func successfulStorageRetryPreservesCaptureFailureAndLegacyErrors() throws {
        var state = SessionProcessingState()
        state.recordFailure("buffer exhausted at 42 seconds", source: .capture)
        state.recordFailure("export directory unavailable", source: .storage)
        let encoded = try JSONEncoder().encode(state)
        state = try JSONDecoder().decode(SessionProcessingState.self, from: encoded)
        #expect(state.clearResolvedStorageFailure() == "export directory unavailable")
        #expect(state.lastError == "buffer exhausted at 42 seconds")
        #expect(state.captureError == state.lastError)
        #expect(state.lastErrorSource == .capture)
        #expect(state.clearResolvedStorageFailure() == nil)
        var ordinary = SessionProcessingState()
        ordinary.recordFailure("temporarily read-only", source: .storage)
        #expect(ordinary.clearResolvedStorageFailure() == "temporarily read-only")
        #expect(ordinary.lastError == nil && ordinary.lastErrorSource == nil)
        var legacy = SessionProcessingState()
        legacy.lastError = "unclassified earlier failure"
        #expect(legacy.clearResolvedStorageFailure() == nil)
        #expect(legacy.lastError == "unclassified earlier failure")
    }

    private struct Fixture {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("LiveLingoPersistenceTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        var directory: URL { root.appendingPathComponent("course", isDirectory: true) }
        var store: SessionStore { SessionStore(directory: directory) }
        var journal: URL { directory.appendingPathComponent(SessionStore.journalFileName) }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    private enum Fault: Error { case injected, timedOut }

    private final class Writes: @unchecked Sendable {
        enum Failure: Equatable { case snapshotBefore(Int), snapshotAfter(Int), journalBefore(Int), journalAfter(Int) }
        private let lock = NSLock()
        private var failure: Failure?
        private var snapshots = 0
        private var journals = 0
        var snapshotCount: Int { lock.withLock { snapshots } }
        func arm(_ failure: Failure) { lock.withLock { self.failure = failure } }
        private func fail(_ position: Failure) throws {
            let matches = lock.withLock {
                guard failure == position else { return false }
                failure = nil
                return true
            }
            if matches { throw Fault.injected }
        }
        private func snapshot(_ data: Data, _ url: URL) throws {
            let count = lock.withLock { snapshots += 1; return snapshots }
            try fail(.snapshotBefore(count))
            try SessionArchiveCoding.atomicWrite(data, url)
            try fail(.snapshotAfter(count))
        }
        private func journal(_ data: Data, _ url: URL) throws {
            let count = lock.withLock { journals += 1; return journals }
            try fail(.journalBefore(count))
            try SessionArchiveCoding.appendAndSync(data, url)
            try fail(.journalAfter(count))
        }
        func store(at directory: URL) -> SessionStore {
            SessionStore(directory: directory, atomicWrite: { try self.snapshot($0, $1) },
                         journalWrite: { try self.journal($0, $1) })
        }
    }

    private final class WriteBarrier: @unchecked Sendable {
        let started: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var writes = 0
        private let failFirst: Bool
        var count: Int { lock.withLock { writes } }
        init(failFirst: Bool = false) {
            self.failFirst = failFirst
            let stream = AsyncStream<Void>.makeStream()
            started = stream.stream
            continuation = stream.continuation
        }
        func release() { semaphore.signal() }
        func write(_ data: Data, _ url: URL) throws {
            let count = lock.withLock { writes += 1; return writes }
            if count == 1 {
                continuation.yield()
                guard semaphore.wait(timeout: .now() + 10) == .success else { throw Fault.timedOut }
                if failFirst { throw Fault.injected }
            }
            try SessionArchiveCoding.atomicWrite(data, url)
        }
    }

    private func segment(id: UUID = UUID(), revision: Int = 0,
                         english: String = "A preserved synthetic source.", chinese: String = "") -> TranscriptSegment {
        .init(id: id, startTime: 1, endTime: 3, english: english, chinese: chinese, inputRevision: revision)
    }

    private func batch(_ evidence: [TranscriptSegment]) -> LearningNoteBatch {
        .init(id: UUID(), evidence: evidence,
              note: .init(topic: "合成课堂", points: [.init(kind: "核心结论", text: "保留原有知识。")]))
    }

    private func checkpoint(_ snapshot: SessionSnapshot, evidence: [UUID]) -> SessionGenerationCheckpoint {
        let input = "Frozen synthetic input"
        return .init(sessionID: snapshot.sessionID, inputRevision: snapshot.inputRevision,
                     modelName: "test-model", protocolVersion: 2,
                     inputDigest: SessionArchiveCoding.digest(Data(input.utf8)),
                     promptDigest: SessionArchiveCoding.digest(Data("test-prompt".utf8)),
                     input: input, prefix: "saved-prefix", evidenceIDs: evidence)
    }

    @Test func coalescedCorrectionsPreserveTheirInterveningTranslation() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let writer = SessionArchiveWriter(directory: fixture.directory)
        let original = segment(chinese: "最初的译文。")
        var desired = try await writer.commit(SessionSnapshot(segments: [original]))
        let first = segment(id: original.id, revision: 1, english: "First corrected input.")
        var translated = first
        translated.completeTranslation("第一次修订的完整译文。")
        let second = segment(id: original.id, revision: 2, english: "Second corrected input.")
        desired.inputRevision = 2
        desired.segments = [second]
        desired.revisionHistory = [
            .init(fromRevision: 0, toRevision: 1, previousSegment: original, replacementSegment: first,
                  reason: "First confirmation"),
            .init(fromRevision: 1, toRevision: 2, previousSegment: translated, replacementSegment: second,
                  reason: "Second confirmation")
        ]
        let saved = try await writer.commit(desired)
        #expect(saved.segments == [second])
        #expect(saved.revisionHistory[1].previousSegment.chinese == translated.chinese)
        #expect(saved.lastJournalSequence == 3)
        #expect(try fixture.store.load() == saved)
        _ = try await writer.commit(desired)
        #expect(try fixture.store.load()?.lastJournalSequence == 3)
    }

    @Test func correctionBeforeFirstSegmentSaveRetainsUnwrittenOriginalAndBatch() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let writer = SessionArchiveWriter(directory: fixture.directory)
        var desired = try await writer.commit(SessionSnapshot())
        let original = segment(chinese: "修订前的完整译文。")
        let oldBatch = batch([original])
        let corrected = segment(id: original.id, revision: 1, english: "User-confirmed correction.")
        desired.inputRevision = 1
        desired.segments = [corrected]
        desired.notebookRevision = 2
        desired.revisionHistory = [.init(fromRevision: 0, toRevision: 1, previousSegment: original,
            replacementSegment: corrected, retainedBatches: [oldBatch], reason: "Confirmed before coalesced save")]
        let saved = try await writer.commit(desired)
        #expect(saved.segments == [corrected])
        #expect(saved.batches.isEmpty)
        #expect(saved.revisionHistory[0].previousSegment == original)
        #expect(saved.revisionHistory[0].retainedBatches == [oldBatch])
        #expect(saved.notebookRevision == 2)
        #expect(saved.lastJournalSequence == 3)
        #expect(try fixture.store.load() == saved)
    }

    @Test(arguments: [false, true])
    func retryAfterPartialJournalSuccessDoesNotRepeatOrLoseAcceptedText(failAfterWrite: Bool) async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let writes = Writes()
        let writer = SessionArchiveWriter(store: writes.store(at: fixture.directory))
        var desired = try await writer.commit(SessionSnapshot())
        desired.segments = [segment(), segment(english: "The second accepted source.")]
        desired.processing.paused = true
        writes.arm(failAfterWrite ? .journalAfter(2) : .journalBefore(2))
        await #expect(throws: Fault.self) { try await writer.commit(desired) }
        let interrupted = try #require(try fixture.store.load())
        #expect(interrupted.segments == Array(desired.segments.prefix(failAfterWrite ? 2 : 1)))
        let saved = try await writer.commit(desired)
        #expect(saved.segments == desired.segments)
        #expect(saved.processing.paused)
        #expect(saved.lastJournalSequence == 3)
        #expect(try Data(contentsOf: fixture.journal).split(separator: 10).count == 3)
        #expect(try fixture.store.load() == saved)
    }

    @Test(arguments: [false, true])
    func retryAfterSnapshotFailureUsesTheActualDiskRevision(failAfterWrite: Bool) async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let writes = Writes()
        let writer = SessionArchiveWriter(store: writes.store(at: fixture.directory))
        var desired = try await writer.commit(SessionSnapshot(segments: [segment()]))
        desired.processing.paused = true
        writes.arm(failAfterWrite ? .snapshotAfter(2) : .snapshotBefore(2))
        await #expect(throws: Fault.self) { try await writer.commit(desired) }
        let interrupted = try #require(try fixture.store.load())
        #expect(interrupted.processing.paused)
        let saved = try await writer.commit(desired)
        #expect(saved.storageRevision > interrupted.storageRevision)
        #expect(saved.lastJournalSequence == 1)
        #expect(saved.segments == desired.segments)
        #expect(try fixture.store.load() == saved)
    }

    @Test func failedCheckpointStillReplaysBatchRetirementAndOnlyDependentInvalidation() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let writes = Writes()
        let writer = SessionArchiveWriter(store: writes.store(at: fixture.directory))
        var initial = SessionSnapshot(segments: [segment(), segment(english: "Unrelated evidence.")])
        let oldBatch = batch([initial.segments[0]])
        initial.batches = [oldBatch]
        initial.latestEvidenceIDs = oldBatch.ids
        initial.notebookRevision = 1
        initial.generationCheckpoints = [checkpoint(initial, evidence: [initial.segments[0].id]),
                                         checkpoint(initial, evidence: [initial.segments[1].id])]
        var desired = try await writer.commit(initial)
        let original = desired.segments[0]
        let replacement = segment(id: original.id, revision: 1, english: "Confirmed correction.")
        desired.segments[0] = replacement
        desired.inputRevision = 1
        desired.batches = []
        desired.latestEvidenceIDs = []
        desired.notebookRevision = 2
        desired.revisionHistory = [.init(fromRevision: 0, toRevision: 1, previousSegment: original,
            replacementSegment: replacement, retainedBatches: [oldBatch], reason: "Confirmed correction")]
        desired.generationCheckpoints[0].invalidated = true
        desired.generationCheckpoints[1].prefix += "-continued"
        writes.arm(.snapshotBefore(2))
        await #expect(throws: Fault.self) { try await writer.commit(desired) }
        let replayed = try #require(try fixture.store.load())
        #expect(replayed.batches.isEmpty)
        #expect(replayed.latestEvidenceIDs.isEmpty)
        #expect(replayed.revisionHistory[0].retainedBatches == [oldBatch])
        #expect(replayed.generationCheckpoints[0].invalidated)
        #expect(replayed.canResume(replayed.generationCheckpoints[1]))
        #expect(replayed.generationCheckpoints[1].prefix == desired.generationCheckpoints[1].prefix)
        let saved = try await writer.commit(desired)
        #expect(saved.revisionHistory.count == 1)
        #expect(saved.lastJournalSequence == replayed.lastJournalSequence)
        #expect(saved.batches.isEmpty)
        #expect(try fixture.store.load() == saved)
    }

    @Test func externalAppendRequiresCompleteDesiredStateBeforeRetry() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let writer = SessionArchiveWriter(directory: fixture.directory)
        let initial = try await writer.commit(SessionSnapshot(segments: [segment()]))
        let external = segment(english: "Externally saved accepted source.")
        var fresh = try fixture.store.append(.upsertSegment(external))
        let before = try Data(contentsOf: fixture.journal)
        var stale = initial
        stale.processing.paused = true
        await #expect(throws: SessionStoreError.self) { try await writer.commit(stale) }
        #expect(try Data(contentsOf: fixture.journal) == before)
        fresh.processing.paused = true
        let saved = try await writer.commit(fresh)
        #expect(saved.segments == fresh.segments)
        #expect(saved.processing.paused)
        #expect(saved.lastJournalSequence == 2)
    }

    @MainActor @Test func inFlightSaveKeepsOneLatestPendingStateAndFlushWaitsForDisk() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let barrier = WriteBarrier(); defer { barrier.release() }
        let store = SessionStore(directory: fixture.directory, atomicWrite: { try barrier.write($0, $1) })
        let writer = SessionArchiveWriter(store: store)
        var desired = SessionSnapshot(segments: [segment()])
        let coordinator = SessionSaveCoordinator(directory: fixture.directory, sessionID: desired.sessionID,
                                                  coalescingInterval: .zero, writer: writer)
        coordinator.submit(desired)
        var entered = barrier.started.makeAsyncIterator()
        _ = await entered.next()
        for index in 0..<200 {
            desired.processing.lastCapturedTime = Double(index)
            coordinator.submit(desired)
        }
        var finished = false
        let flush = Task {
            let result = try await coordinator.flush()
            finished = true
            return result
        }
        await Task.yield()
        #expect(!finished)
        #expect(coordinator.hasPendingWrite)
        #expect(barrier.count == 1)
        barrier.release()
        let saved = try #require(try await flush.value)
        #expect(finished)
        #expect(saved.processing.lastCapturedTime == 199)
        #expect(barrier.count == 2)
        #expect(saved == coordinator.lastSavedSnapshot)
        #expect(try fixture.store.load() == saved)
        #expect(!coordinator.hasPendingWrite)
    }

    @MainActor @Test func failedPumpStaysIdleUntilAnExplicitRetryAndRetainsNewestSubmission() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let writes = Writes()
        writes.arm(.snapshotBefore(1))
        let writer = SessionArchiveWriter(store: writes.store(at: fixture.directory))
        var desired = SessionSnapshot(segments: [segment()])
        let coordinator = SessionSaveCoordinator(directory: fixture.directory, sessionID: desired.sessionID,
                                                  coalescingInterval: .zero, writer: writer)
        let failures = AsyncStream<Void>.makeStream()
        coordinator.onFailure = { _ in failures.continuation.yield() }
        coordinator.submit(desired)
        var failed = failures.stream.makeAsyncIterator()
        _ = await failed.next()
        try await Task.sleep(for: .milliseconds(30))
        #expect(writes.snapshotCount == 1)
        #expect(coordinator.lastError != nil)
        #expect(coordinator.hasPendingWrite)
        writes.arm(.snapshotBefore(2))
        await #expect(throws: Fault.self) { try await coordinator.flush() }
        #expect(writes.snapshotCount == 2)
        desired.segments.append(segment(english: "Newest accepted source after failure."))
        coordinator.submit(desired)
        let saved = try #require(try await coordinator.flush())
        #expect(saved.segments == desired.segments)
        #expect(coordinator.lastError == nil)
        #expect(!coordinator.hasPendingWrite)
        #expect(writes.snapshotCount == 3)
    }

    @MainActor @Test func failureDuringAnInFlightSaveKeepsTheNewestPendingSnapshot() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let barrier = WriteBarrier(failFirst: true); defer { barrier.release() }
        let store = SessionStore(directory: fixture.directory, atomicWrite: { try barrier.write($0, $1) })
        let writer = SessionArchiveWriter(store: store)
        var desired = SessionSnapshot(segments: [segment()])
        let coordinator = SessionSaveCoordinator(directory: fixture.directory, sessionID: desired.sessionID,
                                                  coalescingInterval: .zero, writer: writer)
        let failures = AsyncStream<Void>.makeStream()
        coordinator.onFailure = { _ in failures.continuation.yield() }
        coordinator.submit(desired)
        var entered = barrier.started.makeAsyncIterator()
        _ = await entered.next()
        for index in 0..<20 {
            desired.segments.append(segment(english: "Accepted while saving: \(index)."))
            coordinator.submit(desired)
        }
        barrier.release()
        var failed = failures.stream.makeAsyncIterator()
        _ = await failed.next()
        try await Task.sleep(for: .milliseconds(30))
        #expect(barrier.count == 1)
        #expect(coordinator.hasPendingWrite)
        let saved = try #require(try await coordinator.flush())
        #expect(saved.segments == desired.segments)
        #expect(barrier.count == 2)
        #expect(!coordinator.hasPendingWrite)
    }

    @MainActor @Test func middleCorruptionIsReportedAndOriginalFilesStayUntouched() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try fixture.store.save(SessionSnapshot())
        try fixture.store.append(.upsertSegment(segment()))
        let prefix = try Data(contentsOf: fixture.journal)
        let desired = try fixture.store.append(.processing(.init(phase: .paused, paused: true)))
        let complete = try Data(contentsOf: fixture.journal)
        var corrupted = prefix
        corrupted.append(Data("{}\n".utf8))
        corrupted.append(complete.dropFirst(prefix.count))
        try corrupted.write(to: fixture.journal)
        let snapshotURL = fixture.directory.appendingPathComponent(SessionStore.snapshotFileName)
        let oldSnapshot = try Data(contentsOf: snapshotURL)
        let coordinator = SessionSaveCoordinator(directory: fixture.directory, sessionID: desired.sessionID,
                                                  coalescingInterval: .zero)
        var reported: SessionStoreError?
        coordinator.onFailure = { reported = $0 as? SessionStoreError }
        coordinator.submit(desired)
        await #expect(throws: SessionStoreError.corruptJournal(line: 2)) { try await coordinator.flush() }
        #expect(reported == .corruptJournal(line: 2))
        #expect(coordinator.hasPendingWrite)
        #expect(coordinator.lastSavedSnapshot == nil)
        #expect(try Data(contentsOf: fixture.journal) == corrupted)
        #expect(try Data(contentsOf: snapshotURL) == oldSnapshot)
    }

    @MainActor @Test func migrationRebindUsesLatestSnapshotAndPreservesTheOriginalCourse() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let initial = SessionSnapshot(segments: [segment()])
        let coordinator = SessionSaveCoordinator(directory: fixture.directory, sessionID: initial.sessionID,
                                                  coalescingInterval: .zero)
        var observed: SessionSnapshot?
        coordinator.onSaved = { observed = $0 }
        coordinator.submit(initial)
        let saved = try #require(try await coordinator.flush())
        #expect(observed == saved)
        #expect(saved.storageRevision == 1)
        let destination = fixture.root.appendingPathComponent("migrated", isDirectory: true)
        let receipt = try SessionTreeMigration.promote(from: fixture.directory, to: destination)
        let preserved = try #require(receipt.preservedSourceDirectory)
        #expect(try SessionStore(directory: preserved).load() == saved)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        let rebound = SessionSaveCoordinator(directory: destination, sessionID: saved.sessionID,
                                              restored: saved, coalescingInterval: .zero)
        var next = saved
        next.segments.append(segment(english: "Accepted source after migration."))
        rebound.submit(next)
        let migrated = try #require(try await rebound.flush())
        #expect(migrated.sessionID == initial.sessionID)
        #expect(migrated.segments == next.segments)
        #expect(migrated.storageRevision > saved.storageRevision)
        #expect(try SessionStore(directory: destination).load() == migrated)
        #expect(try SessionStore(directory: preserved).load() == saved)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        var late = initial
        late.processing.paused = true
        coordinator.submit(late)
        await #expect(throws: SessionStoreError.missingSnapshot) { try await coordinator.flush() }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        #expect(try SessionStore(directory: destination).load() == migrated)
        #expect(try SessionStore(directory: preserved).load() == saved)
    }
}
