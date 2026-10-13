import AVFoundation
import CryptoKit
import Foundation

struct TranscriptionCommit: Sendable {
    let id: UUID
    let sessionID: UUID
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let startFrame: Int64
    let endFrame: Int64
    let sampleRate: Double
    let hints: [AuxiliaryTranslationHint]
    let isRepair: Bool
    var language: String? = nil
    /// Only the first pass may revise its own provisional English caption.
    var replacingInitialText: String? = nil
}

struct TranscriptionCandidate: Sendable {
    let id: UUID
    let sessionID: UUID
    let originalText: String
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let audioURL: URL
    /// `context` cannot be mapped automatically to the original time interval.
    let origin: String
    var language: String? = nil
}

/// Disk-backed formal work plus one ordered, yielding language-refinement pump.
/// The capture consumer persists a descriptor synchronously, then wakes this
/// pump. No Task or decoded PCM is retained for waiting chunks.
final class DurableTranscriptionQueue: @unchecked Sendable {
    typealias Transcriber = @Sendable (URL, String, Bool, ASRLanguageMode) async throws -> ASRTranscription
    typealias LegacyTranscriber = @Sendable (URL, String, Bool) async throws -> String
    private struct Context {
        let generation: UUID
        let journal: DurableTranscriptionJournal
        let persistent: Bool
        let identified: Bool
        let handler: @Sendable (SpeechPipeline.Event) -> Void
        var attempts = TranscriptionAttemptCache()
        var sourceTrigger = SourceLanguagePolicy.TriggerState()
    }
    struct Outcome: Encodable, Sendable {
        var text = ""
        var language: String?
        var silent = false
        var candidate: String?
        var origin: String?
        /// Why the exact range has no accepted transcript; identifiers only.
        var failureReason: TranscriptionWorkRecord.FailureReason?
        var otherLanguage = false
        /// Only suppressed chunks persist classifier evidence. Admitted speech
        /// keeps the existing recognition outcome and stored bytes unchanged.
        var noSpeech = false
        var speechConfidence: Double?
        // Runtime-only causal metadata; preserve legacy Outcome/archive bytes.
        var sourceDecision: SourceLanguagePolicy.Decision?
        var sourceInput: SourceLanguagePolicy.ProbeInput?
        var sourceDeferred = false
        private enum CodingKeys: String, CodingKey {
            case text, language, silent, candidate, origin, failureReason, otherLanguage
        }
    }
    private let lock = NSRecursiveLock()
    private let transcriber: Transcriber
    private let speechAnalyzer: SpeechPresenceGate.Analyzer
    private var context: Context?
    private var worker: Task<Void, Never>?
    private var active: Task<Outcome, Error>?
    private var activeRecord: TranscriptionWorkRecord?
    private var activeWasPreempted = false
    private var sourceWorker: Task<Void, Never>?
    private var sourceActive: Task<Outcome, Error>?
    private var recentFormulaContext = ""
    private var storageFailure: String?

    /// Production entry point shared by live capture, import and CLI replay.
    convenience init() {
        self.init(transcriber: { url, model, enhance, mode in
            try await QwenASRClient.transcribe(audioURL: url, modelKey: model, enhanceSpeech: enhance, language: mode)
        }, speechAnalyzer: SpeechPresenceGate.maximumSpeechConfidence)
    }

    /// Inject both boundaries when using synthetic recognizer/audio doubles.
    /// Existing recognition fixtures have no real speech and intentionally
    /// exercise recognition without an external classifier.
    init(transcriber: @escaping Transcriber,
         speechAnalyzer: @escaping SpeechPresenceGate.Analyzer = { _ in nil }) {
        self.transcriber = transcriber
        self.speechAnalyzer = speechAnalyzer
    }

    convenience init(transcriber: @escaping LegacyTranscriber) {
        self.init(transcriber: Self.englishOnly(transcriber))
    }

    static func englishOnly(_ transcriber: @escaping LegacyTranscriber) -> Transcriber {
        { url, model, enhance, mode in
            if mode == .probe { return ASRTranscription(text: "", languageMode: .probe) }
            return ASRTranscription(text: try await transcriber(url, model, enhance))
        }
    }

    /// Call before opening capture. A previous request is cancelled and joined
    /// before any request of the new generation can start.
    func configure(directory: URL, sessionID: UUID, persistent: Bool,
                   identified: Bool, restoring: Bool = false, startPaused: Bool = false,
                   handler: @escaping @Sendable (SpeechPipeline.Event) -> Void) async throws {
        // Invalidate/cancel the old generation now. Its sole worker joins the
        // active request before claiming new ASR work, without delaying capture.
        try requestPause()
        let journal = try DurableTranscriptionJournal(sessionDirectory: directory, sessionID: sessionID)
        if restoring {
            try Self.recoverUnsealedCaptures(journal)
            try Self.recoverRecordingTails(journal)
        }
        if restoring, let snapshot = try SessionStore(directory: directory).load() {
            try Self.reconcileAcceptedCandidates(journal, snapshot: snapshot)
        }
        if !restoring { try journal.setPaused(false) }
        if startPaused { try journal.setPaused(true) }
        lock.withLock {
            context = Context(generation: UUID(), journal: journal, persistent: persistent,
                              identified: identified, handler: handler,
                              sourceTrigger: Self.restoredSourceTrigger(journal.records))
            recentFormulaContext = ""
            storageFailure = nil
        }
        if restoring {
            for record in journal.records {
                if let text = record.text, !text.isEmpty { emitCommit(record, text: text, repair: true) }
                if record.candidateText != nil { emitCandidate(record) }
            }
        }
        publishState()
        wake()
    }

    /// Retains the old nonthrowing API. Storage errors are terminal and visible;
    /// individual ASR errors leave a persistent, retryable interval instead.
    func submit(_ job: SpeechPipeline.ChunkJob,
                handler: @escaping @Sendable (SpeechPipeline.Event) -> Void) {
        do {
            try lock.withLock {
                if context == nil {
                    let directory = job.recordingURL?.deletingLastPathComponent() ?? job.audioURL.deletingLastPathComponent()
                    let journal = try DurableTranscriptionJournal(sessionDirectory: directory, sessionID: job.sessionID ?? UUID())
                    context = Context(generation: UUID(), journal: journal, persistent: job.recordingURL != nil,
                                      identified: job.sessionID != nil, handler: handler)
                }
                guard let context, storageFailure == nil else { return }
                if let id = job.sessionID, id != context.journal.sessionID {
                    throw DurableTranscriptionJournal.JournalError.sessionMismatch
                }
                let audio = try AVAudioFile(forReading: job.audioURL)
                let rate = job.sampleRate ?? audio.processingFormat.sampleRate
                let firstFrame = job.startFrame ?? Int64((job.start * rate).rounded())
                let lastFrame = job.endFrame ?? Int64((job.end * rate).rounded())
                guard audio.processingFormat.sampleRate == rate, audio.length == lastFrame - firstFrame else {
                    throw DurableTranscriptionJournal.JournalError.invalidRange
                }
                let record = TranscriptionWorkRecord(id: job.id, sessionID: context.journal.sessionID,
                    ordinal: context.journal.records.count, audioFile: job.audioURL.lastPathComponent,
                    startFrame: firstFrame, endFrame: lastFrame, sampleRate: rate,
                    start: job.start, end: job.end, captureStart: job.captureStart, captureEnd: job.captureEnd,
                    modelKey: job.modelKey, fallbackModelKey: job.fallbackModelKey, appleEvidence: job.appleEvidence,
                    recordingFile: job.recordingURL?.lastPathComponent)
                if let existing = context.journal.record(id: record.id) {
                    guard existing.startFrame == record.startFrame, existing.endFrame == record.endFrame,
                          existing.audioFile == record.audioFile else { throw DurableTranscriptionJournal.JournalError.duplicateIdentity }
                    return
                }
                let destination = try context.journal.audioURL(for: record)
                if job.audioURL.standardizedFileURL != destination.standardizedFileURL {
                    guard !FileManager.default.fileExists(atPath: destination.path) else { throw DurableTranscriptionJournal.JournalError.duplicateIdentity }
                    try FileManager.default.copyItem(at: job.audioURL, to: destination)
                }
                try context.journal.put(record)
                try context.journal.clearCaptureMarker(id: record.id)
                // Keep an already submitted source response: cancelling the
                // caller cannot preempt its tensor call and would lose the result.
                // The independent formal pump starts immediately; new optional
                // requests are gated against pending formal work under this lock.
                // Captions arriving during an optional repair take precedence.
                // Cancellation is joined by the existing worker before its next claim.
                if let activeRecord, activeRecord.attempt != .initial {
                    activeWasPreempted = true
                    active?.cancel()
                }
            }
            publishState()
            wake()
        } catch { failStorage(error, fallbackHandler: handler) }
    }

