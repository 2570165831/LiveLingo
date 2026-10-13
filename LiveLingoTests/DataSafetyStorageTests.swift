import Foundation
import Darwin
import XCTest
import os
@testable import LiveLingo

enum DataSafetyFixtures {
    static func make(_ label: String) throws -> URL {
        let designated = TestFixtureDirectory.root
        let url = designated.appendingPathComponent("Safety-\(label)-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func preserve(_ root: URL) {
        let destination = TestFixtureDirectory.root
            .appendingPathComponent("fixtures", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: root, to: destination.appendingPathComponent(root.lastPathComponent))
        } catch { XCTFail("Could not preserve synthetic fixture: \(error)") }
    }
}

/// Thread-safe record of recovery inspections and a background save's result.
private final class RecoveryScanProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inspected: [String] = []
    private var outcome: Result<Void, Error>?
    var names: [String] { lock.withLock { inspected } }
    var result: Result<Void, Error>? { lock.withLock { outcome } }
    func record(_ url: URL) { lock.withLock { inspected.append(url.lastPathComponent) } }
    func finish(_ value: Result<Void, Error>) { lock.withLock { outcome = value } }
}

private final class SlowIOProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: [UInt64]
    private var events: [String] = []
    init(ticks: [UInt64]) { self.ticks = ticks }
    func now() -> UInt64 { lock.withLock { ticks.removeFirst() } }
    func record(_ site: SensitiveFileIO.IOCallSite, _ elapsed: UInt64) {
        lock.withLock { events.append("\(site.rawValue):\(elapsed)") }
    }
    var recorded: [String] { lock.withLock { events } }
}

private final class TraceTextProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ text: String) { lock.withLock { values.append(text) } }
    var texts: [String] { lock.withLock { values } }
}

final class DataSafetyStorageTests: XCTestCase {
    func testSignpostUsesTheSameReadableObjectPayloadForBeginAndEnd() {
        let ticks = SlowIOProbe(ticks: [123, 124]), trace = TraceTextProbe()
        SensitiveFileIO.$ioClock.withValue({ ticks.now() }) {
            SensitiveFileIO.$signpostObserver.withValue({ text in trace.record(text); errno = EIO }) {
                errno = EACCES
                SensitiveFileIO.timedIO(.entryStatus) {
                    XCTAssertEqual(trace.texts, ["site=entryStatus start_ns=123"])
                    XCTAssertEqual(errno, EACCES)
                    errno = ENOENT
                }
                XCTAssertEqual(errno, ENOENT)
            }
        }
        XCTAssertEqual(trace.texts, ["site=entryStatus start_ns=123", "site=entryStatus errno=\(ENOENT)"])
    }

