import XCTest
import Darwin
@testable import LiveLingo

private actor ModelSwitchProbe {
    private(set) var events: [String] = []
    private var blocked: Set<String>
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    init(blocked: Set<String> = []) { self.blocked = blocked }
    func record(_ event: String) async {
        events.append(event)
        if blocked.contains(event) {
            await withCheckedContinuation { waiters[event] = $0 }
        }
    }
    func release(_ event: String) {
        blocked.remove(event)
        waiters.removeValue(forKey: event)?.resume()
    }
}

private final class MLXOwnershipRetirementProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.withLock { recorded } }
    func record(_ event: MLXRuntime.RetirementEventForTesting) {
        lock.withLock { recorded.append(event.rawValue) }
    }
}

@MainActor
final class TranslationModelLifetimeTests: XCTestCase {
    private let old = QwenModelProfile.highQuality.translationModel
    private let next = QwenModelProfile.energySaver.translationModel
    private func waitFor(_ event: String, in probe: ModelSwitchProbe) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await probe.events.contains(event) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Model lifecycle did not reach \(event)")
    }

    func testSwitchWaitsForOldRequestAndConfirmedRetirement() async throws {
        let probe = ModelSwitchProbe(blocked: ["old_started", "unload_started"])
        addTeardownBlock { await probe.release("old_started"); await probe.release("unload_started") }
        let previousModel = old
        let lifetime = TranslationModelLifetime(unload: { model in
            guard model == previousModel else { return }
            await probe.record("unload_started")
            await probe.record("unload_finished")
        })
        await lifetime.select(old)
        let previous = Task { try await lifetime.withModel(old) {
            await probe.record("old_started")
            await probe.record("old_finished")
            return "old"
        } }
        await waitFor("old_started", in: probe)
        await lifetime.select(next)
        let replacement = Task { try await lifetime.withModel(next) {
            await probe.record("new_started")
            return "new"
        } }
        await probe.release("old_started")
        _ = try await previous.value
        await waitFor("unload_started", in: probe)
        let beforeExit = await probe.events
        XCTAssertFalse(beforeExit.contains("new_started"), "The new model cannot load before the old one exits")
        await probe.release("unload_started")
        _ = try await replacement.value
        let events = await probe.events
        XCTAssertEqual(events, ["old_started", "old_finished", "unload_started", "unload_finished", "new_started"])
    }

    func testUnconfirmedRetirementCannotAdmitNewModel() async throws {
        let probe = ModelSwitchProbe()
        let previousModel = old
        let lifetime = TranslationModelLifetime(unload: { model in
            guard model == previousModel else { return }
            await probe.record("unload_failed")
            throw QwenRuntimeError.requestFailed("Owned old model has not exited")
        })
        await lifetime.select(old)
        _ = try await lifetime.withModel(old) { "old" }
        await lifetime.select(next)
        await waitFor("unload_failed", in: probe)
        do {
            _ = try await lifetime.withModel(next) {
                await probe.record("new_started")
                return "new"
            }
            XCTFail("Failed retirement must block loading another model")
        } catch { XCTAssertTrue(error is QwenRuntimeError) }
        let events = await probe.events
        XCTAssertFalse(events.contains("new_started"))
    }
}

/// Real pipes and owned child processes, with deterministic fake generations.
/// No model, production preferences or real checkpoint directory is accessed.
@MainActor
final class MLXOwnershipTests: XCTestCase {
    private let model = "qwen3.5-4b-mlx"

    private func makeRuntime(timeout: TimeInterval = 1,
                             onRetirementEvent: (@Sendable (MLXRuntime.RetirementEventForTesting) -> Void)? = nil)
        throws -> (MLXRuntime, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-ownership-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake-worker.pl")
        try Self.worker.write(to: script, atomically: true, encoding: .utf8)
        var configuration = MLXRuntime.TestConfiguration(python: URL(fileURLWithPath: "/usr/bin/perl"),
            script: script, models: directory, state: directory, controlTimeout: timeout)
        configuration.onRetirementEvent = onRetirementEvent
        return (MLXRuntime(testConfiguration: configuration), directory)
    }

    private func generate(_ runtime: MLXRuntime, prompt: String,
                          identity: ReviewRequestIdentityBox? = nil) async throws -> String {
        try await runtime.generate(model: model, prompt: prompt, input: "", prefix: "", thinking: false,
            purpose: "note", finalBudget: 128, timeout: 5,
            onRequestIdentity: { identity?.record($0) }, onUpdate: { _ in })
    }

    private func waitFor(_ condition: @escaping () async -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Owned runtime did not reach the expected state", file: file, line: line)
    }

