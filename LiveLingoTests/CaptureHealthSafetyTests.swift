import AVFoundation
import CoreMedia
import XCTest
@testable import LiveLingo

private final class SafetyClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_000
    var now: TimeInterval { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

private final class SafetyTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var values: [String] { lock.withLock { events } }
    func add(_ event: String) { lock.withLock { events.append(event) } }
}

private func safetyPCM(_ format: AVAudioFormat, frames: Int = 4_800, values: [Float] = [0.25]) -> AVAudioPCMBuffer {
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames)))!
    pcm.frameLength = AVAudioFrameCount(frames)
    for channel in 0..<Int(format.channelCount) {
        for frame in 0..<frames { pcm.floatChannelData![channel][frame] = values[min(channel, values.count - 1)] }
    }
    return pcm
}

private func safetySample(_ pcm: AVAudioPCMBuffer, ready: Bool = true) throws -> CMSampleBuffer {
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
    if ready {
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
    }
    return result
}

private final class SafetySource: SystemAudioCaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var input: OwnedAudioCaptureBuffer?
    private var onError: (@Sendable () -> Void)?
    private var stops = 0
    let failsToStart: Bool
    var onStart: (@Sendable (OwnedAudioCaptureBuffer) -> Void)?
    var onStop: (@Sendable (OwnedAudioCaptureBuffer) -> Void)?
    init(failsToStart: Bool) { self.failsToStart = failsToStart }
    var buffer: OwnedAudioCaptureBuffer { lock.withLock { input! } }
    var stopCount: Int { lock.withLock { stops } }
    func start(input: OwnedAudioCaptureBuffer, onError: @escaping @Sendable () -> Void) async throws {
        lock.withLock { self.input = input; self.onError = onError }
        onStart?(input)
        if failsToStart { throw NSError(domain: "SyntheticCaptureFailure", code: 1) }
    }
    func stop() async {
        let first = lock.withLock { stops += 1; return stops == 1 }
        if first { onStop?(buffer) }
    }
    func fail() { lock.withLock { onError }?() }
}

private final class SafetySources: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SafetySource] = []
    private var failures = 0
    var configure: (@Sendable (SafetySource, Int) -> Void)?
    var count: Int { lock.withLock { values.count } }
    var latest: SafetySource { lock.withLock { values.last! } }
    func failNext(_ count: Int) { lock.withLock { failures = count } }
    func make() -> any SystemAudioCaptureSource {
        let pair = lock.withLock {
            let source = SafetySource(failsToStart: failures > 0)
            failures = max(0, failures - 1)
            let index = values.count
            values.append(source)
            return (source, index)
        }
        configure?(pair.0, pair.1)
        return pair.0
    }
}

private final class SafetyRoute: SystemAudioRouteMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (CaptureHealthIssue) -> Void)?
    private var starts = 0
    private var stops = 0
    var savedCallback: (@Sendable (CaptureHealthIssue) -> Void)? { lock.withLock { callback } }
    var counts: (starts: Int, stops: Int) { lock.withLock { (starts, stops) } }
    func start(onChange: @escaping @Sendable (CaptureHealthIssue) -> Void) {
        lock.withLock { starts += 1; callback = onChange }
    }
    func stop() { lock.withLock { stops += 1; callback = nil } }
    func change(_ issue: CaptureHealthIssue) { savedCallback?(issue) }
}

private final class SafetyEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [CaptureHealthNotice] = []
    private var missing: [CaptureGap] = []
    private var errors: [String] = []
    private var gapHook: (@Sendable () -> Void)?
    var notices: [CaptureHealthNotice] { lock.withLock { updates } }
    var gaps: [CaptureGap] { lock.withLock { missing } }
    var failures: [String] { lock.withLock { errors } }
    func onGap(_ action: @escaping @Sendable () -> Void) { lock.withLock { gapHook = action } }
    func consume(_ event: SpeechPipeline.Event) {
        switch event {
        case .captureHealth(let notice): lock.withLock { updates.append(notice) }
        case .captureGap(let gap):
            let hook = lock.withLock { missing.append(gap); return gapHook }
            hook?()
        case .failure(let error): lock.withLock { errors.append(error) }
        default: break
        }
    }
}

