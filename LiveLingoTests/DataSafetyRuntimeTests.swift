import XCTest
import Foundation
import Darwin
@testable import LiveLingo

private actor DataSafetyRuntimeGate {
    private(set) var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        if !released { await withCheckedContinuation { waiter = $0 } }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}

private final class DataSafetyRuntimeProbe: @unchecked Sendable {
    enum Outcome: Equatable { case success(String), cancelled, failed }
    private let lock = NSLock()
    private var storedOutcome: Outcome?
    private var polls = 0
    var outcome: Outcome? { lock.withLock { storedOutcome } }
    var exitPolls: Int { lock.withLock { polls } }
    func finish(_ outcome: Outcome) { lock.withLock { storedOutcome = outcome } }
    func observeExitWait() { lock.withLock { polls += 1 } }
}

/// Keeps the actual Process objects supplied by the launch hooks. Cleanup does
/// not depend on the runtime actor, its blocked writer, or a PID search.
private final class DataSafetyRuntimeChildren: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Process] = []
    let script: URL
    let interpreter = URL(fileURLWithPath: "/usr/bin/perl")

    init(script: URL) { self.script = script }
    var count: Int { lock.withLock { processes.count } }
    var runningCount: Int { children.filter(\.isRunning).count }
    private var children: [Process] { lock.withLock { processes } }

    func record(_ child: Process) { lock.withLock { processes.append(child) } }

    private func owns(_ child: Process) -> Bool {
        child.executableURL?.resolvingSymlinksInPath() == interpreter.resolvingSymlinksInPath()
            && child.arguments?.first == script.path && child.processIdentifier > 0
    }

    func terminateFirst() {
        guard let child = children.first, owns(child), child.isRunning else { return }
        child.terminate()
    }

    func retireAll() async {
        let owned = children
        for child in owned where child.isRunning {
            guard owns(child) else { XCTFail("Refused cleanup of an unowned child"); continue }
            child.terminate()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(0.8))
        while owned.contains(where: \.isRunning), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        for child in owned where child.isRunning {
            guard owns(child) else { continue }
            _ = Darwin.kill(child.processIdentifier, SIGKILL)
        }
        let killDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while owned.contains(where: \.isRunning), ContinuousClock.now < killDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(owned.contains(where: \.isRunning), "An exact fake child did not exit")
    }
}

/// Only synthetic Perl children and real pipes. ASR children merely announce a
/// URL; they never bind a socket. No preferences, models, or classroom data.
@MainActor
final class DataSafetyRuntimeTests: XCTestCase {
    private let model = "qwen3.5-4b-mlx"

    private func fixture(_ mode: String, source: String) throws -> (URL, DataSafetyRuntimeChildren) {
        let root = try DataSafetyFixtures.make("runtime-" + mode)
        let script = root.appendingPathComponent("fake-child.pl")
        try ("my $mode = '\(mode)';\n" + source).write(to: script, atomically: true, encoding: .utf8)
        let children = DataSafetyRuntimeChildren(script: script)
        addTeardownBlock {
            await children.retireAll()
            DataSafetyFixtures.preserve(root)
        }
        return (root, children)
    }

