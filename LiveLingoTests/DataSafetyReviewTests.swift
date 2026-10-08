import Dispatch
import Darwin
import Foundation
import Testing
@testable import LiveLingo

/// Synthetic, deterministic faults in the real queue. No runtime or preferences.
@Suite(.serialized)
@MainActor
struct DataSafetyReviewTests {
    private static let response = #"{"reviewVersion":2,"corrections":[],"additions":[]}"#

    private func notebook(_ label: String = "fixture", batches: Int = 1) throws -> LearningNotebook {
        var book = LearningNotebook()
        for index in 0..<batches {
            try book.append(evidence: [TranscriptSegment(startTime: Double(index * 4),
                endTime: Double(index * 4 + 3), english: "The synthetic marker \(label) \(index) is green.",
                chinese: "合成标记 \(label) \(index) 是绿色。")],
                note: LearningNote(topic: "合成标记 \(label) \(index)",
                    points: [.init(kind: "核心结论", text: "合成标记是绿色。")]))
        }
        return book
    }

    private func course(_ root: URL, _ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func job(_ directory: URL, _ book: LearningNotebook) throws -> LearningReviewQueue.Job {
        try LearningReviewQueue.prepareJob(directory: directory, batches: book.batches, original: book.markdown())
    }

    private func queue(_ journal: URL,
                       generate: @escaping LearningReviewQueue.Generator = { _, _, _, _, _ in Self.response })
        -> LearningReviewQueue {
        LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled,
            generate: generate, retryDelays: [0.05, 0.05], startupSnapshotReader: { _ in nil })
    }

    private func write(_ jobs: [LearningReviewQueue.Job], to journal: URL, paused: Bool = true) throws {
        try JSONEncoder().encode(LearningReviewQueue.Journal(jobs: jobs, userPaused: paused,
            version: LearningReviewQueue.journalVersion)).write(to: journal, options: .atomic)
    }

    private func read(_ journal: URL) throws -> LearningReviewQueue.Journal {
        try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool, seconds: Double = 3) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func futureJournalIsRejectedWithoutRewritingItsBytes() async throws {
        let root = try DataSafetyFixtures.make("review-future")
        defer { DataSafetyFixtures.preserve(root) }
        let journal = root.appendingPathComponent("queue.json")
        let bytes = Data(#"{"jobs":[],"userPaused":true,"version":99,"futureSafetyState":{"retain":"synthetic"}}"#.utf8)
        try bytes.write(to: journal, options: .atomic)
        let q = queue(journal)
        await q.shutdownForTesting()
        #expect(q.currentFailure != nil)
        q.performPrimaryAction()
        q.startAwaitingJob()
        await q.pauseAndWait()
        #expect(q.currentFailure != nil)
        #expect(try Data(contentsOf: journal) == bytes)
    }

    @Test(arguments: [0, 1, 2])
    func restoreValidationCannotBeBypassedBySaving(_ fault: Int) async throws {
        let root = try DataSafetyFixtures.make("review-invalid-restore")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        let book = try notebook()
        var saved = try job(directory, book)
        var jobs = [saved]
        switch fault {
        case 0: jobs.append(saved) // duplicate job ID
        case 1: saved.next = -1; jobs = [saved]
        default:
            saved.identity = try ReviewIdentity(sessionID: UUID(), scope: .wholeLesson, inputRevision: 0)
            saved.inputDigest = String(repeating: "0", count: 64)
            jobs = [saved]
        }
        let journal = root.appendingPathComponent("queue.json")
        try write(jobs, to: journal)
        let original = try Data(contentsOf: journal)
        var calls = 0
        let q = queue(journal) { _, _, _, _, _ in calls += 1; return Self.response }
        #expect(q.currentFailure != nil)
        #expect(q.userPaused)
        await q.shutdownForTesting()
        q.performPrimaryAction()
        q.retryJob(saved.id)
        #expect(await waitFor { q.managementError != nil || q.currentFailure != nil })
        await q.pauseAndWait()
        #expect(q.currentFailure != nil)
        #expect(try Data(contentsOf: journal) == original)
        #expect(calls == 0)
    }

    @Test func staleQueueWriterCannotDiscardAnotherWritersNewJob() async throws {
        let root = try DataSafetyFixtures.make("review-two-writers")
        defer { DataSafetyFixtures.preserve(root) }
        let first = try course(root, "first")
        let second = try course(root, "second")
        let journal = root.appendingPathComponent("queue.json")
        var initial = try job(first, notebook("first"))
        // An empty prefix has no checkpoint binding. Seed the normalized state
        // so two startup repairs cannot race before the tested stale write.
        initial.prefixInputDigest = nil
        try write([initial], to: journal)
        let initialBytes = try Data(contentsOf: journal)
        let a = queue(journal), b = queue(journal)
        await a.shutdownForTesting()
        await b.shutdownForTesting()
        #expect(a.currentFailure == nil)
        #expect(b.currentFailure == nil)
        #expect(try Data(contentsOf: journal) == initialBytes)
        try await a.enqueueAsync(directory: second, notebook: notebook("second"))
        let latest = try Data(contentsOf: journal)
        b.togglePause()
        try? await b.waitForPendingStorage()
        #expect(b.currentFailure != nil)
        #expect(try Data(contentsOf: journal) == latest)
        #expect(try read(journal).jobs.count == 2)
    }

    @Test(arguments: [false, true])
    func unchangedSaveDetectsExternalReplacement(_ corrupt: Bool) async throws {
        let root = try DataSafetyFixtures.make("review-replaced-file")
        defer { DataSafetyFixtures.preserve(root) }
        let journal = root.appendingPathComponent("queue.json")
        let directory = try course(root, "course")
        try write([try job(directory, notebook())], to: journal)
        let q = queue(journal)
        await q.shutdownForTesting()
        await q.pauseAndWait()
        if corrupt { try Data("{synthetic truncated journal".utf8).write(to: journal, options: .atomic) }
        else { try write([], to: journal, paused: false) }
        let replaced = try Data(contentsOf: journal)
        await q.pauseAndWait()
        #expect(q.currentFailure != nil)
        #expect(try Data(contentsOf: journal) == replaced)
        #expect(q.items.count == 1)
    }

    @Test func journalChecksumRejectsChangedReportBody() async throws {
        let root = try DataSafetyFixtures.make("review-integrity")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        var saved = try job(directory, notebook(batches: 2))
        saved.next = 1
        saved.prefixInputDigest = nil
        saved.reports = ["## Synthetic review\nOriginal body"]
        let journal = root.appendingPathComponent("queue.json")
        try write([saved], to: journal)
        let q = queue(journal)
        await q.shutdownForTesting()
        await q.pauseAndWait()
        var raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        let checksum = raw["checksum"] as? String
        #expect(checksum?.count == 64)
        var jobs = try #require(raw["jobs"] as? [[String: Any]])
        jobs[0]["reports"] = ["## Synthetic review\nChanged body"]
        raw["jobs"] = jobs // retain the previously committed checksum
        let changed = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        try changed.write(to: journal, options: .atomic)
        let restored = queue(journal)
        await restored.shutdownForTesting()
        #expect(restored.currentFailure != nil)
        restored.performPrimaryAction()
        #expect(try Data(contentsOf: journal) == changed)
    }

    @Test func sameCompletedProgressCannotReplaceSavedReportBody() throws {
        let root = try DataSafetyFixtures.make("review-report-conflict")
        defer { DataSafetyFixtures.preserve(root) }
        var saved = try job(root, notebook())
        saved.next = 1
        saved.prefixInputDigest = nil
        saved.reports = ["## Synthetic review\nOriginal body"]
        try ReviewReportCollection.save(LearningReviewQueue.reportEntry(for: saved), in: root)
        let alias = root.appendingPathComponent("summary-review.md")
        let index = root.appendingPathComponent(ReviewReportCollection.manifestFileName)
        let originalAlias = try Data(contentsOf: alias), originalIndex = try Data(contentsOf: index)
        saved.reports = ["## Synthetic review\nChanged body"]
        #expect(throws: ReviewIdentityError.self) {
            try ReviewReportCollection.save(LearningReviewQueue.reportEntry(for: saved), in: root)
        }
        #expect(try Data(contentsOf: alias) == originalAlias)
        #expect(try Data(contentsOf: index) == originalIndex)
    }

