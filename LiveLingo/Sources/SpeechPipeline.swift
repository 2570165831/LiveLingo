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
        /// `observedAt` is this pipeline's uptime when the observation was
        /// emitted, so the receiver can measure its own main-thread queueing.
        case volatile(text: String, start: TimeInterval, end: TimeInterval, observedAt: TimeInterval)
        case final(
            text: String,
            start: TimeInterval,
            end: TimeInterval,
            hints: [AuxiliaryTranslationHint]
        )
        case identifiedFinal(TranscriptionCommit)
        case processing(TranscriptionProcessingState)
        case transcriptionCandidate(TranscriptionCandidate)
        case captureGap(CaptureGap)
        case failure(String)
        case rejectedTranscript
        case transcriptionIssue(start: TimeInterval, end: TimeInterval, message: String)
    }

    enum PipelineError: LocalizedError {
        case noInputDevice
        case invalidInputFormat
        case incompatibleInputFormat
        case importFailed(String)
        case noActiveSession
        case temporaryDirectoryUnavailable
        case noDisplayAvailable

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "没有找到可用的麦克风输入。"
            case .invalidInputFormat:
                return "麦克风返回了无效的音频格式。"
            case .incompatibleInputFormat:
                return "新麦克风的音频格式无法转换到本次录音的保存格式。"
            case .importFailed(let detail):
                return "导入本地文件失败：\(detail)"
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
        var id: UUID = UUID()
        var sessionID: UUID? = nil
        var startFrame: Int64? = nil
        var endFrame: Int64? = nil
        var sampleRate: Double? = nil
        var captureStart: TimeInterval? = nil
        var captureEnd: TimeInterval? = nil
    }

    private struct FlushSnapshot: Sendable {
        let job: ChunkJob?
        let handler: (@Sendable (Event) -> Void)?
    }

    typealias TranscriptionQueue = DurableTranscriptionQueue

    static func preferredTranscript(
        primary: String?, fallback: String, audioDuration: TimeInterval = 10
    ) -> String {
        for candidate in [primary ?? "", fallback] {
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
    private let transcriptionQueue: TranscriptionQueue
    private let systemAudioQueue = DispatchQueue(label: "LiveLingo.SystemAudioCapture")
    private let microphoneRecoveryQueue = DispatchQueue(label: "LiveLingo.MicrophoneRecovery")
    private let previewLocale = Locale(identifier: "en-US")
    private var audioEngine: AVAudioEngine?
    private var systemAudioStream: SCStream?
    var hasRecordedAudio: Bool { stateLock.withLock { writtenFrames > 0 && sessionRecordingURL != nil } }
    private var recordingFile: AVAudioFile?
    private var chunkFile: AVAudioFile?
    private var chunkURL: URL?
    private var chunkDirectory: URL?
    private var inputFormat: AVAudioFormat?
    private let audioProcessingQueue = DispatchQueue(label: "LiveLingo.AudioProcessing", qos: .userInitiated)
    private var boundarySignal: DispatchSourceUserDataAdd!
    private var ingress: OwnedAudioCaptureBuffer?
    private var systemAudioSink: SystemAudioCaptureSink?
    private var systemRecoveryTask: Task<Void, Never>?
    private var systemRecoveryAttempts = 0
    private var generation = UUID()
    private var sessionID = UUID()
    private var identifiedEvents = false
    private var captureConfigured = false
    private var finalizerTask: Task<Void, Never>?
    private var terminalFailureSent = false
    private var terminalFailureDetails: [String] = []
    private var temporarySessionDirectory: URL?
    private var persistsSession = true
    private var sessionRecordingURL: URL?
    private var writtenFrames: Int64 = 0
    private var chunkStartFrame: Int64 = 0
    private var chunkID = UUID()
    private var chunkCaptureStart: TimeInterval?
    private var lastCaptureEnd: TimeInterval?

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

    /// 预览时序测量（只记时间与秒数，不记正文）。
    /// `firstAudioWriteUptime` 是本次会话第一个音频回调的时刻；
    /// `firstPreviewResultUptime` 是首条预览文本发出的时刻。
    private var firstAudioWriteUptime: TimeInterval?
    private var firstPreviewResultUptime: TimeInterval?
    private var lastPreviewResultLogUptime: TimeInterval = 0
    private var suppressedPreviewResultLogs = 0

    private static let previewLatencyLog = Logger(
        subsystem: "com.jianhongli.LiveLingo",
        category: "PreviewLatency"
    )

    private let beforeAudioWrite: (@Sendable () throws -> Void)?
    private let enableAudioAnalysis: Bool

    init(transcriber: TranscriptionQueue.Transcriber? = nil,
         beforeAudioWrite: (@Sendable () throws -> Void)? = nil,
         enableAudioAnalysis: Bool = true) {
        self.beforeAudioWrite = beforeAudioWrite
        self.enableAudioAnalysis = enableAudioAnalysis
        transcriptionQueue = transcriber.map { TranscriptionQueue(transcriber: $0) } ?? TranscriptionQueue()
        super.init()
        boundarySignal = DispatchSource.makeUserDataAddSource(queue: audioProcessingQueue)
        boundarySignal.setEventHandler { [weak self] in self?.rotateReadyChunk() }
        boundarySignal.resume()
    }

    deinit { boundarySignal?.cancel() }

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

    /// Establishes the durable queue before capture; no audio callback performs
    /// file creation, JSON persistence, conversion, analysis, or model work.
    private func beginSession(recordingURL: URL?, sessionID requestedID: UUID?, persistsSession: Bool? = nil,
                              eventHandler: @escaping @Sendable (Event) -> Void) async throws -> URL {
        if stateLock.withLock({ captureConfigured || finalizerTask != nil }) {
            await stopCapture(continueTranscribing: false)
        }
        let id = requestedID ?? UUID()
        let token = UUID()
        let root: URL
        if let recordingURL {
            guard !FileManager.default.fileExists(atPath: recordingURL.path) else {
                throw PipelineError.importFailed("保存位置已有录音，请使用新的课程目录。")
            }
            root = recordingURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } else {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-ASR-" + id.uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        stateLock.withLock {
            generation = token; sessionID = id; identifiedEvents = requestedID != nil
            self.eventHandler = eventHandler; capturePaused = false; isStopping = false
            terminalFailureSent = false; terminalFailureDetails = []; finalizerTask = nil; writtenFrames = 0
            systemRecoveryAttempts = 0
            sessionRecordingURL = recordingURL
            self.persistsSession = persistsSession ?? (recordingURL != nil)
            temporarySessionDirectory = recordingURL == nil ? root : nil
        }
        try await transcriptionQueue.configure(directory: root, sessionID: id,
            persistent: persistsSession ?? (recordingURL != nil), identified: requestedID != nil) { [weak self] event in
                guard let self, self.stateLock.withLock({ self.generation == token }) else { return }
                if case .failure(let message) = event { self.failCapture(message, generation: token) }
                else { eventHandler(event) }
            }
        return root.appendingPathComponent(DurableTranscriptionJournal.directoryName, isDirectory: true)
    }

    func start(inputMode: AudioInputMode, recordingURL: URL?, sessionID: UUID? = nil, persistsSession: Bool? = nil,
               eventHandler: @escaping @Sendable (Event) -> Void) async throws {
        let directory = try await beginSession(recordingURL: recordingURL, sessionID: sessionID,
            persistsSession: persistsSession, eventHandler: eventHandler)
        stateLock.withLock { self.inputMode = inputMode }
        do {
            await startStreamingPreviewIfAvailable()
            switch inputMode {
            case .microphone:
                try await startMicrophoneCapture(recordingURL: recordingURL, temporaryDirectory: directory)
            case .systemAudio:
                try await startSystemAudioCapture(recordingURL: recordingURL, temporaryDirectory: directory)
            }
            try transcriptionQueue.setCapturing(true)
        } catch {
            await stopCapture(continueTranscribing: false)
            throw error
        }
        if inputMode == .microphone { startMicrophoneHealthMonitoring() }
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

        try installMicrophoneTap(on: inputNode, format: format)

        engine.prepare()
        try engine.start()
    }

    private func makeIngress(format: AVAudioFormat) throws -> OwnedAudioCaptureBuffer {
        let (storage, token) = stateLock.withLock { (inputFormat ?? format, generation) }
        let bridge = CaptureFormatBridge(inputFormat: format, storageFormat: storage)
        guard bridge.isUsable else { throw PipelineError.incompatibleInputFormat }
        return try OwnedAudioCaptureBuffer(format: format, queue: audioProcessingQueue,
            consume: { [weak self] buffer, span in
                guard let self, self.stateLock.withLock({ self.generation == token }) else { return }
                let converted = try bridge.convert(buffer)
                if let error = self.write(converted, reportFailure: false, capturedSpan: span) { throw error }
            }, failed: { [weak self] failure in
                self?.captureBufferFailed(failure, generation: token)
            })
    }

    private func installMicrophoneTap(on node: AVAudioInputNode, format: AVAudioFormat) throws {
        let input = try makeIngress(format: format)
        stateLock.withLock { ingress = input }
        if #available(macOS 27, *) {
            try node.installAudioTap(onBus: 0, bufferSize: 2_048, format: format) { source, _ in
                _ = source.withUnsafeAudioBufferList { pointer in
                    input.copy(pointer, frames: source.frameLength, observedEnd: ProcessInfo.processInfo.systemUptime)
                }
            }
        } else {
            node.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in
                input.submit(buffer)
            }
        }
        stateLock.withLock { microphoneTapInstalled = true }
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

        try await openSystemAudioStream(generation: stateLock.withLock { generation })
    }

    private func openSystemAudioStream(generation token: UUID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first else { throw PipelineError.noDisplayAvailable }
        guard stateLock.withLock({ generation == token && !isStopping }) else { throw CancellationError() }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let input = try makeIngress(format: format)
        let sink = SystemAudioCaptureSink(ingress: input) { [weak self] stream, error in
            self?.scheduleSystemAudioRecovery(stream: stream, error: error, generation: token)
        }
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: Self.systemAudioConfiguration(), delegate: sink)
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: systemAudioQueue)
        let accepted = stateLock.withLock { () -> Bool in
            guard generation == token && !isStopping else { return false }
            ingress = input; systemAudioSink = sink; systemAudioStream = stream
            input.setPaused(capturePaused)
            return true
        }
        guard accepted else { input.seal(); throw CancellationError() }
        do { try await stream.startCapture() }
        catch {
            input.seal()
            stateLock.withLock { if systemAudioStream === stream { systemAudioStream = nil; systemAudioSink = nil } }
            throw error
        }
        if !stateLock.withLock({ generation == token && !isStopping && systemAudioStream === stream }) {
            input.seal(); try? await stream.stopCapture(); throw CancellationError()
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
        ingress?.setPaused(true)
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
        ingress?.setPaused(false)
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

    /// Capture finalization is shared by stop, cancellation, and all errors.
    /// Only this task closes the writer and publishes the final chunk.
    func stopCapture(continueTranscribing: Bool = true) async {
        let token = stateLock.withLock { generation }
        // Pause before the final chunk is submitted: live-only stop must not
        // wake a new repair request during capture drain.
        if !continueTranscribing || !stateLock.withLock({ persistsSession }) {
            do { try transcriptionQueue.requestPause() }
            catch { reportQueueFailure(error) }
        }
        let task = stateLock.withLock { () -> Task<Void, Never> in
            if let finalizerTask { return finalizerTask }
            let token = generation
            isStopping = true
            ingress?.seal()
            let task = Task { [self] in await finalizeCapture(generation: token) }
            finalizerTask = task
            return task
        }
        await task.value
        if (!continueTranscribing || !stateLock.withLock({ persistsSession })), stateLock.withLock({ generation == token }) {
            do { try transcriptionQueue.requestPause() }
            catch { reportQueueFailure(error) }
        }
    }

    func stop() async {
        let (token, id) = stateLock.withLock { (generation, sessionID) }
        await stopCapture()
        guard stateLock.withLock({ generation == token }) else { return }
        await transcriptionQueue.finish(sessionID: id)
        await cleanLiveOnlyWorkIfNeeded(generation: token)
    }

    func cancel() async {
        let token = stateLock.withLock { generation }
        await stopCapture(continueTranscribing: false)
        guard stateLock.withLock({ generation == token }) else { return }
        await transcriptionQueue.cancel()
        await cleanLiveOnlyWorkIfNeeded(generation: token)
    }

    func drainTranscription(sessionID: UUID? = nil) async { await transcriptionQueue.finish(sessionID: sessionID) }
    func pauseTranscription() async throws { try await transcriptionQueue.pause() }
    func requestPauseTranscription() throws { try transcriptionQueue.requestPause() }
    func resumeTranscription() throws { try transcriptionQueue.resume() }
    func retryTranscription(id: UUID) throws { try transcriptionQueue.retry(id: id) }
    func transcriptionWork() -> [TranscriptionWorkRecord] { transcriptionQueue.records }
    func transcriptionState() -> TranscriptionProcessingState? { transcriptionQueue.state }
    func retainExistingTranscript(id: UUID, text: String) throws { try transcriptionQueue.retainExistingText(id: id, text: text) }
    func preserveConflictingTranscript(id: UUID, sessionID: UUID, originalText: String,
                                       candidateText: String) throws {
        try transcriptionQueue.preserveConflictingTranscript(id: id, sessionID: sessionID,
            originalText: originalText, candidateText: candidateText)
    }
    func resolveTranscriptionCandidate(id: UUID, acceptedText: String?, expectedOriginal: String? = nil,
                                       expectedCandidate: String? = nil) throws {
        try transcriptionQueue.resolveCandidate(id: id, acceptedText: acceptedText,
            expectedOriginal: expectedOriginal, expectedCandidate: expectedCandidate)
    }
    func reconcileAcceptedTranscriptionCandidates(_ snapshot: SessionSnapshot) throws {
        try transcriptionQueue.reconcileAcceptedCandidates(snapshot)
    }

    /// Saving an in-progress live-only session changes retention, not its IDs
    /// or directory. AppModel owns the later verified whole-course migration.
    func updatePersistence(persistsSession: Bool) throws {
        let valid = stateLock.withLock { () -> Bool in
            guard captureConfigured, !isStopping,
                  !persistsSession || sessionRecordingURL != nil else { return false }
            self.persistsSession = persistsSession
            return true
        }
        guard valid else { throw PipelineError.noActiveSession }
        transcriptionQueue.setPersistence(persistsSession)
    }

    func restoreTranscription(directory: URL, sessionID: UUID, startPaused: Bool = true,
                              eventHandler: @escaping @Sendable (Event) -> Void) async throws {
        await stopCapture(continueTranscribing: false)
        let token = UUID()
        stateLock.withLock {
            generation = token; self.sessionID = sessionID; identifiedEvents = true
            self.eventHandler = eventHandler; temporarySessionDirectory = nil
            persistsSession = true
        }
        try await transcriptionQueue.configure(directory: directory, sessionID: sessionID,
            persistent: true, identified: true, restoring: true, startPaused: startPaused) { [weak self] event in
                guard let self, self.stateLock.withLock({ self.generation == token }) else { return }
                eventHandler(event)
            }
    }

    private func finalizeCapture(generation token: UUID) async {
        stopMicrophoneHealthMonitoring()
        let source = stateLock.withLock { () -> (OwnedAudioCaptureBuffer?, SCStream?, Task<Void, Never>?) in
            let state = (ingress, systemAudioStream, systemRecoveryTask)
            systemRecoveryTask = nil; systemAudioStream = nil
            return state
        }
        source.0?.seal(); source.2?.cancel()
        await withCheckedContinuation { continuation in
            microphoneRecoveryQueue.async { [self] in
                let engine = stateLock.withLock { () -> AVAudioEngine? in
                    guard generation == token else { return nil }
                    let engine = audioEngine
                    if microphoneTapInstalled { engine?.inputNode.removeTap(onBus: 0); microphoneTapInstalled = false }
                    return engine
                }
                engine?.stop()
                continuation.resume()
            }
        }
        if let stream = source.1 { try? await stream.stopCapture() }
        await source.0?.drain()
        await source.2?.value
        if let failure = source.0?.failureSnapshot { recordBufferGap(failure, generation: token) }
        await withCheckedContinuation { continuation in
            audioProcessingQueue.async { [self] in
                guard stateLock.withLock({ generation == token }) else { continuation.resume(); return }
                let detector = stateLock.withLock { let d = activityDetector; activityDetector = nil; return d }
                detector?.finish()
                flushChunkOnConsumer(openNext: false, finishBoundary: true)
                stateLock.withLock {
                    recordingFile = nil; chunkFile = nil; chunkURL = nil
                    ingress = nil; systemAudioSink = nil; audioEngine = nil
                    inputMode = nil; captureConfigured = false
                }
                do { try transcriptionQueue.setCapturing(false) }
                catch { reportQueueFailure(error) }
                continuation.resume()
            }
        }
        await cancelStreamingPreview()
    }

    private func cleanLiveOnlyWorkIfNeeded(generation token: UUID) async {
        guard let root = stateLock.withLock({ generation == token && !persistsSession ? temporarySessionDirectory : nil }) else { return }
        await transcriptionQueue.cancel()
        guard stateLock.withLock({ generation == token }) else { return }
        do {
            try FileManager.default.removeItem(at: root)
            stateLock.withLock { if temporarySessionDirectory == root { temporarySessionDirectory = nil } }
        } catch { reportQueueFailure(error) }
    }

    private func reportQueueFailure(_ error: Error) {
        failCapture("转写状态无法保存：\(error.localizedDescription)", generation: stateLock.withLock { generation })
    }

    private func failCapture(_ message: String, generation token: UUID) {
        let handler = stateLock.withLock { () -> (@Sendable (Event) -> Void)? in
            guard generation == token else { return nil }
            if !terminalFailureDetails.contains(message) { terminalFailureDetails.append(message) }
            guard !terminalFailureSent else { return nil }
            terminalFailureSent = true
            ingress?.seal()
            return eventHandler
        }
        guard let handler else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.stopCapture()
            let detail = self.stateLock.withLock { () -> String? in
                guard self.generation == token else { return nil }
                return self.terminalFailureDetails.joined(separator: "\n")
            }
            if let detail { handler(.failure(detail)) }
        }
    }

    private func captureBufferFailed(_ failure: OwnedAudioCaptureBuffer.Failure, generation token: UUID) {
        failCapture(failure.reason + " 已保存写入成功的录音，缺失区间将在收尾时记录。", generation: token)
    }

    private func recordBufferGap(_ failure: OwnedAudioCaptureBuffer.Failure, generation token: UUID) {
        guard let gap = stateLock.withLock({ () -> CaptureGap? in
            guard generation == token, let inputFormat else { return nil }
            return CaptureGap(sessionID: sessionID, lastWrittenFrame: writtenFrames,
                sampleRate: inputFormat.sampleRate, observedStart: failure.observedStart,
                observedEnd: max(failure.observedEnd, ProcessInfo.processInfo.systemUptime),
                rejectedFrames: failure.rejectedFrames, reason: failure.reason)
        }) else { return }
        do { try transcriptionQueue.addGap(gap) }
        catch { reportQueueFailure(error) }
    }

    @discardableResult
    private func write(_ buffer: AVAudioPCMBuffer, at audioTime: AVAudioTime? = nil,
                       reportFailure: Bool = true, capturedSpan: OwnedAudioCaptureBuffer.Span? = nil) -> Error? {
        stateLock.lock()
        guard captureConfigured else {
            stateLock.unlock()
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        lastAudioCallbackUptime = now
        // 首音频时刻只用于「首音频 → 首条预览结果」的时序测量。
        if firstAudioWriteUptime == nil { firstAudioWriteUptime = capturedSpan?.observedStart ?? now }
        let legacy = legacyPreview
        let detector = activityDetector
        let statistics = Self.audioStatistics(from: buffer)
        let level = waveformMeter.consume(sumSquares: statistics.sumSquares, count: statistics.count,
            peak: statistics.peak, duration: Double(buffer.frameLength) / buffer.format.sampleRate)
        let waveformHandler = level == nil ? nil : eventHandler
        do {
            try beforeAudioWrite?()
            try recordingFile?.write(from: buffer)
            try chunkFile?.write(from: buffer)
            writtenFrames += Int64(buffer.frameLength)
            capturedAudioDuration = Double(writtenFrames) / buffer.format.sampleRate
            if chunkCaptureStart == nil { chunkCaptureStart = capturedSpan?.observedStart }
            lastCaptureEnd = capturedSpan.map { $0.observedStart + Double($0.frames) / (ingress?.format.sampleRate ?? buffer.format.sampleRate) }

            stateLock.unlock()
        } catch {
            stateLock.unlock()
            if reportFailure { failCapture("音频写入失败：\(error.localizedDescription)", generation: stateLock.withLock { generation }) }
            return error
        }

        if let waveformHandler {
            waveformHandler(.audioLevel(level ?? 0))
        }

        if enableAudioAnalysis, let owned = Self.ownedAnalysisCopy(buffer) {
            detector?.analyze(owned)
            if #available(macOS 27, *) { writeModernPreview(owned, at: audioTime) }
            else { legacy?.append(owned) }
        }
        rotateReadyChunk()
        return nil
    }

    private static func ownedAnalysisCopy(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard input.frameLength > 0,
              let output = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return nil }
        output.frameLength = input.frameLength
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        for i in 0..<min(from.count, to.count) {
            guard let source = from[i].mData, let destination = to[i].mData else { return nil }
            memcpy(destination, source, min(Int(from[i].mDataByteSize), Int(to[i].mDataByteSize)))
        }
        return output
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
        guard let locale = stateLock.withLock({ previewSupportedLocale }) else {
            Self.previewLatencyLog.notice("preview event=backend backend=none reason=legacy_unavailable")
            return
        }
        let token = stateLock.withLock { generation }
        let preview = LegacySpeechPreview(locale: locale) { [weak self] text, start, end in
            self?.emitStreamingPreview(text: text, start: start, end: end, generation: token)
        }
        stateLock.withLock { legacyPreview = preview }
        Self.previewLatencyLog.notice("preview event=backend backend=legacy")
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

            let token = stateLock.withLock { generation }
            let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(2)) { continuation in
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
                            end: start + duration,
                            generation: token
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
            Self.previewLatencyLog.notice("preview event=backend backend=modern")
        } catch {
            Self.previewLatencyLog.notice("preview event=backend backend=none reason=modern_unavailable")
            await cancelStreamingPreview()
        }
    }

    private func emitStreamingPreview(text: String, start: TimeInterval, end: TimeInterval, generation token: UUID) {
        let observedAt = ProcessInfo.processInfo.systemUptime
        let emission = stateLock.withLock { () -> (
            handler: (@Sendable (Event) -> Void)?,
            isFirst: Bool,
            shouldLog: Bool,
            suppressed: Int,
            capturedAudioEnd: TimeInterval,
            firstAudio: TimeInterval?
        ) in
            guard generation == token, !capturePaused, !isStopping else { return (nil, false, false, 0, 0, nil) }
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
            let isFirst = firstPreviewResultUptime == nil
            if isFirst { firstPreviewResultUptime = observedAt }
            // 计数器和 configureSession/closeFilesAndCleanUp 共享 stateLock：
            // 先在同一把锁里决定是否记录并记账，再在锁外真正写日志。
            let shouldLog = isFirst || observedAt - lastPreviewResultLogUptime >= 1
            var suppressed = 0
            if shouldLog {
                suppressed = suppressedPreviewResultLogs
                suppressedPreviewResultLogs = 0
                lastPreviewResultLogUptime = observedAt
            } else {
                suppressedPreviewResultLogs += 1
            }
            return (eventHandler, isFirst, shouldLog, suppressed, capturedAudioDuration, firstAudioWriteUptime)
        }
        if let handler = emission.handler {
            if emission.shouldLog {
                Self.logPreviewObservation(
                    isFirst: emission.isFirst,
                    capturedAudioEnd: emission.capturedAudioEnd,
                    rangeEnd: end,
                    firstAudio: emission.firstAudio,
                    suppressed: emission.suppressed,
                    observedAt: observedAt
                )
            }
            handler(.volatile(text: text, start: start, end: end, observedAt: observedAt))
        }
        evaluateBoundaryAndRotate()
    }

    /// 预览识别结果的时序。注意测量边界：
    /// `end` 是识别结果在音频时间轴上的末尾，**不等于**人实际说完这句话的时刻；
    /// 因此这里记录的是「这条结果落后已采集音频多远」，而不是「说话结束后多久」。
    /// 纯日志：调用方已经（在 stateLock 内）决定这次要不要记，这里不再改状态。
    private static func logPreviewObservation(isFirst: Bool, capturedAudioEnd: TimeInterval,
                                              rangeEnd: TimeInterval, firstAudio: TimeInterval?,
                                              suppressed: Int, observedAt: TimeInterval) {
        let lag = previewMilliseconds(max(0, capturedAudioEnd - max(0, rangeEnd)))
        if isFirst {
            let sinceFirstAudio = firstAudio.map {
                " first_audio_to_result_ms=\(previewMilliseconds(max(0, observedAt - $0)))"
            } ?? ""
            previewLatencyLog.notice("preview event=first_result\(sinceFirstAudio, privacy: .public) captured_since_range_end_ms=\(lag, privacy: .public)")
            return
        }
        // 结果可能很密集：1 秒窗口，只保留最后一次并统计被压掉多少条。
        previewLatencyLog.notice("preview event=result captured_since_range_end_ms=\(lag, privacy: .public) suppressed=\(suppressed, privacy: .public)")
    }

    private static func previewMilliseconds(_ value: TimeInterval) -> Int {
        Int(max(0, value) * 1_000)
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
                lastCallbackUptime: ingress?.lastAcceptedUptime ?? lastAudioCallbackUptime,
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
        let plan = stateLock.withLock { () -> (UUID, Bool)? in
            guard inputMode == .microphone, !capturePaused, !isStopping, !microphoneRecoveryScheduled else { return nil }
            microphoneRecoveryScheduled = true
            if microphoneRecoveryAttempts >= Self.maximumMicrophoneRecoveryAttempts { return (generation, false) }
            microphoneRecoveryAttempts += 1
            return (generation, true)
        }
        guard let (token, recover) = plan else { return }
        guard recover else {
            failCapture("麦克风恢复次数已达上限，已录制内容与处理进度保留。", generation: token)
            return
        }
        microphoneRecoveryQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.performMicrophoneRecovery(generation: token)
        }
    }

    private func performMicrophoneRecovery(generation token: UUID) {
        let context = stateLock.withLock { () -> (AVAudioEngine, AVAudioFormat?, OwnedAudioCaptureBuffer?)? in
            guard generation == token, inputMode == .microphone, !capturePaused, !isStopping, let audioEngine else { return nil }
            return (audioEngine, inputFormat, ingress)
        }
        guard let (engine, storage, previous) = context else { return }
        let start = previous?.lastAcceptedUptime ?? ProcessInfo.processInfo.systemUptime
        previous?.seal()
        if stateLock.withLock({ microphoneTapInstalled }) {
            engine.inputNode.removeTap(onBus: 0)
            stateLock.withLock { microphoneTapInstalled = false }
        }
        engine.stop()
        previous?.drainSynchronously()
        audioProcessingQueue.sync { flushChunkOnConsumer(openNext: true, finishBoundary: false) }
        do {
            guard stateLock.withLock({ generation == token && !isStopping && !capturePaused }) else { return }
            let format = engine.inputNode.outputFormat(forBus: 0)
            switch Self.microphoneRecoveryPlan(forOutputFormat: format, storageFormat: storage) {
            case .unavailable: throw PipelineError.noInputDevice
            case .incompatible: throw PipelineError.incompatibleInputFormat
            case .direct, .convert: try installMicrophoneTap(on: engine.inputNode, format: format)
            }
            engine.prepare(); try engine.start()
            let running = stateLock.withLock { () -> Bool in
                guard generation == token else { return false }
                microphoneRecoveryScheduled = false
                lastAudioCallbackUptime = ProcessInfo.processInfo.systemUptime
                return !isStopping && !capturePaused
            }
            if !running { engine.stop(); return }
            recordInterruption(since: start, reason: "麦克风设备切换", generation: token)
        } catch {
            let retry = stateLock.withLock { () -> Bool in
                guard generation == token else { return false }
                microphoneRecoveryScheduled = false
                return !isStopping && !capturePaused
            }
            guard retry else { return }
            recordInterruption(since: start, reason: "麦克风恢复失败", generation: token)
            scheduleMicrophoneRecovery()
        }
    }

    private func scheduleSystemAudioRecovery(stream: SCStream, error: Error, generation token: UUID) {
        stateLock.withLock {
            guard generation == token, systemAudioStream === stream, !isStopping,
                  systemRecoveryTask == nil else { return }
            let previous = ingress
            previous?.seal()
            systemAudioStream = nil
            let start = previous?.lastAcceptedUptime ?? ProcessInfo.processInfo.systemUptime
            let detached = DetachedSystemAudioStream(stream: stream)
            systemRecoveryTask = Task { [weak self] in
                guard let self else { return }
                try? await detached.stream.stopCapture()
                await previous?.drain()
                await self.flushCurrentChunk(openNext: true)
                while !Task.isCancelled {
                    let attempt = self.stateLock.withLock { () -> Int? in
                        guard self.generation == token, !self.isStopping else { return nil }
                        self.systemRecoveryAttempts += 1
                        return self.systemRecoveryAttempts
                    }
                    guard let attempt, attempt <= Self.maximumMicrophoneRecoveryAttempts else { break }
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                        try await self.openSystemAudioStream(generation: token)
                        self.recordInterruption(since: start, reason: "系统内录恢复", generation: token)
                        self.stateLock.withLock {
                            if self.generation == token { self.systemRecoveryTask = nil }
                        }
                        return
                    } catch is CancellationError { break }
                    catch { continue }
                }
                let report = self.stateLock.withLock { () -> Bool in
                    guard self.generation == token else { return false }
                    self.systemRecoveryTask = nil
                    return !self.isStopping && !Task.isCancelled
                }
                if report {
                    self.recordInterruption(since: start, reason: "系统内录恢复失败", generation: token)
                    self.failCapture("系统内录未能恢复，已保存录音与待处理转写。", generation: token)
                }
            }
        }
    }

    private func recordInterruption(since start: TimeInterval, reason: String, generation token: UUID) {
        let end = ProcessInfo.processInfo.systemUptime
        guard end >= start else { return }
        guard let gap = stateLock.withLock({ () -> CaptureGap? in
            guard generation == token, let inputFormat else { return nil }
            return CaptureGap(sessionID: sessionID, lastWrittenFrame: writtenFrames,
                sampleRate: inputFormat.sampleRate, observedStart: start, observedEnd: end,
                rejectedFrames: nil, reason: reason)
        }) else { return }
        do { try transcriptionQueue.addGap(gap) }
        catch { reportQueueFailure(error) }
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

    /// What a configuration change must do before the engine can restart.
    /// Pure so device removal and sample-rate changes are covered by tests
    /// without touching real audio hardware.
    enum MicrophoneRecoveryPlan: Equatable {
        case unavailable
        case direct
        case convert
        case incompatible
    }

    static func microphoneRecoveryPlan(
        forOutputFormat format: AVAudioFormat?,
        storageFormat: AVAudioFormat?
    ) -> MicrophoneRecoveryPlan {
        guard let format, format.channelCount > 0, format.sampleRate > 0 else { return .unavailable }
        guard let storageFormat, storageFormat.channelCount > 0, storageFormat.sampleRate > 0 else {
            return .direct
        }
        if formatsMatch(format, storageFormat) { return .direct }
        return AVAudioConverter(from: format, to: storageFormat) != nil ? .convert : .incompatible
    }

    static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private func flushCurrentChunk(openNext: Bool, finishBoundary: Bool = false) async {
        await withCheckedContinuation { continuation in
            audioProcessingQueue.async { [self] in
                flushChunkOnConsumer(openNext: openNext, finishBoundary: finishBoundary)
                continuation.resume()
            }
        }
    }

    private func flushChunkOnConsumer(openNext: Bool, finishBoundary: Bool = false) {
        let snapshot = stateLock.withLock { () -> FlushSnapshot in
            if finishBoundary { _ = boundaryPolicy.finish(at: capturedAudioDuration) }
            return rotateCurrentChunkLocked(elapsed: capturedAudioDuration, openNext: openNext)
        }
        if let job = snapshot.job, let handler = snapshot.handler { transcriptionQueue.submit(job, handler: handler) }
    }

    private func configureSession(
        format: AVAudioFormat,
        recordingFile: AVAudioFile?,
        chunkDirectory: URL
    ) throws {
        let token = stateLock.withLock { generation }
        let detector = SpeechActivityDetector()
        var detectorReady = false
        do {
            guard enableAudioAnalysis else { throw PipelineError.invalidInputFormat }
            try detector.start(format: format) { [weak self] observation in
                self?.receiveSpeechActivity(observation, generation: token)
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
                writtenFrames = 0; chunkStartFrame = 0
                chunkCaptureStart = nil; lastCaptureEnd = nil
                captureConfigured = true
                firstAudioWriteUptime = nil
                firstPreviewResultUptime = nil
                lastPreviewResultLogUptime = 0
                suppressedPreviewResultLogs = 0
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
        let completedID = chunkID
        let completedFrame = chunkStartFrame
        let captureStart = chunkCaptureStart
        let captureEnd = lastCaptureEnd
        let appleEvidence = AuxiliaryTranslationHintExtractor.timeAlignedText(
            observations: previewObservations,
            start: completedStart,
            end: elapsed
        )
        previewObservations.removeAll { $0.end <= elapsed }
        chunkFile = nil
        chunkURL = nil
        chunkStartedAt = elapsed
        chunkStartFrame = writtenFrames; chunkCaptureStart = nil
        if openNext {
            do {
                try openNextChunkLocked()
            } catch {
                let token = generation
                let message = "无法建立下一段音频：\(error.localizedDescription)"
                audioProcessingQueue.async { [weak self] in self?.failCapture(message, generation: token) }
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
                    recordingURL: sessionRecordingURL,
                    id: completedID, sessionID: sessionID,
                    startFrame: completedFrame, endFrame: writtenFrames,
                    sampleRate: inputFormat?.sampleRate, captureStart: captureStart, captureEnd: captureEnd
                ),
                handler: handler
            )
        }
        if let completedURL { try? FileManager.default.removeItem(at: completedURL) }
        return FlushSnapshot(job: nil, handler: handler)
    }

    private func receiveSpeechActivity(_ observation: SpeechActivityObservation, generation token: UUID) {
        stateLock.withLock {
            guard generation == token, !isStopping else { return }
            boundaryPolicy.observeActivity(
                speech: observation.speech,
                start: observation.start,
                end: observation.end
            )
        }
        evaluateBoundaryAndRotate()
    }

    private func evaluateBoundaryAndRotate() { boundarySignal.add(data: 1) }

    private func rotateReadyChunk() {
        let snapshot = stateLock.withLock { () -> FlushSnapshot? in
            guard captureConfigured, !isStopping,
                  boundaryPolicy.decision(at: capturedAudioDuration) != nil else { return nil }
            return rotateCurrentChunkLocked(elapsed: capturedAudioDuration, openNext: true)
        }
        if let snapshot, let job = snapshot.job, let handler = snapshot.handler {
            transcriptionQueue.submit(job, handler: handler)
        }
    }

    private func openNextChunkLocked() throws {
        guard let chunkDirectory, let inputFormat else {
            throw PipelineError.temporaryDirectoryUnavailable
        }
        chunkID = UUID()
        let url = chunkDirectory.appendingPathComponent("chunk-" + chunkID.uuidString + ".wav")
        try DurableTranscriptionJournal.stageCapture(CaptureChunkDescriptor(id: chunkID, sessionID: sessionID,
            ordinal: nextChunkIndex, audioFile: url.lastPathComponent, recordingFile: sessionRecordingURL?.lastPathComponent,
            startFrame: writtenFrames, sampleRate: inputFormat.sampleRate,
            modelKey: profile.asrKey, fallbackModelKey: profile.fallbackASRKey), directory: chunkDirectory)
        nextChunkIndex += 1
        chunkURL = url
        chunkFile = try AVAudioFile(
            forWriting: url,
            settings: inputFormat.settings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )
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

/// 把本地音频/视频文件解码成流水线统一的 PCM 格式。
/// 不联网、不改动源文件；只依赖系统 AVFoundation，不需要外部 ffmpeg。
enum MediaFileImport {
    /// 导入统一使用的存储格式：ASR 原生的 16 kHz 单声道 float32（非交错），
    /// 一场 90 分钟的课约 345 MB，比按原始 48 kHz 立体声存小得多。
    static let storageFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    enum ImportError: LocalizedError {
        case missingFile
        case noAudioTrack
        case unreadable(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .missingFile: return "找不到要导入的文件。"
            case .noAudioTrack: return "这个文件里没有音频轨道。"
            case .unreadable(let detail): return "无法读取该文件的音频：\(detail)"
            case .empty: return "这个文件没有可用的音频内容。"
            }
        }
    }

    /// AVFoundation 打不开的封装（实测 MKV、WebM 都会失败）会抛 "Cannot Open"。
    /// 直接把它换成用户能照做的说明并列出可用格式，而不是把系统原文丢给用户。
    static func readableFailureHint(for error: Error) -> String {
        let raw = error.localizedDescription
        if (error as NSError).code == -11_828 || raw.localizedCaseInsensitiveContains("cannot open") {
            return "系统不支持这个封装格式。请先转成 MP4、MOV、M4A、WAV、MP3、FLAC 或 AIFF 再导入。"
        }
        // 2026-09-18：截断/损坏的音频会让 AVFoundation 抛**泛化**错误 ✗
        //（实测三种坏文件都只得到 "The operation could not be completed" ✗ —— 用户看了等于没看 ✓）。
        // 这类 NSError 的本地化文案没有任何可操作信息 ✓，换成能指导下一步的中文 ✓。
        let genericAndUnhelpful = raw.isEmpty
            || raw.localizedCaseInsensitiveContains("could not be completed")
            || raw.localizedCaseInsensitiveContains("operation couldn")
        if genericAndUnhelpful {
            return "文件可能损坏或被截断；请先用播放器确认它能正常打开，或换一个文件再试。"
        }
        return raw
    }

    /// 逐块解码并交给 `sink`。返回解码到的总帧数。
    @discardableResult
    static func decode(
        _ fileURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        sink: (AVAudioPCMBuffer) async throws -> Void
    ) async throws -> AVAudioFramePosition {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw ImportError.missingFile }
        // 先用系统类型判定挡掉非媒体文件：否则 AVFoundation 会抛出 -11828 之类的
        // 原始错误，既看不懂又可能卡很久。
        let contentType = try? fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType
        if let contentType,
           !(contentType.conforms(to: .audio) || contentType.conforms(to: .movie)
             || contentType.conforms(to: .audiovisualContent)) {
            throw ImportError.unreadable("不是音频或视频文件（\(contentType.localizedDescription ?? contentType.identifier)）")
        }

        let asset = AVURLAsset(url: fileURL)
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .audio) }
        catch { throw ImportError.unreadable(readableFailureHint(for: error)) }
        // 多条音轨时优先取容器标为"启用"的那条：真实课程录像常有原声轨 + 配音/解说轨，
        // 而默认音轨往往不是第一条（实测 ffmpeg -disposition default 落在第二条时，
        // 之前会转错音轨）。没有启用标记时退回第一条。
        // 用异步 load(.isEnabled)：同步的 isEnabled 在 macOS 13 起已废弃。
        var enabledTrack: AVAssetTrack?
        for candidate in tracks where (try? await candidate.load(.isEnabled)) == true {
            enabledTrack = candidate
            break
        }
        guard let track = enabledTrack ?? tracks.first else {
            throw ImportError.noAudioTrack
        }
        let totalSeconds = ((try? await asset.load(.duration))?.seconds).flatMap { $0.isFinite ? max(0, $0) : 0 } ?? 0

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw ImportError.unreadable(readableFailureHint(for: error)) }   // 2026-09-18：别把泛化英文抛给用户 ✗
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: storageFormat.sampleRate,
            AVNumberOfChannelsKey: Int(storageFormat.channelCount),
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ImportError.unreadable("无法为该文件建立音频读取通道") }
        reader.add(output)
        guard reader.startReading() else {
            throw ImportError.unreadable(reader.error?.localizedDescription ?? "读取器启动失败")
        }
        defer { reader.cancelReading() }

        var framesWritten: AVAudioFramePosition = 0
        var delivered = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let description = CMSampleBufferGetFormatDescription(sample),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let format = AVAudioFormat(streamDescription: streamDescription) else { continue }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
            else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
            )
            guard status == noErr else { throw ImportError.unreadable("音频数据拷贝失败") }
            try await sink(buffer)
            delivered += 1
            framesWritten += AVAudioFramePosition(frames)
            if let onProgress, totalSeconds > 0 {
                onProgress(min(1, Double(framesWritten) / storageFormat.sampleRate / totalSeconds))
            }
        }
        if reader.status == .failed {
            throw ImportError.unreadable(reader.error?.localizedDescription ?? "读取中断")
        }
        guard delivered > 0, framesWritten > 0 else { throw ImportError.empty }
        return framesWritten
    }
}

