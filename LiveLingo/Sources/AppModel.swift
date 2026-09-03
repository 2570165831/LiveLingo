import AppKit
import AVFoundation
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: AppPhase = .idle
    @Published private(set) var audioInputStatus = "等待检查"
    @Published private(set) var speechStatus = "等待检查"
    @Published private(set) var translationStatus = "正在检查本机翻译模型…"
    @Published private(set) var translationReady = false
    @Published private(set) var volatileEnglish = ""
    @Published private(set) var liveChinese = ""
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var lectureSummary = ""
    @Published private(set) var summaryStatus = "等待课堂内容"
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var waveformSamples = Array(repeating: Float.zero, count: 24)
    @Published private(set) var sessionNotice: String?
    @Published var outputDirectory: URL?
    @Published var selectedMode: ModelMode {
        didSet {
            guard selectedMode != oldValue else { return }
            UserDefaults.standard.set(selectedMode.rawValue, forKey: Self.modelModeDefaultsKey)
            applyResolvedProfile()
        }
    }
    @Published var selectedStorageMode: SessionStorageMode {
        didSet {
            guard selectedStorageMode != oldValue else { return }
            UserDefaults.standard.set(
                selectedStorageMode.rawValue,
                forKey: Self.storageModeDefaultsKey
            )
        }
    }
    @Published var selectedInputMode: AudioInputMode {
        didSet {
            guard selectedInputMode != oldValue else { return }
            UserDefaults.standard.set(
                selectedInputMode.rawValue,
                forKey: Self.inputModeDefaultsKey
            )
            refreshPermissionLabels()
        }
    }
    @Published private(set) var effectiveProfile: QwenModelProfile
    @Published private(set) var isOnBattery: Bool

    private let pipeline = SpeechPipeline()
    private var translationQueue: [UUID] = []
    private var translationWorker: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var powerMonitorTask: Task<Void, Never>?
    private var readinessMonitorTask: Task<Void, Never>?
    private var elapsedTickerTask: Task<Void, Never>?
    private var sessionDirectory: URL?
    private var temporarySessionDirectory: URL?
    private var activeStorageMode: SessionStorageMode?
    private var activeInputMode: AudioInputMode?
    private var translationHints: [UUID: [AuxiliaryTranslationHint]] = [:]
    private var generation = 0
    private var readinessGeneration = 0
    private var setupError: String?
    private var runtimeFailurePending = false
    private var lastSummarizedSegmentCount = 0
    private var summaryRefreshRequested = false
    private var summaryTaskGeneration = 0
    private var accumulatedElapsedSeconds: TimeInterval = 0
    private var activeElapsedStartUptime: TimeInterval?

    init() {
        let savedMode = UserDefaults.standard.string(forKey: Self.modelModeDefaultsKey)
            .flatMap(ModelMode.init(rawValue:)) ?? .automatic
        let savedStorageMode = UserDefaults.standard.string(forKey: Self.storageModeDefaultsKey)
            .flatMap(SessionStorageMode.init(rawValue:)) ?? .saveSession
        let savedInputMode = UserDefaults.standard.string(forKey: Self.inputModeDefaultsKey)
            .flatMap(AudioInputMode.init(rawValue:)) ?? .microphone
        let onBattery = PowerSourceMonitor.isOnBattery()
        selectedMode = savedMode
        selectedStorageMode = savedStorageMode
        selectedInputMode = savedInputMode
        isOnBattery = onBattery
        effectiveProfile = savedMode.resolvedProfile(isOnBattery: onBattery)
        refreshPermissionLabels()
        pipeline.update(profile: effectiveProfile)
        startPowerMonitor()
        startRuntimeReadinessMonitor()
    }

    var isRecording: Bool { phase == .recording }
    var isPaused: Bool { phase == .paused }
    var hasActiveSession: Bool { isRecording || isPaused }
    var isLiveOnly: Bool {
        (activeStorageMode ?? selectedStorageMode) == .liveOnly
    }
    var currentInputMode: AudioInputMode {
        activeInputMode ?? selectedInputMode
    }
    var isSystemAudio: Bool { currentInputMode == .systemAudio }
    var canStart: Bool {
        !phase.isBusy && translationReady
    }

    var phaseLabel: String {
        switch phase {
        case .idle: return "待机"
        case .preparing: return "正在准备"
        case .recording: return "录音中"
        case .paused: return "已暂停"
        case .stopping: return isLiveOnly ? "正在结束" : "正在整理并保存"
        case .saved: return "已保存"
        case .liveEnded: return "已结束 · 未保存"
        case .failed: return "需要处理"
        }
    }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return sessionNotice ?? setupError
    }

    var modelModeStatus: String {
        let power = isOnBattery ? "电池" : "接电"
        return "\(selectedMode.title) · \(power) · \(effectiveProfile.shortLabel)"
    }

    func retryRuntimePreparation() {
        startRuntimeReadinessMonitor()
    }

    func requestSummaryRefresh() {
        guard !segments.isEmpty else { return }
        if translationWorker != nil {
            summaryRefreshRequested = true
            summaryStatus = "等待当前字幕翻译完成"
            return
        }
        scheduleSummaryRefresh(force: true)
    }

    @discardableResult
    func chooseOutputDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择会话保存目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            outputDirectory = panel.url
            return panel.url
        }
        return nil
    }

    func convertCurrentSessionToRecording() {
        guard hasActiveSession, activeStorageMode == .liveOnly else { return }
        guard let directory = chooseOutputDirectory() else { return }
        activeStorageMode = .saveSession
        selectedStorageMode = .saveSession
        outputDirectory = directory
    }

    func start() {
        guard !phase.isBusy else { return }
        Task { await startSession() }
    }

    func stop() {
        guard hasActiveSession else { return }
        resetElapsedClock()
        phase = .stopping
        Task { await stopSession() }
    }

    func pause() {
        guard isRecording else { return }
        pipeline.pause()
        pauseElapsedClock()
        phase = .paused
    }

    func resume() {
        guard isPaused else { return }
        do {
            try pipeline.resume()
            resumeElapsedClock()
            phase = .recording
        } catch {
            Task { await failActiveSession("恢复录音失败：\(error.localizedDescription)") }
        }
    }

    func revealSavedSession() {
        guard case .saved(let url) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func startSession() async {
        phase = .preparing
        volatileEnglish = ""
        liveChinese = ""
        segments = []
        lectureSummary = ""
        summaryStatus = "等待课堂内容"
        waveformSamples = Array(repeating: .zero, count: waveformSamples.count)
        sessionNotice = nil
        lastSummarizedSegmentCount = 0
        summaryRefreshRequested = false
        translationQueue = []
        translationHints = [:]
        sessionDirectory = nil
        temporarySessionDirectory = nil
        let storageMode = selectedStorageMode
        let inputMode = selectedInputMode
        activeStorageMode = storageMode
        activeInputMode = inputMode
        generation += 1
        translationWorker?.cancel()
        translationWorker = nil
        cancelSummaryTask()
        resetElapsedClock()

        do {
            if !translationReady { await refreshRuntimeReadiness() }
            guard translationReady else {
                runtimeFailurePending = true
                startRuntimeReadinessMonitor()
                throw AppError.runtimeNotReady
            }
            var selectedOutputDirectory: URL?
            if storageMode.requiresOutputDirectoryBeforeStart {
                if outputDirectory == nil { chooseOutputDirectory() }
                guard let outputDirectory else {
                    activeStorageMode = nil
                    phase = .idle
                    return
                }
                selectedOutputDirectory = outputDirectory
            }

            try await requestPermissions(for: inputMode)

            try await pipeline.prepareModel(profile: effectiveProfile) { [weak self] status in
                Task { @MainActor in self?.speechStatus = status }
            }

            let sessionName = Self.sessionFolderName()
            let recordingURL: URL
            if storageMode.usesTemporaryRecording {
                let temporaryDirectory = try SessionWorkspace.makeTemporarySessionDirectory()
                temporarySessionDirectory = temporaryDirectory
                sessionDirectory = temporaryDirectory
                recordingURL = temporaryDirectory.appendingPathComponent(
                    SessionWorkspace.recordingFileName
                )
            } else {
                guard let selectedOutputDirectory else {
                    throw AppError.outputDirectoryMissing
                }
                let finalDirectory = SessionWorkspace.uniqueFinalDirectory(
                    in: selectedOutputDirectory,
                    preferredName: sessionName
                )
                try FileManager.default.createDirectory(
                    at: finalDirectory,
                    withIntermediateDirectories: false
                )
                sessionDirectory = finalDirectory
                recordingURL = finalDirectory.appendingPathComponent(
                    SessionWorkspace.recordingFileName
                )
            }

            do {
                try await pipeline.start(
                    inputMode: inputMode,
                    recordingURL: recordingURL
                ) { [weak self] event in
                    Task { @MainActor in self?.consume(event) }
                }
            } catch {
                if inputMode == .systemAudio {
                    throw AppError.systemAudioUnavailable(error.localizedDescription)
                }
                throw error
            }
            audioInputStatus = inputMode == .microphone ? "麦克风已接入" : "系统音频已接入"
            phase = .recording
            beginElapsedClock()
        } catch {
            await pipeline.cancel()
            stopElapsedClock()
            if let temporarySessionDirectory {
                try? SessionWorkspace.discardTemporarySession(temporarySessionDirectory)
                self.temporarySessionDirectory = nil
                sessionDirectory = nil
            }
            recoverRuntimeIfNeeded(from: error)
            activeStorageMode = nil
            activeInputMode = nil
            audioInputStatus = inputMode == .systemAudio
                ? "系统音频未接入"
                : "麦克风已授权"
            phase = .failed(error.localizedDescription)
        }
    }

    private func stopSession() async {
        await pipeline.stop()

        if activeStorageMode?.clearsHistoryWhenStopped == true {
            translationWorker?.cancel()
            if let translationWorker { _ = await translationWorker.result }
            let pendingSummary = summaryTask
            cancelSummaryTask()
            if let pendingSummary { _ = await pendingSummary.result }
            var cleanupError: Error?
            if let temporarySessionDirectory {
                do {
                    try SessionWorkspace.discardTemporarySession(temporarySessionDirectory)
                } catch {
                    cleanupError = error
                }
            }
            volatileEnglish = ""
            liveChinese = ""
            segments = []
            lectureSummary = ""
            summaryStatus = "等待课堂内容"
            translationQueue = []
            translationHints = [:]
            sessionDirectory = nil
            temporarySessionDirectory = nil
            activeStorageMode = nil
            activeInputMode = nil
            phase = cleanupError.map {
                .failed("实时录音已结束，但临时文件删除失败：\($0.localizedDescription)")
            } ?? .liveEnded
            return
        }

        do {
            let sessionDirectory = try finalizeSessionDirectoryIfNeeded()
            if let translationWorker { _ = await translationWorker.result }
            if let summaryTask { _ = await summaryTask.result }
            self.summaryTask = nil
            await generateLectureSummary(force: true)
            try SessionExporter.export(
                segments: segments,
                sessionDirectory: sessionDirectory,
                summary: lectureSummary
            )
            volatileEnglish = ""
            translationHints = [:]
            activeStorageMode = nil
            activeInputMode = nil
            phase = .saved(sessionDirectory)
        } catch {
            activeStorageMode = nil
            activeInputMode = nil
            phase = .failed("导出失败：\(error.localizedDescription)")
        }
    }

    private func consume(_ event: SpeechPipeline.Event) {
        switch event {
        case let .audioLevel(level):
            waveformSamples.removeFirst()
            waveformSamples.append(level)
        case let .volatile(text, _, _):
            volatileEnglish = text
        case let .final(text, start, end, hints):
            volatileEnglish = ""
            if summaryTask != nil {
                cancelSummaryTask()
                summaryStatus = lectureSummary.isEmpty
                    ? "字幕翻译优先 · 稍后开始总结"
                    : "字幕更新中 · 稍后刷新摘要"
            }
            let segment = TranscriptSegment(startTime: start, endTime: end, english: text)
            segments.append(segment)
            translationHints[segment.id] = hints
            if lectureSummary.isEmpty {
                summaryStatus = "正在积累课堂上下文"
            }
            translationQueue.append(segment.id)
            drainTranslationQueue()
        case .failure(let message):
            Task { await failActiveSession(message) }
        }
    }

    private func drainTranslationQueue() {
        guard translationWorker == nil, !translationQueue.isEmpty else { return }
        let currentGeneration = generation
        translationWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.translationQueue.isEmpty, !Task.isCancelled, currentGeneration == self.generation {
                let id = self.translationQueue.removeFirst()
                guard let index = self.segments.firstIndex(where: { $0.id == id }) else { continue }
                let english = self.segments[index].english
                let normalizedInput = AcademicInputNormalizer.normalize(english)
                let protectedInput = ChemistryTranslationProtector.prepare(normalizedInput)
                let translationModel = self.effectiveProfile.translationModel
                let hints = self.translationHints.removeValue(forKey: id) ?? []
                self.liveChinese = "翻译中…"
                do {
                    let response = try await QwenTranslationClient.translate(
                        protectedInput.text,
                        modelName: translationModel,
                        hints: hints
                    )
                    let restored = protectedInput.restore(in: response)
                    let chinese = SimplifiedChineseNormalizer.normalize(restored)
                    guard currentGeneration == self.generation,
                          let currentIndex = self.segments.firstIndex(where: { $0.id == id }) else { continue }
                    self.segments[currentIndex].chinese = chinese
                    self.liveChinese = chinese
                } catch is CancellationError {
                    break
                } catch {
                    guard let currentIndex = self.segments.firstIndex(where: { $0.id == id }) else { continue }
                    self.segments[currentIndex].chinese = "[翻译失败：\(error.localizedDescription)]"
                    self.liveChinese = self.segments[currentIndex].chinese
                }
            }
            self.translationWorker = nil
            if !self.translationQueue.isEmpty {
                self.drainTranslationQueue()
            } else {
                let force = self.summaryRefreshRequested
                self.summaryRefreshRequested = false
                self.scheduleSummaryRefresh(force: force)
            }
        }
    }

    private func scheduleSummaryRefresh(force: Bool = false) {
        guard summaryTask == nil else {
            if force { summaryRefreshRequested = true }
            return
        }
        let completedCount = completedTranslationCount
        guard completedCount >= 2 else {
            summaryStatus = completedCount == 0 ? "等待课堂内容" : "再完成一段后开始总结"
            return
        }
        let needsInitialSummary = lectureSummary.isEmpty && completedCount >= 2
        guard force || needsInitialSummary || completedCount - lastSummarizedSegmentCount >= 3 else { return }

        summaryTaskGeneration += 1
        let taskGeneration = summaryTaskGeneration
        summaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.generateLectureSummary(force: force)
            guard self.summaryTaskGeneration == taskGeneration else { return }
            self.summaryTask = nil
            if self.completedTranslationCount - self.lastSummarizedSegmentCount >= 3 {
                self.scheduleSummaryRefresh()
            }
        }
    }

    private func generateLectureSummary(force: Bool) async {
        let completedCount = completedTranslationCount
        guard completedCount >= 2 else { return }
        if force, completedCount == lastSummarizedSegmentCount, !lectureSummary.isEmpty {
            return
        }
        let needsInitialSummary = lectureSummary.isEmpty && completedCount >= 2
        guard force || needsInitialSummary || completedCount - lastSummarizedSegmentCount >= 3 else { return }
        let transcript = LectureSummaryInput.make(from: segments)
        guard !transcript.isEmpty else { return }

        let currentGeneration = generation
        let modelName = effectiveProfile.translationModel
        summaryStatus = force ? "正在生成完整摘要…" : "正在更新摘要…"
        do {
            let response = try await QwenTranslationClient.summarize(
                transcript,
                modelName: modelName
            )
            guard !Task.isCancelled, currentGeneration == generation else { return }
            lectureSummary = SimplifiedChineseNormalizer.normalize(response)
            lastSummarizedSegmentCount = completedCount
            summaryStatus = "已整理 \(completedCount) 段 · 本机生成"
        } catch is CancellationError {
            return
        } catch {
            guard currentGeneration == generation else { return }
            summaryStatus = lectureSummary.isEmpty
                ? "摘要暂不可用：\(error.localizedDescription)"
                : "保留上次摘要 · 本轮更新失败"
        }
    }

    private var completedTranslationCount: Int {
        segments.filter {
            !$0.chinese.isEmpty && !$0.chinese.hasPrefix("[翻译失败：")
        }.count
    }

    private func cancelSummaryTask() {
        summaryTaskGeneration += 1
        summaryTask?.cancel()
        summaryTask = nil
    }

    private func resetElapsedClock() {
        elapsedTickerTask?.cancel()
        elapsedTickerTask = nil
        accumulatedElapsedSeconds = 0
        activeElapsedStartUptime = nil
        elapsedSeconds = 0
    }

    private func beginElapsedClock() {
        accumulatedElapsedSeconds = 0
        elapsedSeconds = 0
        activeElapsedStartUptime = ProcessInfo.processInfo.systemUptime
        elapsedTickerTask?.cancel()
        elapsedTickerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
                self?.updateElapsedClock()
            }
        }
    }

    private func pauseElapsedClock() {
        updateElapsedClock()
        if let activeElapsedStartUptime {
            accumulatedElapsedSeconds += max(
                0,
                ProcessInfo.processInfo.systemUptime - activeElapsedStartUptime
            )
        }
        activeElapsedStartUptime = nil
        elapsedSeconds = accumulatedElapsedSeconds
    }

    private func resumeElapsedClock() {
        guard activeElapsedStartUptime == nil else { return }
        activeElapsedStartUptime = ProcessInfo.processInfo.systemUptime
    }

    private func stopElapsedClock() {
        pauseElapsedClock()
        elapsedTickerTask?.cancel()
        elapsedTickerTask = nil
    }

    private func updateElapsedClock() {
        guard let activeElapsedStartUptime else {
            elapsedSeconds = accumulatedElapsedSeconds
            return
        }
        elapsedSeconds = accumulatedElapsedSeconds + max(
            0,
            ProcessInfo.processInfo.systemUptime - activeElapsedStartUptime
        )
    }

    private func requestPermissions(for inputMode: AudioInputMode) async throws {
        guard inputMode == .microphone else {
            audioInputStatus = "正在接入系统音频…"
            return
        }
        let microphoneGranted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneGranted = true
        case .notDetermined:
            microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            microphoneGranted = false
        }
        audioInputStatus = microphoneGranted ? "麦克风已授权" : "麦克风未授权"
        guard microphoneGranted else { throw AppError.microphoneDenied }
    }

    private func refreshPermissionLabels() {
        switch selectedInputMode {
        case .microphone:
            audioInputStatus = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                ? "麦克风已授权" : "首次开始时请求麦克风授权"
        case .systemAudio:
            audioInputStatus = "首次开始时请求系统音频权限"
        }
        speechStatus = "正在检查本机 ASR…"
    }

    private func startPowerMonitor() {
        powerMonitorTask?.cancel()
        powerMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    break
                }
                guard let self else { break }
                let latest = PowerSourceMonitor.isOnBattery()
                if latest != self.isOnBattery {
                    self.isOnBattery = latest
                    self.applyResolvedProfile()
                }
            }
        }
    }

    private func applyResolvedProfile() {
        let resolved = selectedMode.resolvedProfile(isOnBattery: isOnBattery)
        guard resolved != effectiveProfile else {
            updateReadyLabels()
            return
        }
        effectiveProfile = resolved
        pipeline.update(profile: resolved)
        translationReady = false
        setupError = nil
        updateReadyLabels()
        startRuntimeReadinessMonitor()
    }

    private func startRuntimeReadinessMonitor() {
        readinessMonitorTask?.cancel()
        readinessMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.refreshRuntimeReadiness()
                if self.translationReady { break }
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    break
                }
            }
        }
    }

    private func refreshRuntimeReadiness() async {
        readinessGeneration += 1
        let currentReadinessGeneration = readinessGeneration
        let profile = effectiveProfile
        translationReady = false
        setupError = nil
        speechStatus = "正在检查 Parakeet + Qwen 1.7B 回退…"
        translationStatus = "正在检查 \(profile.shortLabel)…"
        do {
            async let asrCheck: Void = QwenASRClient.checkHealth(
                modelKeys: [profile.asrKey, profile.fallbackASRKey].compactMap { $0 }
            )
            async let translationCheck: Void = QwenTranslationClient.checkModel(
                profile.translationModel
            )
            _ = try await (asrCheck, translationCheck)
            guard currentReadinessGeneration == readinessGeneration,
                  profile == effectiveProfile else { return }
            translationReady = true
            if runtimeFailurePending {
                runtimeFailurePending = false
                if case .failed = phase { phase = .idle }
            }
            updateReadyLabels()
            drainTranslationQueue()
        } catch {
            guard currentReadinessGeneration == readinessGeneration,
                  profile == effectiveProfile else { return }
            translationReady = false
            setupError = error.localizedDescription
            speechStatus = "本机 ASR 服务未就绪"
            translationStatus = "本机模型未就绪"
        }
    }

    private func recoverRuntimeIfNeeded(from error: Error) {
        let isRuntimeFailure: Bool
        if error is QwenRuntimeError {
            isRuntimeFailure = true
        } else if let appError = error as? AppError,
                  case .runtimeNotReady = appError {
            isRuntimeFailure = true
        } else {
            isRuntimeFailure = false
        }
        guard isRuntimeFailure else { return }
        translationReady = false
        setupError = error.localizedDescription
        runtimeFailurePending = true
        startRuntimeReadinessMonitor()
    }

    private func updateReadyLabels() {
        speechStatus = "Parakeet · 异常回退 Qwen 1.7B"
        translationStatus = "\(modelModeStatus) · 学术词表"
    }

    private func failActiveSession(_ message: String) async {
        stopElapsedClock()
        resetElapsedClock()
        cancelSummaryTask()
        if phase == .recording || phase == .paused || phase == .preparing {
            await pipeline.cancel()
        }

        if let translationWorker {
            _ = await translationWorker.result
        }
        cancelSummaryTask()

        if activeStorageMode?.clearsHistoryWhenStopped == true {
            var cleanupMessage = message
            if let temporarySessionDirectory {
                do {
                    try SessionWorkspace.discardTemporarySession(temporarySessionDirectory)
                } catch {
                    cleanupMessage += "；临时文件删除失败：\(error.localizedDescription)"
                }
            }
            volatileEnglish = ""
            liveChinese = ""
            segments = []
            lectureSummary = ""
            summaryStatus = "等待课堂内容"
            translationQueue = []
            translationHints = [:]
            sessionDirectory = nil
            self.temporarySessionDirectory = nil
            activeStorageMode = nil
            activeInputMode = nil
            phase = .failed(cleanupMessage)
            return
        }

        if activeStorageMode?.persistsSession == true {
            do {
                let sessionDirectory = try finalizeSessionDirectoryIfNeeded()
                try SessionExporter.export(
                    segments: segments,
                    sessionDirectory: sessionDirectory,
                    summary: lectureSummary
                )
                volatileEnglish = ""
                translationHints = [:]
                sessionNotice = "\(message) 已自动保存当前录音和 \(segments.count) 段字幕。"
                activeStorageMode = nil
                activeInputMode = nil
                phase = .saved(sessionDirectory)
                return
            } catch {
                activeStorageMode = nil
                activeInputMode = nil
                phase = .failed("\(message)；自动保存字幕失败：\(error.localizedDescription)")
                return
            }
        }

        activeStorageMode = nil
        activeInputMode = nil
        phase = .failed(message)
    }

    private func finalizeSessionDirectoryIfNeeded() throws -> URL {
        if let temporarySessionDirectory {
            guard let outputDirectory else { throw AppError.outputDirectoryMissing }
            let finalDirectory = try SessionWorkspace.promoteTemporarySession(
                from: temporarySessionDirectory,
                to: outputDirectory,
                preferredName: Self.sessionFolderName()
            )
            self.temporarySessionDirectory = nil
            sessionDirectory = finalDirectory
            return finalDirectory
        }
        guard let sessionDirectory else { throw AppError.sessionDirectoryMissing }
        return sessionDirectory
    }

    private static func sessionFolderName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "LiveLingo \(formatter.string(from: Date()))"
    }

    private static let modelModeDefaultsKey = "LiveLingo.modelMode"
    private static let storageModeDefaultsKey = "LiveLingo.storageMode"
    private static let inputModeDefaultsKey = "LiveLingo.inputMode"
}

