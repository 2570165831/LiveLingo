import Darwin
import Foundation
import XCTest
@testable import LiveLingo

final class SessionEnergyTests: XCTestCase {
    private final class IO: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var snapshots = 0
        private var journals = 0
        private var directorySyncs = 0
        var counts: [Int] { lock.withLock { [reads, journals, snapshots] } }
        var directorySyncCount: Int { lock.withLock { directorySyncs } }
        func observe(_ operation: SensitiveFileIO.OptionalOperation) {
            if operation == .directorySync { lock.withLock { directorySyncs += 1 } }
        }
        func reset() { lock.withLock { reads = 0; snapshots = 0; journals = 0; directorySyncs = 0 } }
        func store(_ directory: URL) -> SessionStore {
            SessionStore(directory: directory, atomicWrite: { data, url in
                try SessionArchiveCoding.atomicWrite(data, url)
                self.lock.withLock { self.snapshots += 1 }
            }, journalWrite: { data, url in
                try SessionArchiveCoding.appendAndSync(data, url)
                self.lock.withLock { self.journals += 1 }
            }, didRead: { self.lock.withLock { self.reads += 1 } })
        }
    }

    private func fixture() throws -> URL {
        let root = TestFixtureDirectory.root.appendingPathComponent("SessionEnergy-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    // The old writer's load/append/save sequence for this synthetic workload.
    // Execute the same durable store operations; do not estimate their counts.
    private func baselineCommit(_ desired: SessionSnapshot, store: SessionStore) throws -> SessionSnapshot {
        var current = try XCTUnwrap(store.load())
        try SessionStore.validatePreservation(from: current, to: desired)
        for segment in desired.segments where current.segments.first(where: { $0.id == segment.id }) != segment {
            current = try store.append(.upsertSegment(segment), expectedRevision: current.storageRevision)
        }
        if current.processing != desired.processing {
            current = try store.append(.processing(desired.processing), expectedRevision: current.storageRevision)
        }
        var next = desired
        next.storageRevision = current.storageRevision
        next.lastJournalSequence = current.lastJournalSequence
        next.lastJournalDigest = current.lastJournalDigest
        return try store.save(next)
    }

    func testSyntheticCommitCountsBeforeAndAfter() async throws {
        let root = try fixture()
        for segmentCount in [0, 2, 31] {
            let beforeIO = IO(), afterIO = IO()
            let before = beforeIO.store(root.appendingPathComponent("before-\(segmentCount)"))
            let after = afterIO.store(root.appendingPathComponent("after-\(segmentCount)"))
            let original = SessionSnapshot(createdAt: Date(timeIntervalSince1970: 100))
            var desired = try before.save(original)
            _ = try after.save(original)
            desired.segments = (0..<segmentCount).map {
                TranscriptSegment(startTime: Double($0), endTime: Double($0 + 1),
                                  english: "Synthetic caption \($0).", chinese: "合成字幕。")
            }
            desired.processing.paused = segmentCount > 0
            beforeIO.reset(); afterIO.reset()
            let old = try SensitiveFileIO.$operationObserver.withValue({ beforeIO.observe($0) }) {
                try baselineCommit(desired, store: before)
            }
            let saved = try await SensitiveFileIO.$operationObserver.withValue({ afterIO.observe($0) }) {
                try await SessionArchiveWriter(store: after).commit(desired)
            }
            let events = segmentCount + (segmentCount > 0 ? 1 : 0)
            XCTAssertEqual(beforeIO.counts, [events + 2, events, 1])
            XCTAssertEqual(afterIO.counts, [1, events, events > 0 ? 1 : 0])
            XCTAssertEqual(beforeIO.directorySyncCount, events + 1)
            XCTAssertEqual(afterIO.directorySyncCount, events > 0 ? events + 1 : 0)
            print("ENERGY_SESSION events=\(events) before_reads=\(beforeIO.counts[0]) after_reads=\(afterIO.counts[0]) before_journal_writes=\(beforeIO.counts[1]) after_journal_writes=\(afterIO.counts[1]) before_snapshot_writes=\(beforeIO.counts[2]) after_snapshot_writes=\(afterIO.counts[2]) before_directory_syncs=\(beforeIO.directorySyncCount) after_directory_syncs=\(afterIO.directorySyncCount)")
            XCTAssertEqual(saved.segments, old.segments)
            XCTAssertEqual(saved.processing, old.processing)
            XCTAssertEqual(saved.lastJournalSequence, old.lastJournalSequence)
            XCTAssertEqual(saved.lastJournalDigest, old.lastJournalDigest)
            XCTAssertEqual(try after.load(), saved)
        }
    }

    func testUnchangedCommitPreservesBytesRevisionAndExistingPermissions() async throws {
        let root = try fixture(), io = IO()
        let store = io.store(root.appendingPathComponent("course"))
        let writer = SessionArchiveWriter(store: store)
        let saved = try await writer.commit(SessionSnapshot())
        let url = store.directory.appendingPathComponent(SessionStore.snapshotFileName)
        let bytes = try Data(contentsOf: url)
        var unchanged = saved
        unchanged.updatedAt = saved.updatedAt.addingTimeInterval(1)
        io.reset()
        let originalMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(originalMode.intValue & 0o777, 0o600)
        XCTAssertEqual(chmod(url.path, 0o400), 0)
        let repeated = try await writer.commit(unchanged)
        XCTAssertEqual(repeated, saved)
        XCTAssertEqual(io.counts, [1, 0, 0])
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o400)
    }

    func testUnchangedCommitStillValidatesCompleteJournalAndIncompleteTail() async throws {
        let root = try fixture(), io = IO()
        let store = io.store(root.appendingPathComponent("course"))
        let writer = SessionArchiveWriter(store: store)
        let saved = try await writer.commit(SessionSnapshot())
        let journal = store.directory.appendingPathComponent(SessionStore.journalFileName)
        try Data("{".utf8).write(to: journal)
        io.reset()
        do {
            _ = try await writer.commit(saved)
            XCTFail("An unchanged submission must reject an incomplete tail")
        } catch SessionStoreError.incompleteJournalTail(let bytes) { XCTAssertEqual(bytes, 1) }
        XCTAssertEqual(io.counts, [1, 0, 0])
        XCTAssertEqual(try Data(contentsOf: journal), Data("{".utf8))
    }

    func testUnchangedCommitRejectsCorruptSnapshot() async throws {
        let root = try fixture(), io = IO()
        let store = io.store(root.appendingPathComponent("course"))
        let writer = SessionArchiveWriter(store: store)
        let saved = try await writer.commit(SessionSnapshot())
        let url = store.directory.appendingPathComponent(SessionStore.snapshotFileName)
        let corrupt = Data("{\"schemaVersion\":1}".utf8)
        try corrupt.write(to: url)
        io.reset()
        do {
            _ = try await writer.commit(saved)
            XCTFail("An unchanged submission must verify disk identity and checksum")
        } catch SessionStoreError.corruptSnapshot {}
        XCTAssertEqual(io.counts, [1, 0, 0])
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testReplayedExternalJournalAlwaysGetsDurableCheckpoint() async throws {
        let root = try fixture(), io = IO()
        let store = io.store(root.appendingPathComponent("course"))
        let initial = try store.save(SessionSnapshot())
        var processing = initial.processing
        processing.paused = true
        let replayed = try store.append(.processing(processing), expectedRevision: initial.storageRevision)
        io.reset()
        let saved = try await SessionArchiveWriter(store: store).commit(replayed)
        XCTAssertEqual(io.counts, [1, 0, 1])
        XCTAssertEqual(saved.storageRevision, replayed.storageRevision + 1)
        XCTAssertEqual(try store.load(), saved)
    }

    func testAnotherWritersTextCannotBeLostThroughUnchangedFastPath() async throws {
        let root = try fixture(), io = IO()
        let store = io.store(root.appendingPathComponent("course"))
        let writer = SessionArchiveWriter(store: store)
        let stale = try await writer.commit(SessionSnapshot())
        let foreign = TranscriptSegment(startTime: 0, endTime: 1, english: "Another synthetic writer.")
        _ = try SessionStore(directory: store.directory).append(.upsertSegment(foreign), expectedRevision: stale.storageRevision)
        io.reset()
        do {
            _ = try await writer.commit(stale)
            XCTFail("An unchanged UI value must not discard another writer's caption")
        } catch is SessionStoreError {}
        XCTAssertEqual(io.counts, [1, 0, 0])
        XCTAssertEqual(try store.load()?.segments, [foreign])
    }

    func testNonJournaledMetadataStillCheckpoints() async throws {
        let root = try fixture(), io = IO()
        let store = io.store(root.appendingPathComponent("course"))
        let writer = SessionArchiveWriter(store: store)
        var desired = try await writer.commit(SessionSnapshot())
        desired.notebookRevision = 1
        io.reset()
        let saved = try await writer.commit(desired)
        XCTAssertEqual(io.counts, [1, 0, 1])
        XCTAssertEqual(saved.notebookRevision, 1)
        XCTAssertEqual(try store.load(), saved)
    }
}
