import AVFoundation
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
}

/// Disk-backed work with one serial pump and at most one active ASR task.
/// The capture consumer persists a descriptor synchronously, then wakes this
/// pump. No Task or decoded PCM is retained for waiting chunks.
final class DurableTranscriptionQueue: @unchecked Sendable {
    typealias Transcriber = @Sendable (URL, String, Bool) async throws -> String
    private struct Context {
        let generation: UUID
        let journal: DurableTranscriptionJournal
        let persistent: Bool
        let identified: Bool
        let handler: @Sendable (SpeechPipeline.Event) -> Void
    }
    private struct Outcome: Sendable {
        var text = ""
        var silent = false
        var candidate: String?
        var origin: String?
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

    init(transcriber: @escaping Transcriber = { url, model, enhance in
        try await QwenASRClient.transcribe(audioURL: url, modelKey: model, enhanceSpeech: enhance)
    }) { self.transcriber = transcriber }

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
                                   persistent: persistent, identified: context.identified, handler: context.handler)
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
                                       candidateText: String) throws {
        try lock.withLock {
            guard let context, context.journal.sessionID == sessionID,
                  var record = context.journal.record(id: id) else {
                throw DurableTranscriptionJournal.JournalError.sessionMismatch
            }
            guard originalText != candidateText else { return }
            if let pending = record.candidateText, pending != candidateText {
                throw DurableTranscriptionJournal.JournalError.corrupt("该段已有另一份待确认候选，现有正文和候选均保留。")
            }
            record.text = originalText
            record.candidateText = candidateText
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
                record.text = acceptedText; record.status = .completed; record.failure = nil
            }
            record.candidateText = nil; record.candidateOrigin = nil
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
            record.status = .completed
            record.failure = nil
            record.candidateText = nil
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
                                                 formulaContext: formulaContext, transcriber: transcriber)
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
                    if activeWasPreempted || task.isCancelled {
                        record.status = record.automaticRetryCount < DurableTranscriptionJournal.maximumAutomaticRetries ? .retryWaiting : .failed
                        record.failure = "补转已让出资源，已用重试次数保留。"
                        try owner.journal.put(record)
                        return
                    }
                    switch result {
                    case .success(let output):
                        if let candidate = output.candidate {
                            record.candidateText = candidate; record.candidateOrigin = output.origin
                        }
                        if output.silent {
                            record.status = .silent; record.failure = nil
                            owner.handler(.volatile(text: "", start: record.start, end: record.end,
                                                    observedAt: ProcessInfo.processInfo.systemUptime))
                        } else if !output.text.isEmpty {
                            if let old = record.text, !old.isEmpty, old != output.text {
                                record.candidateText = output.text; record.candidateOrigin = "sameRangeRevision"
                            } else { record.text = output.text }
                            record.status = .completed; record.failure = nil
                            recentFormulaContext = String(output.text.suffix(1000))
                        } else { markFailure(&record, message: "此处尚未得到可靠的英文转写，音频已保留。") }
                        try owner.journal.put(record)
                        if !output.text.isEmpty, record.text == output.text {
                            emitCommit(record, text: output.text, repair: claimed.attempt != .initial)
                        }
                        if record.candidateText != nil { emitCandidate(record) }
                    case .failure(let error):
                        markFailure(&record, message: "本机转写失败：\(error.localizedDescription)；音频已保留。")
                        try owner.journal.put(record)
                    }
                    if let failure = record.failure {
                        let recording = record.recordingFile.map { owner.journal.directory.deletingLastPathComponent().appendingPathComponent($0) }
                        RecordingDiagnostics.append(recordingURL: recording, event: "transcription_missing",
                            start: record.start, end: record.end, detail: failure)
                        owner.handler(.transcriptionIssue(start: record.start, end: record.end, message: failure))
                    }
                }
            } catch { failStorage(error, generation: token) }
            publishState()
        }
    }
    private func markFailure(_ record: inout TranscriptionWorkRecord, message: String) {
        record.failure = message
        record.status = record.automaticRetryCount < DurableTranscriptionJournal.maximumAutomaticRetries ? .retryWaiting : .failed
    }
    private func emitCommit(_ record: TranscriptionWorkRecord, text: String, repair: Bool) {
        lock.withLock {
            guard let context, context.journal.sessionID == record.sessionID else { return }
            let hints = AuxiliaryTranslationHintExtractor.extract(from: record.appleEvidence, primary: text)
            if context.identified {
                context.handler(.identifiedFinal(TranscriptionCommit(id: record.id, sessionID: record.sessionID,
                    text: text, start: record.start, end: record.end, startFrame: record.startFrame,
                    endFrame: record.endFrame, sampleRate: record.sampleRate, hints: hints, isRepair: repair)))
            } else { context.handler(.final(text: text, start: record.start, end: record.end, hints: hints)) }
        }
    }
    private func emitCandidate(_ record: TranscriptionWorkRecord) {
        lock.withLock {
            guard let context, let text = record.candidateText,
                  let audio = try? context.journal.audioURL(for: record) else { return }
            let recording = record.recordingFile.map { context.journal.directory.deletingLastPathComponent().appendingPathComponent($0) }
            let message = "补转得到候选文字（待核对），原正文保留。"
            RecordingDiagnostics.append(recordingURL: recording, event: "transcription_retry",
                start: record.start, end: record.end, detail: message, candidate: text)
            context.handler(.transcriptionCandidate(TranscriptionCandidate(id: record.id, sessionID: record.sessionID,
                originalText: record.text ?? "", text: text, start: record.start, end: record.end,
                audioURL: audio, origin: record.candidateOrigin ?? "context")))
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
    private static func recognize(_ record: TranscriptionWorkRecord, audioURL: URL, recordingURL: URL?,
                                  formulaContext: String, transcriber: Transcriber) async throws -> Outcome {
        try Task.checkCancellation()
        if try DigitalSilenceGate.isSilent(audioURL) { return Outcome(silent: true) }
        let attemptNonce = UUID()
        func recognizeStage(_ url: URL, model: String, enhance: Bool, stage: String) async throws -> String {
            let id = ASRRequestContext.identifier(sessionID: record.sessionID, chunkID: record.id,
                automatic: record.automaticRetryCount, manual: record.manualRetryCount,
                stage: stage, nonce: attemptNonce)
            return try await ASRRequestContext.$requestID.withValue(id) {
                try await transcriber(url, model, enhance)
            }
        }
        var primary = ""
        var primaryError: Error?
        do { primary = try await recognizeStage(audioURL, model: record.modelKey,
            enhance: record.attempt != .initial, stage: "primary") }
        catch is CancellationError { throw CancellationError() }
        catch { primaryError = error }
        try Task.checkCancellation()
        let usable = SpeechPipeline.preferredTranscript(primary: primary, fallback: "", audioDuration: record.duration)
        let formula = FormulaASRReview.needsReview(primary, context: formulaContext)
        let needsFallback = primaryError != nil || formula || !EnglishTranscriptGate.accepts(primary)
            || ASRQualityGate.fallbackReason(for: primary, audioDuration: record.duration) != nil
        var output = Outcome(text: usable)
        if needsFallback, let model = record.fallbackModelKey {
            do {
                let secondary = try await recognizeStage(audioURL, model: model, enhance: true, stage: "fallback")
                try Task.checkCancellation()
                let alternate = SpeechPipeline.preferredTranscript(primary: nil, fallback: secondary, audioDuration: record.duration)
                if output.text.isEmpty { output.text = alternate }
                else if !alternate.isEmpty, alternate != output.text {
                    output.candidate = alternate; output.origin = "alternateModel"
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                // A fallback exception must never erase usable primary speech.
                if output.text.isEmpty { primaryError = error }
            }
        }
        if !output.text.isEmpty { return output }
        // The second automatic attempt may consult neighbours after retrying
        // the EXACT original chunk. Its result is always an explicit candidate.
        if record.attempt != .initial,
           record.automaticRetryCount >= DurableTranscriptionJournal.maximumAutomaticRetries,
           let recordingURL {
            let clip = try RecordingDiagnostics.contextAudio(recordingURL: recordingURL, start: record.start, end: record.end)
            defer { try? FileManager.default.removeItem(at: clip) }
            let text = try await recognizeStage(clip, model: record.fallbackModelKey ?? record.modelKey,
                                                enhance: true, stage: "context")
            try Task.checkCancellation()
            let candidate = SpeechPipeline.preferredTranscript(primary: nil, fallback: text, audioDuration: record.duration + 1.5)
            if !candidate.isEmpty { output.candidate = candidate; output.origin = "context" }
        }
        if output.candidate == nil, let primaryError { throw primaryError }
        return output
    }
}