    var inFlightCount: Int { state?.pendingCount ?? 0 }
    var state: TranscriptionProcessingState? { lock.withLock { context?.journal.processingState } }
    var records: [TranscriptionWorkRecord] { lock.withLock { context?.journal.records ?? [] } }
    var journalDirectory: URL? { lock.withLock { context?.journal.directory } }
    var isPersistent: Bool { lock.withLock { context?.persistent ?? false } }

    func setPersistence(_ persistent: Bool) {
        lock.withLock {
            guard let context else { return }
            self.context = Context(generation: context.generation, journal: context.journal,
                                   persistent: persistent, identified: context.identified, handler: context.handler,
                                   attempts: context.attempts, sourceTrigger: context.sourceTrigger)
        }
    }

    func setCapturing(_ value: Bool) throws {
        try lock.withLock { try context?.journal.setCapturing(value) }
        publishState()
    }
    func recoverRecordingTail() throws {
        try lock.withLock {
            guard let context, context.persistent else { return }
            try Self.recoverRecordingTails(context.journal)
        }
        publishState(); wake()
    }
    func addGap(_ gap: CaptureGap) throws {
        try lock.withLock {
            try context?.journal.addGap(gap)
            context?.handler(.captureGap(gap))
        }
    }
    func pause() async throws {
        try requestPause()
        let tasks = lock.withLock { (worker, active, sourceWorker, sourceActive) }
        _ = await tasks.1?.result
        _ = await tasks.3?.result
        await tasks.0?.value
        await tasks.2?.value
        publishState()
    }
    func requestPause() throws {
        try lock.withLock {
            guard let context else { return }
            self.context = Context(generation: UUID(), journal: context.journal, persistent: context.persistent,
                                   identified: context.identified, handler: context.handler,
                                   sourceTrigger: context.sourceTrigger)
            active?.cancel()
            sourceActive?.cancel()
            do {
                try context.journal.setPaused(true)
                try context.journal.requeueActive()
            } catch {
                storageFailure = "转写工作记录无法保存（\(LearningFailureCode.code(for: error))）"
                throw error
            }
        }
        publishState()
    }
    func resume() throws {
        try lock.withLock {
            guard storageFailure == nil else { throw DurableTranscriptionJournal.JournalError.corrupt(storageFailure!) }
            if let context, !context.persistent, !context.journal.processingState.isCapturing {
                throw DurableTranscriptionJournal.JournalError.corrupt("只实时会话已结束，不能继续补转。")
            }
            try context?.journal.setPaused(false)
        }
        publishState(); wake()
    }
    func retry(id: UUID) throws {
        try lock.withLock {
            if let context, !context.persistent, !context.journal.processingState.isCapturing {
                throw DurableTranscriptionJournal.JournalError.corrupt("只实时会话已结束，不能重试。")
            }
            try context?.journal.retry(id: id)
            if let context, var record = context.journal.record(id: id),
               record.sourceProbeInput != nil, record.sourceProbeFinished != true {
                record.sourceRevisionAllowed = false
                try context.journal.put(record)
            }
            context?.attempts.remove(id: id)
        }
        publishState(); wake()
    }
    func finish(sessionID: UUID? = nil) async {
        guard let owner = lock.withLock({ context }),
              sessionID == nil || sessionID == owner.journal.sessionID else { return }
        while let tasks = lock.withLock({ () -> (Task<Void, Never>?, Task<Void, Never>?)? in
            guard context?.generation == owner.generation else { return nil }
            // A completed worker hands off to the other lane. Schedule and
            // observe that handoff under one lock before deciding to return.
            wake()
            guard worker != nil || sourceWorker != nil else { return nil }
            return (worker, sourceWorker)
        }) {
            await tasks.0?.value
            await tasks.1?.value
        }
        // A generation switch may already have started another worker. Only
        // checkpoint the original journal; never wait for or fail the new one.
        do {
            try lock.withLock {
                if context?.generation == owner.generation {
                    try retireCompletedAudio(owner.journal)
                    try owner.journal.checkpoint()
                }
            }
        }
        catch {
            lock.withLock {
                if context?.generation == owner.generation { failStorage(error) }
            }
        }
    }
    func cancel() async {
        do { try await pause() }
        catch { failStorage(error) }
    }

    /// The caller has joined cancellation. Saved journals retain their state;
    /// volatile sessions release their in-memory transcript and candidate copy.
    func discardVolatileContentAfterCancellation() {
        lock.withLock {
            guard context?.persistent == false, worker == nil, active == nil,
                  sourceWorker == nil, sourceActive == nil else { return }
            context = nil
            activeRecord = nil
            recentFormulaContext = ""
            storageFailure = nil
        }
    }
    /// Updates comparison text after an explicit user revision. Subsequent
    /// same-range recognition becomes a candidate and cannot overwrite it.
    func retainExistingText(id: UUID, text: String) throws {
        try lock.withLock {
            guard let context, var record = context.journal.record(id: id) else { return }
            record.text = text
            record.sourceRevisionAllowed = false
            try context.journal.put(record)
        }
    }
    /// The archive is authoritative after an explicit correction. A late
    /// replay from the ASR journal becomes a durable candidate, not a new body.
    func preserveConflictingTranscript(id: UUID, sessionID: UUID, originalText: String,
                                       originalLanguage: String? = nil, candidateText: String,
                                       candidateLanguage: String? = nil) throws {
        try lock.withLock {
            guard let context, context.journal.sessionID == sessionID,
                  var record = context.journal.record(id: id) else {
                throw DurableTranscriptionJournal.JournalError.sessionMismatch
            }
            guard originalText != candidateText || originalLanguage != candidateLanguage else { return }
            if let pending = record.candidateText,
               pending != candidateText || record.candidateLanguage != candidateLanguage {
                throw DurableTranscriptionJournal.JournalError.corrupt("该段已有另一份待确认候选，现有正文和候选均保留。")
            }
            record.text = originalText
            record.textLanguage = originalLanguage
            record.sourceRevisionAllowed = false
            record.candidateText = candidateText
            record.candidateLanguage = candidateLanguage
            record.candidateOrigin = "sameRangeRevision"
            try context.journal.put(record)
            if record.audioRetired == true {
                _ = try Self.materializeAudio(record, journal: context.journal)
            }
            emitCandidate(record)
        }
        publishState()
    }

