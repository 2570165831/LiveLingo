import AppKit
import AVFoundation
import XCTest
@testable import LiveLingo

private final class ControlledAudioWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    func enable() { lock.withLock { enabled = true } }
    func check() throws {
        if lock.withLock({ enabled }) { throw NSError(domain: "SyntheticTailWriteFailure", code: 1) }
    }
}

private final class ControlledMicrophoneScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@Sendable () -> Void] = []
    var count: Int { lock.withLock { operations.count } }
    func schedule(_ operation: @escaping @Sendable () -> Void) { lock.withLock { operations.append(operation) } }
    @discardableResult func runNext() -> Bool {
        let next = lock.withLock { operations.isEmpty ? nil : operations.removeFirst() }
        next?()
        return next != nil
    }
}

private final class ControlledMicrophoneEngine: NSObject, MicrophoneCaptureEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var input: OwnedAudioCaptureBuffer?
    private var running = false
    private var starts = 0
    private var tapInstalls = 0
    private var stopHook: (@Sendable () -> Void)?
    private var installHook: (@Sendable () -> Void)?
    private var startFailuresRemaining = 0
    var notificationObject: AnyObject { self }
    var outputFormat: AVAudioFormat { lock.withLock { format } }
    var isRunning: Bool { lock.withLock { running } }
    var startCount: Int { lock.withLock { starts } }
    var tapInstallCount: Int { lock.withLock { tapInstalls } }
    var installedFormat: AVAudioFormat? { lock.withLock { input?.format } }
    func setStopHook(_ hook: (@Sendable () -> Void)?) { lock.withLock { stopHook = hook } }
    func setInstallHook(_ hook: (@Sendable () -> Void)?) { lock.withLock { installHook = hook } }
    func failNextStarts(_ count: Int) { lock.withLock { startFailuresRemaining = count } }
    func changeFormat(to sampleRate: Double? = nil) {
        lock.withLock {
            running = false
            if let sampleRate { format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)! }
        }
    }
    func installTap(format: AVAudioFormat, input: OwnedAudioCaptureBuffer) throws {
        let hook = lock.withLock { self.input = input; tapInstalls += 1; return installHook }
        hook?()
    }
    func removeTap() { lock.withLock { input = nil } }
    func prepare() {}
    func start() throws {
        let failed = lock.withLock {
            starts += 1
            if startFailuresRemaining > 0 { startFailuresRemaining -= 1; return true }
            running = true
            return false
        }
        if failed { throw NSError(domain: "SyntheticMicrophone", code: 1) }
    }
    func pause() { lock.withLock { running = false } }
    func stop() {
        let hook = lock.withLock { running = false; return stopHook }
        hook?()
    }
    func send(frames: Int = 1_600, value: Float = 0.1,
              observedEnd: TimeInterval = ProcessInfo.processInfo.systemUptime) -> OwnedAudioCaptureBuffer.Submission? {
        let target = lock.withLock { input }
        guard let target else { return nil }
        let buffer = AVAudioPCMBuffer(pcmFormat: target.format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames { buffer.floatChannelData![0][frame] = value }
        return target.submit(buffer, observedEnd: observedEnd)
    }
    func drain() async { await lock.withLock { input }?.drain() }
}

private final class ControlledMicrophoneNotifications: NotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [@Sendable (Notification) -> Void] = []
    var capturedHandlers: [@Sendable (Notification) -> Void] { lock.withLock { handlers } }
    override func addObserver(forName name: NSNotification.Name?, object obj: Any?,
                              queue: OperationQueue?, using block: @Sendable @escaping (Notification) -> Void) -> NSObjectProtocol {
        if name == .AVAudioEngineConfigurationChange { lock.withLock { handlers.append(block) } }
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }
}