    private func mlx(_ mode: String, timeout: TimeInterval = 0.2,
                     probe: DataSafetyRuntimeProbe? = nil) throws -> (MLXRuntime, URL, DataSafetyRuntimeChildren) {
        let (root, children) = try fixture(mode, source: Self.mlxChild)
        var configuration = MLXRuntime.TestConfiguration(python: children.interpreter,
            script: children.script, models: root, state: root, controlTimeout: timeout,
            interpreterArguments: [])
        configuration.onWorkerLaunched = { child, input in
            // Keep EPIPE local to this test's writer, without changing the
            // test runner's global signal disposition.
            XCTAssertEqual(fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1), 0)
            children.record(child)
        }
        configuration.onExitWait = { probe?.observeExitWait() }
        return (MLXRuntime(testConfiguration: configuration), root, children)
    }

    private func asr(_ mode: String, gate: DataSafetyRuntimeGate? = nil)
        throws -> (ASRRuntime, DataSafetyRuntimeChildren) {
        let (root, children) = try fixture(mode, source: Self.asrChild)
        var configuration = ASRRuntime.TestConfiguration(interpreter: children.interpreter,
            script: children.script, models: root)
        configuration.onChildLaunched = { children.record($0) }
        if let gate { configuration.onCrashCleanup = { await gate.hold() } }
        return (ASRRuntime(testConfiguration: configuration), children)
    }

    private func eventually(timeout: TimeInterval = 3,
                            _ condition: @escaping @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func generate(_ runtime: MLXRuntime, prompt: String)
        -> (Task<Void, Never>, DataSafetyRuntimeProbe) {
        let probe = DataSafetyRuntimeProbe()
        let model = self.model
        let task = Task {
            do {
                let text = try await runtime.generate(model: model, prompt: prompt, input: "", prefix: "",
                    thinking: false, purpose: "text", finalBudget: 64, timeout: 5, onUpdate: { _ in })
                probe.finish(.success(text))
            } catch is CancellationError { probe.finish(.cancelled) }
            catch { probe.finish(.failed) }
        }
        return (task, probe)
    }

    func testWorkerPipeSuppressesSIGPIPEBeforeFirstWrite() async throws {
        let (root, children) = try fixture("pipe-flags", source: Self.mlxChild)
        var configuration = MLXRuntime.TestConfiguration(python: children.interpreter,
            script: children.script, models: root, state: root, controlTimeout: 1,
            interpreterArguments: [])
        configuration.onWorkerLaunched = { child, input in
            children.record(child)
            // This hook runs after Process.run(), before the first write. It
            // observes the production descriptor and never changes its flags.
            XCTAssertEqual(fcntl(input.fileDescriptor, F_GETNOSIGPIPE), 1,
                "The production pipe must suppress SIGPIPE without test-side mutation")
        }
        let runtime = MLXRuntime(testConfiguration: configuration)
        let (task, probe) = generate(runtime, prompt: "synthetic")
        addTeardownBlock { task.cancel(); await children.retireAll() }
        let completed = await eventually { probe.outcome != nil }
        XCTAssertTrue(completed)
        guard completed else { return }
        await task.value
        XCTAssertEqual(probe.outcome, .success("synthetic"))
        XCTAssertEqual(children.count, 1)
        let state = await runtime.resourceStates()[model]
        XCTAssertEqual(state?.outstandingRequests, 0)
        XCTAssertEqual(state?.pendingControls, 0)
        await runtime.unload(model)
        XCTAssertEqual(children.runningCount, 0)
    }

    func testF03CancellationDeadlineCoversBlockedWriteAndRetiresOnlyOwnedChild() async throws {
        let (runtime, root, children) = try mlx("never-read")
        let (task, probe) = generate(runtime, prompt: String(repeating: "x", count: 1_048_576))
        addTeardownBlock { task.cancel(); await children.retireAll() }
        let ready = await eventually {
            let state = await runtime.resourceStates()[self.model]
            return FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path)
                && children.count == 1 && state?.outstandingRequests == 1
        }
        XCTAssertTrue(ready, "The owned child must hold stdin open without reading")
        guard ready else { return }
        let before = await runtime.resourceStates()[model]
        XCTAssertNotNil(before)
        task.cancel()
        let settled = await eventually { probe.outcome != nil && children.runningCount == 0 }
        // This assertion runs before the independent cleanup below. Killing the
        // fake child from the test cannot turn the regression green.
        XCTAssertTrue(settled, "The control deadline must retire the child even while write is blocked")
        if settled {
            XCTAssertEqual(probe.outcome, .cancelled)
            let released = await eventually { await runtime.resourceStates().isEmpty }
            XCTAssertTrue(released, "The retired worker must no longer own requests or controls")
        }
        await children.retireAll()
        let cleaned = await eventually { probe.outcome != nil }
        XCTAssertTrue(cleaned, "Independent exact-child cleanup must also settle the red test")
        if cleaned { await task.value }
    }

    func testF04CancellationDuringDeliveryACKReleasesLeaseAndThrowsCancellation() async throws {
        let (runtime, root, children) = try mlx("delayed-ack", timeout: 2)
        let (task, probe) = generate(runtime, prompt: "synthetic")
        addTeardownBlock { task.cancel(); await children.retireAll() }
        let ackEntered = await eventually {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("ack-pending").path)
        }
        XCTAssertTrue(ackEntered)
        guard ackEntered else { return }
        task.cancel()
        let pending = await runtime.resourceStates()[model]
        XCTAssertEqual(pending?.outstandingRequests, 1)
        XCTAssertEqual(pending?.pendingControls, 1)
        try Data().write(to: root.appendingPathComponent("allow-ack"))
        let completed = await eventually { probe.outcome != nil }
        XCTAssertTrue(completed)
        guard completed else { return }
        await task.value
        XCTAssertEqual(probe.outcome, .cancelled, "A cancelled ACK waiter must not return completed text")
        let state = await runtime.resourceStates()[model]
        XCTAssertEqual(state?.outstandingRequests, 0)
        XCTAssertEqual(state?.pendingControls, 0)
        await runtime.unload(model)
    }

    func testC01CrashCleanupReentryReusesTheAdmittedReplacement() async throws {
        let gate = DataSafetyRuntimeGate()
        let (runtime, children) = try asr("ready", gate: gate)
        addTeardownBlock { await gate.release(); await children.retireAll(); await runtime.stop() }
        let original = try await runtime.endpoint()
        children.terminateFirst()
        let exited = await eventually { children.runningCount == 0 }
        XCTAssertTrue(exited)
        guard exited else { return }
        let first = Task { try await runtime.endpoint() }
        let cleanupEntered = await eventually { await gate.entered }
        XCTAssertTrue(cleanupEntered)
        guard cleanupEntered else { await gate.release(); return }
        let second = try await runtime.endpoint()
        XCTAssertNotEqual(second, original)
        await gate.release()
        let resumed = try await first.value
        XCTAssertEqual(resumed, second, "Crash cleanup must recheck the replacement admitted during its await")
        XCTAssertEqual(children.count, 2, "Only the original and one replacement may be launched")
        let current = try await runtime.endpoint()
        XCTAssertEqual(current, second)
        await runtime.stop()
    }

    func testC04CancelledUnloadKeepsExitPollingPaced() async throws {
        let probe = DataSafetyRuntimeProbe()
        let gate = DataSafetyRuntimeGate()
        let (runtime, _, children) = try mlx("slow-shutdown", timeout: 0.8, probe: probe)
        addTeardownBlock { await gate.release(); await children.retireAll() }
        let (generation, result) = generate(runtime, prompt: "synthetic")
        let generated = await eventually { result.outcome != nil }
        XCTAssertTrue(generated)
        guard generated else { return }
        await generation.value
        XCTAssertEqual(result.outcome, .success("synthetic"))
        let unloading = Task {
            await gate.hold()
            await runtime.unload(model)
            probe.finish(.success("unloaded"))
        }
        let waiting = await eventually { await gate.entered }
        XCTAssertTrue(waiting)
        guard waiting else { return }
        unloading.cancel()
        await gate.release()
        let finished = await eventually { probe.outcome != nil }
        XCTAssertTrue(finished)
        guard finished else { return }
        await unloading.value
        XCTAssertGreaterThan(probe.exitPolls, 0, "The fake child must actually require an exit wait")
        // The child delays exit by 400 ms; 50/20 ms polling has ample room
        // below this bound, whereas a cancelled sleep spins thousands of times.
        XCTAssertLessThan(probe.exitPolls, 64, "Cancelled teardown must still sleep between exit checks")
        XCTAssertEqual(children.runningCount, 0)
        let states = await runtime.resourceStates()
        XCTAssertTrue(states.isEmpty)
    }

    func testA9PreReadyExitDiagnosticReportsTheObservedExitStatus() async throws {
        let (runtime, children) = try asr("exit-before-ready")
        do {
            _ = try await runtime.endpoint()
            XCTFail("The synthetic child exits before announcing readiness")
        } catch let QwenRuntimeError.requestFailed(message) {
            XCTAssertTrue(message.contains("退出状态：exit code 23"), "The summary must use the observed child exit")
            XCTAssertFalse(message.contains("退出状态：仍在运行"))
        } catch { XCTFail("Unexpected error type for a pre-ready child exit") }
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children.runningCount, 0)
        let running = await runtime.isRunning
        XCTAssertFalse(running)
        await runtime.stop()
    }

    private static let mlxChild = #"""
    use strict;
    use warnings;
    use JSON::PP;
    $| = 1;
    my %args;
    while (@ARGV) { my $key = shift @ARGV; $args{$key} = shift @ARGV; }
    my $root = $args{'--state-directory'};
    sub emit { print encode_json($_[0]), "\n"; }
    sub marker { open(my $file, '>', "$root/$_[0]") or die 'marker'; close($file); }
    emit({event => 'ready', version => 2});
    marker('ready');
    if ($mode eq 'never-read') {
        while (1) { select(undef, undef, undef, 0.05); }
    }
    while (my $line = <STDIN>) {
        my $request = decode_json($line);
        my $op = $request->{op};
        if ($op eq 'generate') {
            emit({event => 'model_state', loaded => JSON::PP::true});
            emit({event => 'done', id => $request->{id}, text => 'synthetic'});
        } elsif ($op eq 'ack') {
            if ($mode eq 'delayed-ack') {
                marker('ack-pending');
                while (!-e "$root/allow-ack") { select(undef, undef, undef, 0.01); }
            }
            emit({event => 'ack', controlID => $request->{controlID}});
        } elsif ($op eq 'shutdown') {
            emit({event => 'shutdown', controlID => $request->{controlID}});
            if ($mode eq 'slow-shutdown') { select(undef, undef, undef, 0.4); }
            exit(0);
        } else {
            emit({event => $op eq 'pause' ? 'paused' : $op, controlID => $request->{controlID}});
        }
    }
    """#

    private static let asrChild = #"""
    use strict;
    use warnings;
    use JSON::PP;
    $| = 1;
    exit(23) if $mode eq 'exit-before-ready';
    my $models;
    while (@ARGV) {
        my $arg = shift @ARGV;
        if ($arg eq '--models-dir') { $models = shift @ARGV; }
    }
    print 'LIVELINGO_ASR_READY ', encode_json({protocol => 2, host => '127.0.0.1', port => 1,
        pid => $$, auth => JSON::PP::true, supervised => JSON::PP::true, models_root => $models}), "\n";
    while (<STDIN>) { }
    """#
}
