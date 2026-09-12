import AVFoundation
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit
import Speech

@available(macOS 27, *)
private final class ModernPreviewState {
    var transcriber: SpeechTranscriber?
    var analyzer: SpeechAnalyzer?
    var converter: AnalyzerInputConverter?
    var continuation: AsyncStream<AnalyzerInput>.Continuation?
}

// Compatibility preview only; Parakeet remains the authoritative transcript.
// Never permit Apple's legacy recognizer to send audio to a server.
private final class LegacySpeechPreview: @unchecked Sendable {
    private let lock = NSLock()
    private let recognizer: SFSpeechRecognizer?
    private let emit: @Sendable (String, TimeInterval, TimeInterval) -> Void
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = UUID()
    private var elapsed: TimeInterval = 0
    private var requestStart: TimeInterval = 0
    private var stopped = false

    init(locale: Locale, emit: @escaping @Sendable (String, TimeInterval, TimeInterval) -> Void) {
        recognizer = SFSpeechRecognizer(locale: locale)
        self.emit = emit
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !stopped, let recognizer, recognizer.supportsOnDeviceRecognition else { return }
            if request == nil || elapsed - requestStart >= 45 {
                generation = UUID()
                request?.endAudio()
                task?.cancel()
                let newRequest = SFSpeechAudioBufferRecognitionRequest()
                newRequest.requiresOnDeviceRecognition = true
                newRequest.shouldReportPartialResults = true
                requestStart = elapsed
                let offset = requestStart
                let token = generation
                request = newRequest
                task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
                    guard let self else { return }
                    let accepted = self.lock.withLock {
                        guard !self.stopped, self.generation == token else { return false }
                        if error != nil || result?.isFinal == true { self.request = nil }
                        return true
                    }
                    guard accepted, let result else { return }
                    let transcript = result.bestTranscription
                    guard !transcript.formattedString.isEmpty else { return }
                    let end = transcript.segments.last.map { $0.timestamp + $0.duration } ?? 0
                    self.emit(transcript.formattedString, offset, offset + end)
                }
            }
            request?.append(buffer)
            elapsed += Double(buffer.frameLength) / buffer.format.sampleRate
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            generation = UUID()
            request?.endAudio()
            task?.cancel()
            request = nil
            task = nil
        }
    }
}

final class SpeechPipeline: NSObject, @unchecked Sendable {
    // The frozen candidate still has a 10-second hard ceiling, but normal
    // rotation is now driven by the causal sentence/pause policy.
    static let stableChunkDuration: TimeInterval = 10
    static let waveformUpdateInterval: TimeInterval = 0.1

    static let microphoneStallTimeout: TimeInterval = 3
    static let maximumMicrophoneRecoveryAttempts = 3

    enum Event: Sendable {
        case audioLevel(Float)
        case volatile(text: String, start: TimeInterval, end: TimeInterval)
        case final(
            text: String,
            start: TimeInterval,
            end: TimeInterval,
            hints: [AuxiliaryTranslationHint]
        )
        case failure(String)
        case rejectedTranscript
        case transcriptionIssue(start: TimeInterval, end: TimeInterval, message: String)
    }

