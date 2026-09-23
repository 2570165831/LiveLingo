import AppKit
import UniformTypeIdentifiers
import AVFoundation
import Foundation
import OSLog
@preconcurrency import Translation

enum AppRuntimeEnvironment {
    static var isUnitTesting: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["LIVELINGO_UNIT_TESTING"] == "1" || env["XCTestConfigurationFilePath"] != nil
    }

    @MainActor static var preferences: UserDefaults {
        guard let suite = ProcessInfo.processInfo.environment["LIVELINGO_PREFERENCES_SUITE"] else { return .standard }
        precondition(!suite.isEmpty && suite.utf8.count <= 180 && suite.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
        }, "LIVELINGO_PREFERENCES_SUITE must name a local preference domain")
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("The configured preference domain is unavailable")
        }
        return defaults
    }
}

@MainActor
struct CaptionTranslationDependencies {
    typealias Update = @MainActor @Sendable (String) async -> Void
    var translate: (String, String, [AuxiliaryTranslationHint], Update?) async throws -> String
    var adjacent: (String, String, String, String, String, Bool) async throws -> QwenTranslationClient.AdjacentTranslation

    static let live = Self(
        translate: { try await QwenTranslationClient.translate($0, modelName: $1, hints: $2, onUpdate: $3) },
        adjacent: { try await QwenTranslationClient.translateAdjacent(previous: $0, previousChinese: $1,
            current: $2, context: $3, modelName: $4, repairPrevious: $5) }
    )
    static let unavailable = Self(
        translate: { _, _, _, _ in throw QwenRuntimeError.requestFailed("测试必须注入翻译器") },
        adjacent: { _, _, _, _, _, _ in throw QwenRuntimeError.requestFailed("测试必须注入翻译器") }
    )
}

@MainActor
struct LearningGenerationDependencies {
    var generate: (String, String, String, @escaping @MainActor @Sendable (String) async -> Void) async throws -> String
    static let live = Self(generate: { input, model, prefix, update in
        try await QwenTranslationClient.learningNote(input: input, modelName: model, prefix: prefix, onUpdate: update)
    })
    static let unavailable = Self(generate: { _, _, _, _ in
        throw QwenRuntimeError.requestFailed("测试必须注入笔记生成器")
    })
}

@MainActor
enum ReviewExportSource {
    static func markdown(for directory: URL?, queue: LearningReviewQueue,
                         sessionID: UUID? = nil, inputRevision: Int? = nil) throws -> String? {
        guard let directory else { return nil }
        let accessed = directory.startAccessingSecurityScopedResource()
        defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
        do {
            return try queue.collectedReviewReportMarkdown(for: directory, sessionID: sessionID,
                                                           inputRevision: inputRevision)
        } catch let error as SessionStoreError {
            throw ReviewIdentityError.unreadable(error.localizedDescription)
        }
    }

    /// 把同目录的 `summary-review-batch-<N>.md` 按批次号升序拼成一段，并明确标注这不是整课复查。
    ///
    /// 2026-09-20（父任务验收）：报告**存在但读不出来**（权限、损坏、非 UTF-8、空文件）时
    /// 必须**停止导出并提示** ✗ —— 不能像以前那样用 `try?` 静默跳过 ✗。
    /// 静默跳过的后果是：磁盘上明明有一份复查意见，界面却说“暂无已保存复查意见” ✗，
    /// 用户会以为模型没给意见，而不是“读不到” ✓。目录列不出来时同理 ✓。
    private static func batchReportMarkdown(in directory: URL) throws -> String? {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            throw QwenRuntimeError.requestFailed("读取复查报告目录失败，未导出：\(error.localizedDescription)")
        }
        var found: [(number: Int, text: String)] = []
        for file in files {
            guard let number = LearningReviewScope.batchReportNumber(file.lastPathComponent) else { continue }
            let text: String
            do {
                text = try String(contentsOf: file, encoding: .utf8)
            } catch {
                throw QwenRuntimeError.requestFailed(
                    "局部复查报告读取失败，未导出：\(file.lastPathComponent)（\(error.localizedDescription)）")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw QwenRuntimeError.requestFailed("局部复查报告为空，未导出：\(file.lastPathComponent)")
            }
            found.append((number: number, text: text))
        }
        let reports = found.sorted { $0.number < $1.number }
        guard !reports.isEmpty else { return nil }
        let numbers = reports.map { String($0.number) }.joined(separator: "、")
        let body = reports.map { $0.text }.joined(separator: "\n\n")
        return "以下为局部复查报告（第 \(numbers) 批），不是整课复查。\n\n" + body
    }
}

// MARK: - 苹果初译（预览）调度

/// 预览初译的调度规则：由新识别文本触发，而不是每轮固定等待。
///
/// 关键区别（相对 debounce）：新文本只替换待翻译的**内容**，不重置截止时间，
/// 所以连续增长的字幕不会把首条初译无限推迟。
enum PreviewTranslationPolicy {
    /// 短于这个长度的文本不值得发一次请求。
    static let minimumSourceLength = 3
    /// 两次请求开始之间的最小间隔：连续增长时限频，避免打满本地翻译服务。
    static let minimumRequestInterval: TimeInterval = 0.35
    /// 一条待翻译更新最多被推迟这么久（防止被不断到达的新文本饿死）。
    static let maximumCoalescingDelay: TimeInterval = 1.2

    /// 失败后的有界退避（成功后清零）。实现与测试共用同一张表。
    static func failureBackoff(consecutiveFailures: Int) -> TimeInterval {
        let ladder: [TimeInterval] = [0.5, 1, 2, 4, 8]
        guard consecutiveFailures > 0 else { return 0 }
        return ladder[min(consecutiveFailures, ladder.count) - 1]
    }
}

/// 预览初译的确定性调度状态机：不持有任务、不读时钟、不发请求，
/// 因此可以用假时间戳完整回归测试（见 RealtimePolicyTests）。
struct PreviewTranslationScheduler {
    /// 一次请求的身份 = 文本 + 预览修订号。修订号变化（取消、开关、前缀改写、
    /// 会话切换）说明旧结果作废，即使文本相同也要重新请求。
    struct Source: Equatable {
        var text: String
        var revision: Int
    }

    enum Action: Equatable {
        case idle
        case translate(Source)
        case wait(TimeInterval)
    }

    private(set) var pending: Source?
    /// 当前 `pending` **第一次**变成待翻译的时刻；后续新文本只换内容，不换它。
    private(set) var pendingSince: TimeInterval = 0
    private(set) var requested: Source?
    private(set) var inFlight = false
    private(set) var consecutiveFailures = 0
    private var lastRequestStart: TimeInterval?
    private var retryNotBefore: TimeInterval = 0
    private var lastRevision: Int?

    /// 记下当前屏幕上的源文本（每次循环都调用一次，重复调用无副作用）。
    mutating func note(_ source: Source, at now: TimeInterval) {
        if lastRevision != source.revision {
            // 修订号变化 = 新会话/新开关状态/前缀改写。旧会话攒下的失败退避
            // 不能拖慢新会话（否则一次失败会把新会话压住 8 秒）。
            lastRevision = source.revision
            consecutiveFailures = 0
            retryNotBefore = 0
        }
        guard source.text.count >= PreviewTranslationPolicy.minimumSourceLength else {
            pending = nil
            return
        }
        guard source != requested else {
            // 相同来源不重复请求。
            pending = nil
            return
        }
        if pending == nil { pendingSince = now }
        pending = source
    }

    mutating func beginRequest(_ source: Source, at now: TimeInterval) {
        requested = source
        if pending == source { pending = nil }
        inFlight = true
        lastRequestStart = now
    }

    mutating func finishRequest(success: Bool, at now: TimeInterval) {
        inFlight = false
        guard success else {
            // 失败的那条文本要能在退避结束后重试，因此不算“已请求”。
            requested = nil
            consecutiveFailures += 1
            retryNotBefore = now + PreviewTranslationPolicy.failureBackoff(
                consecutiveFailures: consecutiveFailures
            )
            return
        }
        consecutiveFailures = 0
        retryNotBefore = 0
    }

    /// 停用、会话切换或前缀改写后丢弃全部待办与退避状态。
    mutating func reset() {
        pending = nil
        requested = nil
        inFlight = false
        consecutiveFailures = 0
        retryNotBefore = 0
    }

    func action(at now: TimeInterval) -> Action {
        guard !inFlight, let pending else { return .idle }
        let rateLimit = lastRequestStart.map {
            max(0, $0 + PreviewTranslationPolicy.minimumRequestInterval - now)
        } ?? 0
        let coalescing = max(0, pendingSince + PreviewTranslationPolicy.maximumCoalescingDelay - now)
        let backoff = max(0, retryNotBefore - now)
        // 取 min 保证不会因为“不断有更新”而无限推迟；取 max 保证失败退避不被绕过。
        let delay = max(backoff, min(rateLimit, coalescing))
        return delay > 0 ? .wait(delay) : .translate(pending)
    }
}

/// 预览循环的唤醒信号：新文本/开关变化时立刻结束等待，不用轮询。
@MainActor
final class PreviewWakeSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var pending = false

    func signal() {
        pending = true
        let waiter = continuation
        continuation = nil
        waiter?.resume()
    }

    /// 等到有新变化，或者最多等 `timeout` 秒（`nil` = 一直等到有变化）。
    func wait(timeout: TimeInterval?) async {
        if pending {
            pending = false
            return
        }
        var timer: Task<Void, Never>?
        if let timeout {
            timer = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                self?.signal()
            }
        }
        defer { timer?.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if pending {
                    pending = false
                    continuation.resume()
                    return
                }
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.signal() }
        }
    }
}

/// 预览初译的事件驱动循环。副作用全部注入，因此同一份代码既跑 Apple 的
/// `TranslationSession`，也能在测试里用假翻译器 + 假时钟确定性地跑。
@MainActor
struct PreviewTranslationRunner {
    struct Timing: Equatable {
        /// 真正的排队时长：从「当前源文本/修订号最近一次变化」到本次请求开始。
        /// 包含请求在途期间该文本已经到达并等待的那一段。
        var queue: TimeInterval
        /// 其中属于调度器自身的等待（限频 + 单请求在途合并）。
        var schedulerDelay: TimeInterval
        /// 本次请求的执行时长。
        var execute: TimeInterval
        /// 首条结果专用：从首次出现可翻译文本到结果返回。
        var firstSourceToResult: TimeInterval?
    }

    var now: @MainActor () -> TimeInterval
    var source: @MainActor () -> PreviewTranslationScheduler.Source
    /// 当前源文本最近一次变化的时刻（事件路径记录），用于测量真实排队。
    var sourceArrivedAt: @MainActor () -> TimeInterval
    /// 开关 + 录音状态 + 会话令牌；false 表示任何结果都不许落地。
    var isActive: @MainActor () -> Bool
    /// 本次运行已被更新的会话取代：必须立刻退出，不能继续等下去。
    var isSuperseded: @MainActor () -> Bool
    var translate: @MainActor (String) async throws -> String
    var deliver: @MainActor (PreviewTranslationScheduler.Source, String, Timing) -> Void
    var reportFailure: @MainActor (PreviewTranslationScheduler.Source, Timing, TimeInterval, Int) -> Void
    /// 等待新文本/状态变化，或最多 `timeout` 秒。
    var waitForChange: @MainActor (TimeInterval?) async -> Void

