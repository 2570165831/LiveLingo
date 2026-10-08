import XCTest
import Foundation
import Darwin
@testable import LiveLingo

private actor MLXExitTestGate {
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private func mlxExitTestDelay(_ seconds: TimeInterval) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
}

private final class MLXExitTestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var children: [Process] = []
    private var recordedEvents: [String] = []
    private var polls = 0
    private var joinsWaited = 0
    private var completions: [Bool] = []
    var events: [String] { lock.withLock { recordedEvents } }
    var exitPolls: Int { lock.withLock { polls } }
    var readerJoinWaits: Int { lock.withLock { joinsWaited } }
    var finished: [Bool] { lock.withLock { completions } }
    var launchCount: Int { lock.withLock { children.count } }
    var runningCount: Int { lock.withLock { children }.filter(\.isRunning).count }
    func record(_ child: Process) { lock.withLock { children.append(child) } }
    func record(_ event: MLXRuntime.RetirementEventForTesting) {
        lock.withLock { recordedEvents.append(event.rawValue) }
    }
    func observePoll() { lock.withLock { polls += 1 } }
    func observeRetry(_ phase: MLXRuntime.RetryWaitPhaseForTesting) {
        if case .workerExit = phase { lock.withLock { joinsWaited += 1 } }
    }
    func finish(cancelled: Bool) { lock.withLock { completions.append(cancelled) } }

    // Cleanup only follows assertions and uses retained Process objects. It
    // cannot supply the exit/join evidence that makes a regression pass.
    func cleanup(script: URL) async {
        let owned = lock.withLock { children }
        for child in owned where child.isRunning {
            guard child.executableURL == URL(fileURLWithPath: "/usr/bin/perl"),
                  child.arguments?.first == script.path, child.processIdentifier > 0 else {
                XCTFail("Refused cleanup of a child outside this fixture")
                continue
            }
            _ = Darwin.kill(child.processIdentifier, SIGKILL)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while owned.contains(where: \.isRunning), ContinuousClock.now < deadline {
            await mlxExitTestDelay(0.01)
        }
        XCTAssertFalse(owned.contains(where: \.isRunning), "The exact scripted child must exit")
    }
}

private final class MLXCountedExitChild: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var checks = 0
    private var kills = 0
    private var remainingChecksAfterKill: Int
    init(checksAfterKill: Int = 0) { remainingChecksAfterKill = checksAfterKill }
    func isRunning() -> Bool {
        lock.withLock {
            checks += 1
            if kills > 0, remainingChecksAfterKill > 0 {
                remainingChecksAfterKill -= 1
                if remainingChecksAfterKill == 0 { running = false }
            }
            return running
        }
    }
    func forceKill() {
        lock.withLock {
            kills += 1
            if remainingChecksAfterKill == 0 { running = false }
        }
    }
    var snapshot: (checks: Int, kills: Int, running: Bool) {
        lock.withLock { (checks, kills, running) }
    }
}

private final class MLXBaselineEA14849Process: @unchecked Sendable {
    let child: MLXCountedExitChild
    let processIdentifier: Int32 = -31415
    var isRunning: Bool { child.isRunning() }
    init(_ child: MLXCountedExitChild) { self.child = child }
}

/// Extracted from ea14849:LiveLingo/Sources/MLXRuntime.swift. The two methods
/// below are verbatim except Darwin.kill -> fakeKill; their source mapping is
/// verified separately. Only Process/Worker and their actor context are fake.
@MainActor
private final class MLXBaselineEA14849ExitHarness {
    private struct Worker {
        let id = UUID()
        let process: MLXBaselineEA14849Process
    }
    private struct TestConfiguration {
        let onExitWait: (@Sendable () -> Void)?
    }
    private let testConfiguration: TestConfiguration? = nil
    private let controlTimeout: TimeInterval
    private var retiringWorkers: [String: Worker] = [:]
    init(timeout: TimeInterval) { controlTimeout = timeout }

    func run(_ child: MLXCountedExitChild) async -> Bool {
        let worker = Worker(process: MLXBaselineEA14849Process(child))
        retiringWorkers["baseline-ea14849"] = worker
        await waitForExit(worker, model: "baseline-ea14849")
        return !child.snapshot.running && retiringWorkers["baseline-ea14849"] == nil
    }