    enum PipelineError: LocalizedError {
        case noInputDevice
        case invalidInputFormat
        case noActiveSession
        case temporaryDirectoryUnavailable
        case noDisplayAvailable

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "没有找到可用的麦克风输入。"
            case .invalidInputFormat:
                return "麦克风返回了无效的音频格式。"
            case .noActiveSession:
                return "当前没有可恢复的录音会话。"
            case .temporaryDirectoryUnavailable:
                return "无法建立本机转写音频分段目录。"
            case .noDisplayAvailable:
                return "没有找到可用于内录的显示器。"
            }
        }
    }

    struct ChunkJob: Sendable {
        let audioURL: URL
        let modelKey: String
        let fallbackModelKey: String?
        let start: TimeInterval
        let end: TimeInterval
        let appleEvidence: String
        let recordingURL: URL?
    }

    private struct FlushSnapshot: Sendable {
        let job: ChunkJob?
        let handler: (@Sendable (Event) -> Void)?
    }

    actor TranscriptionQueue {
        typealias Transcriber = @Sendable (URL, String, Bool) async throws -> String
        private let transcriber: Transcriber
        init(transcriber: @escaping Transcriber = { url, model, enhance in
            try await QwenASRClient.transcribe(audioURL: url, modelKey: model, enhanceSpeech: enhance)
        }) { self.transcriber = transcriber }
        private var tail: Task<Void, Never>?
        private var recentFormulaContext = ""
        private var jobs: [UUID: Task<Void, Never>] = [:]
        private var retryTask: Task<Void, Never>?
        private var pendingRetries: [(ChunkJob, @Sendable (Event) -> Void)] = []
        private var finishing = false

        private func report(_ job: ChunkJob, _ message: String, handler: @escaping @Sendable (Event) -> Void) {
            RecordingDiagnostics.append(recordingURL: job.recordingURL, event: "transcription_missing",
                start: job.start, end: job.end, detail: message)
            handler(.transcriptionIssue(start: job.start, end: job.end, message: message))
            // A small bounded backlog; skipped retry work remains recorded against
            // the full recording and does not retain an unbounded chunk directory.
            if pendingRetries.count < 8, job.recordingURL != nil {
                pendingRetries.append((job, handler))
            }
        }

        private func scheduleRetryIfIdle() {
            guard !finishing, jobs.isEmpty, retryTask == nil, !pendingRetries.isEmpty else { return }
            retryTask = Task {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { retryTask = nil; return }
                guard jobs.isEmpty, !finishing else { retryTask = nil; return }
                let (job, handler) = pendingRetries.removeFirst()
                defer { retryTask = nil; scheduleRetryIfIdle() }
                do {
                    guard let recordingURL = job.recordingURL else { return }
                    let context = try RecordingDiagnostics.contextAudio(recordingURL: recordingURL, start: job.start, end: job.end)
                    defer { try? FileManager.default.removeItem(at: context) }
                    let text = try await transcriber(context, job.fallbackModelKey ?? job.modelKey, true)
                    try Task.checkCancellation()
                    let accepted = SpeechPipeline.preferredTranscript(primary: nil, fallback: text,
                        audioDuration: job.end - job.start + 1.5)
                    let message: String
                    if !accepted.isEmpty {
                        // Context includes adjacent speech. Do not silently insert
                        // it into the timestamped transcript and duplicate sentences.
                        message = "上下文重试得到候选文字（待核对）：\(accepted)"
                    } else if !text.isEmpty, !EnglishTranscriptGate.accepts(text) {
                        message = "重试识别为非英语内容，未写入英文字幕。"
                    } else {
                        message = "重试仍未得到可靠文字；此处转写缺失，音频保留。"
                    }
                    RecordingDiagnostics.append(recordingURL: recordingURL, event: "transcription_retry",
                        start: job.start, end: job.end, detail: message, candidate: text)
                    handler(.transcriptionIssue(start: job.start, end: job.end, message: message))
                } catch {
                    RecordingDiagnostics.append(recordingURL: job.recordingURL, event: "transcription_retry_interrupted",
                        start: job.start, end: job.end, detail: error.localizedDescription)
                }
            }
        }

        func submit(_ job: ChunkJob, handler: @escaping @Sendable (Event) -> Void) {
            // New captions take priority over the optional context retry.
            finishing = false
            retryTask?.cancel()
            let previousRetry = retryTask
            let previous = tail
            let id = UUID()
            let task = Task {
                defer {
                    jobs[id] = nil
                    scheduleRetryIfIdle()
                    try? FileManager.default.removeItem(at: job.audioURL)
                }
                if let previous { await previous.value }
                if let previousRetry { await previousRetry.value }
                guard !Task.isCancelled else { return }
                do {
                    if try DigitalSilenceGate.isSilent(job.audioURL) {
                        handler(.volatile(text: "", start: job.start, end: job.end))
                        return
                    }
                    let text = try await transcribeWithFallback(job)
                    recentFormulaContext = String(text.suffix(1000))
                    try Task.checkCancellation()
                    guard !text.isEmpty else {
                        report(job, "此处转写缺失（空白、非英语或异常重复），录音继续。", handler: handler)
                        return
                    }
                    if ASRQualityGate.isShortRepetition(text) {
                        RecordingDiagnostics.append(recordingURL: job.recordingURL, event: "short_repetition_kept",
                            start: job.start, end: job.end, detail: "短句含重复用词，保留待核对。", candidate: text)
                        handler(.transcriptionIssue(start: job.start, end: job.end, message: "短句含重复用词，已保留，请核对。"))
                    }
                    let hints = AuxiliaryTranslationHintExtractor.extract(
                        from: job.appleEvidence,
                        primary: text
                    )
                    handler(.final(
                        text: text,
                        start: job.start,
                        end: job.end,
                        hints: hints
                    ))
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    report(job, "本机转写失败：\(error.localizedDescription)；录音继续，音频保留。", handler: handler)
                }
            }
            jobs[id] = task
            tail = task
        }

        private func transcribeWithFallback(_ job: ChunkJob) async throws -> String {
            let primaryText: String
            do {
                primaryText = try await transcriber(job.audioURL, job.modelKey, false)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard let fallbackModelKey = job.fallbackModelKey else { throw error }
                let fallbackText = try await transcriber(job.audioURL, fallbackModelKey, true)
                return SpeechPipeline.preferredTranscript(
                    primary: nil,
                    fallback: fallbackText,
                    audioDuration: max(0, job.end - job.start)
                )
            }

            let reviewFormula = FormulaASRReview.needsReview(primaryText, context: recentFormulaContext)
            guard let fallbackModelKey = job.fallbackModelKey,
                  reviewFormula || !EnglishTranscriptGate.accepts(primaryText) || ASRQualityGate.fallbackReason(
                      for: primaryText,
                      audioDuration: max(0, job.end - job.start)
                  ) != nil
            else {
                return SpeechPipeline.preferredTranscript(
                    primary: primaryText, fallback: "",
                    audioDuration: max(0, job.end - job.start)
                )
            }

            let fallbackText: String
            do {
                fallbackText = try await transcriber(job.audioURL, fallbackModelKey, true)
            } catch is CancellationError { throw CancellationError() }
            catch {
                if reviewFormula {
                    let usable = SpeechPipeline.preferredTranscript(primary: primaryText, fallback: "", audioDuration: max(0, job.end - job.start))
                    return usable.isEmpty ? "" : usable + " [Formula transcription uncertain]"
                }
                throw error
            }
            if !fallbackText.isEmpty, !EnglishTranscriptGate.accepts(fallbackText) {
                RecordingDiagnostics.append(recordingURL: job.recordingURL, event: "non_english_asr",
                    start: job.start, end: job.end, detail: "备用识别结果不是英语", candidate: fallbackText)
            }
            let selected = SpeechPipeline.preferredTranscript(
                primary: primaryText, fallback: fallbackText,
                audioDuration: max(0, job.end - job.start)
            )
            if selected.isEmpty, !fallbackText.isEmpty, !EnglishTranscriptGate.accepts(fallbackText) {
                throw QwenRuntimeError.requestFailed("识别为非英语内容，未写入英文字幕。")
            }
            // A second recognizer is evidence, not a verified formula. Keep
            // uncertainty explicit instead of silently manufacturing notation.
            if reviewFormula, !selected.isEmpty {
                return selected + " [Formula transcription uncertain]"
            }
            return selected
        }

        func finish() async {
            finishing = true
            retryTask?.cancel()
            await tail?.value
            await retryTask?.value
            pendingRetries.removeAll()
        }

        func cancel() async {
            finishing = true
            retryTask?.cancel()
            pendingRetries.removeAll()
            let active = Array(jobs.values)
            for task in active { task.cancel() }
            for task in active { await task.value }
            await retryTask?.value
            jobs.removeAll()
            tail = nil
        }

    }

    static func preferredTranscript(
        primary: String?, fallback: String, audioDuration: TimeInterval = 10
    ) -> String {
        for candidate in [fallback, primary ?? ""] {
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, EnglishTranscriptGate.accepts(text) else { continue }
            switch ASRQualityGate.fallbackReason(for: text, audioDuration: audioDuration) {
            case nil, .implausiblyShort:
                // A short acknowledgement may be valid. It triggers a retry,
                // but is not evidence of corruption on its own.
                return text
            case .emptyTranscript, .invalidText, .repeatedLoop, .runawayText:
                continue
            }
        }
        return ""
    }

    private let stateLock = NSLock()
    private let transcriptionQueue = TranscriptionQueue()
    private let systemAudioQueue = DispatchQueue(label: "LiveLingo.SystemAudioCapture")
    private let microphoneRecoveryQueue = DispatchQueue(label: "LiveLingo.MicrophoneRecovery")
    private let previewLocale = Locale(identifier: "en-US")
    private var audioEngine: AVAudioEngine?
    private var systemAudioStream: SCStream?
    private var recordingFile: AVAudioFile?
    private var chunkFile: AVAudioFile?
    private var chunkURL: URL?
    private var chunkDirectory: URL?
    private var inputFormat: AVAudioFormat?
    private var submissionTail: Task<Void, Never>?
    private var eventHandler: (@Sendable (Event) -> Void)?
    private var profile = QwenModelProfile.energySaver
    private var chunkStartedAt: TimeInterval = 0
    private var nextChunkIndex = 0
    private var inputMode: AudioInputMode?
    private var microphoneTapInstalled = false
    private var microphoneConfigurationObserver: NSObjectProtocol?
    private var microphoneWatchdogTask: Task<Void, Never>?
    private var lastAudioCallbackUptime: TimeInterval?
    private var waveformMeter = WaveformMeter()
    private var microphoneRecoveryScheduled = false
    private var microphoneRecoveryAttempts = 0
    private var capturePaused = false
    private var isStopping = false
    private var previewSupportedLocale: Locale?
    private var modernPreviewStorage: Any?
    private var legacyPreview: LegacySpeechPreview?
    @available(macOS 27, *)
    private var modernPreview: ModernPreviewState {
        if let value = modernPreviewStorage as? ModernPreviewState { return value }
        let value = ModernPreviewState()
        modernPreviewStorage = value
        return value
    }
    @available(macOS 27, *)
    private var previewTranscriber: SpeechTranscriber? {
        get { modernPreview.transcriber }
        set { modernPreview.transcriber = newValue }
    }
    @available(macOS 27, *)
    private var previewAnalyzer: SpeechAnalyzer? {
        get { modernPreview.analyzer }
        set { modernPreview.analyzer = newValue }
    }
    @available(macOS 27, *)
    private var previewConverter: AnalyzerInputConverter? {
        get { modernPreview.converter }
        set { modernPreview.converter = newValue }
    }
    @available(macOS 27, *)
    private var previewInputContinuation: AsyncStream<AnalyzerInput>.Continuation? {
        get { modernPreview.continuation }
        set { modernPreview.continuation = newValue }
    }
    private var previewAnalysisTask: Task<Void, Never>?
    private var previewResultTask: Task<Void, Never>?
    private var previewObservations: [AuxiliaryTranscriptObservation] = []
    private var activityDetector: SpeechActivityDetector?
    private var boundaryPolicy = CausalBoundaryPolicy()
    private var capturedAudioDuration: TimeInterval = 0

    func update(profile: QwenModelProfile) {
        stateLock.lock()
        self.profile = profile
        stateLock.unlock()
    }

    func prepareModel(
        profile: QwenModelProfile,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        update(profile: profile)
        status("正在检查本机转写服务…")
        try await QwenASRClient.checkHealth(
            modelKeys: [profile.asrKey, profile.fallbackASRKey].compactMap { $0 }
        )
        status("正在准备逐词英文预览…")
        let previewReady = await prepareStreamingPreviewModel()
        let previewLabel = previewReady ? " · 逐词预览" : " · 稳定字幕模式"
        if let fallbackASRKey = profile.fallbackASRKey {
            status("Parakeet 已就绪 · 异常回退 \(fallbackASRKey.uppercased())\(previewLabel)")
        } else {
            status("本机 ASR \(profile.asrKey.uppercased()) 已就绪\(previewLabel)")
        }
    }

    private func prepareStreamingPreviewModel() async -> Bool {
        if #available(macOS 27, *) { return await prepareModernPreviewModel() }
        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        let supported = authorized && SFSpeechRecognizer(locale: previewLocale)?.supportsOnDeviceRecognition == true
        stateLock.withLock { previewSupportedLocale = supported ? previewLocale : nil }
        return supported
    }

    @available(macOS 27, *)
    private func prepareModernPreviewModel() async -> Bool {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: previewLocale)
        else {
            stateLock.withLock { previewSupportedLocale = nil }
            return false
        }

        do {
            let probe = SpeechTranscriber(
                locale: locale,
                preset: .timeIndexedProgressiveTranscription
            )
            let modules: [any SpeechModule] = [probe]
            // Preview is optional. Offline startup must never wait for an
            // operating-system speech model download; bundled ASR remains usable.
            guard await AssetInventory.status(forModules: modules) == .installed else {
                stateLock.withLock { previewSupportedLocale = nil }
                return false
            }
            _ = try await AssetInventory.reserve(locale: locale)
            stateLock.withLock { previewSupportedLocale = locale }
            return true
        } catch {
            stateLock.withLock { previewSupportedLocale = nil }
            return false
        }
    }

    func start(
        inputMode: AudioInputMode,
        recordingURL: URL?,
        eventHandler: @escaping @Sendable (Event) -> Void
    ) async throws {
        self.eventHandler = eventHandler

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingo-ASR-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false
            )
        } catch {
            throw PipelineError.temporaryDirectoryUnavailable
        }

        do {
            await startStreamingPreviewIfAvailable()
            switch inputMode {
            case .microphone:
                try await startMicrophoneCapture(
                    recordingURL: recordingURL,
                    temporaryDirectory: temporaryDirectory
                )
            case .systemAudio:
                try await startSystemAudioCapture(
                    recordingURL: recordingURL,
                    temporaryDirectory: temporaryDirectory
                )
            }
        } catch {
            await cancelStreamingPreview()
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }

        stateLock.withLock {
            self.inputMode = inputMode
            capturePaused = false
            isStopping = false
            waveformMeter = WaveformMeter()
        }
        if inputMode == .microphone {
            startMicrophoneHealthMonitoring()
        }

        // Audio callbacks and classifier/preview observations drive semantic
        // rotation.  There is no independent wall-clock timer: paused capture
        // must not create empty or overlong chunks.
    }

    private func startMicrophoneCapture(
        recordingURL: URL?,
        temporaryDirectory: URL
    ) async throws {
        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { throw PipelineError.noInputDevice }
        guard format.sampleRate > 0 else { throw PipelineError.invalidInputFormat }

        let fullRecording: AVAudioFile?
        if let recordingURL {
            fullRecording = try AVAudioFile(
                forWriting: recordingURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } else {
            fullRecording = nil
        }

        try configureSession(
            format: format,
            recordingFile: fullRecording,
            chunkDirectory: temporaryDirectory
        )

        if #available(macOS 27, *) {
            try inputNode.installAudioTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] sourceBuffer, time in
                guard let self else { return }
                let buffer = AVAudioPCMBuffer(copying: sourceBuffer)
                self.write(buffer, at: time)
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, time in
                // All consumers finish reading before the tap returns.
                self?.write(buffer, at: time)
            }
        }
        stateLock.withLock { microphoneTapInstalled = true }

        engine.prepare()
        try engine.start()
    }

    private func startSystemAudioCapture(
        recordingURL: URL?,
        temporaryDirectory: URL
    ) async throws {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 2
        )!

        let fullRecording: AVAudioFile?
        if let recordingURL {
            fullRecording = try AVAudioFile(
                forWriting: recordingURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } else {
            fullRecording = nil
        }

        try configureSession(
            format: format,
            recordingFile: fullRecording,
            chunkDirectory: temporaryDirectory
        )

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw PipelineError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = Self.systemAudioConfiguration()
        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: systemAudioQueue
        )
        systemAudioStream = stream
        do {
            try await stream.startCapture()
        } catch {
            systemAudioStream = nil
            throw error
        }
    }

    static func systemAudioConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        return configuration
    }

    func pause() {
        stateLock.lock()
        capturePaused = true
        let mode = inputMode
        stateLock.unlock()
        if mode == .microphone, let audioEngine, audioEngine.isRunning {
            audioEngine.pause()
        }
    }

    func resume() throws {
        stateLock.lock()
        let mode = inputMode
        capturePaused = false
        lastAudioCallbackUptime = ProcessInfo.processInfo.systemUptime
        microphoneRecoveryAttempts = 0
        stateLock.unlock()
        switch mode {
        case .microphone:
            guard let audioEngine else { throw PipelineError.noActiveSession }
            guard !audioEngine.isRunning else { return }
            audioEngine.prepare()
            try audioEngine.start()
        case .systemAudio:
            guard systemAudioStream != nil else { throw PipelineError.noActiveSession }
        case nil:
            throw PipelineError.noActiveSession
        }
    }

    func stop() async {
        let started = ProcessInfo.processInfo.systemUptime
        await stopCaptureSource()
        // Capture is stopped and preview callbacks now reject new observations.
        // Keep cleanup joined, but do not delay the last ASR chunk behind preview finalization.
        async let previewFinished: Void = finishStreamingPreview()
        await waitForPendingSubmissions()
        await flushCurrentChunk(openNext: false, finishBoundary: true)
        let submitted = ProcessInfo.processInfo.systemUptime
        await transcriptionQueue.finish()
        let transcribed = ProcessInfo.processInfo.systemUptime
        await previewFinished
        closeFilesAndCleanUp()
        let finished = ProcessInfo.processInfo.systemUptime
        Logger(subsystem: "com.jianhongli.LiveLingo", category: "StopLatency").notice(
            "stop pipeline submit_ms=\(Int((submitted-started)*1000)) asr_wait_ms=\(Int((transcribed-submitted)*1000)) preview_join_cleanup_ms=\(Int((finished-transcribed)*1000)) total_ms=\(Int((finished-started)*1000))"
        )
    }

    func cancel() async {
        await stopCaptureSource()
        await cancelStreamingPreview()
        await waitForPendingSubmissions()
        await transcriptionQueue.cancel()
        closeFilesAndCleanUp()
    }

    private func stopCaptureSource() async {
        stateLock.withLock { isStopping = true }
        stopMicrophoneHealthMonitoring()

        let shouldRemoveMicrophoneTap = stateLock.withLock {
            let installed = microphoneTapInstalled
            microphoneTapInstalled = false
            return installed
        }
        if let audioEngine {
            if shouldRemoveMicrophoneTap {
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            audioEngine.stop()
        }
        if let stream = systemAudioStream {
            try? await stream.stopCapture()
            systemAudioStream = nil
        }
        let detector = stateLock.withLock { () -> SpeechActivityDetector? in
            let value = activityDetector
            activityDetector = nil
            return value
        }
        detector?.finish()
    }

    private func write(_ buffer: AVAudioPCMBuffer, at audioTime: AVAudioTime? = nil) {
        stateLock.lock()
        guard !capturePaused else {
            stateLock.unlock()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        lastAudioCallbackUptime = now
        microphoneRecoveryAttempts = 0
        let legacy = legacyPreview
        let detector = activityDetector
        let statistics = Self.audioStatistics(from: buffer)
        let level = waveformMeter.consume(sumSquares: statistics.sumSquares, count: statistics.count,
            peak: statistics.peak, duration: Double(buffer.frameLength) / buffer.format.sampleRate)
        let waveformHandler = level == nil ? nil : eventHandler
        do {
            try recordingFile?.write(from: buffer)
            try chunkFile?.write(from: buffer)
            capturedAudioDuration += Double(buffer.frameLength) / buffer.format.sampleRate
            stateLock.unlock()
        } catch {
            let handler = eventHandler
            stateLock.unlock()
            handler?(.failure("音频写入失败：\(error.localizedDescription)"))
            return
        }

        if let waveformHandler {
            waveformHandler(.audioLevel(level ?? 0))
        }

        detector?.analyze(buffer)
        evaluateBoundaryAndRotate()

        if #available(macOS 27, *) {
            writeModernPreview(buffer, at: audioTime)
        } else {
            legacy?.append(buffer)
        }
    }

    @available(macOS 27, *)
    private func writeModernPreview(_ buffer: AVAudioPCMBuffer, at audioTime: AVAudioTime?) {
        let (converter, continuation) = stateLock.withLock { (previewConverter, previewInputContinuation) }
        guard let converter, let continuation else { return }
        do {
            for input in try converter.convert(buffer, at: audioTime) {
                continuation.yield(input)
            }
        } catch {
            stateLock.withLock {
                previewConverter = nil
                previewInputContinuation = nil
            }
            continuation.finish()
        }
    }

    static func normalizedAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        let stats = audioStatistics(from: buffer)
        guard stats.count > 0 else { return 0 }
        return normalizedAudioLevel(rms: sqrt(stats.sumSquares / Double(stats.count)))
    }

    static func audioStatistics(from buffer: AVAudioPCMBuffer) -> (sumSquares: Double, count: Int, peak: Double) {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return (0, 0, 0) }

        var sumOfSquares = 0.0
        var peak = 0.0
        var sampleCount = 0
        let isInterleaved = buffer.format.isInterleaved

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { return (0, 0, 0) }
            let buffers = isInterleaved ? 1 : channelCount
            let samplesPerBuffer = isInterleaved ? frameCount * channelCount : frameCount
            for channel in 0..<buffers {
                for index in 0..<samplesPerBuffer {
                    let sample = Double(channels[channel][index])
                    if sample.isFinite {
                        sumOfSquares += sample * sample
                        peak = max(peak, abs(sample))
                    }
                }
            }
            sampleCount = buffers * samplesPerBuffer
        case .pcmFormatFloat64:
            let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for audioBuffer in audioBuffers {
                guard let data = audioBuffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Double.self)
                let samplesInBuffer = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
                for index in 0..<samplesInBuffer {
                    let sample = samples[index]
                    if sample.isFinite {
                        sumOfSquares += sample * sample
                        peak = max(peak, abs(sample))
                    }
                }
                sampleCount += samplesInBuffer
            }
        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else { return (0, 0, 0) }
            let buffers = isInterleaved ? 1 : channelCount
            let samplesPerBuffer = isInterleaved ? frameCount * channelCount : frameCount
            for channel in 0..<buffers {
                for index in 0..<samplesPerBuffer {
                    let sample = Double(channels[channel][index]) / 32_768.0
                    if sample.isFinite {
                        sumOfSquares += sample * sample
                        peak = max(peak, abs(sample))
                    }
                }
            }
            sampleCount = buffers * samplesPerBuffer
        case .pcmFormatInt32:
            guard let channels = buffer.int32ChannelData else { return (0, 0, 0) }
            let buffers = isInterleaved ? 1 : channelCount
            let samplesPerBuffer = isInterleaved ? frameCount * channelCount : frameCount
            for channel in 0..<buffers {
                for index in 0..<samplesPerBuffer {
                    let sample = Double(channels[channel][index]) / 2_147_483_648.0
                    if sample.isFinite {
                        sumOfSquares += sample * sample
                        peak = max(peak, abs(sample))
                    }
                }
            }
            sampleCount = buffers * samplesPerBuffer
        default:
            return (0, 0, 0)
        }

        guard sampleCount > 0 else { return (0, 0, 0) }
        return (sumOfSquares, sampleCount, peak)
    }

    static func normalizedAudioLevel(rms: Double) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return Float(min(1, max(0, (decibels + 60) / 60)))
    }

    private func startStreamingPreviewIfAvailable() async {
        if #available(macOS 27, *) { await startModernPreview(); return }
        guard let locale = stateLock.withLock({ previewSupportedLocale }) else { return }
        let preview = LegacySpeechPreview(locale: locale) { [weak self] text, start, end in
            self?.emitStreamingPreview(text: text, start: start, end: end)
        }
        stateLock.withLock { legacyPreview = preview }
    }

    @available(macOS 27, *)
    private func startModernPreview() async {
        guard let locale = stateLock.withLock({ previewSupportedLocale }) else { return }

        do {
            let transcriber = SpeechTranscriber(
                locale: locale,
                preset: .timeIndexedProgressiveTranscription
            )
            let modules: [any SpeechModule] = [transcriber]
            let analyzer = SpeechAnalyzer(
                modules: modules,
                options: .init(priority: .userInitiated, modelRetention: .whileInUse)
            )
            let converter = try await AnalyzerInputConverter.converter(compatibleWith: modules)
            try await analyzer.prepareToAnalyze(in: nil)

            let stream = AsyncStream<AnalyzerInput> { continuation in
                stateLock.withLock { previewInputContinuation = continuation }
            }

            stateLock.withLock {
                previewTranscriber = transcriber
                previewAnalyzer = analyzer
                previewConverter = converter
            }

            previewResultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard !Task.isCancelled else { break }
                        let text = String(result.text.characters)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        let start = result.range.start.seconds.isFinite
                            ? result.range.start.seconds
                            : 0
                        let duration = result.range.duration.seconds.isFinite
                            ? result.range.duration.seconds
                            : 0
                        self?.emitStreamingPreview(
                            text: text,
                            start: start,
                            end: start + duration
                        )
                    }
                } catch {
                    return
                }
            }

            previewAnalysisTask = Task {
                do {
                    try await analyzer.start(inputSequence: stream)
                } catch {
                    return
                }
            }
        } catch {
            await cancelStreamingPreview()
        }
    }

    private func emitStreamingPreview(text: String, start: TimeInterval, end: TimeInterval) {
        let handler = stateLock.withLock {
            guard !capturePaused, !isStopping else {
                return nil as (@Sendable (Event) -> Void)?
            }
            let observation = AuxiliaryTranscriptObservation(
                text: text,
                start: max(0, start),
                end: max(start, end)
            )
            if let replacementIndex = previewObservations.lastIndex(where: {
                abs($0.start - observation.start) < 0.05
            }) {
                previewObservations[replacementIndex] = observation
            } else {
                previewObservations.append(observation)
            }
            boundaryPolicy.observePreview(
                text: text,
                start: observation.start,
                end: observation.end,
                arrival: max(observation.end, capturedAudioDuration)
            )
            return eventHandler
        }
        handler?(.volatile(text: text, start: start, end: end))
        evaluateBoundaryAndRotate()
    }

    private func finishStreamingPreview() async {
        if #available(macOS 27, *) { await finishModernPreview(); return }
        stopLegacyPreview()
    }

    @available(macOS 27, *)
    private func finishModernPreview() async {
        let state = detachStreamingPreviewState()
        state.continuation?.finish()
        if let analyzer = state.analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        _ = await state.analysisTask?.result
        _ = await state.resultTask?.result
        state.analysisTask?.cancel()
        state.resultTask?.cancel()
        clearStreamingPreviewObjects()
    }

    private func cancelStreamingPreview() async {
        if #available(macOS 27, *) { await cancelModernPreview(); return }
        stopLegacyPreview()
    }

    private func stopLegacyPreview() {
        let preview = stateLock.withLock { let value = legacyPreview; legacyPreview = nil; return value }
        preview?.stop()
    }

    @available(macOS 27, *)
    private func cancelModernPreview() async {
        let state = detachStreamingPreviewState()
        state.continuation?.finish()
        await state.analyzer?.cancelAndFinishNow()
        state.analysisTask?.cancel()
        state.resultTask?.cancel()
        clearStreamingPreviewObjects()
    }

    @available(macOS 27, *)
    private func detachStreamingPreviewState() -> (
        continuation: AsyncStream<AnalyzerInput>.Continuation?,
        analyzer: SpeechAnalyzer?,
        analysisTask: Task<Void, Never>?,
        resultTask: Task<Void, Never>?
    ) {
        stateLock.withLock {
            let state = (
                previewInputContinuation,
                previewAnalyzer,
                previewAnalysisTask,
                previewResultTask
            )
            previewInputContinuation = nil
            previewConverter = nil
            return state
        }
    }

    @available(macOS 27, *)
    private func clearStreamingPreviewObjects() {
        stateLock.withLock {
            previewTranscriber = nil
            previewAnalyzer = nil
            previewConverter = nil
            previewInputContinuation = nil
            previewAnalysisTask = nil
            previewResultTask = nil
        }
    }

    private func startMicrophoneHealthMonitoring() {
        let engine = stateLock.withLock { () -> AVAudioEngine? in
            lastAudioCallbackUptime = ProcessInfo.processInfo.systemUptime
            microphoneRecoveryAttempts = 0
            microphoneRecoveryScheduled = false
            return audioEngine
        }
        guard let engine else { return }

        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleMicrophoneRecovery()
        }
        stateLock.withLock { microphoneConfigurationObserver = observer }

        microphoneWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
                guard let self else { break }
                self.checkMicrophoneCaptureHealth()
            }
        }
    }

    private func stopMicrophoneHealthMonitoring() {
        let monitoring = stateLock.withLock { () -> (NSObjectProtocol?, Task<Void, Never>?) in
            let observer = microphoneConfigurationObserver
            let watchdog = microphoneWatchdogTask
            microphoneConfigurationObserver = nil
            microphoneWatchdogTask = nil
            lastAudioCallbackUptime = nil
            microphoneRecoveryScheduled = false
            microphoneRecoveryAttempts = 0
            return (observer, watchdog)
        }
        monitoring.1?.cancel()
        if let observer = monitoring.0 {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func checkMicrophoneCaptureHealth() {
        let now = ProcessInfo.processInfo.systemUptime
        let stalled = stateLock.withLock {
            guard inputMode == .microphone else { return false }
            return Self.microphoneCaptureIsStalled(
                lastCallbackUptime: lastAudioCallbackUptime,
                now: now,
                isPaused: capturePaused,
                isStopping: isStopping
            )
        }
        if stalled {
            scheduleMicrophoneRecovery()
        }
    }

    private func scheduleMicrophoneRecovery() {
        let outcome = stateLock.withLock { () -> (shouldRecover: Bool, shouldFail: Bool, handler: (@Sendable (Event) -> Void)?) in
            guard inputMode == .microphone,
                  !capturePaused,
                  !isStopping,
                  !microphoneRecoveryScheduled
            else { return (false, false, nil) }

            if microphoneRecoveryAttempts >= Self.maximumMicrophoneRecoveryAttempts {
                microphoneRecoveryScheduled = true
                return (false, true, eventHandler)
            }
            microphoneRecoveryAttempts += 1
            microphoneRecoveryScheduled = true
            return (true, false, eventHandler)
        }

        if outcome.shouldFail {
            outcome.handler?(.failure("麦克风设备变化后未能自动恢复，请重新开始录音。"))
            return
        }
        guard outcome.shouldRecover else { return }

        microphoneRecoveryQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.performMicrophoneRecovery()
        }
    }

    private func performMicrophoneRecovery() {
        let now = ProcessInfo.processInfo.systemUptime
        let context = stateLock.withLock { () -> (AVAudioEngine, (@Sendable (Event) -> Void)?)? in
            guard inputMode == .microphone,
                  !capturePaused,
                  !isStopping,
                  let audioEngine
            else {
                microphoneRecoveryScheduled = false
                return nil
            }
            if audioEngine.isRunning,
               let lastAudioCallbackUptime,
               now - lastAudioCallbackUptime < Self.microphoneStallTimeout {
                microphoneRecoveryScheduled = false
                return nil
            }
            return (audioEngine, eventHandler)
        }
        guard let (engine, handler) = context else { return }

        do {
            engine.stop()
            engine.prepare()
            try engine.start()
            let shouldRemainRunning = stateLock.withLock { () -> Bool in
                microphoneRecoveryScheduled = false
                lastAudioCallbackUptime = ProcessInfo.processInfo.systemUptime
                return !isStopping && !capturePaused && inputMode == .microphone
            }
            if !shouldRemainRunning {
                engine.stop()
            }
        } catch {
            let shouldReport = stateLock.withLock { () -> Bool in
                microphoneRecoveryScheduled = false
                return !isStopping && !capturePaused && inputMode == .microphone
            }
            if shouldReport,
               stateLock.withLock({ microphoneRecoveryAttempts >= Self.maximumMicrophoneRecoveryAttempts }) {
                handler?(.failure("麦克风设备变化后恢复失败：\(error.localizedDescription)"))
            }
        }
    }

    static func microphoneCaptureIsStalled(
        lastCallbackUptime: TimeInterval?,
        now: TimeInterval,
        isPaused: Bool,
        isStopping: Bool
    ) -> Bool {
        guard !isPaused, !isStopping, let lastCallbackUptime else { return false }
        return now - lastCallbackUptime >= microphoneStallTimeout
    }

    private func flushCurrentChunk(openNext: Bool, finishBoundary: Bool = false) async {
        let snapshot = stateLock.withLock { () -> FlushSnapshot in
            let elapsed = capturedAudioDuration
            if finishBoundary {
                _ = boundaryPolicy.finish(at: elapsed)
            }
            return rotateCurrentChunkLocked(elapsed: elapsed, openNext: openNext)
        }
        if let job = snapshot.job, let handler = snapshot.handler {
            await transcriptionQueue.submit(job, handler: handler)
        }
    }

    private func configureSession(
        format: AVAudioFormat,
        recordingFile: AVAudioFile?,
        chunkDirectory: URL
    ) throws {
        let detector = SpeechActivityDetector()
        var detectorReady = false
        do {
            try detector.start(format: format) { [weak self] observation in
                self?.receiveSpeechActivity(observation)
            }
            detectorReady = true
        } catch {
            // Missing classifier evidence leaves the ten-second ceiling active.
            detector.finish()
        }
        do {
            try stateLock.withLock {
                inputFormat = format
                self.recordingFile = recordingFile
                self.chunkDirectory = chunkDirectory
                chunkStartedAt = 0
                nextChunkIndex = 0
                previewObservations = []
                boundaryPolicy = CausalBoundaryPolicy()
                capturedAudioDuration = 0
                activityDetector = detectorReady ? detector : nil
                try openNextChunkLocked()
            }
        } catch {
            detector.finish()
            throw error
        }
    }

    private func rotateCurrentChunkLocked(elapsed: TimeInterval, openNext: Bool) -> FlushSnapshot {
        let completedURL = chunkURL
        let completedLength = chunkFile?.length ?? 0
        let completedStart = chunkStartedAt
        let completedProfile = profile
        let appleEvidence = AuxiliaryTranslationHintExtractor.timeAlignedText(
            observations: previewObservations,
            start: completedStart,
            end: elapsed
        )
        previewObservations.removeAll { $0.end <= elapsed }
        chunkFile = nil
        chunkURL = nil
        chunkStartedAt = elapsed
        if openNext {
            do {
                try openNextChunkLocked()
            } catch {
                eventHandler?(.failure("无法建立下一段音频：\(error.localizedDescription)"))
            }
        }
        let handler = eventHandler
        if completedLength > 0, let completedURL {
            return FlushSnapshot(
                job: ChunkJob(
                    audioURL: completedURL,
                    modelKey: completedProfile.asrKey,
                    fallbackModelKey: completedProfile.fallbackASRKey,
                    start: completedStart,
                    end: elapsed,
                    appleEvidence: appleEvidence,
                    recordingURL: recordingFile?.url
                ),
                handler: handler
            )
        }
        if let completedURL { try? FileManager.default.removeItem(at: completedURL) }
        return FlushSnapshot(job: nil, handler: handler)
    }

    private func receiveSpeechActivity(_ observation: SpeechActivityObservation) {
        stateLock.withLock {
            boundaryPolicy.observeActivity(
                speech: observation.speech,
                start: observation.start,
                end: observation.end
            )
        }
        evaluateBoundaryAndRotate()
    }

    private func evaluateBoundaryAndRotate() {
        stateLock.withLock {
            guard !capturePaused, !isStopping,
                  boundaryPolicy.decision(at: capturedAudioDuration) != nil
            else { return }
            let snapshot = rotateCurrentChunkLocked(
                elapsed: capturedAudioDuration,
                openNext: true
            )
            guard let job = snapshot.job, let handler = snapshot.handler else { return }
            // Rotate and enqueue under the same lock so callbacks cannot reorder chunks.
            let previous = submissionTail
            submissionTail = Task { [transcriptionQueue] in
                if let previous { await previous.value }
                await transcriptionQueue.submit(job, handler: handler)
            }
        }
    }

    private func waitForPendingSubmissions() async {
        let task = stateLock.withLock { () -> Task<Void, Never>? in
            let value = submissionTail
            submissionTail = nil
            return value
        }
        await task?.value
    }

    private func openNextChunkLocked() throws {
        guard let chunkDirectory, let inputFormat else {
            throw PipelineError.temporaryDirectoryUnavailable
        }
        let url = chunkDirectory.appendingPathComponent(
            String(format: "chunk-%05d.wav", nextChunkIndex)
        )
        nextChunkIndex += 1
        chunkURL = url
        chunkFile = try AVAudioFile(
            forWriting: url,
            settings: inputFormat.settings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )
    }

    private func closeFilesAndCleanUp() {
        stateLock.lock()
        recordingFile = nil
        chunkFile = nil
        let directory = chunkDirectory
        chunkURL = nil
        chunkDirectory = nil
        inputFormat = nil
        audioEngine = nil
        systemAudioStream = nil
        inputMode = nil
        microphoneTapInstalled = false
        microphoneConfigurationObserver = nil
        microphoneWatchdogTask = nil
        lastAudioCallbackUptime = nil
        waveformMeter = WaveformMeter()
        microphoneRecoveryScheduled = false
        microphoneRecoveryAttempts = 0
        capturePaused = false
        isStopping = false
        eventHandler = nil
        modernPreviewStorage = nil
        legacyPreview = nil
        previewAnalysisTask = nil
        previewResultTask = nil
        previewObservations = []
        activityDetector = nil
        boundaryPolicy = CausalBoundaryPolicy()
        capturedAudioDuration = 0
        submissionTail = nil
        stateLock.unlock()

        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}

extension SpeechPipeline: SCStreamOutput, SCStreamDelegate {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription)
        else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return }
        buffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            stateLock.lock()
            let handler = eventHandler
            stateLock.unlock()
            handler?(.failure("系统音频读取失败（\(status)）。"))
            return
        }
        write(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        stateLock.lock()
        let shouldReport = !isStopping
        let handler = eventHandler
        stateLock.unlock()
        if shouldReport {
            handler?(.failure("系统音频内录已停止：\(error.localizedDescription)"))
        }
    }
}


