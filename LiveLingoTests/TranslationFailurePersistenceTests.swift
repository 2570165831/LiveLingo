import Foundation
import XCTest
@testable import LiveLingo

@MainActor
final class TranslationFailurePersistenceTests: XCTestCase {
    private typealias Segment = TranscriptSegment
    private typealias Reason = Segment.TranslationFailureReason
    private typealias Failure = Segment.TranslationFailure

    private let sessionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let batchID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func segment(trail: Bool) throws -> Segment {
        try JSONDecoder().decode(Segment.self,
            from: Data((trail ? FrozenTranslationPersistence.trailSegment : FrozenTranslationPersistence.segment).utf8))
    }

    private func batches(trail: Bool) throws -> [LearningNoteBatch] {
        var result = try JSONDecoder().decode([LearningNoteBatch].self,
            from: Data("[\(FrozenTranslationPersistence.firstBatch),\(FrozenTranslationPersistence.secondBatch)]".utf8))
        if trail {
            result[0] = LearningNoteBatch(id: result[0].id, evidence: [try segment(trail: true)],
                                         note: result[0].note, followUps: result[0].followUps)
            var second = result[1].evidence[0]
            second.recordTranslationFailure(.requestTimedOut)
            result[1] = LearningNoteBatch(id: result[1].id, evidence: [second], note: result[1].note)
        }
        return result
    }

