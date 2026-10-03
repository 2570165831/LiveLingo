import Combine
import Foundation
import XCTest
@testable import LiveLingo

// The clock never uses a real timer, advances itself, or resumes on cancellation.
// A cancelled suspension may deliberately return success or throw much later.

@MainActor
private func waveformEventually(
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @MainActor () -> Bool
) async throws {
    for _ in 0..<1_024 {
        if condition() { return }
        await Task.yield()
    }
    guard condition() else {
        XCTFail(message, file: file, line: line)
        throw WaveformAcceptanceFailure.schedulingDidNotSettle
    }
}

private enum WaveformAcceptanceFailure: Error {
    case schedulingDidNotSettle
    case invalidSleep
}

@MainActor
private final class WaveformCompletionFlag {
    var finished = false
}

@MainActor
private func waveformFinished(
    _ task: Task<Void, Never>,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let flag = WaveformCompletionFlag()
    let observer = Task { @MainActor in
        await task.value
        flag.finished = true
    }
    defer { observer.cancel() }
    // Do not block the XCTest indefinitely on task.value if the policy is wrong.
    try await waveformEventually("The released task did not finish", file: file, line: line) {
        flag.finished
    }
}

@MainActor
private final class WaveformVirtualClock {
    struct Sleep {
        let id: Int
        let requested: TimeInterval
        let deadline: TimeInterval
    }

    // Small, fixed Date reference point: no wall-clock time or large Unix epoch.
    private(set) var instant: TimeInterval = 0
    private(set) var sleeps: [Sleep] = []
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var closed = false

    var now: Date { date(instant) }
    var pendingIDs: [Int] { pending.keys.sorted() }

    func date(_ instant: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: instant)
    }

    func advance(to instant: TimeInterval) {
        precondition(instant.isFinite && instant >= self.instant)
        self.instant = instant
        // Advancing time and delivering a callback are separate causal events.
    }

    func sleep(_ delay: TimeInterval) async throws {
        guard !closed else { throw CancellationError() }
        guard delay.isFinite && delay > 0 else {
            XCTFail("The policy requested a non-positive or non-finite sleep")
            throw WaveformAcceptanceFailure.invalidSleep
        }
        // Intentionally no Task.checkCancellation / cancellation handler here.
        // Token invalidation must work even when the injected sleeper returns late.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !closed else {
                continuation.resume(throwing: CancellationError())
                return
            }
            let id = sleeps.count + 1
            pending[id] = continuation
            sleeps.append(Sleep(id: id, requested: delay, deadline: instant + delay))
        }
    }

    func release(_ id: Int, throwing error: Error? = nil) throws {
        let continuation = try XCTUnwrap(pending.removeValue(forKey: id),
                                         "A suspension must be released exactly once")
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func awaitSleepCount(_ count: Int, file: StaticString = #filePath,
                         line: UInt = #line) async throws {
        try await waveformEventually("Expected sleep registration did not arrive",
                                     file: file, line: line) {
            self.sleeps.count >= count
        }
        XCTAssertEqual(sleeps.count, count, "Unexpected extra sleep", file: file, line: line)
    }

    func makeState() -> WaveformFreshnessState {
        WaveformFreshnessState(now: { [self] in now },
                               sleep: { [self] delay in try await sleep(delay) })
    }

    func close() {
        closed = true
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: CancellationError())
        }
    }
}

@MainActor
private final class WaveformPublicationLog {
    private(set) var values: [Bool] = []
    private var subscription: AnyCancellable?

    init(_ state: WaveformFreshnessState) {
        subscription = state.$isReceiving.dropFirst().sink { [weak self] value in
            self?.values.append(value)
        }
    }
}

@MainActor
private final class WaveformAcceptanceFixture {
    let clock: WaveformVirtualClock
    let state: WaveformFreshnessState
    let publications: WaveformPublicationLog

    init() {
        let clock = WaveformVirtualClock()
        let state = clock.makeState()
        self.clock = clock
        self.state = state
        publications = WaveformPublicationLog(state)
    }

    func close() {
        state.unmount()
        clock.close()
    }
}

