import AppKit
import AVFoundation
import Foundation
import OSLog
@preconcurrency import Translation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: AppPhase = .idle {
        didSet {
            if phase != .recording { resetPreviewTranslation() }
            updateReviewAvailability()
        }
    }
    @Published private(set) var audioInputStatus = "等待检查"
    @Published private(set) var speechStatus = "等待检查"
    @Published private(set) var translationStatus = "正在检查本机翻译模型…"
    @Published private(set) var translationReady = false
    @Published private(set) var volatileEnglish = "" {
        didSet {
            if oldValue.isEmpty || volatileEnglish.isEmpty || !volatileEnglish.hasPrefix(oldValue) {
                resetPreviewTranslation()
            }
        }
    }
    @Published var previewTranslationEnabled = true {
        didSet { resetPreviewTranslation() }
    }
    @Published private(set) var previewChinese = ""
    @Published private(set) var previewTranslationStatus = "准备苹果初译…"
    private var previewRevision = 0

    var previewTranslationSource: String {
        volatileEnglish.isEmpty ? (segments.last?.english ?? "") : volatileEnglish
    }

    var supportsPreviewTranslation: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private func resetPreviewTranslation() {
        previewRevision += 1
        previewChinese = ""
    }

    @available(macOS 15.0, *)
    func runPreviewTranslation(session: TranslationSession) async {
        previewTranslationStatus = "准备初译语言包…"
        do {
            try await session.prepareTranslation()
            try Task.checkCancellation()
            previewTranslationStatus = "苹果初译 · 定稿后由 Qwen 替换"
            var lastSource = ""
            var lastRevision = -1
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(800))
                guard previewTranslationEnabled, isRecording else { continue }
                let source = previewTranslationSource.trimmingCharacters(in: .whitespacesAndNewlines)
                let revision = previewRevision
                guard source.count >= 3, source != lastSource || revision != lastRevision else { continue }
                lastSource = source
                lastRevision = revision
                do {
                    let response = try await session.translate(source)
                    try Task.checkCancellation()
                    // Growing partials may use the last prefix translation. A
                    // correction, final segment or lifecycle change invalidates it.
                    guard previewTranslationEnabled, isRecording,
                          revision == previewRevision,
                          previewTranslationSource.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(source)
                    else { continue }
                    previewChinese = SimplifiedChineseNormalizer.normalize(response.targetText)
                    previewTranslationStatus = "苹果初译 · 定稿后由 Qwen 替换"
                } catch {
                    if Task.isCancelled { return }
                    guard revision == previewRevision else { continue }
                    previewChinese = ""
                    previewTranslationStatus = "初译暂不可用，正式翻译继续"
                }
            }
        } catch {
            if !Task.isCancelled {
                previewTranslationStatus = "初译未就绪：\(error.localizedDescription)"
            }
        }
    }
    @Published private(set) var liveChinese = ""
    // Draft output belongs to one segment and never enters exported history.
    @Published private(set) var translatingSegmentID: UUID?
    @Published private(set) var streamingChinese = ""
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var lectureSummary = ""
    @Published private(set) var latestSummaryUpdate = ""
    var latestSummaryScope: String {
        let evidence = segments.filter { latestLearningIDs.contains($0.id) }
        guard let start = evidence.map(\.startTime).min(), let end = evidence.map(\.endTime).max() else {
            return "尚无已完成批次"
        }
        func stamp(_ value: TimeInterval) -> String {
            let seconds = max(0, Int(value))
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        }
        return "最近完成：\(stamp(start))–\(stamp(end))"
    }
    var summaryCoverageStatus: String {
        "已整理 \(lastSummarizedSegmentCount) / \(completedTranslationCount) 段已翻译内容"
    }
    @Published private(set) var reviewAdvice = ""
    private var summaryCycleIDs: Set<UUID>?
    private var summaryCycleUpdate = ""
    @Published private(set) var summaryStatus = "等待课堂内容"
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var lastAudioLevelAt: Date?
    @Published private(set) var waveformSamples = Array(repeating: Float.zero, count: 24)
    private static let rejectedTranscriptNotice = "上一语段未获得可用转写，已跳过；正在继续识别。"
    @Published private(set) var sessionNotice: String?
    @Published var manualTranslationInput = ""
    @Published private(set) var manualTranslationOutput = ""
    @Published private(set) var manualTranslationStatus = "输入英文，翻译为简体中文"
    @Published private(set) var isManualTranslating = false
    private var manualTranslationTask: Task<Void, Never>?
    private var manualRequestInFlight = false
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
    private var translationEnqueuedAt: [UUID: TimeInterval] = [:]
    private static let latencyLog = Logger(subsystem: "com.jianhongli.LiveLingo", category: "TranslationLatency")
    private var translationWorker: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var stopOverlapStarted = false
    private var summaryScheduleTask: Task<Void, Never>?
    @Published private(set) var summaryConcurrencyAllowed = false
    private var summaryMemoryPressureNormal = false
    private var memoryPressureMonitor: DispatchSourceMemoryPressure?
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
    private var summarizedSegmentIDs: Set<UUID> = []
    private var learningNotebook = LearningNotebook()
    private var learningDraft: LearningDraft?
    private var latestLearningIDs: Set<UUID> = []
    let noteReviewQueue: LearningReviewQueue
    private var reviewConcurrency = ReviewConcurrencyPolicy()

    private func invalidateSummary(for id: UUID) {
        if learningDraft?.evidence.contains(where: { $0.id == id }) == true { learningDraft = nil }
        let invalidated = learningNotebook.invalidate(id)
        guard !invalidated.isEmpty else { return }
        // A real revision of earlier evidence invalidates the frozen follow-up
        // context. Ordinary new captions do not change the notebook revision.
        if learningDraft != nil {
            learningDraft = nil
            summaryTask?.cancel()
        }
        summarizedSegmentIDs.subtract(invalidated)
        latestLearningIDs.subtract(invalidated)
        lectureSummary = learningNotebook.markdown()
        latestSummaryUpdate = learningNotebook.markdown(covering: latestLearningIDs)
        lastSummarizedSegmentCount = summarizedSegmentIDs.count
        summaryCycleUpdate = ""
        summaryCycleIDs = nil
        lastSummaryCycleStartedUptime = nil
        summaryStatus = "跨段译文已校正，相关笔记等待更新"
    }

    private func resetLearningNotes() {
        consecutiveSummaryFailures = 0
        reviewAdvice = ""
        learningNotebook = LearningNotebook()
        reviewConcurrency.reset()
        learningDraft = nil
        latestLearningIDs = []

    }
    private var lastSummarizedSegmentCount = 0
    private var summaryRefreshRequested = false
    private var summaryTaskGeneration = 0
    private var lastCaptionActivityUptime: TimeInterval?
    private var lastSummaryCycleStartedUptime: TimeInterval?
    private var consecutiveSummaryFailures = 0
    private var summaryRetryNotBefore: TimeInterval?
    private var accumulatedElapsedSeconds: TimeInterval = 0
    private var activeElapsedStartUptime: TimeInterval?

    init(reviewQueue: LearningReviewQueue? = nil) {
        noteReviewQueue = reviewQueue ?? LearningReviewQueue()
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
        noteReviewQueue.onUpdate = { [weak self] directory, report, status in
            guard let self, case .saved(let current) = self.phase, current == directory else { return }
            self.reviewAdvice = report
            self.summaryStatus = status
        }
        refreshPermissionLabels()
        pipeline.update(profile: effectiveProfile)
        refreshSummaryConcurrency()
        startMemoryPressureMonitor()
        #if !LIVELINGO_CLI
        startPowerMonitor()
        startRuntimeReadinessMonitor()
        #endif
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
        summaryRetryNotBefore = nil
        if translationWorker != nil && !summaryConcurrencyAllowed {
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
        stopOverlapStarted = false
        cancelScheduledSummaryRefresh()
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
        reviewConcurrency.reset()
        phase = .preparing
        volatileEnglish = ""
        liveChinese = ""
        translatingSegmentID = nil
        streamingChinese = ""
        segments = []
        lectureSummary = ""
        latestSummaryUpdate = ""
        summaryCycleIDs = nil
        summaryCycleUpdate = ""
        summaryStatus = "等待课堂内容"
        waveformSamples = Array(repeating: .zero, count: waveformSamples.count)
        sessionNotice = nil
        summarizedSegmentIDs = []
        resetLearningNotes()
        lastSummarizedSegmentCount = 0
        summaryRefreshRequested = false
        lastCaptionActivityUptime = nil
        lastSummaryCycleStartedUptime = nil
        summaryRetryNotBefore = nil
        translationQueue = []
        translationEnqueuedAt = [:]
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
        let stopStarted = ProcessInfo.processInfo.systemUptime
        await pipeline.stop()
        Self.traceStop("pipeline", since: stopStarted)
        let manualStarted = ProcessInfo.processInfo.systemUptime
        if manualRequestInFlight, let manualTranslationTask {
            await manualTranslationTask.value
        }

        Self.traceStop("manual_wait", since: manualStarted)
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
            translatingSegmentID = nil
            streamingChinese = ""
            segments = []
            resetLearningNotes()
            lectureSummary = ""
            latestSummaryUpdate = ""
            summaryCycleIDs = nil
            summaryCycleUpdate = ""
            summaryStatus = "等待课堂内容"
            translationQueue = []
            translationEnqueuedAt = [:]
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
            let migrationStarted = ProcessInfo.processInfo.systemUptime
            let sessionDirectory = try finalizeSessionDirectoryIfNeeded()
            Self.traceStop("recording_migration", since: migrationStarted)
            let drainStarted = ProcessInfo.processInfo.systemUptime
            drainTranslationQueue()
            startStopOverlapIfUseful()
            // A cancelled summary can still be unwinding and about to resume
            // queued captions. Wait for that handoff before exporting.
            while translationWorker != nil || summaryTask != nil || !translationQueue.isEmpty {
                if let summaryTask { _ = await summaryTask.result }
                drainTranslationQueue()
                if let translationWorker { _ = await translationWorker.result }
            }
            Self.traceStop("translation_summary_drain", since: drainStarted)
            self.summaryTask = nil
            cancelScheduledSummaryRefresh()
            let summaryStarted = ProcessInfo.processInfo.systemUptime
            await generateLectureSummary(force: true)
            Self.traceStop("final_summary", since: summaryStarted)
            let exportStarted = ProcessInfo.processInfo.systemUptime
            try SessionExporter.export(segments: segments, sessionDirectory: sessionDirectory, summary: lectureSummary)
            do {
                try noteReviewQueue.enqueue(directory: sessionDirectory, notebook: learningNotebook)
            } catch {
                summaryStatus = "已保存笔记 · 复查排队失败"
                sessionNotice = "复查未开始：\(error.localizedDescription)"
            }
            Self.traceStop("file_export", since: exportStarted)
            Self.traceStop("total", since: stopStarted)
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
            lastAudioLevelAt = Date()
            waveformSamples.removeFirst()
            waveformSamples.append(level)
        case let .volatile(text, _, _):
            volatileEnglish = text
            // Preview updates do not use the translation model. Let a summary
            // finish unless caption backlog or memory pressure requires yielding.
        case let .final(text, start, end, hints):
            if sessionNotice == Self.rejectedTranscriptNotice { sessionNotice = nil }
            volatileEnglish = ""
            markCaptionActivity()
            let segment = TranscriptSegment(startTime: start, endTime: end, english: text)
            segments.append(segment)
            translationHints[segment.id] = hints
            if lectureSummary.isEmpty, summaryTask == nil {
                summaryStatus = "正在积累课堂上下文"
            }
            translationQueue.append(segment.id)
            translationEnqueuedAt[segment.id] = ProcessInfo.processInfo.systemUptime
            updateReviewAvailability()
            yieldSummaryToCaptions()
            drainTranslationQueue()
        case .rejectedTranscript:
            volatileEnglish = ""
            sessionNotice = Self.rejectedTranscriptNotice
        case let .transcriptionIssue(start, end, message):
            let range = "\(Int(start) / 60):\(String(format: "%02d", Int(start) % 60))–\(Int(end) / 60):\(String(format: "%02d", Int(end) % 60))"
            sessionNotice = "\(range) · \(message)"
        case .failure(let message):
            Task { await failActiveSession(message) }
        }
    }

    func translateTypedText(thinking: Bool = false) {
        guard manualTranslationTask == nil else { return }
        let text = manualTranslationInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2000 else {
            manualTranslationStatus = "请输入 1–2000 字符的英文内容"
            return
        }
        isManualTranslating = true
        manualTranslationOutput = ""
        manualTranslationStatus = thinking ? "精确翻译：等待当前字幕翻译或摘要完成…" : "等待当前字幕翻译或摘要完成…"
        manualTranslationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.manualRequestInFlight = false
                self.isManualTranslating = false
                self.manualTranslationTask = nil
                self.drainTranslationQueue()
                let force = self.summaryRefreshRequested
                self.summaryRefreshRequested = false
                self.scheduleSummaryRefresh(force: force)
            }
            do {
                while self.translationWorker != nil || self.summaryTask != nil || self.phase == .stopping {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                self.manualRequestInFlight = true
                let modelName = self.effectiveProfile.translationModel
                self.manualTranslationStatus = thinking ? "精确翻译中 · 思考已开启 · \(modelName)" : "翻译中 · \(modelName)"
                let result = try await QwenTranslationClient.translateTypedText(text, modelName: modelName, thinking: thinking)
                try Task.checkCancellation()
                self.manualTranslationOutput = SimplifiedChineseNormalizer.normalize(result)
                self.manualTranslationStatus = thinking ? "精确翻译完成 · \(modelName)" : "已完成 · \(modelName)"
            } catch is CancellationError {
                self.manualTranslationStatus = "已取消"
            } catch {
                self.manualTranslationStatus = "翻译失败：\(error.localizedDescription)"
            }
        }
    }

    func cancelTypedTranslation() { manualTranslationTask?.cancel() }

    private func drainTranslationQueue() {
        guard !manualRequestInFlight, (summaryTask == nil || summaryConcurrencyAllowed), translationWorker == nil, !translationQueue.isEmpty else { return }
        let currentGeneration = generation
        translationWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.translationQueue.isEmpty, !Task.isCancelled, currentGeneration == self.generation {
                let id = self.translationQueue.removeFirst()
                defer {
                    self.translationEnqueuedAt.removeValue(forKey: id)
                    self.updateReviewAvailability()
                }
                guard let index = self.segments.firstIndex(where: { $0.id == id }) else { continue }
                let english = self.segments[index].english
                let recentContext = self.segments[..<index].suffix(6)
                    .filter { self.segments[index].startTime - $0.endTime <= 60 }
                    .map(\.english).joined(separator: " ")
                let normalizedInput = AcademicInputNormalizer.normalize(english, recentContext: recentContext)
                let protectedInput = ChemistryTranslationProtector.prepare(normalizedInput)
                let translationModel = self.effectiveProfile.translationModel
                let hints = self.translationHints.removeValue(forKey: id) ?? []
                let started = ProcessInfo.processInfo.systemUptime
                let enqueued = self.translationEnqueuedAt[id] ?? started
                Self.traceTranslation("request", id: id, elapsed: started - enqueued)
                self.translatingSegmentID = id
                self.streamingChinese = ""
                self.liveChinese = "翻译中…"
                do {
                    let response: String
                    var revisedPrevious: String?
                    let previousIndex = index > 0 && self.segments[index].startTime - self.segments[index - 1].endTime <= 2
                        && !self.segments[index - 1].chinese.isEmpty
                        && !self.segments[index - 1].chinese.hasPrefix("[翻译失败：") ? index - 1 : nil
                    if let previousIndex {
                        let pair = try await QwenTranslationClient.translateAdjacent(
                            previous: self.segments[previousIndex].english,
                            previousChinese: self.segments[previousIndex].chinese,
                            current: QwenTranslationClient.translationInput(text: normalizedInput, modelName: translationModel, hints: hints),
                            context: self.segments[..<previousIndex].suffix(2).map(\.english).joined(separator: " "),
                            modelName: translationModel,
                            repairPrevious: self.segments[previousIndex].endTime - self.segments[previousIndex].startTime >= 9.5
                                || !".!?".contains(self.segments[previousIndex].english.last ?? " ")
                                || english.first?.isLowercase == true)
                        response = pair.current
                        revisedPrevious = SimplifiedChineseNormalizer.normalize(pair.previous)
                    } else {
                    response = try await QwenTranslationClient.translate(
                        protectedInput.text,
                        modelName: translationModel,
                        hints: hints,
                        onUpdate: { [weak self] partial in
                            guard let self, !Task.isCancelled,
                                  currentGeneration == self.generation,
                                  self.translatingSegmentID == id else { return }
                            let draft = SimplifiedChineseNormalizer.normalize(
                                protectedInput.restorePartial(in: partial)
                            )
                            if self.streamingChinese.isEmpty, !draft.isEmpty {
                                Self.traceTranslation("first_text", id: id,
                                                      elapsed: ProcessInfo.processInfo.systemUptime - started)
                            }
                            self.streamingChinese = draft
                        }
                    )
                    }
                    try Task.checkCancellation()
                    let restored = previousIndex == nil ? protectedInput.restore(in: response) : response
                    let chinese = SimplifiedChineseNormalizer.normalize(restored)
                    guard currentGeneration == self.generation,
                          let currentIndex = self.segments.firstIndex(where: { $0.id == id }) else { break }
                    if let previousIndex, let revisedPrevious,
                       self.segments[previousIndex].chinese != revisedPrevious {
                        self.segments[previousIndex].chinese = revisedPrevious
                        self.invalidateSummary(for: self.segments[previousIndex].id)
                    }
                    self.reviewConcurrency.observe(elapsed: ProcessInfo.processInfo.systemUptime - enqueued, successful: true)
                    self.segments[currentIndex].chinese = chinese
                    self.liveChinese = chinese
                    Self.traceTranslation("complete", id: id,
                                          elapsed: ProcessInfo.processInfo.systemUptime - started)
                } catch is CancellationError {
                    break
                } catch {
                    guard !Task.isCancelled, currentGeneration == self.generation else { break }
                    guard let currentIndex = self.segments.firstIndex(where: { $0.id == id }) else { continue }
                    self.reviewConcurrency.observe(elapsed: 0, successful: false)
                    self.segments[currentIndex].chinese = "[翻译失败：\(error.localizedDescription)]"
                    self.liveChinese = self.segments[currentIndex].chinese
                }
                self.translatingSegmentID = nil
                self.streamingChinese = ""
                self.startStopOverlapIfUseful()
            }
            guard currentGeneration == self.generation else { return }
            self.translatingSegmentID = nil
            self.streamingChinese = ""
            self.translationWorker = nil
            guard !Task.isCancelled else { return }
            self.markCaptionActivity()
            if !self.translationQueue.isEmpty {
                self.drainTranslationQueue()
            } else {
                let force = self.summaryRefreshRequested
                self.summaryRefreshRequested = false
                self.scheduleSummaryRefresh(force: force)
            }
        }
    }

    private static func traceStop(_ stage: String, since start: TimeInterval) {
        let milliseconds = Int(max(0, ProcessInfo.processInfo.systemUptime - start) * 1_000)
        latencyLog.notice("stop stage=\(stage, privacy: .public) elapsed_ms=\(milliseconds)")
    }

    private func startStopOverlapIfUseful() {
        guard phase == .stopping, activeStorageMode?.persistsSession == true,
              !stopOverlapStarted, summaryTask == nil,
              translationWorker != nil, !translationQueue.isEmpty,
              !manualRequestInFlight, !isManualTranslating else { return }
        refreshSummaryConcurrency()
        guard summaryConcurrencyAllowed, !hasCaptionBacklog,
              completedTranslationCount - lastSummarizedSegmentCount >= 2 else { return }
        // One bounded round only: never spawn a summary for each finishing caption.
        stopOverlapStarted = true
        summaryTaskGeneration += 1
        let taskGeneration = summaryTaskGeneration
        summaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.generateLectureSummary(force: false)
            guard taskGeneration == self.summaryTaskGeneration else { return }
            self.summaryTask = nil
            self.drainTranslationQueue()
        }
    }

    private static func traceTranslation(_ event: String, id: UUID, elapsed: TimeInterval) {
        let milliseconds = Int(max(0, elapsed) * 1_000)
        latencyLog.notice("caption event=\(event, privacy: .public) id=\(id.uuidString, privacy: .public) elapsed_ms=\(milliseconds)")
    }

    private func scheduleSummaryRefresh(force: Bool = false) {
        guard hasActiveSession else { return }
        guard summaryMemoryPressureNormal, !hasCaptionBacklog else {
            summaryStatus = summaryMemoryPressureNormal ? "字幕积压，摘要等待资源" : "内存紧张，摘要已暂停"
            if force { summaryRefreshRequested = true }
            return
        }
        guard !isManualTranslating else {
            if force { summaryRefreshRequested = true }
            return
        }
        guard summaryConcurrencyAllowed || (translationWorker == nil && translationQueue.isEmpty) else {
            summaryStatus = "等待字幕翻译空隙"
            if force { summaryRefreshRequested = true }
            return
        }
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
        guard force || completedCount > lastSummarizedSegmentCount else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let retryDelay = max(0, (summaryRetryNotBefore ?? now) - now)
        if !force || retryDelay > 0 {
            let ordinaryDelay = (force || summaryCycleIDs != nil) ? 0 : SummaryRefreshPolicy.delay(
                now: now,
                lastCaptionActivity: lastCaptionActivityUptime,
                lastCycleStarted: needsInitialSummary ? nil : lastSummaryCycleStartedUptime,
                allowConcurrent: summaryConcurrencyAllowed
            )
            let delay = max(ordinaryDelay, retryDelay)
            if delay > 0 {
                if force { summaryRefreshRequested = true }
                summaryScheduleTask?.cancel()
                let currentGeneration = generation
                summaryScheduleTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(delay))
                    } catch {
                        return
                    }
                    guard let self, currentGeneration == self.generation else { return }
                    self.summaryScheduleTask = nil
                    self.scheduleSummaryRefresh(force: force)
                }
                summaryStatus = retryDelay > 0
                    ? "摘要将在 \(Int(ceil(delay))) 秒后重试"
                    : "距下轮整理约 \(Int(ceil(delay))) 秒"
                return
            }
        }

        cancelScheduledSummaryRefresh()
        summaryRefreshRequested = false

        summaryTaskGeneration += 1
        let taskGeneration = summaryTaskGeneration
        summaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.generateLectureSummary(force: force)
            guard self.summaryTaskGeneration == taskGeneration else { return }
            if Task.isCancelled, force { self.summaryRefreshRequested = true }
            self.summaryTask = nil
            self.drainTranslationQueue()
            // Resume pending work after the retry/refresh interval, even if no
            // more captions arrive after a cancelled or bounded summary batch.
            if self.translationWorker == nil {
                let requested = self.summaryRefreshRequested
                self.summaryRefreshRequested = false
                self.scheduleSummaryRefresh(force: requested)
            }
        }
    }

    private func generateLectureSummary(force: Bool) async {
        guard completedTranslationCount >= 2 else { return }
        let eligible = Set(segments.filter {
            !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.chinese.isEmpty && !$0.chinese.hasPrefix("[翻译失败：")
        }.map(\.id)).subtracting(summarizedSegmentIDs)
        if summaryCycleIDs == nil {
            guard !eligible.isEmpty else { return }
            // Freeze this round's boundary; incoming captions belong to the next round.
            summaryCycleIDs = eligible
            summaryCycleUpdate = ""
            lastSummaryCycleStartedUptime = ProcessInfo.processInfo.systemUptime
            Self.latencyLog.notice("summary event=cycle_start pending=\(eligible.count)")
        } else if force, !hasActiveSession {
            // Final export must also include captions completed since the interrupted round.
            summaryCycleIDs?.formUnion(eligible)
        }
        let currentGeneration = generation
        let modelName = effectiveProfile.translationModel
        while !Task.isCancelled, currentGeneration == generation {
            if hasActiveSession || (phase == .stopping && summaryTask != nil) {
                guard summaryMemoryPressureNormal, !hasCaptionBacklog,
                      summaryConcurrencyAllowed || (translationWorker == nil && translationQueue.isEmpty)
                else { return }
            }
            let boundary = summaryCycleIDs ?? []
            let batch = LectureSummaryInput.incremental(
                from: segments.filter { boundary.contains($0.id) },
                coveredIDs: summarizedSegmentIDs, previousSummary: "",
                maximumCharacters: SummaryRefreshPolicy.automaticBatchCharacters
            )
            guard !batch.segmentIDs.isEmpty else {
                summaryCycleIDs = nil
                summaryRetryNotBefore = nil
                return
            }
            let inputSnapshot = segments.filter { batch.segmentIDs.contains($0.id) }
            do {
                if learningDraft?.matches(evidence: inputSnapshot, model: modelName, contextRevision: learningNotebook.revision) != true {
                    let pending = learningNotebook.selectPendingPoints(for: inputSnapshot)
                    learningDraft = LearningDraft(
                        evidence: inputSnapshot, model: modelName,
                        input: try LearningPrompts.input(evidence: inputSnapshot, topics: learningNotebook.topics, pending: pending),
                        pendingTargets: pending.map(\.id), contextRevision: learningNotebook.revision
                    )
                }
                guard let draft = learningDraft else { return }
                // Bound repeated interruption and the retained text, without touching
                // completed batches. Only a valid, fully decoded note commits coverage.
                guard draft.completedNote != nil || (draft.attempts < 12 && draft.text.utf8.count <= 65_536) else {
                    learningDraft = nil
                    throw QwenRuntimeError.requestFailed("本批续写次数已达上限，等待重新整理。")
                }
                var note: LearningNote
                if let completed = draft.completedNote {
                    note = completed
                } else {
                    learningDraft?.attempts += 1
                    summaryStatus = draft.text.isEmpty ? "正在整理本轮新学…" : "正在接续未完成的笔记…"
                    let response = try await QwenTranslationClient.learningNote(
                        input: draft.input, modelName: modelName, prefix: draft.text
                    ) { [weak self] text in
                        guard let self, self.generation == currentGeneration,
                              self.learningDraft?.id == draft.id,
                              inputSnapshot == self.segments.filter({ batch.segmentIDs.contains($0.id) }) else { return }
                        self.learningDraft?.text = text
                    }
                    note = try LearningNote.decode(response)
                    if learningDraft?.id == draft.id { learningDraft?.completedNote = note }
                }
                guard !Task.isCancelled, currentGeneration == generation else { return }
                guard learningDraft?.id == draft.id, learningNotebook.revision == draft.contextRevision else { return }
                guard inputSnapshot == segments.filter({ batch.segmentIDs.contains($0.id) }) else {
                    learningDraft = nil
                    summaryCycleIDs = nil
                    return
                }
                note = LearningPrompts.resolvingFollowUps(note, targets: draft.pendingTargets)
                note.topic = SimplifiedChineseNormalizer.normalize(note.topic)
                note.sourceVersion = 2
                for index in note.points.indices {
                    note.points[index].text = SimplifiedChineseNormalizer.normalize(note.points[index].text)
                }
                try learningNotebook.append(evidence: inputSnapshot, note: note)
                learningDraft = nil
                consecutiveSummaryFailures = 0
                latestLearningIDs = learningNotebook.latestEvidenceIDs
                lectureSummary = learningNotebook.markdown()
                latestSummaryUpdate = learningNotebook.markdown(covering: latestLearningIDs)
                summarizedSegmentIDs.formUnion(batch.segmentIDs)
                lastSummarizedSegmentCount = summarizedSegmentIDs.count
                summaryStatus = "已整理 \(lastSummarizedSegmentCount) 段 · 本机生成"
                Self.latencyLog.notice("summary event=batch_complete")
                if boundary.isSubset(of: summarizedSegmentIDs) {
                    summaryCycleIDs = nil
                    summaryRetryNotBefore = nil
                    return
                }
                // Give caption events an opportunity to update pressure between bounded requests.
                await Task.yield()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, currentGeneration == generation else { return }
                // A broken process/timeout can resume its journal; an invalid
                // finished output must not become an endless JSON continuation.
                if (error as? QwenRuntimeError)?.preservesGenerationProgress != true { learningDraft = nil }
                consecutiveSummaryFailures += 1
                let retry = SummaryRefreshPolicy.failureRetryDelay(consecutiveFailures: consecutiveSummaryFailures)
                summaryRetryNotBefore = ProcessInfo.processInfo.systemUptime + retry
                Self.latencyLog.notice("summary event=failed retry_seconds=\(retry) error=\(error.localizedDescription, privacy: .public)")
                summaryStatus = lectureSummary.isEmpty
                    ? "摘要暂不可用：\(error.localizedDescription)"
                    : "保留上次摘要 · 本轮更新失败"
                return
            }
        }
    }

    private func updateReviewAvailability() {
        let recording = hasActiveSession || phase == .preparing || phase == .stopping
        if hasCaptionBacklog { reviewConcurrency.reset() }
        let capable = reviewConcurrency.allows(mode: selectedMode)
        let available = SummaryResourcePolicy.estimatedAvailableBytes() ?? 0
        noteReviewQueue.setContext(
            recording: recording, concurrent: capable,
            resourcesAvailable: summaryMemoryPressureNormal && !hasCaptionBacklog
                && available >= (recording ? 8 : 4) * 1_024 * 1_024 * 1_024
        )
    }

    private var completedTranslationCount: Int {
        segments.filter {
            !$0.chinese.isEmpty && !$0.chinese.hasPrefix("[翻译失败：")
        }.count
    }

    private func cancelSummaryTask() {
        cancelScheduledSummaryRefresh()
        summaryTaskGeneration += 1
        summaryTask?.cancel()
        summaryTask = nil
    }

    private var hasCaptionBacklog: Bool {
        SummaryRefreshPolicy.shouldYieldToCaptions(
            now: ProcessInfo.processInfo.systemUptime,
            pendingCount: translationEnqueuedAt.count,
            oldestEnqueuedAt: translationEnqueuedAt.values.min()
        )
    }

    private func yieldSummaryToCaptions(resourcePressure: Bool = false) {
        let memoryLimited = resourcePressure || (!summaryConcurrencyAllowed && !translationEnqueuedAt.isEmpty)
        guard memoryLimited || hasCaptionBacklog else { return }
        guard let summaryTask, !summaryTask.isCancelled else { return }
        summaryTask.cancel()
        // A long summary should not repeatedly restart in every short gap.
        summaryRetryNotBefore = ProcessInfo.processInfo.systemUptime
            + SummaryRefreshPolicy.interruptedRetryInterval
        // Keep the task slot until the request has closed. Its existing cleanup
        // resumes the captions, so two requests cannot race this handoff.
        summaryStatus = lectureSummary.isEmpty
            ? "字幕优先，摘要待更新"
            : "保留上次摘要 · 字幕优先，摘要待更新"
        Self.latencyLog.notice("summary event=yield reason=\(memoryLimited ? "memory" : "caption_backlog")")
    }

    private func cancelScheduledSummaryRefresh() {
        summaryScheduleTask?.cancel()
        summaryScheduleTask = nil
    }

    private func markCaptionActivity() {
        lastCaptionActivityUptime = ProcessInfo.processInfo.systemUptime
        if !summaryConcurrencyAllowed { cancelScheduledSummaryRefresh() }
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

    private func refreshSummaryConcurrency() {
        summaryMemoryPressureNormal = SummaryResourcePolicy.pressureIsNormal()
        let allowed = SummaryResourcePolicy.allowsConcurrency(
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            pressureNormal: summaryMemoryPressureNormal,
            availableBytes: SummaryResourcePolicy.estimatedAvailableBytes() ?? 0,
            alreadyEnabled: summaryConcurrencyAllowed
        )
        let lostConcurrency = summaryConcurrencyAllowed && !allowed
        summaryConcurrencyAllowed = allowed
        if !summaryMemoryPressureNormal || lostConcurrency { yieldSummaryToCaptions(resourcePressure: true) }
        updateReviewAvailability()
    }

    private func startMemoryPressureMonitor() {
        let monitor = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        monitor.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.summaryMemoryPressureNormal = false
                self.summaryConcurrencyAllowed = false
                self.yieldSummaryToCaptions(resourcePressure: true)
                self.updateReviewAvailability()
            }
        }
        monitor.resume()
        memoryPressureMonitor = monitor
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
                self.refreshSummaryConcurrency()
                self.yieldSummaryToCaptions()
                self.scheduleSummaryRefresh()
                let latest = PowerSourceMonitor.isOnBattery()
                if latest != self.isOnBattery {
                    self.isOnBattery = latest
                    self.applyResolvedProfile()
                }
            }
        }
    }

    private func applyResolvedProfile() {
        updateReviewAvailability()
        let resolved = selectedMode.resolvedProfile(isOnBattery: isOnBattery)
        guard resolved != effectiveProfile else {
            updateReadyLabels()
            return
        }
        reviewConcurrency.reset()
        effectiveProfile = resolved
        updateReviewAvailability()
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
        RecordingDiagnostics.append(recordingURL: sessionDirectory?.appendingPathComponent("recording.wav"),
            event: "recording_stopped_by_error", detail: message)
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
            translatingSegmentID = nil
            streamingChinese = ""
            segments = []
            resetLearningNotes()
            lectureSummary = ""
            latestSummaryUpdate = ""
            summaryCycleIDs = nil
            summaryCycleUpdate = ""
            summaryStatus = "等待课堂内容"
            translationQueue = []
            translationEnqueuedAt = [:]
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

struct ProtectedChemistryTranslationInput: Sendable {
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

    func restorePartial(in translatedText: String) -> String {
        let lower = translatedText.lowercased()
        // A placeholder may arrive across several tokens. Hold its unfinished
        // suffix until the formula can be restored in full.
        if replacements.contains(where: { lower.hasSuffix($0.placeholder.lowercased()) }) {
            return restore(in: translatedText)
        }
        var heldCount = 0
        for replacement in replacements {
            let placeholder = replacement.placeholder.lowercased()
            for length in 1..<placeholder.count where length > heldCount {
                if lower.hasSuffix(placeholder.prefix(length)) { heldCount = length }
            }
        }
        return restore(in: String(translatedText.dropLast(heldCount)))
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
            return "本机转写服务或内置语言模型尚未就绪。"
        case .outputDirectoryMissing:
            return "尚未选择录音保存目录。"
        case .sessionDirectoryMissing:
            return "会话目录丢失，无法导出记录。"
        }
    }
}