    private func journal(trail: Bool) throws -> LearningReviewQueue.Journal {
        let course = try batches(trail: trail)
        var job = LearningReviewQueue.Job(directory: URL(string: "file:///lesson/")!,
            batches: [course[0]], original: "Fixed original", prompt: nil,
            scope: .batch(1, id: batchID), awaitingManualStart: true,
            identity: try ReviewIdentity(sessionID: sessionID, scope: .batch(1, id: batchID),
                                         inputRevision: 2, notebookRevision: 2),
            inputDigest: try ReviewInputBinding.digest([course[0]]),
            courseInputDigest: try ReviewInputBinding.digest(course),
            courseBatchDigests: try Dictionary(uniqueKeysWithValues: course.map {
                ($0.id.uuidString, try ReviewInputBinding.digest([$0]))
            }))
        job.id = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        return .init(jobs: [job], userPaused: true, version: 3)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingo-TranslationPersistence-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func decodeDiagnostic(_ diagnostic: Any) throws -> Segment {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(FrozenTranslationPersistence.segment.utf8)) as? [String: Any])
        object["translationFailures"] = diagnostic
        return try JSONDecoder().decode(Segment.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private var mixedDiagnostics: [Any] {
        [
            ["reason": "processExited", "count": 2],
            ["reason": "requestTimedOut", "count": 0],
            ["reason": "requestFailed", "count": -1],
            ["reason": "requestFailed", "count": true],
            ["reason": "requestFailed", "count": 1.5],
            ["reason": "requestFailed", "count": "PRIVATE_BAD_COUNT"],
            ["reason": "requestFailed"],
            ["count": 7],
            ["reason": false, "count": 7],
            NSNull(), "PRIVATE_BAD_ENTRY", 7, [],
            ["reason": "FUTURE_PRIVATE_REASON", "count": 3],
            ["reason": "requestTimedOut", "count": 4],
            ["reason": "processExited", "count": 1],
            ["reason": "unknown", "count": 2]
        ]
    }

    func testPersistedReasonStringsAndRecordJSONAreFrozenLiterals() throws {
        let reasons = #"["processExited","requestTimedOut","outputLimitReached","translationRejected","cancelled","interrupted","runtimeUnavailable","invalidResponse","generationInterrupted","requestFailed","unknown","dependencyCancelled"]"#
        XCTAssertEqual(try encode(Reason.allCases), Data(reasons.utf8))
        XCTAssertEqual(try encode(Failure(reason: .dependencyCancelled, count: 2)),
                       Data(#"{"count":2,"reason":"dependencyCancelled"}"#.utf8))
        XCTAssertEqual(Reason.category(for: CancellationError()), .dependencyCancelled)
        XCTAssertEqual(Reason.category(for: URLError(.cancelled)), .dependencyCancelled)

        var value = try segment(trail: false)
        value.recordTranslationFailure(.processExited)
        value.recordTranslationFailure(.processExited)
        value.recordTranslationFailure(.dependencyCancelled)
        XCTAssertEqual(try encode(value), Data(FrozenTranslationPersistence.trailSegment.utf8))
        XCTAssertEqual(try JSONDecoder().decode(Segment.self, from: encode(value)), value)

        let oldReasons = try decodeDiagnostic([
            ["reason": "cancelled", "count": 1], ["reason": "interrupted", "count": 2]
        ])
        XCTAssertEqual(oldReasons.translationFailures,
                       [.init(reason: .cancelled, count: 1), .init(reason: .interrupted, count: 2)])
    }

    func testNormalSegmentAnd020RoundTripMatchFrozenBytes() throws {
        XCTAssertEqual(try encode(segment(trail: false)), Data(FrozenTranslationPersistence.segment.utf8))
        let legacy = try JSONDecoder().decode(TranslationPersistenceLegacy020.TranscriptSegment.self,
            from: Data(FrozenTranslationPersistence.trailSegment.utf8))
        XCTAssertEqual(try encode(legacy), Data(FrozenTranslationPersistence.segment.utf8))
        XCTAssertEqual(try JSONDecoder().decode(Segment.self, from: encode(legacy)), try segment(trail: false))
    }

    func testMalformedDiagnosticKeyDegradesWithoutLosingCourseContent() throws {
        for invalid in [NSNull(), false, 7, "PRIVATE_BAD_KEY", ["reason": "unknown", "count": 1]] as [Any] {
            let decoded = try decodeDiagnostic(invalid)
            XCTAssertEqual(decoded, try segment(trail: false))
            XCTAssertEqual(try encode(decoded), Data(FrozenTranslationPersistence.segment.utf8))
        }
    }

    func testBadDiagnosticEntriesAreSkippedAndGoodNeighboursSurvive() throws {
        let decoded = try decodeDiagnostic(mixedDiagnostics)
        XCTAssertEqual(decoded.translationFailures, [
            .init(reason: .requestTimedOut, count: 4), .init(reason: .processExited, count: 3),
            .init(reason: .unknown, count: 5)
        ])
        XCTAssertEqual(decoded.withoutTranslationFailures, try segment(trail: false))
        let rewritten = String(decoding: try encode(decoded), as: UTF8.self)
        XCTAssertFalse(rewritten.contains("PRIVATE"))
        XCTAssertFalse(rewritten.contains("FUTURE"))

        var saturated = try decodeDiagnostic([
            ["reason": "unknown", "count": Int.max], ["reason": "unknown", "count": 1]
        ])
        saturated.recordTranslationFailure(.unknown)
        XCTAssertEqual(saturated.translationFailures, [.init(reason: .unknown, count: Int.max)])
    }

    func testCoreSegmentCorruptionStillFailsEvenWithOptionalDiagnostics() throws {
        for (key, invalid) in [("id", false), ("english", 7), ("startTime", -1)] as [(String, Any)] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(FrozenTranslationPersistence.trailSegment.utf8)) as? [String: Any])
            object[key] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(Segment.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testCourseStoreLoadsAndRewritesPartlyDamagedOptionalDiagnostics() throws {
        let root = try directory()
        let snapshot = SessionSnapshot(sessionID: sessionID, inputRevision: 2,
            segments: [try segment(trail: false)], createdAt: Date(timeIntervalSince1970: 100))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: SessionArchiveCoding.encode(snapshot)) as? [String: Any])
        var evidence = try XCTUnwrap(object["segments"] as? [[String: Any]])
        evidence[0]["translationFailures"] = mixedDiagnostics
        object["segments"] = evidence
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        struct Envelope: Encodable { let schemaVersion: Int; let payload: Data; let checksum: String }
        let envelope = Envelope(schemaVersion: 1, payload: payload, checksum: SessionArchiveCoding.digest(payload))
        try SessionArchiveCoding.encode(envelope).write(to: root.appendingPathComponent(SessionStore.snapshotFileName))

        let store = SessionStore(directory: root)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.segments[0].translationFailures, try decodeDiagnostic(mixedDiagnostics).translationFailures)
        XCTAssertEqual(loaded.segments[0].withoutTranslationFailures, snapshot.segments[0])
        let saved = try store.save(loaded)
        XCTAssertEqual(try store.load(), saved)
    }

