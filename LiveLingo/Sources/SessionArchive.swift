import Foundation
import CryptoKit
import Darwin

/// A persisted URL may lose its trailing directory separator during decoding.
/// Normalize that presentation detail before comparing course locators. The
/// stable session UUID still identifies content; this only locates its files.
enum SessionDirectoryLocation {
    static func canonical(_ directory: URL) -> URL {
        URL(fileURLWithPath: directory.standardizedFileURL.resolvingSymlinksInPath().path,
            isDirectory: true)
    }
}

/// Disk data deliberately does not depend on LearningNotebook's private state.
/// Loading this value never starts capture, transcription, or a model.
struct SessionSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = currentSchemaVersion
    var sessionID: UUID
    var inputRevision: Int
    var segments: [TranscriptSegment]
    var batches: [LearningNoteBatch]
    var latestEvidenceIDs: Set<UUID>
    var legacyMarkdown: String?
    var notebookRevision: Int
    var notebookSelectionRound: Int
    var notebookLastOffered: [String: Int]
    var generation: Int
    var generationCheckpoints: [SessionGenerationCheckpoint]
    var processing: SessionProcessingState
    var audioFiles: [SessionAudioMetadata]
    var audioRanges: [SessionAudioRange]
    /// The audio subsystem owns the durable work queue, including retry counts.
    var transcriptionJournalPath: String?
    var revisionHistory: [SessionInputRevision]
    var createdAt: Date
    var updatedAt: Date
    /// Optimistic concurrency token. Keep the value returned by save/append.
    var storageRevision: Int = 0
    var lastJournalSequence: Int = 0
    var lastJournalDigest: String = SessionArchiveCoding.genesisDigest

    init(
        sessionID: UUID = UUID(), inputRevision: Int = 0,
        segments: [TranscriptSegment] = [], batches: [LearningNoteBatch] = [],
        latestEvidenceIDs: Set<UUID> = [], legacyMarkdown: String? = nil,
        notebookRevision: Int = 0, notebookSelectionRound: Int = 0,
        notebookLastOffered: [String: Int] = [:], generation: Int = 0,
        generationCheckpoints: [SessionGenerationCheckpoint] = [],
        processing: SessionProcessingState = .init(),
        audioFiles: [SessionAudioMetadata] = [], audioRanges: [SessionAudioRange] = [],
        transcriptionJournalPath: String? = nil, revisionHistory: [SessionInputRevision] = [],
        createdAt: Date = Date(), updatedAt: Date? = nil
    ) {
        self.sessionID = sessionID; self.inputRevision = inputRevision
        self.segments = segments; self.batches = batches
        self.latestEvidenceIDs = latestEvidenceIDs; self.legacyMarkdown = legacyMarkdown
        self.notebookRevision = notebookRevision; self.notebookSelectionRound = notebookSelectionRound
        self.notebookLastOffered = notebookLastOffered; self.generation = generation
        self.generationCheckpoints = generationCheckpoints; self.processing = processing
        self.audioFiles = audioFiles; self.audioRanges = audioRanges
        self.transcriptionJournalPath = transcriptionJournalPath; self.revisionHistory = revisionHistory
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
    }

    /// Paths and runtime progress are excluded. Frozen review input is included.
    func inputFingerprint() throws -> String {
        struct Input: Encodable {
            let sessionID: UUID
            let inputRevision: Int
            let segments: [TranscriptSegment]
            let batches: [LearningNoteBatch]
            let latestEvidenceIDs: [UUID]
            let legacyMarkdown: String?
        }
        return SessionArchiveCoding.digest(try SessionArchiveCoding.encode(Input(
            sessionID: sessionID, inputRevision: inputRevision, segments: segments,
            batches: batches, latestEvidenceIDs: latestEvidenceIDs.sorted { $0.uuidString < $1.uuidString },
            legacyMarkdown: legacyMarkdown
        )))
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SessionStoreError.unsupportedSchema(schemaVersion)
        }
        guard inputRevision >= 0, inputRevision < Int.max, storageRevision >= 0, storageRevision < Int.max,
              lastJournalSequence >= 0, lastJournalSequence < Int.max,
              notebookRevision >= 0, notebookRevision < Int.max, notebookSelectionRound >= 0, generation >= 0,
              notebookLastOffered.values.allSatisfy({ $0 >= 0 && $0 < notebookSelectionRound }),
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              SessionArchiveCoding.isDigest(lastJournalDigest) else {
            throw SessionStoreError.invalidState("会话修订号、时间或日志标识无效")
        }
        guard Set(segments.map(\.id)).count == segments.count,
              Set(batches.map(\.id)).count == batches.count,
              Set(generationCheckpoints.map(\.id)).count == generationCheckpoints.count,
              Set(audioFiles.map(\.relativePath)).count == audioFiles.count,
              Set(audioRanges.map(\.id)).count == audioRanges.count,
              Set(revisionHistory.map(\.id)).count == revisionHistory.count,
              Set(revisionHistory.map(\.toRevision)).count == revisionHistory.count else {
            throw SessionStoreError.invalidState("会话包含重复的稳定标识")
        }
        let retiredBatchIDs = Set(revisionHistory.flatMap { $0.retainedBatches.map(\.id) })
        guard batches.allSatisfy({ !retiredBatchIDs.contains($0.id) }) else {
            throw SessionStoreError.invalidState("失效笔记批次只能保留在修订历史中")
        }
        for segment in segments + batches.flatMap(\.evidence) {
            guard segment.startTime.isFinite, segment.endTime.isFinite,
                  segment.startTime >= 0, segment.endTime >= segment.startTime,
                  segment.inputRevision >= 0, segment.inputRevision <= inputRevision,
                  segment.sessionID == nil || segment.sessionID == sessionID else {
                throw SessionStoreError.invalidState("字幕的会话、时间或修订号不一致")
            }
        }
        let knownEvidence = Set(segments.map(\.id) + batches.flatMap { $0.evidence.map(\.id) })
        guard latestEvidenceIDs.isSubset(of: knownEvidence) else {
            throw SessionStoreError.invalidState("最近更新引用了不存在的片段")
        }
        for checkpoint in generationCheckpoints {
            try checkpoint.validate(sessionID: sessionID)
            guard checkpoint.inputRevision <= inputRevision,
                  checkpoint.invalidated || canResume(checkpoint),
                  Set(checkpoint.evidenceIDs).isSubset(of: knownEvidence) else {
                throw SessionStoreError.invalidState("生成检查点对应的输入版本或来源已失效")
            }
        }
        try processing.validate()
        for audio in audioFiles { try audio.validate() }
        for range in audioRanges {
            try range.validate()
            guard let audio = audioFiles.first(where: { $0.relativePath == range.filePath }) else {
                throw SessionStoreError.invalidState("音频区间未关联录音文件")
            }
            if let frames = audio.frameCount, range.startFrame + range.frameCount > frames {
                throw SessionStoreError.invalidState("音频区间超出已记录的文件帧数")
            }
        }
        if let path = transcriptionJournalPath { try SessionArchiveCoding.validateRelativePath(path) }
        for change in revisionHistory {
            guard change.fromRevision >= 0, change.toRevision > change.fromRevision,
                  change.toRevision <= inputRevision, change.toRevision == change.fromRevision + 1,
                  change.previousSegment.id == change.replacementSegment.id,
                  change.previousSegment.inputRevision <= change.fromRevision,
                  change.replacementSegment.inputRevision == change.toRevision,
                  Set(change.retainedBatches.map(\.id)).count == change.retainedBatches.count,
                  change.retainedBatches.allSatisfy({ $0.ids.contains(change.previousSegment.id) }),
                  change.confirmedAt.timeIntervalSince1970.isFinite, !change.reason.isEmpty else {
                throw SessionStoreError.invalidState("输入修订记录无效")
            }
            for segment in [change.previousSegment, change.replacementSegment] + change.retainedBatches.flatMap(\.evidence) {
                guard segment.startTime.isFinite, segment.endTime.isFinite,
                      segment.startTime >= 0, segment.endTime >= segment.startTime,
                      segment.inputRevision >= 0, segment.inputRevision <= inputRevision,
                      segment.sessionID == nil || segment.sessionID == sessionID else {
                    throw SessionStoreError.invalidState("修订历史含无效或其他课程的字幕")
                }
            }
        }
    }

    /// The checkpoint keeps the revision that produced its frozen input. A
    /// later session revision can reuse it only when every intervening edit is
    /// known and none touches its complete dependency list.
    func canResume(_ checkpoint: SessionGenerationCheckpoint) -> Bool {
        guard !checkpoint.invalidated, checkpoint.sessionID == sessionID,
              checkpoint.inputRevision >= 0, checkpoint.inputRevision <= inputRevision else { return false }
        if checkpoint.inputRevision == inputRevision { return true }
        guard !checkpoint.evidenceIDs.isEmpty else { return false }
        let changes = revisionHistory.filter { $0.toRevision > checkpoint.inputRevision && $0.toRevision <= inputRevision }
            .sorted { $0.toRevision < $1.toRevision }
        guard changes.count == inputRevision - checkpoint.inputRevision else { return false }
        let dependencies = Set(checkpoint.evidenceIDs)
        return changes.enumerated().allSatisfy { offset, change in
            change.fromRevision == checkpoint.inputRevision + offset
                && change.toRevision == change.fromRevision + 1
                && !dependencies.contains(change.previousSegment.id)
        }
    }
}