    func run() async {
        var scheduler = PreviewTranslationScheduler()
        var firstSourceUptime: TimeInterval?
        var hasDelivered = false
        while !Task.isCancelled {
            // 会话已被替换：旧 runner 直接结束，绝不进入无限等待。
            guard !isSuperseded() else { return }
            let iterationStart = now()
            guard isActive() else {
                scheduler.reset()
                await waitForChange(nil)
                continue
            }
            scheduler.note(source(), at: iterationStart)
            switch scheduler.action(at: iterationStart) {
            case .idle:
                await waitForChange(nil)
            case .wait(let delay):
                await waitForChange(delay)
            case .translate(let pending):
                let arrivedAt = sourceArrivedAt()
                if firstSourceUptime == nil { firstSourceUptime = arrivedAt }
                let queued = max(0, iterationStart - arrivedAt)
                let schedulerDelay = max(0, iterationStart - scheduler.pendingSince)
                scheduler.beginRequest(pending, at: iterationStart)
                let started = now()
                do {
                    let translated = try await translate(pending.text)
                    try Task.checkCancellation()
                    let finished = now()
                    scheduler.finishRequest(success: true, at: finished)
                    // 前缀兼容：增长中的文本可以沿用上一次的初译；改写（不再是前缀）、
                    // 修订号变化、开关/会话变化都会作废旧结果。
                    let current = source()
                    guard current.revision == pending.revision, current.text.hasPrefix(pending.text) else { continue }
                    guard isActive() else { continue }
                    var timing = Timing(queue: queued, schedulerDelay: schedulerDelay,
                                        execute: max(0, finished - started),
                                        firstSourceToResult: nil)
                    if !hasDelivered, let firstSourceUptime {
                        timing.firstSourceToResult = max(0, finished - firstSourceUptime)
                    }
                    hasDelivered = true
                    deliver(pending, translated, timing)
                } catch {
                    if Task.isCancelled { return }
                    let finished = now()
                    scheduler.finishRequest(success: false, at: finished)
                    reportFailure(
                        pending,
                        Timing(queue: queued, schedulerDelay: schedulerDelay,
                               execute: max(0, finished - started), firstSourceToResult: nil),
                        PreviewTranslationPolicy.failureBackoff(
                            consecutiveFailures: scheduler.consecutiveFailures
                        ),
                        scheduler.consecutiveFailures
                    )
                }
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var phase: AppPhase = .idle {
        didSet {
            // 暂停/结束时作废旧初译；恢复录音时也叫醒循环，让当前文本重新排一次队。
            if phase != .recording { resetPreviewTranslation() }
            if phase == .recording { markPreviewSourceChanged() }
            previewWake?.signal()
            updateReviewAvailability()
            applyIdleSleepAssertion()
            persistCurrentSession()
        }
    }
    @Published private(set) var audioInputStatus = "等待检查"
    @Published private(set) var speechStatus = "等待检查"
    @Published private(set) var translationStatus = "正在检查本机翻译模型…"
    @Published private(set) var translationReady = false
    @Published private(set) var volatileEnglish = "" {
        didSet {
            // 只有真正变化才算新的预览来源（重复写入同一文本不算）。
            if volatileEnglish != oldValue { markPreviewSourceChanged() }
            if oldValue.isEmpty || volatileEnglish.isEmpty || !volatileEnglish.hasPrefix(oldValue) {
                resetPreviewTranslation()
            }
            // 前缀增长同样是新的预览来源，必须立刻叫醒等待中的初译循环。
            previewWake?.signal()
        }
    }
    @Published var previewTranslationEnabled = true {
        didSet { resetPreviewTranslation() }
    }
    @Published private(set) var previewChinese = ""
    @Published private(set) var previewTranslationStatus = "准备苹果初译…"
    private var previewRevision = 0
    /// 当前预览循环的唤醒信号；同一时刻只服务最新一次会话。
    private var previewWake: PreviewWakeSignal?
    /// 每次 `runPreviewTranslation` 的身份；旧循环返回的结果不能写进新会话。
    private var previewRunToken: UUID?
    /// 预览时序日志的窗口聚合状态（见 `tracePreviewReceiveHop`）。
    private var previewHopWindowStarted: TimeInterval = 0
    private var previewHopWorst: TimeInterval = 0
    private var previewHopCount = 0
    /// 当前预览源文本（或修订号）最近一次变化的时刻。事件路径即记录，
    /// 因此能算上「请求在途期间新文本已经到达并等待」的那段时间。
    private var previewSourceChangedAt: TimeInterval = 0

    var previewTranslationSource: String {
        volatileEnglish.isEmpty ? (segments.last?.english ?? "") : volatileEnglish
    }

    var supportsPreviewTranslation: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private func markPreviewSourceChanged() {
        previewSourceChangedAt = ProcessInfo.processInfo.systemUptime
    }

    private func resetPreviewTranslation() {
        previewRevision += 1
        previewChinese = ""
        // 修订号变化 = 这条文本重新成为「待翻译」，排队时间从此刻算起。
        markPreviewSourceChanged()
        previewWake?.signal()
    }

    private func installPreviewWake(_ wake: PreviewWakeSignal) {
        // 旧循环（会话被替换）必须先被叫醒，否则它会一直挂在等待上。
        previewWake?.signal()
        previewWake = wake
    }

    private func releasePreviewWake(_ wake: PreviewWakeSignal) {
        guard previewWake === wake else { return }
        previewWake = nil
        wake.signal()
    }

    @available(macOS 15.0, *)
    func runPreviewTranslation(session: TranslationSession) async {
        // 令牌必须在任何 await 之前绑定：否则旧会话的 prepareTranslation 返回后
        // 会覆盖新会话的令牌，把最新一次运行误判成“已过期”。
        let runToken = UUID()
        previewRunToken = runToken
        // Wake the superseded loop before preparation: preparation may fail
        // or take a long time, and the old loop must not remain suspended.
        previewWake?.signal()
        markPreviewSourceChanged()
        previewTranslationStatus = "准备初译语言包…"
        do {
            try await session.prepareTranslation()
            try Task.checkCancellation()
            // prepare 期间可能已经有更新的会话接替：旧会话直接退出，不改状态。
            guard previewRunToken == runToken else { return }
            previewTranslationStatus = "苹果初译 · 定稿后由 Qwen 替换"
            let wake = PreviewWakeSignal()
            installPreviewWake(wake)
            defer { releasePreviewWake(wake) }
            await PreviewTranslationRunner(
                now: { ProcessInfo.processInfo.systemUptime },
                source: {
                    PreviewTranslationScheduler.Source(
                        text: self.previewTranslationSource.trimmingCharacters(in: .whitespacesAndNewlines),
                        revision: self.previewRevision
                    )
                },
                sourceArrivedAt: { self.previewSourceChangedAt },
                isActive: {
                    self.previewTranslationEnabled && self.isRecording && self.previewRunToken == runToken
                },
                isSuperseded: { self.previewRunToken != runToken },
                translate: { try await session.translate($0).targetText },
                deliver: { source, translated, timing in
                    self.previewChinese = SimplifiedChineseNormalizer.normalize(translated)
                    self.previewTranslationStatus = "苹果初译 · 定稿后由 Qwen 替换"
                    Self.tracePreview("delivered", characters: source.text.count, timing: timing)
                },
                reportFailure: { source, timing, backoff, failures in
                    // 旧会话/被改写/已停用的失败既不能改动界面，也不能拖慢新会话。
                    guard self.previewRunToken == runToken,
                          self.previewTranslationEnabled, self.isRecording,
                          source.revision == self.previewRevision,
                          self.previewTranslationSource
                              .trimmingCharacters(in: .whitespacesAndNewlines)
                              .hasPrefix(source.text)
                    else { return }
                    self.previewChinese = ""
                    self.previewTranslationStatus = "初译暂不可用，正式翻译继续"
                    Self.tracePreviewFailure(timing: timing, backoff: backoff, failures: failures)
                },
                waitForChange: { timeout in await wake.wait(timeout: timeout) }
            ).run()
        } catch {
            // 旧 prepare 的错误同样不能改新会话的状态。
            guard previewRunToken == runToken else { return }
            if !Task.isCancelled {
                previewTranslationStatus = "初译未就绪：\(error.localizedDescription)"
            }
        }
    }
    @Published private(set) var liveChinese = ""
    // Draft output belongs to one segment and never enters exported history.
    @Published private(set) var translatingSegmentID: UUID?
    @Published private(set) var streamingChinese = ""
    @Published private(set) var segments: [TranscriptSegment] = [] {
        didSet { persistCurrentSession() }
    }
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
            preferences.set(selectedMode.rawValue, forKey: Self.modelModeDefaultsKey)
            applyResolvedProfile()
        }
    }
    @Published var selectedStorageMode: SessionStorageMode {
        didSet {
            guard selectedStorageMode != oldValue else { return }
            preferences.set(
                selectedStorageMode.rawValue,
                forKey: Self.storageModeDefaultsKey
            )
        }
    }
    @Published var selectedInputMode: AudioInputMode {
        didSet {
            guard selectedInputMode != oldValue else { return }
            preferences.set(
                selectedInputMode.rawValue,
                forKey: Self.inputModeDefaultsKey
            )
            refreshPermissionLabels()
        }
    }
    @Published private(set) var effectiveProfile: QwenModelProfile
    @Published private(set) var isOnBattery: Bool

    /// 「专注模式」：只调整本应用自己的任务顺序，见 ProcessingFocusPolicy。
    @Published var processingFocusEnabled: Bool {
        didSet {
            guard processingFocusEnabled != oldValue else { return }
            preferences.set(processingFocusEnabled, forKey: Self.focusModeDefaultsKey)
            updateReviewAvailability()
        }
    }

    /// Independent option, off by default: keep the Mac awake only while a
    /// recording session is running. Never implied by the focus switch.
    @Published var preventIdleSleepWhileRecording: Bool {
        didSet {
            guard preventIdleSleepWhileRecording != oldValue else { return }
            preferences.set(preventIdleSleepWhileRecording, forKey: Self.preventIdleSleepDefaultsKey)
            applyIdleSleepAssertion()
        }
    }

    /// 每批字数：同时决定笔记粒度与后台复查的单批耗时。改动只影响之后生成的批次。
    @Published var noteBatchCharacters: Int {
        didSet {
            guard noteBatchCharacters != oldValue else { return }
            preferences.set(noteBatchCharacters, forKey: Self.noteBatchDefaultsKey)
        }
    }

    @Published var exportFormat: NotesExportFormat = .markdown
    @Published var exportScope: NotesExportScope = .wholeLesson
    @Published var exportIncludesReviewAdvice = false
    @Published var exportIncludesTranscript = true
    @Published private(set) var exportStatus: String?
    @Published private(set) var isExporting = false
    private var idleSleepActivity: NSObjectProtocol?

    var focusStatusLine: String {
        ProcessingFocusPolicy.statusLine(focusMode: processingFocusEnabled)
    }

    var focusExplanation: String { ProcessingFocusPolicy.explanation }

    private let pipeline: SpeechPipeline
    private let captionTranslation: CaptionTranslationDependencies
    private let learningGeneration: LearningGenerationDependencies
    private let backgroundServicesEnabled: Bool
    private let preferences: UserDefaults
    private var translationWorkerID: UUID?
    private var translationQueue: [UUID] = []
    private var translationEnqueuedAt: [UUID: TimeInterval] = [:]
    private static let latencyLog = Logger(subsystem: "com.jianhongli.LiveLingo", category: "TranslationLatency")
    /// 苹果初译（预览）的时序日志：只记毫秒/计数，绝不记正文。
    private static let previewLog = Logger(subsystem: "com.jianhongli.LiveLingo", category: "PreviewLatency")
    private var translationWorker: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var stopOverlapStarted = false
    private var summaryScheduleTask: Task<Void, Never>?
    @Published private(set) var summaryConcurrencyAllowed = false
    private var summaryMemoryPressureNormal = false
    @Published private(set) var runtimeResources: RuntimeResourceSnapshot?
    private var resourceRefreshTask: Task<Void, Never>?
    private var lastResourceDecision: ResourceSchedulingPolicy.Reason?
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
    private var sessionID = UUID()
    private var sessionSnapshot: SessionSnapshot?
    private var sessionSaver: SessionSaveCoordinator?
    private var finalizationOwner: UUID?
    private var processingTask: Task<Void, Never>?
    private var processingTaskID: UUID?
    private var processingPauseTask: Task<Void, Error>?
    private var processingPauseID: UUID?
    @Published private var processingPaused = false
    @Published private(set) var transcriptionProcessing: TranscriptionProcessingState?
    @Published private(set) var transcriptionCandidates: [TranscriptionCandidate] = []
    @Published private(set) var playingCandidateID: UUID?
    private var candidatePlayer: AVAudioPlayer?
    private var candidatePlaybackTask: Task<Void, Never>?
    @Published private(set) var archiveNotice: String?
    @Published private(set) var archiveError: String?
    private var archiveWriteError: String?
    @Published private(set) var candidateConfirmationInFlight = false
    private var lastReviewInvalidation: (sessionID: UUID, revision: Int)?
    @Published private(set) var archiveLoading = false
    @Published private(set) var legacyProvenanceUnavailable = false
    private var readinessGeneration = 0
    private var setupError: String?
    private var runtimeFailurePending = false
    private var summarizedSegmentIDs: Set<UUID> = []
    private var learningNotebook = LearningNotebook() {
        didSet { persistCurrentSession() }
    }
    private var learningDraft: LearningDraft? {
        didSet { persistCurrentSession() }
    }
    private var latestLearningIDs: Set<UUID> = [] {
        didSet { persistCurrentSession() }
    }
    let noteReviewQueue: LearningReviewQueue
    var reviewDisplayDirectory: URL? {
        guard case .saved(let directory) = phase else { return nil }
        return directory
    }
    private var reviewConcurrency = ReviewConcurrencyPolicy()

    // MARK: - 手动复查入口（保存后由用户点选，绝不自动入队）

    /// 界面上「复查…」菜单的一项：一个已完成且有要点的批次。
    struct ReviewBatchChoice: Identifiable, Equatable {
        let id: UUID            // 批次 id
        let number: Int         // 从 1 开始，必须与队列 scope 的编号一致
        let topic: String
        let pointCount: Int
        let timeRange: String   // LearningNoteBatch.timeRangeLabel
        let isLatest: Bool
    }

    /// 最近一次手动复查的结果提示（nil = 没有新提示）；只用于界面展示，不改笔记正文。
    @Published private(set) var reviewQueueNotice: String?

    /// 可复查批次：与 `LearningReviewQueue.enqueue(scope:)` 同一编号规则
    /// （只含有要点的批次，从 1 编号），所以第 N 项就对应 `scope.batch(N)`。
    var reviewBatchChoices: [ReviewBatchChoice] {
        let reviewable = learningNotebook.batches.filter { !$0.note.points.isEmpty }
        return reviewable.enumerated().map { index, batch in
            ReviewBatchChoice(id: batch.id, number: index + 1, topic: batch.note.topic,
                              pointCount: batch.note.points.count, timeRange: batch.timeRangeLabel,
                              isLatest: index == reviewable.count - 1)
        }
    }

    /// 会话已保存且至少有一个可复查批次时才能手动发起复查。
    var canManuallyReview: Bool {
        reviewDisplayDirectory != nil && !reviewBatchChoices.isEmpty
    }

    /// 显式入队整课或某一批：只投递复查任务，不改笔记正文，也不向界面抛错。
    func startManualReview(_ scope: LearningReviewScope) {
        guard let directory = reviewDisplayDirectory else {
            reviewQueueNotice = "复查未排队：会话尚未保存，暂无复查目录"
            return
        }
        let identity = sessionID, epoch = generation
        let revision = sessionSnapshot?.inputRevision
        let notebook = learningNotebook
        Task { [self] in
            do {
                try await flushSessionArchive()
                guard sessionID == identity, generation == epoch,
                      sessionSnapshot?.inputRevision == revision else {
                    if sessionID == identity { reviewQueueNotice = "课程内容已更新，请重新选择需要核对的范围。" }
                    return
                }
                try noteReviewQueue.enqueue(directory: directory, notebook: notebook, scope: scope,
                    sessionID: sessionSnapshot == nil ? nil : identity, inputRevision: revision)
                reviewQueueNotice = "已加入复查队列：\(scope.label) · 只给出核对意见，不会自动修改笔记正文"
            } catch {
                guard sessionID == identity, generation == epoch else { return }
                reviewQueueNotice = "复查未排队：\(error.localizedDescription)"
            }
        }
    }

    private func invalidateSummary(for id: UUID) {
        if learningDraft?.dependencyIDs.contains(id) == true {
            learningDraft = nil
            summaryTask?.cancel()
            summaryCycleIDs = nil
            lastSummaryCycleStartedUptime = nil
        }
        let invalidated = learningNotebook.invalidate(id)
        guard !invalidated.isEmpty else { return }
        // Only a source used by this draft can invalidate its frozen input.
        summarizedSegmentIDs.subtract(invalidated)
        latestLearningIDs.subtract(invalidated)
        lectureSummary = learningNotebook.markdown()
        latestSummaryUpdate = learningNotebook.markdown(covering: latestLearningIDs)
        lastSummarizedSegmentCount = summarizedSegmentIDs.count
        summaryCycleUpdate = ""
        // An unrelated retired batch is eligible for the next round. Preserve
        // this round and its already-generated prefix while it finishes.
        summaryStatus = "跨段译文已校正，相关笔记等待更新"
    }

    private func resetLearningNotes() {
        consecutiveSummaryFailures = 0
        reviewAdvice = ""
        // 新会话不显示上一场留下的手动复查提示。
        reviewQueueNotice = nil
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

    init(reviewQueue: LearningReviewQueue? = nil,
         pipeline: SpeechPipeline = SpeechPipeline(),
         translation: CaptionTranslationDependencies? = nil,
         notes: LearningGenerationDependencies? = nil,
         backgroundServices: Bool = true,
         defaults: UserDefaults = AppRuntimeEnvironment.preferences) {
        precondition(!AppRuntimeEnvironment.isUnitTesting || reviewQueue != nil,
                     "Tests must inject an isolated review queue")
        self.pipeline = pipeline
        self.captionTranslation = translation ?? (AppRuntimeEnvironment.isUnitTesting ? .unavailable : .live)
        self.learningGeneration = notes ?? (AppRuntimeEnvironment.isUnitTesting ? .unavailable : .live)
        self.backgroundServicesEnabled = backgroundServices && !AppRuntimeEnvironment.isUnitTesting
        self.preferences = defaults
        noteReviewQueue = reviewQueue ?? LearningReviewQueue()
        let savedMode = preferences.string(forKey: Self.modelModeDefaultsKey)
            .flatMap(ModelMode.init(rawValue:)) ?? .automatic
        let savedStorageMode = preferences.string(forKey: Self.storageModeDefaultsKey)
            .flatMap(SessionStorageMode.init(rawValue:)) ?? .saveSession
        let savedInputMode = preferences.string(forKey: Self.inputModeDefaultsKey)
            .flatMap(AudioInputMode.init(rawValue:)) ?? .microphone
        let savedBatchCharacters = preferences.object(forKey: Self.noteBatchDefaultsKey) as? Int
        noteBatchCharacters = savedBatchCharacters ?? SummaryRefreshPolicy.automaticBatchCharacters
        let savedFocusMode = preferences.bool(forKey: Self.focusModeDefaultsKey)
        let savedPreventIdleSleep = preferences.bool(forKey: Self.preventIdleSleepDefaultsKey)
        let onBattery = PowerSourceMonitor.isOnBattery()
        processingFocusEnabled = savedFocusMode
        preventIdleSleepWhileRecording = savedPreventIdleSleep
        selectedMode = savedMode
        selectedStorageMode = savedStorageMode
        selectedInputMode = savedInputMode
        isOnBattery = onBattery
        effectiveProfile = savedMode.resolvedProfile(isOnBattery: onBattery)
        noteReviewQueue.onUpdate = { [weak self] directory, _, status in
            guard let self, case .saved(let current) = self.phase, current == directory else { return }
            do {
                self.reviewAdvice = try ReviewExportSource.markdown(for: current, queue: self.noteReviewQueue,
                    sessionID: self.sessionSnapshot?.sessionID, inputRevision: self.sessionSnapshot?.inputRevision) ?? ""
                self.reviewQueueNotice = status
            } catch { self.reviewQueueNotice = error.localizedDescription }
        }
        pipeline.update(profile: effectiveProfile)
        guard backgroundServicesEnabled else { return }
        refreshPermissionLabels()
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
        !phase.isBusy && !archiveLoading && translationReady
    }

    var phaseLabel: String {
        switch phase {
        case .idle: return "待机"
        case .preparing: return "正在准备"
        case .recording: return "录音中"
        case .paused: return "已暂停"
        case .stopping: return isLiveOnly ? "正在结束" : "正在结束采集并保存"
        case .saved: return "已保存"
        case .liveEnded: return "已结束 · 未保存"
        case .failed: return "需要处理"
        }
    }

    var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return sessionNotice ?? archiveError ?? setupError
    }

    func dismissSessionNotice() {
        sessionNotice = nil
    }

    var modelModeStatus: String {
        let power = isOnBattery ? "电池" : "接电"
        return "\(selectedMode.title) · \(power) · \(effectiveProfile.shortLabel)"
    }

    var resourceStatusDescription: String {
        guard let snapshot = runtimeResources else { return "正在读取模型实际占用。" }
        let asr = snapshot.asr
        if let diagnostic = asr.diagnostic { return diagnostic }
        let language = snapshot.languageWorkers.values
        return "转写任务 \(asr.activeCount) · 语言模型任务 \(language.reduce(0) { $0 + $1.outstandingRequests }) · 等待退出确认 \(asr.unresolvedRequests.count + language.reduce(0) { $0 + $1.pendingControls })"
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
        do { try pipeline.updatePersistence(persistsSession: true) }
        catch {
            archiveError = "未能保留当前录音：\(error.localizedDescription)"
            return
        }
        activeStorageMode = .saveSession
        selectedStorageMode = .saveSession
        outputDirectory = directory
        if let sessionDirectory { bindSessionArchive(to: sessionDirectory) }
    }

    func start() {
        guard !phase.isBusy, !archiveLoading, !isImportingFile else { return }
        phase = .preparing
        Task {
            do {
                try await parkSavedProcessing()
                await startSession()
            } catch {
                if let directory = sessionDirectory { phase = .saved(directory) }
                else { phase = .failed("切换前保存失败：\(error.localizedDescription)") }
                archiveError = "当前课程进度尚未保存，保留现场：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 导入本地音视频文件（对标 Coursedude 的本地摄取）

    @Published private(set) var isImportingFile = false
    @Published private(set) var importProgress: Double = 0
    private var importTask: Task<Void, Never>?
    private var importFailureMessage: String?

    /// 选择本地音频/视频文件并走与实时录音相同的转写、翻译、笔记与导出流程。
    /// 不上传任何内容，也不改动源文件；导入需要先选定保存目录。
    func chooseAndImportMediaFile() {
        guard !phase.isBusy, !isImportingFile, !archiveLoading else { return }
        let panel = NSOpenPanel()
        panel.title = "导入本地音频或视频"
        panel.prompt = "导入"
        panel.message = "导入后走与实时录音相同的转写、翻译、笔记与导出流程；不会上传，也不会改动源文件。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // 只列本机 AVFoundation 真能解的封装：MKV/WebM 实测打不开，不让用户白选一次。
        panel.allowedContentTypes = [
            .mpeg4Movie, .quickTimeMovie, .mpeg4Audio,
            .wav, .mp3, .aiff, .audio,
            UTType(filenameExtension: "flac") ?? .audio,
            UTType(filenameExtension: "caf") ?? .audio,
        ]
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url, let self else { return }
                self.importTask?.cancel()
                self.importTask = Task { @MainActor [weak self] in
                    await self?.importMediaFile(url)
                    self?.importTask = nil
                }
            }
        }
    }

    /// 用户主动停止导入：把已经转出来的部分照常整理、导出并保存，不丢已完成的字幕。
    func cancelMediaImport() {
        guard isImportingFile, phase != .stopping else { return }
        sessionNotice = "正在停止导入，已转出的部分会被保存…"
        importTask?.cancel()
    }

    private func importMediaFile(_ fileURL: URL) async {
        guard !phase.isBusy, !isImportingFile, !archiveLoading else { return }
        if outputDirectory == nil { chooseOutputDirectory() }
        guard let outputDirectory else { return }
        let previousPhase = phase
        phase = .preparing
        isImportingFile = true
        importFailureMessage = nil
        importProgress = 0
        defer {
            isImportingFile = false
            importProgress = 0
        }
        do {
            try await parkSavedProcessing()
            try Task.checkCancellation()
        } catch {
            phase = previousPhase
            if !(error is CancellationError) {
                archiveError = "当前课程尚未保存，导入未开始：\(error.localizedDescription)"
            }
            return
        }
        resetSessionStateForNewRun()
        let importSession = sessionID, importEpoch = generation
        activeStorageMode = .saveSession
        sessionNotice = nil

        do {
            if !translationReady { await refreshRuntimeReadiness() }
            guard translationReady else {
                runtimeFailurePending = true
                startRuntimeReadinessMonitor()
                throw AppError.runtimeNotReady
            }
            try await pipeline.prepareModel(profile: effectiveProfile) { [weak self] status in
                Task { @MainActor in
                    guard let self, self.sessionID == importSession, self.generation == importEpoch else { return }
                    self.speechStatus = status
                }
            }
            try Task.checkCancellation()
            guard sessionID == importSession, generation == importEpoch else { return }
            let finalDirectory = SessionWorkspace.uniqueFinalDirectory(
                in: outputDirectory,
                preferredName: Self.sessionFolderName()
            )
            try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: false)
            sessionDirectory = finalDirectory
            bindSessionArchive(to: finalDirectory)
            let recordingURL = finalDirectory.appendingPathComponent(SessionWorkspace.recordingFileName)
            sessionNotice = "正在导入 \(fileURL.lastPathComponent)（完成后自动整理笔记）"
            let eventGeneration = generation
            try await pipeline.importMediaFile(
                fileURL,
                recordingURL: recordingURL,
                sessionID: sessionID,
                eventHandler: { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.generation == eventGeneration else { return }
                        self.consume(event)
                    }
                },
                onProgress: { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.sessionID == importSession, self.generation == importEpoch else { return }
                        self.importProgress = value
                    }
                }
            )
            await finishMediaImport(message: importFailureMessage ?? "导入完成")
        } catch is CancellationError {
            await finishMediaImport(message: importFailureMessage ?? "已停止导入")
        } catch {
            await finishMediaImport(message: "导入中断：\(error.localizedDescription)")
        }
    }

    private func finishMediaImport(message: String) async {
        phase = .stopping
        let hasPartialContent = pipeline.hasRecordedAudio || !segments.isEmpty
        let finishing = Task { @MainActor in
            if hasPartialContent {
                sessionNotice = "\(message)，正在整理保存已导入的内容。"
                await stopSession()
                if case .saved = phase {
                    sessionNotice = "\(message)，已保存已导入的音频和处理结果。"
                }
            } else {
                await pipeline.cancel()
                let oldTranslation = translationWorker
                oldTranslation?.cancel()
                await oldTranslation?.value
                translationWorker = nil
                translationQueue = []
                let pendingSummary = summaryTask
                cancelSummaryTask()
                await pendingSummary?.value
                // No audio or completed result exists in this app-created empty session.
                if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
                sessionDirectory = nil
                activeStorageMode = nil
                phase = .idle
                sessionNotice = "\(message)：没有已导入的音频，未保存空会话。"
            }
        }
        await finishing.value
    }

    // MARK: - 摘要导出

    var exportDirectory: URL? {
        if case .saved(let url) = phase { return url }
        return sessionDirectory
    }

    /// Snapshots the current notes and review advice. Export never calls a model
    /// and never touches the recording or the saved session files.
    func notesExportSnapshot() -> NotesExportSnapshot? {
        let notes = exportScope == .wholeLesson ? lectureSummary : latestSummaryUpdate
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            exportStatus = NotesExportError.emptyNotes.localizedDescription
            return nil
        }
        let directory = exportDirectory
        let transcript = exportIncludesTranscript
            ? (exportScope == .wholeLesson ? segments : segments.filter { latestLearningIDs.contains($0.id) })
            : []
        let report: String?
        do {
            report = exportIncludesReviewAdvice
                ? try ReviewExportSource.markdown(for: directory, queue: noteReviewQueue) : nil
        } catch {
            exportStatus = "读取复查报告失败，未导出：\(error.localizedDescription)"
            return nil
        }
        if exportIncludesReviewAdvice, report == nil {
            exportStatus = "该录音暂无已保存复查意见"
        }
        return NotesExportSnapshot(
            className: "实时课堂",
            sessionName: directory?.lastPathComponent,
            scope: exportScope,
            scopeDetail: exportScope == .wholeLesson ? summaryCoverageStatus : latestSummaryScope,
            coverageLine: summaryCoverageStatus,
            notesMarkdown: trimmed,
            reviewMarkdown: report,
            transcript: transcript,
            generatedAt: Date(),
            includesReviewAdvice: exportIncludesReviewAdvice,
            includesTranscript: exportIncludesTranscript && !transcript.isEmpty
        )
    }

    /// Opens the system save panel asynchronously: recording, capture and the
    /// translation queue keep running while the panel is up.
    func beginNotesExport() {
        guard !isExporting else { return }
        guard let snapshot = notesExportSnapshot() else { return }
        let format = exportFormat
        let panel = NSSavePanel()
        panel.title = "导出课堂笔记"
        panel.prompt = "导出"
        let reviewNotice = snapshot.includesReviewAdvice && snapshot.reviewMarkdown == nil
            ? " · 该录音暂无已保存复查意见" : ""
        panel.message = "所选范围：\(snapshot.scope.title) · 格式：\(format.title)" + reviewNotice
        panel.nameFieldStringValue = NotesExportDocument.defaultFileName(snapshot, format: format)
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url, let self else { return }
                self.performNotesExport(snapshot, format: format, to: url)
            }
        }
    }

    private func performNotesExport(_ snapshot: NotesExportSnapshot, format: NotesExportFormat, to url: URL) {
        isExporting = true
        exportStatus = "正在导出 \(format.title)…"
        Task.detached(priority: .userInitiated) {
            let message: String
            do {
                try NotesExportDocument.write(snapshot, format: format, to: url)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                let reviewNotice = snapshot.includesReviewAdvice && snapshot.reviewMarkdown == nil
                    ? "；该录音暂无已保存复查意见" : ""
                message = "已导出 \(url.lastPathComponent)（\(max(1, size / 1_024)) KB）" + reviewNotice
            } catch {
                message = "导出失败：\(error.localizedDescription)"
            }
            await MainActor.run {
                self.isExporting = false
                self.exportStatus = message
            }
        }
    }

    func clearExportStatus() { exportStatus = nil }

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

    var savedProcessingStatus: String? {
        guard case .saved = phase else { return nil }
        if let state = transcriptionProcessing, state.pendingCount > 0 {
            return "录音已停止 · \(processingPaused || state.isPaused ? "补转已暂停" : "正在补转") · 剩余 \(LearningTimeLabel.stamp(state.backlogSeconds))"
        }
        if processingPaused, !(sessionSnapshot?.processing.pendingSegmentIDs.isEmpty ?? true) {
            return "录音已保存 · 译文与笔记处理已暂停"
        }
        if processingTask != nil { return "录音已保存 · 正在整理译文与笔记" }
        if let state = transcriptionProcessing, state.unresolvedCount > 0 {
            return "已保存 · \(state.unresolvedCount) 段缺少转写，可手动重试"
        }
        return nil
    }

    var savedProcessingIsPaused: Bool { processingPaused }
    var savedTranscriptionWork: [TranscriptionWorkRecord] {
        guard pipeline.transcriptionState()?.sessionID == sessionID else { return [] }
        return pipeline.transcriptionWork()
    }

    private func bindSessionArchive(to directory: URL, restored: SessionSnapshot? = nil) {
        var snapshot = restored ?? SessionSnapshot(sessionID: sessionID,
            audioFiles: [.init(relativePath: SessionWorkspace.recordingFileName)],
            transcriptionJournalPath: DurableTranscriptionJournal.directoryName + "/work.jsonl")
        snapshot.generation = generation
        sessionSnapshot = snapshot
        let saver = SessionSaveCoordinator(directory: directory, sessionID: sessionID, restored: restored)
        let boundID = sessionID
        saver.onFailure = { [weak self, weak saver] error in
            guard let self, self.sessionID == boundID, self.sessionSaver === saver else { return }
            let message = "课程进度保存失败：\(error.localizedDescription)"
            self.archiveWriteError = message
            self.archiveError = message
        }
        saver.onSaved = { [weak self, weak saver] saved in
            guard let self, let saver, self.sessionID == boundID,
                  self.sessionSaver === saver, saved.sessionID == boundID,
                  SessionDirectoryLocation.canonical(saver.directory) == SessionDirectoryLocation.canonical(directory) else { return }
            self.sessionSnapshot?.storageRevision = saved.storageRevision
            self.sessionSnapshot?.lastJournalSequence = saved.lastJournalSequence
            self.sessionSnapshot?.lastJournalDigest = saved.lastJournalDigest
            self.sessionSnapshot?.updatedAt = saved.updatedAt
            if self.archiveError == self.archiveWriteError { self.archiveError = nil }
            self.archiveWriteError = nil
            do {
                try self.pipeline.reconcileAcceptedTranscriptionCandidates(saved)
                if self.pipeline.transcriptionState()?.sessionID == boundID {
                    let pending = Set(self.pipeline.transcriptionWork().filter { $0.candidateText != nil }.map(\.id))
                    self.transcriptionCandidates.removeAll { !pending.contains($0.id) }
                }
            } catch {
                self.archiveError = "正文已保存，候选确认尚未同步；请重试保存：\(error.localizedDescription)"
            }
            let handled = self.lastReviewInvalidation?.sessionID == boundID
                ? self.lastReviewInvalidation!.revision : 0
            if saved.inputRevision > handled {
                let revisions = saved.revisionHistory.filter { $0.toRevision > handled }
                do {
                    try self.noteReviewQueue.invalidateInputs(sessionID: boundID, inputRevision: saved.inputRevision,
                        affectedBatchIDs: revisions.isEmpty ? nil : Set(revisions.flatMap(\.retainedBatches).map(\.id)))
                    self.lastReviewInvalidation = (boundID, saved.inputRevision)
                } catch { self.reviewQueueNotice = "原复查进度已保留；输入修订同步失败：\(error.localizedDescription)" }
            }
        }
        sessionSaver = saver
        persistCurrentSession()
    }

    private func persistCurrentSession() {
        guard let saver = sessionSaver, var snapshot = sessionSnapshot,
              saver.sessionID == sessionID, snapshot.sessionID == sessionID else { return }
        snapshot.segments = segments
        learningNotebook.writeState(to: &snapshot)
        snapshot.latestEvidenceIDs = latestLearningIDs
        snapshot.generation = generation
        snapshot.generationCheckpoints = learningDraft.map {
            [$0.checkpoint(sessionID: sessionID, inputRevision: snapshot.inputRevision, generation: generation)]
        } ?? []
        snapshot.processing.paused = processingPaused
        snapshot.processing.summaryPaused = processingPaused
        snapshot.processing.reviewPaused = noteReviewQueue.userPaused
        snapshot.processing.pendingSegmentIDs = segments.filter { !$0.hasUsableTranslation }.map(\.id)
        snapshot.processing.pendingBatchIDs = learningDraft.map { [$0.id] } ?? []
        if isRecording || isPaused { snapshot.processing.phase = .capturing }
        else if processingPaused { snapshot.processing.phase = .paused }
        else if phase == .stopping || processingTask != nil || (transcriptionProcessing?.pendingCount ?? 0) > 0 {
            snapshot.processing.phase = .draining
        } else if case .saved = phase {
            if (transcriptionProcessing?.unresolvedCount ?? 0) > 0
                || segments.contains(where: { $0.translationState == .failed })
                || snapshot.processing.lastError != nil {
                snapshot.processing.phase = .failed
            } else if !snapshot.processing.pendingSegmentIDs.isEmpty {
                snapshot.processing.phase = .draining
            } else {
                snapshot.processing.phase = .completed
            }
        }
        sessionSnapshot = snapshot
        saver.submit(snapshot)
    }

    private func flushSessionArchive() async throws {
        guard let saver = sessionSaver else { return }
        let identity = sessionID
        persistCurrentSession()
        if let saved = try await saver.readback(), sessionID == identity,
           sessionSaver === saver {
            // The disk actor can advance while the classroom changes. Only
            // reconcile storage counters; keep newer in-memory content.
            sessionSnapshot?.storageRevision = saved.storageRevision
            sessionSnapshot?.lastJournalSequence = saved.lastJournalSequence
            sessionSnapshot?.lastJournalDigest = saved.lastJournalDigest
            sessionSnapshot?.updatedAt = saved.updatedAt
        }
    }

    /// Suspend processing of the displayed saved course before switching UI.
    /// Capture has already ended. New recording never waits for a 9B review.
    private func parkSavedProcessing() async throws {
        stopCandidatePlayback()
        if let task = processingPauseTask {
            try await task.value
            return
        }
        guard sessionSaver != nil else { return }
        let identity = sessionID, epoch = generation
        let pauseID = UUID()
        let oldProcessing = processingTask
        let oldProcessingID = processingTaskID
        let translation = translationWorker
        let translationID = translationWorkerID
        let summary = summaryTask
        processingPaused = true
        oldProcessing?.cancel()
        translation?.cancel()
        cancelSummaryTask()
        processingPauseID = pauseID
        let task = Task { @MainActor [self] in
            var pauseFailure: Error?
            if pipeline.transcriptionState()?.sessionID == identity {
                do { try await pipeline.pauseTranscription() }
                catch { pauseFailure = error }
            }
            await translation?.value
            await summary?.value
            await oldProcessing?.value
            guard sessionID == identity, generation == epoch else { return }
            if processingTaskID == oldProcessingID {
                processingTask = nil
                processingTaskID = nil
            }
            if translationWorkerID == translationID {
                translationWorker = nil
                translationWorkerID = nil
            }
            translatingSegmentID = nil
            streamingChinese = ""
            for index in segments.indices where segments[index].translationState == .translating {
                segments[index].deferTranslation()
            }
            try await flushSessionArchive()
            if let pauseFailure { throw pauseFailure }
        }
        processingPauseTask = task
        defer {
            if processingPauseID == pauseID {
                processingPauseTask = nil
                processingPauseID = nil
            }
        }
        try await task.value
    }

    func chooseSavedSession() {
        guard !phase.isBusy, !archiveLoading else { return }
        let panel = NSOpenPanel()
        panel.title = "打开已保存课程"
        panel.prompt = "打开课程"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            do { try await openSavedSession(directory) }
            catch { archiveError = "课程未打开：\(error.localizedDescription)" }
        }
    }

    func openSavedSession(_ directory: URL, allowAutomaticProcessing: Bool = true) async throws {
        guard !phase.isBusy, !archiveLoading else { return }
        archiveLoading = true
        defer { archiveLoading = false }
        let store = SessionStore(directory: directory)
        var loaded = try await Task.detached { try store.loadDetailed() }.value
        guard var snapshot = loaded.snapshot else { throw SessionStoreError.missingSnapshot }
        _ = try LearningNotebook(snapshot: snapshot)
        let sameDirectory = sessionDirectory.map(SessionDirectoryLocation.canonical)
            == SessionDirectoryLocation.canonical(directory)
        let priorPaused = sameDirectory ? processingPaused : snapshot.processing.paused
        try await parkSavedProcessing()
        if sameDirectory {
            loaded = try await Task.detached { try store.loadDetailed() }.value
            guard let latest = loaded.snapshot else { throw SessionStoreError.missingSnapshot }
            snapshot = latest
        }
        if loaded.incompleteTailBytes > 0 {
            _ = try await Task.detached { try store.preserveIncompleteTailAndResume() }.value
            snapshot = try await Task.detached { try store.load() }.value ?? snapshot
        }
        var recoveryError: String?
        var recoveredNotebook: LearningNotebook?
        do { recoveredNotebook = try noteReviewQueue.restorableLegacyNotebook(for: directory, snapshot: snapshot) }
        catch { recoveryError = error.localizedDescription }
        let notebook = try recoveredNotebook ?? LearningNotebook(snapshot: snapshot)
        if recoveredNotebook != nil { notebook.writeState(to: &snapshot) }
        resetSessionStateForNewRun()
        sessionID = snapshot.sessionID
        sessionDirectory = directory
        segments = snapshot.segments
        for index in segments.indices where segments[index].translationState == .translating {
            segments[index].deferTranslation()
        }
        learningNotebook = notebook
        latestLearningIDs = snapshot.latestEvidenceIDs
        summarizedSegmentIDs = Set(notebook.batches.flatMap(\.ids))
        lastSummarizedSegmentCount = summarizedSegmentIDs.count
        lectureSummary = notebook.batches.isEmpty ? (snapshot.legacyMarkdown ?? "") : notebook.markdown()
        latestSummaryUpdate = notebook.markdown(covering: latestLearningIDs)
        learningDraft = snapshot.generationCheckpoints.compactMap {
            LearningDraft(checkpoint: $0, snapshot: snapshot, model: effectiveProfile.translationModel)
        }.first
        // The CLI's open-only mode must never start saved work. A completed
        // course can stay completed; unfinished work is explicitly parked.
        processingPaused = !allowAutomaticProcessing && snapshot.processing.phase == .completed ? false : true
        legacyProvenanceUnavailable = loaded.legacyProvenanceUnavailable && recoveredNotebook == nil
        sessionSnapshot = snapshot
        phase = .saved(directory)
        elapsedSeconds = snapshot.processing.lastCapturedTime ?? segments.map(\.endTime).max() ?? 0
        if legacyProvenanceUnavailable {
            archiveNotice = "旧课程已打开。原字幕与笔记保留；历史笔记缺少来源批次，重新整理需要明确操作。"
        } else {
            if recoveredNotebook != nil {
                archiveNotice = "已恢复旧队列记录的笔记批次与来源；复查进度和暂停选择保留。"
            } else if loaded.incompleteTailBytes > 0 {
                archiveNotice = "已恢复完整进度；未写完的日志尾部已另存。录音保持停止。"
            } else {
                archiveNotice = "课程已打开；录音保持停止，未完成处理可继续。"
            }
            bindSessionArchive(to: directory, restored: snapshot)
        }
        if let recoveryError { archiveError = recoveryError }
        let identity = sessionID, epoch = generation
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(
            DurableTranscriptionJournal.directoryName).path) {
            do {
                try await pipeline.restoreTranscription(directory: directory, sessionID: identity,
                    startPaused: true) { [weak self] event in
                        Task { @MainActor in
                            guard let self, self.sessionID == identity, self.generation == epoch else { return }
                            self.consume(event)
                        }
                    }
                transcriptionProcessing = pipeline.transcriptionState()
            } catch {
                archiveError = "课程正文已打开；补转队列恢复失败：\(error.localizedDescription)"
            }
        }
        do { reviewAdvice = try ReviewExportSource.markdown(for: directory, queue: noteReviewQueue) ?? "" }
        catch { archiveError = "课程已打开；复查报告读取失败：\(error.localizedDescription)" }
        if allowAutomaticProcessing, !priorPaused, !legacyProvenanceUnavailable, archiveError == nil {
            resumeSavedProcessing()
        } else {
            persistCurrentSession()
        }
    }

    /// Explicitly rebuild provenance from preserved captions. Legacy Markdown
    /// stays in the archive; no invented link is assigned to its old statements.
    func rebuildSavedNotes() {
        guard case .saved(let directory) = phase, legacyProvenanceUnavailable,
              !segments.isEmpty, !archiveLoading else { return }
        var snapshot = sessionSnapshot ?? SessionSnapshot(sessionID: sessionID)
        snapshot.legacyMarkdown = snapshot.legacyMarkdown ?? lectureSummary
        snapshot.segments = segments
        snapshot.processing.paused = true
        learningNotebook = LearningNotebook()
        latestLearningIDs = []
        summarizedSegmentIDs = []
        lastSummarizedSegmentCount = 0
        legacyProvenanceUnavailable = false
        bindSessionArchive(to: directory, restored: snapshot)
        archiveNotice = "正在根据已保存字幕重建笔记；旧版笔记仍保留在课程存档中。"
        resumeSavedProcessing()
    }

    /// Explicit body changes carry old captions and affected batches forward.
    /// Initial translation/filling a missing range does not rewrite prior body.
    private func replaceExistingSegment(at index: Int, with replacement: TranscriptSegment, reason: String,
                                        candidateText: String? = nil) {
        let previous = segments[index]
        guard previous != replacement else { return }
        let nextRevision = (sessionSnapshot?.inputRevision ?? segments.map(\.inputRevision).max() ?? 0) + 1
        var next = replacement
        next.inputRevision = nextRevision
        let retained = learningNotebook.batches.filter { $0.ids.contains(previous.id) }
        let change = SessionInputRevision(fromRevision: nextRevision - 1, toRevision: nextRevision,
            previousSegment: previous, replacementSegment: next, retainedBatches: retained, reason: reason,
            transcriptionCandidateText: candidateText)
        sessionSnapshot?.inputRevision = nextRevision
        sessionSnapshot?.revisionHistory.append(change)
        segments[index] = next
        invalidateSummary(for: previous.id)
        if !next.hasUsableTranslation {
            if !translationQueue.contains(next.id) { translationQueue.append(next.id) }
            translationEnqueuedAt[next.id] = ProcessInfo.processInfo.systemUptime
        }
        persistCurrentSession()
    }

    /// 开始任意一次"课堂会话"前的状态重置：实时录音与文件导入共用。
    private func resetSessionStateForNewRun() {
        stopCandidatePlayback()
        sessionSaver = nil
        sessionSnapshot = nil
        sessionID = UUID()
        finalizationOwner = nil
        processingTask?.cancel()
        processingTask = nil
        processingTaskID = nil
        processingPaused = false
        transcriptionProcessing = nil
        transcriptionCandidates = []
        archiveNotice = nil
        archiveError = nil
        archiveWriteError = nil
        legacyProvenanceUnavailable = false
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
        generation += 1
        translationWorker?.cancel()
        translationWorker = nil
        cancelSummaryTask()
        resetElapsedClock()
    }

    private func startSession() async {
        resetSessionStateForNewRun()
        let startingSession = sessionID, startingEpoch = generation
        let storageMode = selectedStorageMode
        let inputMode = selectedInputMode
        activeStorageMode = storageMode
        activeInputMode = inputMode

        do {
            if !translationReady { await refreshRuntimeReadiness() }
            guard translationReady else {
                runtimeFailurePending = true
                startRuntimeReadinessMonitor()
                throw AppError.runtimeNotReady
            }
            guard sessionID == startingSession, generation == startingEpoch, finalizationOwner == nil else { return }
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
            guard sessionID == startingSession, generation == startingEpoch, finalizationOwner == nil else { return }
            try await pipeline.prepareModel(profile: effectiveProfile) { [weak self] status in
                Task { @MainActor in
                    guard let self, self.sessionID == startingSession, self.generation == startingEpoch else { return }
                    self.speechStatus = status
                }
            }
            guard sessionID == startingSession, generation == startingEpoch, finalizationOwner == nil else { return }

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

            if storageMode.persistsSession, let directory = sessionDirectory {
                bindSessionArchive(to: directory)
                try await flushSessionArchive()
            }

            do {
                let eventGeneration = generation
                try await pipeline.start(
                    inputMode: inputMode,
                    recordingURL: recordingURL,
                    sessionID: sessionID,
                    persistsSession: storageMode.persistsSession
                ) { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.generation == eventGeneration else { return }
                        self.consume(event)
                    }
                }
            } catch {
                if inputMode == .systemAudio {
                    throw AppError.systemAudioUnavailable(error.localizedDescription)
                }
                throw error
            }
            guard sessionID == startingSession, generation == startingEpoch, finalizationOwner == nil else { return }
            audioInputStatus = inputMode == .microphone ? "麦克风已接入" : "系统音频已接入"
            phase = .recording
            beginElapsedClock()
        } catch {
            guard sessionID == startingSession, generation == startingEpoch, finalizationOwner == nil else { return }
            if pipeline.hasRecordedAudio {
                await stopSession(failure: error.localizedDescription)
                return
            }
            await pipeline.cancel()
            guard sessionID == startingSession, generation == startingEpoch, finalizationOwner == nil else { return }
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

    private func stopSession(failure: String? = nil) async {
        let identity = sessionID
        let epoch = generation
        guard finalizationOwner != identity else { return }
        finalizationOwner = identity
        let mode = activeStorageMode
        phase = .stopping
        stopElapsedClock()
        cancelScheduledSummaryRefresh()
        let stopStarted = ProcessInfo.processInfo.systemUptime
        await pipeline.stopCapture(continueTranscribing: mode?.clearsHistoryWhenStopped != true)
        guard sessionID == identity, generation == epoch else { return }
        Self.traceStop("capture_closed", since: stopStarted)

        if mode?.clearsHistoryWhenStopped == true {
            await pipeline.cancel()
            let translation = translationWorker
            translation?.cancel()
            let summary = summaryTask
            cancelSummaryTask()
            await translation?.value
            await summary?.value
            guard sessionID == identity, generation == epoch else { return }
            var cleanupError: Error?
            if let temporarySessionDirectory {
                do { try SessionWorkspace.discardTemporarySession(temporarySessionDirectory) }
                catch { cleanupError = error }
            }
            sessionSaver = nil
            sessionSnapshot = nil
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
            transcriptionCandidates = []
            transcriptionProcessing = nil
            sessionDirectory = nil
            temporarySessionDirectory = nil
            activeStorageMode = nil
            activeInputMode = nil
            if let cleanupError { phase = .failed("实时录音已结束；临时文件删除失败：\(cleanupError.localizedDescription)") }
            else if let failure { phase = .failed(failure) }
            else { phase = .liveEnded }
            return
        }

        // Preserve the capture failure before any migration or export can fail.
        // A successful storage retry must still retain the interruption.
        if let failure {
            sessionSnapshot?.processing.recordFailure(failure, source: .capture)
        }
        do {
            // A converted live-only course may still be in a temporary root.
            // Pause every writer before verified full-tree promotion.
            let directory = try await finalizeSessionDirectoryIfNeeded()
            guard sessionID == identity, generation == epoch else { return }
            if sessionSaver == nil { bindSessionArchive(to: directory) }
            try await flushSessionArchive()
            let captions = segments, notes = lectureSummary
            try await Task.detached {
                try SessionExporter.export(segments: captions, sessionDirectory: directory, summary: notes)
            }.value
            guard sessionID == identity, generation == epoch else { return }
            volatileEnglish = ""
            activeStorageMode = nil
            activeInputMode = nil
            phase = .saved(directory)
            if let failure {
                sessionNotice = Self.recordingStoppedNotice(message: failure, segmentCount: segments.count)
            }
            processingPaused = false
            startSavedDrain()
            try await flushSessionArchive()
            Self.traceStop("audio_and_initial_state_saved", since: stopStarted)
        } catch {
            guard sessionID == identity, generation == epoch else { return }
            processingPaused = true
            activeStorageMode = nil
            activeInputMode = nil
            archiveError = "录音采集已停止；课程保存失败，保留现有文件与内存进度：\(error.localizedDescription)"
            sessionSnapshot?.processing.recordFailure(archiveError!, source: .storage)
            phase = .failed(archiveError!)
        }
    }

    private func startSavedDrain() {
        guard processingTask == nil, !processingPaused else { return }
        let identity = sessionID, epoch = generation
        let taskID = UUID()
        processingTaskID = taskID
        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.finishSavedProcessing(session: identity, epoch: epoch)
            guard self.sessionID == identity, self.generation == epoch, self.processingTaskID == taskID else { return }
            self.processingTask = nil
            self.processingTaskID = nil
            self.persistCurrentSession()
        }
    }

    private func finishSavedProcessing(session identity: UUID, epoch: Int) async {
        await pipeline.drainTranscription(sessionID: identity)
        guard !Task.isCancelled, !processingPaused, sessionID == identity, generation == epoch else { return }
        drainTranslationQueue()
        startStopOverlapIfUseful()
        while translationWorker != nil || summaryTask != nil || !translationQueue.isEmpty {
            if let summaryTask { await summaryTask.value }
            guard !Task.isCancelled, !processingPaused, sessionID == identity, generation == epoch else { return }
            drainTranslationQueue()
            if let translationWorker { await translationWorker.value }
        }
        guard !Task.isCancelled, !processingPaused, sessionID == identity, generation == epoch,
              let directory = sessionDirectory else { return }
        cancelScheduledSummaryRefresh()
        await generateLectureSummary(force: true)
        guard !Task.isCancelled, !processingPaused, sessionID == identity, generation == epoch else { return }
        do {
            try await flushSessionArchive()
            let captions = segments, notes = lectureSummary
            try await Task.detached {
                try SessionExporter.export(segments: captions, sessionDirectory: directory, summary: notes)
            }.value
            guard !Task.isCancelled, sessionID == identity, generation == epoch else { return }
            if let recovered = sessionSnapshot?.processing.clearResolvedStorageFailure(), archiveError == recovered {
                archiveError = nil
            }
            try await flushSessionArchive()
            archiveNotice = "录音和当前处理结果已保存。"
        } catch {
            guard sessionID == identity, generation == epoch else { return }
            archiveError = "录音保留；整理结果保存失败：\(error.localizedDescription)"
            sessionSnapshot?.processing.recordFailure(archiveError!, source: .storage)
        }
    }

    func pauseSavedProcessing() {
        guard case .saved = phase else { return }
        Task {
            do { try await parkSavedProcessing() }
            catch { archiveError = "处理暂停时保存失败：\(error.localizedDescription)" }
        }
    }

    func resumeSavedProcessing(retryID: UUID? = nil) {
        guard case .saved(let directory) = phase, !legacyProvenanceUnavailable else { return }
        let identity = sessionID, epoch = generation
        Task { [self] in
            do {
                if let processingPauseTask { try await processingPauseTask.value }
                guard sessionID == identity, generation == epoch else { return }
                if pipeline.transcriptionState()?.sessionID != identity {
                    try await pipeline.restoreTranscription(directory: directory, sessionID: identity) { [weak self] event in
                        Task { @MainActor in
                            guard let self, self.sessionID == identity, self.generation == epoch else { return }
                            self.consume(event)
                        }
                    }
                }
                guard sessionID == identity, generation == epoch else { return }
                if let retryID { try pipeline.retryTranscription(id: retryID) }
                try pipeline.resumeTranscription()
                processingPaused = false
                for segment in segments where !segment.hasUsableTranslation && !translationQueue.contains(segment.id) {
                    translationQueue.append(segment.id)
                    translationEnqueuedAt[segment.id] = ProcessInfo.processInfo.systemUptime
                }
                drainTranslationQueue()
                startSavedDrain()
                persistCurrentSession()
            } catch {
                guard sessionID == identity, generation == epoch else { return }
                archiveError = "未能继续处理：\(error.localizedDescription)"
            }
        }
    }

    func candidateInputRevision(_ id: UUID) -> Int {
        segments.first(where: { $0.id == id })?.inputRevision ?? 0
    }

    func acceptTranscriptionCandidate(_ id: UUID, editedText: String, expectedOriginal: String,
                                     expectedRevision: Int? = nil, expectedCandidate: String? = nil,
                                     expectedSession: UUID? = nil) {
        guard case .saved = phase, !archiveLoading, !candidateConfirmationInFlight,
              let candidate = transcriptionCandidates.first(where: { $0.id == id }),
              candidate.sessionID == sessionID else { return }
        let accepted = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accepted.isEmpty else { archiveError = "确认文字不能为空。"; return }
        let existing = segments.firstIndex(where: { $0.id == id })
        guard (existing.map { segments[$0].english } ?? "") == expectedOriginal,
              expectedRevision.map({ candidateInputRevision(id) == $0 }) ?? true,
              expectedCandidate.map({ candidate.text == $0 }) ?? true,
              expectedSession.map({ sessionID == $0 }) ?? true else {
            archiveError = "本段原文已发生变化，请重新查看差异后确认。"
            return
        }
        if accepted == expectedOriginal {
            dismissTranscriptionCandidate(id, expectedCandidate: candidate.text)
            return
        }
        let identity = sessionID, epoch = generation
        let previouslyPaused = processingPaused
        candidateConfirmationInFlight = true
        archiveLoading = true
        Task {
            defer { candidateConfirmationInFlight = false; archiveLoading = false }
            do {
                try await parkSavedProcessing()
                guard sessionID == identity, generation == epoch,
                      transcriptionCandidates.contains(where: { $0.id == id && $0.text == candidate.text }),
                      (segments.first(where: { $0.id == id })?.english ?? "") == expectedOriginal,
                      expectedRevision.map({ candidateInputRevision(id) == $0 }) ?? true else {
                    throw SessionStoreError.identityConflict("确认期间的原文或候选已更新")
                }
                // Empty ranges get an explicit empty predecessor, so the
                // revision journal records consent with the same stable ID.
                if !segments.contains(where: { $0.id == id }) {
                    segments.append(.init(id: id, startTime: candidate.start, endTime: candidate.end,
                        english: "", sessionID: identity, inputRevision: sessionSnapshot?.inputRevision ?? 0))
                    segments.sort { $0.startTime < $1.startTime }
                }
                guard let index = segments.firstIndex(where: { $0.id == id }) else {
                    throw SessionStoreError.invalidState("待确认片段无法定位")
                }
                let replacement = TranscriptSegment(id: id, startTime: segments[index].startTime,
                    endTime: segments[index].endTime, english: accepted, sessionID: identity)
                replaceExistingSegment(at: index, with: replacement, reason: "用户确认补转文字",
                                       candidateText: candidate.text)
                try await flushSessionArchive()
                guard sessionID == identity, generation == epoch else { return }
                if let saved = sessionSaver?.lastSavedSnapshot {
                    try pipeline.reconcileAcceptedTranscriptionCandidates(saved)
                }
                guard pipeline.transcriptionWork().first(where: { $0.id == id })?.candidateText == nil else {
                    throw SessionStoreError.invalidState("候选已更新，已保存的修订需要重新核对")
                }
                transcriptionCandidates.removeAll { $0.id == id && $0.text == candidate.text }
                if !translationQueue.contains(id) { translationQueue.append(id) }
                translationEnqueuedAt[id] = ProcessInfo.processInfo.systemUptime
                archiveNotice = "确认文字已保存，旧正文和笔记保留在修订历史中。"
                if !previouslyPaused { resumeSavedProcessing() }
            } catch {
                guard sessionID == identity, generation == epoch else { return }
                archiveError = "确认结果尚未完成保存；处理已暂停，原文修订和候选均保留。请重试保存：\(error.localizedDescription)"
            }
        }
    }

    func retrySavedSessionWrite() {
        guard case .saved(let directory) = phase, !archiveLoading else { return }
        let identity = sessionID, epoch = generation
        archiveLoading = true
        Task {
            defer { archiveLoading = false }
            do {
                try await flushSessionArchive()
                guard sessionID == identity, generation == epoch else { return }
                if let saved = sessionSaver?.lastSavedSnapshot {
                    try pipeline.reconcileAcceptedTranscriptionCandidates(saved)
                }
                // A prior failure may have happened while writing readable
                // exports, after the snapshot succeeded. Retry both outputs
                // before retiring the persisted storage failure.
                let captions = segments, notes = lectureSummary
                try await Task.detached {
                    try SessionExporter.export(segments: captions, sessionDirectory: directory, summary: notes)
                }.value
                guard sessionID == identity, generation == epoch else { return }
                sessionSnapshot?.processing.clearResolvedStorageFailure()
                try await flushSessionArchive()
                guard sessionID == identity, generation == epoch else { return }
                let pending = Set(pipeline.transcriptionWork().filter { $0.candidateText != nil }.map(\.id))
                transcriptionCandidates.removeAll { !pending.contains($0.id) }
                archiveError = sessionSnapshot?.processing.lastError
                archiveNotice = "课程进度已保存；处理保持原暂停状态。"
            } catch {
                guard sessionID == identity, generation == epoch else { return }
                archiveError = "课程进度仍未保存，原文件与待保存内容保留：\(error.localizedDescription)"
                sessionSnapshot?.processing.recordFailure(archiveError!, source: .storage)
            }
        }
    }

    func dismissTranscriptionCandidate(_ id: UUID, expectedCandidate: String? = nil) {
        guard !candidateConfirmationInFlight, !archiveLoading,
              let candidate = transcriptionCandidates.first(where: { $0.id == id }),
              candidate.sessionID == sessionID else { return }
        do {
            try pipeline.resolveTranscriptionCandidate(id: id, acceptedText: nil,
                expectedOriginal: candidate.originalText, expectedCandidate: expectedCandidate ?? candidate.text)
            transcriptionCandidates.removeAll { $0.id == id }
            if playingCandidateID == id { stopCandidatePlayback() }
        } catch { archiveError = "候选尚未关闭：\(error.localizedDescription)" }
    }

    /// Playback is only started by an explicit button action. Tests never
    /// invoke this method and all processing continues on internal audio.
    func playTranscriptionCandidate(_ id: UUID) {
        if playingCandidateID == id { stopCandidatePlayback(); return }
        guard let candidate = transcriptionCandidates.first(where: { $0.id == id }),
              candidate.sessionID == sessionID else { return }
        stopCandidatePlayback()
        do {
            let player = try AVAudioPlayer(contentsOf: candidate.audioURL)
            guard player.prepareToPlay(), player.play() else {
                throw QwenRuntimeError.requestFailed("音频输出未能开始播放")
            }
            candidatePlayer = player
            playingCandidateID = id
            let identity = sessionID
            candidatePlaybackTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0.1, player.duration))) }
                catch { return }
                guard let self, self.sessionID == identity, self.playingCandidateID == id else { return }
                self.stopCandidatePlayback()
            }
        } catch { archiveError = "本段录音无法播放：\(error.localizedDescription)" }
    }

    func stopCandidatePlayback() {
        candidatePlaybackTask?.cancel()
        candidatePlaybackTask = nil
        candidatePlayer?.stop()
        candidatePlayer = nil
        playingCandidateID = nil
    }

    private func consume(_ event: SpeechPipeline.Event) {
        switch event {
        case let .audioLevel(level):
            lastAudioLevelAt = Date()
            waveformSamples.removeFirst()
            waveformSamples.append(level)
        case let .volatile(text, _, _, observedAt):
            tracePreviewReceiveHop(ProcessInfo.processInfo.systemUptime - observedAt)
            volatileEnglish = text
            // Preview updates do not use the translation model. Let a summary
            // finish unless caption backlog or memory pressure requires yielding.
        case let .final(text, start, end, hints):
            appendConfirmedCaption(TranscriptSegment(startTime: start,
                endTime: end, english: text, sessionID: sessionID), hints: hints)
        case .identifiedFinal(let result):
            guard result.sessionID == sessionID else { return }
            if let existing = segments.first(where: { $0.id == result.id }) {
                // A repeated delivery from the same disk range is idempotent.
                // A conflicting result stays a candidate, never a silent edit.
                if existing.english != result.text {
                    do {
                        try pipeline.preserveConflictingTranscript(id: result.id, sessionID: sessionID,
                            originalText: existing.english, candidateText: result.text)
                        archiveNotice = "同一录音段出现不同转写，原文已保留，等待确认。"
                    } catch { archiveError = "原文已保留；候选记录失败：\(error.localizedDescription)" }
                }
                return
            }
            appendConfirmedCaption(TranscriptSegment(id: result.id, startTime: result.start,
                endTime: result.end, english: result.text, sessionID: result.sessionID,
                inputRevision: sessionSnapshot?.inputRevision ?? 0), hints: result.hints)
        case .processing(let state):
            guard state.sessionID == sessionID else { return }
            transcriptionProcessing = state
            if var snapshot = sessionSnapshot {
                let work = pipeline.transcriptionWork()
                let interruptions = snapshot.audioRanges.filter { $0.interruptionReason != nil }
                snapshot.audioRanges = work.map { record in
                    SessionAudioRange(id: record.id, segmentID: record.id,
                        filePath: SessionWorkspace.recordingFileName, startFrame: record.startFrame,
                        frameCount: record.endFrame - record.startFrame,
                        captureStart: record.captureStart ?? record.start,
                        captureEnd: record.captureEnd ?? record.end)
                } + interruptions
                if let last = work.max(by: { $0.endFrame < $1.endFrame }) {
                    snapshot.processing.lastCapturedTime = Double(last.endFrame) / last.sampleRate
                    if !snapshot.audioFiles.isEmpty {
                        snapshot.audioFiles[0].frameCount = last.endFrame
                        snapshot.audioFiles[0].sampleRate = last.sampleRate
                        snapshot.audioFiles[0].isFinalized = !state.isCapturing
                    }
                }
                sessionSnapshot = snapshot
            }
            persistCurrentSession()
        case .transcriptionCandidate(let candidate):
            guard candidate.sessionID == sessionID else { return }
            if let index = transcriptionCandidates.firstIndex(where: { $0.id == candidate.id }) {
                transcriptionCandidates[index] = candidate
            } else { transcriptionCandidates.append(candidate) }
        case .captureGap(let gap):
            guard gap.sessionID == sessionID else { return }
            if sessionSnapshot?.audioRanges.contains(where: { $0.id == gap.id }) == false {
                sessionSnapshot?.audioRanges.append(.init(id: gap.id, segmentID: gap.id,
                    filePath: SessionWorkspace.recordingFileName, startFrame: gap.lastWrittenFrame,
                    frameCount: 0, captureStart: gap.observedStart, captureEnd: gap.observedEnd,
                    interruptionReason: gap.reason))
            }
            sessionSnapshot?.processing.lastCapturedTime = gap.lastWrittenTime
            persistCurrentSession()
        case .rejectedTranscript:
            volatileEnglish = ""
            sessionNotice = Self.rejectedTranscriptNotice
        case let .transcriptionIssue(start, end, message):
            let range = "\(Int(start) / 60):\(String(format: "%02d", Int(start) % 60))–\(Int(end) / 60):\(String(format: "%02d", Int(end) % 60))"
            sessionNotice = "\(range) · \(message)"
        case .failure(let message):
            if isImportingFile {
                importFailureMessage = "导入中断：\(message)"
                sessionNotice = importFailureMessage
                if phase != .stopping { importTask?.cancel() }
            } else {
                let expectedSession = sessionID
                Task {
                    guard self.sessionID == expectedSession else { return }
                    await failActiveSession(message)
                }
            }
        }
    }

    private func appendConfirmedCaption(_ segment: TranscriptSegment, hints: [AuxiliaryTranslationHint]) {
            if sessionNotice == Self.rejectedTranscriptNotice { sessionNotice = nil }
            volatileEnglish = ""
            markCaptionActivity()
            segments.append(segment)
            segments.sort { $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime }
            translationHints[segment.id] = hints
            if lectureSummary.isEmpty, summaryTask == nil {
                summaryStatus = "正在积累课堂上下文"
            }
            translationQueue.append(segment.id)
            translationEnqueuedAt[segment.id] = ProcessInfo.processInfo.systemUptime
            updateReviewAvailability()
            yieldSummaryToCaptions()
            if !processingPaused { drainTranslationQueue() }
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

    #if DEBUG
    /// Synthetic presentation data only. Test hosts have no services or real queue.
    func loadPresentationForTesting(phase: AppPhase, evidence: [TranscriptSegment],
                                    notebook: LearningNotebook = .init(), notice: String? = nil,
                                    preview: String = "") {
        precondition(AppRuntimeEnvironment.isUnitTesting && !backgroundServicesEnabled)
        precondition(!noteReviewQueue.hasWork && translationWorker == nil)
        self.phase = phase
        self.segments = evidence
        self.learningNotebook = notebook
        self.latestLearningIDs = notebook.latestEvidenceIDs
        self.summarizedSegmentIDs = Set(notebook.batches.flatMap { $0.ids })
        self.lastSummarizedSegmentCount = summarizedSegmentIDs.count
        self.lectureSummary = notebook.markdown()
        self.latestSummaryUpdate = notebook.markdown(covering: latestLearningIDs)
        self.summaryStatus = notebook.batches.isEmpty ? "等待课堂内容" : "合成课堂 · 用于界面验收"
        self.sessionNotice = notice
        self.volatileEnglish = preview
        self.previewChinese = preview.isEmpty ? "" : "这段合成课堂用于检查字幕换行与阅读位置。"
        self.translationReady = true
        self.translationStatus = "合成课堂 · 未启动模型"
        self.audioInputStatus = "合成输入 · 未使用麦克风"
        self.speechStatus = "界面验收数据"
        self.elapsedSeconds = evidence.last?.endTime ?? 0
    }

    @discardableResult
    func resetTranslationSessionForTesting() -> Task<Void, Never>? {
        let old = translationWorker
        resetSessionStateForNewRun()
        return old
    }
    func receiveCaptionForTesting(_ text: String, start: TimeInterval, end: TimeInterval) {
        consume(.final(text: text, start: start, end: end, hints: []))
    }
    var translationTaskForTesting: Task<Void, Never>? { translationWorker }
    func receiveIdentifiedCaptionForTesting(_ segment: TranscriptSegment) {
        precondition(AppRuntimeEnvironment.isUnitTesting && !backgroundServicesEnabled)
        appendConfirmedCaption(segment, hints: [])
    }
    func reviseCaptionForTesting(id: UUID, english: String) {
        precondition(AppRuntimeEnvironment.isUnitTesting && !backgroundServicesEnabled)
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        let old = segments[index]
        let revised = TranscriptSegment(id: id, startTime: old.startTime, endTime: old.endTime,
                                        english: english, sessionID: old.sessionID,
                                        inputRevision: old.inputRevision)
        replaceExistingSegment(at: index, with: revised, reason: "测试确认原文修订")
    }
    var savedProcessingTaskForTesting: Task<Void, Never>? { processingTask }
    func generateSummaryForTesting() async {
        precondition(AppRuntimeEnvironment.isUnitTesting && !backgroundServicesEnabled)
        processingPaused = false
        await generateLectureSummary(force: true)
    }
    #endif

    /// A suspended request owns a caption version, never its position in the
    /// time-sorted array. The worker token also separates pause/resume runs.
    private func translationInputIndex(_ input: TranscriptSegment, session: UUID,
                                       epoch: Int, worker: UUID) -> Int? {
        guard !Task.isCancelled, !processingPaused, sessionID == session,
              generation == epoch, translationWorkerID == worker else { return nil }
        return segments.firstIndex {
            $0.id == input.id && $0.inputRevision == input.inputRevision && $0.english == input.english
        }
    }

    private func drainTranslationQueue() {
        guard !processingPaused, !manualRequestInFlight,
              (summaryTask == nil || summaryConcurrencyAllowed),
              translationWorker == nil, !translationQueue.isEmpty else { return }
        let currentGeneration = generation
        let currentSession = sessionID
        let workerID = UUID()
        translationWorkerID = workerID
        translationWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if currentGeneration == self.generation, self.translationWorkerID == workerID {
                    self.translatingSegmentID = nil
                    self.streamingChinese = ""
                    self.translationWorker = nil
                    self.translationWorkerID = nil
                }
            }
            while !self.translationQueue.isEmpty, !Task.isCancelled, !self.processingPaused,
                  currentGeneration == self.generation, currentSession == self.sessionID,
                  self.translationWorkerID == workerID {
                let id = self.translationQueue.removeFirst()
                guard let index = self.segments.firstIndex(where: { $0.id == id }) else {
                    self.translationEnqueuedAt.removeValue(forKey: id)
                    continue
                }
                let input = self.segments[index]
                defer {
                    if currentGeneration == self.generation, currentSession == self.sessionID,
                       self.translationWorkerID == workerID,
                       !self.translationQueue.contains(id) {
                        self.translationEnqueuedAt.removeValue(forKey: id)
                        self.updateReviewAvailability()
                    }
                }
                self.segments[index].beginTranslation()
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
                    let previousIndex = index > 0 && self.segments[index].startTime - self.segments[index - 1].endTime <= 2
                        && self.segments[index - 1].hasUsableTranslation ? index - 1 : nil
                    if let previousIndex {
                        let previousInput = self.segments[previousIndex]
                        let pair = try await self.captionTranslation.adjacent(
                            previousInput.english,
                            previousInput.chinese,
                            QwenTranslationClient.translationInput(text: normalizedInput, modelName: translationModel, hints: hints),
                            self.segments[..<previousIndex].suffix(2).map(\.english).joined(separator: " "),
                            translationModel,
                            previousInput.endTime - previousInput.startTime >= 9.5
                                || !".!?".contains(previousInput.english.last ?? " ")
                                || english.first?.isLowercase == true)
                        try Task.checkCancellation()
                        guard currentGeneration == self.generation, currentSession == self.sessionID,
                              self.translationWorkerID == workerID, !self.processingPaused else { return }
                        guard self.translationInputIndex(input, session: currentSession,
                                                         epoch: currentGeneration, worker: workerID) != nil else { continue }
                        guard let previousIndex = self.translationInputIndex(previousInput,
                                session: currentSession, epoch: currentGeneration, worker: workerID),
                              self.segments[previousIndex].chinese == previousInput.chinese else {
                            if let currentIndex = self.translationInputIndex(input, session: currentSession,
                                    epoch: currentGeneration, worker: workerID) {
                                self.segments[currentIndex].deferTranslation()
                                if !self.translationQueue.contains(id) { self.translationQueue.append(id) }
                            }
                            continue
                        }
                        // A repair that passed acceptance is stored even when the
                        // current sentence fails; a rejected repair never
                        // overwrites the Chinese line already on screen.
                        if let revised = pair.previous,
                           currentGeneration == self.generation,
                           self.segments.indices.contains(previousIndex) {
                            let normalized = SimplifiedChineseNormalizer.normalize(revised)
                            // 2026-09-18：相邻修复**一次处理两段** ✗，模型多回半句就会把两段内容
                            // 塞进前一段 ✗（缺陷文档 round-359 的收敛结论 ✓）。
                            // 因此：修复结果若相对**前一段自己的英文**长得离谱 ✗，就**丢弃这次修复** ✓
                            // —— 保留原有中文 ✓（等价于从未修复 ✓），只会更保守 ✓，不会改坏 ✓。
                            let repairPlausible = TranslationLengthGuard.isPlausible(
                                chinese: normalized,
                                english: self.segments[previousIndex].english)
                            if !repairPlausible {
                                Self.traceTranslation("adjacent_repair", id: self.segments[previousIndex].id,
                                                      elapsed: ProcessInfo.processInfo.systemUptime - started,
                                                      detail: "skipped_length_guard")
                            }
                            if repairPlausible, !normalized.isEmpty, self.segments[previousIndex].chinese != normalized {
                                let previousID = self.segments[previousIndex].id
                                var revisedSegment = self.segments[previousIndex]
                                revisedSegment.completeTranslation(normalized)
                                self.replaceExistingSegment(at: previousIndex, with: revisedSegment,
                                    reason: "相邻语句补全译文")
                                Self.traceTranslation("adjacent_repair", id: previousID,
                                                      elapsed: ProcessInfo.processInfo.systemUptime - started,
                                                      detail: "applied")
                            }
                        } else if let reason = pair.previousRejection {
                            Self.traceTranslation("adjacent_repair_kept", id: self.segments[previousIndex].id,
                                                  elapsed: ProcessInfo.processInfo.systemUptime - started,
                                                  detail: reason)
                        }
                        guard let acceptedCurrent = pair.current else {
                            let reason = pair.currentRejection ?? "未知原因"
                            Self.traceTranslation("rejected", id: id,
                                                  elapsed: ProcessInfo.processInfo.systemUptime - started,
                                                  detail: reason)
                            throw QwenRuntimeError.requestFailed("译文未通过验收（\(reason)），已保留英文行等待重试。")
                        }
                        response = acceptedCurrent
                    } else {
                    response = try await self.captionTranslation.translate(
                        protectedInput.text,
                        translationModel,
                        hints,
                         { [weak self] partial in
                            guard let self, !Task.isCancelled,
                                  self.translatingSegmentID == id,
                                  self.translationInputIndex(input, session: currentSession,
                                      epoch: currentGeneration, worker: workerID) != nil else { return }
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
                    // The restore step must not turn a technical answer into an
                    // English sentence after the model output was accepted.
                    _ = try TranslationAcceptance.validated(chinese, source: protectedInput.text)
                    guard currentGeneration == self.generation, currentSession == self.sessionID,
                          self.translationWorkerID == workerID, !self.processingPaused else { return }
                    guard self.translationInputIndex(input, session: currentSession,
                        epoch: currentGeneration, worker: workerID) != nil else { continue }
                    self.reviewConcurrency.observe(elapsed: ProcessInfo.processInfo.systemUptime - enqueued, successful: true)
                    // 2026-09-18：长度护栏（**只换不伤** ✓）。
                    // 全库实测约 1% 的段落中文里混进了邻居内容 ✗（音频与英文都正常、只有中文异常长 ✗）。
                    // 规则：原译文不可信 → 重试一次 → **只有重试结果可信才替换** ✓；否则保留原样 ✓。
                    var finalChinese = chinese
                    if !TranslationLengthGuard.isPlausible(chinese: chinese, english: protectedInput.text),
                       !Task.isCancelled, currentGeneration == self.generation,
                       let retry = try? await self.captionTranslation.translate(
                           protectedInput.text, translationModel, hints, nil) {
                        let restoredRetry = SimplifiedChineseNormalizer.normalize(protectedInput.restore(in: retry))
                        if let validatedRetry = try? TranslationAcceptance.validated(restoredRetry, source: protectedInput.text),
                           TranslationLengthGuard.isPlausible(chinese: validatedRetry, english: protectedInput.text) {
                            finalChinese = validatedRetry
                            Self.traceTranslation("length_guard_replaced", id: id,
                                                  elapsed: ProcessInfo.processInfo.systemUptime - started)
                        }
                    }
                    guard !Task.isCancelled, currentGeneration == self.generation,
                          currentSession == self.sessionID, self.translationWorkerID == workerID,
                          !self.processingPaused else { return }
                    guard let currentIndex = self.translationInputIndex(input, session: currentSession,
                        epoch: currentGeneration, worker: workerID) else { continue }
                    self.segments[currentIndex].completeTranslation(finalChinese)
                    self.liveChinese = finalChinese
                    Self.traceTranslation(previousIndex == nil ? "complete" : "complete_adjacent", id: id,
                                          elapsed: ProcessInfo.processInfo.systemUptime - started)
                } catch is CancellationError {
                    break
                } catch {
                    guard !Task.isCancelled, currentGeneration == self.generation,
                          currentSession == self.sessionID, self.translationWorkerID == workerID,
                          !self.processingPaused else { break }
                    guard self.translationInputIndex(input, session: currentSession,
                        epoch: currentGeneration, worker: workerID) != nil else { continue }
                    self.reviewConcurrency.observe(elapsed: 0, successful: false)
                    let reason = (error as? QwenRuntimeError).flatMap { runtime -> String? in
                        if case .requestFailed(let message) = runtime { return message }
                        return nil
                    } ?? error.localizedDescription
                    // 2026-09-18：失败先**重试一次**再写占位符。
                    // 起因：今天那节课第 209 段的字幕里出现了 [翻译失败：Final output budget exhausted…] ✗，
                    // 而用同一素材复跑同一段却成功 ✓ → 属**间歇性**失败 ✓，重试一次的成本很低（约 1 秒）✓。
                    var recovered: String?
                    if !Task.isCancelled, currentGeneration == self.generation {
                        // 注意：必须和主路径一致 —— 传**受保护的**文本 ✓ 并在之后 restore ✓，
                        // 否则重试会绕过化学/公式保护层 ✗（这一点是我自审时发现的 ✓）。
                        recovered = try? await self.captionTranslation.translate(
                            protectedInput.text, translationModel, hints, nil)
                    }
                    guard !Task.isCancelled, currentGeneration == self.generation,
                          currentSession == self.sessionID, self.translationWorkerID == workerID,
                          !self.processingPaused else { return }
                    guard let currentIndex = self.translationInputIndex(input, session: currentSession,
                        epoch: currentGeneration, worker: workerID) else { continue }
                    var accepted: String?
                    if let recovered {
                        let restored = SimplifiedChineseNormalizer.normalize(protectedInput.restore(in: recovered))
                        if let validated = try? TranslationAcceptance.validated(restored, source: protectedInput.text),
                           !validated.isEmpty {
                            accepted = validated
                        }
                    }
                    if let accepted {
                        Self.traceTranslation("complete_after_retry", id: id,
                                              elapsed: ProcessInfo.processInfo.systemUptime - started,
                                              detail: reason)
                        self.segments[currentIndex].completeTranslation(accepted)
                        self.liveChinese = accepted
                    } else {
                        Self.traceTranslation("failed", id: id,
                                              elapsed: ProcessInfo.processInfo.systemUptime - started,
                                              detail: reason)
                        self.segments[currentIndex].failTranslation(reason)
                        self.liveChinese = self.segments[currentIndex].displayChinese
                    }
                }
                guard !Task.isCancelled, currentGeneration == self.generation else { return }
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
        guard backgroundServicesEnabled else { return }
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

    private static func traceTranslation(_ event: String, id: UUID, elapsed: TimeInterval,
                                         detail: String? = nil) {
        let milliseconds = Int(max(0, elapsed) * 1_000)
        // Runtime errors can embed source text or paths. Details remain in the
        // UI state; ordinary logging records only their presence.
        latencyLog.notice("caption event=\(event, privacy: .public) id=\(id.uuidString, privacy: .public) elapsed_ms=\(milliseconds) has_diagnostic=\(detail != nil)")
    }

    private static func previewMilliseconds(_ value: TimeInterval) -> Int {
        Int(max(0, value) * 1_000)
    }

    /// 初译请求完成（成功）时的排队/执行时序。只记数字与字符数，不记正文。
    private static func tracePreview(_ event: String, characters: Int,
                                     timing: PreviewTranslationRunner.Timing) {
        let first = timing.firstSourceToResult.map {
            " first_source_to_result_ms=\(previewMilliseconds($0))"
        } ?? ""
        // queue_ms = 从源文本最近一次变化到请求开始（真实排队）；
        // scheduler_delay_ms = 其中调度器自己（限频/在途合并）造成的那部分。
        previewLog.notice("preview event=\(event, privacy: .public) chars=\(characters, privacy: .public) queue_ms=\(previewMilliseconds(timing.queue), privacy: .public) scheduler_delay_ms=\(previewMilliseconds(timing.schedulerDelay), privacy: .public) execute_ms=\(previewMilliseconds(timing.execute), privacy: .public)\(first, privacy: .public)")
    }

    private static func tracePreviewFailure(timing: PreviewTranslationRunner.Timing,
                                            backoff: TimeInterval, failures: Int) {
        previewLog.notice("preview event=failed execute_ms=\(previewMilliseconds(timing.execute), privacy: .public) failures=\(failures, privacy: .public) backoff_ms=\(previewMilliseconds(backoff), privacy: .public)")
    }

    /// 流水线发出预览事件 → AppModel 在主线程收到它的排队耗时。
    /// 识别结果很密集，所以按 1 秒窗口聚合，只保留最差/最后一次。
    private func tracePreviewReceiveHop(_ hop: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        if previewHopCount == 0 || now - previewHopWindowStarted > 5 {
            previewHopWindowStarted = now
        }
        previewHopCount += 1
        previewHopWorst = max(previewHopWorst, hop)
        let window = now - previewHopWindowStarted
        guard window >= 1 else { return }
        Self.previewLog.notice("preview event=main_hop window_ms=\(Self.previewMilliseconds(window), privacy: .public) events=\(self.previewHopCount, privacy: .public) worst_ms=\(Self.previewMilliseconds(self.previewHopWorst), privacy: .public) last_ms=\(Self.previewMilliseconds(hop), privacy: .public)")
        previewHopCount = 0
        previewHopWorst = 0
    }

    private func scheduleSummaryRefresh(force: Bool = false) {
        let savedCanContinue: Bool
        if case .saved = phase { savedCanContinue = processingTask == nil && !legacyProvenanceUnavailable }
        else { savedCanContinue = false }
        guard backgroundServicesEnabled, hasActiveSession || savedCanContinue, !processingPaused else { return }
        guard summaryTask == nil else {
            if force { summaryRefreshRequested = true }
            return
        }
        let admission = ResourceSchedulingPolicy.decide(.summary, in: resourceContext(
            summaryRunning: false, continuingSummary: force || savedCanContinue || summaryCycleIDs != nil))
        // The interval is implemented by the wake-up timer below. Every other
        // refusal applies to all new model requests, including saved courses.
        if !admission.allowed && admission.reason != .interval {
            summaryStatus = admission.reason.description
            recordResourceDecision(admission.reason)
            if force { summaryRefreshRequested = true }
            return
        }
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
        guard !processingPaused, !Task.isCancelled, completedTranslationCount >= 2 else { return }
        let summaryOwner = summaryTaskGeneration
        let summarySession = sessionID
        let eligible = Set(segments.filter {
            !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.hasUsableTranslation
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
        while !Task.isCancelled, !processingPaused, currentGeneration == generation,
              summaryOwner == summaryTaskGeneration, summarySession == sessionID {
            // Gate the start of each bounded request. This also covers forced
            // stop/export and saved-course drains, which have no live timer.
            // An already generating request keeps its slot until it finishes.
            if backgroundServicesEnabled {
                if runtimeResources == nil { await refreshRuntimeResources()?.value }
                guard !Task.isCancelled, !processingPaused, currentGeneration == generation,
                      summaryOwner == summaryTaskGeneration, summarySession == sessionID else { return }
                let admission = ResourceSchedulingPolicy.decide(.summary, in: resourceContext(
                    summaryRunning: false, continuingSummary: true))
                guard admission.allowed else {
                    summaryStatus = admission.reason.description
                    summaryRefreshRequested = true
                    recordResourceDecision(admission.reason)
                    return
                }
            }
            let boundary = summaryCycleIDs ?? []
            let reusableDraft = learningDraft.flatMap { draft -> LearningDraft? in
                let ids = Set(draft.evidence.map(\.id))
                guard ids.isDisjoint(with: summarizedSegmentIDs),
                      draft.matches(evidence: segments.filter { ids.contains($0.id) }, model: modelName),
                      sessionSnapshot.map({ draft.matches(snapshot: $0, model: modelName) }) ?? true else { return nil }
                return draft
            }
            let batchIDs = reusableDraft.map { Set($0.evidence.map(\.id)) }
                ?? LectureSummaryInput.incremental(
                    from: segments.filter { boundary.contains($0.id) },
                    coveredIDs: summarizedSegmentIDs, previousSummary: "",
                    maximumCharacters: noteBatchCharacters).segmentIDs
            guard !batchIDs.isEmpty else {
                summaryCycleIDs = nil
                summaryRetryNotBefore = nil
                return
            }
            let inputSnapshot = segments.filter { batchIDs.contains($0.id) }
            do {
                if reusableDraft == nil {
                    let pending = learningNotebook.selectPendingPoints(for: inputSnapshot)
                    var dependencies = inputSnapshot.map(\.id)
                    for id in pending.flatMap(\.dependencyIDs) where !dependencies.contains(id) { dependencies.append(id) }
                    learningDraft = LearningDraft(
                        evidence: inputSnapshot, model: modelName,
                        input: try LearningPrompts.input(evidence: inputSnapshot, topics: learningNotebook.topics, pending: pending),
                        pendingTargets: pending.map(\.id), contextRevision: learningNotebook.revision,
                        dependencyIDs: dependencies
                    )
                    learningDraft?.freezeBinding(sessionID: sessionID, inputRevision: sessionSnapshot?.inputRevision ?? 0,
                                                 generation: generation)
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
                    let response = try await learningGeneration.generate(
                        draft.input, modelName, draft.text,
                        { [weak self] text in
                        guard let self, !Task.isCancelled, !self.processingPaused,
                              self.generation == currentGeneration, self.sessionID == summarySession,
                              self.summaryTaskGeneration == summaryOwner,
                              self.learningDraft?.id == draft.id,
                              inputSnapshot == self.segments.filter({ batchIDs.contains($0.id) }),
                              self.sessionSnapshot.map({ draft.matches(snapshot: $0, model: modelName) }) ?? true else { return }
                        self.learningDraft?.text = text
                    })
                    guard !Task.isCancelled, !processingPaused, currentGeneration == generation,
                          sessionID == summarySession, summaryTaskGeneration == summaryOwner else { return }
                    note = try LearningNote.decode(response)
                    if learningDraft?.id == draft.id { learningDraft?.completedNote = note }
                }
                guard !Task.isCancelled, !processingPaused, currentGeneration == generation,
                      sessionID == summarySession, summaryTaskGeneration == summaryOwner else { return }
                guard learningDraft?.id == draft.id else { return }
                guard inputSnapshot == segments.filter({ batchIDs.contains($0.id) }),
                      sessionSnapshot.map({ draft.matches(snapshot: $0, model: modelName) }) ?? true else {
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
                summarizedSegmentIDs.formUnion(batchIDs)
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
                guard !Task.isCancelled, !processingPaused, currentGeneration == generation,
                      sessionID == summarySession, summaryTaskGeneration == summaryOwner else { return }
                // A broken process/timeout can resume its journal; an invalid
                // finished output must not become an endless JSON continuation.
                if (error as? QwenRuntimeError)?.preservesGenerationProgress != true { learningDraft = nil }
                consecutiveSummaryFailures += 1
                let retry = SummaryRefreshPolicy.failureRetryDelay(consecutiveFailures: consecutiveSummaryFailures)
                summaryRetryNotBefore = ProcessInfo.processInfo.systemUptime + retry
                Self.latencyLog.notice("summary event=failed retry_seconds=\(retry) failures=\(self.consecutiveSummaryFailures)")
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
        let liveWorkPending = translationWorker != nil || !translationQueue.isEmpty
            || summaryTask != nil || manualRequestInFlight || isManualTranslating
        let decision = ProcessingFocusPolicy.decision(ProcessingFocusPolicy.Context(
            focusMode: processingFocusEnabled,
            recording: recording,
            memoryNormal: summaryMemoryPressureNormal,
            hasCaptionBacklog: hasCaptionBacklog,
            liveWorkPending: liveWorkPending,
            availableBytes: available,
            latencyAllowsConcurrency: capable
        ))
        var reviewContext = resourceContext(summaryRunning: false, continuingSummary: false,
                                            allowConcurrent: capable)
        // Review has its own manual pause state, independent of saved ASR work.
        // The review queue applies that state; this gate only describes resources.
        reviewContext.paused = false
        reviewContext.continuingRequestID = noteReviewQueue.activeRuntimeRequestID
        let admission = ResourceSchedulingPolicy.decide(.review, in: reviewContext)
        noteReviewQueue.setContext(
            recording: recording,
            concurrent: decision.allowConcurrentReview,
            resourcesAvailable: decision.resourcesAvailable && (!backgroundServicesEnabled || admission.allowed)
        )
    }

    private func resourceContext(summaryRunning: Bool, continuingSummary: Bool,
                                 allowConcurrent: Bool? = nil) -> ResourceSchedulingPolicy.Context {
        .init(now: ProcessInfo.processInfo.systemUptime, memoryNormal: summaryMemoryPressureNormal,
            captionBacklog: hasCaptionBacklog, captionPending: translationWorker != nil || !translationQueue.isEmpty,
            recording: hasActiveSession || phase == .preparing || phase == .stopping,
            allowConcurrent: allowConcurrent ?? summaryConcurrencyAllowed, summaryRunning: summaryRunning,
            paused: processingPaused, lastSummaryStarted: lastSummaryCycleStartedUptime,
            continuingSummary: continuingSummary, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            resources: runtimeResources)
    }

    private func recordResourceDecision(_ reason: ResourceSchedulingPolicy.Reason) {
        guard reason != lastResourceDecision else { return }
        lastResourceDecision = reason
        Self.latencyLog.notice("scheduler reason=\(reason.rawValue, privacy: .public)")
    }

    @discardableResult
    private func refreshRuntimeResources() -> Task<Void, Never>? {
        guard backgroundServicesEnabled else { return nil }
        if let resourceRefreshTask { return resourceRefreshTask }
        let task = Task { @MainActor [weak self] in
            async let asr = QwenASRClient.resourceState()
            async let language = MLXRuntime.shared.resourceStates()
            let snapshot = await RuntimeResourceSnapshot(asr: asr, languageWorkers: language)
            guard let self else { return }
            self.runtimeResources = snapshot
            self.updateReviewAvailability()
            self.scheduleSummaryRefresh(force: self.summaryRefreshRequested)
            self.resourceRefreshTask = nil
        }
        resourceRefreshTask = task
        return task
    }

    /// Never implied by the focus switch: the idle-sleep assertion exists only
    /// when the user enabled it and a recording session is actually running.
    private func applyIdleSleepAssertion() {
        let shouldHold = preventIdleSleepWhileRecording && phase.isBusy
        if shouldHold, idleSleepActivity == nil {
            idleSleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
                reason: "LiveLingo 正在录音"
            )
        } else if !shouldHold, let activity = idleSleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            idleSleepActivity = nil
        }
    }

    private var completedTranslationCount: Int {
        segments.filter {
            $0.hasUsableTranslation
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
        let memoryLimited = resourcePressure || !summaryMemoryPressureNormal
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
        refreshRuntimeResources()
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
        guard phase == .recording || phase == .paused || phase == .preparing || phase == .stopping else {
            archiveError = "处理错误：\(message)"
            return
        }
        await stopSession(failure: message)
    }

    private func finalizeSessionDirectoryIfNeeded() async throws -> URL {
        if let temporarySessionDirectory {
            guard let outputDirectory else { throw AppError.outputDirectoryMissing }
            try await pipeline.pauseTranscription()
            let translation = translationWorker
            translation?.cancel()
            let summary = summaryTask
            cancelSummaryTask()
            await translation?.value
            await summary?.value
            try await flushSessionArchive()
            let preferredName = Self.sessionFolderName()
            let identity = sessionID, epoch = generation
            let migration = try await noteReviewQueue.withCourseWritersPaused(sessionID: identity,
                directory: temporarySessionDirectory) {
                let copied = try await Task.detached {
                    try SessionWorkspace.copyTemporarySession(from: temporarySessionDirectory,
                        to: outputDirectory, preferredName: preferredName)
                }.value
                try noteReviewQueue.relocatePausedCourse(sessionID: identity,
                    from: temporarySessionDirectory, to: copied.destinationDirectory)
                do { return try await Task.detached { try SessionTreeMigration.retireVerifiedCopy(copied) }.value }
                catch {
                    try noteReviewQueue.relocatePausedCourse(sessionID: identity,
                        from: copied.destinationDirectory, to: temporarySessionDirectory)
                    throw error
                }
            }
            let finalDirectory = migration.destinationDirectory
            if let preserved = migration.preservedSourceDirectory {
                do {
                    let data = try JSONSerialization.data(withJSONObject: ["source": preserved.path,
                        "destination": finalDirectory.path], options: [.sortedKeys])
                    try data.write(to: finalDirectory.appendingPathComponent("migration-recovery.json"), options: .atomic)
                } catch { archiveNotice = "课程已迁移；原件保留于 \(preserved.path)，恢复位置记录未能保存。" }
            }
            guard let saved = try await Task.detached(operation: {
                try SessionStore(directory: finalDirectory).load()
            }).value else {
                throw SessionStoreError.missingSnapshot
            }
            sessionSaver = nil
            self.temporarySessionDirectory = nil
            sessionDirectory = finalDirectory
            bindSessionArchive(to: finalDirectory, restored: saved)
            try await pipeline.restoreTranscription(directory: finalDirectory, sessionID: identity) { [weak self] event in
                Task { @MainActor in
                    guard let self, self.sessionID == identity, self.generation == epoch else { return }
                    self.consume(event)
                }
            }
            try pipeline.resumeTranscription()
            return finalDirectory
        }
        guard let sessionDirectory else { throw AppError.sessionDirectoryMissing }
        return sessionDirectory
    }

    /// 录音**因设备/运行时错误停止**时给用户看的提示（纯函数 ✓，可单测 ✓）。
    ///
    /// 为什么要抽出来 ✓：这段文案在 round-365 被**特意改过** ✗→✓ ——
    /// 原文只写"已自动保存当前录音和 N 段字幕" ✗，用户读到"已保存"就以为没事 ✓，
    /// 而事实是**后面的内容再也不会被录** ✗（09-17 物理那节就这样丢了近六成 ✗）。
    /// 抽成纯函数后，这条**顺序要求**（先说后果、再说已保存 ✓）能被测试锁住 ✓。
    static func recordingStoppedNotice(message: String, segmentCount: Int) -> String {
        "⚠️ 录音已停止，**后面的内容不会再录**：\(message) 已自动保存当前录音和 \(segmentCount) 段字幕；要继续录制请重新点开始（会新建一次会话）。"
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
    private static let focusModeDefaultsKey = "LiveLingo.processingFocus"
    private static let noteBatchDefaultsKey = "LiveLingo.noteBatchCharacters"
    private static let preventIdleSleepDefaultsKey = "LiveLingo.preventIdleSleepWhileRecording"
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
                paced: Bool = true, exportNotes: Bool = false, runReview: Bool = false,
                report: @escaping @MainActor (String, [String: Any]) -> Void) async throws {
        resetSessionStateForNewRun()
        effectiveProfile = highQuality ? .highQuality : .energySaver
        pipeline.update(profile: effectiveProfile)
        activeStorageMode = .saveSession
        activeInputMode = .systemAudio
        sessionDirectory = directory
        outputDirectory = directory
        bindSessionArchive(to: directory)
        try await flushSessionArchive()
        let identity = sessionID, epoch = generation
        try await pipeline.prepareModel(profile: effectiveProfile) { message in
            Task { @MainActor in report("prepare", ["message": message]) }
        }
        phase = .recording
        let poll = Task { @MainActor in
            while !Task.isCancelled, self.sessionID == identity, self.generation == epoch {
                report("state", ["phase": self.phaseLabel, "sessionID": identity.uuidString,
                    "segments": self.segments.count, "translated": self.completedTranslationCount,
                    "summarized": self.lastSummarizedSegmentCount,
                    "summaryRunning": self.summaryTask != nil, "concurrency": self.summaryConcurrencyAllowed,
                    "pendingTranscription": self.transcriptionProcessing?.pendingCount ?? 0,
                    "unresolvedTranscription": self.transcriptionProcessing?.unresolvedCount ?? 0,
                    "summaryStatus": self.summaryStatus])
                self.refreshSummaryConcurrency()
                self.yieldSummaryToCaptions()
                self.scheduleSummaryRefresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        let preview = Task { @MainActor in
            if #available(macOS 26.0, *) {
                let session = TranslationSession(installedSource: Locale.Language(identifier: "en"),
                    target: Locale.Language(identifier: "zh-Hans"))
                await self.runPreviewTranslation(session: session)
            }
        }
        defer { poll.cancel(); preview.cancel() }
        do {
            let sink: @Sendable (SpeechPipeline.Event) -> Void = { [weak self] event in
                Task { @MainActor in
                    guard let self, self.generation == epoch, self.sessionID == identity else { return }
                    self.consume(event)
                }
            }
            let recording = directory.appendingPathComponent(SessionWorkspace.recordingFileName)
            if let file {
                report("capture", ["kind": paced ? "silent-pcm-replay" : "file-import", "file": file.path])
                if paced {
                    try await pipeline.cliReplay(file: file, recordingURL: recording,
                        sessionID: identity, eventHandler: sink)
                } else {
                    try await pipeline.importMediaFile(file, recordingURL: recording,
                        sessionID: identity, persistsSession: true, eventHandler: sink)
                }
            } else {
                report("capture", ["kind": "system-audio", "seconds": seconds])
                try await pipeline.start(inputMode: .systemAudio, recordingURL: recording,
                    sessionID: identity, persistsSession: true, eventHandler: sink)
                report("capture_ready", ["kind": "system-audio"])
                try await Task.sleep(for: .seconds(seconds))
            }
            guard phase == .recording else {
                throw QwenRuntimeError.requestFailed("CLI capture stopped: " + phaseLabel)
            }
            stopOverlapStarted = false
            let started = ProcessInfo.processInfo.systemUptime
            await stopSession()
            await processingTask?.value
            guard case .saved = phase else { throw QwenRuntimeError.requestFailed(phaseLabel) }
            if let archiveError { throw QwenRuntimeError.requestFailed(archiveError) }

            // Resource pressure can defer the final batch. Continue through the
            // same admission/timer entry as the saved-course UI, then verify it.
            let summaryDeadline = ProcessInfo.processInfo.systemUptime + 1_800
            while completedTranslationCount >= 2 && lastSummarizedSegmentCount < completedTranslationCount {
                try Task.checkCancellation()
                if consecutiveSummaryFailures > 0 {
                    throw QwenRuntimeError.requestFailed("CLI notes generation failed: " + summaryStatus)
                }
                guard ProcessInfo.processInfo.systemUptime < summaryDeadline else {
                    throw QwenRuntimeError.requestFailed("CLI notes timed out; saved progress is retained")
                }
                await refreshRuntimeResources()?.value
                scheduleSummaryRefresh(force: true)
                if let summaryTask { await summaryTask.value }
                else { try await Task.sleep(for: .milliseconds(250)) }
            }
            try await flushSessionArchive()
            try SessionExporter.export(segments: segments, sessionDirectory: directory, summary: lectureSummary)

            if runReview {
                try noteReviewQueue.enqueue(directory: directory, notebook: learningNotebook,
                    scope: .wholeLesson, sessionID: identity, inputRevision: sessionSnapshot?.inputRevision)
                if let failure = noteReviewQueue.currentFailure { throw QwenRuntimeError.requestFailed(failure) }
                if noteReviewQueue.hasWork {
                    noteReviewQueue.startAwaitingJob()
                    report("review_start", ["jobs": noteReviewQueue.items.count, "sessionID": identity.uuidString])
                    let deadline = ProcessInfo.processInfo.systemUptime + 1_800
                    while noteReviewQueue.hasWork || noteReviewQueue.running {
                        try Task.checkCancellation()
                        if let failure = noteReviewQueue.currentFailure {
                            throw QwenRuntimeError.requestFailed("CLI review failed: " + failure)
                        }
                        guard ProcessInfo.processInfo.systemUptime < deadline else {
                            throw QwenRuntimeError.requestFailed("CLI review timed out; saved progress is retained")
                        }
                        await refreshRuntimeResources()?.value
                        try await Task.sleep(for: .milliseconds(250))
                    }
                    if let failure = noteReviewQueue.currentFailure { throw QwenRuntimeError.requestFailed(failure) }
                    guard let reportText = try ReviewExportSource.markdown(for: directory, queue: noteReviewQueue),
                          !reportText.isEmpty else {
                        throw QwenRuntimeError.requestFailed("CLI review ended without a readable report")
                    }
                    report("review_done", ["bytes": reportText.utf8.count, "sessionID": identity.uuidString])
                } else {
                    report("review_skipped", ["reason": "没有可复查的已完成笔记批次"])
                }
            }
            // Export after requested review completion. Read/format/write errors
            // fail this run; an old report or partial file cannot imply success.
            if exportNotes {
                exportScope = .wholeLesson
                exportIncludesTranscript = true
                exportIncludesReviewAdvice = true
                guard let snapshot = notesExportSnapshot() else {
                    throw QwenRuntimeError.requestFailed(exportStatus ?? "笔记快照无法导出")
                }
                for format in NotesExportFormat.allCases {
                    let url = directory.appendingPathComponent(NotesExportDocument.defaultFileName(snapshot, format: format))
                    try NotesExportDocument.write(snapshot, format: format, to: url)
                    let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
                    guard let bytes, bytes.intValue > 0 else { throw QwenRuntimeError.invalidResponse }
                    report("exported", ["format": format.rawValue, "name": url.lastPathComponent, "bytes": bytes.intValue])
                }
            }
            try await flushSessionArchive()
            report("finished", ["phase": phaseLabel, "sessionID": identity.uuidString,
                "stopSeconds": ProcessInfo.processInfo.systemUptime - started, "segments": segments.count,
                "translated": completedTranslationCount, "summarized": lastSummarizedSegmentCount,
                "unresolvedTranscription": transcriptionProcessing?.unresolvedCount ?? 0,
                "summaryStatus": summaryStatus])
        } catch {
            poll.cancel(); preview.cancel()
            await pipeline.cancel()
            let translation = translationWorker
            translation?.cancel()
            let pending = summaryTask
            cancelSummaryTask()
            await translation?.value
            await pending?.value
            await noteReviewQueue.pauseAndWait()
            do { try await flushSessionArchive() }
            catch { report("save_failed", ["error": error.localizedDescription]) }
            throw error
        }
    }

    /// Explicit reopen/resume of a course this CLI isolated and bound. Reopening
    /// never records and never resumes on its own; `resume` is the only path that
    /// continues saved work, and review still needs an explicit `runReview`.
    /// Returns observed facts so the CLI, not the model, decides PASS.
    func cliOpenSaved(directory: URL, resume: Bool, highQuality: Bool, exportNotes: Bool, runReview: Bool,
                      report: @escaping @MainActor (String, [String: Any]) -> Void) async throws -> LiveLingoCLI.CLIObservedSession {
        effectiveProfile = highQuality ? .highQuality : .energySaver
        pipeline.update(profile: effectiveProfile)
        activeStorageMode = .saveSession
        activeInputMode = .systemAudio
        var exported: [URL] = []
        do {
            try await openSavedSession(directory, allowAutomaticProcessing: false)
            // openSavedSession reports a busy phase by returning silently.
            guard case .saved(let opened) = phase,
                  SessionDirectoryLocation.canonical(opened) == SessionDirectoryLocation.canonical(directory),
                  sessionSaver != nil, !legacyProvenanceUnavailable else {
                throw QwenRuntimeError.requestFailed("CLI reopen did not restore the bound saved course")
            }
            // Reopening parks immediately: this CLI never captures a saved course.
            if resume || sessionSnapshot?.processing.phase != .completed {
                try await parkSavedProcessing()
            }
            guard !isRecording, !isPaused else {
                throw QwenRuntimeError.requestFailed("CLI reopen left capture active")
            }
            try await flushSessionArchive()
            let identity = sessionID
            let epoch = generation
            report("opened", ["sessionID": identity.uuidString, "segments": segments.count,
                              "translated": completedTranslationCount,
                              "summarized": lastSummarizedSegmentCount,
                              "revision": sessionSnapshot?.inputRevision ?? 0,
                              "batches": learningNotebook.batches.count,
                              "paused": processingPaused, "capture": isRecording])
            if resume {
                let deadline = ProcessInfo.processInfo.systemUptime + 5_400
                // A resumed course needs the same periodic resource refresh a live
                // run gets, otherwise summary admission would stay blocked on a
                // stale memory-pressure flag and never start the notes work.
                let poll = Task { @MainActor [self] in
                    while !Task.isCancelled, sessionID == identity, generation == epoch {
                        refreshSummaryConcurrency()
                        yieldSummaryToCaptions()
                        scheduleSummaryRefresh()
                        report("state", ["phase": phaseLabel, "sessionID": identity.uuidString,
                                         "segments": segments.count, "translated": completedTranslationCount,
                                         "summarized": lastSummarizedSegmentCount,
                                         "summaryRunning": summaryTask != nil,
                                         "concurrency": summaryConcurrencyAllowed,
                                         "pendingTranscription": transcriptionProcessing?.pendingCount ?? 0,
                                         "unresolvedTranscription": transcriptionProcessing?.unresolvedCount ?? 0])
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    }
                }
                defer { poll.cancel() }
                resumeSavedProcessing()
                // The explicit resume runs inside its own task; its first durable
                // effect is leaving the parked state.
                while processingPaused, sessionID == identity, generation == epoch {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw QwenRuntimeError.requestFailed("CLI resume did not start; saved progress is retained")
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard sessionID == identity, generation == epoch else {
                    throw QwenRuntimeError.requestFailed("CLI resume changed the session identity")
                }
                report("resumed", ["sessionID": identity.uuidString, "segments": segments.count])
                while sessionID == identity, generation == epoch, cliSavedWorkPending {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw QwenRuntimeError.requestFailed("CLI resume timed out; saved progress is retained")
                    }
                    if let summaryTask { await summaryTask.value }
                    else { try await Task.sleep(for: .milliseconds(50)) }
                }
                guard sessionID == identity, generation == epoch else {
                    throw QwenRuntimeError.requestFailed("CLI resume changed the session identity")
                }
                // Same bounded, admission-gated notes completion as a live run,
                // plus an explicit stall guard: a blocked admission must fail the
                // run instead of quietly waiting out the whole deadline.
                let summaryDeadline = ProcessInfo.processInfo.systemUptime + 1_800
                var blockedReason: String?
                var blockedSince: TimeInterval?
                while completedTranslationCount >= 2 && lastSummarizedSegmentCount < completedTranslationCount {
                    try Task.checkCancellation()
                    if consecutiveSummaryFailures > 0 {
                        throw QwenRuntimeError.requestFailed("CLI notes generation failed: " + summaryStatus)
                    }
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now < summaryDeadline else {
                        throw QwenRuntimeError.requestFailed("CLI notes timed out; saved progress is retained")
                    }
                    if let decision = lastResourceDecision, decision != .available, decision != .finishSummary,
                       summaryTask == nil, translationWorker == nil, translationQueue.isEmpty {
                        if blockedReason != decision.rawValue {
                            blockedReason = decision.rawValue
                            blockedSince = now
                        } else if let since = blockedSince, now - since > 180 {
                            throw QwenRuntimeError.requestFailed("CLI notes blocked: " + decision.rawValue)
                        }
                    } else {
                        blockedReason = nil
                        blockedSince = nil
                    }
                    await refreshRuntimeResources()?.value
                    scheduleSummaryRefresh(force: true)
                    if let summaryTask { await summaryTask.value }
                    else { try await Task.sleep(for: .milliseconds(250)) }
                }
                try await flushSessionArchive()
                try SessionExporter.export(segments: segments, sessionDirectory: directory, summary: lectureSummary)
                if runReview {
                    try noteReviewQueue.enqueue(directory: directory, notebook: learningNotebook,
                        scope: .wholeLesson, sessionID: identity, inputRevision: sessionSnapshot?.inputRevision)
                    if let failure = noteReviewQueue.currentFailure { throw QwenRuntimeError.requestFailed(failure) }
                    if noteReviewQueue.hasWork {
                        noteReviewQueue.startAwaitingJob()
                        report("review_start", ["jobs": noteReviewQueue.items.count, "sessionID": identity.uuidString])
                        let reviewDeadline = ProcessInfo.processInfo.systemUptime + 1_800
                        while noteReviewQueue.hasWork || noteReviewQueue.running {
                            try Task.checkCancellation()
                            if let failure = noteReviewQueue.currentFailure {
                                throw QwenRuntimeError.requestFailed("CLI review failed: " + failure)
                            }
                            guard ProcessInfo.processInfo.systemUptime < reviewDeadline else {
                                throw QwenRuntimeError.requestFailed("CLI review timed out; saved progress is retained")
                            }
                            await refreshRuntimeResources()?.value
                            try await Task.sleep(for: .milliseconds(250))
                        }
                        if let failure = noteReviewQueue.currentFailure { throw QwenRuntimeError.requestFailed(failure) }
                        guard let reportText = try ReviewExportSource.markdown(for: directory, queue: noteReviewQueue),
                              !reportText.isEmpty else {
                            throw QwenRuntimeError.requestFailed("CLI review ended without a readable report")
                        }
                        report("review_done", ["bytes": reportText.utf8.count, "sessionID": identity.uuidString])
                    } else {
                        report("review_skipped", ["reason": "没有可复查的已完成笔记批次"])
                    }
                }
                if exportNotes {
                    exportScope = .wholeLesson
                    exportIncludesTranscript = true
                    exportIncludesReviewAdvice = true
                    guard let snapshot = notesExportSnapshot() else {
                        throw QwenRuntimeError.requestFailed(exportStatus ?? "笔记快照无法导出")
                    }
                    for format in NotesExportFormat.allCases {
                        let url = directory.appendingPathComponent(NotesExportDocument.defaultFileName(snapshot, format: format))
                        try NotesExportDocument.write(snapshot, format: format, to: url)
                        let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
                        guard let bytes, bytes.intValue > 0 else { throw QwenRuntimeError.invalidResponse }
                        exported.append(url)
                        report("exported", ["format": format.rawValue, "name": url.lastPathComponent,
                                            "bytes": bytes.intValue])
                    }
                }
                try await flushSessionArchive()
                guard sessionID == identity, generation == epoch else {
                    throw QwenRuntimeError.requestFailed("CLI resume changed the session identity")
                }
            }
            let store = SessionStore(directory: directory)
            let loaded = try await Task.detached { try store.loadDetailed() }.value
            guard let disk = loaded.snapshot else { throw SessionStoreError.missingSnapshot }
            let audio = try AVAudioFile(forReading: directory.appendingPathComponent(SessionWorkspace.recordingFileName))
            report("finished", ["phase": phaseLabel, "sessionID": sessionID.uuidString, "segments": segments.count,
                                "translated": completedTranslationCount, "summarized": lastSummarizedSegmentCount,
                                "revision": disk.inputRevision, "batches": disk.batches.count,
                                "paused": processingPaused, "capture": isRecording])
            return LiveLingoCLI.CLIObservedSession(
                sessionID: sessionID,
                snapshot: disk,
                notes: lectureSummary,
                processingPaused: processingPaused,
                captureActive: isRecording || isPaused || (transcriptionProcessing?.isCapturing ?? false),
                transcription: transcriptionProcessing,
                candidates: transcriptionCandidates.count
                    + pipeline.transcriptionWork().filter { $0.candidateText != nil }.count,
                reviewHasWork: noteReviewQueue.hasWork,
                reviewRunning: noteReviewQueue.running,
                reviewFailure: noteReviewQueue.currentFailure,
                summarizedCount: lastSummarizedSegmentCount,
                translatedCount: completedTranslationCount,
                pendingWorkers: (processingTask != nil ? 1 : 0) + (translationWorker != nil ? 1 : 0)
                    + (summaryTask != nil ? 1 : 0) + translationQueue.count,
                archiveErrorPresent: archiveError != nil,
                journalIncompleteTailBytes: loaded.incompleteTailBytes,
                exportPaths: exported.map(\.path),
                exports: [],
                audioFrames: Int(audio.length),
                audioSampleRate: audio.processingFormat.sampleRate)
        } catch {
            // An interrupted or failed reopen keeps resumable state: stop owned
            // work, persist the parked state and let the caller report failure.
            try? await parkSavedProcessing()
            await noteReviewQueue.pauseAndWait()
            try? await flushSessionArchive()
            throw error
        }
    }

    private var cliSavedWorkPending: Bool {
        processingTask != nil || translationWorker != nil || summaryTask != nil
            || !translationQueue.isEmpty
            || (transcriptionProcessing?.pendingCount ?? 0) > 0
            || (transcriptionProcessing?.activeCount ?? 0) > 0
            || (transcriptionProcessing?.unresolvedCount ?? 0) > 0
    }
}
#endif
