import AVFoundation
import CoreAudio
import Foundation
import OSLog
import ScreenCaptureKit

/// Delivery health is independent of speech detection. A quiet room is valid
/// audio. System capture may omit callbacks while silent; the microphone's
/// existing watchdog still recovers a stalled engine, even if it reports running.
enum CaptureHealthIssue: String, Sendable {
    case noCallbacks = "no_callbacks"
    case noData = "no_data"
    case digitalSilence = "digital_silence"
    case callbackInterrupted = "callback_interrupted"
    case deviceChanged = "device_changed"
    case formatChanged = "format_changed"
    case streamError = "stream_error"
    case recoveryLimited = "recovery_limited"

    func message(for mode: AudioInputMode) -> String {
        let source = mode == .systemAudio ? "系统内录" : "麦克风"
        switch self {
        case .noCallbacks:
            return mode == .systemAudio ? "系统内录暂时没有收到声音（课程暂停或静音时属正常）。"
                : "麦克风已启动，但尚未收到音频。请检查音源。"
        case .noData:
            return "\(source)暂时没有收到声音（课程暂停或静音时属正常）。"
        case .callbackInterrupted:
            return mode == .systemAudio ? "系统内录暂时没有收到声音（课程暂停或静音时属正常）。"
                : "麦克风音频已中断，正在尝试恢复…"
        case .digitalSilence: return "系统内录暂时没有声音（课程暂停或静音时属正常）。"
        case .deviceChanged:
            return mode == .systemAudio ? "系统内录设备已变化，请留意声音是否正常。"
                : "麦克风设备已变化，正在重新连接…"
        case .formatChanged:
            return mode == .systemAudio ? "系统内录音频格式已变化，请留意声音是否正常。"
                : "麦克风格式已变化，正在重新连接…"
        case .streamError: return "\(source)采集流报错，正在尝试恢复…"
        case .recoveryLimited: return "\(source)自动恢复次数已达上限，当前采集保留，请留意声音是否正常。"
        }
    }
}

struct CaptureHealthNotice: Sendable {
    let sessionID: UUID
    let message: String?
}

struct CaptureHealthState {
    static let startupTimeout: TimeInterval = 5
    static let callbackTimeout: TimeInterval = 3
    static let noDataTimeout: TimeInterval = 5
    static let digitalSilenceDuration: TimeInterval = 15
    // Below a 24-bit PCM quantization step, far below ordinary room noise.
    static let digitalSilencePeak = 1e-9
    let mode: AudioInputMode
    var startedAt: TimeInterval
    var issue: CaptureHealthIssue?
    private var hasReceivedCallback = false
    private var silentStart: TimeInterval?
    private var silentEnd: TimeInterval?
    private var silentDuration: TimeInterval = 0

    init(mode: AudioInputMode, startedAt: TimeInterval) {
        self.mode = mode; self.startedAt = startedAt
    }

    mutating func restart(at now: TimeInterval) {
        startedAt = now
        hasReceivedCallback = false
        silentStart = nil; silentEnd = nil; silentDuration = 0
        // Retain the notice until this replacement actually delivers audio.
    }

    mutating func deliveryIssue(_ input: OwnedAudioCaptureBuffer.HealthSnapshot, now: TimeInterval) -> CaptureHealthIssue? {
        if input.callbacks == 0 || (input.lastCallback ?? -.infinity) < startedAt {
            if hasReceivedCallback {
                return now - startedAt >= Self.callbackTimeout ? .callbackInterrupted : nil
            }
            return now - startedAt >= Self.startupTimeout ? .noCallbacks : nil
        }
        hasReceivedCallback = true
        if now - max(input.lastCallback ?? startedAt, startedAt) >= Self.callbackTimeout {
            return .callbackInterrupted
        }
        if mode == .systemAudio,
           now - max(input.lastData ?? startedAt, startedAt) >= Self.noDataTimeout {
            return .noData
        }
        return nil
    }

    mutating func observe(peak: Double, duration: TimeInterval, start: TimeInterval,
                          end: TimeInterval) -> CaptureHealthIssue? {
        hasReceivedCallback = true
        guard mode == .systemAudio else { return nil }
        guard peak.isFinite, duration > 0, start.isFinite, end.isFinite,
              peak <= Self.digitalSilencePeak else {
            silentStart = nil; silentEnd = nil; silentDuration = 0
            return nil
        }
        if silentStart == nil || start - (silentEnd ?? start) >= Self.callbackTimeout {
            silentStart = start; silentDuration = 0
        }
        silentEnd = end
        silentDuration += duration
        // Ring spans are split into 4,096-frame views; their floating-point
        // durations can sum to just below an exact whole second.
        guard silentDuration + 1e-6 >= Self.digitalSilenceDuration,
              end - (silentStart ?? end) + 1e-6 >= Self.digitalSilenceDuration else {
            return issue == .digitalSilence ? issue : nil
        }
        return .digitalSilence
    }
}