struct SessionProcessingState: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case idle, capturing, draining, paused, completed, failed }
    enum FailureSource: String, Codable, Sendable { case capture, storage }
    var phase: Phase = .idle
    var paused: Bool = false
    var pendingSegmentIDs: [UUID] = []
    var pendingBatchIDs: [UUID] = []
    var summaryPaused: Bool = false
    var reviewPaused: Bool = true
    var lastError: String?
    /// Older snapshots have no category. Preserve their error until the user
    /// explicitly resolves it; a successful disk retry cannot erase audio loss.
    var lastErrorSource: FailureSource?
    var captureError: String?
    var lastCapturedTime: TimeInterval?

    mutating func recordFailure(_ message: String, source: FailureSource) {
        if lastErrorSource == .capture, captureError == nil { captureError = lastError }
        if source == .capture { captureError = message }
        lastError = message
        lastErrorSource = source
    }

    @discardableResult
    mutating func clearResolvedStorageFailure() -> String? {
        guard lastErrorSource == .storage else { return nil }
        let previous = lastError
        lastError = captureError
        lastErrorSource = captureError == nil ? nil : .capture
        return previous
    }

    func validate() throws {
        guard Set(pendingSegmentIDs).count == pendingSegmentIDs.count,
              Set(pendingBatchIDs).count == pendingBatchIDs.count,
              lastErrorSource == nil || lastError != nil,
              lastCapturedTime.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw SessionStoreError.invalidState("待处理任务或采集进度无效")
        }
    }
}

