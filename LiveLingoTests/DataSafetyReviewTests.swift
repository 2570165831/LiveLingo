import Dispatch
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
        try write([try job(first, notebook("first"))], to: journal)
        let a = queue(journal), b = queue(journal)
        await a.shutdownForTesting()
        await b.shutdownForTesting()
        try a.enqueue(directory: second, notebook: notebook("second"))
        let latest = try Data(contentsOf: journal)
        b.togglePause()
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
        try q.enqueue(directory: directory, notebook: notebook())
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
        try q.enqueue(directory: directory, notebook: notebook())
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
}