    func testCancellationKeepsOwnershipUntilMatchingPauseAcknowledgement() async throws {
        let (runtime, directory) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task { try await generate(runtime, prompt: "wait") }
        await waitFor { await runtime.resourceStates()[self.model]?.modelLoaded == true }
        task.cancel()
        await waitFor { await runtime.resourceStates()[self.model]?.pendingControls == 1 }
        // Fake worker emits a wrong control ID first. It cannot release this lease.
        try await Task.sleep(for: .milliseconds(40))
        let pending = await runtime.resourceStates()[model]
        XCTAssertEqual(pending?.outstandingRequests, 1)
        XCTAssertEqual(pending?.pendingControls, 1)
        if case .success = await task.result { XCTFail("Cancelled generation succeeded") }
        await waitFor { await runtime.resourceStates()[self.model]?.outstandingRequests == 0 }
        await runtime.unload(model)
        let final = await runtime.resourceStates()
        XCTAssertTrue(final.isEmpty)
    }

    func testCompletedWireKeepsLeaseUntilDeliveryAcknowledged() async throws {
        let (runtime, directory) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = ReviewRequestIdentityBox()
        let task = Task { try await generate(runtime, prompt: "complete", identity: identity) }
        await waitFor { await runtime.resourceStates()[self.model]?.pendingControls == 1 }
        let pending = await runtime.resourceStates()[model]
        XCTAssertEqual(pending?.outstandingRequests, 1)
        let requestID = try XCTUnwrap(identity.latest)
        XCTAssertEqual(pending?.requestIDs, [requestID])
        XCTAssertEqual(pending?.acknowledgingRequestIDs, [requestID])
        await runtime.unload(model) // Cannot retire a delivered-but-unacknowledged request.
        let stillOwned = await runtime.resourceStates()[model]
        XCTAssertEqual(stillOwned?.workerID, pending?.workerID)
        let text = try await task.value
        XCTAssertEqual(text, "complete")
        let released = await runtime.resourceStates()[model]
        XCTAssertEqual(released?.outstandingRequests, 0)
        XCTAssertTrue(released?.requestIDs.isEmpty == true)
        XCTAssertTrue(released?.acknowledgingRequestIDs.isEmpty == true)
        await runtime.unload(model)
    }

    func testPauseTimeoutExitsOnlyOwnedWorkerAndAllowsNewWorker() async throws {
        let (runtime, directory) = try makeRuntime(timeout: 0.15)
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task { try await generate(runtime, prompt: "hang") }
        await waitFor { await runtime.resourceStates()[self.model]?.modelLoaded == true }
        let initialStates = await runtime.resourceStates()
        let old = try XCTUnwrap(initialStates[model])
        task.cancel()
        _ = await task.result
        await waitFor { Darwin.kill(old.processIdentifier, 0) != 0 }
        let replacement = try await generate(runtime, prompt: "fast")
        XCTAssertEqual(replacement, "complete")
        let current = await runtime.resourceStates()[model]
        XCTAssertNotEqual(current?.workerID, old.workerID)
        await runtime.unload(model)
    }

    func testShutdownPreventsSwitchBackFromReusingRetiringProcess() async throws {
        let (runtime, directory) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await generate(runtime, prompt: "fast")
        let retiring = Task { await runtime.unload(model) }
        await waitFor { await runtime.resourceStates()[self.model]?.retiring == true }
        do {
            _ = try await generate(runtime, prompt: "fast")
            XCTFail("Generation reused a retiring process")
        } catch { XCTAssertTrue(error is QwenRuntimeError) }
        await retiring.value
        let states = await runtime.resourceStates()
        XCTAssertTrue(states.isEmpty)
    }