// Only reject effectively digital silence; quiet speech must remain eligible.
enum DigitalSilenceGate {
    static func isSilent(_ url: URL) throws -> Bool {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
              file.processingFormat.commonFormat == .pcmFormatFloat32 else { return false }
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return false }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let value = channels[channel][frame]
                    if !value.isFinite || abs(value) > 0.00001 { return false }
                }
            }
        }
        return true
    }
}

#if LIVELINGO_CLI
extension SpeechPipeline {
    /// Feeds the same post-capture PCM path without opening an output device.
    func cliReplay(file: URL, recordingURL: URL,
                   eventHandler: @escaping @Sendable (Event) -> Void) async throws {
        self.eventHandler = eventHandler
        let audio = try AVAudioFile(forReading: file)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-CLI-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let output = try AVAudioFile(forWriting: recordingURL, settings: audio.processingFormat.settings)
        await startStreamingPreviewIfAvailable()
        try configureSession(format: audio.processingFormat, recordingFile: output, chunkDirectory: temporary)
        stateLock.withLock { capturePaused = false; isStopping = false; inputMode = .systemAudio }
        let start = ProcessInfo.processInfo.systemUptime
        while audio.framePosition < audio.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                frameCapacity: AVAudioFrameCount(audio.processingFormat.sampleRate * 0.05)) else {
                throw PipelineError.invalidInputFormat
            }
            try audio.read(into: buffer)
            write(buffer)
            let target = Double(audio.framePosition) / audio.processingFormat.sampleRate
            let delay = target - (ProcessInfo.processInfo.systemUptime-start)
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        }
    }
}
#endif

