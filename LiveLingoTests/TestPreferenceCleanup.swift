import Darwin
import Foundation
import XCTest
@testable import LiveLingo

/// Both frameworks share the host's unique worker directory. All synthetic
/// fixtures and screenshots remain under this invocation's DerivedData/tmp.
enum TestFixtureDirectory {
    static let root: URL = {
        guard let root = AppRuntimeEnvironment.unitTestTemporaryDirectory else {
            preconditionFailure("Tests require an isolated host temporary directory")
        }
        return root
    }()
}

/// CFFIXED_USER_HOME does not redirect cfprefsd. Remove only a fresh UUID suite
/// registered by this test, after flushing its empty persistent domain.
struct TestPreferenceCleanup: Sendable {
    private let suite: String
    private let plist: URL

    init(suite: String) throws {
        let prefixes = [
            "SpanishFrenchTarget-",
            "FullScreenClassMode-",
            "FloatingSubtitleDisplay-",
            "EnglishTargetPanel-",
            "ClassroomPresentation-",
            "LiveLingoMeterTest-",
            "LiveLingo-CaptionIdentity-",
            "LiveLingo-StabilityDraft-",
            "LiveLingo-StabilityLifecycle-",
            "LiveLingo-Publication-",
            "LiveLingo-CaptionScheduling-",
            "DefaultTargetGolden-",
            "LiveLingo-LatinDefaultPipeline-",
            "LiveLingo-MultilingualAppModel-",
            "LiveLingo-MultilingualCaptionGate-",
            "MultilingualPreview-",
            "LiveLingo-V2bRecovery-",
            "OutputLanguageBaseline-",
            "LiveLingo-Race-",
            "LiveLingo-Test-",
            "LiveLingo-Item7-",
        ]
        guard let prefix = prefixes.first(where: suite.hasPrefix),
              UUID(uuidString: String(suite.dropFirst(prefix.count))) != nil,
              let directory = getpwuid(getuid())?.pointee.pw_dir else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        self.suite = suite
        plist = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent(suite + ".plist")
        guard try Self.fileStatus(at: plist) == nil else {
            throw CocoaError(.fileWriteFileExists)
        }
        _ = PendingTestPreferences.shared
        try Self.emit("CREATED", suite: suite)
    }

    func remove(_ defaults: UserDefaults) throws {
        let hadValues = defaults.persistentDomain(forName: suite)?.isEmpty == false
        let removedAt = Date()
        if hadValues {
            defaults.removePersistentDomain(forName: suite)
            guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
        }
        // The logical domain is cleared before teardown returns. Wait for all
        // cfprefsd writes together at the bundle/normal-process exit boundary.
        // UUID suites remain independent; CLEANED is emitted only after unlink.
        try PendingTestPreferences.shared.enqueue(self, removedAt: hadValues ? removedAt : nil)
    }

    fileprivate func finish(removedAt: Date?) throws -> Bool {
        // A late fixture task must fail cleanup rather than have its new values
        // silently erased. Owners must stop their tasks before registering removal.
        guard let defaults = UserDefaults(suiteName: suite),
              defaults.persistentDomain(forName: suite)?.isEmpty != false else { return false }
        if let removedAt {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: plist.path),
                  let modified = attributes[.modificationDate] as? Date, modified >= removedAt,
                  let data = try? Data(contentsOf: plist),
                  let domain = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  domain.isEmpty else { return false }
        }
        if let status = try Self.fileStatus(at: plist) {
            guard status.st_uid == getuid(), status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try FileManager.default.removeItem(at: plist)
        }
        guard try Self.fileStatus(at: plist) == nil else { throw CocoaError(.fileWriteUnknown) }
        try Self.emit("CLEANED", suite: suite)
        return true
    }

    fileprivate var name: String { suite }

    fileprivate static func emit(_ event: String, suite: String) throws {
        let bytes = Array("TEST_PREFERENCE_\(event) suite=\(suite)\n".utf8)
        // Parallel Xcode activity logs can omit output after the final case.
        // Keep an independent, UUID-only event stream in this worker's scratch
        // directory so bundle/exit cleanup is still externally verifiable.
        let events = TestFixtureDirectory.root.appendingPathComponent("test-preferences.events")
        let descriptor = Darwin.open(events.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        let recorded = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        guard recorded == bytes.count else { throw CocoaError(.fileWriteUnknown) }
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(STDOUT_FILENO, buffer.baseAddress, buffer.count)
        }
        guard written == bytes.count else { throw CocoaError(.fileWriteUnknown) }
    }

    static func finishPending() throws { try PendingTestPreferences.shared.finish() }
    var isPendingForTesting: Bool { PendingTestPreferences.shared.contains(suite) }
    var hasPlistForTesting: Bool { get throws { try Self.fileStatus(at: plist) != nil } }

    func remove() throws {
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileWriteUnknown) }
        try remove(defaults)
    }

    private static func fileStatus(at url: URL) throws -> stat? {
        var status = stat()
        if lstat(url.path, &status) == 0 { return status }
        guard errno == ENOENT else { throw CocoaError(.fileReadUnknown) }
        return nil
    }
}