    private func fakeKill(_ identifier: Int32, _ signal: Int32) -> Int32 {
        guard let worker = retiringWorkers["baseline-ea14849"],
              identifier == worker.process.processIdentifier, signal == SIGKILL else {
            preconditionFailure("The baseline may only signal its counted fake child")
        }
        worker.process.child.forceKill()
        return 0
    }

    private func waitForExit(_ worker: Worker, model: String) async {
        let deadline = (ExitDeadline.current ?? ExitDeadline(seconds: controlTimeout + 2)).limited(to: controlTimeout)
        while worker.process.isRunning && !deadline.isExpired {
            #if DEBUG
            testConfiguration?.onExitWait?()
            #endif
            await Self.sleepForRetirement(0.05)
        }
        if worker.process.isRunning {
            // Process is a child owned by this Worker instance. Never enumerate
            // or signal another application's model processes.
            _ = fakeKill(worker.process.processIdentifier, SIGKILL)
        }
        let killDeadline = (ExitDeadline.current ?? ExitDeadline(seconds: 2)).limited(to: 2)
        while worker.process.isRunning && !killDeadline.isExpired {
            #if DEBUG
            testConfiguration?.onExitWait?()
            #endif
            await Self.sleepForRetirement(0.02)
        }
        if !worker.process.isRunning, retiringWorkers[model]?.id == worker.id {
            retiringWorkers[model] = nil
        }
    }

    private static func sleepForRetirement(_ seconds: TimeInterval) async {
        // Retirement belongs to this exact worker even if its caller was
        // cancelled. A cancelled Task.sleep must not turn polling into a spin.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }
}

/// CPU-only fake state and owned Perl children. Fixture files stay under the
/// runner's configured temporary directory; no model or host environment read.
@MainActor
final class MLXExitCancellationTests: XCTestCase {
    private let model = "qwen3.5-4b-mlx"

    private func eventually(_ condition: @escaping @MainActor () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        struct TimedOut: Error {}
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Exit fixture did not reach the required state", file: file, line: line)
                throw TimedOut()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func fixture(_ mode: String, timeout: TimeInterval = 0.3,
                         joinGate: MLXExitTestGate? = nil)
        throws -> (MLXRuntime, URL, MLXExitTestProbe) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("energy-mlx-exit-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake-exit-worker.pl")
        try ("my $mode = '\(mode)';\n" + Self.fakeWorker).write(to: script, atomically: true, encoding: .utf8)
        let probe = MLXExitTestProbe()
        var configuration = MLXRuntime.TestConfiguration(python: URL(fileURLWithPath: "/usr/bin/perl"),
            script: script, models: root, state: root, controlTimeout: timeout, interpreterArguments: [])
        configuration.onWorkerLaunched = { child, _ in probe.record(child) }
        configuration.onExitWait = { probe.observePoll() }
        configuration.onRetirementEvent = { probe.record($0) }
        configuration.onRetryWait = { probe.observeRetry($0) }
        if let joinGate { configuration.beforeReaderJoin = { await joinGate.hold() } }
        let runtime = MLXRuntime(testConfiguration: configuration)
        let model = self.model
        addTeardownBlock {
            await joinGate?.release()
            await probe.cleanup(script: script)
            await runtime.unload(model)
        }
        return (runtime, root, probe)
    }

    private func generate(_ runtime: MLXRuntime) async throws -> String {
        try await runtime.generate(model: model, prompt: "synthetic", input: "", prefix: "",
            thinking: false, purpose: "text", finalBudget: 32, timeout: 3, onUpdate: { _ in })
    }

    private func unload(_ runtime: MLXRuntime, probe: MLXExitTestProbe,
                        entryGate: MLXExitTestGate? = nil, expiredDeadline: Bool = false) -> Task<Void, Never> {
        let model = self.model
        return Task {
            if let entryGate { await entryGate.hold() }
            if expiredDeadline {
                await ExitDeadline.$current.withValue(ExitDeadline(seconds: 0)) { await runtime.unload(model) }
            } else {
                await runtime.unload(model)
            }
            probe.finish(cancelled: Task.isCancelled)
        }
    }