/// Accumulates every callback, so a pulse between display updates is retained.
struct WaveformMeter {
    private var sum = 0.0
    private var count = 0
    private var peak = 0.0
    private var duration = 0.0
    private var displayed: Float = 0

    mutating func consume(sumSquares: Double, count: Int, peak: Double, duration: Double) -> Float? {
        guard count > 0, sumSquares.isFinite, peak.isFinite, duration.isFinite, duration > 0 else { return nil }
        sum += max(0, sumSquares)
        self.count += count
        self.peak = max(self.peak, max(0, peak))
        self.duration += duration
        guard self.duration >= SpeechPipeline.waveformUpdateInterval else { return nil }
        let rms = sqrt(sum / Double(self.count))
        let average = SpeechPipeline.normalizedAudioLevel(rms: rms)
        let transient = SpeechPipeline.normalizedAudioLevel(rms: self.peak)
        let target = pow(average * 0.8 + transient * 0.2, 2)
        // Immediate attack; release depends on captured time rather than callback count.
        displayed = max(target, displayed * Float(exp(-self.duration / 0.22)))
        sum = 0; self.count = 0; self.peak = 0; self.duration = 0
        return displayed < 0.005 ? 0 : displayed
    }
}

/// A session-side record survives normal export and error-triggered saving.
/// Audio remains in recording.wav; diagnostic entries contain only failed/retried spans.
enum RecordingDiagnostics {
    private static let lock = NSLock()

