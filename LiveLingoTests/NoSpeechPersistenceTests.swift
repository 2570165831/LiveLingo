import Foundation
import Testing
@testable import LiveLingo

/// Synthetic metadata and opaque fixture bytes only. No ASR, SoundAnalysis,
/// playback, GUI, candidate executable, classroom file or app container.
/// Disk specimens are retained under work/nsfilter, never deleted by this suite.
@Suite
struct NoSpeechPersistenceTests {
    private static let session = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let recordID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    // Required fields and synthesized optional encoding frozen at v0.2.0 and
    // v0.1.0+20260922.2. Neither reader knows extendedStatus/failureReason.
    private static let frozenRecordJSON = #"{"appleEvidence":"","attempt":"initial","audioFile":"synthetic-0.wav","automaticRetryCount":0,"end":10,"endFrame":160000,"id":"00000000-0000-0000-0000-000000000002","manualRetryCount":0,"modelKey":"synthetic-no-model","ordinal":0,"sampleRate":16000,"sessionID":"00000000-0000-0000-0000-000000000001","start":0,"startFrame":0,"status":"pending"}"#

    private func record(_ ordinal: Int = 0,
                        status: TranscriptionWorkRecord.Status = .pending) -> TranscriptionWorkRecord {
        var value = TranscriptionWorkRecord(id: ordinal == 0 ? Self.recordID : UUID(),
            sessionID: Self.session, ordinal: ordinal, audioFile: "synthetic-\(ordinal).wav",
            startFrame: Int64(ordinal * 160_000), endFrame: Int64((ordinal + 1) * 160_000),
            sampleRate: 16_000, start: Double(ordinal * 10), end: Double((ordinal + 1) * 10),
            captureStart: nil, captureEnd: nil, modelKey: "synthetic-no-model",
            fallbackModelKey: nil, appleEvidence: "", recordingFile: "synthetic-recording.wav")
        value.status = status
        return value
    }