@MainActor
final class WaveformFreshnessAcceptanceTests: XCTestCase {
    func testUnmountedNilStaleAndInactiveInputsDoNotStartWork() async throws {
        let f = WaveformAcceptanceFixture()
        defer { f.close() }
        XCTAssertEqual(WaveformFreshnessState.freshnessSeconds, 0.6)
        XCTAssertFalse(f.state.isReceiving)

        f.state.update(active: true, lastUpdate: f.clock.date(0))
        XCTAssertFalse(f.state.isReceiving, "An unmounted update only caches input")
        XCTAssertNil(f.state.taskForTesting)
        f.clock.advance(to: 0.2)
        f.state.mount(active: true, lastUpdate: nil)
        f.state.update(active: true, lastUpdate: f.clock.date(-10))
        f.clock.advance(to: 30)
        f.state.update(active: true, lastUpdate: f.clock.date(-10))
        f.state.update(active: false, lastUpdate: f.clock.date(30))
        for _ in 0..<32 { await Task.yield() }

        XCTAssertFalse(f.state.isReceiving)
        XCTAssertNil(f.state.taskForTesting)
        XCTAssertTrue(f.clock.sleeps.isEmpty)
        XCTAssertEqual(f.state.diagnostics.tasksStarted, 0)
        XCTAssertEqual(f.state.diagnostics.tasksCancelled, 0)
        XCTAssertEqual(f.state.diagnostics.sleepsArmed, 0)
        XCTAssertEqual(f.state.diagnostics.wakes, 0)
        XCTAssertEqual(f.state.diagnostics.stateChanges, 0)
        XCTAssertEqual(f.publications.values, [])
    }

    func testDuplicateTimestampKeepsOriginalDeadlineAndLateWakeStopsOnce() async throws {
        let f = WaveformAcceptanceFixture()
        defer { f.close() }
        f.state.mount(active: true, lastUpdate: f.clock.date(0))
        let task = try XCTUnwrap(f.state.taskForTesting)
        try await f.clock.awaitSleepCount(1)
        XCTAssertEqual(f.clock.sleeps[0].deadline, 0.6, accuracy: 1e-9)

        for instant in [0.3, 0.5] {
            f.clock.advance(to: instant)
            f.state.update(active: true, lastUpdate: f.clock.date(0))
        }
        XCTAssertTrue(f.state.isReceiving)
        XCTAssertEqual(f.state.diagnostics.tasksStarted, 1)
        XCTAssertEqual(f.state.diagnostics.tasksCancelled, 0)
        // A delayed callback is permitted; it must not create a catch-up timer.
        f.clock.advance(to: 0.75)
        try f.clock.release(1)
        try await waveformFinished(task)

        XCTAssertFalse(f.state.isReceiving)
        XCTAssertNil(f.state.taskForTesting)
        XCTAssertEqual(f.clock.sleeps.count, 1)
        XCTAssertTrue(f.clock.pendingIDs.isEmpty)
        XCTAssertEqual(f.state.diagnostics.wakes, 1)
        XCTAssertEqual(f.state.diagnostics.stateChanges, 2)
        XCTAssertEqual(f.publications.values, [true, false])
        f.clock.advance(to: 60)
        f.state.update(active: true, lastUpdate: f.clock.date(0))
        XCTAssertNil(f.state.taskForTesting)
        XCTAssertEqual(f.state.diagnostics.tasksStarted, 1)
        XCTAssertEqual(f.publications.values, [true, false])
    }