    func testMaterializationPolicyIsScopedRestoredAndMapsDeniedReads() throws {
        let prior = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        XCTAssertGreaterThanOrEqual(prior, 0)
        XCTAssertThrowsError(try SensitiveFileIO.withoutDatalessMaterialization {
            XCTAssertTrue(SensitiveFileIO.materializationBlocked)
            XCTAssertEqual(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD), IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
            throw SensitiveFileIO.Failure.system(operation: "synthetic denied read", code: EDEADLK)
        }) { error in guard case .dataless = error as? SensitiveFileIO.Failure else { return XCTFail("Expected deferred materialization") } }
        XCTAssertFalse(SensitiveFileIO.materializationBlocked)
        XCTAssertEqual(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD), prior)
    }

    func testNestedPrivateIOPreservesCloudDeferralInsteadOfGenericIOFailure() throws {
        XCTAssertThrowsError(try SensitiveFileIO.withoutDatalessMaterialization {
            try SessionArchiveCoding.privateIO(at: URL(fileURLWithPath: "/synthetic/metadata")) {
                throw SensitiveFileIO.Failure.system(operation: "synthetic denied directory open", code: EDEADLK)
            }
        }) { error in
            XCTAssertEqual(LearningFailureCode.code(for: error), "session_storageDeferred")
            XCTAssertTrue(LearningFailureCode.label(for: LearningFailureCode.code(for: error)).contains("iCloud"))
        }
    }

    func testOutsideStorageScopeCanReadWhileLockedScopeRefusesPlaceholder() throws {
        let root = try DataSafetyFixtures.make("materialization-scope")
        defer { DataSafetyFixtures.preserve(root) }
        let url = root.appendingPathComponent("manifest.json")
        let data = Data("synthetic local bytes".utf8)
        try SensitiveFileIO.atomicWrite(data, to: url)
        try SensitiveFileIO.$datalessProbe.withValue({ $0 == url }) {
            XCTAssertEqual(try SensitiveFileIO.readIfPresent(at: url), data)
            XCTAssertThrowsError(try SensitiveFileIO.withoutDatalessMaterialization { try SensitiveFileIO.readIfPresent(at: url) })
        }
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testWriterDirectoryENOENTNeverExecutesAnUnlockedTransaction() throws {
        let root = try DataSafetyFixtures.make("writer-directory-ENOENT")
        defer { DataSafetyFixtures.preserve(root) }
        _ = try SessionStore(directory: root).save(populatedSnapshot())
        let bytes = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
        var actions = 0
        try SessionStore.$directoryOpenError.withValue(ENOENT) {
            XCTAssertThrowsError(try SessionStore(directory: root).withWriteTransaction { _ in actions += 1 }) { error in
                guard case .io(_, ENOENT) = error as? SessionStoreError else { return XCTFail("Writer must report the missing binding") }
            }
            XCTAssertNil(try SessionStore(directory: root).loadDetailedWithoutRecovery().snapshot)
        }
        XCTAssertEqual(actions, 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), bytes)
    }

    func testLegacyCloudManifestDefersBeforeLocksAndKeepsFrenchSummarySelection() throws {
        let root = try DataSafetyFixtures.make("legacy-cloud-manifest")
        defer { DataSafetyFixtures.preserve(root) }
        try Data(#"{"targetLocale":"fr"}"#.utf8).write(to: root.appendingPathComponent("manifest.json"))
        let summary = "Résumé synthétique original."
        try Data(summary.utf8).write(to: root.appendingPathComponent("summary-fr.md"))
        let probe = RecoveryScanProbe()
        try SensitiveFileIO.$datalessProbe.withValue({ $0.lastPathComponent == "manifest.json" }) {
            try SensitiveFileIO.$ioBeginObserver.withValue({ site, _ in
                if [.storeDirectoryLock, .storeProcessLock, .storeLease].contains(site) { probe.record(root) }
            }) {
                for writer in [false, true] {
                    let operation: () throws -> Void = {
                        if writer { try SessionStore(directory: root).withWriteTransaction { _ in () } }
                        else { _ = try SessionStore(directory: root).loadDetailedWithoutRecovery() }
                    }
                    XCTAssertThrowsError(try operation()) { error in
                            guard case .storageDeferred = error as? SessionStoreError else { return XCTFail("Legacy placeholder must stay deferred") }
                        }
                }
            }
        }
        XCTAssertTrue(probe.names.isEmpty, "Legacy manifest preflight precedes all storage locks")
        let loaded = try XCTUnwrap(SessionStore(directory: root).loadDetailedWithoutRecovery().snapshot)
        XCTAssertEqual(loaded.targetLocale, "fr")
        XCTAssertEqual(loaded.legacyMarkdown, summary)
        XCTAssertEqual(try SessionExporter.savedSummaryURL(in: root, targetLocale: nil).lastPathComponent, "summary-fr.md")
    }

    func testImmutableLegacyExportIndexAndMembersUseNonmaterializingReads() throws {
        let root = try DataSafetyFixtures.make("legacy-export-cloud-index")
        defer { DataSafetyFixtures.preserve(root) }
        let generation = UUID().uuidString
        let version = root.appendingPathComponent(".exports/versions/" + generation, isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        let manifest = Data(#"{"targetLocale":"fr"}"#.utf8), summary = Data("Résumé conservé.".utf8)
        try manifest.write(to: version.appendingPathComponent("manifest.json"))
        try summary.write(to: version.appendingPathComponent("summary-fr.md"))
        let index = try JSONSerialization.data(withJSONObject: ["version": 1,
            "members": ["manifest.json": SessionArchiveCoding.digest(manifest), "summary-fr.md": SessionArchiveCoding.digest(summary)]])
        try index.write(to: version.appendingPathComponent("export-index.json"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(".exports/current").path,
                                                   withDestinationPath: "versions/" + generation)
        for name in ["export-index.json", "manifest.json", "summary-fr.md"] {
            try SensitiveFileIO.$datalessProbe.withValue({ $0.lastPathComponent == name }) {
                XCTAssertThrowsError(try SessionStore(directory: root).loadDetailedWithoutRecovery()) { error in
                    guard case .storageDeferred = error as? SessionStoreError else { return XCTFail("Export placeholder must stay deferred") }
                }
            }
        }
        XCTAssertEqual(try SessionStore(directory: root).loadDetailedWithoutRecovery().snapshot?.legacyMarkdown, "Résumé conservé.")
        let (alias, _) = try committedAlias(in: version, named: "export-index.json")
        try SensitiveFileIO.$beforeTemporaryInspection.withValue({ _ in XCTAssertFalse(SessionStore.isHoldingProcessLock) }) {
            XCTAssertEqual(try SessionStore(directory: root).loadDetailedWithoutRecovery().snapshot?.legacyMarkdown, "Résumé conservé.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
    }

    @MainActor
    func testReviewQueueStartupAutomaticallyRepairsItsCommittedJournalAlias() async throws {
        let root = try DataSafetyFixtures.make("review-startup-alias")
        defer { DataSafetyFixtures.preserve(root) }
        let url = root.appendingPathComponent("learning-review-queue.json")
        let journal = LearningReviewQueue.Journal(jobs: [], userPaused: true, version: 4)
        let bytes = try await LearningReviewStorage(journalURL: url, expectedBytes: nil).save(journal, sequence: 1)
        let (alias, _) = try committedAlias(in: root, named: url.lastPathComponent)
        let queue = SensitiveFileIO.$beforeTemporaryInspection.withValue({ _ in
            XCTAssertFalse(SessionStore.isHoldingProcessLock)
            XCTAssertTrue(LearningReviewStorage.processLockIsAvailableForTesting())
        }) {
            LearningReviewQueue(journalURL: url, observeSleep: false, diagnostics: .disabled,
                generate: { _, _, _, _, _ in throw CancellationError() })
        }
        XCTAssertNil(queue.currentFailure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        var book = LearningNotebook()
        let segment = TranscriptSegment(startTime: 0, endTime: 2, english: "Synthetic queue recovery.", chinese: "合成队列恢复。")
        try book.append(evidence: [segment], note: LearningNote(topic: "合成恢复", points: [.init(kind: "核心结论", text: "合成进度保留。")]))
        let course = root.appendingPathComponent("course", isDirectory: true)
        var snapshot = SessionSnapshot(segments: [segment]); book.writeState(to: &snapshot)
        _ = try SessionStore(directory: course).save(snapshot)
        try queue.enqueue(directory: course, notebook: book)
        try await queue.waitForPendingStorage()
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertNil(queue.currentFailure)
        await queue.shutdownForTesting()
    }
    private static let killProbeState = OSAllocatedUnfairLock(initialState: Optional<URL>.none)

    private func recoveryKillProbe() throws -> URL {
        try Self.killProbeState.withLock { cached in
            if let executable = cached { return executable }
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let root = try DataSafetyFixtures.make("kill-probe-build")
            let executable = root.appendingPathComponent("storage-recovery-kill-probe")
            let log = root.appendingPathComponent("build.log")
            _ = FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["swiftc", "-D", "DEBUG", "-parse-as-library",
                source.appendingPathComponent("LiveLingo/Sources/SensitiveFileIO.swift").path,
                source.appendingPathComponent("Scripts/storage-recovery-kill-probe.swift").path,
                "-o", executable.path]
            compiler.standardOutput = output; compiler.standardError = output
            try compiler.run(); compiler.waitUntilExit()
            guard compiler.terminationStatus == 0 else { throw SessionStoreError.invalidState("Synthetic crash probe failed to compile") }
            let verify = Process()
            verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            verify.arguments = ["--verify", "--strict", executable.path]
            verify.standardOutput = output; verify.standardError = output
            try verify.run(); verify.waitUntilExit()
            guard verify.terminationStatus == 0 else { throw SessionStoreError.invalidState("Synthetic crash probe signature is invalid") }
            cached = executable
            return executable
        }
    }
    private func populatedSnapshot() -> SessionSnapshot {
        let id = UUID()
        let segment = TranscriptSegment(startTime: 1, endTime: 3,
            english: "Synthetic committed evidence survives interrupted publication.",
            chinese: "合成的已提交正文在发布中断后仍须完整。", sessionID: id)
        return SessionSnapshot(sessionID: id, segments: [segment])
    }

    /// Model a kill after publication of the first-write hard link. The
    /// previous committed file is retained, never overwritten by the fixture.
    private func committedAlias(in root: URL, named name: String) throws -> (URL, Data) {
        let destination = root.appendingPathComponent(name)
        let bytes = try Data(contentsOf: destination)
        try FileManager.default.moveItem(at: destination, to: root.appendingPathComponent("before-interruption-" + name))
        let orphan = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        try interruptedWrite(bytes, to: destination, orphan: orphan)
        guard link(orphan.path, destination.path) == 0 else {
            throw SessionStoreError.io(operation: "publish synthetic committed alias", code: errno)
        }
        return (orphan, bytes)
    }

    func testSlowIODiagnosticsOnlyEmitAboveThresholdAndPreserveErrno() {
        let threshold = SensitiveFileIO.slowIOThresholdNanoseconds
        let probe = SlowIOProbe(ticks: [0, threshold - 1, 0, threshold, 0, threshold + 1])
        SensitiveFileIO.$ioClock.withValue({ probe.now() }) {
            SensitiveFileIO.$slowIOObserver.withValue({ site, elapsed in
                probe.record(site, elapsed)
                errno = EIO
            }) {
                for _ in 0..<3 {
                    let result = SensitiveFileIO.timedIO(.temporaryOpen) { errno = EACCES; return Int32(-1) }
                    XCTAssertEqual(result, -1)
                    XCTAssertEqual(errno, EACCES, "Diagnostics must preserve the syscall failure")
                }
            }
        }
        XCTAssertEqual(probe.recorded, ["temporaryOpen:\(threshold + 1)"], "One fixed label and elapsed duration only")
    }

    func testSlowIODiagnosticsAlsoMeasureThrowingCalls() throws {
        let elapsed = SensitiveFileIO.slowIOThresholdNanoseconds + 1
        let probe = SlowIOProbe(ticks: [0, elapsed])
        try SensitiveFileIO.$ioClock.withValue({ probe.now() }) {
            try SensitiveFileIO.$slowIOObserver.withValue({ probe.record($0, $1) }) {
                XCTAssertThrowsError(try SensitiveFileIO.timedIO(.temporaryRead) {
                    throw SessionStoreError.io(operation: "synthetic read failure", code: EIO)
                })
            }
        }
        XCTAssertEqual(probe.recorded, ["temporaryRead:\(elapsed)"])
    }

    func testIOBeginRecordPrecedesCallAndPreservesIncomingErrno() {
        let probe = SlowIOProbe(ticks: [123, 124])
        SensitiveFileIO.$ioClock.withValue({ probe.now() }) {
            SensitiveFileIO.$ioBeginObserver.withValue({ site, start in
                probe.record(site, start)
                errno = EIO
            }) {
                errno = EACCES
                SensitiveFileIO.timedIO(.dataRead) {
                    XCTAssertEqual(probe.recorded, ["dataRead:123"], "A nonreturning call must already have a begin record")
                    XCTAssertEqual(errno, EACCES)
                }
            }
        }
    }

    func testBeginDiagnosticsCoverStoreReadsWritesSyncPublicationAndLocks() throws {
        let root = try DataSafetyFixtures.make("begin-diagnostic-coverage")
        defer { DataSafetyFixtures.preserve(root) }
        let events = RecoveryScanProbe()
        try SensitiveFileIO.$ioBeginObserver.withValue({ site, _ in
            events.record(URL(fileURLWithPath: "/" + site.rawValue))
        }) {
            let store = SessionStore(directory: root)
            let stored = try store.save(populatedSnapshot())
            _ = try store.loadDetailedWithoutRecovery()
            _ = try store.save(stored)
        }
        let actual = Set(events.names)
        let required: [SensitiveFileIO.IOCallSite] = [.dataRead, .dataWrite, .fileSync, .directorySync,
            .fileLink, .fileRename, .storeLease, .storeProcessLock, .storeDirectoryLock]
        for site in required {
            XCTAssertTrue(actual.contains(site.rawValue), "Missing begin diagnostic for \(site.rawValue)")
        }
    }

    func testSnapshotSwapBetweenMetadataAndOpenRejectsNewInodeAndFIFO() throws {
        for fifo in [false, true] {
            let root = try DataSafetyFixtures.make(fifo ? "snapshot-fifo-race" : "snapshot-inode-race")
            defer { DataSafetyFixtures.preserve(root) }
            _ = try SessionStore(directory: root).save(populatedSnapshot())
            let target = root.appendingPathComponent(SessionStore.snapshotFileName)
            let backup = root.appendingPathComponent("original-snapshot")
            let original = try Data(contentsOf: target)
            let states = RecoveryScanProbe(), reads = RecoveryScanProbe()
            try SensitiveFileIO.$ioBeginObserver.withValue({ site, _ in
                if site == .storeLease { states.record(root) }
                if site == .fileOpen, states.names.count == 1 {
                    states.record(root)
                    XCTAssertEqual(Darwin.rename(target.path, backup.path), 0)
                    if fifo { XCTAssertEqual(mkfifo(target.path, 0o600), 0) }
                    else {
                        do { try Data("synthetic replacement".utf8).write(to: target) }
                        catch { XCTFail("Cannot stage synthetic replacement") }
                    }
                }
            }) {
                try SensitiveFileIO.$beforeFileRead.withValue({ reads.record($0) }) {
                    XCTAssertThrowsError(try SessionStore(directory: root).loadDetailedWithoutRecovery()) { error in
                        guard case .unsafePath = error as? SessionStoreError else { return XCTFail("Expected a rejected identity/type race") }
                    }
                }
            }
            XCTAssertEqual(states.names.count, 2, "Race injection must reach the snapshot open")
            XCTAssertTrue(reads.names.isEmpty, "Unverified replacement bytes must never be read")
            XCTAssertEqual(try Data(contentsOf: backup), original)
        }
    }

    func testDatalessSnapshotAndJournalAreDeferredBeforeTakingLocksOrReading() throws {
        let root = try DataSafetyFixtures.make("dataless-preflight")
        defer { DataSafetyFixtures.preserve(root) }
        _ = try SessionStore(directory: root).save(populatedSnapshot())
        let before = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
        for name in [SessionStore.snapshotFileName, SessionStore.journalFileName] {
            let probe = RecoveryScanProbe()
            try SensitiveFileIO.$datalessProbe.withValue({ url in
                XCTAssertFalse(SessionStore.isHoldingProcessLock)
                return url.lastPathComponent == name
            }) {
                try SensitiveFileIO.$ioBeginObserver.withValue({ site, _ in
                    if [.dataRead, .storeDirectoryLock, .storeProcessLock, .storeLease].contains(site) {
                        probe.record(URL(fileURLWithPath: "/" + site.rawValue))
                    }
                }) {
                    XCTAssertThrowsError(try SessionStore(directory: root).loadDetailedWithoutRecovery()) { error in
                        guard case .storageDeferred(let reason) = error as? SessionStoreError else {
                            return XCTFail("Expected a readable deferred-storage error")
                        }
                        XCTAssertTrue(reason.contains("尚未下载"))
                    }
                    XCTAssertThrowsError(try SessionStore(directory: root).save(SessionSnapshot()))
                }
            }
            XCTAssertTrue(probe.names.isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), before)
    }

    func testSlowReviewReadHoldsCourseLockButNeverGlobalWriterLock() throws {
        let root = try DataSafetyFixtures.make("slow-review-read")
        let other = try DataSafetyFixtures.make("slow-review-independent-writer")
        defer { DataSafetyFixtures.preserve(root); DataSafetyFixtures.preserve(other) }
        let stored = try SessionStore(directory: root).save(populatedSnapshot())
        let otherStored = try SessionStore(directory: other).save(populatedSnapshot())
        let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let readDone = DispatchSemaphore(value: 0), sameDone = DispatchSemaphore(value: 0), otherDone = DispatchSemaphore(value: 0)
        let reader = RecoveryScanProbe(), same = RecoveryScanProbe(), independent = RecoveryScanProbe()
        DispatchQueue.global().async {
            reader.finish(Result {
                try SensitiveFileIO.$beforeFileRead.withValue({ url in
                    guard url.lastPathComponent == SessionStore.snapshotFileName else { return }
                    XCTAssertFalse(SessionStore.isHoldingProcessLock)
                    reached.signal()
                    _ = release.wait(timeout: .now() + 15)
                }) {
                    let loaded = try SessionStore(directory: root).loadDetailedWithoutRecovery().snapshot
                    XCTAssertEqual(loaded, stored)
                }
            })
            readDone.signal()
        }
        XCTAssertEqual(reached.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            same.finish(Result { _ = try SessionStore(directory: root).save(stored) })
            sameDone.signal()
        }
        DispatchQueue.global().async {
            independent.finish(Result { _ = try SessionStore(directory: other).save(otherStored) })
            otherDone.signal()
        }
        let independentResult = otherDone.wait(timeout: .now() + 5)
        XCTAssertEqual(sameDone.wait(timeout: .now() + 0.1), .timedOut, "Same-course writes must wait for the consistent read")
        release.signal()
        XCTAssertEqual(readDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(sameDone.wait(timeout: .now() + 5), .success)
        if independentResult != .success { _ = otherDone.wait(timeout: .now() + 5) }
        XCTAssertEqual(independentResult, .success, "Slow old-course reads cannot block active-course saves")
        for probe in [reader, same, independent] { XCTAssertNoThrow(try XCTUnwrap(probe.result).get()) }
    }

    func testWaitingForAnotherInstancesStoreLeaseDoesNotHoldGlobalWriterLock() throws {
        let root = try DataSafetyFixtures.make("external-store-lease")
        let other = try DataSafetyFixtures.make("external-lease-independent")
        defer { DataSafetyFixtures.preserve(root); DataSafetyFixtures.preserve(other) }
        let stored = try SessionStore(directory: root).save(populatedSnapshot())
        let otherStored = try SessionStore(directory: other).save(populatedSnapshot())
        let fd = Darwin.open(root.appendingPathComponent(".session-store.lock").path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { _ = Darwin.close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let reached = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0), otherDone = DispatchSemaphore(value: 0)
        let blocked = RecoveryScanProbe(), independent = RecoveryScanProbe()
        DispatchQueue.global().async {
            blocked.finish(Result {
                try SensitiveFileIO.$ioBeginObserver.withValue({ site, _ in
                    if site == .storeLease {
                        XCTAssertFalse(SessionStore.isHoldingProcessLock)
                        reached.signal()
                    }
                }) { _ = try SessionStore(directory: root).save(stored) }
            })
            done.signal()
        }
        XCTAssertEqual(reached.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            independent.finish(Result { _ = try SessionStore(directory: other).save(otherStored) })
            otherDone.signal()
        }
        let result = otherDone.wait(timeout: .now() + 5)
        _ = flock(fd, LOCK_UN)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        if result != .success { _ = otherDone.wait(timeout: .now() + 5) }
        XCTAssertEqual(result, .success)
        for probe in [blocked, independent] { XCTAssertNoThrow(try XCTUnwrap(probe.result).get()) }
    }

    func testConcurrentSameCourseAliasRepairRetriesBusyLeaseAndRunsWriteOnce() throws {
        let root = try DataSafetyFixtures.make("concurrent-alias-repair")
        defer { DataSafetyFixtures.preserve(root) }
        let stored = try SessionStore(directory: root).save(populatedSnapshot())
        let (alias, _) = try committedAlias(in: root, named: SessionStore.snapshotFileName)
        let leased = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), retried = DispatchSemaphore(value: 0)
        let firstDone = DispatchSemaphore(value: 0), secondDone = DispatchSemaphore(value: 0)
        let first = RecoveryScanProbe(), second = RecoveryScanProbe(), transactions = RecoveryScanProbe()
        DispatchQueue.global().async {
            first.finish(Result {
                try SensitiveFileIO.$afterRecoveryLease.withValue({
                    leased.signal()
                    _ = release.wait(timeout: .now() + 15)
                }) { _ = try SessionStore(directory: root).loadDetailedWithoutRecovery() }
            })
            firstDone.signal()
        }
        XCTAssertEqual(leased.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            second.finish(Result {
                try SensitiveFileIO.$recoveryRetryObserver.withValue({ retried.signal() }) {
                    try SessionStore(directory: root).withWriteTransaction { transaction in
                        transactions.record(root)
                        _ = try transaction.save(stored)
                    }
                }
            })
            secondDone.signal()
        }
        let observedRetry = retried.wait(timeout: .now() + 5)
        release.signal()
        XCTAssertEqual(observedRetry, .success, "The busy lease must be retried, not reported as unsafePath")
        XCTAssertEqual(firstDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(secondDone.wait(timeout: .now() + 5), .success)
        for probe in [first, second] { XCTAssertNoThrow(try XCTUnwrap(probe.result).get()) }
        XCTAssertEqual(transactions.names.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
        XCTAssertEqual(try SessionStore(directory: root).load()?.segments, stored.segments)
    }

    func testBusyAliasRetryHasLimitAndDoesNotRunTransaction() throws {
        let root = try DataSafetyFixtures.make("bounded-alias-retry")
        defer { DataSafetyFixtures.preserve(root) }
        _ = try SessionStore(directory: root).save(populatedSnapshot())
        let (alias, bytes) = try committedAlias(in: root, named: SessionStore.snapshotFileName)
        let fd = Darwin.open(alias.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return XCTFail("Cannot bind synthetic alias") }
        defer { _ = flock(fd, LOCK_UN); _ = Darwin.close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let retries = RecoveryScanProbe()
        try SensitiveFileIO.$recoveryRetryObserver.withValue({ retries.record(root) }) {
            XCTAssertThrowsError(try SessionStore(directory: root).withWriteTransaction { _ in
                XCTFail("No transaction may run before recovery succeeds")
            }) { error in
                guard case .storageDeferred = error as? SessionStoreError else { return XCTFail("Expected deferred storage") }
            }
        }
        XCTAssertEqual(retries.names.count, SensitiveFileIO.recoveryRetryLimit)
        XCTAssertEqual(try Data(contentsOf: alias), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), bytes)
    }

    func testInterruptedRecoveryAfterUnlinkPreservesReceiptAndCommittedBytes() throws {
        let root = try DataSafetyFixtures.make("interruption-after-unlink")
        defer { DataSafetyFixtures.preserve(root) }
        let stored = try SessionStore(directory: root).save(populatedSnapshot())
        let (alias, bytes) = try committedAlias(in: root, named: SessionStore.snapshotFileName)
        let destination = root.appendingPathComponent(SessionStore.snapshotFileName)
        try SensitiveFileIO.$afterAliasUnlink.withValue({ throw SessionStoreError.io(operation: "synthetic termination", code: EIO) }) {
            XCTAssertThrowsError(try SensitiveFileIO.recoverCommittedFileIfNeeded(at: destination))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertGreaterThan(getxattr(destination.path, "com.jianhongli.LiveLingo.temporary-v1", nil, 0, 0, XATTR_NOFOLLOW), 0,
                             "The simulated termination occurs before receipt removal and directory fsync")
        XCTAssertEqual(try SessionStore(directory: root).loadDetailedWithoutRecovery().snapshot, stored)
    }

    func testInterruptedRecoveryBeforeRelockDoesNotRunOrReplayTransaction() throws {
        let root = try DataSafetyFixtures.make("interruption-before-relock")
        defer { DataSafetyFixtures.preserve(root) }
        let stored = try SessionStore(directory: root).save(populatedSnapshot())
        let (alias, bytes) = try committedAlias(in: root, named: SessionStore.snapshotFileName)
        let store = SessionStore(directory: root)
        try SessionStore.$afterAliasRecovery.withValue({
            XCTAssertFalse(SessionStore.isHoldingProcessLock)
            throw SessionStoreError.io(operation: "synthetic termination before relock", code: EIO)
        }) {
            XCTAssertThrowsError(try store.withWriteTransaction { _ in XCTFail("Interrupted before transaction") })
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), bytes)
        var transactions = 0
        try store.withWriteTransaction { transaction in
            transactions += 1
            _ = try transaction.save(stored)
        }
        XCTAssertEqual(transactions, 1)
    }

    func testSIGKILLAfterAliasUnlinkAndBeforeRelockPreservesCommittedCourse() throws {
        let executable = try recoveryKillProbe()
        for stage in ["after-unlink", "before-relock"] {
            let root = try DataSafetyFixtures.make("sigkill-" + stage)
            defer { DataSafetyFixtures.preserve(root) }
            let stored = try SessionStore(directory: root).save(populatedSnapshot())
            let (alias, bytes) = try committedAlias(in: root, named: SessionStore.snapshotFileName)
            let destination = root.appendingPathComponent(SessionStore.snapshotFileName)
            let child = Process()
            child.executableURL = executable
            child.arguments = [stage, destination.path]
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); child.waitUntilExit()
            XCTAssertEqual(child.terminationReason, .uncaughtSignal)
            XCTAssertEqual(child.terminationStatus, SIGKILL, "Only the synthetic helper is killed; no crash dialog is generated")
            XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            let receiptLength = getxattr(destination.path, "com.jianhongli.LiveLingo.temporary-v1", nil, 0, 0, XATTR_NOFOLLOW)
            if stage == "after-unlink" { XCTAssertGreaterThan(receiptLength, 0) }
            else { XCTAssertEqual(receiptLength, -1); XCTAssertEqual(errno, ENOATTR) }
            XCTAssertEqual(try SessionStore(directory: root).loadDetailedWithoutRecovery().snapshot, stored)
            XCTAssertNoThrow(try SessionStore(directory: root).save(stored))
        }
    }

    func testReviewJournalAliasRepairRunsOutsideBothReviewLocks() async throws {
        let root = try DataSafetyFixtures.make("review-journal-alias")
        defer { DataSafetyFixtures.preserve(root) }
        let url = root.appendingPathComponent("review.json")
        let journal = LearningReviewQueue.Journal(jobs: [], userPaused: true, version: 4)
        let initial = try await LearningReviewStorage(journalURL: url, expectedBytes: nil).save(journal, sequence: 1)
        let (alias, _) = try committedAlias(in: root, named: url.lastPathComponent)
        let probe = RecoveryScanProbe()
        let result = try await SensitiveFileIO.$beforeTemporaryInspection.withValue({ pending in
            probe.record(pending)
            XCTAssertTrue(LearningReviewStorage.processLockIsAvailableForTesting())
            let fd = Darwin.open(url.appendingPathExtension("lock").path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            if fd >= 0 {
                XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
                _ = flock(fd, LOCK_UN); _ = Darwin.close(fd)
            } else { XCTFail("Missing synthetic review lock") }
        }) { try await LearningReviewStorage(journalURL: url, expectedBytes: initial).save(journal, sequence: 1) }
        XCTAssertEqual(result, initial)
        XCTAssertEqual(probe.names, [alias.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
        // Alias recovery does not bypass the expected-bytes compare-and-swap.
        do {
            _ = try await LearningReviewStorage(journalURL: url, expectedBytes: Data()).save(journal, sequence: 1)
            XCTFail("A stale review writer must still be rejected")
        } catch ReviewIdentityError.conflict { }
    }

    func testDU05SaveRepairsCommittedAliasesOutsideLocksAndRunsTransactionOnce() throws {
        let root = try DataSafetyFixtures.make("DU05-save-alias")
        defer { DataSafetyFixtures.preserve(root) }
        let store = SessionStore(directory: root)
        let stored = try store.save(populatedSnapshot())
        let (snapshotAlias, original) = try committedAlias(in: root, named: SessionStore.snapshotFileName)
        let (lockAlias, _) = try committedAlias(in: root, named: ".session-store.lock")
        let probe = RecoveryScanProbe()
        var transactions = 0
        let saved = try SensitiveFileIO.$beforeTemporaryInspection.withValue({ url in
            probe.record(url)
            XCTAssertFalse(SessionStore.isHoldingProcessLock, "A temporary alias must never be opened under the process lock")
            let fd = Darwin.open(root.appendingPathComponent(".session-store.lock").path,
                                 O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            XCTAssertGreaterThanOrEqual(fd, 0)
            if fd >= 0 {
                XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "Recovery must also run outside the disk lock")
                _ = flock(fd, LOCK_UN)
                _ = Darwin.close(fd)
            }
        }) {
            try store.withWriteTransaction { transaction in
                transactions += 1
                XCTAssertTrue(SessionStore.isHoldingProcessLock)
                return try transaction.save(stored)
            }
        }
        XCTAssertEqual(transactions, 1, "Recovery retries must not replay an accepted transaction")
        XCTAssertEqual(Set(probe.names), Set([snapshotAlias.lastPathComponent, lockAlias.lastPathComponent]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotAlias.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockAlias.path))
        XCTAssertEqual(try SessionStore(directory: root).load(), saved)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("before-interruption-" + SessionStore.snapshotFileName)), original)
        XCTAssertEqual(saved.sessionID, stored.sessionID)
        XCTAssertEqual(saved.segments, stored.segments)
    }

    func testDU05StalledCommittedAliasRecoveryDoesNotBlockAnotherCourseSave() throws {
        let root = try DataSafetyFixtures.make("DU05-stalled-save-alias")
        let other = try DataSafetyFixtures.make("DU05-independent-course")
        defer { DataSafetyFixtures.preserve(root); DataSafetyFixtures.preserve(other) }
        let stored = try SessionStore(directory: root).save(populatedSnapshot())
        let otherStored = try SessionStore(directory: other).save(populatedSnapshot())
        let (alias, bytes) = try committedAlias(in: root, named: SessionStore.snapshotFileName)
        let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0), otherDone = DispatchSemaphore(value: 0)
        let probe = RecoveryScanProbe(), otherProbe = RecoveryScanProbe()
        DispatchQueue.global().async {
            probe.finish(Result {
                try SensitiveFileIO.$beforeTemporaryInspection.withValue({ url in
                    probe.record(url)
                    XCTAssertFalse(SessionStore.isHoldingProcessLock)
                    reached.signal()
                    _ = release.wait(timeout: .now() + 30)
                }) { _ = try SessionStore(directory: root).save(stored) }
            })
            done.signal()
        }
        XCTAssertEqual(reached.wait(timeout: .now() + 10), .success)
        // The interrupted publication was already complete before any recovery.
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), bytes)
        DispatchQueue.global().async {
            otherProbe.finish(Result { _ = try SessionStore(directory: other).save(otherStored) })
            otherDone.signal()
        }
        let independentSave = otherDone.wait(timeout: .now() + 10)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
        if independentSave != .success { XCTAssertEqual(otherDone.wait(timeout: .now() + 30), .success) }
        XCTAssertEqual(independentSave, .success, "A stalled alias open must not hold the global save lock")
        XCTAssertNoThrow(try XCTUnwrap(probe.result).get())
        XCTAssertNoThrow(try XCTUnwrap(otherProbe.result).get())
        XCTAssertEqual(probe.names, [alias.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
        let reopened = try XCTUnwrap(SessionStore(directory: root).load())
        XCTAssertEqual(reopened.sessionID, stored.sessionID)
        XCTAssertEqual(reopened.segments, stored.segments)
    }

    func testDU05FailedAliasRepairKeepsCommittedBytesAndDoesNotRunTransaction() throws {
        let root = try DataSafetyFixtures.make("DU05-rejected-save-alias")
        defer { DataSafetyFixtures.preserve(root) }
        let store = SessionStore(directory: root)
        _ = try store.save(SessionSnapshot())
        let destination = root.appendingPathComponent(SessionStore.snapshotFileName)
        let bytes = try Data(contentsOf: destination)
        let alias = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        XCTAssertEqual(link(destination.path, alias.path), 0)
        let probe = RecoveryScanProbe()
        var transactions = 0
        XCTAssertThrowsError(try SensitiveFileIO.$beforeTemporaryInspection.withValue({ url in
            probe.record(url)
            XCTAssertFalse(SessionStore.isHoldingProcessLock)
        }) {
            try store.withWriteTransaction { _ in transactions += 1 }
        })
        XCTAssertEqual(transactions, 0)
        XCTAssertEqual(probe.names, [alias.lastPathComponent], "An unproven alias gets one bounded inspection")
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try Data(contentsOf: alias), bytes)
    }

    func testDU05TighteningNeverRecoversButExplicitUnlockedPreparationDoes() throws {
        let root = try DataSafetyFixtures.make("DU05-explicit-alias-preparation")
        defer { DataSafetyFixtures.preserve(root) }
        _ = try SessionStore(directory: root).save(SessionSnapshot())
        let destination = root.appendingPathComponent(SessionStore.snapshotFileName)
        let (alias, bytes) = try committedAlias(in: root, named: SessionStore.snapshotFileName)
        let probe = RecoveryScanProbe()
        try SensitiveFileIO.$beforeTemporaryInspection.withValue({ probe.record($0) }) {
            XCTAssertThrowsError(try SensitiveFileIO.tightenFileIfPresent(destination))
        }
        XCTAssertEqual(probe.names, [], "Validation must not implicitly open a temporary alias")
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
        try SensitiveFileIO.$beforeTemporaryInspection.withValue({ probe.record($0) }) {
            try SensitiveFileIO.recoverCommittedFileIfNeeded(at: destination)
        }
        XCTAssertEqual(probe.names, [alias.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertNoThrow(try SensitiveFileIO.tightenFileIfPresent(destination))
    }

    private func interruptedWrite(_ bytes: Data, to destination: URL, orphan: URL) throws {
        XCTAssertThrowsError(try SensitiveFileIO.$beforeTemporaryCommit.withValue({ pending in
            guard Darwin.rename(pending.path, orphan.path) == 0 else {
                throw SessionStoreError.io(operation: "stage synthetic interruption", code: errno)
            }
            throw SessionStoreError.io(operation: "synthetic process interruption", code: EIO)
        }) { try SessionArchiveCoding.atomicWrite(bytes, destination) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testDU05ReopenRetiresOwnedDuplicateAndKeepsUnknownTemporary() throws {
        let root = try DataSafetyFixtures.make("DU05-duplicate")
        defer { DataSafetyFixtures.preserve(root) }
        let stored = try SessionStore(directory: root).save(SessionSnapshot())
        let destination = root.appendingPathComponent(SessionStore.snapshotFileName)
        let bytes = try Data(contentsOf: destination)
        let orphan = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        let unknown = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        try bytes.write(to: unknown)
        try interruptedWrite(bytes, to: destination, orphan: orphan)
        XCTAssertEqual(try SessionStore(directory: root).load(), stored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "A registered, unused duplicate is safe to retire on reopen")
        XCTAssertEqual(try Data(contentsOf: unknown), bytes, "A familiar name alone proves no ownership")
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testDU05ReopenRetiresOwnedEmptyWriteAndPreservesUniqueCandidate() throws {
        let root = try DataSafetyFixtures.make("DU05-empty")
        defer { DataSafetyFixtures.preserve(root) }
        let stored = try SessionStore(directory: root).save(SessionSnapshot())
        let destination = root.appendingPathComponent(SessionStore.snapshotFileName)
        let original = try Data(contentsOf: destination)
        let empty = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        let unique = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        let uniqueBytes = Data("synthetic unique uncommitted recovery evidence".utf8)
        try interruptedWrite(Data(), to: destination, orphan: empty)
        try interruptedWrite(uniqueBytes, to: destination, orphan: unique)
        XCTAssertEqual(try SessionStore(directory: root).load(), stored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertEqual(try Data(contentsOf: unique), uniqueBytes)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testDU05ReopenRetiresOnlyRegisteredEmptyInitialExportSibling() throws {
        let parent = try DataSafetyFixtures.make("DU05-initial")
        defer { DataSafetyFixtures.preserve(parent) }
        let course = parent.appendingPathComponent("course", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: false)
        let unknown = parent.appendingPathComponent(".course.initial-export-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        var operations = SessionExporter.PublicationOperations()
        operations.exchangeDirectories = { staged, destination in
            guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw SessionStoreError.io(operation: "synthetic export exchange", code: errno)
            }
            throw SessionStoreError.io(operation: "synthetic interruption after exchange", code: EIO)
        }
        XCTAssertThrowsError(try SessionExporter.export(segments: [], sessionDirectory: course, operations: operations))
        let abandoned = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".course.initial-export-") && $0 != unknown }
        XCTAssertEqual(abandoned.count, 1)
        XCTAssertNoThrow(try SessionStore(directory: course).load())
        for item in abandoned { XCTAssertFalse(FileManager.default.fileExists(atPath: item.path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: course.appendingPathComponent("manifest.json").path))
    }

    func testDU05RecoveryKeepsActiveWriterAndRecordsUnknownIdentity() throws {
        let root = try DataSafetyFixtures.make("DU05-active")
        defer { DataSafetyFixtures.preserve(root) }
        let destination = root.appendingPathComponent("snapshot.json")
        let unknown = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        try Data().write(to: unknown)
        try SensitiveFileIO.$beforeTemporaryCommit.withValue({ pending in
            let directory = try SensitiveFileIO.Directory.open(at: root, create: false, tighten: false)
            let results = try directory.recoverTemporaryItems()
            XCTAssertEqual(results.first(where: { $0.name == pending.lastPathComponent })?.reason, "active_or_unavailable")
            XCTAssertEqual(results.first(where: { $0.name == unknown.lastPathComponent })?.reason, "unregistered")
            XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        }) { try SessionArchiveCoding.atomicWrite(Data("synthetic committed body".utf8), destination) }
        XCTAssertEqual(try Data(contentsOf: destination), Data("synthetic committed body".utf8))
    }

    func testDU05WriterWaitsForRecoveryScanHoldingItsNewTemporary() throws {
        let root = try DataSafetyFixtures.make("DU05-lease")
        defer { DataSafetyFixtures.preserve(root) }
        let destination = root.appendingPathComponent("snapshot.json")
        let bytes = Data("synthetic committed body".utf8)
        try SensitiveFileIO.$beforeTemporaryLease.withValue({ pending in
            // A recovery scan that reached the brand-new file first sees no
            // receipt, keeps it, and still holds its lock when the writer asks.
            let directory = try SensitiveFileIO.Directory.open(at: root, create: false, tighten: false)
            XCTAssertEqual(try directory.recoverTemporaryItems().first(where: { $0.name == pending.lastPathComponent })?.reason,
                           "unregistered")
            let scanner = Darwin.open(pending.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard scanner >= 0 else { throw SessionStoreError.io(operation: "open synthetic scanner", code: errno) }
            guard flock(scanner, LOCK_EX | LOCK_NB) == 0 else {
                _ = Darwin.close(scanner)
                throw SessionStoreError.io(operation: "lock synthetic scanner", code: errno)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                _ = flock(scanner, LOCK_UN)
                _ = Darwin.close(scanner)
            }
        }) { try SessionArchiveCoding.atomicWrite(bytes, destination) }
        XCTAssertEqual(try Data(contentsOf: destination), bytes, "A brief scan lock must not fail an ordinary save")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    /// Saves `stored` on a background queue and reports whether it finished
    /// within `limit`. An inspection that stalls models a kernel open that does
    /// not return; it is released afterwards so a failing run cannot hang.
    private func saveWhileInspectionStalls(_ stored: SessionSnapshot, in root: URL, probe: RecoveryScanProbe,
                                           limit: TimeInterval = 10) -> Bool {
        whileInspectionStalls(probe: probe, limit: limit) { _ = try SessionStore(directory: root).save(stored) }
    }

    private func whileInspectionStalls(probe: RecoveryScanProbe, limit: TimeInterval = 10,
                                       _ work: @escaping @Sendable () throws -> Void) -> Bool {
        let release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            probe.finish(Result {
                try SensitiveFileIO.$beforeTemporaryInspection.withValue({ url in
                    probe.record(url)
                    _ = release.wait(timeout: .now() + 60)
                }) { try work() }
            })
            done.signal()
        }
        let finished = done.wait(timeout: .now() + limit) == .success
        if !finished {
            for _ in 0..<16 { release.signal() }
            XCTAssertEqual(done.wait(timeout: .now() + 60), .success)
        }
        return finished
    }

    func testDU05SaveNeverWaitsOnAnotherInProcessWritersTemporary() throws {
        let root = try DataSafetyFixtures.make("DU05-writer-in-flight")
        defer { DataSafetyFixtures.preserve(root) }
        let stored = try SessionStore(directory: root).save(SessionSnapshot())
        // The review queue shares the course directory and writes under its
        // own lock. Its writer pauses after leasing the temporary, mid-commit.
        let queueFile = root.appendingPathComponent("queue.json")
        let queueBytes = Data("synthetic queue body".utf8)
        let paused = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try SensitiveFileIO.$beforeTemporaryCommit.withValue({ _ in
                    paused.signal()
                    _ = resume.wait(timeout: .now() + 60)
                }) { try SensitiveFileIO.atomicWrite(queueBytes, to: queueFile) }
            } catch { XCTFail("The synthetic queue write failed: \(error)") }
            writerDone.signal()
        }
        XCTAssertEqual(paused.wait(timeout: .now() + 30), .success)
        let probe = RecoveryScanProbe()
        let finished = saveWhileInspectionStalls(stored, in: root, probe: probe)
        resume.signal()
        XCTAssertEqual(writerDone.wait(timeout: .now() + 30), .success)
        XCTAssertTrue(finished, "A course save must not wait on another writer's in-flight temporary")
        XCTAssertEqual(probe.names, [], "A save never inspects temporary items")
        XCTAssertNoThrow(try XCTUnwrap(probe.result).get())
        XCTAssertEqual(try Data(contentsOf: queueFile), queueBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }, [])
    }

    func testDU05StalledReopenScanHoldsNoStoreLockAgainstSaves() throws {
        let root = try DataSafetyFixtures.make("DU05-stalled-reopen")
        defer { DataSafetyFixtures.preserve(root) }
        let stored = try SessionStore(directory: root).save(SessionSnapshot())
        let destination = root.appendingPathComponent(SessionStore.snapshotFileName)
        let empty = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        try interruptedWrite(Data(), to: destination, orphan: empty)
        // Reopening the course starts the best-effort scan, which stalls on
        // the abandoned temporary as if its open never returned.
        let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let reopened = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                let loaded = try SensitiveFileIO.$beforeTemporaryInspection.withValue({ _ in
                    reached.signal()
                    _ = release.wait(timeout: .now() + 60)
                }) { try SessionStore(directory: root).load() }
                XCTAssertNotNil(loaded)
            } catch { XCTFail("Reopening the synthetic course failed: \(error)") }
            reopened.signal()
        }
        XCTAssertEqual(reached.wait(timeout: .now() + 30), .success)
        let probe = RecoveryScanProbe()
        let finished = saveWhileInspectionStalls(stored, in: root, probe: probe)
        release.signal()
        XCTAssertEqual(reopened.wait(timeout: .now() + 60), .success)
        XCTAssertTrue(finished, "A stalled recovery scan must not hold the store locks")
        XCTAssertNoThrow(try XCTUnwrap(probe.result).get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path), "The released scan still retires the owned empty write")
    }

    func testDU05SavesAndSaverReadbackNeverScanButReopenStillRecovers() async throws {
        let root = try DataSafetyFixtures.make("DU05-save-without-scan")
        defer { DataSafetyFixtures.preserve(root) }
        let stored = try SessionStore(directory: root).save(SessionSnapshot())
        let destination = root.appendingPathComponent(SessionStore.snapshotFileName)
        let empty = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        try interruptedWrite(Data(), to: destination, orphan: empty)
        let probe = RecoveryScanProbe()
        let saved = try SensitiveFileIO.$beforeTemporaryInspection.withValue({ probe.record($0) }) {
            try SessionStore(directory: root).save(stored)
        }
        let writer = SessionArchiveWriter(directory: root)
        let readback = try await SensitiveFileIO.$beforeTemporaryInspection.withValue({ probe.record($0) }) {
            try await writer.readback()
        }
        XCTAssertEqual(readback, saved)
        XCTAssertEqual(probe.names, [], "Neither a save nor its saver's readback runs the recovery scan")
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertEqual(try SessionStore(directory: root).load(), saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path), "Reopening the course still retires it")
    }

    func testDU05RecoveryNeverOpensAnInProcessWritersLeasedTemporary() throws {
        let root = try DataSafetyFixtures.make("DU05-in-process-lease")
        defer { DataSafetyFixtures.preserve(root) }
        let destination = root.appendingPathComponent("snapshot.json")
        let probe = RecoveryScanProbe()
        try SensitiveFileIO.$beforeTemporaryCommit.withValue({ pending in
            let directory = try SensitiveFileIO.Directory.open(at: root, create: false, tighten: false)
            let results = try SensitiveFileIO.$beforeTemporaryInspection.withValue({ probe.record($0) }) {
                try directory.recoverTemporaryItems()
            }
            XCTAssertEqual(results.first(where: { $0.name == pending.lastPathComponent })?.reason, "active_or_unavailable")
            XCTAssertEqual(probe.names, [], "This process's own active writer is never opened by recovery")
        }) { try SessionArchiveCoding.atomicWrite(Data("synthetic committed body".utf8), destination) }
        XCTAssertEqual(try Data(contentsOf: destination), Data("synthetic committed body".utf8))
    }

    func testDU05KillBetweenLinkAndUnlinkLeavesAnOpenableCourse() throws {
        let root = try DataSafetyFixtures.make("DU05-alias")
        defer { DataSafetyFixtures.preserve(root) }
        let stored = try SessionStore(directory: root).save(SessionSnapshot())
        let destination = root.appendingPathComponent(SessionStore.snapshotFileName)
        let bytes = try Data(contentsOf: destination)
        // Re-create the first-write state: no destination yet, then the new
        // name is linked and the process dies before the temporary is unlinked.
        try FileManager.default.removeItem(at: destination)
        let orphan = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        try interruptedWrite(bytes, to: destination, orphan: orphan)
        XCTAssertEqual(link(orphan.path, destination.path), 0)
        var info = stat()
        XCTAssertEqual(lstat(destination.path, &info), 0)
        XCTAssertEqual(info.st_nlink, 2, "Precondition: the committed file still has its temporary name")

        XCTAssertEqual(try SessionStore(directory: root).load(), stored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "The receipt-proven second name is retired")
        XCTAssertEqual(lstat(destination.path, &info), 0)
        XCTAssertEqual(info.st_nlink, 1)
        XCTAssertEqual(getxattr(destination.path, "com.jianhongli.LiveLingo.temporary-v1", nil, 0, 0, XATTR_NOFOLLOW), -1,
                       "The committed file no longer carries the writer's receipt")
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertNoThrow(try SessionStore(directory: root).save(stored))
    }

    func testDU05UnprovenSecondNameOfCommittedFileStaysRejected() throws {
        let root = try DataSafetyFixtures.make("DU05-unproven-alias")
        defer { DataSafetyFixtures.preserve(root) }
        _ = try SessionStore(directory: root).save(SessionSnapshot())
        let destination = root.appendingPathComponent(SessionStore.snapshotFileName)
        // A familiar temporary name without this inode's receipt proves nothing.
        let alias = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        XCTAssertEqual(link(destination.path, alias.path), 0)
        XCTAssertThrowsError(try SessionStore(directory: root).load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias.path))
        var info = stat()
        XCTAssertEqual(lstat(destination.path, &info), 0)
        XCTAssertEqual(info.st_nlink, 2)
    }

    func testDU05RecoveryPreservesReferencesAndReplacedInodes() throws {
        let root = try DataSafetyFixtures.make("DU05-references")
        defer { DataSafetyFixtures.preserve(root) }
        let destination = root.appendingPathComponent("snapshot.json")
        let bytes = Data("synthetic committed body".utf8)
        try SessionArchiveCoding.atomicWrite(bytes, destination)
        let linked = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        let aliased = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        let replaced = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        for orphan in [linked, aliased, replaced] { try interruptedWrite(bytes, to: destination, orphan: orphan) }
        XCTAssertEqual(link(linked.path, root.appendingPathComponent("retained-hardlink").path), 0)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("retained-alias").path,
            withDestinationPath: "./" + aliased.lastPathComponent)
        let retained = root.appendingPathComponent("retained-original")
        try FileManager.default.moveItem(at: replaced, to: retained)
        try FileManager.default.copyItem(at: retained, to: replaced)
        let directory = try SensitiveFileIO.Directory.open(at: root, create: false, tighten: false)
        let results = try directory.recoverTemporaryItems()
        XCTAssertEqual(results.first(where: { $0.name == linked.lastPathComponent })?.reason, "unknown_identity")
        XCTAssertEqual(results.first(where: { $0.name == aliased.lastPathComponent })?.reason, "referenced")
        XCTAssertEqual(results.first(where: { $0.name == replaced.lastPathComponent })?.reason, "unknown_receipt")
        for item in [linked, aliased, replaced, retained, destination] { XCTAssertEqual(try Data(contentsOf: item), bytes) }
    }

    func testDU05RecoveryNeverFollowsTemporarySymlinksOrCorruptReceipts() throws {
        let root = try DataSafetyFixtures.make("DU05-unsafe")
        defer { DataSafetyFixtures.preserve(root) }
        let protected = root.appendingPathComponent("protected.json")
        let bytes = Data("synthetic protected body".utf8)
        try SessionArchiveCoding.atomicWrite(bytes, protected)
        let symlink = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        let corrupt = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: protected)
        try interruptedWrite(bytes, to: protected, orphan: corrupt)
        let fd = Darwin.open(corrupt.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { _ = Darwin.close(fd) }
        let bad = Data("not a creation receipt".utf8)
        XCTAssertEqual(bad.withUnsafeBytes { fsetxattr(fd, "com.jianhongli.LiveLingo.temporary-v1", $0.baseAddress, $0.count, 0, 0) }, 0)
        let results = try SensitiveFileIO.Directory.open(at: root, create: false, tighten: false).recoverTemporaryItems()
        XCTAssertEqual(results.first(where: { $0.name == symlink.lastPathComponent })?.reason, "unknown_identity")
        XCTAssertEqual(results.first(where: { $0.name == corrupt.lastPathComponent })?.reason, "inspection_failed")
        XCTAssertEqual(try Data(contentsOf: corrupt), bytes)
        XCTAssertEqual(try Data(contentsOf: protected), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path), protected.path)
    }

    func testDU05RecoveryKeepsIndirectSiblingReferences() throws {
        let root = try DataSafetyFixtures.make("DU05-indirect-reference")
        defer { DataSafetyFixtures.preserve(root) }
        let destination = root.appendingPathComponent("snapshot.json")
        let bytes = Data("synthetic committed body".utf8)
        try SessionArchiveCoding.atomicWrite(bytes, destination)
        let orphan = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        try interruptedWrite(bytes, to: destination, orphan: orphan)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("directory-alias").path,
            withDestinationPath: ".")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("indirect-reference").path,
            withDestinationPath: "directory-alias/" + orphan.lastPathComponent)
        let results = try SensitiveFileIO.Directory.open(at: root, create: false, tighten: false).recoverTemporaryItems()
        XCTAssertEqual(results.first(where: { $0.name == orphan.lastPathComponent })?.reason, "referenced")
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testDU05StartupInventoryPreservesUncommittedInitialExport() throws {
        let parent = try DataSafetyFixtures.make("DU05-uncommitted-export")
        defer { DataSafetyFixtures.preserve(parent) }
        let course = parent.appendingPathComponent("course", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: false)
        var operations = SessionExporter.PublicationOperations()
        operations.exchangeDirectories = { _, _ in throw SessionStoreError.io(operation: "synthetic interruption before exchange", code: EIO) }
        XCTAssertThrowsError(try SessionExporter.export(segments: [], sessionDirectory: course, operations: operations))
        let staged = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".course.initial-export-") })
        let manifest = try Data(contentsOf: staged.appendingPathComponent("manifest.json"))
        XCTAssertEqual(try SessionWorkspace.recordingRecoveries(in: parent), [])
        XCTAssertEqual(try Data(contentsOf: staged.appendingPathComponent("manifest.json")), manifest)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: course.path).isEmpty)
    }

    func testDU05UnavailableTrackingParentDoesNotBlockInitialExport() throws {
        let parent = try DataSafetyFixtures.make("DU05-unavailable-parent")
        defer { DataSafetyFixtures.preserve(parent) }
        let course = parent.appendingPathComponent("course", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: false)
        try SensitiveFileIO.$temporaryTrackingParentUnavailable.withValue(true) {
            try SessionExporter.export(segments: [], sessionDirectory: course)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: course.appendingPathComponent("manifest.json").path))
        let siblings = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".course.initial-export-") }
        XCTAssertEqual(siblings.count, 1, "An unavailable trusted parent permits publication but preserves its residual")
        for sibling in siblings { XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: sibling.path).isEmpty) }
    }

    func testDU05StalledRecoveryScanNeverHoldsTheRecordingRecoveryIndexLocks() throws {
        let root = try DataSafetyFixtures.make("DU05-recording-index")
        defer { DataSafetyFixtures.preserve(root) }
        let a = SessionWorkspace.RecordingRecovery(id: UUID(), directory: root.appendingPathComponent("a"), outputRoot: root)
        let b = SessionWorkspace.RecordingRecovery(id: UUID(), directory: root.appendingPathComponent("b"), outputRoot: root)
        try SessionWorkspace.saveRecordingRecoveries([a], in: root)
        let index = root.appendingPathComponent("pending-recordings.json")
        let empty = root.appendingPathComponent(".session-write-\(UUID()).tmp")
        try interruptedWrite(Data(), to: index, orphan: empty)
        // A save holds the in-process recovery lock and the index flock; the
        // recovery scan, whose open can stall, must not run under them.
        let probe = RecoveryScanProbe()
        let finished = whileInspectionStalls(probe: probe) { try SessionWorkspace.saveRecordingRecoveries([b], in: root) }
        XCTAssertTrue(finished, "A stalled recovery scan must not hold the recording-recovery locks")
        XCTAssertEqual(probe.names, [], "Saving the recovery index never runs the recovery scan")
        XCTAssertNoThrow(try XCTUnwrap(probe.result).get())
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertEqual(Set(try SessionWorkspace.recordingRecoveries(in: root).map(\.id)), Set([a.id, b.id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path), "Reading the index at startup still retires it")
    }

    func testN02StaleRecoveryIndexSaveMergesAnotherRecording() throws {
        let root = try DataSafetyFixtures.make("N02")
        defer { DataSafetyFixtures.preserve(root) }
        let a = SessionWorkspace.RecordingRecovery(id: UUID(), directory: root.appendingPathComponent("a"), outputRoot: root)
        let b = SessionWorkspace.RecordingRecovery(id: UUID(), directory: root.appendingPathComponent("b"), outputRoot: root)
        let emptyA = try SessionWorkspace.recordingRecoveries(in: root)
        let emptyB = try SessionWorkspace.recordingRecoveries(in: root)
        try SessionWorkspace.saveRecordingRecoveries(emptyA + [a], in: root)
        try SessionWorkspace.saveRecordingRecoveries(emptyB + [b], in: root)
        XCTAssertEqual(Set(try SessionWorkspace.recordingRecoveries(in: root).map(\.id)), Set([a.id, b.id]))
    }

    func testN03InvalidRecoveryIndexCannotBeOverwrittenAfterReadFailure() throws {
        for raw in [#"{"version":99,"recordings":[],"futureState":"SYNTHETIC_RETAIN"}"#,
                    #"{"version":1,"recordings":[],"futureState":"SYNTHETIC_RETAIN"}"#,
                    "{synthetic truncated index"] {
            let root = try DataSafetyFixtures.make("N03")
            defer { DataSafetyFixtures.preserve(root) }
            let index = root.appendingPathComponent("pending-recordings.json"), bytes = Data(raw.utf8)
            try bytes.write(to: index)
            XCTAssertThrowsError(try SessionWorkspace.recordingRecoveries(in: root))
            let next = SessionWorkspace.RecordingRecovery(id: UUID(), directory: root.appendingPathComponent("new"), outputRoot: root)
            XCTAssertThrowsError(try SessionWorkspace.saveRecordingRecoveries([next], in: root))
            XCTAssertEqual(try Data(contentsOf: index), bytes)
        }
    }

    /// Sandbox relaunch: the recovery index keeps app-scoped bookmarks for the
    /// selected output root and promoted course folder, still reads records
    /// written before bookmarks existed, and re-encodes those unchanged.
    func testRecoveryIndexStoresFolderBookmarksAndReadsLegacyRecords() throws {
        let root = try DataSafetyFixtures.make("recovery-bookmarks")
        defer { DataSafetyFixtures.preserve(root) }
        let output = root.appendingPathComponent("selected", isDirectory: true)
        let course = output.appendingPathComponent("course", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: true)
        let legacyID = UUID()
        let legacy = #"{"version":1,"recordings":[{"id":"\#(legacyID.uuidString)","directory":"\#(root.appendingPathComponent("a").absoluteString)","outputRoot":"\#(output.absoluteString)","needsPromotion":true,"createdAt":1700000000}]}"#
        let index = root.appendingPathComponent("pending-recordings.json")
        try Data(legacy.utf8).write(to: index)
        let read = try SessionWorkspace.recordingRecoveries(in: root)
        XCTAssertEqual(read.map(\.id), [legacyID])
        XCTAssertNil(read.first?.outputRootBookmark)
        XCTAssertNil(read.first?.directoryBookmark)
        try SessionWorkspace.saveRecordingRecoveries([], in: root)
        let reencoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        let legacyKeys = try XCTUnwrap((reencoded["recordings"] as? [[String: Any]])?.first?.keys)
        XCTAssertEqual(Set(legacyKeys), ["id", "directory", "outputRoot", "needsPromotion", "createdAt"],
                       "a record without bookmarks keeps the format older readers accept")

        let selected = SessionWorkspace.RecordingRecovery(id: UUID(), directory: root.appendingPathComponent("b"), outputRoot: root,
                                                          createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            .withOutputRoot(output)
        XCTAssertEqual(selected.outputRoot, output)
        XCTAssertNotNil(selected.outputRootBookmark)
        let promoted = selected.promoted(to: course)
        XCTAssertFalse(promoted.needsPromotion)
        XCTAssertNotNil(promoted.directoryBookmark)
        try SessionWorkspace.saveRecordingRecoveries([promoted], in: root)
        let stored = try XCTUnwrap(SessionWorkspace.recordingRecoveries(in: root).first { $0.id == promoted.id })
        XCTAssertEqual(stored, promoted)

        let moved = root.appendingPathComponent("moved-selected", isDirectory: true)
        try FileManager.default.moveItem(at: output, to: moved)
        let outputAccess = try SessionWorkspace.ScopedFolderAccess(bookmark: try XCTUnwrap(stored.outputRootBookmark))
        defer { outputAccess.stop() }
        XCTAssertEqual(outputAccess.url.resolvingSymlinksInPath().path, moved.resolvingSymlinksInPath().path)
        let courseAccess = try SessionWorkspace.ScopedFolderAccess(bookmark: try XCTUnwrap(stored.directoryBookmark))
        defer { courseAccess.stop() }
        XCTAssertEqual(courseAccess.url.resolvingSymlinksInPath().path,
                       moved.appendingPathComponent("course").resolvingSymlinksInPath().path)
        XCTAssertThrowsError(try SessionWorkspace.ScopedFolderAccess(bookmark: Data("synthetic unreadable bookmark".utf8)))
        // A folder moved to the Trash still resolves, but must not receive the recording.
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: moved, to: trash.appendingPathComponent("selected"))
        XCTAssertThrowsError(try SessionWorkspace.ScopedFolderAccess(bookmark: try XCTUnwrap(stored.outputRootBookmark)))
    }

    func testN06LegacyRegularExportsArePreservedAndReconciled() throws {
        let root = try DataSafetyFixtures.make("N06")
        defer { DataSafetyFixtures.preserve(root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic v1.", chinese: "合成课程。")
        _ = try SessionStore(directory: root).save(SessionSnapshot(segments: [segment]))
        try SessionExporter.export(segments: [segment], sessionDirectory: root, summary: "Original synthetic note", createdAt: Date(timeIntervalSince1970: 0))
        let selectedBefore = try SessionExporter.currentExportDirectory(in: root)
        let original = try Data(contentsOf: selectedBefore.appendingPathComponent("summary-zh-Hans.md"))
        let legacy = Data("Synthetic old-writer updated note\n".utf8)
        // v0.2.0's atomic writes replace root symlinks with regular files.
        let summary = root.appendingPathComponent("summary-zh-Hans.md")
        try legacy.write(to: summary, options: .atomic)
        let oldManifest = Data(#"{"createdAt":"2026-10-08T00:00:00Z","sourceLocale":"en-US","targetLocale":"zh-Hans","recordingFile":"recording.wav","segmentCount":1}"#.utf8)
        try oldManifest.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        try SessionExporter.export(segments: [segment], sessionDirectory: root, summary: "New synthetic note", createdAt: Date(timeIntervalSince1970: 0))
        let selected = try SessionExporter.currentExportDirectory(in: root)
        for name in ["summary-zh-Hans.md", "manifest.json", "bilingual.srt", "bilingual.jsonl", "transcript-en.txt", "transcript-zh-Hans.txt"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), try Data(contentsOf: selected.appendingPathComponent(name)))
        }
        XCTAssertEqual(try Data(contentsOf: selectedBefore.appendingPathComponent("summary-zh-Hans.md")), original)
        let preserved = root.appendingPathComponent(".exports/recovered")
        let recoveries = try FileManager.default.contentsOfDirectory(at: preserved, includingPropertiesForKeys: nil)
        XCTAssertTrue(try recoveries.contains { try Data(contentsOf: $0.appendingPathComponent("summary-zh-Hans.md")) == legacy })
    }

    func testN10UnsupportedSymlinkPublishesCompletePortableGeneration() throws {
        for code in [ENOTSUP, EXDEV] {
            let root = try DataSafetyFixtures.make("N10-link")
            defer { DataSafetyFixtures.preserve(root) }
            try Data("synthetic recording".utf8).write(to: root.appendingPathComponent("recording.wav"))
            var operations = SessionExporter.PublicationOperations()
            operations.createSymbolicLink = { _, _ in throw SessionStoreError.io(operation: "injected symlink", code: code) }
            let caption = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic fallback.", chinese: "合成回退。")
            try SessionExporter.export(segments: [caption], sessionDirectory: root, summary: "合成笔记", operations: operations)
            try SessionExporter.export(segments: [caption], sessionDirectory: root, summary: "合成新笔记", operations: operations)
            let selected = try SessionExporter.currentExportDirectory(in: root)
            XCTAssertNotEqual(selected, root)
            for name in ["summary-zh-Hans.md", "manifest.json", "bilingual.srt", "bilingual.jsonl", "transcript-en.txt", "transcript-zh-Hans.txt"] {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), try Data(contentsOf: selected.appendingPathComponent(name)))
            }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recording.wav")), Data("synthetic recording".utf8))
        }
    }

    func testN10UnsupportedDirectorySwapHasPortableFallback() throws {
        for code in [ENOTSUP, EXDEV] {
            let root = try DataSafetyFixtures.make("N10-swap")
            defer { DataSafetyFixtures.preserve(root) }
            var operations = SessionExporter.PublicationOperations()
            operations.exchangeDirectories = { _, _ in throw SessionStoreError.io(operation: "injected swap", code: code) }
            try SessionExporter.export(segments: [], sessionDirectory: root, summary: "合成空课程", operations: operations)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("summary-zh-Hans.md"), encoding: .utf8), "合成空课程\n")
            let selected = try SessionExporter.currentExportDirectory(in: root)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), try Data(contentsOf: selected.appendingPathComponent("manifest.json")))
        }
    }

    func testN02ConditionalRetirementKeepsAnotherWritersNewLocation() throws {
        let root = try DataSafetyFixtures.make("N02-retirement")
        defer { DataSafetyFixtures.preserve(root) }
        let a = SessionWorkspace.RecordingRecovery(id: UUID(), directory: root.appendingPathComponent("a"), outputRoot: root)
        let saved = try SessionWorkspace.saveRecordingRecoveries([a], in: root)
        var moved = try XCTUnwrap(saved.first)
        moved.directory = root.appendingPathComponent("new-a")
        let b = SessionWorkspace.RecordingRecovery(id: UUID(), directory: root.appendingPathComponent("b"), outputRoot: root)
        try SessionWorkspace.saveRecordingRecoveries([moved, b], in: root, expected: saved)
        let bytes = try Data(contentsOf: root.appendingPathComponent("pending-recordings.json"))
        XCTAssertThrowsError(try SessionWorkspace.saveRecordingRecoveries([], in: root, retiring: saved))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pending-recordings.json")), bytes)
        let latest = try SessionWorkspace.recordingRecoveries(in: root)
        let result = try SessionWorkspace.saveRecordingRecoveries([], in: root, retiring: latest.filter { $0.id == a.id })
        XCTAssertEqual(result.map(\.id), [b.id])
    }

    func testN10PortableMidPublicationFailureRestoresEveryPriorRootMember() throws {
        let root = try DataSafetyFixtures.make("N10-rollback")
        defer { DataSafetyFixtures.preserve(root) }
        try Data("synthetic recording".utf8).write(to: root.appendingPathComponent("recording.wav"))
        var operations = SessionExporter.PublicationOperations()
        operations.createSymbolicLink = { _, _ in throw SessionStoreError.io(operation: "injected symlink", code: ENOTSUP) }
        let first = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic original.", chinese: "合成原文。")
        try SessionExporter.export(segments: [first], sessionDirectory: root, summary: "原合成笔记", operations: operations)
        let names = ["bilingual.jsonl", "bilingual.srt", "manifest.json", "summary-zh-Hans.md", "transcript-en.txt", "transcript-zh-Hans.txt"]
        let before = try names.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        operations.beforeMemberPublication = { name in
            if name == "bilingual.srt" { throw SessionStoreError.io(operation: "injected member publication", code: EIO) }
        }
        let next = TranscriptSegment(startTime: 1, endTime: 2, english: "Synthetic newer.", chinese: "合成新文。")
        XCTAssertThrowsError(try SessionExporter.export(segments: [first, next], sessionDirectory: root, summary: "新合成笔记", operations: operations))
        let selected = try SessionExporter.currentExportDirectory(in: root)
        for (index, name) in names.enumerated() {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), before[index])
            XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent(name)), before[index])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".exports/publishing.json").path))
    }

    func testN10InterruptedPortablePublicationRecoversBeforeNextExport() throws {
        let root = try DataSafetyFixtures.make("N10-interrupted")
        defer { DataSafetyFixtures.preserve(root) }
        try Data("synthetic recording".utf8).write(to: root.appendingPathComponent("recording.wav"))
        var operations = SessionExporter.PublicationOperations()
        operations.createSymbolicLink = { _, _ in throw SessionStoreError.io(operation: "injected symlink", code: EXDEV) }
        let first = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic original.", chinese: "合成原文。")
        try SessionExporter.export(segments: [first], sessionDirectory: root, summary: "原合成笔记", operations: operations)
        let previous = try SessionExporter.currentExportDirectory(in: root)
        try SessionExporter.export(segments: [first], sessionDirectory: root, summary: "新合成笔记", operations: operations)
        let next = try SessionExporter.currentExportDirectory(in: root)
        let names = ["bilingual.jsonl", "bilingual.srt", "manifest.json", "summary-zh-Hans.md", "transcript-en.txt", "transcript-zh-Hans.txt"]
        let store = root.appendingPathComponent(".exports")
        let transaction: [String: Any] = ["version": 1, "rollback": previous.lastPathComponent,
            "next": next.lastPathComponent, "names": names, "originallyPresent": names]
        try JSONSerialization.data(withJSONObject: transaction).write(to: store.appendingPathComponent("publishing.json"))
        try JSONSerialization.data(withJSONObject: ["version": 1, "generation": previous.lastPathComponent])
            .write(to: store.appendingPathComponent("current.json"), options: .atomic)
        try Data(contentsOf: previous.appendingPathComponent("manifest.json"))
            .write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        // The marker and mixed root files represent an interrupted publication;
        // the immutable reader remains on the whole previous generation.
        XCTAssertEqual(try SessionExporter.currentExportDirectory(in: root), previous)
        try SessionExporter.export(segments: [first], sessionDirectory: root, summary: "重试合成笔记", operations: operations)
        let selected = try SessionExporter.currentExportDirectory(in: root)
        for name in names {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), try Data(contentsOf: selected.appendingPathComponent(name)))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent("publishing.json").path))
    }

    func testN10PortableTransitionRetiresLegacyPointerAndCanBeMigrated() throws {
        let outer = try DataSafetyFixtures.make("N10-pointer-transition")
        defer { DataSafetyFixtures.preserve(outer) }
        let root = outer.appendingPathComponent("course"), target = outer.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("synthetic recording".utf8).write(to: root.appendingPathComponent("recording.wav"))
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic transition.", chinese: "合成切换。")
        try SessionExporter.export(segments: [segment], sessionDirectory: root, summary: "旧合成笔记")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".exports/current").path))
        var operations = SessionExporter.PublicationOperations()
        operations.createSymbolicLink = { _, _ in throw SessionStoreError.io(operation: "injected symlink", code: ENOTSUP) }
        try SessionExporter.export(segments: [segment], sessionDirectory: root, summary: "新合成笔记", operations: operations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".exports/current").path))
        let receipt = try SessionTreeMigration.copyVerified(from: root, to: target)
        XCTAssertEqual(try SessionTreeMigration.manifest(of: target), receipt.entries)
        let selected = try SessionExporter.currentExportDirectory(in: target)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("summary-zh-Hans.md")), try Data(contentsOf: selected.appendingPathComponent("summary-zh-Hans.md")))
    }

    func testN06ConcurrentForeignRootBytesArePreservedBeforeRollback() throws {
        let root = try DataSafetyFixtures.make("N06-concurrent-root")
        defer { DataSafetyFixtures.preserve(root) }
        try Data("synthetic recording".utf8).write(to: root.appendingPathComponent("recording.wav"))
        let first = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic original.", chinese: "合成原文。")
        var operations = SessionExporter.PublicationOperations()
        operations.createSymbolicLink = { _, _ in throw SessionStoreError.io(operation: "injected symlink", code: ENOTSUP) }
        try SessionExporter.export(segments: [first], sessionDirectory: root, summary: "旧合成笔记", operations: operations)
        let foreign = Data("SYNTHETIC_EXTERNAL_WRITER\n".utf8)
        operations.beforeMemberPublication = { name in
            if name == "manifest.json" {
                try foreign.write(to: root.appendingPathComponent(name), options: .atomic)
            }
        }
        let second = TranscriptSegment(startTime: 1, endTime: 2, english: "Synthetic newer.", chinese: "合成新文。")
        XCTAssertThrowsError(try SessionExporter.export(segments: [first, second], sessionDirectory: root, summary: "新合成笔记", operations: operations))
        let recovered = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".exports/recovered"), includingPropertiesForKeys: nil)
        XCTAssertTrue(try recovered.contains { try Data(contentsOf: $0.appendingPathComponent("manifest.json")) == foreign })
        let selected = try SessionExporter.currentExportDirectory(in: root)
        for name in ["bilingual.jsonl", "bilingual.srt", "manifest.json", "summary-zh-Hans.md", "transcript-en.txt", "transcript-zh-Hans.txt"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), try Data(contentsOf: selected.appendingPathComponent(name)))
        }
        operations.beforeMemberPublication = { _ in }
        try SessionExporter.export(segments: [first, second], sessionDirectory: root, summary: "重试合成笔记", operations: operations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".exports/publishing.json").path))
    }
    func testN14FirstExportEIOAllowsNormalRetryWithoutInjection() throws {
        let root = try DataSafetyFixtures.make("N14-first-export-retry")
        defer { DataSafetyFixtures.preserve(root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic retry source.", chinese: "合成重试原文。")
        let store = SessionStore(directory: root)
        let snapshot = try store.save(SessionSnapshot(segments: [segment]))
        let snapshotBytes = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
        let recording = Data("SYNTHETIC_RECORDING_RETAINED".utf8)
        try recording.write(to: root.appendingPathComponent("recording.wav"))
        var operations = SessionExporter.PublicationOperations()
        operations.beforeMemberPublication = { name in
            if name == "bilingual.srt" {
                throw SessionStoreError.io(operation: "synthetic first export failure", code: EIO)
            }
        }
        XCTAssertThrowsError(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成首次笔记", createdAt: Date(timeIntervalSince1970: 0), operations: operations)) { error in
            guard let failure = error as? SessionStoreError, case let .io(_, code) = failure else {
                return XCTFail("Expected the injected EIO, got \(error)")
            }
            XCTAssertEqual(code, EIO)
        }
        // Retry with the default operations: no failure/capability injection remains.
        XCTAssertNoThrow(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成重试笔记", createdAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), snapshotBytes)
        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recording.wav")), recording)
        let selected = try SessionExporter.currentExportDirectory(in: root)
        for name in ["bilingual.jsonl", "bilingual.srt", "manifest.json", "summary-zh-Hans.md", "transcript-en.txt", "transcript-zh-Hans.txt"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)),
                           try Data(contentsOf: selected.appendingPathComponent(name)), name)
        }
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent("summary-zh-Hans.md")), Data("合成重试笔记\n".utf8))
    }

    func testN15SymlinkLateForeignSummaryRejectsInconsistentSuccessAndPreservesVersions() throws {
        try assertN15LateForeignSummaryPreserved(portable: false)
    }

    func testN15PortableLateForeignSummaryRejectsInconsistentSuccessAndPreservesVersions() throws {
        try assertN15LateForeignSummaryPreserved(portable: true)
    }

    private func assertN15LateForeignSummaryPreserved(portable: Bool) throws {
        let root = try DataSafetyFixtures.make(portable ? "N15-late-foreign-portable" : "N15-late-foreign-symlink")
        defer { DataSafetyFixtures.preserve(root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic late-writer source.", chinese: "合成并发原文。")
        let store = SessionStore(directory: root)
        let snapshot = try store.save(SessionSnapshot(segments: [segment]))
        let snapshotBytes = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
        let recording = Data("SYNTHETIC_RECORDING_RETAINED".utf8)
        try recording.write(to: root.appendingPathComponent("recording.wav"))
        var operations = SessionExporter.PublicationOperations()
        if portable {
            operations.createSymbolicLink = { _, _ in
                throw SessionStoreError.io(operation: "synthetic unavailable symlink", code: ENOTSUP)
            }
        }
        try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成旧笔记", createdAt: Date(timeIntervalSince1970: 0), operations: operations)
        let names = ["bilingual.jsonl", "bilingual.srt", "manifest.json", "summary-zh-Hans.md", "transcript-en.txt", "transcript-zh-Hans.txt"]
        let previous = try SessionExporter.currentExportDirectory(in: root)
        let previousIndex = try Data(contentsOf: previous.appendingPathComponent("export-index.json"))
        var previousFiles: [String: Data] = [:]
        for name in names { previousFiles[name] = try Data(contentsOf: previous.appendingPathComponent(name)) }
        let foreign = Data("SYNTHETIC_FOREIGN_NOTE_AFTER_MEMBER_CHECK\n".utf8)
        operations.beforeMemberPublication = { name in
            if name == "transcript-zh-Hans.txt" {
                // Replace an already checked member just before the last member.
                try foreign.write(to: root.appendingPathComponent("summary-zh-Hans.md"), options: .atomic)
            }
        }
        XCTAssertThrowsError(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成新笔记", createdAt: Date(timeIntervalSince1970: 0), operations: operations))
        let selected = try SessionExporter.currentExportDirectory(in: root)
        for name in names {
            XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent(name)), previousFiles[name], name)
            XCTAssertEqual(try Data(contentsOf: previous.appendingPathComponent(name)), previousFiles[name], name)
        }
        XCTAssertEqual(try Data(contentsOf: previous.appendingPathComponent("export-index.json")), previousIndex)
        let recoveredRoot = root.appendingPathComponent(".exports/recovered")
        let recoveries = FileManager.default.fileExists(atPath: recoveredRoot.path)
            ? try FileManager.default.contentsOfDirectory(at: recoveredRoot, includingPropertiesForKeys: nil) : []
        let recoveredForeign = recoveries.filter {
            (try? Data(contentsOf: $0.appendingPathComponent("summary-zh-Hans.md"))) == foreign
        }
        XCTAssertTrue((try? Data(contentsOf: root.appendingPathComponent("summary-zh-Hans.md"))) == foreign
            || !recoveredForeign.isEmpty, "The late foreign summary must remain readable at the root or in a verified recovery")
        let versions = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".exports/versions"), includingPropertiesForKeys: nil)
        let nextSummary = Data("合成新笔记\n".utf8)
        let next = try XCTUnwrap(versions.first {
            (try? Data(contentsOf: $0.appendingPathComponent("summary-zh-Hans.md"))) == nextSummary
        }, "The complete attempted generation must be retained")
        let nextIndexObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: next.appendingPathComponent("export-index.json"))) as? [String: Any])
        let nextIndex = try XCTUnwrap(nextIndexObject["members"] as? [String: String])
        XCTAssertEqual(Set(nextIndex.keys), Set(names))
        for name in names {
            let bytes = try Data(contentsOf: next.appendingPathComponent(name))
            XCTAssertEqual(bytes, name == "summary-zh-Hans.md" ? nextSummary : previousFiles[name], name)
            XCTAssertEqual(nextIndex[name], SessionArchiveCoding.digest(bytes), name)
        }
        for recovery in recoveredForeign {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recovery.appendingPathComponent("export-index.json"))) as? [String: Any])
            let index = try XCTUnwrap(object["members"] as? [String: String])
            XCTAssertEqual(index["summary-zh-Hans.md"], SessionArchiveCoding.digest(foreign))
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), snapshotBytes)
        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recording.wav")), recording)
    }

    func testN17FailedExportRetainsUnfinishedAliasAndForeignWriterForRetry() throws {
        let root = try DataSafetyFixtures.make("N17-retained-alias")
        defer { DataSafetyFixtures.preserve(root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic retained source.", chinese: "合成保留原文。")
        let store = SessionStore(directory: root)
        let snapshot = try store.save(SessionSnapshot(segments: [segment]))
        let snapshotBytes = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
        let recording = Data("SYNTHETIC_N17_RECORDING".utf8)
        try recording.write(to: root.appendingPathComponent("recording.wav"))
        let alias = root.appendingPathComponent("bilingual.jsonl")
        let originalIdentity = StorageTestIdentity()
        var operations = SessionExporter.PublicationOperations()
        operations.beforeMemberPublication = { name in
            if name == "bilingual.srt" {
                var info = stat()
                guard lstat(alias.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else {
                    throw SessionStoreError.invalidState("Synthetic alias was not published")
                }
                originalIdentity.value = info
                throw SessionStoreError.io(operation: "synthetic N17 failure", code: EIO)
            }
        }
        XCTAssertThrowsError(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成未完成笔记", createdAt: Date(timeIntervalSince1970: 0), operations: operations)) { error in
            guard let failure = error as? SessionStoreError, case let .io(_, code) = failure else {
                return XCTFail("Expected the injected EIO, got \(error)")
            }
            XCTAssertEqual(code, EIO)
        }
        // A failure must not delete a public name. Retain the unfinished alias;
        // a retry can reuse it without a check-then-unlink ownership race.
        var retained = stat()
        XCTAssertEqual(lstat(alias.path, &retained), 0)
        XCTAssertEqual(retained.st_mode & S_IFMT, S_IFLNK)
        XCTAssertEqual(retained.st_dev, originalIdentity.value?.st_dev)
        XCTAssertEqual(retained.st_ino, originalIdentity.value?.st_ino)
        XCTAssertNoThrow(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成重试笔记", createdAt: Date(timeIntervalSince1970: 0)))
        let foreign = Data("SYNTHETIC_N17_FOREIGN_WRITER\n".utf8)
        try foreign.write(to: alias, options: .atomic)
        operations.beforeMemberPublication = { name in
            if name == "bilingual.srt" { throw SessionStoreError.io(operation: "synthetic next failure", code: EIO) }
        }
        XCTAssertThrowsError(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成再次笔记", createdAt: Date(timeIntervalSince1970: 0), operations: operations))
        XCTAssertNoThrow(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成最终笔记", createdAt: Date(timeIntervalSince1970: 0)))
        let recovered = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".exports/recovered"), includingPropertiesForKeys: nil)
        XCTAssertTrue(recovered.contains { (try? Data(contentsOf: $0.appendingPathComponent("bilingual.jsonl"))) == foreign })
        let selected = try SessionExporter.currentExportDirectory(in: root)
        for name in ["bilingual.jsonl", "bilingual.srt", "manifest.json", "summary-zh-Hans.md", "transcript-en.txt", "transcript-zh-Hans.txt"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), try Data(contentsOf: selected.appendingPathComponent(name)), name)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), snapshotBytes)
        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recording.wav")), recording)
    }

    func testN15PointerBoundaryConflictRequiresRetryAndPreservesBothVersions() throws {
        let root = try DataSafetyFixtures.make("N15-pointer-boundary")
        defer { DataSafetyFixtures.preserve(root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic boundary source.", chinese: "合成边界原文。")
        let store = SessionStore(directory: root)
        let snapshot = try store.save(SessionSnapshot(segments: [segment]))
        let snapshotBytes = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
        let recording = Data("SYNTHETIC_N15_RECORDING".utf8)
        try recording.write(to: root.appendingPathComponent("recording.wav"))
        try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成边界旧笔记", createdAt: Date(timeIntervalSince1970: 0))
        let previous = try SessionExporter.currentExportDirectory(in: root)
        let foreign = Data("SYNTHETIC_N15_AFTER_FINAL_PRECHECK\n".utf8)
        var operations = SessionExporter.PublicationOperations()
        operations.createSymbolicLink = { target, pending in
            guard symlink(target, pending.path) == 0 else {
                throw SessionStoreError.io(operation: "synthetic pointer link", code: errno)
            }
            if target.hasPrefix("versions/") {
                // The prepublication member check has finished. The next
                // operation commits current, so this is the reviewed late window.
                try foreign.write(to: root.appendingPathComponent("summary-zh-Hans.md"), options: .atomic)
            }
        }
        XCTAssertThrowsError(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成边界新笔记", createdAt: Date(timeIntervalSince1970: 0), operations: operations)) { error in
            XCTAssertTrue(error.localizedDescription.contains("需重试"), "A published but inconsistent root view requires an explicit retry: \(error)")
        }
        let selected = try SessionExporter.currentExportDirectory(in: root)
        XCTAssertNotEqual(selected, previous)
        XCTAssertEqual(try Data(contentsOf: selected.appendingPathComponent("summary-zh-Hans.md")), Data("合成边界新笔记\n".utf8))
        XCTAssertEqual(try Data(contentsOf: previous.appendingPathComponent("summary-zh-Hans.md")), Data("合成边界旧笔记\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("summary-zh-Hans.md")), foreign)
        XCTAssertNoThrow(try SessionExporter.export(segments: [segment], sessionDirectory: root,
            summary: "合成边界重试笔记", createdAt: Date(timeIntervalSince1970: 0)))
        let recovered = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".exports/recovered"), includingPropertiesForKeys: nil)
        XCTAssertTrue(recovered.contains { (try? Data(contentsOf: $0.appendingPathComponent("summary-zh-Hans.md"))) == foreign })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), snapshotBytes)
        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("recording.wav")), recording)
    }

    private final class StorageTestIdentity: @unchecked Sendable {
        var value: stat?
    }

    private func checkpoint(_ value: SessionSnapshot) -> SessionGenerationCheckpoint {
        let input = "Synthetic frozen input"
        return SessionGenerationCheckpoint(sessionID: value.sessionID, inputRevision: value.inputRevision,
            modelName: "synthetic", protocolVersion: 2,
            inputDigest: SessionArchiveCoding.digest(Data(input.utf8)),
            promptDigest: SessionArchiveCoding.digest(Data("synthetic prompt".utf8)),
            input: input, prefix: "{\"topic\":\"retained", evidenceIDs: value.segments.map(\.id))
    }

    private func envelopeVersion(in root: URL) throws -> Int {
        let data = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["schemaVersion"] as? Int)
    }

    func testDU01ModernLanguagesRejectLegacyReaderBeforeResave() throws {
        let root = try DataSafetyFixtures.make("DU01"); defer { DataSafetyFixtures.preserve(root) }
        let segment = TranscriptSegment(startTime: 0, endTime: 1, english: "El curso es sintético.", chinese: "合成课程。", sourceLanguage: "es")
        let value = try SessionStore(directory: root).save(SessionSnapshot(segments: [segment], targetLocale: "en"))
        XCTAssertGreaterThan(try envelopeVersion(in: root), 1, "v0.2.0 accepts schema 1 and drops modern fields")
        XCTAssertEqual(try SessionStore(directory: root).load(), value)
    }

    func testDU02AnnotatedCourseRejectsLegacyWriterBeforeRevision() throws {
        let root = try DataSafetyFixtures.make("DU02"); defer { DataSafetyFixtures.preserve(root) }
        var segment = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic formula.", chinese: "合成公式。")
        segment.updateCaptionAnnotation(targetCode: "en", formulaUncertain: true)
        let value = try SessionStore(directory: root).save(SessionSnapshot(segments: [segment]))
        XCTAssertGreaterThan(try envelopeVersion(in: root), 1, "legacy revisions omit the annotation and cannot replay safely")
        XCTAssertEqual(try SessionStore(directory: root).load(), value)
    }

    func testDU03StaleWriterPreservesCheckpointWithoutJournal() async throws {
        let root = try DataSafetyFixtures.make("DU03-direct"); defer { DataSafetyFixtures.preserve(root) }
        let store = SessionStore(directory: root)
        let old = try store.save(SessionSnapshot())
        let writer = SessionArchiveWriter(directory: root, restored: old)
        var newer = old
        newer.generationCheckpoints = [checkpoint(old)]
        let durable = try store.save(newer)
        let saved = try await writer.commit(old)
        XCTAssertEqual(saved.generationCheckpoints, durable.generationCheckpoints)
        XCTAssertEqual(try store.load()?.generationCheckpoints, durable.generationCheckpoints)
    }

    func testDU03StaleWriterPreservesJournalCheckpoint() async throws {
        let root = try DataSafetyFixtures.make("DU03-journal"); defer { DataSafetyFixtures.preserve(root) }
        let store = SessionStore(directory: root)
        let old = try store.save(SessionSnapshot())
        let writer = SessionArchiveWriter(directory: root, restored: old)
        let durable = try store.append(.generationCheckpoint(checkpoint(old)))
        let saved = try await writer.commit(old)
        XCTAssertEqual(saved.generationCheckpoints, durable.generationCheckpoints)
    }

    func testDU03DirectSaveCannotSilentlyDeleteCheckpoint() throws {
        let root = try DataSafetyFixtures.make("DU03-deletion"); defer { DataSafetyFixtures.preserve(root) }
        let store = SessionStore(directory: root)
        var value = SessionSnapshot()
        value.generationCheckpoints = [checkpoint(value)]
        var saved = try store.save(value)
        let original = try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName))
        saved.generationCheckpoints = []
        XCTAssertThrowsError(try store.save(saved))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(SessionStore.snapshotFileName)), original)
    }

    func testDU03CoalescedRetirementCannotDeleteResumedProgress() async throws {
        let root = try DataSafetyFixtures.make("DU03-coalesced"); defer { DataSafetyFixtures.preserve(root) }
        let store = SessionStore(directory: root)
        var value = SessionSnapshot()
        value.generationCheckpoints = [checkpoint(value)]
        let saved = try store.save(value)
        let writer = SessionArchiveWriter(directory: root, restored: saved)
        var resumed = saved
        resumed.generationCheckpoints[0].prefix += " newer synthetic progress"
        let result = try await writer.commit(resumed, retiringCheckpoints: saved.generationCheckpoints)
        XCTAssertEqual(result.generationCheckpoints, resumed.generationCheckpoints)
        XCTAssertEqual(try store.load()?.generationCheckpoints, resumed.generationCheckpoints)
    }

    func testDU04ExportFailureKeepsEntirePreviousVersion() throws {
        let root = try DataSafetyFixtures.make("DU04"); defer { DataSafetyFixtures.preserve(root) }
        let first = TranscriptSegment(startTime: 0, endTime: 1, english: "First synthetic segment.", chinese: "第一段。")
        try SessionExporter.export(segments: [first], sessionDirectory: root, summary: "原合成笔记")
        let names = ["transcript-en.txt", "transcript-zh-Hans.txt", "bilingual.jsonl", "manifest.json", "summary-zh-Hans.md"]
        let originals = try names.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let srt = root.appendingPathComponent("bilingual.srt")
        try FileManager.default.moveItem(at: srt, to: root.appendingPathComponent("previous.srt"))
        try FileManager.default.createDirectory(at: srt, withIntermediateDirectories: false)
        let second = TranscriptSegment(startTime: 1, endTime: 2, english: "Second synthetic segment.", chinese: "第二段。")
        XCTAssertThrowsError(try SessionExporter.export(segments: [first, second], sessionDirectory: root, summary: "新合成笔记"))
        for (index, name) in names.enumerated() {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), originals[index], name)
        }
    }

    func testAtomicExportCourseCanBeMigratedWithOnlyManagedLinks() throws {
        let root = try DataSafetyFixtures.make("DU04-migration"); defer { DataSafetyFixtures.preserve(root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let caption = TranscriptSegment(startTime: 0, endTime: 1, english: "Synthetic migration.", chinese: "合成迁移。")
        _ = try SessionStore(directory: source).save(SessionSnapshot(segments: [caption]))
        try SessionExporter.export(segments: [caption], sessionDirectory: source, summary: "合成笔记")
        let receipt = try SessionTreeMigration.copyVerified(from: source, to: target)
        XCTAssertEqual(try SessionTreeMigration.manifest(of: source), receipt.entries)
        XCTAssertEqual(try SessionTreeMigration.manifest(of: target), receipt.entries)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("bilingual.jsonl")),
                       try Data(contentsOf: target.appendingPathComponent("bilingual.jsonl")))
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside synthetic bytes".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("unknown-link"), withDestinationURL: outside)
        XCTAssertThrowsError(try SessionTreeMigration.manifest(of: source))
    }

    func testInitialExportKeepsPrivateDirectoryPermissions() throws {
        let root = try DataSafetyFixtures.make("DU04-permissions"); defer { DataSafetyFixtures.preserve(root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try SessionExporter.export(segments: [], sessionDirectory: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o700, "Publishing a directory must preserve its private access mode")
    }

    func testAtomicExportCannotFollowAnExternalVersionsDirectory() throws {
        let root = try DataSafetyFixtures.make("DU04-confinement"); defer { DataSafetyFixtures.preserve(root) }
        let course = root.appendingPathComponent("course"), outside = root.appendingPathComponent("outside")
        let store = course.appendingPathComponent(".exports"), identifier = UUID().uuidString
        let generation = outside.appendingPathComponent(identifier)
        try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data(#"{"version":1,"members":{}}"#.utf8).write(to: generation.appendingPathComponent("export-index.json"))
        try FileManager.default.createSymbolicLink(at: store.appendingPathComponent("versions"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(atPath: store.appendingPathComponent("current").path,
                                                  withDestinationPath: "versions/" + identifier)
        XCTAssertThrowsError(try SessionExporter.currentExportDirectory(in: course))
    }
}
