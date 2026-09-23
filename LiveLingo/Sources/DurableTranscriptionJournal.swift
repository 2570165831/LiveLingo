import Foundation
import CryptoKit

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
    }
    enum Attempt: String, Codable, Sendable { case initial, automaticRetry, manual }
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
    var candidateText: String?
    var candidateOrigin: String?
    var failure: String?
    var duration: TimeInterval { max(0, end - start) }
    var needsWork: Bool { [.pending, .active, .retryWaiting, .manualPending].contains(status) }
}

struct TranscriptionProcessingState: Sendable, Equatable {
    let sessionID: UUID
    let isCapturing: Bool
    let isPaused: Bool
    let activeCount: Int
    let pendingCount: Int
    let backlogSeconds: TimeInterval
    let unresolvedCount: Int
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
    private let logURL: URL
    private let snapshotURL: URL
    private(set) var recoveredTruncatedTail = false

    init(sessionDirectory: URL, sessionID: UUID) throws {
        self.sessionID = sessionID
        directory = sessionDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
        logURL = directory.appendingPathComponent("work.jsonl")
        snapshotURL = directory.appendingPathComponent("snapshot.json")
        state = State(sessionID: sessionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: snapshotURL.path) {
            do {
                state = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: snapshotURL)).decode(State.self)
            } catch { throw JournalError.corrupt("快照：\(error.localizedDescription)") }
            guard state.version == 1 else { throw JournalError.corrupt("不支持的快照版本") }
            guard state.sessionID == sessionID else { throw JournalError.sessionMismatch }
        }
        try rebuildIndex()
        if FileManager.default.fileExists(atPath: logURL.path) {
            let data = try Data(contentsOf: logURL)
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
                let savedTail = directory.appendingPathComponent("truncated-tail-\(UUID().uuidString).bin")
                try data.suffix(from: completeEnd).write(to: savedTail, options: .atomic)
                let handle = try FileHandle(forWritingTo: logURL)
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(completeEnd))
                try handle.synchronize()
                recoveredTruncatedTail = true
            }
        } else if state.sequence > 0 { throw JournalError.corrupt("缺少工作日志") }
        for record in state.records { try validateRecord(record) }
        // Recording always requires a deliberate new start after reopening.
        if state.capturing { try setCapturing(false) }
        for var record in state.records where record.status == .active {
            record.status = record.attempt == .automaticRetry
                ? (record.automaticRetryCount < Self.maximumAutomaticRetries ? .retryWaiting : .failed)
                : (record.attempt == .manual ? .failed : .retryWaiting)
            record.failure = "上次转写未完成；保留已消耗的自动重试次数。"
            try put(record)
        }
        if state.sequence == 0 { try setPaused(false) }
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
        if !FileManager.default.fileExists(atPath: logURL.path) {
            try data.write(to: logURL, options: .atomic)
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }; try handle.synchronize()
        } else {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
        }
        apply(change)
        if state.sequence % 128 == 0 { try checkpoint() }
    }
    func checkpoint() throws {
        try lock.withLock {
            let data = try JSONEncoder().encode(Envelope(state))
            try data.write(to: snapshotURL, options: .atomic)
        }
    }
    static func stageCapture(_ descriptor: CaptureChunkDescriptor, directory: URL) throws {
        let url = directory.appendingPathComponent("capture-" + descriptor.id.uuidString + ".json")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw JournalError.duplicateIdentity }
        try JSONEncoder().encode(Envelope(descriptor)).write(to: url, options: .atomic)
    }
    func clearCaptureMarker(id: UUID) throws {
        let url = directory.appendingPathComponent("capture-" + id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func unfinishedCaptures() throws -> [CaptureChunkDescriptor] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension == "json" }
            .map { url in
                let descriptor = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url)).decode(CaptureChunkDescriptor.self)
                guard descriptor.sessionID == sessionID else { throw JournalError.sessionMismatch }
                guard descriptor.startFrame >= 0, descriptor.sampleRate.isFinite, descriptor.sampleRate > 0,
                      descriptor.audioFile == URL(fileURLWithPath: descriptor.audioFile).lastPathComponent,
                      !descriptor.audioFile.isEmpty, descriptor.audioFile != ".", descriptor.audioFile != ".." else {
                    throw JournalError.unsafePath
                }
                return descriptor
            }.sorted { $0.ordinal < $1.ordinal }
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
        let url = directory.appendingPathComponent(record.audioFile)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath() else { throw JournalError.unsafePath }
        return url
    }
    func recordingURL(for record: TranscriptionWorkRecord) throws -> URL? {
        try validateRecord(record)
        guard let file = record.recordingFile else { return nil }
        let parent = directory.deletingLastPathComponent()
        let url = parent.appendingPathComponent(file)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == parent.resolvingSymlinksInPath() else {
            throw JournalError.unsafePath
        }
        return url
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
                record.status = record.attempt == .initial ? .pending
                    : (record.attempt == .automaticRetry && record.automaticRetryCount < Self.maximumAutomaticRetries ? .retryWaiting : .failed)
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
                unresolvedCount: state.records.filter { $0.status == .failed || $0.status == .retryWaiting || $0.candidateText != nil }.count)
        }
    }
}
