import AppKit
import AVFoundation
import CoreMedia
import XCTest
@testable import LiveLingo

private final class HealthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ProcessInfo.processInfo.systemUptime
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

private func healthPCM(_ format: AVAudioFormat, frames: Int, value: Float) -> AVAudioPCMBuffer {
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames)))!
    pcm.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<Int(format.channelCount) {
        for frame in 0..<frames { pcm.floatChannelData![channel][frame] = value }
    }
    return pcm
}

private func healthSample(_ pcm: AVAudioPCMBuffer) throws -> CMSampleBuffer {
    var asbd = pcm.format.streamDescription.pointee
    var description: CMAudioFormatDescription?
    XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &description), noErr)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(pcm.format.sampleRate)),
        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: Int(pcm.frameLength),
        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
        sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
    let result = try XCTUnwrap(sample)
    XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
    XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
    return result
}

private final class HealthSource: SystemAudioCaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var input: OwnedAudioCaptureBuffer?
    private var onError: (@Sendable () -> Void)?
    private var stops = 0
    let shouldFail: Bool
    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }
    func start(input: OwnedAudioCaptureBuffer, onError: @escaping @Sendable () -> Void) async throws {
        lock.withLock { self.input = input; self.onError = onError }
        if shouldFail { throw NSError(domain: "Private error text must not enter health diagnostics", code: 9) }
    }
    func stop() async { lock.withLock { stops += 1 } }
    var buffer: OwnedAudioCaptureBuffer { lock.withLock { input! } }
    var stopCount: Int { lock.withLock { stops } }
    func fail() { lock.withLock { onError }?() }
    func send(frames: Int = 4_800, value: Float = 0.25, end: TimeInterval,
              format: AVAudioFormat? = nil) -> OwnedAudioCaptureBuffer.Submission {
        buffer.submit(healthPCM(format ?? buffer.format, frames: frames, value: value), observedEnd: end)
    }
}

private final class HealthSources: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HealthSource] = []
    private var failures = 0
    var count: Int { lock.withLock { values.count } }
    var latest: HealthSource { lock.withLock { values.last! } }
    func failNext(_ count: Int) { lock.withLock { failures = count } }
    func make() -> any SystemAudioCaptureSource {
        lock.withLock {
            let source = HealthSource(shouldFail: failures > 0)
            if failures > 0 { failures -= 1 }
            values.append(source)
            return source
        }
    }
}

private final class HealthRoute: SystemAudioRouteMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (CaptureHealthIssue) -> Void)?
    var savedCallback: (@Sendable (CaptureHealthIssue) -> Void)? { lock.withLock { callback } }
    func start(onChange: @escaping @Sendable (CaptureHealthIssue) -> Void) { lock.withLock { callback = onChange } }
    func stop() { lock.withLock { callback = nil } }
    func change(_ issue: CaptureHealthIssue = .deviceChanged) { savedCallback?(issue) }
}

private final class HealthDelay: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    private var hook: (@Sendable () -> Void)?
    var delays: [TimeInterval] { lock.withLock { values } }
    func setHook(_ value: (@Sendable () -> Void)?) { lock.withLock { hook = value } }
    func wait(_ seconds: TimeInterval) async throws {
        let callback = lock.withLock { values.append(seconds); return hook }
        callback?()
        try Task.checkCancellation()
    }
}

private final class HealthEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CaptureHealthNotice] = []
    private var missing: [CaptureGap] = []
    private var errors: [String] = []
    let failed = XCTestExpectation(description: "Capture fails after bounded recovery")
    var notices: [CaptureHealthNotice] { lock.withLock { values } }
    var gaps: [CaptureGap] { lock.withLock { missing } }
    var failures: [String] { lock.withLock { errors } }
    func consume(_ event: SpeechPipeline.Event) {
        if case .captureHealth(let notice) = event { lock.withLock { values.append(notice) } }
        if case .captureGap(let gap) = event { lock.withLock { missing.append(gap) } }
        if case .failure(let message) = event {
            lock.withLock { errors.append(message) }
            failed.fulfill()
        }
    }
}