struct SessionGenerationCheckpoint: Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var sessionID: UUID
    var inputRevision: Int
    var generation: Int = 0
    var kind: String = "summary"
    var modelName: String
    var protocolVersion: Int
    var inputDigest: String
    var promptDigest: String
    var input: String
    var prefix: String = ""
    /// Complete source dependency set, including prior pending questions.
    var evidenceIDs: [UUID] = []
    /// The new batch's own evidence can be a subset of the dependencies. Nil
    /// preserves the legacy meaning in which both sets were identical.
    var batchEvidenceIDs: [UUID]?
    var pendingTargetIDs: [String] = []
    var contextRevision: Int = 0
    var attempts: Int = 0
    var completedNote: LearningNote?
    var invalidated: Bool = false

    func matches(sessionID: UUID, inputRevision: Int, modelName: String,
                 protocolVersion: Int, input: String, prompt: String) -> Bool {
        !invalidated && self.sessionID == sessionID && self.inputRevision == inputRevision
            && self.modelName == modelName && self.protocolVersion == protocolVersion
            && self.input == input
            && inputDigest == SessionArchiveCoding.digest(Data(input.utf8))
            && promptDigest == SessionArchiveCoding.digest(Data(prompt.utf8))
    }

    /// Use this overload after reopening or revising a different source segment.
    func matches(snapshot: SessionSnapshot, modelName: String, protocolVersion: Int,
                 input: String, prompt: String) -> Bool {
        snapshot.canResume(self) && matches(sessionID: snapshot.sessionID, inputRevision: self.inputRevision,
                                            modelName: modelName, protocolVersion: protocolVersion,
                                            input: input, prompt: prompt)
    }

    fileprivate func validateContinuation(from old: Self) throws {
        guard id == old.id, sessionID == old.sessionID, inputRevision == old.inputRevision,
              generation == old.generation, kind == old.kind, modelName == old.modelName,
              protocolVersion == old.protocolVersion, inputDigest == old.inputDigest,
              promptDigest == old.promptDigest, input == old.input, evidenceIDs == old.evidenceIDs,
              batchEvidenceIDs == old.batchEvidenceIDs,
              pendingTargetIDs == old.pendingTargetIDs, contextRevision == old.contextRevision else {
            throw SessionStoreError.identityConflict("相同检查点对应不同生成输入")
        }
        guard prefix.hasPrefix(old.prefix), attempts >= old.attempts,
              !old.invalidated || invalidated,
              old.completedNote == nil || completedNote == old.completedNote else {
            throw SessionStoreError.invalidState("检查点不能丢弃已保存前缀、完成结果或失效状态")
        }
    }

    func validate(sessionID: UUID) throws {
        guard self.sessionID == sessionID, inputRevision >= 0, generation >= 0,
              protocolVersion > 0, contextRevision >= 0, attempts >= 0,
              !modelName.isEmpty, !kind.isEmpty,
              inputDigest == SessionArchiveCoding.digest(Data(input.utf8)),
              SessionArchiveCoding.isDigest(promptDigest), Set(evidenceIDs).count == evidenceIDs.count,
              batchEvidenceIDs.map({ Set($0).count == $0.count && Set($0).isSubset(of: Set(evidenceIDs)) }) ?? true else {
            throw SessionStoreError.invalidState("生成检查点未正确绑定输入与协议")
        }
    }
}

struct SessionAudioMetadata: Codable, Equatable, Sendable {
    var relativePath: String
    var sampleRate: Double?
    var channelCount: Int?
    var frameCount: Int64?
    var byteCount: UInt64?
    var sha256: String?
    var isFinalized: Bool = false

    func validate() throws {
        try SessionArchiveCoding.validateRelativePath(relativePath)
        guard sampleRate.map({ $0.isFinite && $0 > 0 }) ?? true,
              channelCount.map({ $0 > 0 }) ?? true,
              frameCount.map({ $0 >= 0 }) ?? true,
              sha256.map(SessionArchiveCoding.isDigest) ?? true else {
            throw SessionStoreError.invalidState("音频元数据无效")
        }
    }
}

struct SessionAudioRange: Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var segmentID: UUID
    var filePath: String
    var startFrame: Int64
    var frameCount: Int64
    var captureStart: TimeInterval
    var captureEnd: TimeInterval
    var interruptionReason: String?

    func validate() throws {
        try SessionArchiveCoding.validateRelativePath(filePath)
        guard startFrame >= 0, frameCount >= 0, startFrame <= Int64.max - frameCount,
              captureStart.isFinite, captureEnd.isFinite, captureStart >= 0, captureEnd >= captureStart else {
            throw SessionStoreError.invalidState("音频帧范围或采集时间无效")
        }
    }
}

struct SessionInputRevision: Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var fromRevision: Int
    var toRevision: Int
    var previousSegment: TranscriptSegment
    var replacementSegment: TranscriptSegment
    var retainedBatches: [LearningNoteBatch] = []
    var reason: String
    var confirmedAt: Date = Date()
    /// Exact ASR proposal the user accepted. After a crash between the course
    /// commit and queue acknowledgement, this supplies durable consent.
    var transcriptionCandidateText: String? = nil
}

enum SessionJournalEvent: Codable, Equatable, Sendable {
    case upsertSegment(TranscriptSegment)
    case appendBatch(LearningNoteBatch)
    case processing(SessionProcessingState)
    case generationCheckpoint(SessionGenerationCheckpoint)
    case inputRevision(SessionInputRevision)

