import Foundation
import Testing
@testable import LiveLingo

@MainActor
@Suite(.isolatedStorage)
struct TargetPersistenceTests {
    // Generated from dd-tl567/baseline-code/SessionArchive.swift's original
    // declarations and encoder, not from the new SessionSnapshot encoder.
    // The specimen has empty collections and fixed UUID/date values.
    private static let oldSnapshotJSON = #"{"audioFiles":[],"audioRanges":[],"batches":[],"createdAt":1000000,"generation":0,"generationCheckpoints":[],"inputRevision":0,"lastJournalDigest":"0000000000000000000000000000000000000000000000000000000000000000","lastJournalSequence":0,"latestEvidenceIDs":[],"notebookLastOffered":{},"notebookRevision":0,"notebookSelectionRound":0,"processing":{"paused":false,"pendingBatchIDs":[],"pendingSegmentIDs":[],"phase":"idle","reviewPaused":true,"summaryPaused":false},"revisionHistory":[],"schemaVersion":1,"segments":[],"sessionID":"00000000-0000-0000-0000-000000000001","storageRevision":0,"updatedAt":1000000}"#
    private static let oldSnapshotChecksum = "c77258bf60e0cc3aeea88c2f506921dc696d01d025211d9f3cc58b5fd0427bb9"
    private static let oldInputFingerprint = "a96b86b92372d998c1ba784e75db02eba082d9bce97a9066335ff47576d39682"
    // Generated with the original baseline-code Job declaration. Its prompt
    // is deliberately synthetic, so a Codable round trip must retain it.
    private static let oldJobJSON = #"{"batches":[],"directory":"file:\/\/\/synthetic\/target-persistence\/course\/","id":"00000000-0000-0000-0000-000000000002","next":0,"original":"synthetic original","prefix":"","prompt":"frozen-review-placeholder","reports":[]}"#

    private func baselineSnapshot() throws -> SessionSnapshot {
        try SessionArchiveCoding.decode(SessionSnapshot.self, from: Data(Self.oldSnapshotJSON.utf8))
    }

    @Test func defaultSnapshotPreservesOldBytesChecksumAndFingerprint() throws {
        let bytes = Data(Self.oldSnapshotJSON.utf8)
        let decoded = try baselineSnapshot()
        #expect(decoded.targetLocale == nil)
        #expect(decoded.effectiveTargetLocale == "zh-Hans")
        try decoded.validate()
        #expect(try SessionArchiveCoding.encode(decoded) == bytes)
        #expect(SessionArchiveCoding.digest(bytes) == Self.oldSnapshotChecksum)
        #expect(try decoded.inputFingerprint() == Self.oldInputFingerprint)
        let fresh = SessionSnapshot(sessionID: decoded.sessionID, createdAt: decoded.createdAt)
        #expect(try SessionArchiveCoding.encode(fresh) == bytes)
        #expect(try fresh.inputFingerprint() == Self.oldInputFingerprint)
    }

    @Test func knownUnreleasedTargetsRoundTripAndBindInput() throws {
        let original = try baselineSnapshot()
        for locale in ["zh-Hant-TW", "zh-Hant-HK", "en", "es", "fr"] {
            var snapshot = original
            snapshot.targetLocale = locale
            try snapshot.validate()
            let bytes = try SessionArchiveCoding.encode(snapshot)
            let loaded = try SessionArchiveCoding.decode(SessionSnapshot.self, from: bytes)
            #expect(loaded == snapshot)
            #expect(loaded.targetLocale == locale)
            #expect(try loaded.inputFingerprint() != Self.oldInputFingerprint)
            try SessionStore.validatePreservation(from: snapshot, to: loaded)
        }
        var unknown = original
        unknown.targetLocale = "not-a-target"
        #expect(throws: SessionStoreError.self) { try unknown.validate() }
    }

