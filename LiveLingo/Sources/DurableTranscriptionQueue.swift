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

/// Disk-backed work with one serial pump and at most one active ASR task.
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
    }
    private let lock = NSRecursiveLock()
    private let transcriber: Transcriber
    private var context: Context?
    private var worker: Task<Void, Never>?
    private var active: Task<Outcome, Error>?
    private var activeRecord: TranscriptionWorkRecord?
    private var activeWasPreempted = false
    private var recentFormulaContext = ""
    private var storageFailure: String?

    init(transcriber: @escaping Transcriber = { url, model, enhance, mode in
        try await QwenASRClient.transcribe(audioURL: url, modelKey: model, enhanceSpeech: enhance, language: mode)
    }) { self.transcriber = transcriber }

    convenience init(transcriber: @escaping LegacyTranscriber) {
        self.init(transcriber: Self.englishOnly(transcriber))
    }

    static func englishOnly(_ transcriber: @escaping LegacyTranscriber) -> Transcriber {
        { url, model, enhance, _ in
            ASRTranscription(text: try await transcriber(url, model, enhance))
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
        if restoring { try Self.recoverUnsealedCaptures(journal) }
        if restoring, let snapshot = try SessionStore(directory: directory).load() {
            try Self.reconcileAcceptedCandidates(journal, snapshot: snapshot)
        }
        if !restoring { try journal.setPaused(false) }
        if startPaused { try journal.setPaused(true) }
        lock.withLock {
            context = Context(generation: UUID(), journal: journal, persistent: persistent,
                              identified: identified, handler: handler)
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
                                   attempts: context.attempts)
        }
    }

    func setCapturing(_ value: Bool) throws {
        try lock.withLock { try context?.journal.setCapturing(value) }
        publishState()
    }
    func addGap(_ gap: CaptureGap) throws {
        try lock.withLock {
            try context?.journal.addGap(gap)
            context?.handler(.captureGap(gap))
        }
    }
    func pause() async throws {
        try requestPause()
        let tasks = lock.withLock { (worker, active) }
        _ = await tasks.1?.result
        await tasks.0?.value
        publishState()
    }
    func requestPause() throws {
        try lock.withLock {
            guard let context else { return }
            self.context = Context(generation: UUID(), journal: context.journal, persistent: context.persistent,
                                   identified: context.identified, handler: context.handler)
            active?.cancel()
            do {
                try context.journal.setPaused(true)
                try context.journal.requeueActive()
            } catch {
                storageFailure = error.localizedDescription
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
            context?.attempts.remove(id: id)
        }
        publishState(); wake()
    }
    func finish(sessionID: UUID? = nil) async {
        guard let owner = lock.withLock({ context }),
              sessionID == nil || sessionID == owner.journal.sessionID else { return }
        while let task = lock.withLock({ context?.generation == owner.generation ? worker : nil }) {
            await task.value
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
    /// Updates comparison text after an explicit user revision. Subsequent
    /// same-range recognition becomes a candidate and cannot overwrite it.
    func retainExistingText(id: UUID, text: String) throws {
        try lock.withLock {
            guard let context, var record = context.journal.record(id: id) else { return }
            record.text = text
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
            record.candidateText = candidateText
            record.candidateLanguage = candidateLanguage
            record.candidateOrigin = "sameRangeRevision"
            try context.journal.put(record)
            _ = try Self.materializeAudio(record, journal: context.journal)
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
                try journal.clearCaptureMarker(id: pending.id); continue
            }
            let layout = try WAVContextClip.readLayout(at: original)
            guard layout.frameCount > 0 else { try journal.clearCaptureMarker(id: pending.id); continue }
            guard layout.sampleRate == pending.sampleRate else { throw DurableTranscriptionJournal.JournalError.invalidRange }
            let duration = Double(layout.frameCount) / layout.sampleRate
            guard duration <= WAVContextClip.maximumClipSeconds,
                  layout.dataByteCount <= WAVContextClip.maximumClipBytes else {
                throw DurableTranscriptionJournal.JournalError.corrupt("未封口分块超出预期长度，原音频已保留")
            }
            let temporary = try WAVContextClip.extract(from: original, start: 0, end: duration, padding: 0)
            defer { try? FileManager.default.removeItem(at: temporary) }
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

    private func retireCompletedAudio(_ journal: DurableTranscriptionJournal) throws {
        guard !journal.processingState.isCapturing else { return }
        for var record in journal.records where (record.status == .completed || record.status == .silent)
            && record.candidateText == nil && record.audioRetired != true {
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
            // Compare only this bounded range, never read an entire lecture.
            let extract = try WAVContextClip.extract(from: recording, start: record.start, end: record.end, padding: 0)
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
    }

    private static func materializeAudio(_ record: TranscriptionWorkRecord, journal: DurableTranscriptionJournal) throws -> URL {
        let url = try journal.audioURL(for: record)
        guard !FileManager.default.fileExists(atPath: url.path), record.audioRetired == true else { return url }
        guard let original = try journal.recordingURL(for: record) else { throw WAVContextClip.ClipError.fileMissing }
        let layout = try WAVContextClip.readLayout(at: original)
        guard layout.sampleRate == record.sampleRate, layout.frameCount >= record.endFrame else {
            throw WAVContextClip.ClipError.rangeNotWrittenYet
        }
        let temporary = try WAVContextClip.extract(from: original, start: record.start, end: record.end, padding: 0)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: temporary, to: url)
        var updated = record; updated.audioRetired = false
        try journal.put(updated)
        return url
    }
    private func wake() {
        lock.withLock {
            guard worker == nil, storageFailure == nil,
                  let context, !context.journal.isPaused, context.journal.records.contains(where: \.needsWork) else { return }
            worker = Task { [weak self] in
                guard let self else { return }
                await self.run(generation: context.generation)
            }
        }
    }
    private func run(generation token: UUID) async {
        while true {
            let lease: (Context, TranscriptionWorkRecord, Task<Outcome, Error>)?
            do {
                lease = try lock.withLock {
                    guard storageFailure == nil, let context, context.generation == token,
                          let record = try context.journal.claimNext() else {
                        worker = nil; active = nil; activeRecord = nil
                        return nil
                    }
                    let formulaContext = recentFormulaContext
                    let url = try Self.materializeAudio(record, journal: context.journal)
                    let recording = try context.journal.recordingURL(for: record)
                    let task = Task { [transcriber] in
                        try await Self.recognize(record, audioURL: url, recordingURL: recording,
                                                 formulaContext: formulaContext, attempts: context.attempts,
                                                 transcriber: transcriber)
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
                    if activeWasPreempted || task.isCancelled {
                        if record.interruptedRetryStaysOtherLanguage { record.status = .otherLanguage }
                        else {
                            record.status = record.automaticRetryCount < DurableTranscriptionJournal.maximumAutomaticRetries ? .retryWaiting : .failed
                            record.failure = "补转已让出资源，已用重试次数保留。"
                            record.failureReason = .interrupted
                        }
                        try owner.journal.put(record)
                        return
                    }
                    switch result {
                    case .success(let output):
                        if let candidate = output.candidate {
                            record.candidateText = candidate; record.candidateOrigin = output.origin
                            record.candidateLanguage = nil
                        }
                        if output.silent {
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
                        } else if output.otherLanguage {
                            record.status = .otherLanguage
                            record.failure = "此处为非英语讲话（未转写），音频已保留，可手动重试。"
                            record.failureReason = output.failureReason
                        } else {
                            markFailure(&record, message: "此处尚未得到可靠的英文转写，音频已保留。", reason: output.failureReason)
                        }
                        try owner.journal.put(record)
                        if !output.text.isEmpty, record.text == output.text, record.textLanguage == output.language {
                            emitCommit(record, text: output.text, repair: claimed.attempt != .initial)
                        }
                        if record.candidateText != nil { emitCandidate(record) }
                    case .failure(let error):
                        markFailure(&record, message: "本机转写失败：\(error.localizedDescription)；音频已保留。", reason: .error)
                        try owner.journal.put(record)
                    }
                    if let failure = record.failure {
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
    private func markFailure(_ record: inout TranscriptionWorkRecord, message: String,
                             reason: TranscriptionWorkRecord.FailureReason?) {
        record.failure = message
        record.failureReason = reason
        record.status = record.automaticRetryCount < DurableTranscriptionJournal.maximumAutomaticRetries ? .retryWaiting : .failed
    }
    private func emitCommit(_ record: TranscriptionWorkRecord, text: String, repair: Bool) {
        lock.withLock {
            guard let context, context.journal.sessionID == record.sessionID else { return }
            let hints = record.textLanguage == nil
                ? AuxiliaryTranslationHintExtractor.extract(from: record.appleEvidence, primary: text) : []
            if context.identified {
                context.handler(.identifiedFinal(TranscriptionCommit(id: record.id, sessionID: record.sessionID,
                    text: text, start: record.start, end: record.end, startFrame: record.startFrame,
                    endFrame: record.endFrame, sampleRate: record.sampleRate, hints: hints, isRepair: repair,
                    language: record.textLanguage)))
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
            storageFailure = error.localizedDescription
            active?.cancel()
            (context?.handler ?? fallbackHandler)?(.failure("转写工作记录无法保存：\(error.localizedDescription)"))
        }
    }
    static func recognize(_ record: TranscriptionWorkRecord, audioURL: URL, recordingURL: URL?,
                                  formulaContext: String, attempts: TranscriptionAttemptCache,
                                  transcriber: Transcriber) async throws -> Outcome {
        try Task.checkCancellation()
        if try DigitalSilenceGate.isSilent(audioURL) { return Outcome(silent: true) }
        let attemptNonce = UUID()
        func recognizeStage(_ url: URL, model: String, enhance: Bool, stage: String,
                            mode: ASRLanguageMode = .english) async throws -> ASRTranscription {
            try Task.checkCancellation()
            // Only enhanced exact-range requests recur during automatic repair.
            // Raw first-pass speech and final neighbour clips need no caching.
            let reusable = enhance && stage != "context" && record.attempt != .manual
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
            if let key, result.text.utf8.count <= TranscriptionAttemptCache.maximumTextBytes,
               (try? TranscriptionAttemptCache.fingerprint(url)) == key.audio {
                attempts.store(result, for: key)
                if mode == .auto, result.decode == .forced {
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
        var primaryError: Error?
        do { primary = try await recognizeStage(audioURL, model: record.modelKey,
            enhance: record.attempt != .initial, stage: "primary").text }
        catch is CancellationError { throw CancellationError() }
        catch { primaryError = error }
        try Task.checkCancellation()
        let usable = SpeechPipeline.preferredTranscript(primary: primary, fallback: "", audioDuration: record.duration)
        let formula = FormulaASRReview.needsReview(primary, context: formulaContext)
        let needsFallback = primaryError != nil || formula || !EnglishTranscriptGate.accepts(primary)
            || ASRQualityGate.fallbackReason(for: primary, audioDuration: record.duration) != nil
        var output = Outcome(text: usable)
        if usable.isEmpty {
            output.failureReason = primaryError == nil
                ? .rejection(of: primary, audioDuration: record.duration) : .error
        }
        var fallbackVerdict: EnglishTranscriptGate.Verdict?
        if needsFallback, let model = record.fallbackModelKey {
            do {
                let mode: ASRLanguageMode = usable.isEmpty ? .auto : .english
                let result = try await recognizeStage(audioURL, model: model, enhance: true, stage: "fallback", mode: mode)
                try Task.checkCancellation()
                if result.decode == .detected,
                   SourceLanguagePolicy.accepts(result, audioDuration: record.duration, requestedMode: mode) {
                    return Outcome(text: result.text, language: result.language)
                }
                let secondary: String
                if result.decode == .detected {
                    secondary = try await recognizeStage(audioURL, model: model, enhance: true,
                                                         stage: "fallbackEn", mode: .english).text
                } else { secondary = result.text }
                try Task.checkCancellation()
                let alternate = SpeechPipeline.preferredTranscript(primary: nil, fallback: secondary, audioDuration: record.duration)
                fallbackVerdict = EnglishTranscriptGate.verdict(secondary)
                if output.text.isEmpty {
                    output.text = alternate
                    // A primary error stays the reason: it, not the language, blocks `.otherLanguage`.
                    if primaryError == nil { output.failureReason = .rejection(of: secondary, audioDuration: record.duration) }
                }
                else if !alternate.isEmpty, alternate != output.text {
                    output.candidate = alternate; output.origin = "alternateModel"
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // A fallback exception must never erase usable primary speech.
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
            defer { try? FileManager.default.removeItem(at: clip) }
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
