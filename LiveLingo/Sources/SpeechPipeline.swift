import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech

final class SpeechPipeline: NSObject, @unchecked Sendable {
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

    private struct ChunkJob: Sendable {
        let audioURL: URL
        let modelKey: String
        let fallbackModelKey: String?
        let start: TimeInterval
        let end: TimeInterval
        let appleEvidence: String
    }

    private struct FlushSnapshot: Sendable {
        let job: ChunkJob?
        let handler: (@Sendable (Event) -> Void)?
    }

    private actor TranscriptionQueue {
        private var tail: Task<Void, Never>?

        func submit(_ job: ChunkJob, handler: @escaping @Sendable (Event) -> Void) {
            let previous = tail
            tail = Task {
                if let previous { await previous.value }
                guard !Task.isCancelled else { return }
                defer { try? FileManager.default.removeItem(at: job.audioURL) }
                do {
                    let text = try await transcribeWithFallback(job)
                    guard !text.isEmpty else { return }
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
                    handler(.failure("本机转写失败：\(error.localizedDescription)"))
                }
            }
        }

        private func transcribeWithFallback(_ job: ChunkJob) async throws -> String {
            let primaryText: String
            do {
                primaryText = try await QwenASRClient.transcribe(
                    audioURL: job.audioURL,
                    modelKey: job.modelKey
                )
            } catch {
                guard let fallbackModelKey = job.fallbackModelKey else { throw error }
                let fallbackText = try await QwenASRClient.transcribe(
                    audioURL: job.audioURL,
                    modelKey: fallbackModelKey,
                    enhanceSpeech: true
                )
                return SpeechPipeline.preferredTranscript(
                    primary: nil,
                    fallback: fallbackText
                )
            }

            guard let fallbackModelKey = job.fallbackModelKey,
                  ASRQualityGate.fallbackReason(
                      for: primaryText,
                      audioDuration: max(0, job.end - job.start)
                  ) != nil
            else { return primaryText }

            let fallbackText = try await QwenASRClient.transcribe(
                audioURL: job.audioURL,
                modelKey: fallbackModelKey,
                enhanceSpeech: true
            )
            return SpeechPipeline.preferredTranscript(
                primary: primaryText,
                fallback: fallbackText
            )
        }

        func finish() async {
            await tail?.value
        }

        func cancel() {
            tail?.cancel()
            tail = nil
        }
    }

    static func preferredTranscript(primary: String?, fallback: String) -> String {
        let fallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallback.isEmpty, EnglishTranscriptGate.accepts(fallback) {
            return fallback
        }

        let primary = primary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !primary.isEmpty, EnglishTranscriptGate.accepts(primary) {
            return primary
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
    private var chunkTimerTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (Event) -> Void)?
    private var profile = QwenModelProfile.energySaver
    private var sessionStartedAt: Date?
    private var chunkStartedAt: TimeInterval = 0
    private var nextChunkIndex = 0
    private var inputMode: AudioInputMode?
    private var microphoneTapInstalled = false
    private var microphoneConfigurationObserver: NSObjectProtocol?
    private var microphoneWatchdogTask: Task<Void, Never>?
    private var lastAudioCallbackUptime: TimeInterval?
    private var lastWaveformUpdateUptime: TimeInterval?
    private var microphoneRecoveryScheduled = false
    private var microphoneRecoveryAttempts = 0
    private var capturePaused = false
    private var isStopping = false
    private var previewSupportedLocale: Locale?
    private var previewTranscriber: SpeechTranscriber?
    private var previewAnalyzer: SpeechAnalyzer?
    private var previewConverter: AnalyzerInputConverter?
    private var previewInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var previewAnalysisTask: Task<Void, Never>?
    private var previewResultTask: Task<Void, Never>?
    private var previewObservations: [AuxiliaryTranscriptObservation] = []

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
            if await AssetInventory.status(forModules: modules) != .installed,
               let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
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
            lastWaveformUpdateUptime = nil
        }
        if inputMode == .microphone {
            startMicrophoneHealthMonitoring()
        }

        chunkTimerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Self.stableChunkDuration))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self.flushCurrentChunk(openNext: true)
            }
        }
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

        try inputNode.installAudioTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] sourceBuffer, time in
            guard let self else { return }
            let buffer = AVAudioPCMBuffer(copying: sourceBuffer)
            self.write(buffer, at: time)
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
        await stopCaptureSource()
        await finishStreamingPreview()
        chunkTimerTask?.cancel()
        chunkTimerTask = nil
        await flushCurrentChunk(openNext: false)
        await transcriptionQueue.finish()
        closeFilesAndCleanUp()
    }

    func cancel() async {
        await stopCaptureSource()
        await cancelStreamingPreview()
        chunkTimerTask?.cancel()
        chunkTimerTask = nil
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
        let converter = previewConverter
        let continuation = previewInputContinuation
        let shouldUpdateWaveform = lastWaveformUpdateUptime.map {
            now - $0 >= Self.waveformUpdateInterval
        } ?? true
        if shouldUpdateWaveform {
            lastWaveformUpdateUptime = now
        }
        let waveformHandler = shouldUpdateWaveform ? eventHandler : nil
        do {
            try recordingFile?.write(from: buffer)
            try chunkFile?.write(from: buffer)
            stateLock.unlock()
        } catch {
            let handler = eventHandler
            stateLock.unlock()
            handler?(.failure("音频写入失败：\(error.localizedDescription)"))
            return
        }

        if let waveformHandler {
            waveformHandler(.audioLevel(Self.normalizedAudioLevel(from: buffer)))
        }

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
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return 0 }

        var sumOfSquares = 0.0
        var sampleCount = 0
        let isInterleaved = buffer.format.isInterleaved

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = buffer.floatChannelData else { return 0 }
            let buffers = isInterleaved ? 1 : channelCount
            let samplesPerBuffer = isInterleaved ? frameCount * channelCount : frameCount
            for channel in 0..<buffers {
                for index in 0..<samplesPerBuffer {
                    let sample = Double(channels[channel][index])
                    sumOfSquares += sample * sample
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
                    sumOfSquares += sample * sample
                }
                sampleCount += samplesInBuffer
            }
        case .pcmFormatInt16:
            guard let channels = buffer.int16ChannelData else { return 0 }
            let buffers = isInterleaved ? 1 : channelCount
            let samplesPerBuffer = isInterleaved ? frameCount * channelCount : frameCount
            for channel in 0..<buffers {
                for index in 0..<samplesPerBuffer {
                    let sample = Double(channels[channel][index]) / 32_768.0
                    sumOfSquares += sample * sample
                }
            }
            sampleCount = buffers * samplesPerBuffer
        case .pcmFormatInt32:
            guard let channels = buffer.int32ChannelData else { return 0 }
            let buffers = isInterleaved ? 1 : channelCount
            let samplesPerBuffer = isInterleaved ? frameCount * channelCount : frameCount
            for channel in 0..<buffers {
                for index in 0..<samplesPerBuffer {
                    let sample = Double(channels[channel][index]) / 2_147_483_648.0
                    sumOfSquares += sample * sample
                }
            }
            sampleCount = buffers * samplesPerBuffer
        default:
            return 0
        }

        guard sampleCount > 0 else { return 0 }
        return normalizedAudioLevel(rms: sqrt(sumOfSquares / Double(sampleCount)))
    }

    static func normalizedAudioLevel(rms: Double) -> Float {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return Float(min(1, max(0, (decibels + 60) / 60)))
    }

    private func startStreamingPreviewIfAvailable() async {
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
            return eventHandler
        }
        handler?(.volatile(text: text, start: start, end: end))
    }

    private func finishStreamingPreview() async {
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
        let state = detachStreamingPreviewState()
        state.continuation?.finish()
        await state.analyzer?.cancelAndFinishNow()
        state.analysisTask?.cancel()
        state.resultTask?.cancel()
        clearStreamingPreviewObjects()
    }

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

    private func flushCurrentChunk(openNext: Bool) async {
        let elapsed = max(0, Date().timeIntervalSince(sessionStartedAt ?? Date()))
        let snapshot = rotateCurrentChunk(elapsed: elapsed, openNext: openNext)
        if let job = snapshot.job, let handler = snapshot.handler {
            await transcriptionQueue.submit(job, handler: handler)
        }
    }

    private func configureSession(
        format: AVAudioFormat,
        recordingFile: AVAudioFile?,
        chunkDirectory: URL
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        inputFormat = format
        self.recordingFile = recordingFile
        self.chunkDirectory = chunkDirectory
        sessionStartedAt = Date()
        chunkStartedAt = 0
        nextChunkIndex = 0
        previewObservations = []
        try openNextChunkLocked()
    }

    private func rotateCurrentChunk(elapsed: TimeInterval, openNext: Bool) -> FlushSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
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
                    appleEvidence: appleEvidence
                ),
                handler: handler
            )
        }
        if let completedURL { try? FileManager.default.removeItem(at: completedURL) }
        return FlushSnapshot(job: nil, handler: handler)
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
        lastWaveformUpdateUptime = nil
        microphoneRecoveryScheduled = false
        microphoneRecoveryAttempts = 0
        capturePaused = false
        isStopping = false
        eventHandler = nil
        sessionStartedAt = nil
        previewTranscriber = nil
        previewAnalyzer = nil
        previewConverter = nil
        previewInputContinuation = nil
        previewAnalysisTask = nil
        previewResultTask = nil
        previewObservations = []
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