extension SpeechPipeline {
    /// 导入上限：同时最多允许 4 个分块在转写队列里排着，喂得更快就等一等。
    static let importBacklogLimit = 4

    /// 把本地音频/视频文件喂进与实时采集**完全相同**的分块、转写、翻译路径。
    /// 与 CLI 回放的差别：不按实时速度播放，而是尽快解码喂入（用背压保证不堆积），
    /// 因此一场 90 分钟的课不需要 90 分钟。停止/保存仍由调用方走 `stop()`。
    func importMediaFile(
        _ fileURL: URL,
        recordingURL: URL?,
        sessionID: UUID? = nil,
        persistsSession: Bool? = nil,
        eventHandler: @escaping @Sendable (Event) -> Void,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let temporaryDirectory = try await beginSession(recordingURL: recordingURL, sessionID: sessionID,
            persistsSession: persistsSession, eventHandler: eventHandler)
        let token = stateLock.withLock { generation }
        let format = MediaFileImport.storageFormat
        do {
            let output = try recordingURL.map {
                try AVAudioFile(forWriting: $0, settings: format.settings,
                                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            }
            try configureSession(format: format, recordingFile: output, chunkDirectory: temporaryDirectory)
        } catch {
            await stopCapture(continueTranscribing: false)
            throw error
        }

        stateLock.withLock {
            capturePaused = false
            isStopping = false
        }

        try transcriptionQueue.setCapturing(true)
        do {
            try await MediaFileImport.decode(fileURL, onProgress: onProgress) { [weak self] buffer in
                guard let self else { throw CancellationError() }
                let transfer = DecodedAudioTransfer(buffer: buffer)
                let error: Error? = await withCheckedContinuation { continuation in
                    self.audioProcessingQueue.async {
                        guard self.stateLock.withLock({ self.generation == token && !self.isStopping }) else {
                            continuation.resume(returning: CancellationError()); return
                        }
                        continuation.resume(returning: self.write(transfer.buffer, reportFailure: false))
                    }
                }
                if let error { throw MediaFileImport.ImportError.unreadable("音频写入失败：\(error.localizedDescription)") }
                // 有界背压：转写落后时就等一下，别把整场课的分块全堆到磁盘上。
                while self.transcriptionQueue.inFlightCount >= Self.importBacklogLimit {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(40))
                }
            }
        } catch {
            // Queued ASR jobs still own these files. stop()/cancel() joins them
            // before closeFilesAndCleanUp removes the directory.
            throw error
        }
    }
}