    func testOutputLimitUsesStructuredCodeAndReleasesFailedRequest() async throws {
        let (runtime, directory) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: directory) }
        for prompt in ["budget-error", "legacy-error"] {
            do {
                _ = try await generate(runtime, prompt: prompt)
                XCTFail("An error event cannot complete a request")
            } catch let error as QwenRuntimeError {
                if prompt == "budget-error" {
                    guard case .outputLimitReached = error else { return XCTFail("Lost structured output limit") }
                    XCTAssertEqual(CaptionTranslationAttempt.recovery(for: error), .expandedBudget)
                } else {
                    guard case .requestFailed = error else { return XCTFail("Guessed a type from message text") }
                    XCTAssertEqual(CaptionTranslationAttempt.recovery(for: error), .standard)
                }
            }
            let states = await runtime.resourceStates()
            XCTAssertEqual(states[model]?.outstandingRequests, 0)
        }
        await runtime.unload(model)
    }

    func testClosedOutputKeepsRetiringProcessVisibleUntilActualExit() async throws {
        let probe = MLXOwnershipRetirementProbe()
        let (runtime, directory) = try makeRuntime(timeout: 0.5, onRetirementEvent: { probe.record($0) })
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task { try await generate(runtime, prompt: "close-pipe") }
        await waitFor { await runtime.resourceStates()[self.model]?.retiring == true }
        let state = await runtime.resourceStates()[model]
        let retained = try XCTUnwrap(state)
        XCTAssertEqual(retained.outstandingRequests, 1)
        XCTAssertEqual(Darwin.kill(retained.processIdentifier, 0), 0)
        _ = await task.result
        await waitFor { await runtime.resourceStates().isEmpty }
        XCTAssertNotEqual(Darwin.kill(retained.processIdentifier, 0), 0)
        XCTAssertEqual(probe.events,
            ["inputClosed", "forceKillSent", "exitObserved", "stdoutJoined", "stderrJoined", "retired"],
            "Stdout EOF cannot release ownership before exact-child exit and both reader joins")
    }

    func testImmediateAcknowledgementsCompleteWithoutChangingResultsOrWorker() async throws {
        let (runtime, directory) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await generate(runtime, prompt: "fast")
        let initial = await runtime.resourceStates()[model]?.workerID
        var durations: [Double] = []
        for _ in 0..<32 {
            let start = ProcessInfo.processInfo.systemUptime
            let result = try await generate(runtime, prompt: "fast")
            durations.append(ProcessInfo.processInfo.systemUptime - start)
            XCTAssertEqual(result, "complete")
            let state = await runtime.resourceStates()[model]
            XCTAssertEqual(state?.workerID, initial)
            XCTAssertEqual(state?.outstandingRequests, 0)
            XCTAssertEqual(state?.pendingControls, 0)
        }
        print("CONTROL_ACK_ROUND_TRIPS " + String(decoding: try JSONEncoder().encode(durations), as: UTF8.self))
        await runtime.unload(model)
    }

    func testFirstMatchingAcknowledgementCannotBeOverwrittenByDuplicate() async throws {
        let (runtime, directory) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await generate(runtime, prompt: "duplicate-ack")
        XCTAssertEqual(result, "complete")
        let state = await runtime.resourceStates()[model]
        XCTAssertEqual(state?.outstandingRequests, 0)
        XCTAssertEqual(state?.pendingControls, 0)
        await runtime.unload(model)
    }

    func testFailedAcknowledgementCannotBeOverwrittenByLaterSuccess() async throws {
        let (runtime, directory) = try makeRuntime(timeout: 0.5)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await generate(runtime, prompt: "failed-then-success-ack")
            XCTFail("A failed checkpoint acknowledgement must not become success")
        } catch let error as QwenRuntimeError {
            guard case .generationInterrupted = error else {
                return XCTFail("Lost failed acknowledgement error")
            }
        }
        await runtime.unload(model)
    }

    func testWorkerExitResolvesOutstandingAcknowledgement() async throws {
        let (runtime, directory) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await generate(runtime, prompt: "exit-on-ack")
            XCTFail("A worker exit cannot confirm delivery")
        } catch {
            XCTAssertTrue(error is QwenRuntimeError)
        }
        await waitFor { await runtime.resourceStates().isEmpty }
    }

    private static let worker = #"""
