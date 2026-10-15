import AVFoundation
import CoreMedia
import Foundation
import SoundAnalysis

/// One place for the sensitivity, reminder and automatic-save constants.
enum AlarmPolicy {
    static let windowSeconds: TimeInterval = 3
    static let overlap = 0.5
    static let historySeconds: TimeInterval = 12
    static let confidenceThreshold = 0.5
    static let requiredWindows = 3
    static let minimumHitSpan: TimeInterval = 6
    static let cooldownSeconds: TimeInterval = 180
    static let countdownSeconds = 30
    static let postAlarmFolderSuffix = " · 警报后"
    static let breathingPeriod: TimeInterval = 2.4
    static let labels: Set<String> = [
        "smoke_detector", "siren", "civil_defense_siren", "fire_engine_siren",
        "police_siren", "ambulance_siren", "alarm_clock", "beep", "door_bell"
    ]
    static let title = "检测到警报声 · 请按现场指示撤离，不用停下来保存"
    static let notification = "检测到警报声。录音和笔记会自动保留，不用停下来保存。请以现场广播和工作人员指示为准。"
    static let savedTitle = "已保存本节，新录音已在同一位置开始"
    static let explanation = "只在录音且使用麦克风时工作，全部在本机分析。只是辅助提醒，不能代替火警等安全设备。系统内录和导入文件不会触发；麦克风仍可能收进扬声器播放的声音。"
}

struct AlarmSoundObservation: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let score: Double
}

/// Audio time establishes persistence; monotonic wall time establishes cooldown.
/// Duplicate, out-of-order and invalid windows can never contribute extra votes.
struct AlarmTriggerRule: Sendable {
    private(set) var isPresented = false
    private(set) var nextAllowedAt: TimeInterval = 0
    private var windows: [AlarmSoundObservation] = []
    private var lastEnd: TimeInterval = -.infinity

    mutating func observe(_ observation: AlarmSoundObservation, now: TimeInterval) -> Bool {
        guard observation.start.isFinite, observation.end.isFinite, observation.score.isFinite,
              now.isFinite, observation.start >= 0, observation.end > observation.start,
              observation.score >= 0, observation.score <= 1, observation.end > lastEnd,
              abs(observation.end - observation.start - AlarmPolicy.windowSeconds) < 0.01 else { return false }
        if observation.end - lastEnd > AlarmPolicy.windowSeconds { windows.removeAll() }
        lastEnd = observation.end
        guard !isPresented, now >= nextAllowedAt else { windows.removeAll(); return false }
        // The classifier still advances every 1.5 seconds, but overlapping
        // results cannot vote twice for the same PCM. Count three independent
        // 3-second windows within twelve seconds, including misses in that cadence.
        guard windows.last.map({ observation.start >= $0.end - 0.001 }) ?? true else { return false }
        windows.append(observation)
        windows.removeAll { $0.start < observation.end - AlarmPolicy.historySeconds - 0.001 }
        let hits = windows.filter { $0.score >= AlarmPolicy.confidenceThreshold }
        guard hits.count >= AlarmPolicy.requiredWindows,
              let first = hits.first, let last = hits.last,
              last.end - first.end >= AlarmPolicy.minimumHitSpan else { return false }
        isPresented = true
        nextAllowedAt = now + AlarmPolicy.cooldownSeconds
        windows.removeAll()
        return true
    }

    mutating func dismiss(now: TimeInterval) {
        isPresented = false
        nextAllowedAt = max(nextAllowedAt, now + AlarmPolicy.cooldownSeconds)
        windows.removeAll()
    }
    mutating func clearEvidence() { windows.removeAll(); lastEnd = -.infinity }
    mutating func stop() { self = Self() }
}

/// No audio or classifier output is persisted. A bounded utility lane owns all
/// SoundAnalysis calls; capture only copies PCM and never waits for inference.
final class AlarmSoundAnalyzer: @unchecked Sendable {
    private final class Observer: NSObject, SNResultsObserving {
        let handler: @Sendable (AlarmSoundObservation) -> Void
        let failed: @Sendable () -> Void
        init(handler: @escaping @Sendable (AlarmSoundObservation) -> Void,
             failed: @escaping @Sendable () -> Void) { self.handler = handler; self.failed = failed }
        func request(_ request: any SNRequest, didProduce result: any SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let score = result.classifications.filter { AlarmPolicy.labels.contains($0.identifier) }
                .map(\.confidence).max() ?? 0
            handler(.init(start: result.timeRange.start.seconds, end: result.timeRange.end.seconds, score: score))
        }
        func request(_ request: any SNRequest, didFailWithError error: any Error) { failed() }
        func requestDidComplete(_ request: any SNRequest) {}
    }
    private let queue = DispatchQueue(label: "LiveLingo.AlarmAnalysis", qos: .utility)
    private let lock = NSLock()
    private var enabled = true
    private var pendingFrames: AVAudioFramePosition = 0
    private var droppedFrames: AVAudioFramePosition = 0
    // Only accessed on queue after init.
    private var analyzer: SNAudioStreamAnalyzer?
    private let observer: Observer
    let sampleRate: Double

