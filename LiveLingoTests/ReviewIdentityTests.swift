import Foundation
#if !REVIEW_IDENTITY_STANDALONE
import Testing
@testable import LiveLingo
#endif

/// The standalone runner and Xcode tests execute the same scenarios against the
/// production types. Every queue has a fake generator and a temporary journal.
@MainActor
enum ReviewIdentityScenarios {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static let emptyResponse = #"{"reviewVersion":2,"corrections":[],"additions":[]}"#

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(description: message) }
    }

    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch is ReviewIdentityError { return }
        throw Failure(description: message)
    }

    static func until(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(description: message)
    }

    @MainActor final class Fixture {
        let root: URL
        let directory: URL
        let journal: URL
        let sessionID = UUID()
        let book: LearningNotebook
        var queues: [LearningReviewQueue] = []
        var queue: LearningReviewQueue { queues.last! }
        var store: SessionStore { SessionStore(directory: directory) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-ReviewIdentity-\(UUID())")
            directory = root.appendingPathComponent("lesson")
            journal = root.appendingPathComponent("queue.json")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var notebook = LearningNotebook()
            for index in 0..<2 {
                let segment = TranscriptSegment(startTime: Double(index * 10), endTime: Double(index * 10 + 8),
                    english: "Sample \(index) has a temperature of 20 degrees Celsius.",
                    chinese: "第 \(index) 份样品的温度是 20 摄氏度。")
                try notebook.append(evidence: [segment], note: LearningNote(topic: "温度 \(index)",
                    points: [.init(kind: "核心结论", text: "第 \(index) 份样品的温度是 20 摄氏度。")]))
            }
            book = notebook
            var snapshot = SessionSnapshot(sessionID: sessionID,
                segments: notebook.batches.flatMap(\.evidence))
            notebook.writeState(to: &snapshot)
            _ = try store.save(snapshot)
            try (notebook.markdown() + "\n").write(to: directory.appendingPathComponent("summary-zh-Hans.md"),
                                                   atomically: true, encoding: .utf8)
            _ = makeQueue()
        }

        @discardableResult
        func makeQueue(generate: LearningReviewQueue.Generator? = nil) -> LearningReviewQueue {
            let queue = LearningReviewQueue(journalURL: journal, observeSleep: false, diagnostics: .disabled,
                generate: generate ?? { _, _, _, _ in ReviewIdentityScenarios.emptyResponse })
            queue.setContext(recording: true, concurrent: false, resourcesAvailable: false)
            queues.append(queue)
            return queue
        }

        func savedJournal() throws -> LearningReviewQueue.Journal {
            try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: journal))
        }

        func putJournal(_ value: LearningReviewQueue.Journal) throws {
            try JSONEncoder().encode(value).write(to: journal, options: .atomic)
        }

        func reviseFirst() throws -> SessionSnapshot {
            guard let saved = try store.load() else { throw Failure(description: "Missing synthetic snapshot") }
            let previous = saved.segments[0]
            let replacement = TranscriptSegment(id: previous.id, startTime: previous.startTime,
                endTime: previous.endTime, english: "Sample zero has a temperature of 30 degrees Celsius.",
                chinese: "第零份样品的温度是 30 摄氏度。", sessionID: sessionID,
                inputRevision: saved.inputRevision + 1)
            let retired = saved.batches.filter { $0.ids.contains(previous.id) }
            _ = try store.append(.inputRevision(.init(fromRevision: saved.inputRevision,
                toRevision: saved.inputRevision + 1, previousSegment: previous,
                replacementSegment: replacement, retainedBatches: retired, reason: "Synthetic confirmed revision")))
            let batch = LearningNoteBatch(id: UUID(), evidence: [replacement],
                note: LearningNote(topic: "修订后的温度", points: [.init(kind: "核心结论", text: "温度为 30 摄氏度。")]))
            let revised = try store.append(.appendBatch(batch))
            let notebook = try LearningNotebook(snapshot: revised)
            try (notebook.markdown() + "\n").write(to: directory.appendingPathComponent("summary-zh-Hans.md"),
                                                   atomically: true, encoding: .utf8)
            return revised
        }

        func entry(scope: LearningReviewScope = .wholeLesson, complete: Bool = true,
                   revision: Int = 0, text: String, jobID: UUID = UUID()) throws -> ReviewReportEntry {
            let selected = try ReviewInputBinding.selected(book.batches, scope: scope)
            return ReviewReportEntry(jobID: jobID,
                identity: try ReviewIdentity(sessionID: sessionID, scope: scope, inputRevision: revision,
                                             notebookRevision: book.revision),
                scope: scope, inputDigest: try ReviewInputBinding.digest(selected),
                completed: complete ? selected.count : 0, total: selected.count,
                supersededByRevision: nil, updatedAt: Date(timeIntervalSince1970: 100),
                fileName: scope.reportFileName, markdown: text)
        }

        func finish() async {
            for queue in queues { await queue.shutdownForTesting() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do { try await body(fixture) }
        catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    static func stableBatchIdentitySurvivesDisplayReordering() async throws {
        try await withFixture { fixture in
            let batch = fixture.book.batches[1]
            let first = LearningReviewScope.batch(2, id: batch.id)
            let relabeled = LearningReviewScope.batch(99, id: batch.id)
            let a = try ReviewIdentity(sessionID: fixture.sessionID, scope: first, inputRevision: 0)
            let b = try ReviewIdentity(sessionID: fixture.sessionID, scope: relabeled, inputRevision: 0)
            try check(a == b, "Display numbering must not be part of scope identity")
            try check(first.reportFileName == relabeled.reportFileName, "Report filename changed with display order")
            let selected = try ReviewInputBinding.selected(Array(fixture.book.batches.reversed()), scope: first)
            try check(selected == [batch], "Batch lookup used the stale display index")
        }
    }

    static func sameScopeDeduplicatesAndOtherScopesCoexist() async throws {
        try await withFixture { f in
            try f.queue.enqueue(directory: f.directory, notebook: f.book, sessionID: f.sessionID, inputRevision: 0)
            try f.queue.enqueue(directory: f.directory, notebook: f.book, scope: .batch(1))
            try f.queue.enqueue(directory: f.directory, notebook: f.book,
                scope: .batch(999, id: f.book.batches[0].id), sessionID: f.sessionID, inputRevision: 0)
            try check(f.queue.items.count == 2, "Same scope duplicated or another scope disappeared")
            let jobs = try f.savedJournal().jobs
            try check(jobs.allSatisfy { $0.identity?.sessionID == f.sessionID }, "Queue did not save session identity")
            try check(jobs.last?.resolvedScope.batchID == f.book.batches[0].id, "Local batch UUID was not frozen")
            try check(jobs.last?.resolvedScope.batchNumber == 1, "Stored label did not resolve from current order")
        }
    }

    static func copiedUUIDWithDifferentContentIsRejected() async throws {
        try await withFixture { f in
            try f.queue.enqueue(directory: f.directory, notebook: f.book)
            let other = f.root.appendingPathComponent("conflicting-copy")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            guard var snapshot = try f.store.load() else { throw Failure(description: "Missing fixture snapshot") }
            snapshot.batches[0].note.points[0].text = "不同内容，仍使用同一批次 ID。"
            snapshot.storageRevision = 0
            snapshot.lastJournalSequence = 0
            snapshot.lastJournalDigest = SessionArchiveCoding.genesisDigest
            _ = try SessionStore(directory: other).save(snapshot)
            let altered = try LearningNotebook(snapshot: snapshot)
            try rejects("Conflicting UUID copy was merged") {
                try f.queue.enqueue(directory: other, notebook: altered, scope: .batch(2))
            }
            try check(f.queue.items.count == 1, "Conflict changed the original queue")
        }
    }

    static func identicalContentInAnotherSessionStaysSeparate() async throws {
        try await withFixture { f in
            try f.queue.enqueue(directory: f.directory, notebook: f.book)
            let other = f.root.appendingPathComponent("other-lesson")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let otherID = UUID()
            var snapshot = SessionSnapshot(sessionID: otherID, segments: f.book.batches.flatMap(\.evidence))
            f.book.writeState(to: &snapshot)
            _ = try SessionStore(directory: other).save(snapshot)
            try f.queue.enqueue(directory: other, notebook: f.book, sessionID: otherID, inputRevision: 0)
            try check(f.queue.items.count == 2, "Two courses with the same wording were deduplicated")
            try rejects("Export accepted another course ID") {
                _ = try f.queue.collectedReviewReportMarkdown(for: f.directory, sessionID: otherID)
            }
        }
    }

    static func inputRevisionRetiresOnlyDependentPendingScopes() async throws {
        try await withFixture { f in
            try f.queue.enqueue(directory: f.directory, notebook: f.book)
            try f.queue.enqueue(directory: f.directory, notebook: f.book, scope: .batch(2))
            let oldID = f.queue.items[0].id
            let localID = f.queue.items[1].id
            let revised = try f.reviseFirst()
            try f.queue.invalidateInputs(sessionID: f.sessionID, inputRevision: 1,
                                         affectedBatchIDs: [f.book.batches[0].id])
            try check(f.queue.items.map(\.id) == [localID], "Unrelated local scope was lost")
            let saved = try f.savedJournal()
            try check(saved.retiredJobs?.first?.id == oldID, "Historical task identity was lost")
            try check(saved.retiredJobs?.first?.supersededByRevision == 1, "Retired task lacks revision marker")
            try check(saved.retiredJobs?.first?.prefix.isEmpty == true, "Stale unfinished prefix survived")
            let newBook = try LearningNotebook(snapshot: revised)
            try f.queue.enqueue(directory: f.directory, notebook: newBook, sessionID: f.sessionID, inputRevision: 1)
            try check(f.queue.items.count == 2, "New whole-course scope failed to coexist with valid local scope")
            let text = try f.queue.collectedReviewReportMarkdown(for: f.directory, sessionID: f.sessionID, inputRevision: 1)
            try check(text?.contains("历史版本") == true && text?.contains("输入版本 1") == true,
                      "Versioned export discarded history or omitted current input revision")
        }
    }

    static func migrationMovesEveryRangeAndKeepsPause() async throws {
        try await withFixture { f in
            f.queue.togglePause()
            try f.queue.enqueue(directory: f.directory, notebook: f.book)
            try f.queue.enqueue(directory: f.directory, notebook: f.book, scope: .batch(1))
            let before = try f.savedJournal()
            let moved = f.root.appendingPathComponent("moved")
            try FileManager.default.copyItem(at: f.directory, to: moved)
            f.queue.relocateJob(before.jobs[0].id, to: moved)
            try await until("Relocation did not update every scope") {
                f.queue.items.count == 2 && f.queue.items.allSatisfy {
                    $0.directory.standardizedFileURL == moved.standardizedFileURL
                }
            }
            let after = try f.savedJournal()
            try check(after.jobs.map(\.id) == before.jobs.map(\.id), "Relocation recreated queue jobs")
            try check(after.jobs.map(\.next) == before.jobs.map(\.next), "Relocation reset completed progress")
            try check(after.jobs.map(\.reports) == before.jobs.map(\.reports), "Relocation changed completed reports")
            try check(after.userPaused && f.queue.userPaused, "Relocation changed manual pause state")
            let wrong = f.root.appendingPathComponent("wrong")
            try FileManager.default.createDirectory(at: wrong, withIntermediateDirectories: true)
            _ = try SessionStore(directory: wrong).save(SessionSnapshot(sessionID: UUID(),
                segments: f.book.batches.flatMap(\.evidence), batches: f.book.batches))
            f.queue.relocateJob(after.jobs[0].id, to: wrong)
            try await until("Wrong-session relocation did not report a conflict") { f.queue.managementError != nil }
            try check(f.queue.items.allSatisfy { $0.directory.standardizedFileURL == moved.standardizedFileURL },
                      "Rejected migration partially moved the course")
        }
    }

    static func localOriginalIsValidatedAgainstItsBatch() async throws {
        try await withFixture { f in
            try f.queue.enqueue(directory: f.directory, notebook: f.book, scope: .batch(1))
            await f.queue.shutdownForTesting()
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: f.journal)) as! [String: Any]
            var jobs = json["jobs"] as! [[String: Any]]
            jobs[0]["original"] = "局部笔记原文，与整课 Markdown 不同。"
            json["jobs"] = jobs
            try JSONSerialization.data(withJSONObject: json).write(to: f.journal, options: .atomic)
            let queue = f.makeQueue()
            let moved = f.root.appendingPathComponent("local-moved")
            try FileManager.default.copyItem(at: f.directory, to: moved)
            guard let id = queue.items.first?.id else { throw Failure(description: "Local job failed to reload") }
            queue.relocateJob(id, to: moved)
            try await until("Local scope incorrectly compared its original with whole-course Markdown") {
                queue.items.first?.directory.standardizedFileURL == moved.standardizedFileURL
            }
            try check(queue.managementError == nil, "Local-scope migration failed")
        }
    }

    static func localProgressCannotHideFinishedWholeCourse() async throws {
        try await withFixture { f in
            let whole = try f.entry(text: "## 整课已完成意见\n完整的整课建议保留。")
            try ReviewReportCollection.save(whole, in: f.directory)
            try f.queue.enqueue(directory: f.directory, notebook: f.book, scope: .batch(1))
            let report = try f.queue.collectedReviewReportMarkdown(for: f.directory)
            try check(report?.contains("完整的整课建议保留") == true, "Pending local review hid a completed whole report")
            try check(report?.contains("第 1 批（局部）") == true, "Local scope disappeared from export")
            try check(report?.components(separatedBy: "完整的整课建议保留").count == 2, "Whole report was duplicated")
        }
    }

    static func finishedDiskRangeWinsOverAnUnfinishedRetry() async throws {
        try await withFixture { f in
            let whole = try f.entry(text: "## 完整结果\n这份报告已经完成。")
            try ReviewReportCollection.save(whole, in: f.directory)
            try f.queue.enqueue(directory: f.directory, notebook: f.book)
            let report = try f.queue.collectedReviewReportMarkdown(for: f.directory)
            try check(report?.contains("这份报告已经完成") == true, "An unfinished retry replaced a completed report")
            try check(report?.contains("0/2 批") == false, "Same range/version was exported twice")
        }
    }

    static func corruptLocalReportCannotHideBehindAnotherRange() async throws {
        try await withFixture { f in
            try f.queue.enqueue(directory: f.directory, notebook: f.book)
            let local = f.directory.appendingPathComponent("summary-review-batch-1.md")
            let corrupt = Data([0xFF, 0xFE, 0x80])
            try corrupt.write(to: local)
            try rejects("A corrupt local report was silently omitted") {
                _ = try f.queue.collectedReviewReportMarkdown(for: f.directory)
            }
            try check(try Data(contentsOf: local) == corrupt, "Read failure modified the corrupt report")
        }
    }

    static func damagedManifestIsVisibleAndPreserved() async throws {
        try await withFixture { f in
            try f.queue.enqueue(directory: f.directory, notebook: f.book)
            let file = f.directory.appendingPathComponent(ReviewReportCollection.manifestFileName)
            let damaged = Data("{\"version\":1,\"entries\":[".utf8)
            try damaged.write(to: file)
            try rejects("Damaged index was silently bypassed") {
                _ = try f.queue.collectedReviewReportMarkdown(for: f.directory)
            }
            try check(try Data(contentsOf: file) == damaged, "Damaged index was overwritten")
        }
    }

    static func legacyWholeAndLocalReportsRemainReadable() async throws {
        try await withFixture { f in
            try "旧整课意见\n".write(to: f.directory.appendingPathComponent("summary-review.md"),
                                    atomically: true, encoding: .utf8)
            try "旧局部意见\n".write(to: f.directory.appendingPathComponent("summary-review-batch-1.md"),
                                    atomically: true, encoding: .utf8)
            try f.queue.enqueue(directory: f.directory, notebook: f.book, scope: .batch(2))
            let report = try f.queue.collectedReviewReportMarkdown(for: f.directory)
            try check(report?.contains("旧整课意见") == true, "Legacy whole report was lost")
            try check(report?.contains("旧局部意见") == true, "Legacy local report was lost")
            try check(report?.contains("旧格式未记录输入版本") == true, "Legacy input revision was invented")
        }
    }

    static func manifestCommitSurvivesAnOlderLatestFile() async throws {
        try await withFixture { f in
            var record = try f.entry(complete: false, text: "已完成 0 批")
            try ReviewReportCollection.save(record, in: f.directory)
            let alias = f.directory.appendingPathComponent(record.fileName)
            let earlierAlias = try Data(contentsOf: alias)
            record.completed = record.total
            record.markdown = "已完成全部批次，包含真实保留的测试意见。"
            try ReviewReportCollection.save(record, in: f.directory)
            // Simulate termination after the authoritative manifest committed,
            // before the convenience latest-report file was refreshed.
            try earlierAlias.write(to: alias, options: .atomic)
            let output = try ReviewReportCollection.markdown(in: f.directory, queueReports: [])
            try check(output?.contains("已完成全部批次") == true, "A stale convenience file lost committed history")
            try "用户独立修改的另一份内容".write(to: alias, atomically: true, encoding: .utf8)
            try rejects("Unrecognized report changes were accepted as a valid older file") {
                _ = try ReviewReportCollection.markdown(in: f.directory, queueReports: [])
            }
        }
    }

    static func oldJournalKeepsStableIDsProgressPauseAndCompatiblePrefix() async throws {
        try await withFixture { f in
            await f.queue.shutdownForTesting()
            var legacy = LearningReviewQueue.Job(directory: f.directory, batches: f.book.batches,
                original: f.book.markdown(), next: 1, prefix: "compatible saved prefix", reports: ["已完成第一批"],
                scope: .wholeLesson)
            legacy.prefixInputDigest = LearningReviewQueue.prefixDigest(for: legacy)
            try f.putJournal(.init(jobs: [legacy], userPaused: true, version: 2))
            let restored = f.makeQueue()
            let saved = try f.savedJournal()
            try check(restored.userPaused, "Legacy manual pause was lost")
            try check(saved.jobs[0].id == legacy.id, "Legacy job ID was regenerated")
            try check(saved.jobs[0].batches.map(\.id) == legacy.batches.map(\.id), "Legacy batch IDs were regenerated")
            try check(saved.jobs[0].next == 1 && saved.jobs[0].reports == legacy.reports, "Completed progress was reset")
            try check(saved.jobs[0].prefix == legacy.prefix, "A compatible prefix was unnecessarily discarded")
            try check(saved.jobs[0].identity?.sessionID == f.sessionID, "Exact legacy evidence was not bound to the snapshot")
            try check(saved.jobs[0].prefixInputDigest == LearningReviewQueue.prefixDigest(for: saved.jobs[0]),
                      "Migrated prefix was not rebound to its proven identity")
        }
    }

    static func pausedPartialReviewRetainsCompletedAdviceAfterRevision() async throws {
        try await withFixture { f in
            await f.queue.shutdownForTesting()
            var calls = 0
            let queue = f.makeQueue { _, _, _, update in
                calls += 1
                if calls > 1 {
                    await update("unfinished prefix")
                    try await Task.sleep(for: .seconds(30))
                }
                return emptyResponse
            }
            try queue.enqueue(directory: f.directory, notebook: f.book)
            queue.setContext(recording: false, concurrent: true, resourcesAvailable: true)
            try await until("First batch did not complete") { queue.items.first?.completed == 1 && calls == 2 }
            _ = try f.reviseFirst()
            try queue.invalidateInputs(sessionID: f.sessionID, inputRevision: 1,
                                       affectedBatchIDs: [f.book.batches[0].id])
            try await until("Superseded generator did not stop") { !queue.running }
            let saved = try f.savedJournal()
            guard let retired = saved.retiredJobs?.first else { throw Failure(description: "Partial history was lost") }
            try check(retired.next == 1 && retired.reports.count == 1, "Completed advice was discarded with the unfinished prefix")
            try check(retired.prefix.isEmpty, "Invalidated prefix remained resumable")
            let report = try queue.collectedReviewReportMarkdown(for: f.directory, inputRevision: 1)
            try check(report?.contains("第 1 批") == true && report?.contains("历史版本") == true,
                      "Historical completed advice was omitted from export")
        }
    }

    static func prefixesBindSessionScopeAndInputRevision() async throws {
        try await withFixture { f in
            let digest = try ReviewInputBinding.digest(f.book.batches)
            var job = LearningReviewQueue.Job(directory: f.directory, batches: f.book.batches,
                original: f.book.markdown(), identity: try ReviewIdentity(sessionID: f.sessionID,
                    scope: .wholeLesson, inputRevision: 0), inputDigest: digest)
            let first = LearningReviewQueue.prefixDigest(for: job)
            job.identity = try ReviewIdentity(sessionID: UUID(), scope: .wholeLesson, inputRevision: 0)
            try check(first != LearningReviewQueue.prefixDigest(for: job), "Prefix was reusable across courses")
            job.identity = try ReviewIdentity(sessionID: f.sessionID, scope: .wholeLesson, inputRevision: 1)
            try check(first != LearningReviewQueue.prefixDigest(for: job), "Prefix was reusable across input revisions")
            let local = LearningReviewScope.batch(1, id: f.book.batches[0].id)
            job.identity = try ReviewIdentity(sessionID: f.sessionID, scope: local, inputRevision: 0)
            try check(first != LearningReviewQueue.prefixDigest(for: job), "Prefix was reusable across scopes")
        }
    }

    typealias Scenario = @MainActor () async throws -> Void
    static var all: [(String, Scenario)] { [
        ("stableBatchIdentitySurvivesDisplayReordering", stableBatchIdentitySurvivesDisplayReordering),
        ("sameScopeDeduplicatesAndOtherScopesCoexist", sameScopeDeduplicatesAndOtherScopesCoexist),
        ("copiedUUIDWithDifferentContentIsRejected", copiedUUIDWithDifferentContentIsRejected),
        ("identicalContentInAnotherSessionStaysSeparate", identicalContentInAnotherSessionStaysSeparate),
        ("inputRevisionRetiresOnlyDependentPendingScopes", inputRevisionRetiresOnlyDependentPendingScopes),
        ("migrationMovesEveryRangeAndKeepsPause", migrationMovesEveryRangeAndKeepsPause),
        ("localOriginalIsValidatedAgainstItsBatch", localOriginalIsValidatedAgainstItsBatch),
        ("localProgressCannotHideFinishedWholeCourse", localProgressCannotHideFinishedWholeCourse),
        ("finishedDiskRangeWinsOverAnUnfinishedRetry", finishedDiskRangeWinsOverAnUnfinishedRetry),
        ("corruptLocalReportCannotHideBehindAnotherRange", corruptLocalReportCannotHideBehindAnotherRange),
        ("damagedManifestIsVisibleAndPreserved", damagedManifestIsVisibleAndPreserved),
        ("legacyWholeAndLocalReportsRemainReadable", legacyWholeAndLocalReportsRemainReadable),
        ("manifestCommitSurvivesAnOlderLatestFile", manifestCommitSurvivesAnOlderLatestFile),
        ("oldJournalKeepsStableIDsProgressPauseAndCompatiblePrefix", oldJournalKeepsStableIDsProgressPauseAndCompatiblePrefix),
        ("pausedPartialReviewRetainsCompletedAdviceAfterRevision", pausedPartialReviewRetainsCompletedAdviceAfterRevision),
        ("prefixesBindSessionScopeAndInputRevision", prefixesBindSessionScopeAndInputRevision)
    ] }
}