final class MicrophoneLifecycleTests: XCTestCase, @unchecked Sendable {
    private typealias Fixture = (pipeline: SpeechPipeline, engine: ControlledMicrophoneEngine,
        scheduler: ControlledMicrophoneScheduler, notifications: ControlledMicrophoneNotifications,
        events: CaptureSleepEvents, recording: URL, sleepNotifications: NotificationCenter)
    private func start(beforeAudioWrite: (@Sendable () throws -> Void)? = nil) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-MicLifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let engine = ControlledMicrophoneEngine()
        let scheduler = ControlledMicrophoneScheduler()
        let notifications = ControlledMicrophoneNotifications()
        let events = CaptureSleepEvents()
        let sleepNotifications = NotificationCenter()
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Synthetic audio around a device lifecycle change." },
            beforeAudioWrite: beforeAudioWrite, enableAudioAnalysis: false, captureSleepNotificationCenter: sleepNotifications,
            microphoneEngineFactory: { engine }, microphoneNotifications: notifications,
            microphoneRecoveryScheduler: scheduler.schedule, enableMicrophoneWatchdog: false)
        let recording = directory.appendingPathComponent("recording.wav")
        try await pipeline.start(inputMode: .microphone, recordingURL: recording, sessionID: UUID(), eventHandler: events.consume)
        return (pipeline, engine, scheduler, notifications, events, recording, sleepNotifications)
    }
    private func change(_ f: Fixture, sampleRate: Double? = nil) {
        f.engine.changeFormat(to: sampleRate)
        f.notifications.post(name: .AVAudioEngineConfigurationChange, object: f.engine.notificationObject)
    }

    func testPauseBeforeQueuedRecoveryAllowsResumeAndLaterDeviceChanges() async throws {
        let f = try await start()
        XCTAssertEqual(f.engine.send(), .accepted)
        await f.engine.drain()
        change(f)
        XCTAssertEqual(f.scheduler.count, 1)
        XCTAssertEqual(f.pipeline.syntheticMicrophoneRecoveryState.attempts, 0,
                       "Queued work is not an actual recovery attempt")
        f.pipeline.pause()
        XCTAssertTrue(f.scheduler.runNext())
        XCTAssertFalse(f.pipeline.syntheticMicrophoneRecoveryState.pending,
                       "A paused delayed callback must not hold recovery admission forever")
        XCTAssertEqual(f.engine.startCount, 1)
        try f.pipeline.resume()
        XCTAssertEqual(f.scheduler.count, 1, "Resume must finish the device change deferred by pause")
        _ = f.scheduler.runNext()
        XCTAssertEqual(f.engine.send(value: 0.2), .accepted)
        await f.engine.drain()
        change(f)
        XCTAssertEqual(f.scheduler.count, 1, "A later device change must still be admitted")
        _ = f.scheduler.runNext()
        XCTAssertEqual(f.engine.send(value: 0.3), .accepted)
        await f.engine.drain()
        await f.pipeline.stop()
        XCTAssertTrue(f.events.failures.isEmpty)
        XCTAssertEqual(try AVAudioFile(forReading: f.recording).length, 4_800)
    }

    func testPauseDuringRecoveryDoesNotLeaveASealedInputAfterResume() async throws {
        let f = try await start()
        XCTAssertEqual(f.engine.send(), .accepted)
        await f.engine.drain()
        change(f)
        f.engine.setStopHook { f.pipeline.pause() }
        XCTAssertTrue(f.scheduler.runNext())
        f.engine.setStopHook(nil)
        XCTAssertFalse(f.pipeline.syntheticMicrophoneRecoveryState.pending)
        try f.pipeline.resume()
        XCTAssertEqual(f.scheduler.count, 1)
        _ = f.scheduler.runNext()
        XCTAssertEqual(f.engine.send(value: 0.2), .accepted, "Resume must bind a usable replacement input")
        await f.engine.drain()
        await f.pipeline.stop()
        XCTAssertTrue(f.events.failures.isEmpty)
        XCTAssertEqual(try AVAudioFile(forReading: f.recording).length, 3_200)
    }

    func testDeviceChangeWhilePausedIsAppliedBeforeAudioResumes() async throws {
        let f = try await start()
        XCTAssertEqual(f.engine.send(), .accepted)
        await f.engine.drain()
        f.pipeline.pause()
        change(f, sampleRate: 48_000)
        XCTAssertEqual(f.scheduler.count, 0)
        try f.pipeline.resume()
        XCTAssertEqual(f.scheduler.count, 1)
        _ = f.scheduler.runNext()
        XCTAssertEqual(f.engine.installedFormat?.sampleRate, 48_000)
        XCTAssertEqual(f.engine.send(frames: 4_800, value: 0.2), .accepted)
        await f.engine.drain()
        await f.pipeline.stop()
        let saved = try AVAudioFile(forReading: f.recording)
        XCTAssertEqual(saved.processingFormat.sampleRate, 16_000, "Existing WAV storage format must remain fixed")
        XCTAssertEqual(saved.length, 3_200, "All accepted input, including converter tail, must reach the WAV")
        let samples = AVAudioPCMBuffer(pcmFormat: saved.processingFormat, frameCapacity: AVAudioFrameCount(saved.length))!
        try saved.read(into: samples)
        XCTAssertEqual(samples.floatChannelData![0][0], 0.1, accuracy: 0.0001)
        XCTAssertEqual(samples.floatChannelData![0][2_000], 0.2, accuracy: 0.001)
    }

    func testCancelledDelayedCallbackCannotClearNewResumeRequest() async throws {
        let f = try await start()
        change(f)
        f.pipeline.pause()
        try f.pipeline.resume()
        XCTAssertEqual(f.scheduler.count, 2)
        XCTAssertTrue(f.scheduler.runNext()) // cancelled request
        XCTAssertTrue(f.pipeline.syntheticMicrophoneRecoveryState.pending)
        XCTAssertEqual(f.pipeline.syntheticMicrophoneRecoveryState.attempts, 0)
        XCTAssertEqual(f.engine.startCount, 1)
        XCTAssertTrue(f.scheduler.runNext()) // current request
        XCTAssertFalse(f.pipeline.syntheticMicrophoneRecoveryState.pending)
        XCTAssertEqual(f.pipeline.syntheticMicrophoneRecoveryState.attempts, 1)
        XCTAssertEqual(f.engine.startCount, 2)
        XCTAssertEqual(f.engine.send(), .accepted)
        await f.engine.drain()
        await f.pipeline.stop()
        XCTAssertEqual(try AVAudioFile(forReading: f.recording).length, 1_600)
    }

    func testNewTapHonorsPauseThatArrivesDuringInstallation() async throws {
        let f = try await start()
        XCTAssertEqual(f.engine.send(), .accepted)
        await f.engine.drain()
        f.engine.setInstallHook { f.pipeline.pause() }
        change(f)
        XCTAssertTrue(f.scheduler.runNext())
        XCTAssertEqual(f.engine.send(value: 0.9), .paused)
        XCTAssertEqual(f.engine.startCount, 1)
        XCTAssertFalse(f.pipeline.syntheticMicrophoneRecoveryState.pending)
        f.engine.setInstallHook(nil)
        try f.pipeline.resume()
        XCTAssertTrue(f.scheduler.runNext())
        XCTAssertEqual(f.engine.send(value: 0.2), .accepted)
        await f.engine.drain()
        await f.pipeline.stop()
        let file = try AVAudioFile(forReading: f.recording)
        XCTAssertEqual(file.length, 3_200)
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 3_200)!
        try file.read(into: pcm)
        for i in 0..<3_200 { XCTAssertEqual(pcm.floatChannelData![0][i], i < 1_600 ? 0.1 : 0.2) }
    }

    func testDuplicateNotificationsCoalesceAndSilentPCMIsHealthy() async throws {
        let f = try await start()
        for _ in 0..<5 { change(f) }
        XCTAssertEqual(f.scheduler.count, 1)
        XCTAssertEqual(f.pipeline.syntheticMicrophoneRecoveryState.attempts, 0)
        XCTAssertTrue(f.scheduler.runNext())
        XCTAssertEqual(f.pipeline.syntheticMicrophoneRecoveryState.attempts, 1)
        let time = ProcessInfo.processInfo.systemUptime
        for i in 0..<8 {
            let end = time + Double(i)
            XCTAssertEqual(f.engine.send(value: 0, observedEnd: end), .accepted)
            await f.engine.drain()
            f.pipeline.checkSyntheticMicrophoneHealth(now: end + 0.25)
        }
        XCTAssertEqual(f.scheduler.count, 0)
        XCTAssertEqual(f.engine.startCount, 2)
        await f.pipeline.stop()
        XCTAssertTrue(f.events.failures.isEmpty)
        XCTAssertEqual(try AVAudioFile(forReading: f.recording).length, 12_800)
    }

    func testFailedStartsRemainBoundedAndPreserveRecordedPCM() async throws {
        let f = try await start()
        XCTAssertEqual(f.engine.send(), .accepted)
        await f.engine.drain()
        f.engine.failNextStarts(10)
        change(f)
        for _ in 0..<(SpeechPipeline.maximumMicrophoneRecoveryAttempts + 1) {
            XCTAssertTrue(f.scheduler.runNext())
        }
        for _ in 0..<200 where f.events.failures.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(f.events.failures.count, 1)
        XCTAssertTrue(f.events.failures.first?.contains("恢复次数") == true)
        XCTAssertEqual(f.scheduler.count, 0)
        XCTAssertEqual(f.engine.startCount, 1 + SpeechPipeline.maximumMicrophoneRecoveryAttempts)
        XCTAssertEqual(f.pipeline.transcriptionState()?.isCapturing, false)
        await f.pipeline.stop()
        XCTAssertEqual(try AVAudioFile(forReading: f.recording).length, 1_600)
    }

    func testPreviousSessionCallbacksCannotTouchTheReplacementCapture() async throws {
        let f = try await start()
        XCTAssertEqual(f.engine.send(), .accepted)
        await f.engine.drain()
        let oldNotification = try XCTUnwrap(f.notifications.capturedHandlers.first)
        change(f)
        await f.pipeline.stop()
        let replacement = f.recording.deletingLastPathComponent().appendingPathComponent("second/recording.wav")
        try await f.pipeline.start(inputMode: .microphone, recordingURL: replacement, sessionID: UUID(), eventHandler: f.events.consume)
        oldNotification(Notification(name: .AVAudioEngineConfigurationChange, object: f.engine.notificationObject))
        XCTAssertFalse(f.pipeline.syntheticMicrophoneRecoveryState.pending)
        change(f)
        XCTAssertEqual(f.scheduler.count, 2)
        XCTAssertTrue(f.scheduler.runNext()) // old session
        XCTAssertTrue(f.pipeline.syntheticMicrophoneRecoveryState.pending)
        XCTAssertEqual(f.engine.startCount, 2)
        XCTAssertTrue(f.scheduler.runNext())
        XCTAssertEqual(f.engine.startCount, 3)
        XCTAssertEqual(f.engine.send(), .accepted)
        await f.engine.drain()
        await f.pipeline.stop()
        XCTAssertTrue(f.events.failures.isEmpty)
        XCTAssertEqual(try AVAudioFile(forReading: f.recording).length, 1_600)
        XCTAssertEqual(try AVAudioFile(forReading: replacement).length, 1_600)
    }

    func testSleepWhileRecoveryIsQueuedCannotRestartTheMicrophone() async throws {
        let f = try await start()
        XCTAssertEqual(f.engine.send(), .accepted)
        await f.engine.drain()
        change(f)
        f.sleepNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        for _ in 0..<200 where f.events.failures.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(f.events.failures.count, 1)
        XCTAssertTrue(f.events.failures.first?.contains("休眠") == true)
        XCTAssertTrue(f.scheduler.runNext())
        f.sleepNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(f.engine.startCount, 1)
        XCTAssertFalse(f.engine.isRunning)
        XCTAssertEqual(f.scheduler.count, 0)
        XCTAssertEqual(f.pipeline.transcriptionState()?.isCapturing, false)
        await f.pipeline.stop()
        XCTAssertEqual(try AVAudioFile(forReading: f.recording).length, 1_600)
    }

    func testEveryRemovedDeviceFlushesItsTailBeforeTheNextInput() async throws {
        let f = try await start()
        XCTAssertEqual(f.engine.send(), .accepted)
        await f.engine.drain()
        change(f, sampleRate: 48_000)
        XCTAssertTrue(f.scheduler.runNext())
        XCTAssertEqual(f.engine.send(frames: 4_800, value: 0.2), .accepted)
        await f.engine.drain()
        change(f, sampleRate: 44_100)
        XCTAssertTrue(f.scheduler.runNext())
        XCTAssertEqual(f.engine.send(frames: 4_410, value: 0.3), .accepted)
        await f.engine.drain()
        await f.pipeline.stop()
        XCTAssertTrue(f.events.failures.isEmpty)
        let reader = try AVAudioFile(forReading: f.recording)
        XCTAssertEqual(reader.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(reader.length, 4_800)
        let samples = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 4_800)!
        try reader.read(into: samples)
        XCTAssertEqual(samples.floatChannelData![0][0], 0.1, accuracy: 0.0001)
        XCTAssertEqual(samples.floatChannelData![0][2_000], 0.2, accuracy: 0.001)
        XCTAssertEqual(samples.floatChannelData![0][4_000], 0.3, accuracy: 0.001)
    }

    func testTailWriteFailureStopsRecoveryBeforeStartingAnotherInput() async throws {
        let failure = ControlledAudioWriteFailure()
        let f = try await start(beforeAudioWrite: failure.check)
        XCTAssertEqual(f.engine.send(), .accepted)
        await f.engine.drain()
        change(f, sampleRate: 48_000)
        XCTAssertTrue(f.scheduler.runNext())
        XCTAssertEqual(f.engine.send(frames: 4_800, value: 0.2), .accepted)
        await f.engine.drain()
        failure.enable()
        change(f, sampleRate: 44_100)
        XCTAssertTrue(f.scheduler.runNext())
        for _ in 0..<200 where f.events.failures.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(f.events.failures.count, 1)
        XCTAssertTrue(f.events.failures.first?.contains("尾部") == true)
        XCTAssertEqual(f.engine.startCount, 2, "A terminal write error must close the recovery gate synchronously")
        XCTAssertEqual(f.scheduler.count, 0)
        XCTAssertEqual(f.pipeline.transcriptionState()?.isCapturing, false)
        await f.pipeline.stop()
        let saved = try AVAudioFile(forReading: f.recording)
        XCTAssertGreaterThanOrEqual(saved.length, 1_600)
        XCTAssertLessThan(saved.length, 3_200)
    }

    func testConverterFinishesExactDurationAcrossCommonRatePairs() throws {
        for (sourceRate, targetRate) in [(16_000.0, 48_000.0), (48_000.0, 16_000.0),
                                         (44_100.0, 48_000.0), (48_000.0, 44_100.0)] {
            let inputFormat = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1)!
            let targetFormat = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1)!
            let bridge = CaptureFormatBridge(inputFormat: inputFormat, storageFormat: targetFormat)
            let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(sourceRate / 100))!
            input.frameLength = input.frameCapacity
            for i in 0..<Int(input.frameLength) { input.floatChannelData![0][i] = 0.1 }
            var frames = 0
            for _ in 0..<7 { frames += Int(try bridge.convert(input).frameLength) }
            let beforeFinish = frames
            try bridge.finish { output in
                frames += Int(output.frameLength)
                for i in 0..<Int(output.frameLength) { XCTAssertTrue(output.floatChannelData![0][i].isFinite) }
            }
            XCTAssertEqual(frames, Int((targetRate * 0.07).rounded()), "\(sourceRate) → \(targetRate)")
            XCTAssertGreaterThan(frames, beforeFinish)
        }
    }

    func testResumeGetsAFullGracePeriodDespiteOldAcceptedAudio() async throws {
        let f = try await start()
        XCTAssertEqual(f.engine.send(observedEnd: ProcessInfo.processInfo.systemUptime - 20), .accepted)
        await f.engine.drain()
        f.pipeline.pause()
        try f.pipeline.resume()
        let resumed = ProcessInfo.processInfo.systemUptime
        f.pipeline.checkSyntheticMicrophoneHealth(now: resumed + 0.5)
        XCTAssertEqual(f.scheduler.count, 0, "Pre-pause callbacks must not bypass the resume grace period")
        f.pipeline.checkSyntheticMicrophoneHealth(now: resumed + SpeechPipeline.microphoneStallTimeout + 0.5)
        XCTAssertEqual(f.scheduler.count, 1, "The grace period must still expire if audio does not return")
        await f.pipeline.stop()
    }
}