    static func append(recordingURL: URL?, event: String, start: TimeInterval? = nil,
                       end: TimeInterval? = nil, detail: String, candidate: String? = nil) {
        let logger = Logger(subsystem: "com.jianhongli.LiveLingo", category: "RecordingDiagnostics")
        logger.notice("event=\(event, privacy: .public) detail=\(detail, privacy: .private)")
        guard let recordingURL else { return }
        lock.withLock {
            do {
                var row: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()),
                    "event": event, "detail": detail]
                if let start { row["start"] = start }
                if let end { row["end"] = end }
                if let candidate { row["candidate"] = candidate }
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                data.append(0x0a)
                let url = recordingURL.deletingLastPathComponent().appendingPathComponent("transcription-issues.jsonl")
                if !FileManager.default.fileExists(atPath: url.path) {
                    try data.write(to: url, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                }
            } catch {
                logger.error("Recording diagnostic write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func contextAudio(recordingURL: URL, start: TimeInterval, end: TimeInterval) throws -> URL {
        let input = try AVAudioFile(forReading: recordingURL)
        let rate = input.processingFormat.sampleRate
        let first = AVAudioFramePosition(max(0, start - 0.75) * rate)
        let last = min(input.length, AVAudioFramePosition((end + 0.75) * rate))
        guard last > first, last - first <= AVAudioFramePosition(rate * 90),
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                  frameCapacity: AVAudioFrameCount(last - first)) else {
            throw SpeechPipeline.PipelineError.invalidInputFormat
        }
        input.framePosition = first
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-retry-\(UUID().uuidString).wav")
        try autoreleasepool {
            let output = try AVAudioFile(forWriting: url, settings: input.processingFormat.settings)
            var remaining = AVAudioFrameCount(last - first)
            while remaining > 0 {
                try input.read(into: buffer, frameCount: remaining)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                remaining -= buffer.frameLength
            }
            if #available(macOS 15, *) { output.close() }
        }
        return url
    }
}