    @Test(arguments: [false, true])
    func completedReportSurvivesFinalJournalFailureWithoutRegeneration(_ restart: Bool) async throws {
        let root = try DataSafetyFixtures.make("review-final-save")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        let journal = root.appendingPathComponent("queue.json")
        let preserved = root.appendingPathComponent("pre-failure-queue.json")
        var calls = 0
        var fault: Error?
        var injected = false
        let q = queue(journal) { _, _, _, _, _ in calls += 1; return Self.response }
        q.setContext(recording: false, concurrent: true, resourcesAvailable: false)
        try await q.enqueueAsync(directory: directory, notebook: notebook())
        q.onUpdate = { _, _, _ in
            guard !injected else { return }
            injected = true
            do {
                try FileManager.default.moveItem(at: journal, to: preserved)
                try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
            } catch { fault = error }
        }
        q.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        #expect(await waitFor { injected && !q.running })
        #expect(fault == nil)
        #expect(q.currentFailure != nil)
        #expect(q.items.first?.completed == 1)
        #expect(try read(preserved).jobs.first?.next == 0)
        #expect(try ReviewReportCollection.read(in: directory).contains { $0.completed == 1 })
        if restart { await q.shutdownForTesting() }
        try FileManager.default.moveItem(at: journal, to: root.appendingPathComponent("obstructed-slot"))
        try FileManager.default.moveItem(at: preserved, to: journal)
        if restart {
            var restartCalls = 0
            let restored = queue(journal) { _, _, _, _, _ in restartCalls += 1; return Self.response }
            restored.setContext(recording: false, concurrent: true, resourcesAvailable: true)
            #expect(await waitFor { restored.items.isEmpty && !restored.running })
            #expect(restartCalls == 0)
            await restored.shutdownForTesting()
        } else {
            q.performPrimaryAction()
            #expect(await waitFor { q.items.isEmpty && !q.running })
            #expect(q.currentFailure == nil)
        }
        #expect(calls == 1)
        #expect(try read(journal).jobs.isEmpty)
        await q.shutdownForTesting()
    }

    @Test(arguments: ["SYNTHETIC_PREFIX_a", "SYNTHETIC_DIFFERENT_CONTENT_abcdefghijklmnop"])
    func streamCheckpointOnlyAcceptsMonotonicExtension(_ replacement: String) async throws {
        let root = try DataSafetyFixtures.make("review-prefix")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        var saved = try job(directory, notebook())
        let prefix = "SYNTHETIC_PREFIX_abcdefghijklmnop"
        saved.prefix = prefix
        let journal = root.appendingPathComponent("queue.json")
        try write([saved], to: journal)
        var updated = false
        var suppliedPrefix = ""
        let q = queue(journal) { _, current, _, _, update in
            suppliedPrefix = current
            await update(replacement)
            updated = true
            while true { try await Task.sleep(for: .milliseconds(10)) }
        }
        q.togglePause()
        #expect(await waitFor { updated })
        await q.pauseAndWait()
        #expect(suppliedPrefix == prefix)
        #expect(try read(journal).jobs.first?.prefix == prefix)
        await q.shutdownForTesting()
    }

    @Test(arguments: [false, true])
    func retryTimerFollowsNewHeadAfterQueueEdit(_ remove: Bool) async throws {
        let root = try DataSafetyFixtures.make("review-timer")
        defer { DataSafetyFixtures.preserve(root) }
        var early = try job(course(root, "early"), notebook("early"))
        var late = try job(course(root, "late"), notebook("late"))
        let now = Date().timeIntervalSince1970
        early.retryPending = .init(attempts: 1, notBefore: now + 0.2, code: "synthetic")
        late.retryPending = .init(attempts: 1, notBefore: now + 3, code: "synthetic")
        let journal = root.appendingPathComponent("queue.json")
        try write([late, early], to: journal, paused: false)
        var calls = 0
        let q = queue(journal) { _, _, _, _, _ in calls += 1; return Self.response }
        q.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        if remove { q.removeJob(late.id) } else { q.moveJobToEnd(late.id) }
        #expect(await waitFor({ calls > 0 }, seconds: 1))
        #expect(calls == 1)
        #expect(q.managementError == nil)
        await q.shutdownForTesting()
    }

