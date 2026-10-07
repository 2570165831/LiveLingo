import Foundation
import CryptoKit
import Darwin

struct CaptureGap: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    let sessionID: UUID
    let lastWrittenFrame: Int64
    let sampleRate: Double
    /// Uptime observations, deliberately separate from positions in the WAV.
    let observedStart: TimeInterval
    let observedEnd: TimeInterval
    let rejectedFrames: Int64?
    let reason: String
    var lastWrittenTime: TimeInterval { Double(lastWrittenFrame) / sampleRate }
}

struct TranscriptionWorkRecord: Codable, Sendable, Equatable, Identifiable {
    enum Status: String, Codable, Sendable {
        case pending, active, retryWaiting, manualPending, completed, silent, failed
        /// Terminal, never retried automatically: neither the enhanced English pass
        /// nor the fallback produced accepted English, and the fallback heard
        /// Han-dominant speech. Audio is kept; manual retry works.
        case otherLanguage

        /// What 0.2.0 understands. Newer statuses are written as this plus
        /// `extendedStatus`, so an older build still decodes the whole journal.
        var legacy: Status { self == .otherLanguage ? .failed : self }
    }
    enum Attempt: String, Codable, Sendable { case initial, automaticRetry, manual }
    /// Why the latest attempt produced no accepted English. A fixed set of
    /// identifiers only; recognizer text is never persisted here.
    enum FailureReason: String, Codable, Sendable {
        case englishGateHanDominant, englishGateNoLatin, emptyOutput, invalidText
        case repeatedLoop, runawayText, error
        /// The attempt did not finish: reopened after quitting, paused, or yielded to captions.
        case interrupted

        /// Mirrors `SpeechPipeline.preferredTranscript`; nil when the text is accepted.
        static func rejection(of text: String, audioDuration: TimeInterval) -> FailureReason? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .emptyOutput }
            switch EnglishTranscriptGate.verdict(trimmed) {
            case .hanDominant: return .englishGateHanDominant
            case .noLatin: return .englishGateNoLatin
            case .accepted: break
            }
            switch ASRQualityGate.fallbackReason(for: trimmed, audioDuration: audioDuration) {
            case nil, .implausiblyShort: return nil
            case .emptyTranscript: return .emptyOutput
            case .invalidText: return .invalidText
            case .repeatedLoop: return .repeatedLoop
            case .runawayText: return .runawayText
            }
        }
    }
    let id: UUID
    let sessionID: UUID
    let ordinal: Int
    /// Relative to the journal directory, so moving a complete session is safe.
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
    var recordingFile: String? = nil
    /// Only true after exact PCM comparison against the sealed session WAV.
    /// The original range can then be materialized for an explicit later retry.
    var audioRetired: Bool? = nil
    var status: Status = .pending
    var attempt: Attempt = .initial
    var automaticRetryCount = 0
    var manualRetryCount = 0
    var text: String?
    var textLanguage: String?
    var candidateText: String?
    var candidateLanguage: String?
    var candidateOrigin: String?
    var failure: String?
    var failureReason: FailureReason?
    var duration: TimeInterval { max(0, end - start) }
    var needsWork: Bool { [.pending, .active, .retryWaiting, .manualPending].contains(status) }
    /// An unfinished manual retry of non-English speech heard nothing new, so
    /// that terminal verdict stands. With a fallback model, this reason otherwise
    /// only remains on a chunk awaiting its first automatic retry, which offers
    /// no manual retry.
    var interruptedRetryStaysOtherLanguage: Bool {
        attempt == .manual && failureReason == .englishGateHanDominant && fallbackModelKey != nil
    }
}