    fileprivate func apply(to snapshot: inout SessionSnapshot) throws {
        switch self {
        case .upsertSegment(let segment):
            if let index = snapshot.segments.firstIndex(where: { $0.id == segment.id }) {
                let previous = snapshot.segments[index]
                guard previous.english == segment.english, previous.startTime == segment.startTime,
                      previous.endTime == segment.endTime, previous.inputRevision == segment.inputRevision else {
                    throw SessionStoreError.invalidState("正文改动必须提供确认后的修订记录")
                }
                snapshot.segments[index] = segment
            } else { snapshot.segments.append(segment) }
        case .appendBatch(let batch):
            if let existing = snapshot.batches.first(where: { $0.id == batch.id }) {
                guard existing == batch else { throw SessionStoreError.identityConflict("笔记批次内容冲突") }
            } else {
                snapshot.batches.append(batch)
                snapshot.latestEvidenceIDs = batch.ids
                snapshot.notebookRevision += 1
            }
        case .processing(let state): snapshot.processing = state
        case .generationCheckpoint(let checkpoint):
            if let index = snapshot.generationCheckpoints.firstIndex(where: { $0.id == checkpoint.id }) {
                let old = snapshot.generationCheckpoints[index]
                try checkpoint.validateContinuation(from: old)
                snapshot.generationCheckpoints[index] = checkpoint
            } else { snapshot.generationCheckpoints.append(checkpoint) }
        case .inputRevision(let change):
            guard snapshot.inputRevision < Int.max,
                  change.fromRevision == snapshot.inputRevision,
                  change.toRevision == snapshot.inputRevision + 1,
                  change.previousSegment.id == change.replacementSegment.id,
                  change.replacementSegment.inputRevision == change.toRevision,
                  let index = snapshot.segments.firstIndex(where: { $0.id == change.previousSegment.id }),
                  snapshot.segments[index] == change.previousSegment else {
                throw SessionStoreError.invalidState("输入修订与当前正文不匹配")
            }
            let affected = snapshot.batches.filter { $0.ids.contains(change.previousSegment.id) }
            guard affected.allSatisfy({ change.retainedBatches.contains($0) }),
                  change.retainedBatches.allSatisfy({ retained in
                      snapshot.batches.first(where: { $0.id == retained.id }).map { $0 == retained } ?? true
                  }) else {
                throw SessionStoreError.invalidState("输入修订必须完整保留受影响的原笔记批次")
            }
            snapshot.segments[index] = change.replacementSegment
            snapshot.inputRevision = change.toRevision
            snapshot.revisionHistory.append(change)
            let retiredIDs = Set(change.retainedBatches.map(\.id))
            snapshot.batches.removeAll { retiredIDs.contains($0.id) }
            snapshot.latestEvidenceIDs.subtract(change.retainedBatches.flatMap { $0.ids })
            if !affected.isEmpty { snapshot.notebookRevision += 1 }
            let remainingReferences = Set(snapshot.batches.flatMap { batch in
                batch.note.points.indices.map { "\(batch.id.uuidString):\($0)" }
            })
            snapshot.notebookLastOffered = snapshot.notebookLastOffered.filter { remainingReferences.contains($0.key) }
            for index in snapshot.generationCheckpoints.indices {
                if !snapshot.canResume(snapshot.generationCheckpoints[index]) {
                    snapshot.generationCheckpoints[index].invalidated = true
                }
            }
        }
        try snapshot.validate()
    }
}

enum SessionStoreError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalidState(String)
    case corruptSnapshot
    case corruptJournal(line: Int)
    case sequenceMismatch(expected: Int, found: Int)
    case incompleteJournalTail(bytes: Int)
    case missingSnapshot
    case staleSnapshot
    case identityConflict(String)
    case unsafePath(String)
    case io(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "课程使用不支持的存储版本 \(version)，原文件已保留。"
        case .invalidState(let reason): return "课程状态无效：\(reason)。"
        case .corruptSnapshot: return "课程快照损坏，已停止写入并保留原文件。"
        case .corruptJournal(let line): return "处理日志第 \(line) 行损坏，已停止恢复并保留原文件。"
        case let .sequenceMismatch(expected, found): return "处理日志顺序不完整：应为 \(expected)，实际为 \(found)。"
        case .incompleteJournalTail(let bytes): return "日志末尾有 \(bytes) 字节尚未写完整；继续前需先保留并恢复日志。"
        case .missingSnapshot: return "处理日志缺少对应课程快照，原文件已保留。"
        case .staleSnapshot: return "课程已被其他写入更新，请重新读取后保存。"
        case .identityConflict(let reason): return "课程身份冲突：\(reason)，已停止自动合并。"
        case .unsafePath(let path): return "课程路径不满足文件安全要求：\(path)。"
        case let .io(operation, code): return "课程文件操作失败（\(operation)，\(code)）。"
        }
    }
}

struct SessionLoadResult: Sendable {
    enum Origin: Sendable { case absent, snapshot, legacy }
    var snapshot: SessionSnapshot?
    var origin: Origin
    var incompleteTailBytes: Int = 0
    var legacyProvenanceUnavailable: Bool = false
    /// Informational only. Capture always needs a new explicit user action.
    var captureWasActive: Bool { snapshot?.processing.phase == .capturing }
}

/// All writers use a process lock and an advisory disk lock. Snapshot/journal
/// files stay untouched during reads. The injectable write is for fault tests.
final class SessionStore: @unchecked Sendable {
    static let snapshotFileName = "session-snapshot.json"
    static let journalFileName = "session-journal.jsonl"
    private static let processLock = NSLock()
    let directory: URL
    private let atomicWrite: @Sendable (Data, URL) throws -> Void
    private let journalWrite: @Sendable (Data, URL) throws -> Void
    private let legacySessionID: UUID