    func testDirectBatchCopiesAndBatchDecodingExcludeTrailsAtBothBoundaries() throws {
        let plain = try batches(trail: false)
        let recovered = try batches(trail: true)
        XCTAssertEqual(recovered, plain)
        XCTAssertTrue(recovered.flatMap(\.evidence).allSatisfy { $0.translationFailures.isEmpty })
        XCTAssertEqual(try encode(recovered[0]), Data(FrozenTranslationPersistence.firstBatch.utf8))
        XCTAssertEqual(try encode(recovered[1]), Data(FrozenTranslationPersistence.secondBatch.utf8))
        XCTAssertEqual(try encode(recovered), try encode(plain))
        XCTAssertFalse(try segment(trail: true).translationFailures.isEmpty)

        for trail in [mixedDiagnostics, "PRIVATE_BAD_KEY"] as [Any] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(FrozenTranslationPersistence.firstBatch.utf8)) as? [String: Any])
            var evidence = try XCTUnwrap(object["evidence"] as? [[String: Any]])
            evidence[0]["translationFailures"] = trail
            object["evidence"] = evidence
            let decoded = try JSONDecoder().decode(LearningNoteBatch.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded, plain[0])
            XCTAssertEqual(try encode(decoded), Data(FrozenTranslationPersistence.firstBatch.utf8))
        }

        var withFollowUps = plain[0]
        withFollowUps.followUps = [.init(state: .missing, detail: "稍后核对")]
        let legacy = try JSONDecoder().decode(TranslationPersistenceLegacy020.LearningNoteBatch.self,
                                              from: encode(withFollowUps))
        XCTAssertEqual(try encode(legacy), try encode(withFollowUps))
    }

    func testProjectionPreservesLanguageIdentityAndTranslationState() throws {
        var value = Segment(id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            startTime: 7, endTime: 8, english: "Il fait froid.", chinese: "很冷。",
            sessionID: sessionID, inputRevision: 2, sourceLanguage: "fr")
        let before = value
        value.recordTranslationFailure(.processExited)
        XCTAssertEqual(value.withoutTranslationFailures, before)
        XCTAssertTrue(value.withoutTranslationFailures.hasExplicitSourceLanguage)
        XCTAssertEqual(try encode(value.withoutTranslationFailures), try encode(before))

        let inferredJSON = #"{"chinese":"房间很冷。","endTime":3,"english":"房间很冷。","id":"11111111-1111-1111-1111-111111111111","startTime":1,"translationState":"completed","translationFailures":[{"count":1,"reason":"processExited"}]}"#
        let inferred = try JSONDecoder().decode(Segment.self, from: Data(inferredJSON.utf8))
        XCTAssertEqual(inferred.withoutTranslationFailures.sourceLanguage, "zh")
        XCTAssertFalse(inferred.withoutTranslationFailures.hasExplicitSourceLanguage)
        XCTAssertFalse(String(decoding: try encode(inferred.withoutTranslationFailures), as: UTF8.self).contains("sourceLanguage"))
    }

    func testDraftAndReviewWireInputIgnoreOnlyDiagnostics() throws {
        let plain = try segment(trail: false)
        var recovered = try segment(trail: true)
        let input = try LearningPrompts.input(evidence: [recovered], topics: [])
        XCTAssertEqual(input, FrozenTranslationPersistence.generateInput)
        XCTAssertEqual(input, try LearningPrompts.input(evidence: [plain], topics: []))
        var draft = LearningDraft(evidence: [recovered], model: "fixed-model", input: input)
        XCTAssertEqual(draft.evidence, [plain])
        recovered.recordTranslationFailure(.requestTimedOut)
        XCTAssertTrue(draft.matches(evidence: [recovered], model: "fixed-model"))
        draft.freezeBinding(sessionID: sessionID, inputRevision: 2, generation: 1)
        let checkpoint = draft.checkpoint(sessionID: sessionID, inputRevision: 2, generation: 1)
        let snapshot = SessionSnapshot(sessionID: sessionID, inputRevision: 2, segments: [recovered], generation: 1)
        XCTAssertTrue(draft.matches(snapshot: snapshot, model: "fixed-model"))
        let restored = try XCTUnwrap(LearningDraft(checkpoint: checkpoint, snapshot: snapshot, model: "fixed-model"))
        XCTAssertEqual(restored.evidence, [plain])
        XCTAssertTrue(restored.matches(evidence: [recovered], model: "fixed-model"))
        XCTAssertEqual(restored.checkpoint(sessionID: sessionID, inputRevision: 2, generation: 1), checkpoint)
        recovered.completeTranslation("房间很暖。")
        XCTAssertFalse(draft.matches(evidence: [recovered], model: "fixed-model"))

        let review = try LearningPrompts.reviewInput(batches(trail: true)[0])
        XCTAssertEqual(review.json, FrozenTranslationPersistence.reviewInput)
        XCTAssertEqual(review, try LearningPrompts.reviewInput(batches(trail: false)[0]))
    }

    func testBatchDigestsAndSharedJournalMatchFrozenPreTrailBytes() throws {
        let plain = try batches(trail: false)
        let recovered = try batches(trail: true)
        XCTAssertEqual(try ReviewInputBinding.digest([recovered[0]]), FrozenTranslationPersistence.firstDigest)
        XCTAssertEqual(try ReviewInputBinding.digest([recovered[1]]), FrozenTranslationPersistence.secondDigest)
        XCTAssertEqual(try ReviewInputBinding.digest(recovered), FrozenTranslationPersistence.courseDigest)
        XCTAssertEqual(try ReviewInputBinding.digest(recovered), try ReviewInputBinding.digest(plain))
        XCTAssertEqual(try encode(journal(trail: false)), Data(FrozenTranslationPersistence.journal.utf8))
        XCTAssertEqual(try encode(journal(trail: true)), Data(FrozenTranslationPersistence.journal.utf8))

        let legacy = try JSONDecoder().decode(TranslationPersistenceLegacy020.Journal.self,
                                               from: encode(journal(trail: true)))
        XCTAssertEqual(try encode(legacy), Data(FrozenTranslationPersistence.journal.utf8))
        var oldJob = try XCTUnwrap(legacy.jobs.first)
        XCTAssertNoThrow(try TranslationPersistenceLegacy020.upgradeBoundIdentity(&oldJob))
        XCTAssertEqual(oldJob.inputDigest, FrozenTranslationPersistence.firstDigest)
        XCTAssertEqual(oldJob.courseInputDigest, FrozenTranslationPersistence.courseDigest)
        XCTAssertEqual(oldJob.courseBatchDigests, [
            "33333333-3333-3333-3333-333333333333": FrozenTranslationPersistence.firstDigest,
            "55555555-5555-5555-5555-555555555555": FrozenTranslationPersistence.secondDigest
        ])
        let oldCourse = try JSONDecoder().decode([TranslationPersistenceLegacy020.LearningNoteBatch].self,
                                                 from: encode(recovered))
        XCTAssertEqual(try TranslationPersistenceLegacy020.digest(oldCourse), FrozenTranslationPersistence.courseDigest)
        for batch in oldCourse {
            XCTAssertEqual(try TranslationPersistenceLegacy020.digest([batch]), oldJob.courseBatchDigests?[batch.id.uuidString])
        }
        let reopened = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: encode(legacy))
        XCTAssertEqual(try encode(reopened), Data(FrozenTranslationPersistence.journal.utf8))

        oldJob.inputDigest = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try TranslationPersistenceLegacy020.upgradeBoundIdentity(&oldJob))
    }

    func testCourseInputFingerprintIgnoresTrailsButStillBindsContent() throws {
        let course = try batches(trail: false)
        let plain = SessionSnapshot(sessionID: sessionID, inputRevision: 2,
            segments: course.flatMap(\.evidence), batches: course, latestEvidenceIDs: course[1].ids,
            notebookRevision: 2, createdAt: Date(timeIntervalSince1970: 100))
        var recovered = plain
        recovered.segments[0] = try segment(trail: true)
        recovered.segments[1].recordTranslationFailure(.requestTimedOut)
        recovered.batches = try batches(trail: true)
        // Diagnostics do not change the pre-trail English input identity.
        XCTAssertEqual(try plain.inputFingerprint(), FrozenTranslationPersistence.inputFingerprint)
        XCTAssertEqual(try recovered.inputFingerprint(), FrozenTranslationPersistence.inputFingerprint)
        recovered.segments[0].completeTranslation("房间很暖。")
        XCTAssertNotEqual(try recovered.inputFingerprint(), FrozenTranslationPersistence.inputFingerprint)
    }

    func testQueueRestoreValidatesBoundAndUpgradesUnboundIdentityAfter020RoundTrip() async throws {
        let root = try directory()
        let course = root.appendingPathComponent("lesson", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: true)
        let currentBatches = try batches(trail: true)
        var second = currentBatches[1].evidence[0]
        second.recordTranslationFailure(.requestTimedOut)
        let snapshot = SessionSnapshot(sessionID: sessionID, inputRevision: 2,
            segments: [try segment(trail: true), second], batches: currentBatches, notebookRevision: 2,
            createdAt: Date(timeIntervalSince1970: 100))
        _ = try SessionStore(directory: course).save(snapshot)

        for bound in [true, false] {
            let url = root.appendingPathComponent(bound ? "bound-queue.json" : "unbound-queue.json")
            var saved = try JSONDecoder().decode(LearningReviewQueue.Journal.self,
                from: encode(JSONDecoder().decode(TranslationPersistenceLegacy020.Journal.self,
                    from: Data(FrozenTranslationPersistence.journal.utf8))))
            saved.jobs[0].directory = course
            saved.jobs[0].prompt = LearningPrompts.review
            if !bound {
                saved.jobs[0].identity = nil
                saved.jobs[0].inputDigest = nil
                saved.jobs[0].courseInputDigest = nil
                saved.jobs[0].courseBatchDigests = nil
                saved.jobs[0].scope = .batch(1)
            }
            try encode(saved).write(to: url)
            let queue = LearningReviewQueue(journalURL: url, observeSleep: false, diagnostics: .disabled,
                generate: { _, _, _, _, _ in
                    XCTFail("Persistence checks must not start model generation")
                    throw CancellationError()
                })
            XCTAssertNil(queue.currentFailure)
            XCTAssertTrue(queue.userPaused)
            XCTAssertFalse(queue.running)
            XCTAssertEqual(queue.items.count, 1)
            let restored = try JSONDecoder().decode(LearningReviewQueue.Journal.self, from: Data(contentsOf: url))
            let job = try XCTUnwrap(restored.jobs.first)
            XCTAssertEqual(job.identity?.sessionID, sessionID)
            XCTAssertEqual(job.identity?.inputRevision, 2)
            XCTAssertEqual(job.identity?.notebookRevision, 2)
            XCTAssertEqual(job.resolvedScope.batchID, batchID)
            XCTAssertEqual(job.inputDigest, FrozenTranslationPersistence.firstDigest)
            XCTAssertEqual(job.courseInputDigest, FrozenTranslationPersistence.courseDigest)
            XCTAssertEqual(job.courseBatchDigests, try journal(trail: false).jobs[0].courseBatchDigests)
            XCTAssertNoThrow(try ReviewInputBinding.validate(identity: job.identity, scope: job.resolvedScope,
                batches: job.batches, digest: job.inputDigest, original: job.original, in: course, allowHistorical: false))
            await queue.shutdownForTesting()
        }
    }
}