extension TranscriptionWorkRecord {
    // Same keys and optionality as the synthesized coding of 0.2.0, plus
    // optional keys it ignores. Unknown values from a newer build degrade to
    // the legacy status and to no reason instead of failing the journal.
    private enum CodingKeys: String, CodingKey {
        case id, sessionID, ordinal, audioFile, startFrame, endFrame, sampleRate, start, end
        case captureStart, captureEnd, modelKey, fallbackModelKey, appleEvidence, recordingFile, audioRetired
        case status, extendedStatus, attempt, automaticRetryCount, manualRetryCount
        case text, textLanguage, candidateText, candidateLanguage, candidateOrigin, failure, failureReason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), sessionID: try c.decode(UUID.self, forKey: .sessionID),
            ordinal: try c.decode(Int.self, forKey: .ordinal), audioFile: try c.decode(String.self, forKey: .audioFile),
            startFrame: try c.decode(Int64.self, forKey: .startFrame), endFrame: try c.decode(Int64.self, forKey: .endFrame),
            sampleRate: try c.decode(Double.self, forKey: .sampleRate),
            start: try c.decode(TimeInterval.self, forKey: .start), end: try c.decode(TimeInterval.self, forKey: .end),
            captureStart: try c.decodeIfPresent(TimeInterval.self, forKey: .captureStart),
            captureEnd: try c.decodeIfPresent(TimeInterval.self, forKey: .captureEnd),
            modelKey: try c.decode(String.self, forKey: .modelKey),
            fallbackModelKey: try c.decodeIfPresent(String.self, forKey: .fallbackModelKey),
            appleEvidence: try c.decode(String.self, forKey: .appleEvidence),
            recordingFile: try c.decodeIfPresent(String.self, forKey: .recordingFile),
            audioRetired: try c.decodeIfPresent(Bool.self, forKey: .audioRetired))
        status = try c.decodeIfPresent(String.self, forKey: .extendedStatus).flatMap(Status.init(rawValue:))
            ?? c.decode(Status.self, forKey: .status)
        attempt = try c.decode(Attempt.self, forKey: .attempt)
        automaticRetryCount = try c.decode(Int.self, forKey: .automaticRetryCount)
        manualRetryCount = try c.decode(Int.self, forKey: .manualRetryCount)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        let storedLanguage = try c.decodeIfPresent(String.self, forKey: .textLanguage)
        textLanguage = SpokenLanguage.nonEnglishCode(storedLanguage)
        if storedLanguage == nil, status == .completed,
           let text, EnglishTranscriptGate.verdict(text) == .hanDominant { textLanguage = "zh" }
        candidateText = try c.decodeIfPresent(String.self, forKey: .candidateText)
        candidateLanguage = SpokenLanguage.nonEnglishCode(try c.decodeIfPresent(String.self, forKey: .candidateLanguage))
        candidateOrigin = try c.decodeIfPresent(String.self, forKey: .candidateOrigin)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason).flatMap(FailureReason.init(rawValue:))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(sessionID, forKey: .sessionID)
        try c.encode(ordinal, forKey: .ordinal); try c.encode(audioFile, forKey: .audioFile)
        try c.encode(startFrame, forKey: .startFrame); try c.encode(endFrame, forKey: .endFrame)
        try c.encode(sampleRate, forKey: .sampleRate); try c.encode(start, forKey: .start); try c.encode(end, forKey: .end)
        try c.encodeIfPresent(captureStart, forKey: .captureStart); try c.encodeIfPresent(captureEnd, forKey: .captureEnd)
        try c.encode(modelKey, forKey: .modelKey); try c.encodeIfPresent(fallbackModelKey, forKey: .fallbackModelKey)
        try c.encode(appleEvidence, forKey: .appleEvidence)
        try c.encodeIfPresent(recordingFile, forKey: .recordingFile); try c.encodeIfPresent(audioRetired, forKey: .audioRetired)
        try c.encode(status.legacy, forKey: .status)
        if status != status.legacy { try c.encode(status.rawValue, forKey: .extendedStatus) }
        try c.encode(attempt, forKey: .attempt)
        try c.encode(automaticRetryCount, forKey: .automaticRetryCount); try c.encode(manualRetryCount, forKey: .manualRetryCount)
        try c.encodeIfPresent(text, forKey: .text); try c.encodeIfPresent(candidateText, forKey: .candidateText)
        try c.encodeIfPresent(SpokenLanguage.nonEnglishCode(textLanguage), forKey: .textLanguage)
        try c.encodeIfPresent(SpokenLanguage.nonEnglishCode(candidateLanguage), forKey: .candidateLanguage)
        try c.encodeIfPresent(candidateOrigin, forKey: .candidateOrigin); try c.encodeIfPresent(failure, forKey: .failure)
        try c.encodeIfPresent(failureReason?.rawValue, forKey: .failureReason)
    }
}