    private func directory() throws -> URL {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent("work/nsfilter/persistence-fixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func object(_ value: some Encodable) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: SessionArchiveCoding.encode(value))
        return try #require(json as? [String: Any])
    }

    @Test func ordinaryRecordsKeepFrozenBytesAndOmitAnalysisKeys() throws {
        let frozen = Data(Self.frozenRecordJSON.utf8)
        let decoded = try JSONDecoder().decode(TranscriptionWorkRecord.self, from: frozen)
        #expect(decoded.speechConfidence == nil)
        #expect(try SessionArchiveCoding.encode(decoded) == frozen)
        for status in [TranscriptionWorkRecord.Status.pending, .active, .retryWaiting,
                       .manualPending, .completed, .silent, .failed, .otherLanguage] {
            let bytes = try object(record(status: status))
            #expect(bytes["speechConfidence"] == nil)
            #expect(bytes["failureReason"] == nil)
            if status != .otherLanguage { #expect(bytes["extendedStatus"] == nil) }
        }
    }

    @Test func noSpeechRoundTripsWithTerminalLegacySpelling() throws {
        var value = record(status: .noSpeech)
        value.failureReason = .noSpeech
        value.speechConfidence = 0.09
        let encoded = try SessionArchiveCoding.encode(value)
        let bytes = try object(value)
        #expect(bytes["status"] as? String == "silent")
        #expect(bytes["extendedStatus"] as? String == "noSpeech")
        #expect(bytes["failureReason"] as? String == "noSpeech")
        #expect(bytes["speechConfidence"] as? Double == 0.09)
        let decoded = try JSONDecoder().decode(TranscriptionWorkRecord.self, from: encoded)
        #expect(decoded == value)
        #expect(!decoded.needsWork)
        #expect(!decoded.isClaimable)
        #expect(!decoded.isStuckFailed)
        #expect(decoded.audioRetired == nil)
        #expect(try JSONDecoder().decode(FrozenPublishedRecord.self, from: encoded).status == .silent)
        #expect(try JSONDecoder().decode(FrozenLabRecord.self, from: encoded).status == .silent)
        #expect(try JSONDecoder().decode(FrozenLabRecord.self, from: encoded).failureReason == nil)
    }

    @Test func knownExtensionWinsAndFutureExtensionsDegradeToLegacy() throws {
        var value = record(status: .noSpeech)
        value.failureReason = .noSpeech
        value.speechConfidence = 0
        var bytes = try object(value)
        bytes["status"] = "failed"
        var encoded = try JSONSerialization.data(withJSONObject: bytes)
        #expect(try JSONDecoder().decode(TranscriptionWorkRecord.self, from: encoded).status == .noSpeech)
        bytes["status"] = "silent"
        bytes["extendedStatus"] = "futureTerminal"
        bytes["failureReason"] = "futureReason"
        encoded = try JSONSerialization.data(withJSONObject: bytes)
        let decoded = try JSONDecoder().decode(TranscriptionWorkRecord.self, from: encoded)
        #expect(decoded.status == .silent)
        #expect(decoded.failureReason == nil)
        #expect(decoded.speechConfidence == 0)
    }

    @Test func journalReopenPreservesTerminalVerdictAndOpaqueAudio() throws {
        let root = try directory()
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: Self.session)
        let value = record()
        let chunk = journal.directory.appendingPathComponent(value.audioFile)
        let original = root.appendingPathComponent("synthetic-recording.wav")
        let chunkBytes = Data("synthetic-unopened-chunk".utf8)
        let originalBytes = Data("synthetic-unopened-original".utf8)
        try chunkBytes.write(to: chunk, options: .withoutOverwriting)
        try originalBytes.write(to: original, options: .withoutOverwriting)
        try journal.put(value)
        #expect(try journal.claimNext()?.attempt == .initial)
        try journal.markNoSpeech(id: value.id, speechConfidence: 0.05)
        #expect(try journal.claimNext() == nil)
        #expect(journal.processingState.noSpeechCount == 1)
        #expect(journal.processingState.pendingCount == 0)
        #expect(journal.processingState.backlogSeconds == 0)
        #expect(journal.processingState.unresolvedCount == 0)
        #expect(journal.processingState.failedCount == 0)
        #expect(!journal.processingState.hasAutomaticWork)
        try journal.checkpoint()
        let reopened = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: Self.session)
        let saved = try #require(reopened.record(id: value.id))
        #expect(saved.status == .noSpeech)
        #expect(saved.failureReason == .noSpeech)
        #expect(saved.speechConfidence == 0.05)
        #expect(saved.audioRetired == nil)
        #expect(saved.automaticRetryCount == 0)
        #expect(saved.manualRetryCount == 0)
        #expect(reopened.processingState.noSpeechCount == 1)
        #expect(try reopened.claimNext() == nil)
        #expect(try Data(contentsOf: chunk) == chunkBytes)
        #expect(try Data(contentsOf: original) == originalBytes)
    }

