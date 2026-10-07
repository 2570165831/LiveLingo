import XCTest
import Foundation
import Darwin
@testable import LiveLingo

private actor TranslationRetirementProbe {
    private(set) var controlHeld = false
    private(set) var requestReleaseWaits = 0
    private(set) var workerExitWaits = 0
    private var controlReleased = false
    private var controlWaiter: CheckedContinuation<Void, Never>?

    func holdResolvedControl() async {
        controlHeld = true
        guard !controlReleased else { return }
        await withCheckedContinuation { controlWaiter = $0 }
    }

    func releaseControl() {
        controlReleased = true
        controlWaiter?.resume()
        controlWaiter = nil
    }

    func observe(_ phase: MLXRuntime.RetryWaitPhaseForTesting) {
        switch phase {
        case .requestRelease: requestReleaseWaits += 1
        case .workerExit: workerExitWaits += 1
        }
    }
}

/// Real pipes and owned Perl children. No service, model, GPU or production
/// checkpoint directory is involved; hooks only hold/observe real actor jobs.
@MainActor
final class TranslationRetirementRegressionTests: XCTestCase {
    private let model = "qwen3.5-4b-mlx"

    private func fixture(controlTimeout: TimeInterval = 0.3, holdControl: Bool = true)
        throws -> (MLXRuntime, URL, TranslationRetirementProbe) {
        // Keep all fixtures within this task's allowed DerivedData directory.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("translation-retirement-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake-retirement-worker.pl")
        try Self.fakeWorker.write(to: script, atomically: true, encoding: .utf8)
        let probe = TranslationRetirementProbe()
        var configuration = MLXRuntime.TestConfiguration(python: URL(fileURLWithPath: "/usr/bin/perl"),
            script: script, models: root, state: root, controlTimeout: controlTimeout)
        if holdControl {
            configuration.onCancellationControlResolved = { await probe.holdResolvedControl() }
        }
        configuration.onRetryWait = { await probe.observe($0) }
        let runtime = MLXRuntime(testConfiguration: configuration)
        let model = self.model
        addTeardownBlock {
            await probe.releaseControl()
            try? Data().write(to: root.appendingPathComponent("allow-exit"))
            try? await runtime.finishRetirementBeforeRetry(model)
            await runtime.unload(model)
        }
        return (runtime, root, probe)
    }

    private func generate(_ runtime: MLXRuntime, prompt: String,
                          timeout: TimeInterval = 0.01) async throws -> String {
        try await runtime.generate(model: model, prompt: prompt, input: "", prefix: "",
            thinking: false, purpose: "text", finalBudget: 64, timeout: timeout,
            inactivityTimeout: timeout, onUpdate: { _ in })
    }