    @Test func preservationRejectsTargetChangesDespiteNewRevision() throws {
        let original = try baselineSnapshot()
        var changed = original
        changed.targetLocale = "en"
        changed.inputRevision += 1
        #expect(throws: SessionStoreError.self) {
            try SessionStore.validatePreservation(from: original, to: changed)
        }
        var english = original
        english.targetLocale = "en"
        var french = english
        french.targetLocale = "fr"
        #expect(throws: SessionStoreError.self) {
            try SessionStore.validatePreservation(from: english, to: french)
        }
    }

    @Test func explicitSimplifiedChineseIsEquivalentToMissingTarget() throws {
        let original = try baselineSnapshot()
        var explicit = original
        explicit.targetLocale = "zh-Hans"
        try explicit.validate()
        try SessionStore.validatePreservation(from: original, to: explicit)
        try SessionStore.validatePreservation(from: explicit, to: original)
        #expect(try explicit.inputFingerprint() == Self.oldInputFingerprint)
        let stamped = SessionSnapshot(sessionID: original.sessionID, createdAt: original.createdAt,
            targetLocale: "zh-Hans")
        #expect(stamped.targetLocale == nil)
        #expect(try SessionArchiveCoding.encode(stamped) == Data(Self.oldSnapshotJSON.utf8))
    }

    @Test func oldJobOmitsNilTargetAndRetainsItsPromptBytes() throws {
        let bytes = Data(Self.oldJobJSON.utf8)
        var job = try JSONDecoder().decode(LearningReviewQueue.Job.self, from: bytes)
        #expect(job.targetLocale == nil)
        #expect(job.prompt == "frozen-review-placeholder")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(job) == bytes)
        job.targetLocale = "en"
        let loaded = try JSONDecoder().decode(LearningReviewQueue.Job.self, from: encoder.encode(job))
        #expect(loaded.targetLocale == "en")
        #expect(loaded.prompt == job.prompt)
    }

    @Test func reviewTargetResolutionUsesOnlyTheSuppliedSnapshot() throws {
        var snapshot = try baselineSnapshot()
        snapshot.targetLocale = "en"
        #expect(try LearningReviewQueue.resolvedTargetLocale(nil, snapshot: snapshot) == "en")
        #expect(throws: ReviewIdentityError.self) {
            _ = try LearningReviewQueue.resolvedTargetLocale("fr", snapshot: snapshot)
        }
        #expect(throws: ReviewIdentityError.self) {
            try LearningReviewQueue.validateTargetLocale(nil, snapshot: snapshot)
        }
        #expect(try LearningReviewQueue.resolvedTargetLocale(nil, snapshot: nil) == nil)
        #expect(LearningReviewQueue.reviewPrompt(for: nil) == LearningPrompts.review)
        #expect(LearningReviewQueue.reviewPrompt(for: "zh-Hant-TW") == LearningPrompts.review)
        #expect(LearningReviewQueue.reviewPrompt(for: "zh-Hant-HK") == LearningPrompts.review)
        for locale in ["en", "es", "fr", "unknown"] {
            #expect(LearningReviewQueue.reviewPrompt(for: locale) == nil)
        }
        let originalBinding = LearningReviewQueue.prefixDigest(json: "synthetic input", prompt: LearningPrompts.review)
        #expect(originalBinding == LearningReviewQueue.prefixDigest(json: "synthetic input",
            prompt: LearningPrompts.review, targetLocale: "zh-Hans"))
        #expect(originalBinding != LearningReviewQueue.prefixDigest(json: "synthetic input",
            prompt: LearningPrompts.review, targetLocale: "zh-Hant-TW"))
    }

    private struct Fixture {
        let root: URL
        init() throws {
            // Every test write stays under dd-tl567, including after integration.
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("TargetPersistence-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
        var directory: URL { root.appendingPathComponent("course", isDirectory: true) }
        var journal: URL { root.appendingPathComponent("queue.json") }
    }

    private func oldJobObject() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(Self.oldJobJSON.utf8)) as? [String: Any])
    }
    private func writeV3Journal(_ job: [String: Any], to url: URL) throws {
        let root: [String: Any] = ["jobs": [job], "userPaused": true, "version": 3]
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: url)
    }
    private func readJournal(_ url: URL) throws -> LearningReviewQueue.Journal {
        try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: url))
    }
    private func pausedQueue(_ url: URL) -> LearningReviewQueue {
        LearningReviewQueue(journalURL: url, observeSleep: false, diagnostics: .disabled,
            generate: { _, _, _, _, _ in
                Issue.record("Pure persistence tests must never invoke generation")
                throw CancellationError()
            })
    }

    @Test func oldV3JournalKeepsFrozenChineseReviewPrompt() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        var oldJob = try oldJobObject()
        oldJob["directory"] = fixture.directory.absoluteString
        oldJob["prompt"] = LearningPrompts.review
        try writeV3Journal(oldJob, to: fixture.journal)
        let queue = pausedQueue(fixture.journal)
        await queue.shutdownForTesting()
        let journal = try readJournal(fixture.journal)
        let job = try #require(journal.jobs.first)
        #expect(journal.version == 3)
        #expect(journal.userPaused)
        #expect(job.targetLocale == nil)
        #expect(job.prompt == LearningPrompts.review)
        #expect(SessionArchiveCoding.digest(Data((job.prompt ?? "").utf8))
            == "ab5bce580c7f4ba53cb7ac419e51dbfdcf1517315e0869cc16272ae8fd916fcd")
    }

    @Test func oldNilTargetInheritsItsCourseAndPreservesUnsupportedPrompt() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let segment = TranscriptSegment(startTime: 0, endTime: 1,
            english: "Heat increases.", chinese: "Heat increases.")
        let batch = LearningNoteBatch(id: UUID(), evidence: [segment], note: LearningNote(topic: "Heat", points: [
            .init(kind: "核心结论", text: "Heat increases.")
        ]))
        _ = try SessionStore(directory: fixture.directory).save(SessionSnapshot(
            segments: [segment], batches: [batch], createdAt: Date(timeIntervalSince1970: 1_000), targetLocale: "en"))
        var oldJob = try oldJobObject()
        oldJob["directory"] = fixture.directory.absoluteString
        oldJob["batches"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([batch]))
        oldJob["prompt"] = "English review instructions preserved verbatim."
        oldJob["prefix"] = "unfinished English prefix"
        let digest = SessionArchiveCoding.digest(Data("original English input binding".utf8))
        oldJob["prefixInputDigest"] = digest
        try writeV3Journal(oldJob, to: fixture.journal)
        let queue = pausedQueue(fixture.journal)
        await queue.shutdownForTesting()
        let job = try #require(try readJournal(fixture.journal).jobs.first)
        #expect(job.targetLocale == "en")
        #expect(job.prompt == "English review instructions preserved verbatim.")
        #expect(job.prefix == "unfinished English prefix")
        #expect(job.prefixInputDigest == digest)
        #expect(job.failure?.contains("尚无复查提示词") == true)
    }
}