struct TranscriptionProcessingState: Sendable, Equatable {
    let sessionID: UUID
    let isCapturing: Bool
    let isPaused: Bool
    let activeCount: Int
    let pendingCount: Int
    let backlogSeconds: TimeInterval
    let unresolvedCount: Int
    /// Terminal non-English chunks without a pending candidate. Disjoint from
    /// `unresolvedCount`: nothing is pending or failed.
    var otherLanguageCount = 0
    /// Audio is opened on demand; no waiting task retains decoded audio.
    let prefetchedCount: Int = 0
}

/// Written before opening each audio file. One marker per uncommitted chunk
/// survives a crash between writer close, next-chunk creation, and journal append.
struct CaptureChunkDescriptor: Codable, Sendable {
    let id: UUID
    let sessionID: UUID
    let ordinal: Int
    let audioFile: String
    let recordingFile: String?
    let startFrame: Int64
    let sampleRate: Double
    let modelKey: String
    let fallbackModelKey: String?
}

/// One checksummed mutation per line. A snapshot is an acceleration aid; the
/// ordered journal remains work truth. No classroom text is written to OSLog.
final class DurableTranscriptionJournal: @unchecked Sendable {
    static let directoryName = "durable-transcription"
    static let maximumAutomaticRetries = 2
    enum JournalError: LocalizedError {
        case corrupt(String), sessionMismatch, invalidRange, duplicateIdentity, unsafePath
        var errorDescription: String? {
            switch self {
            case .corrupt(let detail): return "转写工作记录损坏，原文件已保留：\(detail)"
            case .sessionMismatch: return "转写工作记录属于另一个会话。"
            case .invalidRange: return "转写片段的帧范围或时间范围无效。"
            case .duplicateIdentity: return "同一转写片段 ID 对应不同音频范围。"
            case .unsafePath: return "转写工作记录包含目录外的音频路径。"
            }
        }
    }
    private struct State: Codable {
        var version = 1
        let sessionID: UUID
        var sequence = 0
        var paused = false
        var capturing = false
        var records: [TranscriptionWorkRecord] = []
        var gaps: [CaptureGap] = []
    }
    private struct Mutation: Codable {
        let version: Int
        let sessionID: UUID
        let sequence: Int
        var record: TranscriptionWorkRecord?
        var gap: CaptureGap?
        var paused: Bool?
        var capturing: Bool?
    }
    private struct Envelope: Codable {
        let payload: Data
        let sha256: String
        init<T: Encodable>(_ value: T) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            payload = try encoder.encode(value)
            sha256 = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        }
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            let actual = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            guard actual == sha256 else { throw JournalError.corrupt("校验和不匹配") }
            return try JSONDecoder().decode(type, from: payload)
        }
    }
    let directory: URL
    let sessionID: UUID
    private let lock = NSRecursiveLock()
    private var state: State
    private var index: [UUID: Int] = [:]
    private let sessionRoot: SensitiveFileIO.Directory
    private let workRoot: SensitiveFileIO.Directory
    private(set) var recoveredTruncatedTail = false

    init(sessionDirectory: URL, sessionID: UUID) throws {
        self.sessionID = sessionID
        directory = sessionDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
        state = State(sessionID: sessionID)
        let root = try Self.privateIO {
            try SensitiveFileIO.Directory.open(at: sessionDirectory, create: true, tighten: true)
        }
        sessionRoot = root
        workRoot = try Self.privateIO { try root.subdirectory(named: Self.directoryName) }
        if let data = try Self.privateIO({ try workRoot.readIfPresent(named: "snapshot.json") }) {
            do {
                state = try JSONDecoder().decode(Envelope.self, from: data).decode(State.self)
            } catch { throw JournalError.corrupt("快照：\(error.localizedDescription)") }
            guard state.version == 1 else { throw JournalError.corrupt("不支持的快照版本") }
            guard state.sessionID == sessionID else { throw JournalError.sessionMismatch }
        }
        try rebuildIndex()
        if let data = try Self.privateIO({ try workRoot.readIfPresent(named: "work.jsonl") }) {
            let completeEnd = data.lastIndex(of: 0x0a).map { $0 + 1 } ?? 0
            var previousSequence = 0
            // Validate every complete row, including rows covered by snapshot.
            for row in data.prefix(completeEnd).split(separator: 0x0a, omittingEmptySubsequences: false).dropLast() {
                let change: Mutation
                do { change = try JSONDecoder().decode(Envelope.self, from: Data(row)).decode(Mutation.self) }
                catch { throw JournalError.corrupt("日志第 \(previousSequence + 1) 条：\(error.localizedDescription)") }
                guard change.version == 1, change.sessionID == sessionID,
                      change.sequence == previousSequence + 1 else {
                    throw JournalError.corrupt("日志序号或会话身份不连续")
                }
                previousSequence = change.sequence
                if change.sequence > state.sequence { try validate(change); apply(change) }
            }
            guard previousSequence >= state.sequence else { throw JournalError.corrupt("日志短于快照") }
            if completeEnd < data.count {
                // Preserve the incomplete bytes before repairing only the tail.
                let savedTail = "truncated-tail-\(UUID().uuidString).bin"
                try Self.privateIO {
                    try workRoot.atomicWrite(Data(data.suffix(from: completeEnd)), named: savedTail, requireAbsent: true)
                    try workRoot.truncate(named: "work.jsonl", to: UInt64(completeEnd))
                }
                recoveredTruncatedTail = true
            }
        } else if state.sequence > 0 { throw JournalError.corrupt("缺少工作日志") }
        for record in state.records { try validateRecord(record) }
        // Recording always requires a deliberate new start after reopening.
        if state.capturing { try setCapturing(false) }
        for var record in state.records where record.status == .active {
            if record.interruptedRetryStaysOtherLanguage { record.status = .otherLanguage; try put(record); continue }
            record.status = record.attempt == .automaticRetry
                ? (record.automaticRetryCount < Self.maximumAutomaticRetries ? .retryWaiting : .failed)
                : (record.attempt == .manual ? .failed : .retryWaiting)
            record.failure = "上次转写未完成；保留已消耗的自动重试次数。"
            record.failureReason = .interrupted
            try put(record)
        }
        if state.sequence == 0 { try setPaused(false) }
    }

    private static func privateIO<T>(_ action: () throws -> T) throws -> T {
        do { return try action() }
        catch SensitiveFileIO.Failure.unsafePath { throw JournalError.unsafePath }
        catch SensitiveFileIO.Failure.system(_, let code) {
            if code == ELOOP || code == ENOTDIR { throw JournalError.unsafePath }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private func rebuildIndex() throws {
        for (offset, record) in state.records.enumerated() {
            guard index.updateValue(offset, forKey: record.id) == nil else { throw JournalError.duplicateIdentity }
        }
    }
    private func validateRecord(_ record: TranscriptionWorkRecord) throws {
        guard record.sessionID == sessionID else { throw JournalError.sessionMismatch }
        guard record.startFrame >= 0, record.endFrame > record.startFrame,
              record.sampleRate.isFinite, record.sampleRate > 0,
              record.start.isFinite, record.end.isFinite, record.start >= 0, record.end > record.start,
              abs(Double(record.startFrame) / record.sampleRate - record.start) <= 1 / record.sampleRate + 0.000001,
              abs(Double(record.endFrame) / record.sampleRate - record.end) <= 1 / record.sampleRate + 0.000001,
              (0...Self.maximumAutomaticRetries).contains(record.automaticRetryCount) else { throw JournalError.invalidRange }
        guard !record.audioFile.isEmpty, record.audioFile == URL(fileURLWithPath: record.audioFile).lastPathComponent,
              record.audioFile != ".", record.audioFile != ".." else { throw JournalError.unsafePath }
        if let recording = record.recordingFile {
            guard !recording.isEmpty, recording == URL(fileURLWithPath: recording).lastPathComponent,
                  recording != ".", recording != ".." else { throw JournalError.unsafePath }
        }
    }
    private func validate(_ change: Mutation) throws {
        guard change.sequence == state.sequence + 1 else { throw JournalError.corrupt("快照与日志序号不连续") }
        if let record = change.record {
            try validateRecord(record)
            if let i = index[record.id] {
                let old = state.records[i]
                guard old.startFrame == record.startFrame, old.endFrame == record.endFrame,
                      old.sampleRate == record.sampleRate, old.audioFile == record.audioFile,
                      old.ordinal == record.ordinal else { throw JournalError.duplicateIdentity }
            }
        }
        if let gap = change.gap {
            guard gap.sessionID == sessionID, gap.observedStart.isFinite, gap.observedEnd.isFinite,
                  gap.observedEnd >= gap.observedStart, gap.sampleRate > 0 else { throw JournalError.invalidRange }
        }
    }
    private func apply(_ change: Mutation) {
        if let record = change.record {
            if let i = index[record.id] { state.records[i] = record }
            else { index[record.id] = state.records.count; state.records.append(record) }
        }
        if let gap = change.gap { state.gaps.append(gap) }
        if let paused = change.paused { state.paused = paused }
        if let capturing = change.capturing { state.capturing = capturing }
        state.sequence = change.sequence
    }
    private func append(record: TranscriptionWorkRecord? = nil, gap: CaptureGap? = nil,
                        paused: Bool? = nil, capturing: Bool? = nil) throws {
        let change = Mutation(version: 1, sessionID: sessionID, sequence: state.sequence + 1,
                              record: record, gap: gap, paused: paused, capturing: capturing)
        try validate(change)
        var data = try JSONEncoder().encode(Envelope(change)); data.append(0x0a)
        try Self.privateIO {
            if try workRoot.requireRegularFileIfPresent(named: "work.jsonl") {
                try workRoot.append(data, named: "work.jsonl")
            } else {
                try workRoot.atomicWrite(data, named: "work.jsonl", requireAbsent: true)
            }
        }
        apply(change)
        if state.sequence % 128 == 0 { try checkpoint() }
    }
    func checkpoint() throws {
        try lock.withLock {
            let data = try JSONEncoder().encode(Envelope(state))
            try Self.privateIO { try workRoot.atomicWrite(data, named: "snapshot.json") }
        }
    }
    static func stageCapture(_ descriptor: CaptureChunkDescriptor, directory: URL) throws {
        let name = "capture-" + descriptor.id.uuidString + ".json"
        let data = try JSONEncoder().encode(Envelope(descriptor))
        do {
            try Self.privateIO {
                let root = try SensitiveFileIO.Directory.open(at: directory, create: false, tighten: true)
                try root.atomicWrite(data, named: name, requireAbsent: true)
            }
        } catch let error as POSIXError where error.code == .EEXIST {
            throw JournalError.duplicateIdentity
        }
    }
    func clearCaptureMarker(id: UUID) throws {
        try lock.withLock {
            try Self.privateIO { try workRoot.removeRegularFileIfPresent(named: "capture-" + id.uuidString + ".json") }
        }
    }
    func unfinishedCaptures() throws -> [CaptureChunkDescriptor] {
        try lock.withLock {
            try Self.privateIO { try workRoot.names() }
            .filter { $0.hasPrefix("capture-") && $0.hasSuffix(".json") }
            .map { name in
                guard let data = try Self.privateIO({ try workRoot.readIfPresent(named: name) }) else {
                    throw JournalError.unsafePath
                }
                let descriptor = try JSONDecoder().decode(Envelope.self, from: data).decode(CaptureChunkDescriptor.self)
                guard descriptor.sessionID == sessionID else { throw JournalError.sessionMismatch }
                guard descriptor.startFrame >= 0, descriptor.sampleRate.isFinite, descriptor.sampleRate > 0,
                      descriptor.audioFile == URL(fileURLWithPath: descriptor.audioFile).lastPathComponent,
                      !descriptor.audioFile.isEmpty, descriptor.audioFile != ".", descriptor.audioFile != ".." else {
                    throw JournalError.unsafePath
                }
                return descriptor
            }.sorted { $0.ordinal < $1.ordinal }
        }
    }
    var records: [TranscriptionWorkRecord] { lock.withLock { state.records } }
    var gaps: [CaptureGap] { lock.withLock { state.gaps } }
    var isPaused: Bool { lock.withLock { state.paused } }
    func record(id: UUID) -> TranscriptionWorkRecord? { lock.withLock { index[id].map { state.records[$0] } } }
    func put(_ record: TranscriptionWorkRecord) throws { try lock.withLock { try append(record: record) } }
    func setPaused(_ value: Bool) throws {
        try lock.withLock { if state.sequence == 0 || state.paused != value { try append(paused: value) } }
    }
    func setCapturing(_ value: Bool) throws {
        try lock.withLock { if state.capturing != value { try append(capturing: value) } }
    }
    func addGap(_ gap: CaptureGap) throws { try lock.withLock { try append(gap: gap) } }
    func audioURL(for record: TranscriptionWorkRecord) throws -> URL {
        try validateRecord(record)
        try Self.privateIO {
            try sessionRoot.assertStillAtOriginalPath()
            try workRoot.assertStillAtOriginalPath()
            _ = try workRoot.requireRegularFileIfPresent(named: record.audioFile)
        }
        return directory.appendingPathComponent(record.audioFile)
    }
    func recordingURL(for record: TranscriptionWorkRecord) throws -> URL? {
        try validateRecord(record)
        guard let file = record.recordingFile else { return nil }
        try Self.privateIO {
            try sessionRoot.assertStillAtOriginalPath()
            try workRoot.assertStillAtOriginalPath()
            _ = try sessionRoot.requireRegularFileIfPresent(named: file)
        }
        return directory.deletingLastPathComponent().appendingPathComponent(file)
    }
    func claimNext() throws -> TranscriptionWorkRecord? {
        try lock.withLock {
            guard !state.paused else { return nil }
            let candidate = state.records.first { [.pending, .manualPending].contains($0.status) }
                ?? state.records.first { $0.status == .retryWaiting && $0.automaticRetryCount < Self.maximumAutomaticRetries }
            guard var record = candidate else { return nil }
            if record.status == .retryWaiting { record.attempt = .automaticRetry; record.automaticRetryCount += 1 }
            else if record.status == .manualPending { record.attempt = .manual; record.manualRetryCount += 1 }
            else { record.attempt = .initial }
            record.status = .active
            try append(record: record) // debit retries durably BEFORE invoking ASR
            return record
        }
    }
    func requeueActive() throws {
        try lock.withLock {
            for var record in state.records where record.status == .active {
                if record.interruptedRetryStaysOtherLanguage { record.status = .otherLanguage }
                else if record.attempt == .initial { record.status = .pending }
                else {
                    record.status = record.attempt == .automaticRetry && record.automaticRetryCount < Self.maximumAutomaticRetries ? .retryWaiting : .failed
                    record.failureReason = .interrupted
                }
                try append(record: record)
            }
        }
    }
    func retry(id: UUID) throws {
        try lock.withLock {
            guard var record = record(id: id) else { throw JournalError.corrupt("找不到该转写片段") }
            guard record.status != .active else { return }
            record.status = .manualPending
            try append(record: record)
        }
    }
    var processingState: TranscriptionProcessingState {
        lock.withLock {
            let pending = state.records.filter(\.needsWork)
            return TranscriptionProcessingState(sessionID: sessionID, isCapturing: state.capturing,
                isPaused: state.paused, activeCount: pending.filter { $0.status == .active }.count,
                pendingCount: pending.count, backlogSeconds: pending.reduce(0) { $0 + $1.duration },
                unresolvedCount: state.records.filter { $0.status == .failed || $0.status == .retryWaiting || $0.candidateText != nil }.count,
                // A pending candidate still needs confirmation; it is counted once, as unresolved.
                otherLanguageCount: state.records.filter { $0.status == .otherLanguage && $0.candidateText == nil }.count)
        }
    }
}