// Literal fixtures freeze the sorted JSON emitted before translation trails
// (e1e3b03); SHA-256 values are over the exact UTF-8 batch arrays, not rawValue
// interpolation or expected values generated by the production encoder.
private enum FrozenTranslationPersistence {
    static let segment = #"{"chinese":"房间很冷。","endTime":3,"english":"The room is cold.","id":"11111111-1111-1111-1111-111111111111","inputRevision":2,"sessionID":"22222222-2222-2222-2222-222222222222","startTime":1,"translationState":"completed"}"#
    static let trailSegment = #"{"chinese":"房间很冷。","endTime":3,"english":"The room is cold.","id":"11111111-1111-1111-1111-111111111111","inputRevision":2,"sessionID":"22222222-2222-2222-2222-222222222222","startTime":1,"translationFailures":[{"count":2,"reason":"processExited"},{"count":1,"reason":"dependencyCancelled"}],"translationState":"completed"}"#
    static let firstBatch = #"{"evidence":[{"chinese":"房间很冷。","endTime":3,"english":"The room is cold.","id":"11111111-1111-1111-1111-111111111111","inputRevision":2,"sessionID":"22222222-2222-2222-2222-222222222222","startTime":1,"translationState":"completed"}],"id":"33333333-3333-3333-3333-333333333333","note":{"points":[{"kind":"核心结论","text":"房间很冷。"}],"topic":"温度"}}"#
    static let secondBatch = #"{"evidence":[{"chinese":"钟响了。","endTime":6,"english":"A bell rings.","id":"44444444-4444-4444-4444-444444444444","inputRevision":2,"sessionID":"22222222-2222-2222-2222-222222222222","startTime":4,"translationState":"completed"}],"id":"55555555-5555-5555-5555-555555555555","note":{"points":[{"kind":"核心结论","text":"钟响了。"}],"topic":"声音"}}"#
    static let firstDigest = "fa1ab9422e096f4c25a63bb631b88a9c2079ffa62fc2068fe5a3c231d2d2dbbb"
    static let secondDigest = "778b1ac9fa13de77101c5c10d058224c0fdffbea5af28d1c0cae389d632e2d93"
    static let courseDigest = "e867b9305f0a05bc54ababdb315e759325fe6359a430e065dc211ba2a8d82867"
    static let inputFingerprint = "d5b847384a30ae11e6cb0fdaf05e953db7945352dfffae13c3fa398ce5359bc4"
    static let generateInput = #"{"evidence":[{"id":"en0s0","index":0,"language":"en","text":"The room is cold."},{"id":"zh0s0","index":0,"language":"zh","text":"房间很冷。"}],"pendingPoints":[]}"#
    static let reviewInput = #"{"evidence":[{"index":0,"quotes":[{"id":"e0.en.0","language":"en","text":"The room is cold."},{"id":"e0.zh.0","language":"zh","text":"房间很冷。"}]}],"laterContext":[],"laterEvidence":[],"laterEvidenceOmittedCount":0,"note":{"points":[{"index":0,"kind":"核心结论","text":"房间很冷。"}],"topic":"温度"},"omittedEarlierCandidates":0,"reviewVersion":2}"#
    static let journal = #"{"jobs":[{"awaitingManualStart":true,"batches":[{"evidence":[{"chinese":"房间很冷。","endTime":3,"english":"The room is cold.","id":"11111111-1111-1111-1111-111111111111","inputRevision":2,"sessionID":"22222222-2222-2222-2222-222222222222","startTime":1,"translationState":"completed"}],"id":"33333333-3333-3333-3333-333333333333","note":{"points":[{"kind":"核心结论","text":"房间很冷。"}],"topic":"温度"}}],"courseBatchDigests":{"33333333-3333-3333-3333-333333333333":"fa1ab9422e096f4c25a63bb631b88a9c2079ffa62fc2068fe5a3c231d2d2dbbb","55555555-5555-5555-5555-555555555555":"778b1ac9fa13de77101c5c10d058224c0fdffbea5af28d1c0cae389d632e2d93"},"courseInputDigest":"e867b9305f0a05bc54ababdb315e759325fe6359a430e065dc211ba2a8d82867","directory":"file:\/\/\/lesson\/","id":"66666666-6666-6666-6666-666666666666","identity":{"inputRevision":2,"notebookRevision":2,"scope":{"batch":{"_0":"33333333-3333-3333-3333-333333333333"}},"sessionID":"22222222-2222-2222-2222-222222222222"},"inputDigest":"fa1ab9422e096f4c25a63bb631b88a9c2079ffa62fc2068fe5a3c231d2d2dbbb","next":0,"original":"Fixed original","prefix":"","reports":[],"scope":{"batchID":"33333333-3333-3333-3333-333333333333","batchNumber":1,"kind":"batch"}}],"userPaused":true,"version":3}"#
}