    private func eventually(_ condition: @escaping @MainActor () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        struct WaitTimedOut: Error {}
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("The scripted runtime did not reach the required interleaving", file: file, line: line)
                throw WaitTimedOut()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func timeOut(_ runtime: MLXRuntime, prompt: String) async throws {
        do {
            _ = try await generate(runtime, prompt: prompt)
            XCTFail("The scripted generation must time out")
        } catch QwenRuntimeError.requestTimedOut {}
    }

    private func assertResolvedControlStillOwnsRequest(_ runtime: MLXRuntime,
                                                      _ probe: TranslationRetirementProbe)
        async throws -> MLXRuntime.ResourceState {
        try await eventually { await probe.controlHeld }
        // The hook runs after the real continuation receives its resolved
        // result, before control() removes its entry or pause() retires/releases.
        let visible = await runtime.resourceStates()
        let state = try XCTUnwrap(visible[model])
        XCTAssertEqual(state.pendingControls, 0, "The cancellation result is already resolved")
        XCTAssertEqual(state.outstandingRequests, 1, "Resolution has not released the request")
        XCTAssertFalse(state.retiring, "The worker has not entered retirement yet")
        XCTAssertEqual(Darwin.kill(state.processIdentifier, 0), 0)
        return state
    }

    private func bootCount(_ root: URL) throws -> Int {
        try String(contentsOf: root.appendingPathComponent("boots"), encoding: .utf8)
            .split(separator: "\n").count
    }

    func testRetryWaitsThroughResolvedCancelFailureAndOwnedWorkerRetirement() async throws {
        let (runtime, root, probe) = try fixture()
        try await timeOut(runtime, prompt: "stall-first-worker")
        let old = try await assertResolvedControlStillOwnsRequest(runtime, probe)
        var retryFinished = false
        let retry = Task {
            defer { retryFinished = true }
            try await runtime.finishRetirementBeforeRetry(model)
        }
        defer { retry.cancel() }
        try await eventually { await probe.requestReleaseWaits >= 2 }
        XCTAssertFalse(retryFinished, "A resolved entry cannot admit the retry before retirement starts")
        let held = await runtime.resourceStates()[model]
        XCTAssertEqual(held?.workerID, old.workerID)
        XCTAssertFalse(held?.retiring ?? true)
        XCTAssertEqual(try bootCount(root), 1)

        await probe.releaseControl()
        try await eventually { await probe.workerExitWaits > 0 }
        try await eventually { retryFinished }
        try await retry.value
        let retired = await runtime.resourceStates()
        XCTAssertTrue(retired.isEmpty)
        XCTAssertNotEqual(Darwin.kill(old.processIdentifier, 0), 0, "Retry admission requires the old child to exit")
        let text = try await generate(runtime, prompt: "stall-first-worker", timeout: 5)
        XCTAssertEqual(text, "translated")
        let replacement = await runtime.resourceStates()[model]
        XCTAssertNotEqual(replacement?.workerID, old.workerID)
        XCTAssertEqual(replacement?.outstandingRequests, 0)
        XCTAssertEqual(try bootCount(root), 2, "Only the admitted retry may boot a replacement")
    }

    func testRetryWaitsForResolvedCancelSuccessToReleaseRequestWithoutReboot() async throws {
        let (runtime, root, probe) = try fixture()
        try await timeOut(runtime, prompt: "acknowledge-cancel")
        let old = try await assertResolvedControlStillOwnsRequest(runtime, probe)
        var retryFinished = false
        let retry = Task {
            defer { retryFinished = true }
            try await runtime.finishRetirementBeforeRetry(model)
        }
        defer { retry.cancel() }
        try await eventually { await probe.requestReleaseWaits >= 2 }
        XCTAssertFalse(retryFinished)
        await probe.releaseControl()
        try await eventually { retryFinished }
        try await retry.value
        let released = await runtime.resourceStates()[model]
        XCTAssertEqual(released?.workerID, old.workerID)
        XCTAssertEqual(released?.outstandingRequests, 0)
        XCTAssertFalse(released?.retiring ?? true)
        let exitWaits = await probe.workerExitWaits
        XCTAssertEqual(exitWaits, 0, "A successful cancellation must keep the healthy worker")
        let text = try await generate(runtime, prompt: "complete", timeout: 5)
        XCTAssertEqual(text, "translated")
        XCTAssertEqual(try bootCount(root), 1)
    }

    func testRetryWaitIsBoundedWhenResolvedCancellationCannotReleaseOwnership() async throws {
        let (runtime, root, probe) = try fixture(controlTimeout: 0.05)
        try await timeOut(runtime, prompt: "stall-first-worker")
        let old = try await assertResolvedControlStillOwnsRequest(runtime, probe)
        var retryFinished = false
        let retry = Task {
            defer { retryFinished = true }
            try await runtime.finishRetirementBeforeRetry(model)
        }
        defer { retry.cancel() }
        try await eventually { await probe.requestReleaseWaits > 0 }
        // Keep the resolved entry held. The runtime's own deadline must fail
        // admission while the test task remains uncancelled.
        try await eventually { retryFinished }
        XCTAssertFalse(retry.isCancelled)
        do {
            try await retry.value
            XCTFail("An unreleased request must exhaust the bounded retry wait")
        } catch QwenRuntimeError.generationInterrupted {}
        let held = await runtime.resourceStates()[model]
        XCTAssertEqual(held?.workerID, old.workerID)
        XCTAssertEqual(held?.outstandingRequests, 1)
        XCTAssertFalse(held?.retiring ?? true)
        XCTAssertEqual(Darwin.kill(old.processIdentifier, 0), 0)
        XCTAssertEqual(try bootCount(root), 1)
    }

    func testCancellingRetryAfterEnteringExitWaitLeavesTheExistingOwnerInCharge() async throws {
        let (runtime, root, probe) = try fixture(controlTimeout: 3, holdControl: false)
        do {
            _ = try await generate(runtime, prompt: "close-output", timeout: 5)
            XCTFail("The scripted worker must close its output")
        } catch QwenRuntimeError.processExited {}
        let visible = await runtime.resourceStates()
        let old = try XCTUnwrap(visible[model])
        XCTAssertTrue(old.retiring)
        XCTAssertEqual(Darwin.kill(old.processIdentifier, 0), 0)
        var retryFinished = false
        let retry = Task {
            defer { retryFinished = true }
            try await runtime.finishRetirementBeforeRetry(model)
        }
        defer { retry.cancel() }
        // This event comes from INSIDE the exit-wait loop, after its
        // cancellation check. Never cancel a task that has not started yet.
        try await eventually { await probe.workerExitWaits > 0 }
        XCTAssertFalse(retryFinished)
        let waiting = await runtime.resourceStates()[model]
        XCTAssertEqual(waiting?.workerID, old.workerID)
        XCTAssertTrue(waiting?.retiring == true)
        XCTAssertEqual(Darwin.kill(old.processIdentifier, 0), 0)
        retry.cancel()
        try await eventually { retryFinished }
        do {
            try await retry.value
            XCTFail("Cancellation must interrupt an active exit waiter")
        } catch is CancellationError {}
        let retained = await runtime.resourceStates()[model]
        XCTAssertEqual(retained?.workerID, old.workerID)
        XCTAssertTrue(retained?.retiring == true, "The retirement owner must still retain the running child")
        XCTAssertEqual(Darwin.kill(old.processIdentifier, 0), 0)
        XCTAssertEqual(try bootCount(root), 1, "Cancelling a waiter must not boot a replacement")

        try Data().write(to: root.appendingPathComponent("allow-exit"))
        try await runtime.finishRetirementBeforeRetry(model)
        let finished = await runtime.resourceStates()
        XCTAssertTrue(finished.isEmpty)
        XCTAssertNotEqual(Darwin.kill(old.processIdentifier, 0), 0)
        XCTAssertEqual(try bootCount(root), 1)
    }

    private static let fakeWorker = #"""
    use strict;
    use warnings;
    use JSON::PP;
    $| = 1;
    my $state;
    for (my $i = 0; $i < @ARGV; $i++) { $state = $ARGV[$i + 1] if $ARGV[$i] eq '--state-directory'; }
    my $first = !-e "$state/first-boot";
    open(my $flag, '>', "$state/first-boot") or die;
    close $flag;
    open(my $boots, '>>', "$state/boots") or die;
    print $boots "boot\n";
    close $boots;
    sub emit { my ($event, %fields) = @_; print encode_json({event => $event, %fields}), "\n"; }
    emit('ready', version => 2);
    my $stalled = 0;
    while (my $line = <STDIN>) {
        my $command = decode_json($line);
        my $op = $command->{op};
        if ($op eq 'generate') {
            emit('model_state', loaded => JSON::PP::true);
            if ($command->{prompt} eq 'close-output') {
                $SIG{TERM} = 'IGNORE';
                close STDOUT;
                while (!-e "$state/allow-exit") { select(undef, undef, undef, 0.01); }
                exit 0;
            }
            if ($command->{prompt} eq 'stall-first-worker' && $first) {
                $SIG{TERM} = 'IGNORE';
                $stalled = 1;
                next;
            }
            next if $command->{prompt} eq 'acknowledge-cancel';
            emit('done', id => $command->{id}, text => 'translated');
        } elsif ($op eq 'cancel') {
            next if $stalled;
            emit('cancel', id => $command->{id}, controlID => $command->{controlID}, state => 'released');
        } elsif ($op eq 'ack') {
            emit('ack', id => $command->{id}, controlID => $command->{controlID}, state => 'released');
        } elsif ($op eq 'shutdown') {
            emit('shutdown', controlID => $command->{controlID}, state => 'released');
            exit 0;
        }
    }
    """#
}