#if DEBUG
extension SpeechPipeline {
    /// Test-only input: no audio device, permission, recognizer, or model startup.
    func startSyntheticCapture(format: AVAudioFormat, recordingURL: URL?, sessionID: UUID, persistsSession: Bool? = nil,
                               eventHandler: @escaping @Sendable (Event) -> Void) async throws -> OwnedAudioCaptureBuffer {
        let directory = try await beginSession(recordingURL: recordingURL, sessionID: sessionID,
            persistsSession: persistsSession, eventHandler: eventHandler)
        let file = try recordingURL.map { try AVAudioFile(forWriting: $0, settings: format.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved) }
        try configureSession(format: format, recordingFile: file, chunkDirectory: directory)
        let input = try makeIngress(format: format)
        stateLock.withLock { ingress = input }
        try transcriptionQueue.setCapturing(true)
        return input
    }
    var syntheticWorkDirectory: URL? { transcriptionQueue.journalDirectory }
}
#endif

#if LIVELINGO_CLI
extension SpeechPipeline {
    /// Feeds the same post-capture PCM path without opening an output device.
    func cliReplay(file: URL, recordingURL: URL, sessionID: UUID,
                   eventHandler: @escaping @Sendable (Event) -> Void) async throws {
        let temporary = try await beginSession(recordingURL: recordingURL, sessionID: sessionID,
                                               persistsSession: true, eventHandler: eventHandler)
        let audio = try AVAudioFile(forReading: file)
        let output = try AVAudioFile(forWriting: recordingURL, settings: audio.processingFormat.settings)
        await startStreamingPreviewIfAvailable()
        try configureSession(format: audio.processingFormat, recordingFile: output, chunkDirectory: temporary)
        try transcriptionQueue.setCapturing(true)
        stateLock.withLock { capturePaused = false; isStopping = false; inputMode = .systemAudio }
        let start = ProcessInfo.processInfo.systemUptime
        while audio.framePosition < audio.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                frameCapacity: AVAudioFrameCount(audio.processingFormat.sampleRate * 0.05)) else {
                throw PipelineError.invalidInputFormat
            }
            try audio.read(into: buffer)
            let transfer = DecodedAudioTransfer(buffer: buffer)
            let failure = await withCheckedContinuation { continuation in
                audioProcessingQueue.async { continuation.resume(returning: self.write(transfer.buffer, reportFailure: false)) }
            }
            if let failure { throw failure }
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

/// Reads PCM/float WAV data that may still be growing.
///
/// The recorder writes through `AVAudioFile`, which keeps the `data` chunk
/// length at zero until the file is closed, so `AVAudioFile(forReading:)`
/// reports `length == 0` for a recording in progress even though audio is
/// already on disk. This reader parses the RIFF chunks itself, takes a size
/// snapshot, tolerates a stale or short `data` length, drops an incomplete
/// trailing frame and never writes to the original recording.
enum WAVContextClip {
    struct Layout: Equatable {
        let formatTag: UInt16
        let channelCount: Int
        let sampleRate: Double
        let bitsPerSample: Int
        let blockAlign: Int
        let dataOffset: Int
        let dataByteCount: Int