// Namespaced v0.2.0 persisted segment fields and decoder, read from src-v020.
// Unrelated rendering/mutation methods are omitted. Note/review auxiliary
// records are unchanged and reused; evidence must use this old segment type.
private enum TranslationPersistenceLegacy020 {
    struct TranscriptSegment: Codable, Equatable {
        enum TranslationState: String, Codable { case pending, translating, completed, failed }
        let id: UUID
        let sessionID: UUID?
        var inputRevision: Int
        let startTime: TimeInterval
        let endTime: TimeInterval
        let english: String
        var chinese: String
        private(set) var translationState: TranslationState
        private(set) var translationError: String?

        var hasUsableTranslation: Bool {
            translationState == .completed && !chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

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

    struct LearningNoteBatch: Codable {
        let id: UUID
        let evidence: [TranscriptSegment]
        var note: LearningNote
        var followUps: [LearningFollowUp]? = nil
    }

    struct Job: Codable {
        var id: UUID
        var directory: URL
        let batches: [LearningNoteBatch]
        let original: String
        var next: Int
        var prefix: String
        var reports: [String]
        var failure: String?
        var prompt: String?
        var directoryBookmark: Data?
        var prefixInputDigest: String?
        var events: [ReviewQueueEvent]?
        var lastRequestID: String?
        var retryPending: LearningReviewQueue.RetryState?
        var interruption: LearningReviewQueue.Interruption?
        var stats: LearningReviewQueue.JobStats?
        var scope: LearningReviewScope?
        var awaitingManualStart: Bool?
        var identity: ReviewIdentity?
        var inputDigest: String?
        var courseInputDigest: String?
        var courseBatchDigests: [String: String]?
        var supersededByRevision: Int?
        var resolvedScope: LearningReviewScope { scope ?? .wholeLesson }
    }

    struct Journal: Codable {
        var jobs: [Job]
        var userPaused: Bool
        var version: Int?
        var retiredJobs: [Job]?
    }

    static func digest(_ batches: [LearningNoteBatch]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ReviewInputBinding.digest(try encoder.encode(batches))
    }

    // The bound-job branch of v0.2.0 upgradeIdentity: progress and identity
    // validation precede a digest recomputed from the *old* evidence encoding.
    // Current identity validation uses only batch IDs, never evidence bytes.
    static func upgradeBoundIdentity(_ job: inout Job) throws {
        guard job.next >= 0, job.next <= job.batches.count, job.reports.count <= job.next,
              let identity = job.identity else {
            throw ReviewIdentityError.conflict("保存的复查进度无效")
        }
        let encoder = JSONEncoder()
        let batches = try JSONDecoder().decode([LiveLingo.LearningNoteBatch].self, from: encoder.encode(job.batches))
        try identity.validate(scope: job.resolvedScope, batches: batches)
        guard job.inputDigest == (try digest(job.batches)) else {
            throw ReviewIdentityError.conflict("保存的复查输入校验失败")
        }
    }
}