    @Test func lateCallbackCannotOverwriteOrCancelCurrentAttempt() async throws {
        let root = try DataSafetyFixtures.make("review-attempt")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        let journal = root.appendingPathComponent("queue.json")
        var firstUpdate: (@MainActor @Sendable (String) async -> Void)?
        var calls = 0
        var secondCancelled = false
        let q = queue(journal) { _, _, _, record, update in
            calls += 1
            record("synthetic-attempt-\(calls)")
            if calls == 1 { firstUpdate = update }
            else { await update("SYNTHETIC_CURRENT_PREFIX") }
            do { while true { try await Task.sleep(for: .milliseconds(10)) } }
            catch { if calls == 2 { secondCancelled = true }; throw error }
        }
        try await q.enqueueAsync(directory: directory, notebook: notebook())
        #expect(await waitFor { firstUpdate != nil })
        await q.pauseAndWait()
        q.togglePause()
        #expect(await waitFor { calls == 2 && q.activeRuntimeRequestID == "synthetic-attempt-2" })
        let stale = try #require(firstUpdate)
        await stale("SYNTHETIC_STALE_PREFIX")
        #expect(q.journalForTesting.jobs.first?.prefix == "SYNTHETIC_CURRENT_PREFIX")
        await stale(String(repeating: "x", count: 524_289))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!secondCancelled)
        #expect(q.currentFailure == nil)
        #expect(q.activeRuntimeRequestID == "synthetic-attempt-2")
        await q.pauseAndWait()
        await q.shutdownForTesting()
    }

    @Test func cancellationBeforeWorkerStartsNeverEntersGenerator() async throws {
        let root = try DataSafetyFixtures.make("review-cancel-entry")
        defer { DataSafetyFixtures.preserve(root) }
        var calls = 0
        let q = queue(root.appendingPathComponent("queue.json")) { _, _, _, _, _ in
            calls += 1
            return Self.response
        }
        try q.enqueue(directory: root, notebook: notebook())
        await q.pauseAndWait()
        #expect(calls == 0)
        #expect(q.items.first?.completed == 0)
        await q.shutdownForTesting()
    }

    @Test func asyncReportReadYieldsMainActorWhileAnotherStoreOwnsLock() async throws {
        let root = try DataSafetyFixtures.make("review-main-actor")
        defer { DataSafetyFixtures.preserve(root) }
        let writing = try course(root, "writer"), reading = try course(root, "reader")
        let entered = ReviewRequestIdentityBox()
        let release = DispatchSemaphore(value: 0)
        let writer = SessionStore(directory: writing, atomicWrite: { data, url in
            entered.record("synthetic-writer-holds-lock")
            _ = release.wait(timeout: .now() + 2)
            try data.write(to: url, options: .atomic)
        })
        let writeTask = Task.detached { try writer.save(SessionSnapshot()) }
        #expect(await waitFor { entered.latest != nil })
        var heartbeat = false
        let pulse = Task { @MainActor in heartbeat = true; release.signal() }
        let q = queue(root.appendingPathComponent("queue.json"))
        _ = try await q.collectedReviewReportMarkdownAsync(for: reading)
        #expect(heartbeat, "The report reader must release MainActor while storage is locked")
        await pulse.value
        _ = try await writeTask.value
        await q.shutdownForTesting()
    }

    @Test func applicationTerminationReportsQueuePersistenceFailure() async throws {
        let root = try DataSafetyFixtures.make("review-termination-save")
        defer { DataSafetyFixtures.preserve(root) }
        let journal = root.appendingPathComponent("queue.json")
        try write([try job(root, notebook())], to: journal)
        let q = queue(journal)
        await q.shutdownForTesting()
        await q.pauseAndWait()
        try FileManager.default.moveItem(at: journal, to: root.appendingPathComponent("preserved-queue.json"))
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        var threw = false
        do { try await q.pauseForApplicationTermination() }
        catch { threw = true }
        #expect(threw, "Termination must not confirm an unreadable or unwritable queue")
    }

    @Test func applicationTerminationAllowsPersistedGenerationFailure() async throws {
        let root = try DataSafetyFixtures.make("review-termination-model")
        defer { DataSafetyFixtures.preserve(root) }
        let journal = root.appendingPathComponent("queue.json")
        var saved = try job(root, notebook())
        saved.failure = "Synthetic generation failure already retained in the queue"
        saved.awaitingManualStart = true
        try write([saved], to: journal)
        let q = queue(journal)
        await q.shutdownForTesting()
        try await q.pauseForApplicationTermination()
        #expect(q.currentFailure == saved.failure)
        #expect(try read(journal).jobs.first?.failure == saved.failure)
    }

    private func recoveryJob(in directory: URL, notebook book: LearningNotebook,
                             bound: Bool) throws -> LearningReviewQueue.Job {
        var saved = try job(directory, book)
        saved.prefixInputDigest = nil
        if bound {
            let snapshot = try SessionStore(directory: directory).save(SessionSnapshot(
                segments: book.batches.flatMap(\.evidence), batches: book.batches,
                notebookRevision: book.revision))
            saved.identity = try ReviewIdentity(sessionID: snapshot.sessionID, scope: .wholeLesson,
                inputRevision: snapshot.inputRevision, notebookRevision: snapshot.notebookRevision)
            saved.courseInputDigest = try ReviewInputBinding.digest(snapshot.batches)
        }
        return saved
    }

    private func assertRejectedRecovery(_ pending: LearningReviewQueue.Job, journal: URL,
                                        directory: URL, alias: Data, manifest: Data) async throws {
        var calls = 0
        let q = queue(journal) { _, _, _, _, _ in calls += 1; throw CancellationError() }
        q.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        #expect(await waitFor { !q.running && (q.currentFailure != nil || q.items.isEmpty) })
        await q.shutdownForTesting()
        #expect(q.currentFailure != nil, "Conflicting recovery data must visibly pause the queue")
        #expect(calls == 0, "A recovery conflict must never enter the generator")
        #expect(q.items.count == 1, "The unfinished job must remain available for recovery")
        let disk = try read(journal)
        #expect(disk.jobs.count == 1)
        #expect(disk.jobs.first?.id == pending.id)
        #expect(disk.jobs.first?.identity == pending.identity)
        #expect(disk.jobs.first?.next == pending.next)
        #expect(disk.jobs.first?.reports == pending.reports)
        #expect(try Data(contentsOf: directory.appendingPathComponent("summary-review.md")) == alias)
        #expect(try Data(contentsOf: directory.appendingPathComponent(ReviewReportCollection.manifestFileName)) == manifest,
                "Keep the conflicting manifest bytes as well as the previously committed report")
    }

    @Test(arguments: [false, true])
    func completedReportRecoveryRejectsChangedBatchBodies(_ bound: Bool) async throws {
        let root = try DataSafetyFixtures.make("review-recovery-body")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        let pending = try recoveryJob(in: directory, notebook: notebook(), bound: bound)
        let journal = root.appendingPathComponent("queue.json")
        try write([pending], to: journal, paused: false)
        var completed = pending
        completed.next = 1
        completed.reports = ["## Synthetic completed advisory\nSYNTHETIC_ORIGINAL_ADVISORY"]
        try ReviewReportCollection.save(LearningReviewQueue.reportEntry(for: completed), in: directory)
        let alias = try Data(contentsOf: directory.appendingPathComponent("summary-review.md"))
        let manifestURL = directory.appendingPathComponent(ReviewReportCollection.manifestFileName)
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var entries = try #require(raw["entries"] as? [[String: Any]])
        entries[0]["batchReports"] = ["## Synthetic completed advisory\nSYNTHETIC_MUTATED_ADVISORY"]
        raw["entries"] = entries
        let changed = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        try changed.write(to: manifestURL, options: .atomic)
        #expect(throws: ReviewIdentityError.self) { _ = try ReviewReportCollection.read(in: directory) }
        try await assertRejectedRecovery(pending, journal: journal, directory: directory,
                                         alias: alias, manifest: changed)
    }

    @Test(arguments: [false, true], [false, true])
    func completedReportRecoveryRejectsMissingBatchBodies(_ bound: Bool, _ missing: Bool) async throws {
        let root = try DataSafetyFixtures.make("review-recovery-count")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        let pending = try recoveryJob(in: directory, notebook: notebook(batches: 2), bound: bound)
        let journal = root.appendingPathComponent("queue.json")
        try write([pending], to: journal, paused: false)
        var completed = pending
        completed.next = 2
        completed.reports = ["## Synthetic first advisory\nFIRST_RETAINED_BODY",
                             "## Synthetic second advisory\nSECOND_RETAINED_BODY"]
        try ReviewReportCollection.save(LearningReviewQueue.reportEntry(for: completed), in: directory)
        let alias = try Data(contentsOf: directory.appendingPathComponent("summary-review.md"))
        let manifestURL = directory.appendingPathComponent(ReviewReportCollection.manifestFileName)
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var entries = try #require(raw["entries"] as? [[String: Any]])
        if missing { entries[0].removeValue(forKey: "batchReports") }
        else { entries[0]["batchReports"] = Array(completed.reports.prefix(1)) }
        raw["entries"] = entries
        let changed = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        try changed.write(to: manifestURL, options: .atomic)
        try await assertRejectedRecovery(pending, journal: journal, directory: directory,
                                         alias: alias, manifest: changed)
    }

    @Test(arguments: [false, true])
    func completedReportRecoveryCannotReplaceTheJournalsCompletedPrefix(_ bound: Bool) async throws {
        let root = try DataSafetyFixtures.make("review-recovery-prefix")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        var pending = try recoveryJob(in: directory, notebook: notebook(batches: 2), bound: bound)
        pending.next = 1
        pending.reports = ["## Synthetic first advisory\nJOURNAL_RETAINED_PREFIX"]
        let journal = root.appendingPathComponent("queue.json")
        try write([pending], to: journal, paused: false)
        var completed = pending
        completed.next = 2
        completed.reports = ["## Synthetic first advisory\nCONFLICTING_SAVED_PREFIX",
                             "## Synthetic second advisory\nSECOND_RETAINED_BODY"]
        try ReviewReportCollection.save(LearningReviewQueue.reportEntry(for: completed), in: directory)
        // This manifest is internally valid. The conflict is with the separate
        // journal's already committed prefix, not an invalid checksum fixture.
        #expect(try ReviewReportCollection.read(in: directory).first?.batchReports == completed.reports)
        let alias = try Data(contentsOf: directory.appendingPathComponent("summary-review.md"))
        let manifest = try Data(contentsOf: directory.appendingPathComponent(ReviewReportCollection.manifestFileName))
        try await assertRejectedRecovery(pending, journal: journal, directory: directory,
                                         alias: alias, manifest: manifest)
    }

    @Test(arguments: [false, true])
    func validCompletedReportRecoveryRetainsEveryBatchWithoutGeneration(_ bound: Bool) async throws {
        let root = try DataSafetyFixtures.make("review-recovery-valid")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        let pending = try recoveryJob(in: directory, notebook: notebook(batches: 2), bound: bound)
        let journal = root.appendingPathComponent("queue.json")
        try write([pending], to: journal, paused: false)
        var completed = pending
        completed.next = 2
        completed.reports = ["## Synthetic first advisory\nFIRST_RETAINED_BODY\n\n- retained detail",
                             "## Synthetic second advisory\nSECOND_RETAINED_BODY"]
        try ReviewReportCollection.save(LearningReviewQueue.reportEntry(for: completed), in: directory)
        let alias = try Data(contentsOf: directory.appendingPathComponent("summary-review.md"))
        var calls = 0
        let q = queue(journal) { _, _, _, _, _ in calls += 1; throw CancellationError() }
        q.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        #expect(await waitFor { !q.running && (q.items.isEmpty || q.currentFailure != nil) })
        await q.shutdownForTesting()
        #expect(q.currentFailure == nil)
        #expect(calls == 0)
        #expect(try read(journal).jobs.isEmpty)
        #expect(try ReviewReportCollection.read(in: directory).first?.batchReports == completed.reports)
        #expect(try Data(contentsOf: directory.appendingPathComponent("summary-review.md")) == alias)
    }

    @Test func manualEnqueueYieldsMainActorWhileAnotherStoreOwnsLock() async throws {
        let root = try DataSafetyFixtures.make("review-enqueue-main-actor")
        defer { DataSafetyFixtures.preserve(root) }
        let writing = try course(root, "writer"), reading = try course(root, "reader")
        let journal = root.appendingPathComponent("queue.json")
        let book = try notebook()
        var calls = 0
        let q = queue(journal) { _, _, _, _, _ in calls += 1; throw CancellationError() }
        q.setContext(recording: false, concurrent: true, resourcesAvailable: false)
        let delay = ReviewSafetyStorageDelay()
        defer { delay.release() }
        let writer = SessionStore(directory: writing, atomicWrite: { data, url in
            delay.waitOnce()
            try data.write(to: url, options: .atomic)
        })
        let writeTask = Task.detached { try writer.save(SessionSnapshot()) }
        #expect(await waitFor { delay.entered })
        let attempted = ReviewRequestIdentityBox()
        let operation = Task { @MainActor in
            attempted.record("synthetic-enqueue-started")
            try await q.enqueueAsync(directory: reading, notebook: book)
        }
        let pulse = Task { @MainActor in
            let started = await waitFor { attempted.latest != nil }
            if started { delay.releaseFromHeartbeat() }
            return started
        }
        try await operation.value
        #expect(await pulse.value)
        _ = try await writeTask.value
        #expect(delay.releasedByHeartbeat,
                "Enqueue must let MainActor release the real store lock before the fallback timeout")
        #expect(!delay.timedOut, "A heartbeat after a timeout cannot demonstrate UI responsiveness")
        await q.pauseAndWait()
        #expect(q.currentFailure == nil)
        #expect(calls == 0)
        #expect(try read(journal).jobs.first?.directory == reading)
        #expect(try read(journal).jobs.first?.batches == book.batches)
        await q.shutdownForTesting()
    }

    @Test(arguments: ["pause", "primary-action", "resource-refresh"])
    func queuePersistenceYieldsMainActorDuringSyntheticSlowStorage(_ action: String) async throws {
        let root = try DataSafetyFixtures.make("review-persistence-main-actor")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        let storage = try course(root, "queue-storage")
        let journal = storage.appendingPathComponent("queue.json")
        var saved = try job(directory, notebook())
        saved.prefixInputDigest = nil
        try write([saved], to: journal, paused: false)
        var calls = 0
        let q = queue(journal) { _, _, _, _, _ in calls += 1; throw CancellationError() }
        q.setContext(recording: false, concurrent: true, resourcesAvailable: false)
        try await q.waitForPendingStorage()
        let delay = ReviewSafetyStorageDelay()
        defer { delay.release() }
        try await ReviewStorageTestHooks.$beforeDirectoryAccess.withValue({ url in
            guard url.standardizedFileURL.path == storage.standardizedFileURL.path else { return }
            delay.waitOnce()
        }) {
            let operation = Task { @MainActor in
                switch action {
                case "pause": await q.pauseAndWait()
                case "primary-action": q.performPrimaryAction()
                default:
                    // A changed resource context still blocks generation while its
                    // pause event requires a real journal persistence operation.
                    q.setContext(recording: true, concurrent: false, resourcesAvailable: true)
                }
            }
            let pulse = Task { @MainActor in
                let entered = await waitFor { delay.entered }
                if entered { delay.releaseFromHeartbeat() }
                return entered
            }
            await operation.value
            #expect(await pulse.value, "The delay must engage on this synthetic journal's actual storage path")
            #expect(delay.waitedOnMainThread == false, "The filesystem operation must execute off MainActor")
            #expect(delay.releasedByHeartbeat)
            #expect(!delay.timedOut)
            await q.pauseAndWait()
            #expect(q.currentFailure == nil)
            #expect(calls == 0)
            let disk = try read(journal)
            #expect(disk.userPaused)
            #expect(disk.jobs.first?.id == saved.id)
            #expect(disk.jobs.first?.batches == saved.batches)
            #expect(disk.jobs.first?.reports == saved.reports)
            await q.shutdownForTesting()
        }
    }

    @Test func completedOutputCallbackCannotRemoveAnotherCompletedJob() async throws {
        let root = try DataSafetyFixtures.make("review-output-ownership")
        defer { DataSafetyFixtures.preserve(root) }
        let a = try course(root, "a"), b = try course(root, "b")
        let journal = root.appendingPathComponent("queue.json")
        let first = try recoveryJob(in: a, notebook: notebook("a"), bound: true)
        var second = try job(b, notebook("b"))
        second.next = second.batches.count
        second.reports = ["## Synthetic completed second report\nKeep this unrelated advice."]
        second.prefixInputDigest = nil
        try write([first, second], to: journal)
        var calls = 0, invalidated = false
        var callbackError: Error?
        let q = queue(journal) { _, _, _, _, _ in calls += 1; return Self.response }
        q.onUpdate = { directory, _, progress in
            guard directory == a, progress.contains("1/1"), !invalidated else { return }
            invalidated = true
            q.setContext(recording: true, concurrent: false, resourcesAvailable: false)
            do { try q.invalidateInputs(sessionID: first.identity!.sessionID, inputRevision: 1) }
            catch { callbackError = error }
        }
        q.setContext(recording: false, concurrent: true, resourcesAvailable: true)
        q.performPrimaryAction()
        #expect(await waitFor { invalidated && !q.running })
        await q.shutdownForTesting()
        #expect(callbackError == nil)
        #expect(calls == 1)
        #expect(q.items.map(\.id) == [second.id], "A stale output continuation must not remove the next job")
        let disk = try read(journal)
        #expect(disk.jobs.map(\.id) == [second.id])
        #expect(disk.jobs.first?.reports == second.reports)
        #expect(disk.retiredJobs?.first(where: { $0.id == first.id })?.next == 1)
        #expect(disk.retiredJobs?.first(where: { $0.id == first.id })?.reports.count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func n16SupersedingAdmissionRetiresEachIDOnceAndRestarts(_ invalidateDuringOutput: Bool,
                                                          _ failAdmissionSave: Bool) async throws {
        let root = try DataSafetyFixtures.make("N16-enqueue-reentry")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        let book = try notebook("old-input")
        let store = SessionStore(directory: directory)
        let saved = try store.save(SessionSnapshot(segments: book.batches.flatMap(\.evidence),
            batches: book.batches, notebookRevision: book.revision))
        let journal = root.appendingPathComponent("queue.json")
        var calls = 0
        let q = queue(journal) { _, _, _, _, _ in calls += 1; return Self.response }
        q.setContext(recording: true, concurrent: false, resourcesAvailable: false)
        try await q.enqueueAsync(directory: directory, notebook: book,
            sessionID: saved.sessionID, inputRevision: saved.inputRevision)
        let oldID = try #require(q.items.first?.id)
        let previous = try #require(saved.segments.first)
        let replacement = TranscriptSegment(id: previous.id, startTime: previous.startTime,
            endTime: previous.endTime, english: "The synthetic marker has a revised input.",
            chinese: "合成标记的输入已经修订。", sessionID: saved.sessionID,
            inputRevision: saved.inputRevision + 1)
        _ = try store.append(.inputRevision(.init(fromRevision: saved.inputRevision,
            toRevision: saved.inputRevision + 1, previousSegment: previous,
            replacementSegment: replacement, retainedBatches: saved.batches,
            reason: "Synthetic confirmed revision")))
        let revised = try store.append(.appendBatch(LearningNoteBatch(id: UUID(), evidence: [replacement],
            note: LearningNote(topic: "合成修订", points: [.init(kind: "核心结论", text: "输入已经修订。")]))))
        let newBook = try LearningNotebook(snapshot: revised)
        var entered = false
        var callbackError: Error?
        var heldLock: Int32 = -1
        defer { if heldLock >= 0 { _ = flock(heldLock, LOCK_UN); _ = Darwin.close(heldLock) } }
        q.onUpdate = { _, _, _ in
            guard !entered,
                  q.journalForTesting.jobs.contains(where: { $0.id == oldID }) else { return }
            entered = true
            do {
                if invalidateDuringOutput {
                    try q.invalidateInputs(sessionID: saved.sessionID, inputRevision: revised.inputRevision)
                }
                if failAdmissionSave {
                    heldLock = Darwin.open(journal.appendingPathExtension("lock").path,
                        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
                    guard heldLock >= 0, flock(heldLock, LOCK_EX | LOCK_NB) == 0 else {
                        throw POSIXError(.EIO)
                    }
                }
            }
            catch { callbackError = error }
        }
        var admissionError: Error?
        do {
            try await q.enqueueAsync(directory: directory, notebook: newBook,
                sessionID: saved.sessionID, inputRevision: revised.inputRevision)
        } catch { admissionError = error }
        #expect(entered)
        #expect(callbackError == nil)
        #expect((admissionError != nil) == failAdmissionSave)
        if failAdmissionSave {
            #expect(q.currentFailure != nil)
            #expect(q.journalForTesting.jobs.contains { $0.id == oldID } == !invalidateDuringOutput,
                "Admission rollback must retain a retirement performed by a reentrant callback")
            #expect(q.journalForTesting.retiredJobs?.contains { $0.id == oldID } == (invalidateDuringOutput ? true : nil))
            _ = flock(heldLock, LOCK_UN)
            _ = Darwin.close(heldLock)
            heldLock = -1
            q.onUpdate = nil
            q.togglePause()
            try await q.waitForPendingStorage()
            try await q.enqueueAsync(directory: directory, notebook: newBook,
                sessionID: saved.sessionID, inputRevision: revised.inputRevision)
        }
        try await q.waitForPendingStorage()
        await q.shutdownForTesting()
        #expect(q.currentFailure == nil)
        let bytes = try Data(contentsOf: journal)
        let disk = try read(journal)
        try disk.validateIntegrity()
        let all = disk.jobs + (disk.retiredJobs ?? [])
        #expect(disk.jobs.count == 1)
        #expect(disk.jobs.first?.identity?.inputRevision == revised.inputRevision)
        #expect(disk.retiredJobs?.count == 1)
        #expect(all.filter { $0.id == oldID }.count == 1)
        #expect(Set(all.map(\.id)).count == all.count)
        let restored = queue(journal) { _, _, _, _, _ in calls += 1; return Self.response }
        await restored.shutdownForTesting()
        #expect(restored.currentFailure == nil)
        #expect(restored.items.count == 1)
        #expect(try Data(contentsOf: journal) == bytes)
        #expect(calls == 0)
    }

    @Test(arguments: [0, 1, 2])
    func n18SupersedingAdmissionPreservesEventsDuringReportSave(_ refresh: Int) async throws {
        let root = try DataSafetyFixtures.make("N18-enqueue-events")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        let book = try notebook("original")
        let store = SessionStore(directory: directory)
        let saved = try store.save(SessionSnapshot(segments: book.batches.flatMap(\.evidence),
            batches: book.batches, notebookRevision: book.revision))
        let journal = root.appendingPathComponent("queue.json")
        var calls = 0
        let q = queue(journal) { _, _, _, _, _ in calls += 1; return Self.response }
        q.setContext(recording: true, concurrent: false, resourcesAvailable: false)
        try await q.enqueueAsync(directory: directory, notebook: book,
            sessionID: saved.sessionID, inputRevision: saved.inputRevision)
        try await q.waitForPendingStorage()
        let oldID = try #require(q.items.first?.id)
        let appended = TranscriptSegment(startTime: 4, endTime: 7,
            english: "The synthetic append-only evidence is new.", chinese: "合成追加证据是新的。",
            sessionID: saved.sessionID, inputRevision: saved.inputRevision)
        _ = try store.append(.upsertSegment(appended))
        let updated = try store.append(.appendBatch(LearningNoteBatch(id: UUID(), evidence: [appended],
            note: LearningNote(topic: "合成追加笔记", points: [.init(kind: "核心结论", text: "同一输入追加合成笔记。")]))))
        let newBook = try LearningNotebook(snapshot: updated)
        #expect(updated.inputRevision == saved.inputRevision)
        #expect(newBook.revision == book.revision + 1)
        var beforeRefresh: LearningReviewQueue.Job?
        var afterRefresh: LearningReviewQueue.Job?
        q.onUpdate = { _, _, _ in
            guard beforeRefresh == nil,
                  let current = q.journalForTesting.jobs.first(where: { $0.id == oldID }) else { return }
            beforeRefresh = current
            switch refresh {
            case 0: q.setContext(recording: true, concurrent: false, resourcesAvailable: false)
            case 1: q.setContext(recording: false, concurrent: true, resourcesAvailable: false)
            default: q.togglePause()
            }
            afterRefresh = q.journalForTesting.jobs.first(where: { $0.id == oldID })
        }
        var admissionError: Error?
        do {
            try await q.enqueueAsync(directory: directory, notebook: newBook,
                sessionID: saved.sessionID, inputRevision: updated.inputRevision)
        } catch { admissionError = error }
        q.onUpdate = nil
        try await q.waitForPendingStorage()
        await q.shutdownForTesting()
        let before = try #require(beforeRefresh)
        let after = try #require(afterRefresh)
        #expect(after.events != before.events, "The report callback must append a real lifecycle event")
        #expect(after.events?.contains { $0.code == "paused" && $0.detail == "management" } == true)
        var withoutEventsBefore = before, withoutEventsAfter = after
        withoutEventsBefore.events = nil; withoutEventsAfter.events = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(withoutEventsBefore) == encoder.encode(withoutEventsAfter),
            "Only events may change in this admission regression")
        #expect(admissionError == nil, "A lifecycle event must not reject the valid newer notebook")
        #expect(q.currentFailure == nil)
        let bytes = try Data(contentsOf: journal)
        let disk = try read(journal)
        try disk.validateIntegrity()
        let all = disk.jobs + (disk.retiredJobs ?? [])
        #expect(disk.jobs.count == 1)
        #expect(disk.jobs.first?.id != oldID)
        #expect(disk.jobs.first?.identity?.notebookRevision == newBook.revision)
        #expect(disk.jobs.first?.batches == newBook.batches)
        #expect(disk.retiredJobs?.count == 1)
        #expect(all.filter { $0.id == oldID }.count == 1)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(disk.retiredJobs?.first(where: { $0.id == oldID })?.events == after.events,
            "Retirement must retain events appended while the report was being saved")
        #expect(disk.userPaused == (refresh == 2))
        let restored = queue(journal) { _, _, _, _, _ in calls += 1; return Self.response }
        await restored.shutdownForTesting()
        #expect(restored.currentFailure == nil)
        #expect(restored.items.map(\.id) == disk.jobs.map(\.id))
        #expect(restored.journalForTesting.retiredJobs?.first(where: { $0.id == oldID })?.events == after.events)
        #expect(try Data(contentsOf: journal) == bytes)
        #expect(calls == 0)
    }

    @Test func n16JournalRejectsDuplicateLiveAndRetiredIDsBeforeWriting() throws {
        let root = try DataSafetyFixtures.make("N16-journal-ids")
        defer { DataSafetyFixtures.preserve(root) }
        let saved = try job(try course(root, "course"), notebook())
        let duplicate = LearningReviewQueue.Journal(jobs: [saved], userPaused: true,
            version: LearningReviewQueue.journalVersion, retiredJobs: [saved])
        let encoded = try JSONEncoder().encode(duplicate)
        let decoded = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: encoded)
        var rejected = false
        do { try decoded.validateIntegrity() }
        catch is ReviewIdentityError { rejected = true }
        #expect(rejected, "A valid checksum must not permit duplicate live/history IDs")
    }

    @Test func manualEnqueueRejectsCandidateInvalidatedByOutputCallback() async throws {
        let root = try DataSafetyFixtures.make("review-enqueue-ownership")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        let book = try notebook()
        let snapshot = try SessionStore(directory: directory).save(SessionSnapshot(
            segments: book.batches.flatMap(\.evidence), batches: book.batches,
            notebookRevision: book.revision))
        let journal = root.appendingPathComponent("queue.json")
        let q = queue(journal)
        q.setContext(recording: true, concurrent: false, resourcesAvailable: false)
        var invalidated = false
        var callbackError: Error?
        q.onUpdate = { _, _, _ in
            guard !invalidated else { return }
            invalidated = true
            do { try q.invalidateInputs(sessionID: snapshot.sessionID, inputRevision: 1) }
            catch { callbackError = error }
        }
        var rejected = false
        do { try await q.enqueueAsync(directory: directory, notebook: book) }
        catch is ReviewIdentityError { rejected = true }
        await q.shutdownForTesting()
        #expect(invalidated)
        #expect(callbackError == nil)
        #expect(rejected, "Admission must report the candidate was invalidated while its report was saved")
        #expect(q.items.isEmpty)
        let disk = try read(journal)
        #expect(disk.jobs.isEmpty)
        #expect(disk.retiredJobs?.count == 1)
        #expect(disk.retiredJobs?.first?.batches == book.batches)
    }

    @Test(arguments: [false, true])
    func failedRemovalRestoresItsJobAndCanRetryStorage(_ lastJob: Bool) async throws {
        let root = try DataSafetyFixtures.make("review-removal-rollback")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        let journal = root.appendingPathComponent("queue.json")
        var failed = try job(directory, notebook("failed"))
        failed.failure = "Synthetic generation failure"
        var other = try job(directory, notebook("other"))
        other.failure = "Another synthetic failure"
        try write(lastJob ? [failed] : [failed, other], to: journal)
        let q = queue(journal)
        try await q.waitForPendingStorage()
        let original = try Data(contentsOf: journal)
        let lock = Darwin.open(journal.appendingPathExtension("lock").path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        #expect(lock >= 0)
        defer { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        q.removeFailedJob()
        _ = try? await q.waitForPendingStorage()
        #expect(await waitFor { q.currentFailure != nil })
        #expect(q.items.map(\.id) == (lastJob ? [failed.id] : [failed.id, other.id]))
        #expect(try Data(contentsOf: journal) == original)
        #expect(flock(lock, LOCK_UN) == 0)
        q.performPrimaryAction()
        _ = try? await q.waitForPendingStorage()
        #expect(q.currentFailure == failed.failure, "Retrying storage must retain the original generation failure")
        #expect(try read(journal).jobs.first?.id == failed.id)
        q.removeFailedJob()
        _ = try? await q.waitForPendingStorage()
        #expect(await waitFor { q.items.count == (lastJob ? 0 : 1) })
        #expect(try read(journal).jobs.map(\.id) == (lastJob ? [] : [other.id]))
        await q.shutdownForTesting()
    }

    @Test func anEmptyQueueCanRetryAnUnconfirmedPauseSave() async throws {
        let root = try DataSafetyFixtures.make("review-empty-retry")
        defer { DataSafetyFixtures.preserve(root) }
        let journal = root.appendingPathComponent("queue.json")
        try write([], to: journal, paused: false)
        let q = queue(journal)
        let lock = Darwin.open(journal.appendingPathExtension("lock").path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        #expect(lock >= 0)
        defer { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        await q.pauseAndWait()
        #expect(q.currentFailure != nil)
        #expect(flock(lock, LOCK_UN) == 0)
        q.performPrimaryAction()
        _ = try? await q.waitForPendingStorage()
        #expect(q.currentFailure == nil)
        #expect(try read(journal).userPaused)
        #expect(try read(journal).jobs.isEmpty)
        await q.shutdownForTesting()
    }

    @Test func failureDiagnosticsYieldMainActorDuringSyntheticSlowStorage() async throws {
        let root = try DataSafetyFixtures.make("review-diagnostics-main-actor")
        defer { DataSafetyFixtures.preserve(root) }
        let directory = try course(root, "course")
        let journal = root.appendingPathComponent("queue.json")
        let diagnostics = root.appendingPathComponent("ReviewDiagnostics")
        try write([try job(directory, notebook())], to: journal)
        let finalResponse = "{synthetic invalid final JSON"
        var generatedInputHash: String?
        let q = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .standard,
            generate: { input, _, _, _, _ in
                generatedInputHash = ReviewInputBinding.digest(Data(input.utf8))
                return finalResponse
            }, retryDelays: [0.01, 0.01], startupSnapshotReader: { _ in nil })
        try await q.waitForPendingStorage()
        let delay = ReviewSafetyStorageDelay()
        defer { delay.release() }
        try await ReviewStorageTestHooks.$beforeDirectoryAccess.withValue({ url in
            guard url.standardizedFileURL.path == diagnostics.standardizedFileURL.path else { return }
            delay.waitOnce()
        }) {
            let pulse = Task { @MainActor in
                let entered = await waitFor { delay.entered }
                if entered { delay.releaseFromHeartbeat() }
                return entered
            }
            q.setContext(recording: false, concurrent: true, resourcesAvailable: true)
            q.performPrimaryAction()
            #expect(await pulse.value, "The delay must engage on this synthetic diagnostics storage path")
            #expect(delay.waitedOnMainThread == false)
            #expect(delay.releasedByHeartbeat)
            #expect(!delay.timedOut)
            #expect(await waitFor { !q.running && q.currentFailure != nil })
            await q.shutdownForTesting()
            let files = try FileManager.default.contentsOfDirectory(at: diagnostics, includingPropertiesForKeys: nil)
            #expect(files.count == 1)
            let data = try Data(contentsOf: #require(files.first))
            let snapshot = try JSONDecoder().decode(ReviewDiagnosticSnapshot.self, from: data)
            #expect(snapshot.containsReasoning == false)
            #expect(snapshot.stage == "decode")
            #expect(snapshot.code == "invalid_json")
            #expect(generatedInputHash != nil)
            #expect(snapshot.inputSHA256 == generatedInputHash)
            #expect(snapshot.responseSHA256 == ReviewInputBinding.digest(Data(finalResponse.utf8)))
            #expect(snapshot.inputBytes > 0)
            #expect(snapshot.responseBytes == finalResponse.utf8.count)
            #expect(snapshot.input == nil)
            #expect(snapshot.finalResponse == nil)
            #expect(snapshot.inputOmitted == true)
            #expect(snapshot.responseOmitted == true)
            let storedJSON = String(decoding: data, as: UTF8.self)
            #expect(!storedJSON.contains(finalResponse))
            #expect(!storedJSON.contains("The synthetic marker fixture 0 is green."))
        }
    }
}

/// The timeout makes a failing synchronous call bounded. A passing result must
/// be released by a MainActor heartbeat, never by that timeout.
private final class ReviewSafetyStorageDelay: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var claimed = false
    private var didTimeout = false
    private var heartbeatReleased = false
    private var mainThread: Bool?

    var entered: Bool { lock.withLock { claimed } }
    var timedOut: Bool { lock.withLock { didTimeout } }
    var waitedOnMainThread: Bool? { lock.withLock { mainThread } }
    var releasedByHeartbeat: Bool { lock.withLock { heartbeatReleased && !didTimeout } }

    func waitOnce() {
        let shouldWait = lock.withLock {
            guard !claimed else { return false }
            mainThread = Thread.isMainThread
            claimed = true
            return true
        }
        guard shouldWait else { return }
        let result = semaphore.wait(timeout: .now() + 2)
        lock.withLock { didTimeout = result == .timedOut }
    }

    func releaseFromHeartbeat() {
        lock.withLock { heartbeatReleased = true }
        semaphore.signal()
    }

    func release() { semaphore.signal() }
}