#if LIVELINGO_CLI
extension AppModel {
    func cliRun(file: URL?, seconds: Double, directory: URL, highQuality: Bool,
                report: @escaping @MainActor (String, [String: Any]) -> Void) async throws {
        effectiveProfile = highQuality ? .highQuality : .energySaver
        pipeline.update(profile: effectiveProfile)
        activeStorageMode = .saveSession
        activeInputMode = .systemAudio
        sessionDirectory = directory
        outputDirectory = directory
        phase = .preparing
        try await pipeline.prepareModel(profile: effectiveProfile) { reportText in
            Task { @MainActor in report("prepare", ["message": reportText]) }
        }
        phase = .recording
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                report("state", ["phase": self.phaseLabel, "segments": self.segments.count,
                    "translated": self.completedTranslationCount, "summarized": self.lastSummarizedSegmentCount,
                    "summaryRunning": self.summaryTask != nil, "concurrency": self.summaryConcurrencyAllowed,
                    "previewEnglish": self.previewTranslationSource, "previewChinese": self.previewChinese,
                    "translatingID": self.translatingSegmentID?.uuidString ?? "",
                    "latestEnglish": self.segments.last?.english ?? "",
                    "latestChinese": self.segments.last?.chinese ?? "",
                    "summary": self.lectureSummary, "summaryStatus": self.summaryStatus, "latestUpdate": self.latestSummaryUpdate])
                self.refreshSummaryConcurrency()
                self.yieldSummaryToCaptions()
                self.scheduleSummaryRefresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        let preview = Task { @MainActor in
            if #available(macOS 26.0, *) {
                let session = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans"))
                await self.runPreviewTranslation(session: session)
            }
        }
        defer { poll.cancel(); preview.cancel() }
        do {
            let sink: @Sendable (SpeechPipeline.Event) -> Void = { [weak self] event in
                Task { @MainActor in self?.consume(event) }
            }
            if let file {
                report("capture", ["kind": "silent-pcm-replay", "file": file.path])
                try await pipeline.cliReplay(file: file, recordingURL: directory.appendingPathComponent("recording.wav"), eventHandler: sink)
            } else {
                report("capture", ["kind": "system-audio", "seconds": seconds])
                try await pipeline.start(inputMode: .systemAudio, recordingURL: directory.appendingPathComponent("recording.wav"), eventHandler: sink)
                report("capture_ready", ["kind": "system-audio"])
                try await Task.sleep(for: .seconds(seconds))
            }
            guard phase == .recording else { throw QwenRuntimeError.requestFailed("CLI session stopped unexpectedly: " + phaseLabel) }
            phase = .stopping
            stopOverlapStarted = false
            cancelScheduledSummaryRefresh()
            let started = ProcessInfo.processInfo.systemUptime
            await stopSession()
            report("finished", ["phase": phaseLabel, "stopSeconds": ProcessInfo.processInfo.systemUptime-started,
                "segments": segments.count, "translated": completedTranslationCount,
                "summarized": lastSummarizedSegmentCount, "summaryStatus": summaryStatus, "summary": lectureSummary])
            if case .saved = phase {} else { throw QwenRuntimeError.requestFailed(phaseLabel) }
        } catch {
            await pipeline.cancel()
            translationWorker?.cancel()
            let pending = summaryTask
            cancelSummaryTask()
            await translationWorker?.value
            await pending?.value
            throw error
        }
    }
}
#endif