    init(format: AVAudioFormat, handler: @escaping @Sendable (AlarmSoundObservation) -> Void,
         failed: @escaping @Sendable () -> Void) throws {
        sampleRate = format.sampleRate
        observer = Observer(handler: handler, failed: failed)
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: AlarmPolicy.windowSeconds, preferredTimescale: 16_000)
        request.overlapFactor = AlarmPolicy.overlap
        guard AlarmPolicy.labels.isSubset(of: Set(request.knownClassifications)) else {
            throw NSError(domain: "LiveLingo.Alarm", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "系统声音分类器缺少警报标签。"])
        }
        try analyzer.add(request, withObserver: observer)
        self.analyzer = analyzer
    }

    func submit(_ buffer: AVAudioPCMBuffer, at position: AVAudioFramePosition) {
        let frames = AVAudioFramePosition(buffer.frameLength)
        let accepted = lock.withLock { () -> Bool in
            guard enabled else { return false }
            guard pendingFrames + frames <= AVAudioFramePosition(sampleRate * AlarmPolicy.windowSeconds) else {
                droppedFrames += frames
                return false
            }
            pendingFrames += frames
            return true
        }
        guard accepted else { return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            lock.withLock { pendingFrames -= frames }; return
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in source.indices {
            guard let from = source[index].mData, let to = destination[index].mData else {
                lock.withLock { pendingFrames -= frames }; return
            }
            memcpy(to, from, min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize)))
        }
        let owned = AlarmOwnedPCM(copy)
        queue.async { [self] in
            defer { lock.withLock { pendingFrames -= frames } }
            guard lock.withLock({ enabled }) else { return }
            analyzer?.analyze(owned.buffer, atAudioFramePosition: position)
        }
    }

    func stop() {
        lock.withLock { enabled = false }
        queue.async { [self] in analyzer?.removeAllRequests(); analyzer = nil }
    }
    func drain() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    var droppedAudioSeconds: Double { lock.withLock { Double(droppedFrames) / sampleRate } }
}

private final class AlarmOwnedPCM: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

struct AlarmCountdown: Equatable, Sendable {
    private(set) var deadline: TimeInterval?
    mutating func start(now: TimeInterval) { deadline = now + Double(AlarmPolicy.countdownSeconds) }
    mutating func cancel() { deadline = nil }
    func remaining(now: TimeInterval) -> Int? { deadline.map { max(0, Int(ceil($0 - now))) } }
    mutating func takeDue(now: TimeInterval, recording: Bool, paused: Bool, importing: Bool,
                          liveOnly: Bool, enabled: Bool) -> Bool {
        guard let deadline, now >= deadline else { return false }
        self.deadline = nil
        return recording && !paused && !importing && !liveOnly && enabled
    }
}

struct AlarmBannerState: Equatable, Sendable {
    var secondsRemaining: Int?
    var saved = false
    var saving = false
    var failure: String?
    var liveOnly = false
    var title: String { saved ? AlarmPolicy.savedTitle : AlarmPolicy.title }
    var detail: String {
        if let failure { return failure }
        if saving { return "正在保存本节，录音继续。" }
        if secondsRemaining != nil { return "倒计时结束后保存本节，并另开新录音继续。" }
        return liveOnly ? "实时暂存模式：只提醒，不自动保存或分段。" : "录音继续保留，请按现场指示行动。"
    }
    var canCancelSegmentation: Bool { secondsRemaining != nil && !saved && !saving }
    var buttonTitle: String {
        if canCancelSegmentation, let secondsRemaining { return "取消（\(secondsRemaining)）" }
        return "知道了"
    }
    func buttonDetail(hasKeyboardFocus: Bool) -> String {
        (canCancelSegmentation ? "不分段" : "关闭提醒") + (hasKeyboardFocus ? " · Esc" : "")
    }
    var accessibilityHint: String {
        canCancelSegmentation ? "取消自动分段并关闭提醒，录音继续；字幕窗或 LiveLingo 获得键盘焦点时可按 Esc"
            : "关闭提醒，录音继续；字幕窗或 LiveLingo 获得键盘焦点时可按 Esc"
    }
}