    init(directory: URL, legacySessionID: UUID = UUID(),
         atomicWrite: @escaping @Sendable (Data, URL) throws -> Void = SessionArchiveCoding.atomicWrite,
         journalWrite: @escaping @Sendable (Data, URL) throws -> Void = SessionArchiveCoding.appendAndSync) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.legacySessionID = legacySessionID
        self.atomicWrite = atomicWrite
        self.journalWrite = journalWrite
    }

    func load() throws -> SessionSnapshot? { try loadDetailed().snapshot }

    func loadDetailed() throws -> SessionLoadResult {
        try locked(writing: false) { try read().result }
    }

    @discardableResult
    func save(_ value: SessionSnapshot) throws -> SessionSnapshot {
        try locked(writing: true) {
            try value.validate()
            // UI state can retain pre-encoding Date fractions after a journal
            // append. Compare the same persisted representation on both sides,
            // keeping exact history/content checks instead of relaxing them.
            let snapshot = try SessionArchiveCoding.decode(SessionSnapshot.self,
                from: SessionArchiveCoding.encode(value))
            try snapshot.validate()
            let current = try read()
            guard current.result.incompleteTailBytes == 0 else {
                throw SessionStoreError.incompleteJournalTail(bytes: current.result.incompleteTailBytes)
            }
            if let stored = current.result.snapshot, current.result.origin == .snapshot {
                guard stored.sessionID == snapshot.sessionID else {
                    throw SessionStoreError.identityConflict("保存内容属于另一课程")
                }
                guard snapshot.storageRevision == stored.storageRevision,
                      snapshot.lastJournalSequence == stored.lastJournalSequence,
                      snapshot.lastJournalDigest == stored.lastJournalDigest else {
                    throw SessionStoreError.staleSnapshot
                }
                try Self.validatePreservation(from: stored, to: snapshot)
            } else {
                guard snapshot.storageRevision == 0, snapshot.lastJournalSequence == 0,
                      snapshot.lastJournalDigest == SessionArchiveCoding.genesisDigest else {
                    throw SessionStoreError.staleSnapshot
                }
                if let legacy = current.result.snapshot {
                    try Self.validatePreservation(from: legacy, to: snapshot)
                }
            }
            var saved = snapshot
            saved.storageRevision += 1
            saved.updatedAt = Date()
            let payload = try SessionArchiveCoding.encode(saved)
            let envelope = SnapshotEnvelope(schemaVersion: SessionSnapshot.currentSchemaVersion,
                                            payload: payload, checksum: SessionArchiveCoding.digest(payload))
            try atomicWrite(try SessionArchiveCoding.encode(envelope), directory.appendingPathComponent(Self.snapshotFileName))
            // Date's epoch conversion can round fractional timestamps. Return
            // exactly the value that subsequent readers will compare.
            return try SessionArchiveCoding.decode(SessionSnapshot.self, from: payload)
        }
    }

    @discardableResult
    func append(_ event: SessionJournalEvent, expectedRevision: Int? = nil) throws -> SessionSnapshot {
        try locked(writing: true) {
            let current = try read()
            guard current.result.origin == .snapshot, var snapshot = current.result.snapshot else {
                throw SessionStoreError.missingSnapshot
            }
            guard current.result.incompleteTailBytes == 0 else {
                throw SessionStoreError.incompleteJournalTail(bytes: current.result.incompleteTailBytes)
            }
            if let expectedRevision, expectedRevision != snapshot.storageRevision {
                throw SessionStoreError.staleSnapshot
            }
            let old = snapshot
            let row = try JournalRecord(sequence: old.lastJournalSequence + 1,
                                        sessionID: old.sessionID, baseStorageRevision: old.storageRevision,
                                        previousDigest: old.lastJournalDigest, event: event)
            let persistedEvent = try row.event(line: row.sequence)
            try persistedEvent.apply(to: &snapshot)
            try Self.validatePreservation(from: old, to: snapshot)
            var bytes = try SessionArchiveCoding.encode(row)
            bytes.append(0x0A)
            let url = directory.appendingPathComponent(Self.journalFileName)
            try journalWrite(bytes, url)
            snapshot.storageRevision += 1
            snapshot.lastJournalSequence = row.sequence
            snapshot.lastJournalDigest = row.checksum
            return snapshot
        }
    }

    /// Explicit repair only. The entire original journal is durably preserved,
    /// byte for byte, before replacing the active file with its verified prefix.
    @discardableResult
    func preserveIncompleteTailAndResume() throws -> URL? {
        try locked(writing: true) {
            let state = try read()
            guard state.result.incompleteTailBytes > 0 else { return nil }
            let journal = directory.appendingPathComponent(Self.journalFileName)
            let original = try Data(contentsOf: journal)
            guard original == state.journalData else { throw SessionStoreError.staleSnapshot }
            let backup = directory.appendingPathComponent("session-journal.incomplete-\(UUID().uuidString).jsonl")
            try atomicWrite(original, backup)
            guard try Data(contentsOf: backup) == original,
                  try Data(contentsOf: journal) == original else { throw SessionStoreError.staleSnapshot }
            try atomicWrite(original.prefix(state.validJournalBytes), journal)
            return backup
        }
    }

    private struct SnapshotEnvelope: Codable {
        let schemaVersion: Int
        let payload: Data
        let checksum: String
    }

    private struct JournalRecord: Codable {
        var schemaVersion: Int = 1
        let sequence: Int
        let sessionID: UUID
        let baseStorageRevision: Int
        let previousDigest: String
        let payload: Data
        let checksum: String

        init(sequence: Int, sessionID: UUID, baseStorageRevision: Int,
             previousDigest: String, event: SessionJournalEvent) throws {
            self.sequence = sequence; self.sessionID = sessionID
            self.baseStorageRevision = baseStorageRevision; self.previousDigest = previousDigest
            self.payload = try SessionArchiveCoding.encode(event)
            self.checksum = Self.digest(version: 1, sequence: sequence, sessionID: sessionID,
                                        revision: baseStorageRevision, previous: previousDigest, payload: payload)
        }

        static func digest(version: Int, sequence: Int, sessionID: UUID, revision: Int,
                           previous: String, payload: Data) -> String {
            var bytes = Data("LiveLingo-journal-\(version)\n\(sequence)\n\(sessionID.uuidString)\n\(revision)\n\(previous)\n".utf8)
            bytes.append(payload)
            return SessionArchiveCoding.digest(bytes)
        }

        func event(line: Int) throws -> SessionJournalEvent {
            guard schemaVersion == 1 else { throw SessionStoreError.unsupportedSchema(schemaVersion) }
            guard sequence > 0, sequence < Int.max, baseStorageRevision > 0, baseStorageRevision < Int.max,
                  checksum == Self.digest(version: schemaVersion, sequence: sequence, sessionID: sessionID,
                                          revision: baseStorageRevision, previous: previousDigest, payload: payload) else {
                throw SessionStoreError.corruptJournal(line: line)
            }
            do { return try SessionArchiveCoding.decode(SessionJournalEvent.self, from: payload) }
            catch { throw SessionStoreError.corruptJournal(line: line) }
        }
    }

    private struct ReadState {
        var result: SessionLoadResult
        var journalData: Data = Data()
        var validJournalBytes: Int = 0
    }

    private func read() throws -> ReadState {
        let snapshotURL = directory.appendingPathComponent(Self.snapshotFileName)
        let journalURL = directory.appendingPathComponent(Self.journalFileName)
        try SessionArchiveCoding.requireRegularFileIfPresent(snapshotURL)
        try SessionArchiveCoding.requireRegularFileIfPresent(journalURL)
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            guard !FileManager.default.fileExists(atPath: journalURL.path) else { throw SessionStoreError.missingSnapshot }
            let legacy = try readLegacy()
            return ReadState(result: .init(snapshot: legacy, origin: legacy == nil ? .absent : .legacy,
                                           legacyProvenanceUnavailable: legacy != nil))
        }
        let data = try Data(contentsOf: snapshotURL)
        try SessionArchiveCoding.checkSchema(data)
        var snapshot: SessionSnapshot
        do {
            let envelope = try SessionArchiveCoding.decode(SnapshotEnvelope.self, from: data)
            guard envelope.checksum == SessionArchiveCoding.digest(envelope.payload) else {
                throw SessionStoreError.corruptSnapshot
            }
            try SessionArchiveCoding.checkSchema(envelope.payload)
            snapshot = try SessionArchiveCoding.decode(SessionSnapshot.self, from: envelope.payload)
            try snapshot.validate()
        } catch let error as SessionStoreError { throw error }
        catch { throw SessionStoreError.corruptSnapshot }
        let checkpointSequence = snapshot.lastJournalSequence
        let checkpointDigest = snapshot.lastJournalDigest
        let bytes = FileManager.default.fileExists(atPath: journalURL.path) ? try Data(contentsOf: journalURL) : Data()
        var position = bytes.startIndex
        var sequence = 0
        var digest = SessionArchiveCoding.genesisDigest
        var tailCount = 0
        while position < bytes.endIndex {
            guard let newline = bytes[position...].firstIndex(of: 0x0A) else {
                let tail = Data(bytes[position...])
                guard SessionJSONPrefix.isObjectPrefix(tail) else { throw SessionStoreError.corruptJournal(line: sequence + 1) }
                // A complete but invalid record is corruption, even without LF.
                if (try? JSONSerialization.jsonObject(with: tail)) != nil {
                    try SessionArchiveCoding.checkSchema(tail)
                    guard let row = try? SessionArchiveCoding.decode(JournalRecord.self, from: tail) else {
                        throw SessionStoreError.corruptJournal(line: sequence + 1)
                    }
                    let event = try row.event(line: sequence + 1)
                    guard row.sequence == sequence + 1, row.previousDigest == digest,
                          row.sessionID == snapshot.sessionID else { throw SessionStoreError.corruptJournal(line: sequence + 1) }
                    if row.sequence > checkpointSequence {
                        guard row.baseStorageRevision == snapshot.storageRevision else {
                            throw SessionStoreError.corruptJournal(line: sequence + 1)
                        }
                        var preview = snapshot
                        try event.apply(to: &preview)
                        try Self.validatePreservation(from: snapshot, to: preview)
                    }
                }
                tailCount = tail.count
                break
            }
            let line = Data(bytes[position..<newline])
            try SessionArchiveCoding.checkSchema(line, journalLine: sequence + 1)
            guard let row = try? SessionArchiveCoding.decode(JournalRecord.self, from: line) else {
                throw SessionStoreError.corruptJournal(line: sequence + 1)
            }
            let event = try row.event(line: sequence + 1)
            guard row.sequence == sequence + 1 else {
                throw SessionStoreError.sequenceMismatch(expected: sequence + 1, found: row.sequence)
            }
            guard row.sessionID == snapshot.sessionID, row.previousDigest == digest else {
                throw SessionStoreError.corruptJournal(line: sequence + 1)
            }
            sequence = row.sequence; digest = row.checksum
            if sequence == checkpointSequence, digest != checkpointDigest {
                throw SessionStoreError.corruptSnapshot
            }
            if sequence > checkpointSequence {
                guard row.baseStorageRevision == snapshot.storageRevision else { throw SessionStoreError.staleSnapshot }
                let old = snapshot
                try event.apply(to: &snapshot)
                try Self.validatePreservation(from: old, to: snapshot)
                snapshot.storageRevision += 1
                snapshot.lastJournalSequence = sequence
                snapshot.lastJournalDigest = digest
            }
            position = bytes.index(after: newline)
        }
        guard sequence >= checkpointSequence,
              checkpointSequence != 0 || checkpointDigest == SessionArchiveCoding.genesisDigest else {
            throw SessionStoreError.corruptSnapshot
        }
        return ReadState(result: .init(snapshot: snapshot, origin: .snapshot, incompleteTailBytes: tailCount),
                         journalData: bytes, validJournalBytes: position)
    }

    private func readLegacy() throws -> SessionSnapshot? {
        let jsonl = directory.appendingPathComponent("bilingual.jsonl")
        let markdown = directory.appendingPathComponent("summary-zh-Hans.md")
        try SessionArchiveCoding.requireRegularFileIfPresent(jsonl)
        try SessionArchiveCoding.requireRegularFileIfPresent(markdown)
        let hasJSONL = FileManager.default.fileExists(atPath: jsonl.path)
        let hasMarkdown = FileManager.default.fileExists(atPath: markdown.path)
        guard hasJSONL || hasMarkdown else { return nil }
        var segments: [TranscriptSegment] = []
        if hasJSONL {
            let text = try String(contentsOf: jsonl, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                if line.isEmpty && (index == lines.count - 1 || lines.count == 2 && lines.allSatisfy(\.isEmpty)) { continue }
                do {
                    segments.append(try SessionArchiveCoding.decode(TranscriptSegment.self, from: Data(line.utf8)))
                } catch { throw SessionStoreError.corruptJournal(line: index + 1) }
            }
        }
        let ids = Set(segments.compactMap(\.sessionID))
        guard ids.count <= 1 else { throw SessionStoreError.identityConflict("旧字幕包含多个会话标识") }
        let summary = hasMarkdown ? try String(contentsOf: markdown, encoding: .utf8) : nil
        let date = (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let snapshot = SessionSnapshot(sessionID: ids.first ?? legacySessionID,
                                       inputRevision: segments.map(\.inputRevision).max() ?? 0,
                                       segments: segments, legacyMarkdown: summary, createdAt: date)
        try snapshot.validate()
        return snapshot
    }

    static func validatePreservation(from old: SessionSnapshot, to new: SessionSnapshot) throws {
        guard new.inputRevision >= old.inputRevision,
              old.revisionHistory.allSatisfy({ new.revisionHistory.contains($0) }),
              old.legacyMarkdown == nil || new.legacyMarkdown == old.legacyMarkdown else {
            throw SessionStoreError.invalidState("保存会丢失已有正文或修订记录")
        }
        let retained = new.revisionHistory.flatMap(\.retainedBatches)
        for batch in old.batches {
            guard new.batches.contains(batch) || retained.contains(batch) else {
                throw SessionStoreError.invalidState("已有笔记批次必须保留或记入修订历史")
            }
        }
        for segment in old.segments {
            guard let next = new.segments.first(where: { $0.id == segment.id }) else {
                throw SessionStoreError.invalidState("保存会丢失已有字幕")
            }
            let changedInput = segment.english != next.english || segment.startTime != next.startTime
                || segment.endTime != next.endTime || segment.inputRevision != next.inputRevision
            let changedTranslation = segment.hasUsableTranslation
                && (next.chinese != segment.chinese || !next.hasUsableTranslation)
            if changedInput || changedTranslation {
                guard new.inputRevision > old.inputRevision,
                      new.revisionHistory.contains(where: { $0.previousSegment == segment && $0.toRevision > old.inputRevision }) else {
                    throw SessionStoreError.invalidState("正文改动缺少原文修订记录")
                }
                let changes = new.revisionHistory.filter { $0.previousSegment.id == segment.id && $0.toRevision > old.inputRevision }
                    .sorted { $0.toRevision < $1.toRevision }
                var cursor = segment
                for change in changes {
                    guard Self.samePreservedInput(cursor, change.previousSegment) else {
                        throw SessionStoreError.invalidState("修订记录与保留的正文不连续")
                    }
                    cursor = change.replacementSegment
                }
                guard Self.samePreservedInput(cursor, next) else {
                    throw SessionStoreError.invalidState("当前正文与最后一条修订不一致")
                }
            }
        }
        for checkpoint in old.generationCheckpoints {
            if let next = new.generationCheckpoints.first(where: { $0.id == checkpoint.id }) {
                try next.validateContinuation(from: checkpoint)
            }
        }
    }

    private static func samePreservedInput(_ old: TranscriptSegment, _ new: TranscriptSegment) -> Bool {
        old.id == new.id && old.english == new.english && old.startTime == new.startTime
            && old.endTime == new.endTime && old.inputRevision == new.inputRevision
            && (!old.hasUsableTranslation || old.chinese == new.chinese && new.hasUsableTranslation)
    }

    private func locked<T>(writing: Bool, _ action: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        if writing { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let lockURL = directory.appendingPathComponent(".session-store.lock")
        try SessionArchiveCoding.requireRegularFileIfPresent(lockURL)
        let flags = (writing ? O_RDWR | O_CREAT : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW
        let fd = Darwin.open(lockURL.path, flags, 0o600)
        if fd < 0 {
            if !writing && errno == ENOENT { return try action() }
            throw SessionStoreError.io(operation: "open lock", code: errno)
        }
        defer { _ = Darwin.close(fd) }
        guard flock(fd, writing ? LOCK_EX : LOCK_SH) == 0 else {
            throw SessionStoreError.io(operation: "lock", code: errno)
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try action()
    }
}

enum SessionArchiveCoding {
    static let genesisDigest = String(repeating: "0", count: 64)
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Double.self) { return Date(timeIntervalSince1970: number / 1_000) }
            let text = try value.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid stored date")
        }
        return try decoder.decode(type, from: data)
    }
    static func checkSchema(_ data: Data, journalLine: Int? = nil) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else {
            if let journalLine { throw SessionStoreError.corruptJournal(line: journalLine) }
            throw SessionStoreError.corruptSnapshot
        }
        guard number.intValue == SessionSnapshot.currentSchemaVersion else {
            throw SessionStoreError.unsupportedSchema(number.intValue)
        }
    }
    static func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SessionStoreError.unsafePath(path)
        }
    }
    static func requireRegularFileIfPresent(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return }
            throw SessionStoreError.io(operation: "lstat", code: errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw SessionStoreError.unsafePath(url.path) }
    }
    static func atomicWrite(_ data: Data, _ destination: URL) throws {
        try requireRegularFileIfPresent(destination)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".session-write-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SessionStoreError.io(operation: "create snapshot", code: errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw SessionStoreError.io(operation: "replace snapshot", code: errno)
        }
        try syncDirectory(destination.deletingLastPathComponent())
    }
    static func appendAndSync(_ data: Data, _ destination: URL) throws {
        try requireRegularFileIfPresent(destination)
        let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SessionStoreError.io(operation: "open journal", code: errno) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try syncDirectory(destination.deletingLastPathComponent())
    }
    static func syncDirectory(_ directory: URL) throws {
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard directoryFD >= 0 else { throw SessionStoreError.io(operation: "open snapshot directory", code: errno) }
        defer { _ = Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw SessionStoreError.io(operation: "sync snapshot directory", code: errno) }
    }
}