    @Test func manualRetryClearsCurrentVerdictAndCannotBeFilteredAgain() throws {
        let journal = try DurableTranscriptionJournal(sessionDirectory: directory(), sessionID: Self.session)
        let value = record()
        try journal.put(value)
        _ = try journal.claimNext()
        try journal.markNoSpeech(id: value.id, speechConfidence: 0.099)
        try journal.retry(id: value.id)
        let pending = try #require(journal.record(id: value.id))
        #expect(pending.status == .manualPending)
        #expect(pending.speechConfidence == nil)
        #expect(pending.failureReason == nil)
        #expect(pending.failure == nil)
        #expect(journal.processingState.noSpeechCount == 0)
        #expect(journal.processingState.claimableCount == 1)
        let claimedRecord = try journal.claimNext()
        let manual = try #require(claimedRecord)
        #expect(manual.attempt == .manual)
        #expect(manual.manualRetryCount == 1)
        #expect(manual.automaticRetryCount == 0)
        #expect(throws: DurableTranscriptionJournal.JournalError.self) {
            try journal.markNoSpeech(id: value.id, speechConfidence: 0)
        }
        #expect(journal.record(id: value.id)?.status == .active)
        #expect(try object(manual)["speechConfidence"] == nil)
    }

    @Test func restoredManualPendingClearsOldConfidenceWhenClaimed() throws {
        let journal = try DurableTranscriptionJournal(sessionDirectory: directory(), sessionID: Self.session)
        var pending = record(status: .manualPending)
        pending.speechConfidence = 0.02
        try journal.put(pending)
        let claimedRecord = try journal.claimNext()
        let claimed = try #require(claimedRecord)
        #expect(claimed.attempt == .manual)
        #expect(claimed.speechConfidence == nil)
        #expect(journal.record(id: pending.id)?.speechConfidence == nil)
    }

    @Test func automaticRepairAfterManualRetryCannotRestoreNoSpeechVerdict() throws {
        let journal = try DurableTranscriptionJournal(sessionDirectory: directory(), sessionID: Self.session)
        var value = record(status: .active)
        value.attempt = .automaticRetry
        value.manualRetryCount = 1
        value.automaticRetryCount = 1
        try journal.put(value)
        #expect(throws: DurableTranscriptionJournal.JournalError.self) {
            try journal.markNoSpeech(id: value.id, speechConfidence: 0.01)
        }
        #expect(journal.record(id: value.id)?.status == .active)
        #expect(journal.record(id: value.id)?.speechConfidence == nil)
    }

    @Test func invalidConfidenceCannotMutateTheJournal() throws {
        let journal = try DurableTranscriptionJournal(sessionDirectory: directory(), sessionID: Self.session)
        let value = record()
        try journal.put(value)
        _ = try journal.claimNext()
        let log = journal.directory.appendingPathComponent("work.jsonl")
        let before = try Data(contentsOf: log)
        for confidence in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            #expect(throws: DurableTranscriptionJournal.JournalError.self) {
                try journal.markNoSpeech(id: value.id, speechConfidence: confidence)
            }
            #expect(try Data(contentsOf: log) == before)
        }
        #expect(journal.record(id: value.id)?.status == .active)
        #expect(journal.record(id: value.id)?.speechConfidence == nil)
    }

    @Test func noSpeechWritebackPreservesBodyAddedAfterClaim() throws {
        let journal = try DurableTranscriptionJournal(sessionDirectory: directory(), sessionID: Self.session)
        try journal.put(record())
        var current = try #require(try journal.claimNext())
        current.text = "Synthetic speech added while classification was running."
        current.failure = "Earlier empty attempt"
        current.failureReason = .emptyOutput
        try journal.put(current)
        try journal.markNoSpeech(id: current.id, speechConfidence: 0.05)
        let saved = try #require(journal.record(id: current.id))
        #expect(saved.status == .completed)
        #expect(saved.text == current.text)
        #expect(saved.failure == nil)
        #expect(saved.failureReason == nil)
        #expect(saved.speechConfidence == nil)
        #expect(journal.processingState.noSpeechCount == 0)
    }

    @Test func candidateOnlyWritebackKeepsRepairBudgetAndExplainsExhaustion() throws {
        for retries in [0, DurableTranscriptionJournal.maximumAutomaticRetries] {
            let root = try directory()
            let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: Self.session)
            var current = record(status: .active)
            current.attempt = .automaticRetry
            current.automaticRetryCount = retries
            current.candidateText = "Synthetic candidate added during classification."
            current.candidateOrigin = "context"
            try journal.put(current)
            try journal.markNoSpeech(id: current.id, speechConfidence: 0.05)
            let saved = try #require(journal.record(id: current.id))
            #expect(saved.status == (retries < DurableTranscriptionJournal.maximumAutomaticRetries ? .retryWaiting : .failed))
            #expect(saved.candidateText == current.candidateText)
            #expect(saved.candidateOrigin == "context")
            #expect(saved.text == nil)
            #expect(saved.failure?.isEmpty == false)
            #expect(saved.failureReason == .emptyOutput)
            #expect(saved.speechConfidence == nil)
            #expect(saved.isClaimable == (retries < DurableTranscriptionJournal.maximumAutomaticRetries))
            try journal.checkpoint()
            let reopened = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: Self.session)
            #expect(reopened.record(id: current.id) == saved)
            #expect(reopened.processingState.noSpeechCount == 0)
            #expect(reopened.processingState.candidateCount == 1)
        }
    }

    @Test func noSpeechTerminalClearsDeferredReplacementWork() throws {
        let journal = try DurableTranscriptionJournal(sessionDirectory: directory(), sessionID: Self.session)
        var current = record(status: .active)
        current.sourceProbeInput = .init(parakeetAccepted: false, mean: 0.3, minimum: 0.01)
        current.sourceProbeFinished = false
        current.sourceRevisionAllowed = true
        current.sourceInitialEnglishDigest = "synthetic-obsolete-digest"
        try journal.put(current)
        try journal.markNoSpeech(id: current.id, speechConfidence: 0.05)
        let saved = try #require(journal.record(id: current.id))
        #expect(saved.status == .noSpeech)
        #expect(saved.sourceProbeInput == nil)
        #expect(saved.sourceProbeFinished == nil)
        #expect(saved.sourceRevisionAllowed == nil)
        #expect(saved.sourceInitialEnglishDigest == nil)
        #expect(journal.processingState.pendingCount == 0)
    }

    @Test func terminalCountersRemainDisjointFromFailuresAndCandidates() throws {
        let journal = try DurableTranscriptionJournal(sessionDirectory: directory(), sessionID: Self.session)
        var filtered = record(status: .noSpeech)
        filtered.failureReason = .noSpeech
        filtered.speechConfidence = 0.03
        try journal.put(filtered)
        try journal.put(record(1, status: .failed))
        try journal.put(record(2, status: .otherLanguage))
        var candidate = record(3, status: .noSpeech)
        candidate.candidateText = "Synthetic preserved candidate"
        try journal.put(candidate)
        try journal.put(record(4, status: .silent))
        try journal.put(record(5))
        let state = journal.processingState
        #expect(state.noSpeechCount == 1)
        #expect(state.otherLanguageCount == 1)
        #expect(state.unresolvedCount == 2)
        #expect(state.failedCount == 1)
        #expect(state.candidateCount == 1)
        #expect(state.failedWithCandidateCount == 0)
        #expect(state.pendingCount == 1)
        #expect(state.claimableCount == 1)
        #expect(state.backlogSeconds == 10)
    }

    @Test func optionalArchiveCountKeepsReaderGatesAndInputFingerprint() throws {
        var snapshot = SessionSnapshot(sessionID: Self.session, createdAt: Date(timeIntervalSince1970: 1_000))
        let frozen = try SessionArchiveCoding.encode(snapshot)
        let fingerprint = try snapshot.inputFingerprint()
        #expect(try object(snapshot.processing)["noSpeechCount"] == nil)
        snapshot.processing.noSpeechCount = 2
        try snapshot.validate()
        #expect(try snapshot.inputFingerprint() == fingerprint)
        let encoded = try SessionArchiveCoding.encode(snapshot)
        let decoded = try SessionArchiveCoding.decode(SessionSnapshot.self, from: encoded)
        #expect(decoded.processing.noSpeechCount == 2)
        #expect(try SessionArchiveCoding.minimumReaderVersion(for: encoded) == 1)
        snapshot.targetLocale = "en"
        #expect(try SessionArchiveCoding.minimumReaderVersion(for: SessionArchiveCoding.encode(snapshot)) == 2)
        snapshot.captureUTCOffsetSeconds = 0
        #expect(try SessionArchiveCoding.minimumReaderVersion(for: SessionArchiveCoding.encode(snapshot)) == 3)
        snapshot.targetLocale = nil
        snapshot.captureUTCOffsetSeconds = nil
        snapshot.processing.noSpeechCount = nil
        #expect(try SessionArchiveCoding.encode(snapshot) == frozen)
        snapshot.processing.noSpeechCount = -1
        #expect(throws: SessionStoreError.self) { try snapshot.validate() }
    }

    @Test func detailsExposeFilteredCountAndManualRetryWithoutChangingOldLabels() {
        let filtered = record(status: .noSpeech)
        #expect(SavedProcessingPresentation.showsTranscriptionTask(filtered))
        #expect(SavedProcessingPresentation.canRetryTranscription(filtered))
        #expect(!SavedProcessingPresentation.canRetryTranscription(record(status: .silent)))
        #expect(!SavedProcessingPresentation.showsTranscriptionTask(record(status: .silent)))
        #expect(SavedProcessingPresentation.recordLabel(.noSpeech) == "未识别到讲话")
        #expect(SavedProcessingPresentation.recordLabel(.silent) == "已确认无讲话")
        let baseline = TranscriptionProcessingState(sessionID: Self.session,
            isCapturing: false, isPaused: false, activeCount: 0, pendingCount: 0,
            backlogSeconds: 0, unresolvedCount: 0)
        #expect(SavedProcessingPresentation.workSummary(baseline, segments: [])
            == "等待转写 0 段 · 待确认或失败 0 段")
        var state = baseline
        state.noSpeechCount = 2
        #expect(SavedProcessingPresentation.workSummary(state, segments: [])
            == "等待转写 0 段 · 待确认或失败 0 段 · 未识别到讲话 2 段")
        #expect(SavedProcessingPresentation.noSpeechSummary(count: 0) == nil)
    }

    @Test func noSpeechStatisticsAreAddedOnlyForPositiveCounts() throws {
        let baseline: [String: Any] = ["event": "finished", "segments": 2, "unresolvedTranscription": 0]
        func bytes(_ fields: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        }
        for count in [0, -1] {
            #expect(try bytes(TranscriptionProcessingState.addingNoSpeechStatistic(baseline, count: count))
                == bytes(baseline))
        }
        let filtered = TranscriptionProcessingState.addingNoSpeechStatistic(baseline, count: 3)
        #expect(filtered["noSpeechTranscription"] as? Int == 3)
        #expect(filtered["unresolvedTranscription"] as? Int == 0)
        #expect(filtered["segments"] as? Int == 2)
    }

    @Test func frozenReaderRewriteLosesExtensionButKeepsTerminalAudioLocator() throws {
        var value = record(status: .noSpeech)
        value.failureReason = .noSpeech
        value.speechConfidence = 0.01
        let old = try JSONDecoder().decode(FrozenPublishedRecord.self, from: SessionArchiveCoding.encode(value))
        let rewritten = try SessionArchiveCoding.encode(old)
        let json = try JSONSerialization.jsonObject(with: rewritten)
        let bytes = try #require(json as? [String: Any])
        #expect(bytes["extendedStatus"] == nil)
        #expect(bytes["failureReason"] == nil)
        #expect(bytes["speechConfidence"] == nil)
        let reread = try JSONDecoder().decode(TranscriptionWorkRecord.self, from: rewritten)
        #expect(reread.status == .silent)
        #expect(!reread.needsWork)
        #expect(reread.recordingFile == value.recordingFile)
        #expect(reread.startFrame == value.startFrame)
        #expect(reread.endFrame == value.endFrame)
        #expect(reread.speechConfidence == nil)
    }
}