/// Cancellation-aware, manually advanced sleeps exercise the real task loop,
/// including stop while its next one-second check is waiting.
private final class SafetySleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var cancelled: Set<UUID> = []
    private var intervals: [TimeInterval] = []
    private var cancellations = 0
    var delays: [TimeInterval] { lock.withLock { intervals } }
    var pending: Int { lock.withLock { requests.count } }
    var cancelCount: Int { lock.withLock { cancellations } }
    func wait(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let reject = lock.withLock {
                    intervals.append(seconds)
                    if cancelled.remove(id) != nil || Task.isCancelled { return true }
                    requests.append((id, continuation))
                    return false
                }
                if reject { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = self.lock.withLock {
                self.cancellations += 1
                guard let index = self.requests.firstIndex(where: { $0.0 == id }) else {
                    self.cancelled.insert(id)
                    return nil as CheckedContinuation<Void, Error>?
                }
                return self.requests.remove(at: index).1
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
    func next() {
        let continuation = lock.withLock { requests.isEmpty ? nil : requests.removeFirst().1 }
        continuation?.resume()
    }
}

private final class SafetyBackoff: @unchecked Sendable {
    private let lock = NSLock()
    private var intervals: [TimeInterval] = []
    private var hook: (@Sendable () -> Void)?
    let clock: SafetyClock
    init(clock: SafetyClock) { self.clock = clock }
    var delays: [TimeInterval] { lock.withLock { intervals } }
    func setHook(_ hook: (@Sendable () -> Void)?) { lock.withLock { self.hook = hook } }
    func wait(_ seconds: TimeInterval) async throws {
        let action = lock.withLock { intervals.append(seconds); return hook }
        clock.advance(seconds)
        action?()
        try Task.checkCancellation()
    }
}

private final class SafetyPipelineBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: SpeechPipeline?
    var pipeline: SpeechPipeline? { lock.withLock { value } }
    func set(_ pipeline: SpeechPipeline) { lock.withLock { value = pipeline } }
}

private final class SafetyMic: NSObject, MicrophoneCaptureEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var input: OwnedAudioCaptureBuffer?
    private var format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var running = false
    private var starts = 0
    private var failures = 0
    var notificationObject: AnyObject { self }
    var outputFormat: AVAudioFormat { lock.withLock { format } }
    var isRunning: Bool { lock.withLock { running } }
    var startCount: Int { lock.withLock { starts } }
    var buffer: OwnedAudioCaptureBuffer { lock.withLock { input! } }
    func changeStoppedFormat(to rate: Double = 16_000) {
        lock.withLock { running = false; format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)! }
    }
    func failNextStarts(_ count: Int) { lock.withLock { failures = count } }
    func installTap(format: AVAudioFormat, input: OwnedAudioCaptureBuffer) throws { lock.withLock { self.input = input } }
    func removeTap() { lock.withLock { input = nil } }
    func prepare() {}
    func start() throws {
        let fail = lock.withLock { starts += 1; if failures > 0 { failures -= 1; return true }; running = true; return false }
        if fail { throw NSError(domain: "SyntheticMicFailure", code: 1) }
    }
    func pause() { lock.withLock { running = false } }
    func stop() { lock.withLock { running = false } }
}

private final class SafetyMicScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [@Sendable () -> Void] = []
    private var intervals: [TimeInterval] = []
    var delays: [TimeInterval] { lock.withLock { intervals } }
    var pending: Int { lock.withLock { operations.count } }
    func schedule(_ seconds: TimeInterval, _ operation: @escaping @Sendable () -> Void) {
        lock.withLock { intervals.append(seconds); operations.append(operation) }
    }
    func next() {
        let operation = lock.withLock { operations.isEmpty ? nil : operations.removeFirst() }
        operation?()
    }
}