#if !REVIEW_IDENTITY_STANDALONE
@MainActor
struct ReviewIdentityTests {
    @Test func legacyNotebookRestoresOriginalSourcesWithoutChangingReviewProgress() async throws {
        try await ReviewIdentityScenarios.withFixture { f in
            await f.queue.shutdownForTesting()
            let job = LearningReviewQueue.Job(directory: f.directory, batches: f.book.batches,
                original: f.book.markdown(), next: 1, reports: ["已完成第一批"], scope: .wholeLesson)
            try f.putJournal(.init(jobs: [job], userPaused: true, version: 2))
            let queue = f.makeQueue()
            let before = try Data(contentsOf: f.journal)
            let legacy = SessionSnapshot(sessionID: f.sessionID, segments: f.book.batches.flatMap(\.evidence),
                                         legacyMarkdown: f.book.markdown())
            let restoredJournal = try f.savedJournal()
            let restoredJob = try #require(restoredJournal.jobs.first)
            #expect(restoredJob.resolvedScope.isWholeLesson)
            #expect(!restoredJob.batches.isEmpty)
            #expect(restoredJob.original == legacy.legacyMarkdown)
            #expect(SessionDirectoryLocation.canonical(restoredJob.directory)
                == SessionDirectoryLocation.canonical(f.directory))
            let result = try queue.restorableLegacyNotebook(for: f.directory, snapshot: legacy)
            let recovered = try #require(result)
            #expect(recovered.batches == f.book.batches)
            #expect(recovered.latestEvidenceIDs == f.book.batches.last?.ids)
            #expect(queue.userPaused)
            #expect(try Data(contentsOf: f.journal) == before)
            let saved = try f.savedJournal()
            #expect(saved.jobs.first?.next == 1)
            #expect(saved.jobs.first?.reports == ["已完成第一批"])
            var changed = legacy
            changed.segments[0].completeTranslation("已修订的温度为 30 摄氏度。")
            #expect(throws: ReviewIdentityError.self) {
                try queue.restorableLegacyNotebook(for: f.directory, snapshot: changed)
            }
            #expect(try Data(contentsOf: f.journal) == before)
        }
    }

    @Test func courseMigrationWaitsForCancelledWriterAndResumesAtNewLocation() async throws {
        try await ReviewIdentityScenarios.withFixture { f in
            await f.queue.shutdownForTesting()
            var calls = 0
            var writerStopped = false
            let marker = f.directory.appendingPathComponent("writer-finished.txt")
            let queue = f.makeQueue { _, _, _, _ in
                calls += 1
                if calls == 1 {
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch {
                        // Real cleanup can outlive cancellation of the model
                        // request. The migration must await this boundary.
                        try await Task.detached {
                            try await Task.sleep(for: .milliseconds(50))
                            try Data("writer finished".utf8).write(to: marker)
                        }.value
                        writerStopped = true
                        throw error
                    }
                }
                return ReviewIdentityScenarios.emptyResponse
            }
            try queue.enqueue(directory: f.directory, notebook: f.book)
            queue.setContext(recording: false, concurrent: true, resourcesAvailable: true)
            try await ReviewIdentityScenarios.until("Generator did not start") { calls == 1 }
            let loaded = try f.store.load()
            let snapshot = try #require(loaded)
            let oldWriter = SessionArchiveWriter(directory: f.directory, restored: snapshot)
            let target = f.root.appendingPathComponent("moved-course")
            let receipt = try await queue.withCourseWritersPaused(sessionID: f.sessionID, directory: f.directory) {
                #expect(writerStopped)
                let copied = try SessionTreeMigration.copyVerified(from: f.directory, to: target)
                try queue.relocatePausedCourse(sessionID: f.sessionID, from: f.directory, to: target)
                return try SessionTreeMigration.retireVerifiedCopy(copied)
            }
            #expect(receipt.preservedSourceDirectory != nil)
            #expect(!FileManager.default.fileExists(atPath: f.directory.path))
            #expect(try String(contentsOf: target.appendingPathComponent("writer-finished.txt"), encoding: .utf8) == "writer finished")
            do {
                _ = try await oldWriter.commit(snapshot)
                Issue.record("A late saver recreated the retired course")
            } catch {}
            try await ReviewIdentityScenarios.until("Review did not finish at its new directory") { !queue.hasWork && !queue.running }
            #expect(try ReviewExportSource.markdown(for: target, queue: queue)?.contains("第 2 批") == true)
            #expect(!FileManager.default.fileExists(atPath: f.directory.path))
            #expect(!queue.userPaused)
        }
    }

    @Test func rejectedRetirementRollsQueueBackAndKeepsBothTrees() async throws {
        try await ReviewIdentityScenarios.withFixture { f in
            f.queue.togglePause()
            try f.queue.enqueue(directory: f.directory, notebook: f.book)
            try f.queue.enqueue(directory: f.directory, notebook: f.book, scope: .batch(1))
            let before = try f.savedJournal()
            let target = f.root.appendingPathComponent("failed-move")
            do {
                _ = try await f.queue.withCourseWritersPaused(sessionID: f.sessionID, directory: f.directory) {
                    let copied = try SessionTreeMigration.copyVerified(from: f.directory, to: target)
                    try f.queue.relocatePausedCourse(sessionID: f.sessionID, from: f.directory, to: target)
                    try Data("unexpected write".utf8).write(to: target.appendingPathComponent("late.txt"))
                    do { return try SessionTreeMigration.retireVerifiedCopy(copied) }
                    catch {
                        try f.queue.relocatePausedCourse(sessionID: f.sessionID, from: target, to: f.directory)
                        throw error
                    }
                }
                Issue.record("Changed destination was accepted")
            } catch is SessionMigrationError {}
            let after = try f.savedJournal()
            #expect(after.jobs.map(\.id) == before.jobs.map(\.id))
            #expect(after.jobs.map(\.directory) == before.jobs.map(\.directory))
            #expect(after.userPaused)
            #expect(FileManager.default.fileExists(atPath: f.directory.path))
            #expect(FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func appendedNotesPreserveFrozenReviewAndAllowANewScope() async throws {
        try await ReviewIdentityScenarios.withFixture { f in
            try f.queue.enqueue(directory: f.directory, notebook: f.book)
            var grown = f.book
            let evidence = TranscriptSegment(startTime: 20, endTime: 28,
                english: "The next sample has a temperature of 40 degrees Celsius.",
                chinese: "下一份样品的温度是 40 摄氏度。")
            try grown.append(evidence: [evidence], note: .init(topic: "新增样品", points: [
                .init(kind: "核心结论", text: "下一份样品温度为 40 摄氏度。", sourceIDs: ["en0s0"])
            ], sourceVersion: 2))
            var snapshot = try #require(try f.store.load())
            snapshot.segments.append(evidence)
            grown.writeState(to: &snapshot)
            _ = try f.store.save(snapshot)
            try f.queue.enqueue(directory: f.directory, notebook: grown,
                scope: .batch(3, id: grown.batches[2].id))
            #expect(f.queue.items.count == 2)
            let reports = try #require(try f.queue.collectedReviewReportMarkdown(for: f.directory))
            #expect(reports.contains("笔记版本 2"))
            #expect(reports.contains("笔记版本 3"))
            try f.queue.enqueue(directory: f.directory, notebook: grown)
            #expect(f.queue.items.count == 2)
            let saved = try f.savedJournal()
            #expect(saved.retiredJobs?.count == 1)
            #expect(saved.retiredJobs?.first?.identity?.notebookRevision == 2)
            #expect(saved.jobs.first(where: { $0.resolvedScope.isWholeLesson })?.identity?.notebookRevision == 3)
        }
    }
    @Test func stableBatchIdentity() async throws { try await ReviewIdentityScenarios.stableBatchIdentitySurvivesDisplayReordering() }
    @Test func scopeDeduplication() async throws { try await ReviewIdentityScenarios.sameScopeDeduplicatesAndOtherScopesCoexist() }
    @Test func conflictingCopies() async throws { try await ReviewIdentityScenarios.copiedUUIDWithDifferentContentIsRejected() }
    @Test func separateCourses() async throws { try await ReviewIdentityScenarios.identicalContentInAnotherSessionStaysSeparate() }
    @Test func relatedInputInvalidation() async throws { try await ReviewIdentityScenarios.inputRevisionRetiresOnlyDependentPendingScopes() }
    @Test func allRangeMigration() async throws { try await ReviewIdentityScenarios.migrationMovesEveryRangeAndKeepsPause() }
    @Test func localMigrationValidation() async throws { try await ReviewIdentityScenarios.localOriginalIsValidatedAgainstItsBatch() }
    @Test func aggregateWholeAndLocal() async throws { try await ReviewIdentityScenarios.localProgressCannotHideFinishedWholeCourse() }
    @Test func completedRangePreservation() async throws { try await ReviewIdentityScenarios.finishedDiskRangeWinsOverAnUnfinishedRetry() }
    @Test func corruptLocalReport() async throws { try await ReviewIdentityScenarios.corruptLocalReportCannotHideBehindAnotherRange() }
    @Test func corruptManifest() async throws { try await ReviewIdentityScenarios.damagedManifestIsVisibleAndPreserved() }
    @Test func legacyReports() async throws { try await ReviewIdentityScenarios.legacyWholeAndLocalReportsRemainReadable() }
    @Test func interruptedAliasWrite() async throws { try await ReviewIdentityScenarios.manifestCommitSurvivesAnOlderLatestFile() }
    @Test func oldQueueMigration() async throws { try await ReviewIdentityScenarios.oldJournalKeepsStableIDsProgressPauseAndCompatiblePrefix() }
    @Test func partialReviewHistory() async throws { try await ReviewIdentityScenarios.pausedPartialReviewRetainsCompletedAdviceAfterRevision() }
    @Test func prefixIdentityBinding() async throws { try await ReviewIdentityScenarios.prefixesBindSessionScopeAndInputRevision() }
}
#endif