/// XCTest ends before Swift Testing on this host. The observation boundary
/// drains XCTest's batch; a normal-exit hook also drains Swift Testing's batch.
/// A killed/crashed host still fails the external preference log guard.
private final class PendingTestPreferences: NSObject, XCTestObservation, @unchecked Sendable {
    static let shared = PendingTestPreferences()
    private struct Pending: Sendable {
        let cleanup: TestPreferenceCleanup
        let removedAt: Date?
    }
    private let lock = NSLock()
    private let finishLock = NSLock()
    private var pending: [String: Pending] = [:]

    private override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
        atexit {
            do { try PendingTestPreferences.shared.finish() }
            catch { PendingTestPreferences.failExit() }
        }
    }

    func enqueue(_ cleanup: TestPreferenceCleanup, removedAt: Date?) throws {
        try lock.withLock {
            guard pending[cleanup.name] == nil else { throw CocoaError(.fileWriteFileExists) }
            pending[cleanup.name] = Pending(cleanup: cleanup, removedAt: removedAt)
        }
    }

    func contains(_ suite: String) -> Bool { lock.withLock { pending[suite] != nil } }

    func finish() throws {
        finishLock.lock()
        defer { finishLock.unlock() }
        var remaining = lock.withLock { Array(pending.values) }
        guard !remaining.isEmpty else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        repeat {
            var waiting: [Pending] = []
            for request in remaining {
                if try request.cleanup.finish(removedAt: request.removedAt) {
                    _ = lock.withLock { pending.removeValue(forKey: request.cleanup.name) }
                } else {
                    waiting.append(request)
                }
            }
            remaining = waiting
            if !remaining.isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        } while !remaining.isEmpty && ProcessInfo.processInfo.systemUptime < deadline
        guard remaining.isEmpty else { throw CocoaError(.fileWriteUnknown) }
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        do { try finish() }
        catch { Self.failExit() }
    }

    private static func failExit() -> Never {
        fputs("TEST_PREFERENCE_BATCH_FAILED: synthetic suite cleanup or evidence logging failed\n", stderr)
        fflush(nil)
        _exit(EXIT_FAILURE)
    }
}

/// An unstructured completion observer permits the deadline to report failure
/// even when the observed task ignores cancellation. Callers then preserve the
/// fixture instead of deleting files while an owned writer can still run.
@MainActor
enum TestTaskLifetime {
    enum Failure: Error { case timedOut }

    /// Capture handles before reset clears AppModel's slots. A failed join
    /// throws before callers remove preferences or an owned fixture directory.
    static func stop(_ model: AppModel, queue: LearningReviewQueue) async throws {
        let tasks = [model.savedProcessingTaskForTesting, model.translationTaskForTesting,
                     model.summaryTaskForTesting, model.summaryWakeTaskForTesting,
                     model.chineseDisplayPreparationForTesting].compactMap { $0 }
        let pause = model.savedPauseTaskForTesting
        for task in tasks { task.cancel() }
        for task in tasks { try await value(task) }
        // A pause may still be finishing its archive after its UI flag flips.
        // Reset changes lifecycleRevision; doing so before joining that pause
        // would invalidate the test's own final save and report a false failure.
        if let pause { try await value(pause) }
        let translation = model.resetTranslationSessionForTesting()
        if let translation { try await value(translation) }
        let shutdown = Task { await queue.shutdownForTesting() }
        try await value(shutdown)
    }