use strict;
use warnings;
use JSON::PP;
$| = 1;
sub emit {
    my ($event, %values) = @_;
    print encode_json({event => $event, %values}), "\n";
}
emit('ready', version => 2);
my %requests;
while (my $line = <STDIN>) {
    my $command = decode_json($line);
    my $op = $command->{op};
    my $rid = $command->{id};
    my $control = $command->{controlID};
    if ($op eq 'generate') {
        $requests{$rid} = $command->{prompt};
        emit('model_state', loaded => JSON::PP::true);
        if ($command->{prompt} eq 'budget-error' || $command->{prompt} eq 'legacy-error') {
            my %code = $command->{prompt} eq 'budget-error' ? (code => 'output_budget_exhausted') : ();
            emit('error', id => $rid, message => 'Final output budget exhausted',
                 recoverable => JSON::PP::false, %code);
            next;
        }
        emit('snapshot', id => $rid, wire => 'progress');
        if ($command->{prompt} eq 'close-pipe') {
            $SIG{TERM} = 'IGNORE';
            close STDOUT;
            select(undef, undef, undef, 10);
            last;
        }
        if ($command->{prompt} ne 'wait' && $command->{prompt} ne 'hang') {
            emit('done', id => $rid, wire => 'complete', text => 'complete');
        }
    } elsif ($op eq 'pause') {
        select(undef, undef, undef, 10) if ($requests{$rid} // '') eq 'hang';
        emit('paused', id => $rid, controlID => 'wrong-' . $control, state => 'saved');
        select(undef, undef, undef, 0.2);
        emit('paused', id => $rid, controlID => $control, state => 'saved');
    } elsif ($op eq 'cancel' || $op eq 'ack') {
        exit 3 if $op eq 'ack' && ($requests{$rid} // '') eq 'exit-on-ack';
        select(undef, undef, undef, 0.2) if ($requests{$rid} // '') eq 'complete';
        if ($op eq 'ack' && ($requests{$rid} // '') eq 'failed-then-success-ack') {
            emit('ack', id => $rid, controlID => $control, state => 'checkpoint_failed');
        }
        emit($op, id => $rid, controlID => $control, state => 'released');
        if ($op eq 'ack' && ($requests{$rid} // '') eq 'duplicate-ack') {
            emit('ack', id => $rid, controlID => $control, state => 'checkpoint_failed');
        }
    } elsif ($op eq 'shutdown') {
        select(undef, undef, undef, 0.1);
        emit('shutdown', controlID => $control, state => 'ready_to_exit');
        last;
    }
}
"""#
}

/// Readiness only checks that files exist; it never parses weight headers.
final class MLXModelReadinessTests: XCTestCase {
    private var root: URL!
    private var model: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-readiness-\(UUID())")
        model = root.appendingPathComponent("models/mlx-community/Qwen3.5-4B-MLX-8bit")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        for name in ["config.json", "tokenizer.json"] { try write("{}", to: name) }
        let worker = root.appendingPathComponent("worker.py")
        try Data().write(to: worker)
        let environment = ["LIVELINGO_MLX_PYTHON": "/usr/bin/python3", "LIVELINGO_MLX_WORKER": worker.path,
                           "LIVELINGO_MLX_MODELS": root.appendingPathComponent("models").path,
                           "LIVELINGO_MLX_STATE": root.appendingPathComponent("state").path]
        var previous: [String: String?] = [:]
        for (key, value) in environment {
            previous[key] = .some(ProcessInfo.processInfo.environment[key])
            setenv(key, value, 1)
        }
        let restore = previous, directory = root!
        addTeardownBlock {
            for (key, value) in restore {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: model.appendingPathComponent(name))
    }

    private func assertIncomplete(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try MLXRuntime.checkModel("qwen3.5-4b-mlx"), message, file: file, line: line) { error in
            guard case QwenRuntimeError.modelUnavailable = error else {
                return XCTFail("Expected modelUnavailable, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(error.localizedDescription.contains("请重新安装"), file: file, line: line)
        }
    }

    func testConfigAndTokenizerWithoutWeightsAreNotReady() {
        assertIncomplete("A model without any weight file must not pass readiness")
        try? write("", to: "notes.safetensors")
        assertIncomplete("Only model*.safetensors files count as model weights")
    }

    func testSingleWeightFileIsReady() throws {
        try write("", to: "model.safetensors")
        XCTAssertNoThrow(try MLXRuntime.checkModel("qwen3.5-4b-mlx"))
    }

    func testIndexRequiresEveryReferencedShard() throws {
        try write(#"{"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}"#,
                  to: "model.safetensors.index.json")
        try write("", to: "model-00001-of-00002.safetensors")
        assertIncomplete("A missing shard listed in the index must not pass readiness")
        try write("", to: "model-00002-of-00002.safetensors")
        XCTAssertNoThrow(try MLXRuntime.checkModel("qwen3.5-4b-mlx"))
    }

    func testUnusableIndexIsNotReadyEvenWithAWeightFile() throws {
        try write("", to: "model.safetensors")
        try Data().write(to: model.deletingLastPathComponent().appendingPathComponent("outside.safetensors"))
        for index in ["not json", #"{"weight_map": {}}"#, #"{"weight_map": {"a": "../outside.safetensors"}}"#] {
            try write(index, to: "model.safetensors.index.json")
            assertIncomplete("An unusable shard index must not pass readiness")
        }
        try FileManager.default.createDirectory(at: model.appendingPathComponent("shard.safetensors"),
                                                withIntermediateDirectories: true)
        try write(#"{"weight_map": {"a": "shard.safetensors"}}"#, to: "model.safetensors.index.json")
        assertIncomplete("A directory is not a weight file")
    }
}