    func testContinuousTimestampInputReusesTaskWithoutFalsePulseThenStops() async throws {
        let f = WaveformAcceptanceFixture()
        defer { f.close() }
        f.state.mount(active: true, lastUpdate: f.clock.date(0))
        let task = try XCTUnwrap(f.state.taskForTesting)
        try await f.clock.awaitSleepCount(1)

        // These exact policy inputs also represent zero-amplitude meter events.
        // Amplitude and Reduce Motion are deliberately not fabricated API inputs.
        for instant in [0.1, 0.2, 0.3, 0.4, 0.5, 0.6] {
            f.clock.advance(to: instant)
            f.state.update(active: true, lastUpdate: f.clock.date(instant))
        }
        // The event at 0.6 arrives BEFORE delivery of the original expiry wake.
        try f.clock.release(1)
        try await f.clock.awaitSleepCount(2)
        XCTAssertEqual(f.clock.sleeps[1].deadline, 1.2, accuracy: 1e-9)
        XCTAssertTrue(f.state.isReceiving)
        XCTAssertFalse(task.isCancelled)
        XCTAssertEqual(f.state.diagnostics.tasksStarted, 1)
        XCTAssertEqual(f.state.diagnostics.tasksCancelled, 0)
        XCTAssertEqual(f.state.diagnostics.wakes, 1)
        XCTAssertEqual(f.publications.values, [true])

        f.clock.advance(to: 1.2)
        try f.clock.release(2)
        try await waveformFinished(task)
        XCTAssertFalse(f.state.isReceiving)
        XCTAssertNil(f.state.taskForTesting)
        XCTAssertEqual(f.state.diagnostics.tasksStarted, 1)
        XCTAssertEqual(f.state.diagnostics.tasksCancelled, 0)
        XCTAssertEqual(f.state.diagnostics.sleepsArmed, 2)
        XCTAssertEqual(f.state.diagnostics.wakes, 2)
        XCTAssertEqual(f.state.diagnostics.stateChanges, 2)
        XCTAssertEqual(f.publications.values, [true, false])
        f.clock.advance(to: 30)
        for _ in 0..<32 { await Task.yield() }
        XCTAssertEqual(f.clock.sleeps.count, 2)
        XCTAssertTrue(f.clock.pendingIDs.isEmpty)
        XCTAssertNil(f.state.taskForTesting)
    }

    func testNearExpiryInputUsesItsTimestampRatherThanWakeTime() async throws {
        let f = WaveformAcceptanceFixture()
        defer { f.close() }
        f.state.mount(active: true, lastUpdate: f.clock.date(0))
        let task = try XCTUnwrap(f.state.taskForTesting)
        try await f.clock.awaitSleepCount(1)
        f.clock.advance(to: 0.59)
        f.state.update(active: true, lastUpdate: f.clock.date(0.59))
        f.clock.advance(to: 0.6)
        try f.clock.release(1)
        try await f.clock.awaitSleepCount(2)

        XCTAssertEqual(f.clock.sleeps[1].deadline, 1.19, accuracy: 1e-9,
                       "Do not restart a full freshness window at the wake")
        XCTAssertEqual(f.clock.sleeps[1].requested, 0.59, accuracy: 1e-9)
        XCTAssertEqual(f.publications.values, [true])
        XCTAssertEqual(f.state.diagnostics.tasksStarted, 1)
        XCTAssertEqual(f.state.diagnostics.tasksCancelled, 0)
        // Slightly past the non-exact binary boundary, independently of rounding.
        f.clock.advance(to: 1.1901)
        try f.clock.release(2)
        try await waveformFinished(task)
        XCTAssertFalse(f.state.isReceiving)
        XCTAssertNil(f.state.taskForTesting)
        XCTAssertEqual(f.publications.values, [true, false])
        XCTAssertEqual(f.clock.sleeps.count, 2)
    }