        var frameCount: Int { blockAlign > 0 ? dataByteCount / blockAlign : 0 }
    }

    enum ClipError: LocalizedError, Equatable {
        case fileMissing
        case notWaveFile
        case malformedHeader
        case unsupportedEncoding(UInt16)
        case recordingEmpty
        case rangeNotWrittenYet
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .fileMissing: return "录音文件不存在，无法提取上下文音频。"
            case .notWaveFile: return "录音文件不是 WAV 格式，无法提取上下文音频。"
            case .malformedHeader: return "录音文件头不完整，暂时无法提取上下文音频。"
            case .unsupportedEncoding(let tag): return "录音编码不受支持（tag \(tag)），无法提取上下文音频。"
            case .recordingEmpty: return "录音数据区还没有可读取的音频。"
            case .rangeNotWrittenYet: return "该片段的音频还没有写入录音文件。"
            case .readFailed(let detail): return "读取录音数据失败：\(detail)"
            }
        }
    }

    static let maximumClipSeconds: TimeInterval = 90
    static let maximumClipBytes = 64 << 20

    static func readLayout(at url: URL) throws -> Layout {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ClipError.fileMissing }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()).map { Int($0) } ?? 0
        guard fileSize >= 12 else { throw ClipError.recordingEmpty }
        try handle.seek(toOffset: 0)
        guard let riff = try? handle.read(upToCount: 12), riff.count == 12,
              ascii(riff, 0, 4) == "RIFF", ascii(riff, 8, 4) == "WAVE" else {
            throw ClipError.notWaveFile
        }

        var format: (tag: UInt16, channels: Int, rate: Double, bits: Int, blockAlign: Int)?
        var dataSection: (offset: Int, byteCount: Int)?
        var offset = 12
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try? handle.read(upToCount: 8), chunk.count == 8,
                  let declared = uint32(chunk, 4) else { throw ClipError.malformedHeader }
            let identifier = ascii(chunk, 0, 4).lowercased()
            let payload = offset + 8
            if identifier == "fmt ", format == nil {
                try handle.seek(toOffset: UInt64(payload))
                guard let body = try? handle.read(upToCount: 40), body.count >= 16,
                      let tag = uint16(body, 0), let channels = uint16(body, 2),
                      let rate = uint32(body, 4), let align = uint16(body, 12),
                      let bits = uint16(body, 14) else { throw ClipError.malformedHeader }
                var resolvedTag = tag
                if tag == 0xFFFE, body.count >= 26, let sub = uint16(body, 24) { resolvedTag = sub }
                guard resolvedTag == 1 || resolvedTag == 3 else { throw ClipError.unsupportedEncoding(resolvedTag) }
                let resolvedAlign = Int(align) > 0 ? Int(align) : Int(channels) * Int(bits) / 8
                guard channels > 0, rate > 0, bits > 0, resolvedAlign > 0 else { throw ClipError.malformedHeader }
                format = (resolvedTag, Int(channels), Double(rate), Int(bits), resolvedAlign)
            } else if identifier == "data", dataSection == nil {
                // A zero or oversized length means the writer has not updated
                // the header yet: the bytes after the offset are the truth.
                let available = max(0, fileSize - payload)
                let declaredBytes = Int(declared)
                let byteCount = (declaredBytes <= 0 || declaredBytes > available) ? available : declaredBytes
                dataSection = (payload, byteCount)
            }
            if format != nil, dataSection != nil { break }
            let advance = 8 + Int(declared) + (Int(declared) % 2)
            guard advance > 8 else { throw ClipError.malformedHeader }
            offset += advance
        }

        guard let format, let dataSection else { throw ClipError.malformedHeader }
        return Layout(
            formatTag: format.tag,
            channelCount: format.channels,
            sampleRate: format.rate,
            bitsPerSample: format.bits,
            blockAlign: format.blockAlign,
            dataOffset: dataSection.offset,
            dataByteCount: dataSection.byteCount
        )
    }

    static func extract(from recordingURL: URL,
                        start: TimeInterval, end: TimeInterval,
                        maximumSeconds: TimeInterval = maximumClipSeconds,
                        maximumBytes: Int = maximumClipBytes,
                        padding: TimeInterval = 0.75) throws -> URL {
        let layout = try readLayout(at: recordingURL)
        let rate = layout.sampleRate
        guard rate > 0, layout.blockAlign > 0, layout.frameCount > 0 else { throw ClipError.recordingEmpty }

        let firstFrame = max(0, Int(((start - padding) * rate).rounded(.down)))
        var lastFrame = min(layout.frameCount, Int(((end + padding) * rate).rounded(.up)))
        guard firstFrame < layout.frameCount, lastFrame > firstFrame else { throw ClipError.rangeNotWrittenYet }
        let maximumFrames = Int(maximumSeconds * rate)
        if lastFrame - firstFrame > maximumFrames { lastFrame = firstFrame + maximumFrames }
        var byteCount = (lastFrame - firstFrame) * layout.blockAlign
        if byteCount > maximumBytes { byteCount = (maximumBytes / layout.blockAlign) * layout.blockAlign }
        guard byteCount >= layout.blockAlign else { throw ClipError.rangeNotWrittenYet }

        let data = try readBytes(at: recordingURL,
                                 offset: layout.dataOffset + firstFrame * layout.blockAlign,
                                 count: byteCount)
        let completeFrames = data.count / layout.blockAlign
        guard completeFrames > 0 else { throw ClipError.rangeNotWrittenYet }
        let payload = data.prefix(completeFrames * layout.blockAlign)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingo-retry-\(UUID().uuidString).wav")
        try write(payload: payload, layout: layout, to: url)
        return url
    }

    private static func readBytes(at url: URL, offset: Int, count: Int) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ClipError.fileMissing }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            var data = Data()
            data.reserveCapacity(min(count, 8 << 20))
            while data.count < count {
                let wanted = min(count - data.count, 1 << 20)
                guard let chunk = try handle.read(upToCount: wanted), !chunk.isEmpty else { break }
                data.append(chunk)
            }
            return data
        } catch {
            throw ClipError.readFailed(error.localizedDescription)
        }
    }

    static func header(layout: Layout, payloadBytes: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + payloadBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(layout.formatTag)
        append(UInt16(layout.channelCount))
        append(UInt32(layout.sampleRate))
        append(UInt32(layout.sampleRate * Double(layout.blockAlign)))
        append(UInt16(layout.blockAlign))
        append(UInt16(layout.bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(payloadBytes))
        return data
    }

    private static func write(payload: Data, layout: Layout, to url: URL) throws {
        var output = header(layout: layout, payloadBytes: payload.count)
        output.append(payload)
        try output.write(to: url, options: .atomic)
    }

    private static func ascii(_ data: Data, _ offset: Int, _ length: Int) -> String {
        guard offset >= 0, offset + length <= data.count else { return "" }
        let slice = data[data.index(data.startIndex, offsetBy: offset)..<data.index(data.startIndex, offsetBy: offset + length)]
        return String(decoding: slice, as: UTF8.self)
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let base = data.index(data.startIndex, offsetBy: offset)
        return UInt16(data[base]) | UInt16(data[data.index(after: base)]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let base = data.index(data.startIndex, offsetBy: offset)
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(data[data.index(base, offsetBy: index)]) << (8 * index)
        }
        return value
    }
}