enum SimplifiedChineseNormalizer {
    private static let traditionalToSimplified = StringTransform("Traditional-Simplified")

    static func normalize(_ text: String) -> String {
        text.applyingTransform(traditionalToSimplified, reverse: false) ?? text
    }
}

struct ProtectedChemistryTranslationInput {
    let text: String
    fileprivate let replacements: [(placeholder: String, original: String)]

    func restore(in translatedText: String) -> String {
        replacements.reduce(translatedText) { result, replacement in
            result.replacingOccurrences(
                of: replacement.placeholder,
                with: replacement.original,
                options: [.caseInsensitive]
            )
        }
    }
}

enum ChemistryTranslationProtector {
    private static let elementSymbols: Set<String> = [
        "H", "He", "Li", "Be", "B", "C", "N", "O", "F", "Ne", "Na", "Mg", "Al", "Si", "P", "S", "Cl", "Ar",
        "K", "Ca", "Sc", "Ti", "V", "Cr", "Mn", "Fe", "Co", "Ni", "Cu", "Zn", "Ga", "Ge", "As", "Se", "Br", "Kr",
        "Rb", "Sr", "Y", "Zr", "Nb", "Mo", "Tc", "Ru", "Rh", "Pd", "Ag", "Cd", "In", "Sn", "Sb", "Te", "I", "Xe",
        "Cs", "Ba", "La", "Ce", "Pr", "Nd", "Pm", "Sm", "Eu", "Gd", "Tb", "Dy", "Ho", "Er", "Tm", "Yb", "Lu",
        "Hf", "Ta", "W", "Re", "Os", "Ir", "Pt", "Au", "Hg", "Tl", "Pb", "Bi", "Po", "At", "Rn", "Fr", "Ra",
        "Ac", "Th", "Pa", "U", "Np", "Pu", "Am", "Cm", "Bk", "Cf", "Es", "Fm", "Md", "No", "Lr", "Rf", "Db",
        "Sg", "Bh", "Hs", "Mt", "Ds", "Rg", "Cn", "Nh", "Fl", "Mc", "Lv", "Ts", "Og"
    ]