    func testPauseResumeOldSuccessfulReturnCannotClearReplacement() async throws {
        let f = WaveformAcceptanceFixture()
        defer { f.close() }
        f.state.mount(active: true, lastUpdate: f.clock.date(0))
        let retired = try XCTUnwrap(f.state.taskForTesting)
        try await f.clock.awaitSleepCount(1)
        f.clock.advance(to: 0.1)
        f.state.update(active: false, lastUpdate: f.clock.date(0))
        XCTAssertFalse(f.state.isReceiving)
        XCTAssertTrue(retired.isCancelled)
        XCTAssertNil(f.state.taskForTesting)

        f.clock.advance(to: 0.2)
        f.state.update(active: true, lastUpdate: f.clock.date(0))
        let replacement = try XCTUnwrap(f.state.taskForTesting)
        try await f.clock.awaitSleepCount(2)
        XCTAssertEqual(f.clock.sleeps[1].deadline, 0.6, accuracy: 1e-9,
                       "Resume gets only the original event's remaining lifetime")
        f.clock.advance(to: 0.25)
        try f.clock.release(1) // Cancelled sleeper returns normally, deliberately late.
        try await waveformFinished(retired)
        XCTAssertTrue(f.state.isReceiving)
        XCTAssertNotNil(f.state.taskForTesting)
        XCTAssertFalse(replacement.isCancelled)
        XCTAssertEqual(f.clock.pendingIDs, [2])
        XCTAssertEqual(f.state.diagnostics.wakes, 0, "Obsolete token wakes are excluded")
        XCTAssertEqual(f.publications.values, [true, false, true])

        f.clock.advance(to: 0.6)
        try f.clock.release(2)
        try await waveformFinished(replacement)
        XCTAssertFalse(f.state.isReceiving)
        XCTAssertNil(f.state.taskForTesting)
        XCTAssertEqual(f.state.diagnostics.tasksStarted, 2)
        XCTAssertEqual(f.state.diagnostics.tasksCancelled, 1)
        XCTAssertEqual(f.state.diagnostics.wakes, 1)
        XCTAssertEqual(f.state.diagnostics.stateChanges, 4)
        XCTAssertEqual(f.publications.values, [true, false, true, false])
        f.clock.advance(to: 1)
        f.state.update(active: true, lastUpdate: f.clock.date(0))
        XCTAssertNil(f.state.taskForTesting)
        XCTAssertEqual(f.state.diagnostics.tasksStarted, 2)
    }

    func testUnmountedUpdateAndLateCancellationCannotAffectRemount() async throws {
        let f = WaveformAcceptanceFixture()
        defer { f.close() }
        f.state.mount(active: true, lastUpdate: f.clock.date(0))
        let retired = try XCTUnwrap(f.state.taskForTesting)
        try await f.clock.awaitSleepCount(1)
        f.clock.advance(to: 0.1)
        f.state.unmount()
        XCTAssertFalse(f.state.isReceiving)
        XCTAssertTrue(retired.isCancelled)
        XCTAssertNil(f.state.taskForTesting)
        f.clock.advance(to: 0.2)
        f.state.update(active: true, lastUpdate: f.clock.date(0.2))
        XCTAssertFalse(f.state.isReceiving)
        XCTAssertNil(f.state.taskForTesting)
        XCTAssertEqual(f.state.diagnostics.tasksStarted, 1)

        f.clock.advance(to: 0.25)
        f.state.mount(active: true, lastUpdate: f.clock.date(0.2))
        let replacement = try XCTUnwrap(f.state.taskForTesting)
        try await f.clock.awaitSleepCount(2)
        XCTAssertEqual(f.clock.sleeps[1].deadline, 0.8, accuracy: 1e-9)
        f.clock.advance(to: 0.3)
        try f.clock.release(1, throwing: CancellationError())
        try await waveformFinished(retired)
        XCTAssertTrue(f.state.isReceiving)
        XCTAssertNotNil(f.state.taskForTesting)
        XCTAssertFalse(replacement.isCancelled)
        XCTAssertEqual(f.clock.pendingIDs, [2])
        XCTAssertEqual(f.state.diagnostics.wakes, 0)
        XCTAssertEqual(f.publications.values, [true, false, true])

        f.clock.advance(to: 0.8001)
        try f.clock.release(2)
        try await waveformFinished(replacement)
        XCTAssertFalse(f.state.isReceiving)
        XCTAssertNil(f.state.taskForTesting)
        XCTAssertEqual(f.state.diagnostics.tasksStarted, 2)
        XCTAssertEqual(f.state.diagnostics.tasksCancelled, 1)
        XCTAssertEqual(f.state.diagnostics.wakes, 1)
        XCTAssertEqual(f.publications.values, [true, false, true, false])
    }

