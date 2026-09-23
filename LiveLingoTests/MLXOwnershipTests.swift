import XCTest
import Darwin
@testable import LiveLingo

/// Real pipes and owned child processes, with deterministic fake generations.
/// No model, production preferences or real checkpoint directory is accessed.
@MainActor
final class MLXOwnershipTests: XCTestCase {
    private let model = "qwen3.5-4b-mlx"

    private func makeRuntime(timeout: TimeInterval = 1) throws -> (MLXRuntime, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-ownership-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake-worker.pl")
        try Self.worker.write(to: script, atomically: true, encoding: .utf8)
        return (MLXRuntime(testConfiguration: .init(python: URL(fileURLWithPath: "/usr/bin/perl"),
            script: script, models: directory, state: directory, controlTimeout: timeout)), directory)
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

    func testClosedOutputKeepsRetiringProcessVisibleUntilActualExit() async throws {
        let (runtime, directory) = try makeRuntime(timeout: 0.5)
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
        select(undef, undef, undef, 0.2) if ($requests{$rid} // '') eq 'complete';
        emit($op, id => $rid, controlID => $control, state => 'released');
    } elsif ($op eq 'shutdown') {
        select(undef, undef, undef, 0.1);
        emit('shutdown', controlID => $control, state => 'ready_to_exit');
        last;
    }
}
"""#
}