/// A session-side record survives normal export and error-triggered saving.
/// Audio remains in recording.wav; diagnostic entries contain only failed/retried spans.
enum RecordingDiagnostics {
    private static let lock = NSLock()

    static func append(recordingURL: URL?, event: String, start: TimeInterval? = nil,
                       end: TimeInterval? = nil, detail: String, candidate: String? = nil) {
        let logger = Logger(subsystem: "com.jianhongli.LiveLingo", category: "RecordingDiagnostics")
        logger.notice("event=\(event, privacy: .public) has_interval=\(start != nil && end != nil) has_candidate=\(candidate != nil)")
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
                let code = (error as NSError).code
                logger.error("event=recording_diagnostic_write_failed code=\(code)")
            }
        }
    }

    static func contextAudio(recordingURL: URL, start: TimeInterval, end: TimeInterval) throws -> URL {
        try WAVContextClip.extract(from: recordingURL, start: start, end: end)
    }
}

/// Converts tap buffers from the current hardware format into the format the
/// session files were opened with, so a device switch never writes a foreign
/// sample rate or channel count into a running recording.
struct CaptureFormatBridge: @unchecked Sendable {
    private(set) var inputFormat: AVAudioFormat
    let storageFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(inputFormat: AVAudioFormat, storageFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
        self.storageFormat = storageFormat
        self.converter = SpeechPipeline.formatsMatch(inputFormat, storageFormat)
            ? nil
            : AVAudioConverter(from: inputFormat, to: storageFormat)
    }

    var needsConversion: Bool { converter != nil }

    var isUsable: Bool {
        converter != nil || SpeechPipeline.formatsMatch(inputFormat, storageFormat)
    }

    /// Returns false when the new hardware format cannot be bridged, so the
    /// caller keeps the previous recording untouched instead of writing bytes
    /// that do not belong to the file format.
    mutating func update(inputFormat newFormat: AVAudioFormat) -> Bool {
        inputFormat = newFormat
        if SpeechPipeline.formatsMatch(newFormat, storageFormat) {
            converter = nil
            return true
        }
        converter = AVAudioConverter(from: newFormat, to: storageFormat)
        return converter != nil
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter else { return buffer }
        let ratio = storageFormat.sampleRate / max(1, inputFormat.sampleRate)
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: storageFormat, frameCapacity: max(1, capacity)) else {
            throw SpeechPipeline.PipelineError.invalidInputFormat
        }
        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, pointer in
            if delivered {
                pointer.pointee = .noDataNow
                return nil
            }
            delivered = true
            pointer.pointee = .haveData
            return buffer
        }
        if status == .error {
            throw conversionError ?? SpeechPipeline.PipelineError.incompatibleInputFormat
        }
        return output
    }
}