/// An intentionally closed diagnostic schema: no text, device IDs, formats,
/// levels, samples, or paths. Healthy capture never creates this file.
struct CaptureHealthDiagnostic: Codable, Sendable {
    let category: String
    let time: TimeInterval
    let callbacks: Int64
    let frames: Int64
    let recoveryAttempts: Int
}

enum CaptureHealthDiagnostics {
    static let fileName = "capture-health.jsonl"
    private static let lock = NSLock()
    private static let logger = Logger(subsystem: "com.jianhongli.LiveLingo", category: "CaptureHealth")

    static func append(_ event: CaptureHealthDiagnostic, beside recording: URL?) {
        logger.notice("category=\(event.category, privacy: .public) time=\(event.time) callbacks=\(event.callbacks) frames=\(event.frames) attempts=\(event.recoveryAttempts)")
        guard let recording else { return }
        lock.withLock {
            do {
                var data = try JSONEncoder().encode(event)
                data.append(0x0a)
                let url = recording.deletingLastPathComponent().appendingPathComponent(fileName)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try data.write(to: url, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                }
            } catch {
                logger.error("category=diagnostic_write_failed count=\((error as NSError).code)")
            }
        }
    }
}

/// Tests replace only the device boundary; buffering, finalization, and retry
/// admission still run through the production pipeline.
protocol SystemAudioCaptureSource: AnyObject, Sendable {
    func start(input: OwnedAudioCaptureBuffer, onError: @escaping @Sendable () -> Void) async throws
    func stop() async
}

final class ScreenSystemAudioCaptureSource: SystemAudioCaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var stream: SCStream?
    private var sink: SystemAudioCaptureSink?
    private var stopped = false
    private let queue = DispatchQueue(label: "LiveLingo.SystemAudioCapture")

    func start(input: OwnedAudioCaptureBuffer, onError: @escaping @Sendable () -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first else { throw SpeechPipeline.PipelineError.noDisplayAvailable }
        let sink = SystemAudioCaptureSink(ingress: input) { _, _ in onError() }
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: SpeechPipeline.systemAudioConfiguration(), delegate: sink)
        try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: queue)
        let accepted = lock.withLock {
            guard !stopped else { return false }
            self.stream = stream; self.sink = sink
            return true
        }
        guard accepted else { throw CancellationError() }
        try await stream.startCapture()
        if lock.withLock({ stopped }) { try? await stream.stopCapture(); throw CancellationError() }
    }

    func stop() async {
        let previous = lock.withLock { stopped = true; let old = stream; stream = nil; return old }
        if let previous { try? await previous.stopCapture() }
        lock.withLock { sink = nil }
    }
}

protocol SystemAudioRouteMonitoring: AnyObject, Sendable {
    func start(onChange: @escaping @Sendable (CaptureHealthIssue) -> Void)
    func stop()
}

/// Core Audio property reads/listeners do not open an audio device or request
/// capture permission. The listener never retains a device name or identifier
/// in diagnostics. Changing the default output rebinds the device listeners.
final class SystemAudioRouteMonitor: SystemAudioRouteMonitoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "LiveLingo.SystemAudioRoute")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var onChange: (@Sendable (CaptureHealthIssue) -> Void)?
    private var bindings: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() { queue.setSpecific(key: queueKey, value: true) }

    func start(onChange: @escaping @Sendable (CaptureHealthIssue) -> Void) {
        queue.sync {
            removeBindings()
            self.onChange = onChange
            bindRoute()
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true { onChange = nil; removeBindings() }
        else { queue.sync { onChange = nil; removeBindings() } }
    }
    deinit { stop() }

    private func removeBindings() {
        for (object, value, block) in bindings {
            var address = value
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        bindings = []
    }

    private func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     block: @escaping AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                mElement: kAudioObjectPropertyElementMain)
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            bindings.append((object, address, block))
        }
    }

    private func bindRoute() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        add(system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] _, _ in
            guard let self, self.onChange != nil else { return }
            self.removeBindings(); self.bindRoute(); self.onChange?(.deviceChanged)
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return }
        let changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?(.formatChanged) }
        add(device, kAudioDevicePropertyNominalSampleRate, block: changed)
        add(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput, block: changed)
        add(device, kAudioDevicePropertyDeviceIsAlive) { [weak self] _, _ in self?.onChange?(.deviceChanged) }
    }
}