/// Required fields/optional payload copied from the published 0.1.0 build
/// tag v0.1.0+20260922.2 and v0.2.0, avoiding execution of either old reader.
private struct FrozenPublishedRecord: Codable {
    enum Status: String, Codable { case pending, active, retryWaiting, manualPending, completed, silent, failed }
    enum Attempt: String, Codable { case initial, automaticRetry, manual }
    let id: UUID
    let sessionID: UUID
    let ordinal: Int
    let audioFile: String
    let startFrame: Int64
    let endFrame: Int64
    let sampleRate: Double
    let start: TimeInterval
    let end: TimeInterval
    let captureStart: TimeInterval?
    let captureEnd: TimeInterval?
    let modelKey: String
    let fallbackModelKey: String?
    let appleEvidence: String
    var recordingFile: String?
    var audioRetired: Bool?
    var status: Status
    var attempt: Attempt
    var automaticRetryCount: Int
    var manualRetryCount: Int
    var text: String?
    var candidateText: String?
    var candidateOrigin: String?
    var failure: String?
}

/// Exact old-lab fallback decisions, projected onto status/reason. The old lab
/// reads raw strings and tolerates unfamiliar extendedStatus/failureReason.
private struct FrozenLabRecord: Decodable {
    enum Status: String, Decodable { case pending, active, retryWaiting, manualPending, completed, silent, failed, otherLanguage }
    enum FailureReason: String { case englishGateHanDominant, englishGateNoLatin, emptyOutput, invalidText, repeatedLoop, runawayText, error, interrupted }
    let status: Status
    let failureReason: FailureReason?
    private enum CodingKeys: String, CodingKey { case status, extendedStatus, failureReason }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .extendedStatus).flatMap(Status.init(rawValue:))
            ?? c.decode(Status.self, forKey: .status)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason).flatMap(FailureReason.init(rawValue:))
    }
}