    func resolveCandidate(id: UUID, acceptedText: String?, expectedOriginal: String? = nil,
                          expectedCandidate: String? = nil) throws {
        try lock.withLock {
            guard let context, var record = context.journal.record(id: id) else {
                throw DurableTranscriptionJournal.JournalError.corrupt("候选已不在当前录音队列中。")
            }
            guard expectedOriginal.map({ (record.text ?? "") == $0 }) ?? true,
                  expectedCandidate.map({ record.candidateText == $0 }) ?? true else {
                throw DurableTranscriptionJournal.JournalError.corrupt("候选或原文已更新，请重新查看后确认。")
            }
            if let acceptedText {
                guard !acceptedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DurableTranscriptionJournal.JournalError.corrupt("确认文字为空")
                }
                record.text = acceptedText; record.textLanguage = record.candidateLanguage
                record.status = .completed; record.failure = nil; record.failureReason = nil
            }
            record.candidateText = nil; record.candidateLanguage = nil; record.candidateOrigin = nil
            try context.journal.put(record)
        }
        publishState()
    }

    func reconcileAcceptedCandidates(_ snapshot: SessionSnapshot) throws {
        let changed = try lock.withLock {
            guard let context, context.journal.sessionID == snapshot.sessionID else { return false }
            return try Self.reconcileAcceptedCandidates(context.journal, snapshot: snapshot)
        }
        if changed { publishState() }
    }

    @discardableResult
    private static func reconcileAcceptedCandidates(_ journal: DurableTranscriptionJournal,
                                                    snapshot: SessionSnapshot) throws -> Bool {
        guard snapshot.sessionID == journal.sessionID else {
            throw DurableTranscriptionJournal.JournalError.sessionMismatch
        }
        var changed = false
        for var record in journal.records {
            guard let candidate = record.candidateText,
                  let change = snapshot.revisionHistory.last(where: {
                      $0.previousSegment.id == record.id
                          && $0.transcriptionCandidateText == candidate
                          && $0.previousSegment.english == (record.text ?? "")
                  }), let body = snapshot.segments.first(where: { $0.id == record.id }),
                  body.english == change.replacementSegment.english,
                  !body.hasExplicitSourceLanguage || body.sourceLanguage == record.candidateLanguage,
                  body.inputRevision == change.toRevision else { continue }
            record.text = body.english
            record.textLanguage = body.sourceLanguage
            record.status = .completed
            record.failure = nil
            record.failureReason = nil
            record.candidateText = nil
            record.candidateLanguage = nil
            record.candidateOrigin = nil
            try journal.put(record)
            changed = true
        }
        return changed
    }
    private static func recoverUnsealedCaptures(_ journal: DurableTranscriptionJournal) throws {
        for pending in try journal.unfinishedCaptures() {
            if journal.record(id: pending.id) != nil { try journal.clearCaptureMarker(id: pending.id); continue }
            let original = journal.directory.appendingPathComponent(pending.audioFile)
            guard original.resolvingSymlinksInPath().deletingLastPathComponent() == journal.directory.resolvingSymlinksInPath() else {
                throw DurableTranscriptionJournal.JournalError.unsafePath
            }
            // A marker whose writer never opened has no samples to recover.
            guard FileManager.default.fileExists(atPath: original.path) else {
                if pending.recordingFile == nil { try journal.clearCaptureMarker(id: pending.id) }
                continue
            }
            let layout: WAVContextClip.Layout
            do {
                layout = try WAVContextClip.readLayout(at: original)
                guard layout.frameCount > 0, layout.sampleRate == pending.sampleRate else {
                    throw WAVContextClip.ClipError.recordingEmpty
                }
                guard Double(layout.frameCount) / layout.sampleRate <= WAVContextClip.maximumClipSeconds,
                      layout.dataByteCount <= WAVContextClip.maximumClipBytes else {
                    throw DurableTranscriptionJournal.JournalError.corrupt("未封口分块超出预期长度，原音频已保留")
                }
            } catch {
                // Keep this file and marker, but do not let one damaged capture
                // prevent independently valid chunks and committed text replaying.
                if !journal.gaps.contains(where: { $0.id == pending.id }) {
                    try journal.addGap(CaptureGap(id: pending.id, sessionID: pending.sessionID,
                        lastWrittenFrame: pending.startFrame, sampleRate: pending.sampleRate,
                        observedStart: 0, observedEnd: 0, rejectedFrames: nil,
                        reason: "未封口音频无法恢复，原文件和标记已保留：" + error.localizedDescription))
                }
                continue
            }
            let duration = Double(layout.frameCount) / layout.sampleRate
            let temporary = try WAVContextClip.extract(from: original, start: 0, end: duration, padding: 0,
                destinationDirectory: journal.directory, frameRange: 0..<layout.frameCount)
            defer { preserveTemporary(temporary, in: journal.directory) }
            let recoveredName = "recovered-" + pending.id.uuidString + ".wav"
            let recovered = journal.directory.appendingPathComponent(recoveredName)
            if FileManager.default.fileExists(atPath: recovered.path) {
                guard try Data(contentsOf: recovered) == Data(contentsOf: temporary) else {
                    throw DurableTranscriptionJournal.JournalError.duplicateIdentity
                }
            } else { try FileManager.default.copyItem(at: temporary, to: recovered) }
            let record = TranscriptionWorkRecord(id: pending.id, sessionID: pending.sessionID,
                ordinal: pending.ordinal, audioFile: recoveredName, startFrame: pending.startFrame,
                endFrame: pending.startFrame + Int64(layout.frameCount), sampleRate: layout.sampleRate,
                start: Double(pending.startFrame) / layout.sampleRate,
                end: Double(pending.startFrame + Int64(layout.frameCount)) / layout.sampleRate,
                captureStart: nil, captureEnd: nil, modelKey: pending.modelKey,
                fallbackModelKey: pending.fallbackModelKey, appleEvidence: "", recordingFile: pending.recordingFile)
            try journal.put(record)
            try journal.clearCaptureMarker(id: pending.id)
        }
    }

    private static func recoverRecordingTails(_ journal: DurableTranscriptionJournal) throws {
        let captures = try journal.unfinishedCaptures()
        let references = journal.records.map {
            CaptureChunkDescriptor(id: $0.id, sessionID: $0.sessionID, ordinal: $0.ordinal,
                audioFile: $0.audioFile, recordingFile: $0.recordingFile, startFrame: $0.startFrame,
                sampleRate: $0.sampleRate, modelKey: $0.modelKey, fallbackModelKey: $0.fallbackModelKey)
        } + captures
        var visited: Set<String> = []
        for reference in references {
            guard let file = reference.recordingFile, visited.insert(file).inserted else { continue }
            let parent = journal.directory.deletingLastPathComponent()
            let recording = parent.appendingPathComponent(file)
            guard file == recording.lastPathComponent,
                  recording.resolvingSymlinksInPath().deletingLastPathComponent() == parent.resolvingSymlinksInPath() else {
                throw DurableTranscriptionJournal.JournalError.unsafePath
            }
            guard FileManager.default.fileExists(atPath: recording.path) else { continue }
            let layout: WAVContextClip.Layout
            do { layout = try WAVContextClip.readLayout(at: recording) }
            catch WAVContextClip.ClipError.recordingEmpty {
                // A cancelled startup can leave an empty, still-open WAV.
                // Its marker remains available if actual audio later appears.
                guard !journal.records.contains(where: { $0.recordingFile == file }) else { throw WAVContextClip.ClipError.recordingEmpty }
                continue
            }
            guard layout.sampleRate == reference.sampleRate,
                  references.filter({ $0.recordingFile == file }).allSatisfy({ $0.sampleRate == layout.sampleRate }) else {
                throw DurableTranscriptionJournal.JournalError.invalidRange
            }
            var first = journal.records.filter { $0.recordingFile == file }.map(\.endFrame).max() ?? 0
            let limit = min(Int64(WAVContextClip.maximumClipSeconds * layout.sampleRate),
                            Int64(WAVContextClip.maximumClipBytes / layout.blockAlign))
            guard limit > 0 else { throw DurableTranscriptionJournal.JournalError.invalidRange }
            while first < Int64(layout.frameCount) {
                let end = min(Int64(layout.frameCount), first + limit)
                let id = UUID(), name = "recovered-tail-" + id.uuidString + ".wav"
                let ordinal = (journal.records.map(\.ordinal).max() ?? -1) + 1
                let descriptor = CaptureChunkDescriptor(id: id, sessionID: journal.sessionID,
                    ordinal: ordinal, audioFile: name, recordingFile: file, startFrame: first,
                    sampleRate: layout.sampleRate, modelKey: reference.modelKey, fallbackModelKey: reference.fallbackModelKey)
                try DurableTranscriptionJournal.stageCapture(descriptor, directory: journal.directory)
                let temporary = try WAVContextClip.extract(from: recording, start: Double(first) / layout.sampleRate,
                    end: Double(end) / layout.sampleRate, padding: 0, destinationDirectory: journal.directory,
                    frameRange: Int(first)..<Int(end))
                defer { preserveTemporary(temporary, in: journal.directory) }
                guard Int64(try WAVContextClip.readLayout(at: temporary).frameCount) == end - first else {
                    throw DurableTranscriptionJournal.JournalError.invalidRange
                }
                try FileManager.default.moveItem(at: temporary, to: journal.directory.appendingPathComponent(name))
                try journal.put(TranscriptionWorkRecord(id: id, sessionID: journal.sessionID,
                    ordinal: ordinal, audioFile: name, startFrame: first, endFrame: end, sampleRate: layout.sampleRate,
                    start: Double(first) / layout.sampleRate, end: Double(end) / layout.sampleRate,
                    captureStart: nil, captureEnd: nil, modelKey: reference.modelKey,
                    fallbackModelKey: reference.fallbackModelKey, appleEvidence: "", recordingFile: file))
                try journal.clearCaptureMarker(id: id)
                first = end
            }
        }
    }

    private static func preserveTemporary(_ url: URL, in directory: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.moveItem(at: url,
            to: directory.appendingPathComponent("superseded-" + UUID().uuidString + ".wav"))
    }

    private func retireCompletedAudio(_ journal: DurableTranscriptionJournal) throws {
        #if LIVELINGO_DROP_PROBE
        // Retain generated evidence: this experiment forbids file cleanup.
        return
        #else
        guard !journal.processingState.isCapturing else { return }
        for var record in journal.records where (record.status == .completed || record.status == .silent)
            && record.candidateText == nil && record.audioRetired != true
            && (record.sourceProbeInput == nil || record.sourceProbeFinished == true) {
            guard let recording = try journal.recordingURL(for: record) else { continue }
            let chunk = try journal.audioURL(for: record)
            guard FileManager.default.fileExists(atPath: chunk.path),
                  FileManager.default.fileExists(atPath: recording.path) else { continue }
            let original = try WAVContextClip.readLayout(at: recording)
            let part = try WAVContextClip.readLayout(at: chunk)
            guard original.sampleRate == record.sampleRate, original.frameCount >= record.endFrame,
                  original.channelCount == part.channelCount, original.formatTag == part.formatTag,
                  original.bitsPerSample == part.bitsPerSample,
                  part.frameCount == record.endFrame - record.startFrame else { continue }
            // Compare only this bounded range, never read an entire lecture. Use the record's
            // integer frames: frame / rate * rate need not round-trip to the same frame.
            let extract = try WAVContextClip.extract(from: recording, start: record.start, end: record.end, padding: 0,
                frameRange: Int(record.startFrame)..<Int(record.endFrame))
            defer { try? FileManager.default.removeItem(at: extract) }
            let extracted = try WAVContextClip.readLayout(at: extract)
            let source = try FileHandle(forReadingFrom: chunk)
            let other = try FileHandle(forReadingFrom: extract)
            defer { try? source.close(); try? other.close() }
            try source.seek(toOffset: UInt64(part.dataOffset))
            try other.seek(toOffset: UInt64(extracted.dataOffset))
            guard part.dataByteCount == extracted.dataByteCount,
                  try source.read(upToCount: part.dataByteCount) == other.read(upToCount: extracted.dataByteCount) else { continue }
            record.audioRetired = true
            try journal.put(record)
            try FileManager.default.removeItem(at: chunk)
        }
        #endif
    }

    private static func materializeAudio(_ record: TranscriptionWorkRecord, journal: DurableTranscriptionJournal) throws -> URL {
        let url = try journal.audioURL(for: record)
        if record.audioRetired != true {
            let part = try WAVContextClip.readLayout(at: url)
            guard part.sampleRate == record.sampleRate, Int64(part.frameCount) == record.endFrame - record.startFrame else {
                throw DurableTranscriptionJournal.JournalError.invalidRange
            }
            return url
        }
        guard let original = try journal.recordingURL(for: record) else { throw WAVContextClip.ClipError.fileMissing }
        let layout = try WAVContextClip.readLayout(at: original)
        guard layout.sampleRate == record.sampleRate, layout.frameCount >= record.endFrame else {
            throw WAVContextClip.ClipError.rangeNotWrittenYet
        }
        let temporary = try WAVContextClip.extract(from: original, start: record.start, end: record.end, padding: 0,
            destinationDirectory: journal.directory, frameRange: Int(record.startFrame)..<Int(record.endFrame))
        defer { preserveTemporary(temporary, in: journal.directory) }
        guard Int64(try WAVContextClip.readLayout(at: temporary).frameCount) == record.endFrame - record.startFrame else {
            throw DurableTranscriptionJournal.JournalError.invalidRange
        }
        if FileManager.default.fileExists(atPath: url.path) {
            if (try? samePCM(url, temporary)) != true {
                try FileManager.default.moveItem(at: url,
                    to: journal.directory.appendingPathComponent("invalid-audio-" + UUID().uuidString + ".wav"))
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } else { try FileManager.default.moveItem(at: temporary, to: url) }
        var updated = record; updated.audioRetired = false
        try journal.put(updated)
        return url
    }
    private static func samePCM(_ left: URL, _ right: URL) throws -> Bool {
        let a = try WAVContextClip.readLayout(at: left), b = try WAVContextClip.readLayout(at: right)
        guard a.sampleRate == b.sampleRate, a.channelCount == b.channelCount,
              a.formatTag == b.formatTag, a.bitsPerSample == b.bitsPerSample,
              a.blockAlign == b.blockAlign, a.dataByteCount == b.dataByteCount, a.frameCount > 0 else { return false }
        let lhs = try FileHandle(forReadingFrom: left), rhs = try FileHandle(forReadingFrom: right)
        defer { try? lhs.close(); try? rhs.close() }
        try lhs.seek(toOffset: UInt64(a.dataOffset)); try rhs.seek(toOffset: UInt64(b.dataOffset))
        var remaining = a.dataByteCount
        while remaining > 0 {
            let count = min(remaining, 1 << 20)
            guard let first = try lhs.read(upToCount: count), let second = try rhs.read(upToCount: count),
                  first.count == count, first == second else { return false }
            remaining -= count
        }
        return true
    }
    private func wake() {
        lock.withLock {
            guard storageFailure == nil, let context, !context.journal.isPaused else { return }
            let records = context.journal.records
            // Use the same budget/source gate as claimNext and processingState;
            // an exhausted legacy retry must not repeatedly wake an idle pump.
            if worker == nil, records.contains(where: \.isClaimable) {
                worker = Task { [weak self] in await self?.run(generation: context.generation) }
            }
            if sourceWorker == nil, worker == nil,
               records.contains(where: { $0.sourceTriggerPendingBoundary == true
                   || ($0.sourceProbeInput != nil && $0.sourceProbeFinished != true) }) {
                sourceWorker = Task { [weak self] in await self?.runSources(generation: context.generation) }
            }
        }
    }

    static func restoredSourceTrigger(_ records: [TranscriptionWorkRecord]) -> SourceLanguagePolicy.TriggerState {
        var progress = SourceLanguagePolicy.TriggerState()
        for record in records.sorted(by: { $0.ordinal < $1.ordinal }) {
            if let after = record.sourceTriggerAfter { progress = after }
            else if record.sourceProbeInput != nil || record.sourceTriggerPendingBoundary == true
                || record.status == .pending || record.status == .active {
                break // An unresolved older ordinal cannot be overtaken.
            } else { progress = .init() } // Legacy records contribute no head evidence.
        }
        return progress
    }

    /// Formal failures are causal boundaries, but only after every older head
    /// has resolved. Persist their first predecessor then, before a repair can
    /// use it. Never advance the live chain from a repair's current evidence.
    private func refreshInitialProgress(_ owner: Context) throws {
        var progress = SourceLanguagePolicy.TriggerState()
        for var record in owner.journal.records.sorted(by: { $0.ordinal < $1.ordinal }) {
            if let after = record.sourceTriggerAfter { progress = after; continue }
            guard record.sourceProbeInput == nil, record.status != .pending, record.status != .active else { break }
            if record.attempt == .initial {
                record.sourceTriggerPredecessor = record.sourceTriggerPredecessor ?? progress
                var after = record.sourceTriggerPredecessor ?? .init()
                after.advance(index: record.ordinal, decision: record.sourceTriggerDecision)
                record.sourceTriggerAfter = after
                record.sourceTriggerPendingBoundary = nil
                try owner.journal.put(record)
                progress = after
            } else { progress = .init() }
        }
        context?.sourceTrigger = progress
    }

    private func canStartSource(generation: UUID) -> Bool {
        lock.withLock {
            guard let owner = context, owner.generation == generation,
                  !owner.journal.isPaused, storageFailure == nil, worker == nil else { return false }
            return !owner.journal.records.contains { $0.status == .pending }
        }
    }

    private func commitEnglishBeforeProbe(_ output: Outcome, record claimed: TranscriptionWorkRecord,
                                          generation: UUID) throws {
        try lock.withLock {
            guard let owner = context, owner.generation == generation,
                  var record = owner.journal.record(id: claimed.id), !output.text.isEmpty,
                  record.text?.isEmpty != false else { return }
            record.text = output.text; record.textLanguage = nil
            if claimed.attempt == .initial {
                record.sourceRevisionAllowed = record.sourceRevisionAllowed != false
                record.sourceInitialEnglishDigest = TranscriptionWorkRecord.englishDigest(output.text)
            }
            try owner.journal.put(record)
            recentFormulaContext = String(output.text.suffix(1000))
            emitCommit(record, text: output.text, repair: claimed.attempt != .initial)
        }
    }

    private func preserveInitialDecision(_ decision: SourceLanguagePolicy.Decision?,
                                         record: inout TranscriptionWorkRecord, owner: Context) throws {
        guard record.attempt == .initial, record.sourceTriggerAfter == nil else { return }
        record.sourceTriggerDecision = decision
        // A foreground failure may complete ahead of older deferred heads.
        // Its predecessor is supplied by the ordered progress drain instead.
        guard let predecessor = record.sourceTriggerPredecessor else {
            record.sourceTriggerPendingBoundary = true
            return
        }
        var progress = predecessor
        progress.advance(index: record.ordinal, decision: decision)
        record.sourceTriggerDecision = decision; record.sourceTriggerAfter = progress
        try owner.journal.put(record)
        try refreshInitialProgress(owner)
    }
    private func run(generation token: UUID) async {
        while true {
            let lease: (Context, TranscriptionWorkRecord, Task<Outcome, Error>)?
            do {
                lease = try lock.withLock {
                    guard storageFailure == nil, let context, context.generation == token,
                          var record = try context.journal.claimNext() else {
                        worker = nil; active = nil; activeRecord = nil
                        return nil
                    }
                    if record.attempt != .initial, record.sourceTriggerPredecessor == nil {
                        record.sourceTriggerPredecessor = .init()
                        try context.journal.put(record)
                    }
                    if record.attempt == .initial, record.sourceTriggerPredecessor == nil {
                        try refreshInitialProgress(context)
                        let predecessor = record.ordinal == 0 ? SourceLanguagePolicy.TriggerState()
                            : context.journal.records.first { $0.ordinal == record.ordinal - 1 }?.sourceTriggerAfter
                        if let predecessor {
                            record.sourceTriggerPredecessor = predecessor
                            try context.journal.put(record)
                        }
                    }
                    let claimed = record
                    let formulaContext = recentFormulaContext
                    // Only the immediately preceding completed range is evidence
                    // that the added left audio has already entered the body.
                    let previous = context.journal.records.first { $0.ordinal == claimed.ordinal - 1 }
                    let previousText = previous.flatMap { prior in
                        prior.status == .completed && prior.textLanguage == nil
                            && prior.sessionID == claimed.sessionID && prior.sampleRate == claimed.sampleRate
                            && prior.endFrame == claimed.startFrame ? prior.text : nil
                    }
                    let url = try Self.materializeAudio(record, journal: context.journal)
                    let recording = try context.journal.recordingURL(for: record)
                    let task = Task { [transcriber, speechAnalyzer] in
                        try await Self.recognize(claimed, audioURL: url, recordingURL: recording,
                                                 formulaContext: formulaContext, attempts: context.attempts,
                                                 previousText: previousText,
                                                 sourceTrigger: claimed.sourceTriggerPredecessor ?? .init(),
                                                 deferSource: claimed.attempt == .initial,
                                                 transcriber: transcriber,
                                                 speechAnalyzer: speechAnalyzer,
                                                 commitEnglish: { output in
                                                     try self.commitEnglishBeforeProbe(output, record: claimed, generation: token)
                                                 }, preserveDecision: { decision in
                                                     try self.lock.withLock {
                                                         guard self.context?.generation == token,
                                                               var current = context.journal.record(id: claimed.id) else { return }
                                                         try self.preserveInitialDecision(decision, record: &current, owner: context)
                                                     }
                                                 })
                    }
                    active = task; activeRecord = record; activeWasPreempted = false
                    return (context, record, task)
                }
            } catch {
                lock.withLock { worker = nil; active = nil; activeRecord = nil }
                failStorage(error, generation: token); return
            }
            guard let (owner, claimed, task) = lease else { wake(); return }
            publishState()
            let result = await task.result
            do {
                try lock.withLock {
                    active = nil; activeRecord = nil
                    guard context?.generation == owner.generation else { return }
                    var record = owner.journal.record(id: claimed.id) ?? claimed
                    defer { if !record.needsWork { owner.attempts.remove(id: record.id) } }
                    if activeWasPreempted && claimed.attempt == .manual && !record.interruptedRetryStaysOtherLanguage {
                        // The user's request still stands after yielding to fresh
                        // captions: queue it again as manual, refunding this
                        // unfinished pass and leaving the automatic budget alone.
                        // A standing non-English verdict is restored below instead.
                        record.status = .manualPending
                        if record.manualRetryCount > 0 { record.manualRetryCount -= 1 }
                        try owner.journal.put(record)
                        return
                    }
                    if activeWasPreempted || task.isCancelled {
                        if record.interruptedRetryStaysOtherLanguage { record.status = .otherLanguage }
                        else {
                            // Yielding to fresh captions is not a finished attempt:
                            // refund the automatic retry debited at claim time.
                            let refunded = activeWasPreempted && claimed.attempt == .automaticRetry
                                && record.automaticRetryCount > 0
                            if refunded { record.automaticRetryCount -= 1 }
                            record.status = record.automaticRetryCount < DurableTranscriptionJournal.maximumAutomaticRetries ? .retryWaiting : .failed
                            record.failure = refunded ? "补转已让给新字幕，未计入自动重试次数。" : "补转已让出资源，已用重试次数保留。"
                            record.failureReason = .interrupted
                        }
                        try owner.journal.put(record)
                        return
                    }
                    switch result {
                    case .success(let output):
                        // Only completed initial passes advance the live stream.
                        // Repeated repairs of one ordinal must not confirm itself
                        // or disrupt the next live segment's causal predecessor.
                        if let input = output.sourceInput {
                            record.sourceProbeInput = input; record.sourceProbeFinished = false
                            record.sourceRevisionAllowed = record.sourceRevisionAllowed != false
                                && (claimed.text?.isEmpty != false || record.hasProvisionalInitialEnglish)
                        } else { try preserveInitialDecision(output.sourceDecision, record: &record, owner: owner) }
                        // Recheck the live journal after the asynchronous attempt:
                        // an explicit edit, candidate or retry may have arrived.
                        if output.noSpeech, record.status != .active || record.manualRetryCount > 0 || record.attempt == .manual {
                            try owner.journal.put(record)
                            return
                        }
                        if output.noSpeech, record.text?.isEmpty == false || record.candidateText?.isEmpty == false
                            || !record.appleEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            record.status = record.text?.isEmpty == false ? .completed : .failed
                            record.failure = nil; record.failureReason = nil; record.speechConfidence = nil
                            try owner.journal.put(record)
                            return
                        }
                        let alreadyDelivered = record.text?.isEmpty == false
                        if let candidate = output.candidate {
                            record.candidateText = candidate; record.candidateOrigin = output.origin
                            record.candidateLanguage = nil
                        }
                        if output.noSpeech, let confidence = output.speechConfidence {
                            record.status = .noSpeech
                            record.text = nil; record.textLanguage = nil
                            record.candidateText = nil; record.candidateLanguage = nil; record.candidateOrigin = nil
                            record.sourceProbeInput = nil; record.sourceProbeFinished = nil
                            record.sourceRevisionAllowed = nil; record.sourceInitialEnglishDigest = nil
                            record.failure = "未识别到讲话，音频已保留，可手动重试。"
                            record.failureReason = .noSpeech
                            record.speechConfidence = confidence
                            RecordingDiagnostics.append(recordingURL: try? owner.journal.recordingURL(for: record),
                                event: "transcription_no_speech", start: record.start, end: record.end,
                                detail: "", reason: .noSpeech)
                        } else if output.silent {
                            record.status = .silent; record.failure = nil; record.failureReason = nil
                            owner.handler(.volatile(text: "", start: record.start, end: record.end,
                                                    observedAt: ProcessInfo.processInfo.systemUptime))
                        } else if !output.text.isEmpty {
                            if let old = record.text, !old.isEmpty,
                               old != output.text || record.textLanguage != output.language {
                                record.candidateText = output.text; record.candidateOrigin = "sameRangeRevision"
                                record.candidateLanguage = output.language
                            } else { record.text = output.text; record.textLanguage = output.language }
                            record.status = .completed; record.failure = nil; record.failureReason = nil
                            if output.language == nil { recentFormulaContext = String(output.text.suffix(1000)) }
                        } else if claimed.attempt == .initial, record.hasProvisionalInitialEnglish {
                            record.status = .completed; record.failure = nil; record.failureReason = nil
                        } else if output.otherLanguage {
                            record.status = .otherLanguage
                            record.failure = "此处为\(SavedProcessingPresentation.untranscribedSpeech)，音频已保留，可手动重试。"
                            record.failureReason = output.failureReason
                        } else {
                            markFailure(&record, message: "此处尚未得到可靠的英文转写，音频已保留。", reason: output.failureReason)
                        }
                        try owner.journal.put(record)
                        if !alreadyDelivered, !output.text.isEmpty, record.text == output.text, record.textLanguage == output.language {
                            emitCommit(record, text: output.text, repair: claimed.attempt != .initial)
                        }
                        if record.candidateText != nil { emitCandidate(record) }
                    case .failure(let error):
                        if claimed.attempt == .initial, record.hasProvisionalInitialEnglish {
                            record.status = .completed; record.failure = nil; record.failureReason = nil
                        } else {
                            markFailure(&record, message: "本机转写失败：\(LearningFailureCode.label(for: LearningFailureCode.code(for: error)))；音频已保留。", reason: .error)
                        }
                        try preserveInitialDecision(nil, record: &record, owner: owner)
                        try owner.journal.put(record)
                    }
                    try refreshInitialProgress(owner)
                    if let failure = record.failure, record.status != .noSpeech {
                        let recording = record.recordingFile.map { owner.journal.directory.deletingLastPathComponent().appendingPathComponent($0) }
                        RecordingDiagnostics.append(recordingURL: recording,
                            event: record.status == .otherLanguage ? "transcription_non_english" : "transcription_missing",
                            start: record.start, end: record.end, detail: failure, reason: record.failureReason)
                        if record.status != .otherLanguage {
                            owner.handler(.transcriptionIssue(start: record.start, end: record.end, message: failure))
                        } else if record.candidateText == nil {
                            // Terminal, not an error: counted in the saved status, never a warning.
                            owner.handler(.nonEnglishSpeech(start: record.start, end: record.end))
                        }
                    }
                }
            } catch { failStorage(error, generation: token) }
            publishState()
        }
    }
    private func runSources(generation token: UUID) async {
        while true {
            let lease: (Context, TranscriptionWorkRecord, Task<Outcome, Error>)?
            do {
                lease = try lock.withLock {
                    if let owner = context, owner.generation == token { try refreshInitialProgress(owner) }
                    guard storageFailure == nil, let owner = context, owner.generation == token,
                          !owner.journal.isPaused, worker == nil,
                          !owner.journal.records.contains(where: { $0.status == .pending }),
                          var record = owner.journal.records.filter({
                              $0.sourceProbeInput != nil && $0.sourceProbeFinished != true
                          }).min(by: { $0.ordinal < $1.ordinal }), let input = record.sourceProbeInput else {
                        sourceWorker = nil; sourceActive = nil
                        return nil
                    }
                    // Resolve causality in ordinal order, never from the most
                    // recently delivered foreground caption or a repair.
                    if record.sourceTriggerPredecessor == nil {
                        try refreshInitialProgress(owner)
                        record.sourceTriggerPredecessor = owner.journal.records.first {
                            $0.ordinal == record.ordinal - 1
                        }?.sourceTriggerAfter ?? .init()
                        try owner.journal.put(record)
                    }
                    let claimed = record
                    let url = try Self.materializeAudio(record, journal: owner.journal)
                    let task = Task { [transcriber] in
                        try await Self.recognize(claimed, audioURL: url, recordingURL: nil,
                            formulaContext: "", attempts: owner.attempts,
                            sourceTrigger: claimed.sourceTriggerPredecessor ?? .init(), sourceOnly: input,
                            transcriber: transcriber,
                            canStartSource: { self.canStartSource(generation: token) }, preserveDecision: { decision in
                                try self.lock.withLock {
                                    guard self.context?.generation == token,
                                          var current = owner.journal.record(id: claimed.id) else { return }
                                    try self.preserveInitialDecision(decision, record: &current, owner: owner)
                                }
                            })
                    }
                    sourceActive = task
                    return (owner, claimed, task)
                }
            } catch {
                lock.withLock { sourceWorker = nil; sourceActive = nil }
                failStorage(error, generation: token); return
            }
            guard let (owner, claimed, task) = lease else { wake(); return }
            let result = await task.result
            do {
                try lock.withLock {
                    sourceActive = nil
                    guard context?.generation == token else { return }
                    // Yielding is not a failed head and must not clear the chain.
                    // A successful persisted head may resume body-only work.
                    guard !task.isCancelled else { return }
                    guard var record = owner.journal.record(id: claimed.id) else { return }
                    let previousFailure = record.failure
                    let previousReason = record.failureReason
                    switch result {
                    case .success(let output):
                        if output.sourceDeferred { return }
                        record.sourceProbeFinished = true
                        try preserveInitialDecision(output.sourceDecision, record: &record, owner: owner)
                        if !output.text.isEmpty, let language = output.language {
                            let previous = record.text
                            let canReplace = record.sourceRevisionAllowed == true
                                && record.text == claimed.text && record.textLanguage == nil
                            if previous?.isEmpty != false || canReplace {
                                record.text = output.text; record.textLanguage = language
                                record.status = .completed; record.failure = nil; record.failureReason = nil
                                // Alternate English suggestions from this first
                                // pass are superseded by the confirmed source.
                                if record.candidateOrigin == "alternateModel" {
                                    record.candidateText = nil; record.candidateLanguage = nil; record.candidateOrigin = nil
                                }
                                try owner.journal.put(record)
                                emitCommit(record, text: output.text, repair: false,
                                    replacingInitialText: canReplace ? previous : nil)
                            } else {
                                record.candidateText = output.text; record.candidateLanguage = language
                                record.candidateOrigin = "sameRangeRevision"
                                try owner.journal.put(record); emitCandidate(record)
                            }
                        } else {
                            if record.text?.isEmpty != false, record.status != .silent {
                                markFailure(&record, message: record.failure ?? "此处尚未得到可靠的英文转写，音频已保留。",
                                    reason: record.failureReason ?? output.failureReason)
                            }
                            try owner.journal.put(record)
                        }
                    case .failure(let error):
                        record.sourceProbeFinished = true
                        try preserveInitialDecision(nil, record: &record, owner: owner)
                        if record.text?.isEmpty != false, record.status != .silent {
                            markFailure(&record, message: record.failure
                                ?? "本机转写失败：\(LearningFailureCode.label(for: LearningFailureCode.code(for: error)))；音频已保留。",
                                reason: record.failureReason ?? .error)
                        }
                        try owner.journal.put(record)
                    }
                    // Old journals can still contain an active source pass with
                    // English already delivered. Every finished head/body path
                    // must close that work, including English and failed probes.
                    if record.status == .active, record.text?.isEmpty == false {
                        record.status = .completed; record.failure = nil; record.failureReason = nil
                        try owner.journal.put(record)
                    }
                    if !record.needsWork { owner.attempts.remove(id: record.id) }
                    if let failure = record.failure, failure != previousFailure || record.failureReason != previousReason {
                        let recording = record.recordingFile.map {
                            owner.journal.directory.deletingLastPathComponent().appendingPathComponent($0)
                        }
                        RecordingDiagnostics.append(recordingURL: recording, event: "transcription_missing",
                            start: record.start, end: record.end, detail: failure, reason: record.failureReason)
                        owner.handler(.transcriptionIssue(start: record.start, end: record.end, message: failure))
                    }
                }
            } catch { failStorage(error, generation: token) }
            publishState()
        }
    }

    private func markFailure(_ record: inout TranscriptionWorkRecord, message: String,
                             reason: TranscriptionWorkRecord.FailureReason?) {
        record.failure = message
        record.failureReason = reason
        record.status = record.automaticRetryCount < DurableTranscriptionJournal.maximumAutomaticRetries ? .retryWaiting : .failed
    }
    private func emitCommit(_ record: TranscriptionWorkRecord, text: String, repair: Bool,
                            replacingInitialText: String? = nil) {
        lock.withLock {
            guard let context, context.journal.sessionID == record.sessionID else { return }
            let hints = record.textLanguage == nil
                ? AuxiliaryTranslationHintExtractor.extract(from: record.appleEvidence, primary: text) : []
            if context.identified {
                context.handler(.identifiedFinal(TranscriptionCommit(id: record.id, sessionID: record.sessionID,
                    text: text, start: record.start, end: record.end, startFrame: record.startFrame,
                    endFrame: record.endFrame, sampleRate: record.sampleRate, hints: hints, isRepair: repair,
                    language: record.textLanguage, replacingInitialText: replacingInitialText)))
            } else { context.handler(.final(text: text, start: record.start, end: record.end, hints: hints,
                                           language: record.textLanguage)) }
        }
    }
    private func emitCandidate(_ record: TranscriptionWorkRecord) {
        lock.withLock {
            guard let context, let text = record.candidateText,
                  let audio = try? context.journal.audioURL(for: record) else { return }
            let recording = record.recordingFile.map { context.journal.directory.deletingLastPathComponent().appendingPathComponent($0) }
            let message = "补转得到候选文字（待核对），原正文保留。"
            RecordingDiagnostics.append(recordingURL: recording, event: "transcription_retry",
                start: record.start, end: record.end, detail: message, candidate: text, reason: record.failureReason)
            context.handler(.transcriptionCandidate(TranscriptionCandidate(id: record.id, sessionID: record.sessionID,
                originalText: record.text ?? "", text: text, start: record.start, end: record.end,
                audioURL: audio, origin: record.candidateOrigin ?? "context", language: record.candidateLanguage)))
            context.handler(.transcriptionIssue(start: record.start, end: record.end, message: message))
        }
    }
    private func publishState() {
        lock.withLock { if let context { context.handler(.processing(context.journal.processingState)) } }
    }
    private func failStorage(_ error: Error, fallbackHandler: (@Sendable (SpeechPipeline.Event) -> Void)? = nil,
                             generation: UUID? = nil) {
        lock.withLock {
            if let generation, context?.generation != generation { return }
            guard storageFailure == nil else { return }
            storageFailure = "转写工作记录无法保存（\(LearningFailureCode.code(for: error))）"
            active?.cancel()
            sourceActive?.cancel()
            (context?.handler ?? fallbackHandler)?(.failure("转写工作记录无法保存：\(LearningFailureCode.label(for: LearningFailureCode.code(for: error)))"))
        }
    }
    /// Never deduplicate body words by spelling: two equal words can have
    /// different starts. Removed left words need a direct predecessor suffix.
    static func retainedParakeetText(_ result: ASRTranscription, offset: Double,
                                    clipDuration: Double, previousText: String?) -> String? {
        guard let spans = result.parakeetWordSpans, !spans.isEmpty,
              spans.map(\.text).joined(separator: " ") == result.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " "),
              spans.allSatisfy({ !$0.text.isEmpty && $0.text.split(whereSeparator: { $0.isWhitespace }).count == 1
                  && $0.start.isFinite && $0.end.isFinite && $0.start >= 0
                  && $0.end >= $0.start && $0.start < clipDuration && $0.end <= clipDuration }),
              zip(spans, spans.dropFirst()).allSatisfy({ $0.start <= $1.start }) else { return nil }
        let left = spans.prefix { $0.start < offset }
        if !left.isEmpty {
            func words(_ text: String) -> [String] {
                text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }.map(String.init)
            }
            let excluded = words(left.map(\.text).joined(separator: " "))
            guard let previousText, !excluded.isEmpty,
                  Array(words(previousText).suffix(excluded.count)) == excluded else { return nil }
        }
        return spans.dropFirst(left.count).map(\.text).joined(separator: " ")
    }

    static func recognize(_ record: TranscriptionWorkRecord, audioURL: URL, recordingURL: URL?,
                                  formulaContext: String, attempts: TranscriptionAttemptCache,
                                  previousText: String? = nil,
                                  sourceTrigger: SourceLanguagePolicy.TriggerState = .init(),
                                  deferSource: Bool = false,
                                  sourceOnly: SourceLanguagePolicy.ProbeInput? = nil,
                                  transcriber: Transcriber,
                                  speechAnalyzer: SpeechPresenceGate.Analyzer = { _ in nil },
                                  commitEnglish: @Sendable (Outcome) throws -> Void = { _ in },
                                  canStartSource: @Sendable () -> Bool = { true },
                                  preserveDecision: @Sendable (SourceLanguagePolicy.Decision) throws -> Void = { _ in }) async throws -> Outcome {
        try Task.checkCancellation()
        // Preserve the original digital-silence verdict before any classifier.
        if sourceOnly == nil, try DigitalSilenceGate.isSilent(audioURL) {
            return Outcome(silent: true, sourceInput: deferSource
                ? .init(parakeetAccepted: true, mean: nil, minimum: nil) : nil)
        }
        let mayFilter = sourceOnly == nil && record.attempt != .manual && record.manualRetryCount == 0
            && record.text?.isEmpty != false && record.candidateText?.isEmpty != false
            && record.appleEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // All recognizer/classifier evidence must describe these same bytes.
        // An unreadable or changed waveform cannot support a no-speech verdict.
        let gateAudio = mayFilter ? (try? TranscriptionAttemptCache.fingerprint(audioURL)) : nil
        let attemptNonce = UUID()
        func recognizeStage(_ url: URL, model: String, enhance: Bool, stage: String,
                            mode: ASRLanguageMode = .english) async throws -> ASRTranscription {
            try Task.checkCancellation()
            // Only enhanced exact-range requests recur during automatic repair.
            // Raw first-pass speech and final neighbour clips need no caching.
            let reusable = (enhance || mode == .probe) && stage != "context" && record.attempt != .manual
            let fingerprint = reusable ? try? TranscriptionAttemptCache.fingerprint(url) : nil
            let key = fingerprint.map { TranscriptionAttemptCache.Key(id: record.id, model: model,
                                                                       enhanced: enhance, mode: mode, audio: $0) }
            if let key, let result = attempts.result(for: key) {
                try Task.checkCancellation()
                return result
            }
            let id = ASRRequestContext.identifier(sessionID: record.sessionID, chunkID: record.id,
                automatic: record.automaticRetryCount, manual: record.manualRetryCount,
                stage: stage, nonce: attemptNonce)
            let result = try await ASRRequestContext.$requestID.withValue(id) {
                try await transcriber(url, model, enhance, mode)
            }
            try Task.checkCancellation()
            let failedConfirmedBody = mode == .auto && ASRRequestContext.confirmedSourceLanguage != nil
                && (result.decode == .forced || result.text.isEmpty)
            if let key, !failedConfirmedBody, result.text.utf8.count <= TranscriptionAttemptCache.maximumTextBytes,
               (try? TranscriptionAttemptCache.fingerprint(url)) == key.audio {
                attempts.store(result, for: key)
                if mode == .auto, result.decode == .forced, ASRRequestContext.confirmedSourceLanguage == nil {
                    // Forced auto decoding is the same English generation on
                    // this waveform. Strip probe metadata to match an English
                    // reply exactly; detected replies stay in their own mode.
                    let englishKey = TranscriptionAttemptCache.Key(id: key.id, model: key.model,
                        enhanced: key.enhanced, mode: .english, audio: key.audio)
                    attempts.store(ASRTranscription(text: result.text), for: englishKey)
                }
            }
            return result
        }
        var primary = ""
        var primaryResult: ASRTranscription?
        var primaryError: Error?
        if sourceOnly != nil { primary = record.text ?? "" }
        else { do {
            primaryResult = try await recognizeStage(audioURL, model: record.modelKey,
                enhance: record.attempt != .initial, stage: "primary")
            primary = primaryResult?.text ?? ""
        }
        catch is CancellationError { throw CancellationError() }
        catch { primaryError = error }
        }
        try Task.checkCancellation()
        if sourceOnly == nil, record.attempt == .initial, record.modelKey == "parakeet",
           record.duration > 0, record.duration <= 3, record.start >= 0.25,
           primaryError == nil,
           SpeechPipeline.preferredTranscript(primary: primary, fallback: "", audioDuration: record.duration).isEmpty,
           let recordingURL {
            do {
                let layout = try WAVContextClip.readLayout(at: recordingURL)
                let leftFrames = Int64((0.25 * layout.sampleRate).rounded(.down))
                guard layout.sampleRate == record.sampleRate, leftFrames > 0,
                      record.startFrame >= leftFrames, record.endFrame <= Int64(layout.frameCount) else {
                    throw WAVContextClip.ClipError.rangeNotWrittenYet
                }
                let first = record.startFrame - leftFrames
                let clip = try WAVContextClip.extract(from: recordingURL, start: Double(first) / layout.sampleRate,
                    end: record.end, padding: 0, destinationDirectory: audioURL.deletingLastPathComponent(),
                    frameRange: Int(first)..<Int(record.endFrame))
                #if !LIVELINGO_DROP_PROBE
                defer { try? FileManager.default.removeItem(at: clip) }
                #endif
                guard Int64(try WAVContextClip.readLayout(at: clip).frameCount) == record.endFrame - first else {
                    throw WAVContextClip.ClipError.rangeNotWrittenYet
                }
                let padded = try await recognizeStage(clip, model: "parakeet", enhance: false, stage: "leftContext")
                let offset = Double(leftFrames) / layout.sampleRate
                let retained = retainedParakeetText(padded, offset: offset,
                    clipDuration: Double(record.endFrame - first) / layout.sampleRate, previousText: previousText)
                if let retained,
                   !SpeechPipeline.preferredTranscript(primary: retained, fallback: "", audioDuration: record.duration).isEmpty {
                    primary = retained
                    primaryResult = padded
                }
                // Unaligned left context may include borrowed words. Keep the
                // exact-range retries free of candidates; neighbour candidates
                // are offered below only after their automatic budget is spent.
            } catch is CancellationError { throw CancellationError() }
            catch { /* Optional left context never invalidates the exact-range pass. */ }
        }
        let usable = SpeechPipeline.preferredTranscript(primary: primary, fallback: "", audioDuration: record.duration)
        let formula = FormulaASRReview.needsReview(primary, context: formulaContext)
        let needsFallback = sourceOnly == nil && (primaryError != nil || formula || !EnglishTranscriptGate.accepts(primary)
            || ASRQualityGate.fallbackReason(for: primary, audioDuration: record.duration) != nil)
        let input = sourceOnly ?? SourceLanguagePolicy.ProbeInput(parakeetAccepted: !usable.isEmpty
            && primaryResult?.parakeetConfidenceValid != false,
            mean: primaryResult?.parakeetMeanProbability.flatMap { $0.isFinite ? $0 : nil },
            minimum: primaryResult?.parakeetMinProbability.flatMap { $0.isFinite ? $0 : nil })
        let plan = sourceTrigger.plan(index: record.ordinal, parakeetAccepted: input.parakeetAccepted,
            mean: input.mean, minimum: input.minimum)
        var output = Outcome(text: usable)
        output.sourceDecision = SourceLanguagePolicy.decide(plan, language: nil, probability: nil,
            englishProbability: nil, probeFailed: plan.selected)
        if usable.isEmpty {
            output.failureReason = sourceOnly != nil ? record.failureReason : primaryError == nil
                ? .rejection(of: primary, audioDuration: record.duration) : .error
        }
        var fallbackVerdict: EnglishTranscriptGate.Verdict?
        var fallbackHasText = false
        var fallbackSucceeded = false
        var fallbackFailed = false
        // Any usable primary English is durable before optional work begins.
        if plan.selected && !output.text.isEmpty { try commitEnglish(output) }
        if needsFallback, let model = record.fallbackModelKey {
            do {
                // Formal English repair also precedes the optional language head.
                let secondary = try await recognizeStage(audioURL, model: model, enhance: true, stage: "fallback").text
                fallbackHasText = !secondary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                fallbackSucceeded = true
                let alternate = SpeechPipeline.preferredTranscript(primary: nil, fallback: secondary, audioDuration: record.duration)
                fallbackVerdict = EnglishTranscriptGate.verdict(secondary)
                if output.text.isEmpty {
                    output.text = alternate
                    if primaryError == nil { output.failureReason = .rejection(of: secondary, audioDuration: record.duration) }
                } else if !alternate.isEmpty, alternate != output.text {
                    output.candidate = alternate; output.origin = "alternateModel"
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                fallbackFailed = true
                if output.text.isEmpty { primaryError = error; output.failureReason = .error }
            }
        }
        // A formal service error is final for this pass. Never send a language
        // request to the same failed fallback before reporting the error.
        if sourceOnly == nil, output.text.isEmpty, !fallbackSucceeded, let primaryError { throw primaryError }
        if fallbackFailed { return output }
        if deferSource, record.fallbackModelKey != nil,
           plan.selected || record.sourceTriggerPredecessor == nil,
           !output.text.isEmpty || record.sourceTriggerPredecessor == nil {
            output.sourceDecision = nil; output.sourceInput = input
            return output
        }
        if plan.selected, let model = record.fallbackModelKey, record.status != .silent {
            if !canStartSource() { return Outcome(sourceDeferred: true) }
            if !output.text.isEmpty { try commitEnglish(output) }
            do {
                let decision: SourceLanguagePolicy.Decision
                if sourceOnly != nil, let saved = record.sourceTriggerDecision { decision = saved }
                else {
                    let head = try await recognizeStage(audioURL, model: model, enhance: false, stage: "languageProbe", mode: .probe)
                    // Reuse this already scheduled head; never start another
                    // language request ahead of formal work or deferred causality.
                    let validHead = head.text.isEmpty && head.languageMode == .probe && head.policy == 1
                        && (head.detectedLabel == "None" || SpokenLanguage.all.contains { $0.qwenLabel == head.detectedLabel })
                    if mayFilter, output.text.isEmpty, output.candidate == nil,
                       primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !fallbackHasText,
                       SpeechPresenceGate.parakeetSuggestsNoSpeech(valid: primaryResult?.parakeetConfidenceValid,
                           mean: primaryResult?.parakeetMeanProbability, minimum: primaryResult?.parakeetMinProbability,
                           emptyTranscript: primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                       SpeechPresenceGate.languageSuggestsNoSpeech(valid: validHead, noSpeechLabel: head.detectedLabel == "None",
                           probability: head.languageProbability, englishProbability: head.englishProbability),
                       let gateAudio, (try? TranscriptionAttemptCache.fingerprint(audioURL)) == gateAudio {
                        let key = TranscriptionAttemptCache.SpeechKey(id: record.id, audio: gateAudio)
                        let confidence: Double?
                        if let cached = attempts.speechAnalysis(for: key) { confidence = cached.confidence }
                        else {
                            confidence = try? speechAnalyzer(audioURL)
                            try Task.checkCancellation()
                            if (try? TranscriptionAttemptCache.fingerprint(audioURL)) == gateAudio {
                                attempts.storeSpeechAnalysis(.init(confidence: confidence), for: key)
                            }
                        }
                        try Task.checkCancellation()
                        if (try? TranscriptionAttemptCache.fingerprint(audioURL)) == gateAudio,
                           SpeechPresenceGate.shouldSuppress(confidence) {
                            return Outcome(failureReason: .noSpeech, noSpeech: true, speechConfidence: confidence)
                        }
                    }
                    decision = SourceLanguagePolicy.decide(plan,
                    language: SpokenLanguage.all.first { $0.qwenLabel == head.detectedLabel }?.code,
                    probability: head.languageProbability, englishProbability: head.englishProbability,
                    probeFailed: head.languageMode != .probe || head.policy != 1 || head.detectedLabel == nil)
                }
                output.sourceDecision = decision
                // Persist the head independently of optional body success.
                try preserveDecision(decision)
                if let language = decision.language {
                    if !canStartSource() { return Outcome(sourceDecision: decision, sourceDeferred: true) }
                    let result = try await ASRRequestContext.$confirmedSourceLanguage.withValue(language) {
                        try await recognizeStage(audioURL, model: model, enhance: true, stage: "confirmedSource", mode: .auto)
                    }
                    if result.language == language, result.decode == .detected,
                       SourceLanguagePolicy.accepts(result, audioDuration: record.duration) {
                        return Outcome(text: result.text, language: result.language, sourceDecision: decision)
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Neither failed heads nor failed source bodies erase English.
                // The successful head remains the initial causal evidence.
                if output.text.isEmpty { primaryError = error; output.failureReason = .error }
            }
        }
        if !output.text.isEmpty { return output }
        // No English was accepted, the enhanced English pass has run (it can still
        // recover speech the raw pass missed), and the multilingual fallback heard
        // Han-dominant speech. Stop: later automatic attempts reuse these results
        // and neighbour context would only borrow adjacent sentences.
        if primaryError == nil, record.attempt != .initial, fallbackVerdict == .hanDominant {
            output.otherLanguage = true
            return output
        }
        // The second automatic attempt may consult neighbours after retrying
        // the EXACT original chunk. Its result is always an explicit candidate.
        if record.attempt != .initial,
           record.automaticRetryCount >= DurableTranscriptionJournal.maximumAutomaticRetries,
           let recordingURL {
            let clip = try RecordingDiagnostics.contextAudio(recordingURL: recordingURL, start: record.start, end: record.end)
            #if !LIVELINGO_DROP_PROBE
            defer { try? FileManager.default.removeItem(at: clip) }
            #endif
            let text = try await recognizeStage(clip, model: record.fallbackModelKey ?? record.modelKey,
                                                enhance: true, stage: "context", mode: .english).text
            try Task.checkCancellation()
            let candidate = SpeechPipeline.preferredTranscript(primary: nil, fallback: text, audioDuration: record.duration + 1.5)
            if !candidate.isEmpty { output.candidate = candidate; output.origin = "context" }
        }
        if output.candidate == nil, let primaryError { throw primaryError }
        return output
    }
}

/// Short-lived, bounded raw results for deterministic bundled recognizers.
/// A new queue generation owns a new cache. No audio, error, or cancelled result
/// is retained. Nothing is written to archives. Gate checks still run on hits.
final class TranscriptionAttemptCache: @unchecked Sendable {
    struct SpeechKey: Hashable { let id: UUID; let audio: Data }
    struct SpeechAnalysis { let confidence: Double? }
    struct Key: Hashable {
        let id: UUID
        let model: String
        let enhanced: Bool
        let mode: ASRLanguageMode
        let audio: Data
    }
    static let maximumTextBytes = 16 * 1024
    private let lock = NSLock()
    private var entries: [Key: ASRTranscription] = [:]
    private var order: [Key] = []
    private var speechEntries: [SpeechKey: SpeechAnalysis] = [:]
    private var speechOrder: [SpeechKey] = []

    func speechAnalysis(for key: SpeechKey) -> SpeechAnalysis? { lock.withLock { speechEntries[key] } }
    func storeSpeechAnalysis(_ result: SpeechAnalysis, for key: SpeechKey) {
        lock.withLock {
            if speechEntries[key] == nil {
                if speechOrder.count == 64 { speechEntries.removeValue(forKey: speechOrder.removeFirst()) }
                speechOrder.append(key)
            }
            speechEntries[key] = result
        }
    }

    func result(for key: Key) -> ASRTranscription? { lock.withLock { entries[key] } }
    func store(_ result: ASRTranscription, for key: Key) {
        guard result.text.utf8.count <= Self.maximumTextBytes else { return }
        lock.withLock {
            if entries[key] == nil {
                if order.count == 64 { entries.removeValue(forKey: order.removeFirst()) }
                order.append(key)
            }
            entries[key] = result
        }
    }
    func remove(id: UUID) {
        lock.withLock {
            for key in speechOrder where key.id == id { speechEntries.removeValue(forKey: key) }
            speechOrder.removeAll { $0.id == id }
            for key in order where key.id == id { entries.removeValue(forKey: key) }
            order.removeAll { $0.id == id }
        }
    }
    static func fingerprint(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let limit = 64 * 1024 * 1024
        guard values.isRegularFile == true, let size = values.fileSize, size <= limit else {
            throw CocoaError(.fileReadTooLarge)
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256(), count = 0
        while let data = try file.read(upToCount: 64 * 1024), !data.isEmpty {
            count += data.count
            guard count <= limit else { throw CocoaError(.fileReadTooLarge) }
            digest.update(data: data)
        }
        return Data(digest.finalize())
    }
}