/// A grammar check distinguishes a truncated JSON object from arbitrary bytes.
/// Journal records contain only ASCII envelope fields and base64 payloads.
private struct SessionJSONPrefix {
    private enum End: Error { case incomplete, invalid }
    private var bytes: [UInt8]
    private var index = 0
    static func isObjectPrefix(_ data: Data) -> Bool {
        var parser = Self(bytes: Array(data))
        parser.whitespace()
        guard parser.index < parser.bytes.count, parser.bytes[parser.index] == 123 else { return false }
        do {
            try parser.value(depth: 0)
            parser.whitespace()
            return parser.index == parser.bytes.count
        } catch End.incomplete { return true }
        catch { return false }
    }
    private mutating func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    private mutating func next() throws -> UInt8 {
        guard index < bytes.count else { throw End.incomplete }
        return bytes[index]
    }
    private mutating func consume(_ byte: UInt8) throws {
        guard try next() == byte else { throw End.invalid }
        index += 1
    }
    private mutating func value(depth: Int) throws {
        guard depth < 64 else { throw End.invalid }
        whitespace()
        switch try next() {
        case 123:
            index += 1; whitespace()
            if try next() == 125 { index += 1; return }
            while true {
                try string(); whitespace(); try consume(58); try value(depth: depth + 1); whitespace()
                if try next() == 125 { index += 1; return }
                try consume(44); whitespace()
            }
        case 91:
            index += 1; whitespace()
            if try next() == 93 { index += 1; return }
            while true {
                try value(depth: depth + 1); whitespace()
                if try next() == 93 { index += 1; return }
                try consume(44)
            }
        case 34: try string()
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        case 45, 48...57: try number()
        default: throw End.invalid
        }
    }
    private mutating func string() throws {
        try consume(34)
        while true {
            let byte = try next(); index += 1
            if byte == 34 { return }
            guard byte >= 32, byte < 128 else { throw End.invalid }
            if byte == 92 {
                let escape = try next(); index += 1
                if escape == 117 {
                    for _ in 0..<4 {
                        let hex = try next()
                        guard (48...57).contains(hex) || (65...70).contains(hex) || (97...102).contains(hex) else { throw End.invalid }
                        index += 1
                    }
                } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escape) { throw End.invalid }
            }
        }
    }
    private mutating func literal(_ text: String) throws { for byte in text.utf8 { try consume(byte) } }
    private mutating func number() throws {
        if try next() == 45 { index += 1 }
        if try next() == 48 { index += 1 }
        else {
            guard (49...57).contains(try next()) else { throw End.invalid }
            repeat { index += 1 } while index < bytes.count && (48...57).contains(bytes[index])
        }
        if index < bytes.count && bytes[index] == 46 {
            index += 1
            guard (48...57).contains(try next()) else { throw End.invalid }
            repeat { index += 1 } while index < bytes.count && (48...57).contains(bytes[index])
        }
        if index < bytes.count && [69, 101].contains(bytes[index]) {
            index += 1
            if [43, 45].contains(try next()) { index += 1 }
            guard (48...57).contains(try next()) else { throw End.invalid }
            repeat { index += 1 } while index < bytes.count && (48...57).contains(bytes[index])
        }
    }
}