private final class CaptureSleepEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func consume(_ event: SpeechPipeline.Event) {
        if case .failure(let message) = event { lock.withLock { messages.append(message) } }
    }
    var failures: [String] { lock.withLock { messages } }
}

private final class CapturingSleepNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [@Sendable (Notification) -> Void] = []
    var sleepHandlers: [@Sendable (Notification) -> Void] { lock.withLock { blocks } }
    override func addObserver(forName name: NSNotification.Name?, object obj: Any?,
                              queue: OperationQueue?, using block: @Sendable @escaping (Notification) -> Void) -> NSObjectProtocol {
        if name == NSWorkspace.willSleepNotification { lock.withLock { blocks.append(block) } }
        return super.addObserver(forName: name, object: obj, queue: queue, using: block)
    }
}

final class CaptureSleepTests: XCTestCase, @unchecked Sendable {
    private func beginCapture(center: NotificationCenter, mode: AudioInputMode? = .microphone,
                              existing: SpeechPipeline? = nil) async throws
        -> (pipeline: SpeechPipeline, events: CaptureSleepEvents, recording: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-Sleep-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let events = CaptureSleepEvents()
        let pipeline = existing ?? SpeechPipeline(transcriber: { _, _, _ in "Synthetic audio before a lifecycle event." },
            enableAudioAnalysis: false, captureSleepNotificationCenter: center)
        let recording = directory.appendingPathComponent("recording.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let input = try await pipeline.startSyntheticCapture(format: format, recordingURL: recording,
            sessionID: UUID(), inputMode: mode, eventHandler: events.consume)
        let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3_200)!
        audio.frameLength = 3_200
        for i in 0..<3_200 { audio.floatChannelData![0][i] = Float(i % 100) / 1_000 }
        XCTAssertEqual(input.submit(audio), .accepted)
        await input.drain()
        return (pipeline, events, recording)
    }

    private func waitForSleepFailure(_ events: CaptureSleepEvents) async throws {
        for _ in 0..<200 where events.failures.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(events.failures.count, 1)
        XCTAssertTrue(events.failures.first?.contains("休眠") == true)
    }

    func testOnlyDisplaySleepKeepsBothAudioInputsCapturing() async throws {
        for mode in [AudioInputMode.microphone, .systemAudio] {
            let center = NotificationCenter()
            let capture = try await beginCapture(center: center, mode: mode)
            center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(capture.pipeline.transcriptionState()?.isCapturing, true)
            XCTAssertTrue(capture.events.failures.isEmpty)
            await capture.pipeline.stop()
            XCTAssertEqual(try AVAudioFile(forReading: capture.recording).length, 3_200)
        }
    }

    func testSleepEndsPausedMicrophoneAndSystemAudioWithoutWakeRestart() async throws {
        for mode in [AudioInputMode.microphone, .systemAudio] {
            let center = NotificationCenter()
            let capture = try await beginCapture(center: center, mode: mode)
            capture.pipeline.pause()
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            try await waitForSleepFailure(capture.events)
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(capture.pipeline.transcriptionState()?.isCapturing, false)
            XCTAssertEqual(capture.events.failures.count, 1)
            XCTAssertEqual(try AVAudioFile(forReading: capture.recording).length, 3_200)
            await capture.pipeline.stop()
        }
    }

    func testRepeatedSleepNotificationsFinalizeOnceAndLeaveOneDurableChunk() async throws {
        let center = NotificationCenter()
        let capture = try await beginCapture(center: center)
        for _ in 0..<3 { center.post(name: NSWorkspace.willSleepNotification, object: nil) }
        try await waitForSleepFailure(capture.events)
        await capture.pipeline.stop()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(capture.events.failures.count, 1)
        XCTAssertEqual(capture.pipeline.transcriptionWork().count, 1)
        XCTAssertEqual(capture.pipeline.transcriptionWork().first?.endFrame, 3_200)
        XCTAssertEqual(try AVAudioFile(forReading: capture.recording).length, 3_200)
    }

    func testOldSessionSleepCallbackCannotStopReplacementSession() async throws {
        let center = CapturingSleepNotificationCenter()
        let first = try await beginCapture(center: center)
        let oldCallback = try XCTUnwrap(center.sleepHandlers.first)
        await first.pipeline.stop()
        let second = try await beginCapture(center: center, existing: first.pipeline)
        oldCallback(Notification(name: NSWorkspace.willSleepNotification))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(first.events.failures.isEmpty)
        XCTAssertTrue(second.events.failures.isEmpty)
        XCTAssertEqual(second.pipeline.transcriptionState()?.isCapturing, true)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await waitForSleepFailure(second.events)
        await second.pipeline.stop()
        XCTAssertEqual(try AVAudioFile(forReading: first.recording).length, 3_200)
        XCTAssertEqual(try AVAudioFile(forReading: second.recording).length, 3_200)
    }

    func testNonDeviceInputDoesNotSubscribeToCaptureSleepHandling() async throws {
        let center = CapturingSleepNotificationCenter()
        let capture = try await beginCapture(center: center, mode: nil)
        XCTAssertTrue(center.sleepHandlers.isEmpty)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(capture.pipeline.transcriptionState()?.isCapturing, true)
        XCTAssertTrue(capture.events.failures.isEmpty)
        await capture.pipeline.stop()
    }

    func testSleepFinalizesRecordedAudioBeforeReportingWhyCaptureStopped() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveLingo-Sleep-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let notificationCenter = NotificationCenter()
        let events = CaptureSleepEvents()
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "A synthetic sentence recorded before sleep." },
            enableAudioAnalysis: false, captureSleepNotificationCenter: notificationCenter)
        let recording = directory.appendingPathComponent("recording.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let input = try await pipeline.startSyntheticCapture(format: format, recordingURL: recording,
            sessionID: UUID(), inputMode: .microphone, eventHandler: events.consume)
        let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        audio.frameLength = 8_000
        for i in 0..<8_000 { audio.floatChannelData![0][i] = Float(i % 100) / 1_000 }
        XCTAssertEqual(input.submit(audio), .accepted)
        await input.drain()
        XCTAssertEqual(pipeline.transcriptionState()?.isCapturing, true)

        // Isolated notification center: no real sleep, device or permission.
        notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        for _ in 0..<200 where events.failures.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(events.failures.count, 1, "System sleep must end capture with an explicit cause")
        XCTAssertTrue(events.failures.first?.contains("休眠") == true)
        XCTAssertEqual(pipeline.transcriptionState()?.isCapturing, false,
                       "Failure delivery must follow durable capture finalization")
        await pipeline.stop()
        let reader = try AVAudioFile(forReading: recording)
        XCTAssertEqual(reader.length, 8_000)
        let readback = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 8_000)!
        try reader.read(into: readback)
        XCTAssertEqual(readback.frameLength, audio.frameLength)
        for i in 0..<8_000 { XCTAssertEqual(readback.floatChannelData![0][i], audio.floatChannelData![0][i]) }
        let work = pipeline.transcriptionWork()
        XCTAssertEqual(work.count, 1)
        XCTAssertEqual(work.first?.endFrame, 8_000)
    }
}