final class CaptureHealthSafetyTests: XCTestCase, @unchecked Sendable {
    private struct Fixture {
        let pipeline: SpeechPipeline
        let clock: SafetyClock
        let sources: SafetySources
        let route: SafetyRoute
        let backoff: SafetyBackoff
        let events: SafetyEvents
        let recording: URL
        let id: UUID
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureSafety-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func start(sources: SafetySources = SafetySources(), beforeWrite: (@Sendable () throws -> Void)? = nil,
                       watchdog: SafetySleeper? = nil, routeSleep: SafetySleeper? = nil,
                       recoverySleep: SafetySleeper? = nil) async throws -> Fixture {
        let clock = SafetyClock(), route = SafetyRoute(), events = SafetyEvents(), id = UUID()
        let backoff = SafetyBackoff(clock: clock)
        let recording = try directory().appendingPathComponent("recording.wav")
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Synthetic capture remains complete after a reported stream error." },
            beforeAudioWrite: beforeWrite, enableAudioAnalysis: false, captureSleepNotificationCenter: NotificationCenter(),
            enableMicrophoneWatchdog: false, enableCaptureHealthWatchdog: watchdog != nil,
            captureUptime: { clock.now }, systemAudioSourceFactory: sources.make, systemAudioRouteMonitor: route,
            systemAudioRecoveryDelay: { seconds in
                if let recoverySleep { try await recoverySleep.wait(seconds) } else { try await backoff.wait(seconds) }
            }, captureHealthCheckDelay: { seconds in try await watchdog!.wait(seconds) },
            systemAudioRouteDelay: { seconds in if let routeSleep { try await routeSleep.wait(seconds) } })
        try await pipeline.start(inputMode: .systemAudio, recordingURL: recording, sessionID: id, eventHandler: events.consume)
        addTeardownBlock { await pipeline.stop() }
        return Fixture(pipeline: pipeline, clock: clock, sources: sources, route: route, backoff: backoff,
            events: events, recording: recording, id: id)
    }
    private func send(_ f: Fixture, elapsed: TimeInterval = 0.1, duration: TimeInterval = 0.1,
                      values: [Float] = [0.25]) async {
        f.clock.advance(elapsed)
        let input = f.sources.latest.buffer
        XCTAssertEqual(input.submit(safetyPCM(input.format, frames: Int(input.format.sampleRate * duration), values: values),
            observedEnd: f.clock.now), .accepted)
        await input.drain()
        await f.pipeline.drainSyntheticCaptureHealthEvents()
    }
    private func check(_ f: Fixture, after seconds: TimeInterval) async {
        f.clock.advance(seconds)
        f.pipeline.checkSyntheticCaptureHealth(now: f.clock.now)
        await f.pipeline.drainSyntheticCaptureHealthEvents()
    }
    private func eventually(_ condition: @escaping @Sendable () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < end else { XCTFail("Synthetic task did not reach the expected boundary"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    private func diagnostics(_ recording: URL) throws -> [[String: Any]] {
        let url = recording.deletingLastPathComponent().appendingPathComponent(CaptureHealthDiagnostics.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Data(contentsOf: url).split(separator: 0x0a).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }
    private func verifyAudio(_ recording: URL, _ runs: [(Int, Float)]) throws {
        let file = try AVAudioFile(forReading: recording)
        let frames = runs.reduce(0) { $0 + $1.0 }
        XCTAssertEqual(file.length, Int64(frames))
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
        try file.read(into: pcm)
        for channel in 0..<Int(pcm.format.channelCount) {
            var offset = 0
            for (count, value) in runs {
                for index in offset..<(offset + count) { XCTAssertEqual(pcm.floatChannelData![channel][index], value, accuracy: 1e-8) }
                offset += count
            }
        }
    }

    func testMidSessionCallbackGapsOnlyWarnWithoutRotationGapsOrRecovery() async throws {
        let f = try await start()
        await send(f)
        for _ in 0..<5 {
            await check(f, after: 30)
            XCTAssertEqual(f.sources.count, 1)
            XCTAssertEqual(f.sources.latest.stopCount, 0)
            XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
            XCTAssertTrue(f.pipeline.transcriptionWork().isEmpty)
            XCTAssertTrue(f.events.gaps.isEmpty)
            XCTAssertTrue(f.events.failures.isEmpty)
            await send(f)
            XCTAssertNil(f.events.notices.last?.message)
        }
        XCTAssertTrue(f.backoff.delays.isEmpty)
        XCTAssertFalse(try diagnostics(f.recording).contains { ($0["category"] as? String)?.contains("recovery") == true })
        await f.pipeline.stop()
        try verifyAudio(f.recording, [(6 * 4_800, 0.25)])
    }

    func testRouteNotificationsDebounceAndKeepTheSameHealthyStream() async throws {
        let sleeper = SafetySleeper()
        let f = try await start(routeSleep: sleeper)
        await send(f)
        for _ in 0..<8 { f.route.change(.deviceChanged) }
        f.route.change(.formatChanged)
        try await eventually { sleeper.pending == 1 }
        XCTAssertTrue(f.events.notices.isEmpty)
        f.clock.advance(0.75)
        sleeper.next()
        await f.pipeline.waitForSyntheticSystemRouteNotice()
        XCTAssertEqual(f.events.notices.count, 1)
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.formatChanged.message(for: .systemAudio))
        XCTAssertTrue(sleeper.delays.allSatisfy { $0 == 0.75 })
        XCTAssertEqual(try diagnostics(f.recording).count, 1)
        XCTAssertEqual(f.sources.count, 1)
        XCTAssertEqual(f.sources.latest.stopCount, 0)
        XCTAssertTrue(f.pipeline.transcriptionWork().isEmpty)
        XCTAssertTrue(f.events.gaps.isEmpty)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        await send(f)
        XCTAssertNil(f.events.notices.last?.message)
    }

    func testSpentBudgetKeepsCurrentSourceBeforeAnySealStopOrRotation() async throws {
        let f = try await start()
        for attempt in 1...3 {
            await send(f)
            f.sources.latest.fail()
            await f.pipeline.waitForSyntheticSystemRecovery()
            XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, attempt)
        }
        XCTAssertEqual(f.events.gaps.map(\.lastWrittenFrame), [4_800, 9_600, 14_400],
            "Different ingress identities must each retain their own gap")
        let current = f.sources.latest
        let work = f.pipeline.transcriptionWork().count
        let gaps = f.events.gaps.count
        current.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.recoveryLimited.message(for: .systemAudio))
        XCTAssertEqual(current.stopCount, 0)
        XCTAssertEqual(f.sources.count, 4)
        XCTAssertEqual(f.pipeline.transcriptionWork().count, work)
        XCTAssertEqual(f.events.gaps.count, gaps)
        XCTAssertTrue(f.events.failures.isEmpty)
        await check(f, after: 60)
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.recoveryLimited.message(for: .systemAudio))
        for _ in 0..<5 { f.route.change(.deviceChanged); await f.pipeline.waitForSyntheticSystemRouteNotice() }
        XCTAssertEqual(current.stopCount, 0)
        await send(f)
        XCTAssertNil(f.events.notices.last?.message)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 3)
        for _ in 0..<29 { await send(f, elapsed: 1, duration: 1) }
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 3)
        await send(f, elapsed: 1, duration: 1)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        current.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 1)
        XCTAssertEqual(f.backoff.delays, [0.25, 0.5, 1, 0.25])
    }

    func testSuccessfulReopenAndSilentCallbackGapsDoNotSpendOrRenewBudget() async throws {
        let f = try await start()
        await send(f)
        f.sources.latest.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        await check(f, after: 4.99)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 1)
        await check(f, after: 0.02)
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.noCallbacks.message(for: .systemAudio))
        await check(f, after: 120)
        XCTAssertEqual(f.sources.count, 2)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 1)
        XCTAssertTrue(f.events.failures.isEmpty)
    }

    func testRealErrorWithThreeFailedOpensReportsFailureAndOneGap() async throws {
        let f = try await start()
        await send(f)
        f.sources.failNext(10)
        f.sources.latest.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        try await eventually { f.events.failures.count == 1 }
        XCTAssertEqual(f.sources.count, 4)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 3)
        XCTAssertEqual(f.backoff.delays, [0.25, 0.5, 1])
        XCTAssertEqual(f.events.gaps.count, 1)
        XCTAssertEqual(f.events.gaps.first?.lastWrittenFrame, 4_800)
        XCTAssertEqual(f.events.gaps.first?.observedStart ?? 0, 1_000.1, accuracy: 1e-8)
        XCTAssertEqual(f.events.gaps.first?.observedEnd ?? 0, 1_001.85, accuracy: 1e-8)
        await f.pipeline.stop()
        try verifyAudio(f.recording, [(4_800, 0.25)])
    }

    func testPausedRouteChangesDoNotReopenAndPauseCannotRenewSystemBudget() async throws {
        let f = try await start()
        await send(f)
        f.sources.latest.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        await send(f)
        f.pipeline.pause()
        f.route.change(.deviceChanged)
        await f.pipeline.waitForSyntheticSystemRouteNotice()
        f.clock.advance(60)
        f.pipeline.checkSyntheticCaptureHealth(now: f.clock.now)
        try f.pipeline.resume()
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(f.sources.count, 2)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 1)
        XCTAssertEqual(f.sources.latest.stopCount, 0)
        XCTAssertEqual(f.events.gaps.count, 1)
        XCTAssertNil(f.events.notices.last?.message)
        await send(f)
    }

    func testSparseBurstAndInterruptedPCMDoNotRenewSystemBudget() async throws {
        let f = try await start()
        f.sources.latest.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        for _ in 0..<31 { await send(f, elapsed: 1) }
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 1)
        for _ in 0..<31 { await send(f, elapsed: 0.01, duration: 1) }
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 1)
        for _ in 0..<20 { await send(f, elapsed: 1, duration: 1) }
        await check(f, after: 3)
        for _ in 0..<11 { await send(f, elapsed: 1, duration: 1) }
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 1)
        for _ in 0..<19 { await send(f, elapsed: 1, duration: 1) }
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
    }

    func testStopAndImmediateStartCallbacksProveSealDrainAndChunkOrder() async throws {
        let sources = SafetySources(), trace = SafetyTrace(), box = SafetyPipelineBox()
        sources.configure = { source, index in
            source.onStart = { input in
                trace.add("start.\(index)")
                if index == 1 {
                    XCTAssertEqual(box.pipeline?.transcriptionWork().map(\.endFrame), [4_800])
                    trace.add("old.chunk.sealed")
                    XCTAssertEqual(input.submit(safetyPCM(input.format, values: [0.5]), observedEnd: 1_000.5), .accepted)
                    trace.add("new.submitted")
                }
            }
            source.onStop = { input in
                trace.add("stop.\(index)")
                if index == 0 {
                    XCTAssertEqual(input.submit(safetyPCM(input.format, values: [0.3]), observedEnd: 1_000.2), .closed,
                        "The old source must already be sealed when stop calls back")
                    trace.add("old.stop.rejected")
                }
            }
        }
        let f = try await start(sources: sources, beforeWrite: { trace.add("write") })
        box.set(f.pipeline)
        f.clock.advance(0.1)
        let old = f.sources.latest.buffer
        XCTAssertEqual(old.submit(safetyPCM(old.format), observedEnd: f.clock.now), .accepted)
        f.sources.latest.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        await f.sources.latest.buffer.drain()
        XCTAssertEqual(old.pendingFrames, 0)
        let sequence = trace.values
        XCTAssertLessThan(try XCTUnwrap(sequence.firstIndex(of: "old.stop.rejected")), try XCTUnwrap(sequence.firstIndex(of: "start.1")))
        XCTAssertLessThan(try XCTUnwrap(sequence.firstIndex(of: "write")), try XCTUnwrap(sequence.firstIndex(of: "start.1")))
        XCTAssertEqual(Array(sequence[try XCTUnwrap(sequence.firstIndex(of: "start.1"))...].prefix(3)),
            ["start.1", "old.chunk.sealed", "new.submitted"])
        XCTAssertEqual(f.events.gaps.count, 1)
        XCTAssertEqual(f.events.gaps.first?.lastWrittenFrame, 4_800, "An immediate start callback must not move the old gap boundary")
        XCTAssertEqual(f.events.gaps.first?.rejectedFrames, 4_800)
        XCTAssertEqual(f.events.gaps.first?.observedStart ?? 0, 1_000.1, accuracy: 1e-8)
        XCTAssertEqual(f.events.gaps.first?.observedEnd ?? 0, 1_000.35, accuracy: 1e-8)
        await f.pipeline.stop()
        XCTAssertEqual(f.events.gaps.count, 1)
        try verifyAudio(f.recording, [(4_800, 0.25), (4_800, 0.5)])
    }

    func testFormatRecoveryRecordsOneMergedGapAtTheOldFrameBoundary() async throws {
        let f = try await start()
        await send(f)
        let old = f.sources.latest.buffer
        let foreign = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        f.clock.advance(0.1)
        XCTAssertEqual(old.submit(try safetySample(safetyPCM(foreign, frames: 4_410, values: [0.9])), observedEnd: f.clock.now), .overflow)
        await old.drain()
        await f.pipeline.waitForSyntheticSystemRecovery()
        let gap = try XCTUnwrap(f.events.gaps.first)
        XCTAssertEqual(f.events.gaps.count, 1)
        XCTAssertEqual(gap.sessionID, f.id)
        XCTAssertEqual(gap.lastWrittenFrame, 4_800)
        XCTAssertEqual(gap.sampleRate, 48_000)
        XCTAssertEqual(gap.rejectedFrames, 4_410)
        XCTAssertEqual(gap.observedStart, 1_000.1, accuracy: 1e-8)
        XCTAssertEqual(gap.observedEnd, 1_000.45, accuracy: 1e-8)
        await send(f, values: [0.5])
        await f.pipeline.stop()
        XCTAssertEqual(f.events.gaps.count, 1)
        try verifyAudio(f.recording, [(4_800, 0.25), (4_800, 0.5)])
    }

    func testPCMFromFailedStartIsDrainedAndChunkSealedBeforeTheNextStart() async throws {
        let sources = SafetySources(), box = SafetyPipelineBox(), trace = SafetyTrace()
        sources.configure = { source, index in
            source.onStart = { input in
                trace.add("start.\(index)")
                if index == 1 {
                    XCTAssertEqual(input.submit(safetyPCM(input.format, values: [0.4]), observedEnd: 1_000.35), .accepted)
                } else if index == 2 {
                    XCTAssertEqual(box.pipeline?.transcriptionWork().map(\.endFrame), [4_800, 9_600])
                    trace.add("failed.start.chunk.sealed")
                    XCTAssertEqual(input.submit(safetyPCM(input.format, values: [0.5]), observedEnd: 1_000.85), .accepted)
                }
            }
            source.onStop = { _ in trace.add("stop.\(index)") }
        }
        let f = try await start(sources: sources)
        box.set(f.pipeline)
        await send(f)
        sources.failNext(1)
        sources.latest.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        await sources.latest.buffer.drain()
        XCTAssertLessThan(try XCTUnwrap(trace.values.firstIndex(of: "stop.1")), try XCTUnwrap(trace.values.firstIndex(of: "start.2")))
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 2)
        XCTAssertEqual(f.backoff.delays, [0.25, 0.5])
        XCTAssertEqual(f.events.gaps.count, 1)
        await f.pipeline.stop()
        try verifyAudio(f.recording, [(4_800, 0.25), (4_800, 0.4), (4_800, 0.5)])
    }

    func testStopDuringFormatRecoveryDeduplicatesGapByInputIdentity() async throws {
        let sleeper = SafetySleeper()
        let f = try await start(recoverySleep: sleeper)
        await send(f)
        let old = f.sources.latest.buffer
        let foreign = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        f.clock.advance(0.1)
        XCTAssertEqual(old.submit(safetyPCM(foreign, frames: 4_410), observedEnd: f.clock.now), .overflow)
        await old.drain()
        try await eventually { sleeper.pending == 1 }
        f.clock.advance(0.25)
        await f.pipeline.stop()
        XCTAssertEqual(sleeper.pending, 0)
        XCTAssertEqual(f.events.gaps.count, 1)
        XCTAssertEqual(f.events.gaps.first?.lastWrittenFrame, 4_800)
        XCTAssertEqual(f.events.gaps.first?.rejectedFrames, 4_410)
        XCTAssertEqual(f.events.gaps.first?.observedStart ?? 0, 1_000.1, accuracy: 1e-8)
        XCTAssertEqual(f.events.gaps.first?.observedEnd ?? 0, 1_000.45, accuracy: 1e-8)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        XCTAssertEqual(f.sources.count, 1)
        XCTAssertTrue(f.events.failures.isEmpty)
    }

    func testResumeBetweenPausedExitAndCompletionCannotReportExhaustion() async throws {
        let f = try await start()
        await send(f)
        f.backoff.setHook { f.pipeline.pause() }
        f.events.onGap {
            f.backoff.setHook(nil)
            do { try f.pipeline.resume() }
            catch { XCTFail("Resume must retain the pending recovery: \(error)") }
        }
        f.sources.latest.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(f.sources.count, 2)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 1)
        XCTAssertEqual(f.backoff.delays, [0.25, 0.25])
        XCTAssertEqual(f.events.gaps.count, 1)
        XCTAssertTrue(f.events.failures.isEmpty)
        XCTAssertFalse(try diagnostics(f.recording).contains { $0["category"] as? String == "system_recovery_exhausted" })
        await send(f)
    }

    func testPauseDuringBackoffCountsOnlyTheLaterActualOpen() async throws {
        let f = try await start()
        await send(f)
        f.backoff.setHook { f.pipeline.pause() }
        f.sources.latest.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        XCTAssertEqual(f.sources.count, 1)
        f.backoff.setHook(nil)
        try f.pipeline.resume()
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 1)
        XCTAssertEqual(f.sources.count, 2)
        XCTAssertEqual(f.backoff.delays, [0.25, 0.25])
        XCTAssertEqual(f.events.gaps.count, 1)
        XCTAssertTrue(f.events.failures.isEmpty)
    }

    func testPauseBeforeStartAdmissionDoesNotSpendAnAttemptOrLoseResume() async throws {
        let sources = SafetySources(), box = SafetyPipelineBox(), trace = SafetyTrace()
        sources.configure = { source, index in
            if index == 1 { box.pipeline?.pause() }
            source.onStart = { _ in trace.add("start.\(index)") }
        }
        let f = try await start(sources: sources)
        box.set(f.pipeline)
        await send(f)
        f.events.onGap {
            do { try f.pipeline.resume() }
            catch { XCTFail("Resume must retain the pending recovery: \(error)") }
        }
        sources.latest.fail()
        await f.pipeline.waitForSyntheticSystemRecovery()
        XCTAssertEqual(trace.values, ["start.0", "start.2"], "The paused allocated source must never start")
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 1)
        XCTAssertEqual(f.backoff.delays, [0.25, 0.25])
        XCTAssertEqual(f.events.gaps.count, 1)
        XCTAssertTrue(f.events.failures.isEmpty)
        await send(f)
    }

    func testNotReadyCMSampleBuffersAreCallbacksWithoutData() async throws {
        try await emptySampleCallbacks(invalid: false)
    }
    func testInvalidCMSampleBuffersAreCallbacksWithoutData() async throws {
        try await emptySampleCallbacks(invalid: true)
    }
    private func emptySampleCallbacks(invalid: Bool) async throws {
        let f = try await start()
        let input = f.sources.latest.buffer
        for callback in 1...5 {
            let sample = try safetySample(safetyPCM(input.format), ready: false)
            if invalid { XCTAssertEqual(CMSampleBufferInvalidate(sample), noErr) }
            f.clock.advance(1)
            XCTAssertEqual(input.submit(sample, observedEnd: f.clock.now), .closed)
            XCTAssertEqual(input.healthSnapshot.callbacks, Int64(callback))
            XCTAssertEqual(input.healthSnapshot.frames, 0)
            f.pipeline.checkSyntheticCaptureHealth(now: f.clock.now)
        }
        await f.pipeline.drainSyntheticCaptureHealthEvents()
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.noData.message(for: .systemAudio))
        XCTAssertEqual(try diagnostics(f.recording).last?["category"] as? String, "system_no_data")
        XCTAssertEqual(f.sources.count, 1)
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        XCTAssertTrue(f.events.gaps.isEmpty)
        await send(f)
        XCTAssertNil(f.events.notices.last?.message)
    }

    func testDigitalSilenceThresholdIncludesExactlyOneNanounit() async throws {
        XCTAssertEqual(CaptureHealthState.digitalSilencePeak, 1e-9, "The specified peak threshold must not drift")
        let f = try await start()
        for _ in 0..<15 { await send(f, elapsed: 1, duration: 1, values: [Float(1e-9)]) }
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.digitalSilence.message(for: .systemAudio))
        XCTAssertEqual(f.pipeline.syntheticSystemRecoveryAttempts, 0)
        XCTAssertTrue(f.events.gaps.isEmpty)
    }
    func testTwoNanounitsRemainHealthy() async throws {
        let f = try await start()
        for _ in 0..<16 { await send(f, elapsed: 1, duration: 1, values: [Float(2e-9)]) }
        XCTAssertTrue(f.events.notices.isEmpty)
        XCTAssertTrue(try diagnostics(f.recording).isEmpty)
    }
    func testSoundInEitherStereoChannelPreventsDigitalSilence() async throws {
        for channels: [Float] in [[0, 1e-6], [1e-6, 0]] {
            let f = try await start()
            for _ in 0..<16 { await send(f, elapsed: 1, duration: 1, values: channels) }
            XCTAssertTrue(f.events.notices.isEmpty)
            XCTAssertTrue(try diagnostics(f.recording).isEmpty)
            XCTAssertEqual(f.sources.count, 1)
            await f.pipeline.stop()
        }
    }

    func testWatchdogChecksEverySecondAndStopCancelsItAndTheRouteListener() async throws {
        let sleeper = SafetySleeper(), routeSleep = SafetySleeper()
        let f = try await start(watchdog: sleeper, routeSleep: routeSleep)
        try await eventually { sleeper.pending == 1 }
        XCTAssertEqual(sleeper.delays, [1])
        f.clock.advance(5.01)
        sleeper.next()
        try await eventually { sleeper.delays.count == 2 && sleeper.pending == 1 }
        await f.pipeline.drainSyntheticCaptureHealthEvents()
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.noCallbacks.message(for: .systemAudio))
        XCTAssertEqual(f.route.counts.starts, 1)
        let callback = try XCTUnwrap(f.route.savedCallback)
        f.route.change(.deviceChanged)
        try await eventually { routeSleep.pending == 1 }
        await f.pipeline.stop()
        XCTAssertEqual(sleeper.pending, 0)
        XCTAssertEqual(sleeper.cancelCount, 1)
        XCTAssertEqual(routeSleep.pending, 0)
        XCTAssertEqual(routeSleep.cancelCount, 1)
        XCTAssertNil(f.route.savedCallback)
        XCTAssertEqual(f.route.counts.stops, 1)
        callback(.deviceChanged)
        sleeper.next(); routeSleep.next()
        f.pipeline.checkSyntheticCaptureHealth(now: f.clock.now + 100)
        await f.pipeline.drainSyntheticCaptureHealthEvents()
        XCTAssertEqual(sleeper.delays, [1, 1])
        XCTAssertEqual(f.events.notices.count, 1)
        XCTAssertEqual(f.sources.count, 1)
    }

    private struct MicFixture {
        let pipeline: SpeechPipeline
        let clock: SafetyClock
        let engine: SafetyMic
        let scheduler: SafetyMicScheduler
        let notifications: NotificationCenter
        let events: SafetyEvents
        let recording: URL
    }
    private func mic(watchdog: SafetySleeper? = nil) async throws -> MicFixture {
        let clock = SafetyClock(), engine = SafetyMic(), scheduler = SafetyMicScheduler(), events = SafetyEvents()
        let notifications = NotificationCenter()
        let recording = try directory().appendingPathComponent("microphone.wav")
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Synthetic microphone PCM." }, enableAudioAnalysis: false,
            captureSleepNotificationCenter: NotificationCenter(), microphoneEngineFactory: { engine },
            microphoneNotifications: notifications, microphoneRecoveryDelayScheduler: scheduler.schedule,
            enableMicrophoneWatchdog: watchdog != nil, enableCaptureHealthWatchdog: watchdog != nil,
            captureUptime: { clock.now }, captureHealthCheckDelay: { seconds in try await watchdog!.wait(seconds) })
        try await pipeline.start(inputMode: .microphone, recordingURL: recording, sessionID: UUID(), eventHandler: events.consume)
        addTeardownBlock { await pipeline.stop() }
        return MicFixture(pipeline: pipeline, clock: clock, engine: engine, scheduler: scheduler,
            notifications: notifications, events: events, recording: recording)
    }
    private func sendMic(_ f: MicFixture, seconds: TimeInterval = 0.1, frames: Int = 1_600, value: Float = 0) async {
        f.clock.advance(seconds)
        let input = f.engine.buffer
        XCTAssertEqual(input.submit(safetyPCM(input.format, frames: frames, values: [value]), observedEnd: f.clock.now), .accepted)
        await input.drain()
        await f.pipeline.drainSyntheticCaptureHealthEvents()
    }
    func testRunningMicrophoneWithoutCallbacksRecoversAfterStartupGrace() async throws {
        let f = try await mic()
        f.clock.advance(4.99)
        f.pipeline.checkSyntheticCaptureHealth(now: f.clock.now)
        await f.pipeline.drainSyntheticCaptureHealthEvents()
        XCTAssertTrue(f.events.notices.isEmpty)
        XCTAssertEqual(f.scheduler.pending, 0)
        f.clock.advance(0.02)
        f.pipeline.checkSyntheticCaptureHealth(now: f.clock.now)
        await f.pipeline.drainSyntheticCaptureHealthEvents()
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.noCallbacks.message(for: .microphone))
        XCTAssertTrue(f.engine.isRunning, "A running flag must not suppress the no-callback watchdog")
        XCTAssertEqual(f.scheduler.pending, 1)
        XCTAssertEqual(f.engine.startCount, 1)
        XCTAssertEqual(f.pipeline.syntheticMicrophoneRecoveryState.attempts, 0)
        f.scheduler.next()
        XCTAssertEqual(f.engine.startCount, 2)
        XCTAssertEqual(f.pipeline.syntheticMicrophoneRecoveryState.attempts, 1)
        await sendMic(f)
        XCTAssertNil(f.events.notices.last?.message)
    }
    func testRunningMicrophoneCallbackInterruptionRecoversAndKeepsResumeGrace() async throws {
        let f = try await mic()
        await sendMic(f)
        f.clock.advance(SpeechPipeline.microphoneStallTimeout + 0.01)
        f.pipeline.checkSyntheticCaptureHealth(now: f.clock.now)
        await f.pipeline.drainSyntheticCaptureHealthEvents()
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.callbackInterrupted.message(for: .microphone))
        XCTAssertTrue(f.engine.isRunning)
        XCTAssertEqual(f.scheduler.pending, 1)
        XCTAssertEqual(f.engine.startCount, 1)
        f.scheduler.next()
        XCTAssertEqual(f.engine.startCount, 2)
        await sendMic(f)
        XCTAssertNil(f.events.notices.last?.message)
        f.pipeline.pause()
        try f.pipeline.resume()
        f.clock.advance(0.5)
        f.pipeline.checkSyntheticCaptureHealth(now: f.clock.now)
        await f.pipeline.drainSyntheticCaptureHealthEvents()
        XCTAssertNil(f.events.notices.last?.message)
        XCTAssertEqual(f.scheduler.pending, 0)
        f.clock.advance(SpeechPipeline.microphoneStallTimeout)
        f.pipeline.checkSyntheticCaptureHealth(now: f.clock.now)
        XCTAssertEqual(f.scheduler.pending, 1, "Resume must retain the original stall timeout")
    }
    func testMicrophoneSixteenSecondsOfZeroPCMHasNoSilenceOrDataWarning() async throws {
        let f = try await mic()
        for _ in 0..<16 {
            await sendMic(f, seconds: 1, frames: 16_000)
            f.pipeline.checkSyntheticCaptureHealth(now: f.clock.now)
        }
        await f.pipeline.drainSyntheticCaptureHealthEvents()
        XCTAssertTrue(f.events.notices.isEmpty)
        XCTAssertTrue(f.events.gaps.isEmpty)
        XCTAssertEqual(f.scheduler.pending, 0)
        XCTAssertTrue(try diagnostics(f.recording).isEmpty)
    }
    func testMicrophoneConfigurationChangeStillReconnectsARunningEngine() async throws {
        let f = try await mic()
        f.notifications.post(name: .AVAudioEngineConfigurationChange, object: f.engine)
        await f.pipeline.drainSyntheticCaptureHealthEvents()
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.deviceChanged.message(for: .microphone))
        XCTAssertEqual(try diagnostics(f.recording).last?["category"] as? String, "microphone_device_changed")
        XCTAssertTrue(f.engine.isRunning)
        XCTAssertEqual(f.scheduler.pending, 1)
        f.scheduler.next()
        await sendMic(f)
        XCTAssertNil(f.events.notices.last?.message)
        XCTAssertEqual(f.engine.startCount, 2)
    }
    func testStoppedMicrophoneFormatChangePublishesNoticeAndUsesProductionBackoffSequence() async throws {
        let f = try await mic()
        f.engine.changeStoppedFormat(to: 48_000)
        f.engine.failNextStarts(2)
        f.notifications.post(name: .AVAudioEngineConfigurationChange, object: f.engine)
        await f.pipeline.drainSyntheticCaptureHealthEvents()
        XCTAssertEqual(f.events.notices.last?.message, CaptureHealthIssue.formatChanged.message(for: .microphone))
        XCTAssertEqual(try diagnostics(f.recording).first?["category"] as? String, "microphone_format_changed")
        f.scheduler.next(); f.scheduler.next(); f.scheduler.next()
        XCTAssertEqual(f.scheduler.delays, [0.25, 0.5, 1])
        XCTAssertEqual(f.scheduler.pending, 0)
        XCTAssertEqual(f.pipeline.syntheticMicrophoneRecoveryState.attempts, 3)
        await sendMic(f, frames: 4_800)
        XCTAssertNil(f.events.notices.last?.message)
        XCTAssertEqual(f.engine.startCount, 4)
        XCTAssertTrue(f.events.failures.isEmpty)
    }
    func testMicrophoneWatchdogAlsoStopsItsOneSecondChecks() async throws {
        let sleeper = SafetySleeper()
        let f = try await mic(watchdog: sleeper)
        try await eventually { sleeper.pending == 1 }
        f.clock.advance(5.01)
        sleeper.next()
        try await eventually { sleeper.delays.count == 2 && sleeper.pending == 1 }
        await f.pipeline.drainSyntheticCaptureHealthEvents()
        XCTAssertNotNil(f.events.notices.last?.message)
        XCTAssertEqual(f.scheduler.pending, 1)
        XCTAssertTrue(f.engine.isRunning)
        await f.pipeline.stop()
        let starts = f.engine.startCount
        f.scheduler.next()
        XCTAssertEqual(f.engine.startCount, starts, "A queued recovery must not restart after stop")
        XCTAssertEqual(sleeper.cancelCount, 1)
        XCTAssertEqual(sleeper.pending, 0)
        f.notifications.post(name: .AVAudioEngineConfigurationChange, object: f.engine)
        XCTAssertEqual(f.scheduler.pending, 0)
        XCTAssertEqual(sleeper.delays, [1, 1])
    }
}