struct SessionDirectoryIdentity: Equatable, Sendable {
    let directory: URL
    let sessionID: UUID?
    let inputRevision: Int?
    let inputFingerprint: String

    static func resolve(directory: URL, bookmark: Data? = nil) throws -> Self {
        var location = directory.standardizedFileURL.resolvingSymlinksInPath()
        if let bookmark {
            var stale = false
            let bookmarked = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale)
                .standardizedFileURL.resolvingSymlinksInPath()
            if FileManager.default.fileExists(atPath: location.path), location != bookmarked {
                throw SessionStoreError.identityConflict("路径与书签指向不同目录")
            }
            location = bookmarked
        }
        guard try location.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw SessionStoreError.unsafePath(location.path)
        }
        let result = try SessionStore(directory: location).loadDetailed()
        if let snapshot = result.snapshot, result.origin == .snapshot {
            guard result.incompleteTailBytes == 0 else {
                throw SessionStoreError.incompleteJournalTail(bytes: result.incompleteTailBytes)
            }
            return Self(directory: location, sessionID: snapshot.sessionID, inputRevision: snapshot.inputRevision,
                        inputFingerprint: try snapshot.inputFingerprint())
        }
        // A legacy directory has no asserted UUID until explicitly saved.
        var bytes = Data()
        for name in ["bilingual.jsonl", "summary-zh-Hans.md"] {
            let path = location.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) {
                bytes.append(Data(name.utf8)); bytes.append(0)
                bytes.append(Data(SessionArchiveCoding.digest(try Data(contentsOf: path)).utf8))
            }
        }
        return Self(directory: location, sessionID: nil, inputRevision: nil,
                    inputFingerprint: SessionArchiveCoding.digest(bytes))
    }

    func assertCompatible(with other: Self) throws {
        guard sessionID == other.sessionID, inputRevision == other.inputRevision,
              inputFingerprint == other.inputFingerprint,
              sessionID != nil || directory == other.directory else {
            throw SessionStoreError.identityConflict("目录副本的身份、修订号或内容不一致")
        }
    }
}