    func testNilResetCancelsAndExactlyExpiredTimestampCannotRestart() async throws {
        let f = WaveformAcceptanceFixture()
        defer { f.close() }
        f.state.mount(active: true, lastUpdate: f.clock.date(0))
        let retired = try XCTUnwrap(f.state.taskForTesting)
        try await f.clock.awaitSleepCount(1)
        f.clock.advance(to: 0.2)
        f.state.update(active: true, lastUpdate: nil)
        XCTAssertFalse(f.state.isReceiving)
        XCTAssertTrue(retired.isCancelled)
        XCTAssertNil(f.state.taskForTesting)
        f.clock.advance(to: 0.3)
        try f.clock.release(1)
        try await waveformFinished(retired)
        XCTAssertEqual(f.state.diagnostics.wakes, 0)

        f.clock.advance(to: 0.6)
        f.state.update(active: true, lastUpdate: f.clock.date(0))
        XCTAssertFalse(f.state.isReceiving, "Exactly 0.6 seconds old is not fresh")
        XCTAssertNil(f.state.taskForTesting)
        f.clock.advance(to: 30)
        f.state.update(active: true, lastUpdate: nil)
        XCTAssertNil(f.state.taskForTesting)
        XCTAssertEqual(f.state.diagnostics.tasksStarted, 1)
        XCTAssertEqual(f.state.diagnostics.tasksCancelled, 1)
        XCTAssertEqual(f.state.diagnostics.sleepsArmed, 1)
        XCTAssertEqual(f.state.diagnostics.stateChanges, 2)
        XCTAssertEqual(f.publications.values, [true, false])
        XCTAssertTrue(f.clock.pendingIDs.isEmpty)
    }

    func testSuspendedTaskDoesNotRetainOwnerOrDisturbNewOwner() async throws {
        let clock = WaveformVirtualClock()
        var owner: WaveformFreshnessState? = clock.makeState()
        weak var departedOwner = owner
        var newOwner: WaveformFreshnessState?
        var retiredTask: Task<Void, Never>?
        var replacementTask: Task<Void, Never>?
        defer {
            // Also releases continuations if the weak-owner assertion fails.
            departedOwner?.unmount()
            owner?.unmount()
            newOwner?.unmount()
            retiredTask?.cancel()
            replacementTask?.cancel()
            clock.close()
        }

        owner?.mount(active: true, lastUpdate: clock.date(0))
        retiredTask = try XCTUnwrap(owner?.taskForTesting)
        let retired = try XCTUnwrap(retiredTask)
        try await clock.awaitSleepCount(1)
        owner = nil // Do not explicitly unmount: deinit is the behavior under test.
        try await waveformEventually("A suspended freshness task retained its owner") {
            departedOwner == nil
        }
        XCTAssertTrue(retired.isCancelled, "Releasing the owner cancels its task")

        clock.advance(to: 0.2)
        newOwner = clock.makeState()
        let current = try XCTUnwrap(newOwner)
        let publications = WaveformPublicationLog(current)
        current.mount(active: true, lastUpdate: clock.date(0.2))
        replacementTask = try XCTUnwrap(current.taskForTesting)
        let replacement = try XCTUnwrap(replacementTask)
        try await clock.awaitSleepCount(2)
        clock.advance(to: 0.3)
        try clock.release(1)
        try await waveformFinished(retired)
        XCTAssertNil(departedOwner)
        XCTAssertTrue(current.isReceiving)
        XCTAssertNotNil(current.taskForTesting)
        XCTAssertFalse(replacement.isCancelled)
        XCTAssertEqual(current.diagnostics.tasksStarted, 1)
        XCTAssertEqual(current.diagnostics.tasksCancelled, 0)
        XCTAssertEqual(current.diagnostics.wakes, 0)
        XCTAssertEqual(publications.values, [true])

        clock.advance(to: 0.8001)
        try clock.release(2)
        try await waveformFinished(replacement)
        XCTAssertFalse(current.isReceiving)
        XCTAssertNil(current.taskForTesting)
        XCTAssertEqual(current.diagnostics.wakes, 1)
        XCTAssertEqual(current.diagnostics.tasksStarted, 1)
        XCTAssertEqual(current.diagnostics.tasksCancelled, 0)
        XCTAssertEqual(publications.values, [true, false])
        XCTAssertTrue(clock.pendingIDs.isEmpty)
    }
}