    static func value<Value: Sendable, TaskFailure: Error>(
        _ task: Task<Value, TaskFailure>, timeout: Duration = .seconds(5)
    ) async throws -> Value {
        var result: Result<Value, TaskFailure>?
        let observer = Task { @MainActor in result = await task.result }
        defer {
            observer.cancel()
            if result == nil { task.cancel() }
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while result == nil {
            guard ContinuousClock.now < deadline else {
                task.cancel()
                throw Failure.timedOut
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        // The observed result proves that this join can no longer remain parked.
        await observer.value
        return try result!.get()
    }
}

@MainActor
final class TestInfrastructureTests: XCTestCase {
    func testLogicalCleanupPrecedesOneBatchDiskFlush() throws {
        var cleanups: [TestPreferenceCleanup] = []
        for _ in 0..<2 {
            let suite = "LiveLingo-Test-\(UUID().uuidString)"
            let cleanup = try TestPreferenceCleanup(suite: suite)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.set("synthetic preference", forKey: "value")
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(reopened.string(forKey: "value"), "synthetic preference")
            try cleanup.remove(defaults)
            XCTAssertTrue(defaults.persistentDomain(forName: suite)?.isEmpty != false)
            XCTAssertTrue(cleanup.isPendingForTesting)
            cleanups.append(cleanup)
        }
        try TestPreferenceCleanup.finishPending()
        for cleanup in cleanups {
            XCTAssertFalse(cleanup.isPendingForTesting)
            XCTAssertFalse(try cleanup.hasPlistForTesting)
        }
    }

    func testReadOnlyDomainCleanupDoesNotManufactureAPlist() throws {
        let suite = "LiveLingo-Test-\(UUID().uuidString)"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertNil(defaults.object(forKey: "absent"))
        try cleanup.remove(defaults)
        try TestPreferenceCleanup.finishPending()
        XCTAssertFalse(try cleanup.hasPlistForTesting)
    }

    func testTaskDeadlineReturnsBeforeANonCooperativeTaskCompletes() async throws {
        var continuation: CheckedContinuation<Void, Never>?
        let task = Task { @MainActor in
            await withCheckedContinuation { continuation = $0 }
        }
        defer { continuation?.resume(); task.cancel() }
        await Task.yield()
        do {
            try await TestTaskLifetime.value(task, timeout: .milliseconds(100))
            XCTFail("An unreleased synthetic task must reach its deadline")
        } catch TestTaskLifetime.Failure.timedOut {
            XCTAssertTrue(task.isCancelled)
        }
        let pending = try XCTUnwrap(continuation)
        continuation = nil
        pending.resume()
        await task.value
    }

    func testStorageLeaseSuspendsUntilTheCurrentOwnerReleases() async throws {
        let gate = IsolatedStorageGate()
        let first = UUID(), second = UUID()
        try await gate.acquire(first)
        var entered = false
        let waiter = Task { @MainActor in
            try await gate.acquire(second)
            entered = true
            await gate.release(second)
        }
        defer { waiter.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await gate.waitingCountForTesting == 0 {
            guard ContinuousClock.now < deadline else { throw TestTaskLifetime.Failure.timedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(entered)
        await gate.release(first)
        try await TestTaskLifetime.value(waiter)
        XCTAssertTrue(entered)
    }

    func testCancellingAQueuedStorageLeaseDoesNotBlockItsSuccessor() async throws {
        let gate = IsolatedStorageGate()
        let first = UUID(), cancelled = UUID(), next = UUID()
        try await gate.acquire(first)
        let waiter = Task { try await gate.acquire(cancelled) }
        defer { waiter.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await gate.waitingCountForTesting == 0 {
            guard ContinuousClock.now < deadline else { throw TestTaskLifetime.Failure.timedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
        waiter.cancel()
        do {
            try await TestTaskLifetime.value(waiter)
            XCTFail("A cancelled waiter must not acquire a held lease")
        } catch is CancellationError { }
        await gate.release(first)
        let successor = Task {
            try await gate.acquire(next)
            await gate.release(next)
        }
        try await TestTaskLifetime.value(successor)
    }
}

import Testing

/// Swift Testing suites that share process-wide storage locks use one asynchronous lease.
/// Apply `@Suite(.isolatedStorage)` to every participating suite. Existing traits,
/// including `.serialized`, can remain: `@Suite(.serialized, .isolatedStorage)`.
///
/// Each test case owns the same gate until its entire asynchronous body returns.
/// Tests must still await their background storage work before returning. This
/// gate is process-local and does not participate in XCTest's scheduling.
nonisolated struct IsolatedStorageScope: TestTrait, SuiteTrait, TestScoping {
    typealias TestScopeProvider = IsolatedStorageScope

    var isRecursive: Bool { true }

    private static let gate = IsolatedStorageGate()
    @TaskLocal private static var activeTestID: Test.ID?

    func scopeProvider(for test: Test, testCase: Test.Case?) -> IsolatedStorageScope? {
        // Recursive suite traits also reach suites and the outer test-function
        // scope. Locking either would deadlock their descendant case scopes (or
        // let parallel parameterized cases bypass the gate through inheritance).
        guard !test.isSuite, testCase != nil else { return nil }
        return self
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // Keep direct calls consistent with scopeProvider's case-only contract.
        guard !test.isSuite, testCase != nil else {
            try await function()
            return
        }

        // A nested suite may repeat an inherited trait. Only the same case's
        // nested provider can reuse its lease; outer scopes never set this value.
        if Self.activeTestID == test.id {
            try await function()
            return
        }

        let token = UUID()
        try await Self.gate.acquire(token)
        do {
            // Cancellation can race with a waiter being granted ownership.
            // Once acquired, this scope always releases, even on that race.
            try Task.checkCancellation()
            print("TEST_STORAGE_SCOPE_ENTER pid=\(ProcessInfo.processInfo.processIdentifier) test=\(test.id)")
            try await Self.$activeTestID.withValue(test.id) {
                try await function()
            }
        } catch {
            print("TEST_STORAGE_SCOPE_EXIT pid=\(ProcessInfo.processInfo.processIdentifier) test=\(test.id)")
            await Self.gate.release(token)
            throw error
        }
        print("TEST_STORAGE_SCOPE_EXIT pid=\(ProcessInfo.processInfo.processIdentifier) test=\(test.id)")
        await Self.gate.release(token)
    }
}

extension Trait where Self == IsolatedStorageScope {
    nonisolated static var isolatedStorage: Self { Self() }
}

/// The actor only protects bookkeeping. Waiting suspends a continuation; it
/// never holds an NSLock, semaphore, or the main actor while awaiting admission.
private actor IsolatedStorageGate {
    private nonisolated struct Waiter: Sendable {
        let token: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var owner: UUID?
    private var waiters: [Waiter] = []
    var waitingCountForTesting: Int { waiters.count }

    func acquire(_ token: UUID) async throws {
        try Task.checkCancellation()
        if owner == nil {
            owner = token
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                // Cancellation before registration must not leave a waiter.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(token: token, continuation: continuation))
                }
            }
        } onCancel: {
            // Scheduling removal is nonblocking, including for a main-actor test.
            Task { await self.cancelWaiting(token) }
        }
    }

    func release(_ token: UUID) {
        precondition(owner == token, "Storage gate released by a non-owner")
        if waiters.isEmpty {
            owner = nil
        } else {
            let next = waiters.removeFirst()
            owner = next.token
            next.continuation.resume()
        }
    }

    private func cancelWaiting(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else {
            // Already granted: provideScope observes cancellation and releases
            // after the body unwinds. Cancellation must never revoke a live body.
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