    private static let patterns = [
        #"(?<![A-Za-z])pH\s*\d+(?:\.\d+)?(?![A-Za-z])"#,
        #"(?<![A-Za-z])(?:[A-Z][a-z]?\d*|\((?:[A-Z][a-z]?\d*)+\)\d*)+(?:\^\d*[+-]|\d*[+-])?(?![A-Za-z])"#,
        #"(?<![A-Za-z0-9])(?:\d+(?:\.\d+)?\s*)?(?:μ|µ|u|m|c|d|k|M)?(?:mol|g|L|l|M|Pa|bar|atm|K|°C)(?:\s*/\s*(?:mol|L|l|g))?(?![A-Za-z])"#,
        #"(?<![A-Za-z0-9])(?:FTIR|NMR|UV-Vis|HPLC|UPLC|GC-MS|LC-MS|TLC|IR|MS|SN1|SN2|E1|E2|sp2|sp3)(?![A-Za-z0-9])"#
    ]

    static func prepare(_ source: String) -> ProtectedChemistryTranslationInput {
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        var candidates: [NSRange] = []

        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: source, range: fullRange) {
                guard match.range.length > 0 else { continue }
                if pattern == patterns[1], !looksLikeChemicalFormula(match.range, in: source) {
                    continue
                }
                candidates.append(match.range)
            }
        }

        let selected = nonOverlappingRanges(from: candidates)
            .sorted { $0.location < $1.location }
        guard !selected.isEmpty else {
            return ProtectedChemistryTranslationInput(text: source, replacements: [])
        }

        let mutable = NSMutableString(string: source)
        let sourceString = source as NSString
        let replacements = selected.enumerated().map { index, range in
            (
                placeholder: "ZXQCHEM\(index)QXZ",
                original: sourceString.substring(with: range)
            )
        }

        for (range, replacement) in zip(selected, replacements).reversed() {
            mutable.replaceCharacters(in: range, with: replacement.placeholder)
        }

        return ProtectedChemistryTranslationInput(
            text: mutable as String,
            replacements: replacements
        )
    }

    private static func looksLikeChemicalFormula(_ range: NSRange, in source: String) -> Bool {
        let candidate = (source as NSString).substring(with: range)
        guard let elementPattern = try? NSRegularExpression(pattern: #"[A-Z][a-z]?"#) else { return false }
        let candidateRange = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        let matches = elementPattern.matches(in: candidate, range: candidateRange)
        let symbols = matches.map { (candidate as NSString).substring(with: $0.range) }
        guard !symbols.isEmpty, symbols.allSatisfy(elementSymbols.contains) else { return false }

        if candidate.rangeOfCharacter(from: .decimalDigits) != nil { return true }
        if candidate.rangeOfCharacter(from: CharacterSet(charactersIn: "()+-^")) != nil { return true }
        return symbols.count >= 2
    }

    private static func nonOverlappingRanges(from candidates: [NSRange]) -> [NSRange] {
        var selected: [NSRange] = []
        for candidate in candidates.sorted(by: {
            if $0.length != $1.length { return $0.length > $1.length }
            return $0.location < $1.location
        }) where !selected.contains(where: { NSIntersectionRange($0, candidate).length > 0 }) {
            selected.append(candidate)
        }
        return selected
    }
}

private enum AppError: LocalizedError {
    case microphoneDenied
    case systemAudioUnavailable(String)
    case runtimeNotReady
    case outputDirectoryMissing
    case sessionDirectoryMissing

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "未获得麦克风权限。请在“系统设置 → 隐私与安全性 → 麦克风”中允许 LiveLingo。"
        case .systemAudioUnavailable(let detail):
            return "系统音频内录启动失败：\(detail) 请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 LiveLingo，然后重新开始。"
        case .runtimeNotReady:
            return "本机 Qwen 服务或当前 LM Studio 模型尚未就绪。"
        case .outputDirectoryMissing:
            return "尚未选择录音保存目录。"
        case .sessionDirectoryMissing:
            return "会话目录丢失，无法导出记录。"
        }
    }
}