    private func assertJoined(_ probe: MLXExitTestProbe, killed: Bool,
                              file: StaticString = #filePath, line: UInt = #line) {
        var expected = ["inputClosed"]
        if killed { expected.append("forceKillSent") }
        expected += ["exitObserved", "stdoutJoined", "stderrJoined", "retired"]
        XCTAssertEqual(probe.events, expected, "One retirement must join both reads and consumers", file: file, line: line)
        XCTAssertEqual(probe.launchCount, 1, file: file, line: line)
        XCTAssertEqual(probe.runningCount, 0, file: file, line: line)
    }

    func testCancelledUnloadBeforeEntryClosesInputForEOFAndJoinsReaders() async throws {
        let (runtime, root, probe) = try fixture("eof")
        let result = try await generate(runtime)
        XCTAssertEqual(result, "synthetic")
        let gate = MLXExitTestGate()
        addTeardownBlock { await gate.release() }
        let task = unload(runtime, probe: probe, entryGate: gate)
        try await eventually { await gate.entered }
        task.cancel()
        await gate.release()
        try await eventually { !probe.finished.isEmpty }
        await task.value
        XCTAssertEqual(probe.finished, [true], "This cancels unload itself, before it enters the runtime")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("stdin-eof").path))
        let states = await runtime.resourceStates()
        XCTAssertTrue(states.isEmpty)
        assertJoined(probe, killed: false)
    }

    func testCancellationDuringGracefulExitDoesNotForceKill() async throws {
        let (runtime, _, probe) = try fixture("graceful")
        _ = try await generate(runtime)
        let task = unload(runtime, probe: probe)
        try await eventually { probe.exitPolls > 0 }
        task.cancel()
        try await eventually { !probe.finished.isEmpty }
        await task.value
        XCTAssertEqual(probe.finished, [true])
        XCTAssertLessThanOrEqual(probe.exitPolls, 10, "Cancelled graceful retirement must keep its delay")
        let states = await runtime.resourceStates()
        XCTAssertTrue(states.isEmpty)
        assertJoined(probe, killed: false)
    }

    func testCancellationDuringForceKillRetainsExactChildUntilExitAndJoin() async throws {
        let (runtime, _, probe) = try fixture("force-kill", timeout: 0.2)
        _ = try await generate(runtime)
        let initialStates = await runtime.resourceStates()
        let old = try XCTUnwrap(initialStates[model])
        let task = unload(runtime, probe: probe)
        try await eventually { probe.exitPolls > 0 }
        task.cancel()
        let retained = await runtime.resourceStates()[model]
        XCTAssertEqual(retained?.workerID, old.workerID)
        XCTAssertTrue(retained?.retiring == true)
        XCTAssertEqual(Darwin.kill(old.processIdentifier, 0), 0)
        try await eventually { !probe.finished.isEmpty }
        await task.value
        XCTAssertEqual(probe.finished, [true])
        XCTAssertLessThanOrEqual(probe.exitPolls, 110, "Includes the bounded 2-second post-kill polling window")
        XCTAssertNotEqual(Darwin.kill(old.processIdentifier, 0), 0)
        let states = await runtime.resourceStates()
        XCTAssertTrue(states.isEmpty)
        assertJoined(probe, killed: true)
    }

    func testCancellationWhileJoiningReadersKeepsOwnershipAndConcurrentUnloadJoinsSameTask() async throws {
        let gate = MLXExitTestGate()
        let (runtime, _, probe) = try fixture("graceful", joinGate: gate)
        _ = try await generate(runtime)
        let initialStates = await runtime.resourceStates()
        let old = try XCTUnwrap(initialStates[model])
        let task = unload(runtime, probe: probe)
        try await eventually { await gate.entered }
        task.cancel()
        let retained = await runtime.resourceStates()[model]
        XCTAssertEqual(retained?.workerID, old.workerID)
        XCTAssertTrue(retained?.retiring == true, "Exited child stays owned through reader join")
        XCTAssertNotEqual(Darwin.kill(old.processIdentifier, 0), 0)
        XCTAssertTrue(probe.finished.isEmpty, "Cancelling unload cannot release unjoined readers")
        do {
            _ = try await generate(runtime)
            XCTFail("Reader join must finish before a replacement worker is admitted")
        } catch QwenRuntimeError.generationInterrupted {}
        XCTAssertGreaterThan(probe.readerJoinWaits, 0, "Admission must wait for the exited child's reader joins")
        XCTAssertEqual(probe.launchCount, 1, "A held join gate must not admit a replacement")
        let second = unload(runtime, probe: probe)
        await gate.release()
        try await eventually { probe.finished.count == 2 }
        await task.value
        await second.value
        XCTAssertEqual(probe.finished.filter { $0 }.count, 1)
        let states = await runtime.resourceStates()
        XCTAssertTrue(states.isEmpty)
        assertJoined(probe, killed: false)
    }

    func testGenerateAfterChildExitWaitsForReaderJoinThenCreatesReplacement() async throws {
        let gate = MLXExitTestGate()
        let (runtime, _, probe) = try fixture("graceful", joinGate: gate)
        _ = try await generate(runtime)
        let initialStates = await runtime.resourceStates()
        let old = try XCTUnwrap(initialStates[model])
        let retiring = unload(runtime, probe: probe)
        try await eventually { await gate.entered }
        XCTAssertNotEqual(Darwin.kill(old.processIdentifier, 0), 0)
        var replacementFinished = false
        let replacement = Task {
            defer { replacementFinished = true }
            return try await generate(runtime)
        }
        defer { replacement.cancel() }
        try await eventually { probe.readerJoinWaits > 0 }
        XCTAssertFalse(replacementFinished, "An exited child still owns its unjoined readers")
        XCTAssertEqual(probe.launchCount, 1)
        let retained = await runtime.resourceStates()[model]
        XCTAssertEqual(retained?.workerID, old.workerID)
        XCTAssertTrue(retained?.retiring == true)
        await gate.release()
        try await eventually { replacementFinished }
        let result = try await replacement.value
        await retiring.value
        XCTAssertEqual(result, "synthetic")
        let current = await runtime.resourceStates()[model]
        XCTAssertNotEqual(current?.workerID, old.workerID)
        XCTAssertEqual(current?.outstandingRequests, 0)
        XCTAssertEqual(probe.launchCount, 2, "Only the admitted replacement may launch a second child")
        XCTAssertEqual(probe.events, ["inputClosed", "exitObserved", "stdoutJoined", "stderrJoined", "retired"])
        await runtime.unload(model)
        let states = await runtime.resourceStates()
        XCTAssertTrue(states.isEmpty)
    }

    func testCancelledGenerateWaitingForExitedChildReaderJoinLeavesOwnerIntact() async throws {
        let gate = MLXExitTestGate()
        let (runtime, _, probe) = try fixture("graceful", joinGate: gate)
        _ = try await generate(runtime)
        let initialStates = await runtime.resourceStates()
        let old = try XCTUnwrap(initialStates[model])
        let retiring = unload(runtime, probe: probe)
        try await eventually { await gate.entered }
        let replacement = Task { try await generate(runtime) }
        defer { replacement.cancel() }
        try await eventually { probe.readerJoinWaits > 0 }
        replacement.cancel()
        do {
            _ = try await replacement.value
            XCTFail("Cancellation must interrupt admission waiting for reader join")
        } catch is CancellationError {}
        let retained = await runtime.resourceStates()[model]
        XCTAssertEqual(retained?.workerID, old.workerID)
        XCTAssertTrue(retained?.retiring == true)
        XCTAssertEqual(retained?.outstandingRequests, 0)
        XCTAssertEqual(probe.launchCount, 1)
        XCTAssertTrue(probe.finished.isEmpty, "Cancelling admission cannot finish the retirement owner")
        await gate.release()
        await retiring.value
        let states = await runtime.resourceStates()
        XCTAssertTrue(states.isEmpty)
        assertJoined(probe, killed: false)
    }

    func testExpiredDeadlineAndCancelledUnloadStillObserveExitAndJoin() async throws {
        let (runtime, _, probe) = try fixture("force-kill")
        _ = try await generate(runtime)
        let gate = MLXExitTestGate()
        addTeardownBlock { await gate.release() }
        let task = unload(runtime, probe: probe, entryGate: gate, expiredDeadline: true)
        try await eventually { await gate.entered }
        task.cancel()
        await gate.release()
        try await eventually { !probe.finished.isEmpty }
        await task.value
        XCTAssertEqual(probe.finished, [true])
        XCTAssertEqual(probe.exitPolls, 0, "Expired poll windows must transfer to the exact child exit event")
        let states = await runtime.resourceStates()
        XCTAssertTrue(states.isEmpty)
        assertJoined(probe, killed: true)
    }

    private struct CheckMeasurement: Encodable, Sendable {
        let implementation: String
        let taskCancelled: Bool
        let graceSeconds: Double
        let killSeconds: Double
        let elapsedSeconds: Double
        let isRunningChecks: Int
        let fakeKillCalls: Int
        let exitConfirmed: Bool
    }

    private func measure(legacy: Bool, cancel: Bool, baselineEA14849: Bool = false, checksAfterKill: Int = 0,
                         timeout: TimeInterval = 0.08, killTimeout: TimeInterval = 0.2) async throws -> CheckMeasurement {
        let child = MLXCountedExitChild(checksAfterKill: checksAfterKill), gate = MLXExitTestGate()
        addTeardownBlock { await gate.release() }
        let task = Task {
            await gate.hold()
            let start = ProcessInfo.processInfo.systemUptime
            let confirmed: Bool
            let implementation: String
            if baselineEA14849 {
                precondition(!legacy && killTimeout == 2, "The extracted baseline keeps its original 2-second kill window")
                implementation = "baseline-ea14849"
                confirmed = await MLXBaselineEA14849ExitHarness(timeout: timeout).run(child)
            } else if legacy {
                implementation = "audit-legacy-swallowed-sleep"
                confirmed = await legacySwallowedSleep(child, timeout: timeout, killTimeout: killTimeout)
            } else {
                implementation = "production-owned-exit"
                confirmed = await MLXRuntime.waitForExitForTesting(timeout: timeout, killTimeout: killTimeout,
                    isRunning: { child.isRunning() }, forceKill: { child.forceKill() })
            }
            let snapshot = child.snapshot
            return CheckMeasurement(implementation: implementation,
                taskCancelled: Task.isCancelled, graceSeconds: timeout, killSeconds: killTimeout,
                elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
                isRunningChecks: snapshot.checks, fakeKillCalls: snapshot.kills, exitConfirmed: confirmed)
        }
        try await eventually { await gate.entered }
        if cancel { task.cancel() }
        await gate.release()
        return await task.value
    }

    private struct BaselineComparison: Encodable {
        let baseline: CheckMeasurement
        let current: CheckMeasurement
        var checkDelta: Int { current.isRunningChecks - baseline.isRunningChecks }
        enum CodingKeys: String, CodingKey { case baseline, current, checkDelta }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(baseline, forKey: .baseline)
            try container.encode(current, forKey: .current)
            try container.encode(checkDelta, forKey: .checkDelta)
        }
    }

    func testBaselineEA14849AndCurrentExitCheckCountsUseSameFakeChildAndTimeout() async throws {
        var comparisons: [BaselineComparison] = []
        for cancelled in [true, false] {
            let baseline = try await measure(legacy: false, cancel: cancelled, baselineEA14849: true, killTimeout: 2)
            let current = try await measure(legacy: false, cancel: cancelled, killTimeout: 2)
            for sample in [baseline, current] {
                XCTAssertEqual(sample.taskCancelled, cancelled)
                XCTAssertTrue(sample.exitConfirmed)
                XCTAssertEqual(sample.fakeKillCalls, 1)
                XCTAssertLessThanOrEqual(sample.isRunningChecks, 8)
            }
            XCTAssertEqual(baseline.graceSeconds, current.graceSeconds)
            XCTAssertEqual(baseline.killSeconds, current.killSeconds)
            comparisons.append(BaselineComparison(baseline: baseline, current: current))
        }
        // Both implementations already have cancellation-independent waits.
        // Two grace sleeps normally give six property reads in either case;
        // scheduler delays may reduce that count. No reduction is required.
        print("MLX_EXIT_BASELINE_EA14849_COUNTS " + String(decoding: try JSONEncoder().encode(comparisons), as: UTF8.self))
    }

    // Deliberately reproduces the audit's pre-fix loop, only on counted fake
    // state. This is a historical reference, not a claim about the base HEAD.
    private func legacySwallowedSleep(_ child: MLXCountedExitChild, timeout: TimeInterval,
                                      killTimeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while child.isRunning() && ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning() { child.forceKill() }
        let killDeadline = ProcessInfo.processInfo.systemUptime + killTimeout
        while child.isRunning() && ProcessInfo.processInfo.systemUptime < killDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !child.isRunning()
    }

    func testCancelledExitCheckCountsAgainstLegacySwallowedSleep() async throws {
        let before = try await measure(legacy: true, cancel: true)
        let after = try await measure(legacy: false, cancel: true)
        let normal = try await measure(legacy: false, cancel: false)
        for sample in [before, after, normal] {
            XCTAssertTrue(sample.exitConfirmed)
            XCTAssertEqual(sample.fakeKillCalls, 1)
        }
        XCTAssertTrue(before.taskCancelled)
        XCTAssertTrue(after.taskCancelled)
        XCTAssertFalse(normal.taskCancelled)
        XCTAssertLessThanOrEqual(after.isRunningChecks, 8)
        XCTAssertLessThanOrEqual(normal.isRunningChecks, 8)
        XCTAssertGreaterThan(before.isRunningChecks, after.isRunningChecks * 8,
            "The finite legacy busy loop must perform substantially more actual property checks")
        print("MLX_EXIT_HISTORICAL_BUSY_LOOP_COUNTS " + String(decoding: try JSONEncoder().encode([before, after, normal]), as: UTF8.self))
    }

    func testAlreadyCancelledPostKillWaitKeepsRealDelay() async throws {
        // The fake exit needs three post-kill observations, forcing two real
        // 20-ms waits. An already-cancelled Task.sleep would skip both waits.
        let sample = try await measure(legacy: false, cancel: true, checksAfterKill: 3, timeout: 0)
        XCTAssertTrue(sample.taskCancelled)
        XCTAssertTrue(sample.exitConfirmed)
        XCTAssertEqual(sample.fakeKillCalls, 1)
        XCTAssertLessThanOrEqual(sample.isRunningChecks, 8)
        XCTAssertGreaterThanOrEqual(sample.elapsedSeconds, 0.035)
        print("MLX_EXIT_POST_KILL_COUNTS " + String(decoding: try JSONEncoder().encode(sample), as: UTF8.self))
    }

    private static let fakeWorker = #"""
    use strict;
    use warnings;
    use JSON::PP;
    $| = 1;
    my $state;
    for (my $i = 0; $i < @ARGV; $i++) { $state = $ARGV[$i + 1] if $ARGV[$i] eq '--state-directory'; }
    $SIG{TERM} = 'IGNORE' if $mode eq 'force-kill';
    sub emit { my ($event, %fields) = @_; print encode_json({event => $event, %fields}), "\n"; }
    sub mark {
        my ($name) = @_;
        open(my $file, '>', "$state/$name") or die;
        print $file "synthetic\n";
        close $file;
    }
    emit('ready', version => 2);
    while (my $line = <STDIN>) {
        my $command = decode_json($line);
        my $op = $command->{op};
        if ($op eq 'generate') {
            emit('model_state', loaded => JSON::PP::true);
            emit('done', id => $command->{id}, text => 'synthetic');
        } elsif ($op eq 'ack') {
            emit('ack', id => $command->{id}, controlID => $command->{controlID}, state => 'released');
        } elsif ($op eq 'shutdown') {
            mark('shutdown-seen');
            emit('shutdown', controlID => $command->{controlID}, state => 'ready_to_exit');
            if ($mode eq 'graceful') {
                select(undef, undef, undef, 0.12);
                print STDERR "synthetic stderr tail\n";
                exit 0;
            }
            if ($mode eq 'force-kill') { while (1) { select(undef, undef, undef, 1); } }
        }
    }
    mark('stdin-eof');
    if ($mode eq 'force-kill') { while (1) { select(undef, undef, undef, 1); } }
    emit('model_state', loaded => JSON::PP::false);
    print STDERR "synthetic stderr EOF tail\n";
    """#
}