/// Two recording-continuity faults are covered here:
/// 1. context retry could not read a recording that was still being written,
/// 2. a microphone switch stopped capture because the new hardware format was
///    pushed into the tap and file of the old one.
final class AudioContinuityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveLingoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - 录音仍在写入时的上下文提取

    func testContextExtractionWorksWhileTheRecordingIsStillOpen() throws {
        let url = directory.appendingPathComponent("recording.wav")
        let format = Self.floatFormat(48_000, channels: 1)
        let writer = try Self.writer(at: url, format: format)
        try Self.writeRamp(to: writer, format: format, seconds: 6, startingAt: 0)

        let sizeBefore = try Self.fileSize(url)
        let headerBefore = try Self.prefixBytes(url, count: 8_192)

        // The reason the old code failed: a writer that is still open leaves the
        // data chunk length at zero, so AVAudioFile reports an empty recording.
        let liveLength = try AVAudioFile(forReading: url).length
        XCTAssertEqual(liveLength, 0, "仍在写入的 WAV 在 AVAudioFile 中应当读不到长度")

        // The window is [start - 0.75, end + 0.75].
        let clip = try WAVContextClip.extract(from: url, start: 2, end: 4)
        XCTAssertEqual(try Self.duration(of: clip), 3.5, accuracy: 0.02)

        // The window starts 0.75 s before the requested start and the samples
        // carry their own time stamp, so this also proves the data offset.
        let firstSamples = try Self.firstFrames(of: clip, count: 4)
        XCTAssertEqual(Double(firstSamples[0]), 1.25, accuracy: 0.01)

        XCTAssertEqual(try Self.fileSize(url), sizeBefore, "提取上下文不得改写原录音")
        XCTAssertEqual(try Self.prefixBytes(url, count: 8_192), headerBefore, "原录音头不得被改写")
    }

    func testLayoutReadsARealHeaderWithAZeroLengthDataChunk() throws {
        let url = directory.appendingPathComponent("live-layout.wav")
        let format = Self.floatFormat(48_000, channels: 1)
        let writer = try Self.writer(at: url, format: format)
        try Self.writeRamp(to: writer, format: format, seconds: 6, startingAt: 0)

        let layout = try WAVContextClip.readLayout(at: url)
        XCTAssertEqual(layout.sampleRate, 48_000)
        XCTAssertEqual(layout.channelCount, 1)
        XCTAssertEqual(layout.bitsPerSample, 32)
        XCTAssertEqual(layout.blockAlign, 4)
        XCTAssertGreaterThan(layout.dataOffset, 44)
        XCTAssertGreaterThan(layout.dataByteCount, 0)
        XCTAssertEqual(layout.frameCount, layout.dataByteCount / layout.blockAlign)
    }

    func testChunkWalkHandlesPaddingAndAnUnupdatedDataLength() throws {
        let url = directory.appendingPathComponent("handmade.wav")
        let frames = 4_800
        var bytes = Data()
        func appendU32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        func appendU16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        bytes.append(contentsOf: Array("RIFF".utf8))
        appendU32(0) // stale length, as while recording
        bytes.append(contentsOf: Array("WAVE".utf8))
        bytes.append(contentsOf: Array("JUNK".utf8))
        appendU32(3)
        bytes.append(contentsOf: [1, 2, 3, 0]) // odd size plus pad byte
        bytes.append(contentsOf: Array("fmt ".utf8))
        appendU32(16)
        appendU16(3); appendU16(1); appendU32(48_000); appendU32(48_000 * 4); appendU16(4); appendU16(32)
        bytes.append(contentsOf: Array("data".utf8))
        appendU32(0) // writer has not updated this yet
        bytes.append(Data(repeating: 0x11, count: frames * 4))
        try bytes.write(to: url)

        let layout = try WAVContextClip.readLayout(at: url)
        XCTAssertEqual(layout.dataOffset, 56)
        XCTAssertEqual(layout.dataByteCount, frames * 4)
        XCTAssertEqual(layout.frameCount, frames)

        let clip = try WAVContextClip.extract(from: url, start: 0, end: 0.05)
        XCTAssertEqual(try Self.duration(of: clip), 0.1, accuracy: 0.001)
    }

    func testAppendedAudioIsVisibleInALaterSnapshot() throws {
        let url = directory.appendingPathComponent("growing.wav")
        let format = Self.floatFormat(48_000, channels: 1)
        let writer = try Self.writer(at: url, format: format)
        try Self.writeRamp(to: writer, format: format, seconds: 3, startingAt: 0)

        let first = try WAVContextClip.extract(from: url, start: 0, end: 1)
        XCTAssertEqual(try Self.duration(of: first), 1.75, accuracy: 0.02)

        try Self.writeRamp(to: writer, format: format, seconds: 3, startingAt: 3)
        let second = try WAVContextClip.extract(from: url, start: 4, end: 5)
        // The writer may still hold the newest bytes in memory, so the length is
        // only bounded here; the sample values prove which audio was read.
        XCTAssertGreaterThanOrEqual(try Self.duration(of: second), 1.0)
        XCTAssertLessThanOrEqual(try Self.duration(of: second), 2.52)
        let samples = try Self.firstFrames(of: second, count: 4)
        XCTAssertEqual(Double(samples[0]), 3.25, accuracy: 0.02)
    }

    func testPartialTrailingFrameIsDroppedInsteadOfCorruptingTheClip() throws {
        let url = directory.appendingPathComponent("truncated.wav")
        let format = Self.floatFormat(48_000, channels: 1)
        let writer = try Self.writer(at: url, format: format)
        try Self.writeRamp(to: writer, format: format, seconds: 6, startingAt: 0)
        if #available(macOS 15, *) { writer.close() }

        let handle = try FileHandle(forWritingTo: url)
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - 3)
        try handle.close()

        let clip = try WAVContextClip.extract(from: url, start: 5, end: 6)
        // 6 s minus three bytes leaves 143 999 3/4 frames; the clip must keep
        // only complete frames instead of failing or emitting a broken file.
        XCTAssertEqual(try Self.duration(of: clip), 1.7499, accuracy: 0.001)
    }

    func testUnwrittenRangeAndUnreadableFilesGetDistinctDiagnostics() throws {
        let url = directory.appendingPathComponent("short.wav")
        let format = Self.floatFormat(48_000, channels: 1)
        let writer = try Self.writer(at: url, format: format)
        try Self.writeRamp(to: writer, format: format, seconds: 1, startingAt: 0)

        XCTAssertThrowsEqual(
            try WAVContextClip.extract(from: url, start: 30, end: 31),
            WAVContextClip.ClipError.rangeNotWrittenYet
        )

        let missing = directory.appendingPathComponent("missing.wav")
        XCTAssertThrowsEqual(
            try WAVContextClip.extract(from: missing, start: 0, end: 1),
            WAVContextClip.ClipError.fileMissing
        )

        let notWave = directory.appendingPathComponent("notes.txt")
        try Data(repeating: 0x41, count: 512).write(to: notWave)
        XCTAssertThrowsEqual(
            try WAVContextClip.extract(from: notWave, start: 0, end: 1),
            WAVContextClip.ClipError.notWaveFile
        )
    }

    func testExtractedClipIsBoundedAndReadableByStandardReaders() throws {
        let url = directory.appendingPathComponent("bounded.wav")
        let format = Self.floatFormat(48_000, channels: 1)
        let writer = try Self.writer(at: url, format: format)
        try Self.writeRamp(to: writer, format: format, seconds: 30, startingAt: 0)

        let clip = try WAVContextClip.extract(from: url, start: 0, end: 20,
                                              maximumSeconds: 1, maximumBytes: 1 << 20)
        XCTAssertLessThanOrEqual(try Self.duration(of: clip), 1.0001)
        let reader = try AVAudioFile(forReading: clip)
        XCTAssertEqual(reader.processingFormat.sampleRate, 48_000)
        XCTAssertEqual(reader.processingFormat.channelCount, 1)
    }

    // MARK: - 设备切换与格式变化

    func testRecoveryPlanCoversSampleRateChannelAndDeviceRemoval() {
        let storage = Self.floatFormat(48_000, channels: 1)
        let builtIn = Self.floatFormat(44_100, channels: 1)
        let stereo = Self.floatFormat(48_000, channels: 2)

        XCTAssertEqual(
            SpeechPipeline.microphoneRecoveryPlan(forOutputFormat: builtIn, storageFormat: storage),
            .convert
        )
        XCTAssertEqual(
            SpeechPipeline.microphoneRecoveryPlan(forOutputFormat: stereo, storageFormat: storage),
            .convert
        )
        XCTAssertEqual(
            SpeechPipeline.microphoneRecoveryPlan(forOutputFormat: storage, storageFormat: storage),
            .direct
        )
        XCTAssertEqual(
            SpeechPipeline.microphoneRecoveryPlan(forOutputFormat: nil, storageFormat: storage),
            .unavailable
        )
        let removed = AVAudioFormat(standardFormatWithSampleRate: 0, channels: 0)
        XCTAssertEqual(
            SpeechPipeline.microphoneRecoveryPlan(forOutputFormat: removed, storageFormat: storage),
            .unavailable
        )
        XCTAssertEqual(
            SpeechPipeline.microphoneRecoveryPlan(forOutputFormat: builtIn, storageFormat: nil),
            .direct
        )
    }

    func testBridgeSurvivesRepeatedHardwareFormatChanges() throws {
        let session = Self.floatFormat(48_000, channels: 1)
        let airPods = Self.floatFormat(48_000, channels: 1)
        let builtIn = Self.floatFormat(44_100, channels: 1)

        var bridge = CaptureFormatBridge(inputFormat: airPods, storageFormat: session)
        XCTAssertFalse(bridge.needsConversion)
        XCTAssertTrue(bridge.isUsable)

        XCTAssertTrue(bridge.update(inputFormat: builtIn))
        XCTAssertTrue(bridge.needsConversion)
        // A sample-rate converter may prime its filter on the first buffer, so
        // the frames are counted across several callbacks.
        var convertedFrames = 0
        for _ in 0..<4 {
            let converted = try bridge.convert(Self.ramp(format: builtIn, seconds: 0.1, startingAt: 7))
            XCTAssertEqual(converted.format.sampleRate, 48_000)
            XCTAssertEqual(converted.format.channelCount, 1)
            convertedFrames += Int(converted.frameLength)
        }
        // A sample-rate converter keeps a fixed few milliseconds of samples in
        // its filter; measured shortfall is 264 frames over these four buffers,
        // so the allowance is one priming latency rather than a drift budget.
        XCTAssertEqual(Double(convertedFrames), 4 * 4_800, accuracy: 800)

        for _ in 0..<5 {
            XCTAssertTrue(bridge.update(inputFormat: airPods))
            XCTAssertFalse(bridge.needsConversion)
            let direct = try bridge.convert(Self.ramp(format: airPods, seconds: 0.05, startingAt: 1))
            XCTAssertEqual(direct.frameLength, 2_400)
            XCTAssertTrue(bridge.update(inputFormat: builtIn))
            XCTAssertTrue(bridge.needsConversion)
            _ = try bridge.convert(Self.ramp(format: builtIn, seconds: 0.05, startingAt: 1))
        }
    }

    func testBridgeDownmixesStereoHardwareIntoTheMonoSessionFile() throws {
        let session = Self.floatFormat(48_000, channels: 1)
        let stereo = Self.floatFormat(44_100, channels: 2)
        let bridge = CaptureFormatBridge(inputFormat: stereo, storageFormat: session)
        XCTAssertTrue(bridge.isUsable)

        var frames = 0
        for _ in 0..<3 {
            let output = try bridge.convert(Self.ramp(format: stereo, seconds: 0.2, startingAt: 0))
            XCTAssertEqual(output.format.channelCount, 1)
            XCTAssertEqual(output.format.sampleRate, 48_000)
            frames += Int(output.frameLength)
        }
        XCTAssertEqual(Double(frames), 3 * 9_600, accuracy: 1_600)
    }

    func testSessionFileStaysWritableAcrossAFormatChange() throws {
        let url = directory.appendingPathComponent("session.wav")
        let session = Self.floatFormat(48_000, channels: 1)
        let file = try Self.writer(at: url, format: session)

        // First device: 48 kHz.
        try file.write(from: Self.ramp(format: session, seconds: 1, startingAt: 0))
        // The user switches to a 44.1 kHz device.
        let bridge = CaptureFormatBridge(inputFormat: Self.floatFormat(44_100, channels: 1),
                                         storageFormat: session)
        try file.write(from: try bridge.convert(Self.ramp(format: Self.floatFormat(44_100, channels: 1),
                                                          seconds: 1, startingAt: 1)))
        if #available(macOS 15, *) { file.close() }

        // The recording stays a single readable 48 kHz file instead of a
        // half-48-kHz, half-44.1-kHz stream.
        let reader = try AVAudioFile(forReading: url)
        XCTAssertEqual(reader.processingFormat.sampleRate, 48_000)
        // One second at 48 kHz plus one converted second at 44.1 kHz, minus the
        // converter's fixed priming latency instead of a rising drift.
        XCTAssertEqual(Double(reader.length), 96_000, accuracy: 800)
    }

    // MARK: - helpers

    private static func floatFormat(_ rate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    }

    private static func writer(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: format.settings,
                        commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    /// Samples carry their own time stamp, which makes an offset mistake visible.
    private static func ramp(format: AVAudioFormat, seconds: Double, startingAt offset: Double) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount((format.sampleRate * seconds).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channels = Int(format.channelCount)
        guard let data = buffer.floatChannelData else { return buffer }
        for frame in 0..<Int(frames) {
            let value = Float(offset + Double(frame) / format.sampleRate)
            for channel in 0..<channels {
                data[format.isInterleaved ? 0 : channel][format.isInterleaved ? frame * channels + channel : frame] = value
            }
        }
        return buffer
    }

    private static func writeRamp(to file: AVAudioFile, format: AVAudioFormat,
                                  seconds: Double, startingAt offset: Double) throws {
        try file.write(from: ramp(format: format, seconds: seconds, startingAt: offset))
    }

    private static func duration(of url: URL) throws -> Double {
        let reader = try AVAudioFile(forReading: url)
        return Double(reader.length) / reader.processingFormat.sampleRate
    }

    private static func firstFrames(of url: URL, count: Int) throws -> [Float] {
        let reader = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat,
                                      frameCapacity: AVAudioFrameCount(max(count, 1)))!
        try reader.read(into: buffer, frameCount: AVAudioFrameCount(max(count, 1)))
        guard let data = buffer.floatChannelData else { return [] }
        return (0..<Int(buffer.frameLength)).map { data[0][$0] }
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int) ?? -1
    }

    private static func prefixBytes(_ url: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return (try handle.read(upToCount: count)) ?? Data()
    }

    private func XCTAssertThrowsEqual(_ expression: @autoclosure () throws -> URL,
                                      _ expected: WAVContextClip.ClipError,
                                      file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try expression()
            XCTFail("预期抛出 \(expected)", file: file, line: line)
        } catch let error as WAVContextClip.ClipError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("抛出了未预期的错误：\(error)", file: file, line: line)
        }
    }

    // MARK: - 静音闸门（DigitalSilenceGate）

    /// 判静音会**直接跳过转写**（见 SpeechPipeline 的调用点），所以判错的代价是丢真实语音。
    /// 这里钉住它的边界：只有"整段都是 0 且有限"才算静音；NaN、极小非零信号、
    /// 任意声道的信号、以及它无法分析的格式，都必须判**不静音**。
    func testSilenceGateOnlyReportsSilenceWhenItCanProveIt() throws {
        let allZero = try writeFloatWav(name: "silent.wav", perChannel: [[Float](repeating: 0, count: 4_096)])
        XCTAssertTrue(try DigitalSilenceGate.isSilent(allZero), "全 0 应判静音")

        var tiny = [Float](repeating: 0, count: 4_096)
        tiny[512] = 1e-4
        let tinyURL = try writeFloatWav(name: "tiny.wav", perChannel: [tiny])
        XCTAssertFalse(try DigitalSilenceGate.isSilent(tinyURL), "1e-4 的信号不该被当成静音")

        let belowThreshold = try writeFloatWav(name: "below.wav",
                                               perChannel: [[Float](repeating: 1e-6, count: 4_096)])
        XCTAssertTrue(try DigitalSilenceGate.isSilent(belowThreshold), "远低于阈值的底噪仍算静音")

        var withNaN = [Float](repeating: 0, count: 4_096)
        withNaN[100] = .nan
        let nanURL = try writeFloatWav(name: "nan.wav", perChannel: [withNaN])
        XCTAssertFalse(try DigitalSilenceGate.isSilent(nanURL), "NaN 与任何数比较都是 false，必须靠 isFinite 拦住")

        let stereo = try writeFloatWav(name: "stereo.wav", perChannel: [
            [Float](repeating: 0, count: 4_096),
            {
                var channel = [Float](repeating: 0, count: 4_096)
                channel[10] = 0.5
                return channel
            }(),
        ])
        XCTAssertFalse(try DigitalSilenceGate.isSilent(stereo), "任一频道有信号就不算静音")
    }

    /// 16 位 PCM（应用之外常见的录音格式）也要能正确判断：AVAudioFile 会把它读成 float32，
    /// 所以闸门应当照常分析，而不是因为"不是 float32 文件"就一律放行。
    func testSilenceGateAlsoHandlesSixteenBitRecordings() throws {
        let silent = try writeInt16Wav(name: "int16-silent.wav", amplitude: 0)
        XCTAssertTrue(try DigitalSilenceGate.isSilent(silent), "全 0 的 16 位录音应判静音")

        let loud = try writeInt16Wav(name: "int16-loud.wav", amplitude: 8_000)
        XCTAssertFalse(try DigitalSilenceGate.isSilent(loud), "有信号的 16 位录音不该判静音")
    }

    @discardableResult
    private func writeFloatWav(name: String, perChannel: [[Float]]) throws -> URL {
        let channels = AVAudioChannelCount(perChannel.count)
        let frames = AVAudioFrameCount(perChannel[0].count)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
        let url = directory.appendingPathComponent(name)
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for (channel, values) in perChannel.enumerated() {
            for (index, value) in values.enumerated() {
                buffer.floatChannelData![channel][index] = value
            }
        }
        try file.write(from: buffer)
        if #available(macOS 15, *) { file.close() }
        return url
    }

    @discardableResult
    private func writeInt16Wav(name: String, amplitude: Int16 = 0) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(4_096)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        if let data = buffer.int16ChannelData {
            for index in 0..<Int(frames) {
                data[0][index] = amplitude == 0 ? 0 : (index % 256 == 0 ? amplitude : 0)
            }
        }
        try file.write(from: buffer)
        if #available(macOS 15, *) { file.close() }
        return url
    }
}