private final class HealthMic: NSObject, MicrophoneCaptureEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var input: OwnedAudioCaptureBuffer?
    private var running = false
    private var starts = 0
    var notificationObject: AnyObject { self }
    let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    var isRunning: Bool { lock.withLock { running } }
    var startCount: Int { lock.withLock { starts } }
    var buffer: OwnedAudioCaptureBuffer { lock.withLock { input! } }
    func installTap(format: AVAudioFormat, input: OwnedAudioCaptureBuffer) throws { lock.withLock { self.input = input } }
    func removeTap() { lock.withLock { input = nil } }
    func prepare() {}
    func start() throws { lock.withLock { starts += 1; running = true } }
    func pause() { lock.withLock { running = false } }
    func stop() { lock.withLock { running = false } }
}

private final class HealthMicScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@Sendable () -> Void] = []
    var count: Int { lock.withLock { operations.count } }
    func schedule(_ operation: @escaping @Sendable () -> Void) { lock.withLock { operations.append(operation) } }
    func runNext() { lock.withLock { operations.removeFirst() }() }
}

final class CaptureHealthTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        let pipeline: SpeechPipeline
        let clock: HealthClock
        let sources: HealthSources
        let route: HealthRoute
        let delay: HealthDelay
        let events: HealthEvents
        let recording: URL
        let id: UUID
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureHealth-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func start() async throws -> Fixture {
        let clock = HealthClock(), sources = HealthSources(), route = HealthRoute()
        let delay = HealthDelay(), events = HealthEvents(), id = UUID()
        let recording = try directory().appendingPathComponent("recording.wav")
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "The synthetic classroom audio remains complete across capture recovery." },
            enableAudioAnalysis: false, captureSleepNotificationCenter: NotificationCenter(),
            enableMicrophoneWatchdog: false, enableCaptureHealthWatchdog: false,
            captureUptime: { clock.now }, systemAudioSourceFactory: sources.make,
            systemAudioRouteMonitor: route, systemAudioRecoveryDelay: delay.wait)
        try await pipeline.start(inputMode: .systemAudio, recordingURL: recording, sessionID: id,
                                 eventHandler: events.consume)
        addTeardownBlock { await pipeline.stop() }
        return Fixture(pipeline: pipeline, clock: clock, sources: sources, route: route, delay: delay,
                       events: events, recording: recording, id: id)
    }

    private func send(_ f: Fixture, seconds: TimeInterval = 0.1, value: Float = 0.25) async {
        f.clock.advance(seconds)
        XCTAssertEqual(f.sources.latest.send(frames: Int(48_000 * seconds), value: value, end: f.clock.now), .accepted)
        await f.sources.latest.buffer.drain()
        await f.pipeline.drainSyntheticCaptureHealthEvents()
    }

    private func check(_ f: Fixture, after seconds: TimeInterval) async {
        f.clock.advance(seconds)
        f.pipeline.checkSyntheticCaptureHealth(now: f.clock.now)
        await f.pipeline.drainSyntheticCaptureHealthEvents()
    }

    private func diagnostics(_ f: Fixture) throws -> [[String: Any]] {
        let url = f.recording.deletingLastPathComponent().appendingPathComponent(CaptureHealthDiagnostics.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Data(contentsOf: url).split(separator: 0x0a).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }

    private func verifyAudio(_ f: Fixture, values: [(Int, Float)]) throws {
        let file = try AVAudioFile(forReading: f.recording)
        let count = values.reduce(0) { $0 + $1.0 }
        XCTAssertEqual(file.length, Int64(count))
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count))!
        try file.read(into: pcm)
        for channel in 0..<Int(file.processingFormat.channelCount) {
            var offset = 0
            for (frames, value) in values {
                for frame in offset..<(offset + frames) {
                    XCTAssertEqual(pcm.floatChannelData![channel][frame], value, accuracy: 1e-8)
                }
                offset += frames
            }
        }
    }

    func testStartupWithoutCallbacksWarnsAtFiveSecondsAndClearsOnDelivery() async throws {
        let f = try await start()
        await check(f, after: 4.99)
        XCTAssertTrue(f.events.notices.isEmpty)
        XCTAssertTrue(try diagnostics(f).isEmpty)
        await check(f, after: 0.02)
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.noCallbacks.message(for: .systemAudio))
        XCTAssertEqual(try diagnostics(f).first?["callbacks"] as? Int, 0)
        await check(f, after: 60)
        XCTAssertEqual(f.events.notices.count, 1, "An unchanged warning must not spam events or disk")
        XCTAssertEqual(f.sources.count, 1, "An idle playback source is not proof that capture needs restarting")
        XCTAssertEqual(f.sources.latest.stopCount, 0)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        XCTAssertTrue(f.delay.delays.isEmpty)
        XCTAssertTrue(f.events.failures.isEmpty)
        await send(f)
        XCTAssertNil(f.events.notices.last?.message)
        await f.pipeline.stop()
        try verifyAudio(f, values: [(4_800, 0.25)])
    }

    func testContinuousDigitalSilenceWarnsOnlyAfterFifteenSeconds() async throws {
        let f = try await start()
        for _ in 0..<14 { await send(f, seconds: 1, value: 0) }
        XCTAssertTrue(f.events.notices.isEmpty)
        await send(f, seconds: 1, value: 0)
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.digitalSilence.message(for: .systemAudio))
        for _ in 0..<3 { await send(f, seconds: 1, value: 0) }
        XCTAssertEqual(f.events.notices.count, 1)
        XCTAssertEqual(f.sources.count, 1, "Digital silence alone must not consume recovery attempts")
        XCTAssertEqual(f.sources.latest.stopCount, 0)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        XCTAssertTrue(f.delay.delays.isEmpty)
        XCTAssertTrue(f.events.failures.isEmpty)
        await send(f, value: 1e-6)
        XCTAssertNil(f.events.notices.last?.message)
        await f.pipeline.stop()
        try verifyAudio(f, values: [(18 * 48_000, 0), (4_800, 1e-6)])
    }

    func testBelowTinyThresholdCountsAsDigitalSilence() async throws {
        let f = try await start()
        for _ in 0..<15 { await send(f, seconds: 1, value: 1e-10) }
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.digitalSilence.message(for: .systemAudio))
    }

    func testQuietButNonzeroAudioRemainsHealthyWithoutDiagnostics() async throws {
        let f = try await start()
        for _ in 0..<18 {
            await send(f, seconds: 1, value: 1e-7)
            await check(f, after: 0)
        }
        XCTAssertTrue(f.events.notices.isEmpty)
        XCTAssertTrue(try diagnostics(f).isEmpty)
        XCTAssertEqual(f.sources.count, 1)
        await f.pipeline.stop()
        try verifyAudio(f, values: [(18 * 48_000, 1e-7)])
    }

    func testSilenceMustBeContinuousAcrossWallAndAudioTime() async throws {
        let f = try await start()
        for _ in 0..<10 { await send(f, seconds: 1, value: 0) }
        await send(f, value: 0.01)
        for _ in 0..<10 { await send(f, seconds: 1, value: 0) }
        XCTAssertTrue(f.events.notices.isEmpty)
        var health = CaptureHealthState(mode: .systemAudio, startedAt: 0)
        for _ in 0..<30 { XCTAssertNil(health.observe(peak: 0, duration: 1, start: 0, end: 1)) }
    }

    func testFreshEmptyCallbacksWarnAboutMissingDataWithoutRestart() async throws {
        let f = try await start()
        for _ in 0..<5 {
            f.clock.advance(1)
            XCTAssertEqual(f.sources.latest.send(frames: 0, end: f.clock.now), .accepted)
            f.pipeline.checkSyntheticCaptureHealth(now: f.clock.now)
        }
        await f.pipeline.drainSyntheticCaptureHealthEvents()
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.noData.message(for: .systemAudio))
        XCTAssertEqual(try diagnostics(f).first?["callbacks"] as? Int, 5)
        XCTAssertEqual(try diagnostics(f).first?["frames"] as? Int, 0)
        XCTAssertEqual(f.sources.count, 1)
        XCTAssertEqual(f.sources.latest.stopCount, 0)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        XCTAssertTrue(f.delay.delays.isEmpty)
        XCTAssertTrue(f.events.failures.isEmpty)
        await send(f, value: 0)
        XCTAssertNil(f.events.notices.last?.message)
    }

    func testRuntimeCallbackInterruptionOnlyWarnsAndKeepsEverySampleOnTheSameInput() async throws {
        let f = try await start()
        let old = f.sources.latest
        f.clock.advance(0.1)
        XCTAssertEqual(old.send(end: f.clock.now), .accepted) // deliberately not drained by the test
        await check(f, after: 2.99)
        XCTAssertTrue(f.events.notices.isEmpty)
        await check(f, after: 0.02)
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(f.sources.count, 1)
        XCTAssertTrue(f.sources.latest === old)
        XCTAssertEqual(old.stopCount, 0)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        XCTAssertTrue(f.pipeline.transcriptionWork().isEmpty, "A callback gap must not rotate the current chunk")
        XCTAssertTrue(f.events.gaps.isEmpty)
        XCTAssertTrue(f.events.failures.isEmpty)
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.callbackInterrupted.message(for: .systemAudio))
        XCTAssertTrue(f.delay.delays.isEmpty)
        await send(f, value: 0.5)
        XCTAssertNil(f.events.notices.last?.message)
        XCTAssertEqual(old.buffer.pendingFrames, 0)
        await f.pipeline.stop()
        try verifyAudio(f, values: [(4_800, 0.25), (4_800, 0.5)])
        XCTAssertEqual(f.pipeline.transcriptionWork().map(\.startFrame), [0])
        XCTAssertEqual(f.pipeline.transcriptionWork().map(\.endFrame), [9_600])
    }

    func testStreamErrorWithFailedReopensUsesBackoffAndStopsAtThreeAttempts() async throws {
        let f = try await start()
        await send(f)
        f.sources.failNext(10)
        f.sources.latest.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        await fulfillment(of: [f.events.failed], timeout: 3)
        XCTAssertEqual(f.sources.count, 4)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 3)
        XCTAssertEqual(f.delay.delays, [0.25, 0.5, 1])
        XCTAssertEqual(f.events.failures.count, 1)
        XCTAssertEqual(try diagnostics(f).filter { ($0["category"] as? String) == "system_recovery_attempt" }.count, 3)
        await f.pipeline.stop()
        try verifyAudio(f, values: [(4_800, 0.25)])
    }

    func testSuccessfulReopensWithoutDeliveryDoNotSpendOrRenewRecoveryBudget() async throws {
        let f = try await start()
        await send(f)
        for attempt in 1...3 {
            f.sources.latest.fail()
            await f.pipeline.waitForSyntheticSystemRecovery()
            XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, attempt)
            let reopened = f.sources.latest
            await check(f, after: 5.01)
            XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.noCallbacks.message(for: .systemAudio))
            await check(f, after: 60)
            XCTAssertTrue(f.sources.latest === reopened)
            XCTAssertEqual(reopened.stopCount, 0)
            XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, attempt)
            XCTAssertTrue(f.events.failures.isEmpty)
        }
        XCTAssertEqual(f.sources.count, 4)
        XCTAssertEqual(f.delay.delays, [0.25, 0.5, 1])
        let current = f.sources.latest
        let chunks = f.pipeline.transcriptionWork().count
        let gaps = f.events.gaps.count
        current.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.recoveryLimited.message(for: .systemAudio))
        XCTAssertEqual(f.sources.count, 4)
        XCTAssertEqual(current.stopCount, 0, "A spent budget must preserve the attached source")
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 3)
        XCTAssertEqual(f.pipeline.transcriptionWork().count, chunks)
        XCTAssertEqual(f.events.gaps.count, gaps)
        XCTAssertTrue(f.events.failures.isEmpty)
        await send(f, value: 0.5)
        XCTAssertNil(f.events.notices.last?.message)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 3, "A brief callback must not renew the budget")
        await f.pipeline.stop()
        try verifyAudio(f, values: [(4_800, 0.25), (4_800, 0.5)])
    }

    func testDeviceChangeOnlyWarnsAndKeepsTheNormalStreamOpen() async throws {
        let f = try await start()
        await send(f)
        let current = f.sources.latest
        f.route.change()
        await f.pipeline.waitForSyntheticSystemRouteNotice()
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.deviceChanged.message(for: .systemAudio))
        XCTAssertEqual(f.sources.count, 1)
        XCTAssertTrue(f.sources.latest === current)
        XCTAssertEqual(current.stopCount, 0)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        XCTAssertTrue(f.delay.delays.isEmpty)
        XCTAssertTrue(f.pipeline.transcriptionWork().isEmpty)
        XCTAssertTrue(f.events.gaps.isEmpty)
        XCTAssertTrue(f.events.failures.isEmpty)
        await send(f, value: 0.5)
        XCTAssertNil(f.events.notices.last?.message)
        await f.pipeline.stop()
        try verifyAudio(f, values: [(4_800, 0.25), (4_800, 0.5)])
    }

    func testFormatChangeRecoversWithoutDroppingAlreadyAcceptedPCM() async throws {
        let f = try await start()
        let old = f.sources.latest
        f.clock.advance(0.1)
        XCTAssertEqual(old.send(end: f.clock.now), .accepted)
        let foreign = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        XCTAssertEqual(old.send(end: f.clock.now, format: foreign), .overflow)
        await old.buffer.drain() // delivers the format-change event, not a device call
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.formatChanged.message(for: .systemAudio))
        XCTAssertEqual(f.sources.count, 2)
        XCTAssertTrue(f.events.failures.isEmpty)
        await send(f, value: 0.5)
        await f.pipeline.stop()
        try verifyAudio(f, values: [(4_800, 0.25), (4_800, 0.5)])
    }

    func testScreenCaptureKitSampleBufferFormatChangeUsesTheSameRecovery() async throws {
        let f = try await start()
        let old = f.sources.latest.buffer
        f.clock.advance(0.1)
        let normal = try healthSample(healthPCM(old.format, frames: 4_800, value: 0.25))
        XCTAssertEqual(old.submit(normal, observedEnd: f.clock.now), .accepted)
        f.clock.advance(0.1)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let changed = try healthSample(healthPCM(format, frames: 4_410, value: 0.9))
        XCTAssertEqual(old.submit(changed, observedEnd: f.clock.now), .overflow)
        await old.drain()
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(old.healthSnapshot.callbacks, 2)
        XCTAssertEqual(old.healthSnapshot.frames, 4_800)
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.formatChanged.message(for: .systemAudio))
        await send(f, value: 0.5)
        await f.pipeline.stop()
        try verifyAudio(f, values: [(4_800, 0.25), (4_800, 0.5)])
    }

    func testHardwareFormatNotificationOnlyWarnsAndKeepsTheNormalStreamOpen() async throws {
        let f = try await start()
        await send(f)
        f.route.change(.formatChanged)
        await f.pipeline.waitForSyntheticSystemRouteNotice()
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.formatChanged.message(for: .systemAudio))
        XCTAssertTrue(try diagnostics(f).contains { ($0["category"] as? String) == "system_format_changed" })
        XCTAssertEqual(f.sources.count, 1)
        XCTAssertEqual(f.sources.latest.stopCount, 0)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        XCTAssertTrue(f.delay.delays.isEmpty)
        XCTAssertTrue(f.pipeline.transcriptionWork().isEmpty)
        XCTAssertTrue(f.events.gaps.isEmpty)
        XCTAssertTrue(f.events.failures.isEmpty)
        await send(f)
        XCTAssertNil(f.events.notices.last?.message)
    }

    func testStopAndOldRouteNotificationCannotRestartCapture() async throws {
        let f = try await start()
        await send(f)
        let callback = try XCTUnwrap(f.route.savedCallback)
        await f.pipeline.stop()
        callback(.deviceChanged)
        f.sources.latest.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(f.sources.count, 1)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        XCTAssertTrue(f.events.notices.isEmpty)
    }

    func testDelegateStreamErrorRecoversAndOldDelegateCannotRestartNewSource() async throws {
        let f = try await start()
        await send(f)
        let old = f.sources.latest
        old.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        old.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(f.sources.count, 2)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 1)
        XCTAssertEqual(old.stopCount, 1)
        XCTAssertEqual(f.sources.latest.stopCount, 0)
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.streamError.message(for: .systemAudio))
    }

    func testPauseIgnoresElapsedTimeAndDoesNotQueueDeviceRecoveryOnResume() async throws {
        let f = try await start()
        f.pipeline.pause()
        f.route.change()
        await f.pipeline.waitForSyntheticSystemRouteNotice()
        await check(f, after: 60)
        XCTAssertTrue(f.events.notices.isEmpty)
        XCTAssertEqual(f.sources.count, 1)
        try f.pipeline.resume()
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(f.sources.count, 1)
        XCTAssertEqual(f.sources.latest.stopCount, 0)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        XCTAssertTrue(f.events.notices.isEmpty)
        XCTAssertTrue(f.delay.delays.isEmpty)
        await send(f)
        XCTAssertNil(f.events.notices.last?.message)
    }

    func testPauseDuringStreamErrorBackoffDoesNotSpendAttemptOrPreventResume() async throws {
        let f = try await start()
        await send(f)
        f.delay.setHook { f.pipeline.pause() }
        f.sources.latest.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(f.sources.count, 1)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        XCTAssertTrue(f.events.failures.isEmpty)
        f.delay.setHook(nil)
        try f.pipeline.resume()
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(f.sources.count, 2)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 1)
        XCTAssertEqual(f.delay.delays, [0.25, 0.25])
        await send(f, value: 0.5)
        await f.pipeline.stop()
        try verifyAudio(f, values: [(4_800, 0.25), (4_800, 0.5)])
    }

    func testDiagnosticsHaveOnlyFixedCategoriesTimesAndCounts() async throws {
        let f = try await start()
        await send(f)
        f.sources.failNext(1)
        f.route.change()
        await f.pipeline.waitForSyntheticSystemRouteNotice()
        f.sources.latest.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        await send(f)
        let rows = try diagnostics(f)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(rows.filter { ($0["category"] as? String) == "system_recovery_attempt" }.count, 2)
        for row in rows {
            XCTAssertEqual(Set(row.keys), ["category", "time", "callbacks", "frames", "recoveryAttempts"])
            XCTAssertTrue(["system_device_changed", "system_stream_error", "system_recovery_attempt", "system_delivery_resumed"].contains(row["category"] as? String ?? ""))
            XCTAssertNotNil(row["time"] as? Double)
            XCTAssertNotNil(row["callbacks"] as? Int)
            XCTAssertNotNil(row["frames"] as? Int)
            XCTAssertNotNil(row["recoveryAttempts"] as? Int)
        }
    }

    func testHealthyAudioLeavesExistingOutputAndDiagnosticsUntouched() async throws {
        let f = try await start()
        for _ in 0..<18 { await send(f, seconds: 1) }
        await f.pipeline.stop()
        XCTAssertTrue(f.events.notices.isEmpty)
        XCTAssertTrue(f.events.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.recording.deletingLastPathComponent()
            .appendingPathComponent(CaptureHealthDiagnostics.fileName).path))
        try verifyAudio(f, values: [(18 * 48_000, 0.25)])
    }

    func testSyntheticReplayWithoutDeviceMonitoringNeverProducesHealthEvents() async throws {
        let directory = try directory(), events = HealthEvents()
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Synthetic replay." }, enableAudioAnalysis: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let recording = directory.appendingPathComponent("recording.wav")
        let input = try await pipeline.startSyntheticCapture(format: format, recordingURL: recording,
            sessionID: UUID(), inputMode: .systemAudio, eventHandler: events.consume)
        for _ in 0..<20 {
            XCTAssertEqual(input.submit(healthPCM(format, frames: 16_000, value: 0)), .accepted)
            await input.drain()
        }
        pipeline.checkSyntheticCaptureHealth(now: ProcessInfo.processInfo.systemUptime + 60)
        await pipeline.stop()
        XCTAssertTrue(events.notices.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(CaptureHealthDiagnostics.fileName).path))
        XCTAssertEqual(try AVAudioFile(forReading: recording).length, 320_000)
    }

    func testMicrophoneNoCallbacksHasVisibleNoticeAndClearsAfterRecoveryAudio() async throws {
        let clock = HealthClock(), engine = HealthMic(), scheduler = HealthMicScheduler(), events = HealthEvents()
        let recording = try directory().appendingPathComponent("recording.wav")
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Synthetic microphone." }, enableAudioAnalysis: false,
            captureSleepNotificationCenter: NotificationCenter(), microphoneEngineFactory: { engine },
            microphoneNotifications: NotificationCenter(), microphoneRecoveryScheduler: scheduler.schedule,
            enableMicrophoneWatchdog: false, enableCaptureHealthWatchdog: false, captureUptime: { clock.now })
        try await pipeline.start(inputMode: .microphone, recordingURL: recording, sessionID: UUID(), eventHandler: events.consume)
        clock.advance(4.99)
        pipeline.checkSyntheticCaptureHealth(now: clock.now)
        XCTAssertEqual(scheduler.count, 0)
        clock.advance(0.02)
        pipeline.checkSyntheticCaptureHealth(now: clock.now)
        await pipeline.drainSyntheticCaptureHealthEvents()
        XCTAssertEqual(events.notices.last?.message, CaptureHealthIssue.noCallbacks.message(for: .microphone))
        XCTAssertEqual(scheduler.count, 1)
        scheduler.runNext()
        clock.advance(0.1)
        XCTAssertEqual(engine.buffer.submit(healthPCM(engine.outputFormat, frames: 1_600, value: 0), observedEnd: clock.now), .accepted)
        await engine.buffer.drain()
        await pipeline.drainSyntheticCaptureHealthEvents()
        XCTAssertNil(events.notices.last?.message, "Valid silent microphone PCM is healthy delivery")
        XCTAssertEqual(engine.startCount, 2)
        await pipeline.stop()
        XCTAssertEqual(try AVAudioFile(forReading: recording).length, 1_600)
    }

    @MainActor
    func testNoticeUsesExistingRecordingStatusAndDoesNotReplaceOtherNotices() async throws {
        let directory = try directory()
        let suite = "LiveLingo-Test-\(UUID().uuidString)"
        let preferenceCleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("review.json"), observeSleep: false,
            diagnostics: .disabled) { _, _, _, _, _ in throw CancellationError() }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
        addTeardownBlock {
            try await TestTaskLifetime.stop(model, queue: queue)
            try preferenceCleanup.remove()
        }
        model.loadPresentationForTesting(phase: .recording, evidence: [], notice: "已有课堂提示")
        let id = model.captureHealthSessionIDForTesting
        let warning = CaptureHealthIssue.digitalSilence.message(for: .systemAudio)
        model.receiveTranscriptionNoticeForTesting(.captureHealth(.init(sessionID: UUID(), message: warning)))
        XCTAssertEqual(model.errorMessage, "已有课堂提示")
        model.receiveTranscriptionNoticeForTesting(.captureHealth(.init(sessionID: id, message: warning)))
        XCTAssertEqual(model.errorMessage, warning)
        XCTAssertTrue(model.isRecording)
        model.receiveTranscriptionNoticeForTesting(.captureHealth(.init(sessionID: id, message: nil)))
        XCTAssertEqual(model.errorMessage, "已有课堂提示")
    }
}
