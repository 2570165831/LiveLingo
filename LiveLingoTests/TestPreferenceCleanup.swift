import Darwin
import Foundation
import XCTest
@testable import LiveLingo

/// A synthetic calendar clock that advances only with monotonic elapsed time.
/// Timer integration still runs, but changing the host's date cannot move it.
@MainActor
final class TestWallClock {
    private let origin = ContinuousClock.now
    private let epoch: Date

    init(epoch: Date = Date(timeIntervalSince1970: 0)) { self.epoch = epoch }

    func now() -> Date {
        let elapsed = origin.duration(to: .now).components
        return epoch.addingTimeInterval(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
}

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

/// Preferences stay in memory, including reopening a suite and inspecting its
/// persistent domain. Neither reads nor teardown touch the user's preferences.
/// Sendability is inherited from UserDefaults; restating it can become an
/// unavailable-conformance warning depending on which files share a compile job.
class TestUserDefaults: UserDefaults {
    private final class Domain: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var values: [String: Any] = [:]
        var volatile: [String: [String: Any]] = [:]
        var registered: [String: Any] = [:]
    }
    private final class Suites: @unchecked Sendable {
        let lock = NSLock()
        var domains: [String: Domain] = [:]
    }
    private static let suites = Suites()
    private let suite: String
    private let domain: Domain

    override init?(suiteName: String?) {
        guard let suiteName else { return nil }
        suite = suiteName
        domain = Self.suites.lock.withLock {
            if let existing = Self.suites.domains[suiteName] { return existing }
            let created = Domain()
            Self.suites.domains[suiteName] = created
            return created
        }
        super.init(suiteName: suiteName)
    }

    override func object(forKey key: String) -> Any? {
        domain.lock.withLock {
            domain.volatile[UserDefaults.argumentDomain]?[key]
                ?? domain.volatile[suite]?[key]
                ?? domain.values[key]
                ?? domain.registered[key]
        }
    }
    override func string(forKey key: String) -> String? {
        let value = object(forKey: key)
        return value as? String ?? (value as? NSNumber)?.stringValue
    }
    override func bool(forKey key: String) -> Bool {
        let value = object(forKey: key)
        return (value as? NSNumber)?.boolValue ?? (value as? NSString)?.boolValue ?? false
    }
    override func integer(forKey key: String) -> Int {
        let value = object(forKey: key)
        return (value as? NSNumber)?.intValue ?? (value as? NSString)?.integerValue ?? 0
    }
    override func double(forKey key: String) -> Double {
        let value = object(forKey: key)
        return (value as? NSNumber)?.doubleValue ?? (value as? NSString)?.doubleValue ?? 0
    }
    override func float(forKey key: String) -> Float { Float(double(forKey: key)) }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func url(forKey key: String) -> URL? {
        let value = object(forKey: key)
        return value as? URL ?? (value as? String).flatMap(URL.init(string:))
    }

    override func set(_ value: Any?, forKey key: String) {
        willChangeValue(forKey: key)
        domain.lock.withLock { domain.values[key] = value }
        didChangeValue(forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }
    override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(value as Any, forKey: key) }
    override func set(_ value: URL?, forKey key: String) { set(value as Any?, forKey: key) }
    override func removeObject(forKey key: String) { set(nil as Any?, forKey: key) }
    override func register(defaults: [String: Any]) {
        domain.lock.withLock { domain.registered.merge(defaults) { _, new in new } }
    }
    override func persistentDomain(forName name: String) -> [String: Any]? {
        guard name == suite else { return nil }
        return domain.lock.withLock { domain.values.isEmpty ? nil : domain.values }
    }
    override func setPersistentDomain(_ values: [String: Any], forName name: String) {
        precondition(name == suite)
        domain.lock.withLock { domain.values = values }
    }
    override func removePersistentDomain(forName name: String) {
        precondition(name == suite)
        domain.lock.withLock { domain.values = [:] }
    }
    override func volatileDomain(forName name: String) -> [String: Any] {
        domain.lock.withLock { domain.volatile[name] ?? [:] }
    }
    override func setVolatileDomain(_ values: [String: Any], forName name: String) {
        domain.lock.withLock { domain.volatile[name] = values }
    }
    override func removeVolatileDomain(forName name: String) {
        domain.lock.withLock { domain.volatile[name] = nil }
    }
    override func synchronize() -> Bool { true }
    override func dictionaryRepresentation() -> [String: Any] {
        domain.lock.withLock {
            var values = domain.registered
            values.merge(domain.values) { _, new in new }
            values.merge(domain.volatile[suite] ?? [:]) { _, new in new }
            values.merge(domain.volatile[UserDefaults.argumentDomain] ?? [:]) { _, new in new }
            return values
        }
    }
    fileprivate static func release(suite: String) {
        suites.lock.withLock { _ = suites.domains.removeValue(forKey: suite) }
    }
}

/// Existing fixture registrations now release only their synthetic suite.
struct TestPreferenceCleanup: Sendable {
    private let suite: String

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
              UUID(uuidString: String(suite.dropFirst(prefix.count))) != nil else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        self.suite = suite
        try Self.emit("CREATED", suite: suite)
    }

    /// Only the in-memory test store is accepted, so a fixture can never fall
    /// back to the user's real preference domain (cfprefsd, ~/Library/Preferences).
    func remove(_ defaults: UserDefaults) throws {
        guard defaults is TestUserDefaults else { throw CocoaError(.fileWriteInvalidFileName) }
        defaults.removePersistentDomain(forName: suite)
        try remove()
    }

    fileprivate static func emit(_ event: String, suite: String) throws {
        let bytes = Array("TEST_PREFERENCE_\(event) suite=\(suite)\n".utf8)
        // Parallel Xcode activity logs can omit output after the final case.
        // Keep an independent, UUID-only event stream in this worker's scratch
        // directory so every suite's cleanup is still externally verifiable.
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

    /// Read-only check that the account's real preference directory never
    /// received this synthetic suite (the external guard checks the same path).
    var hasPlistForTesting: Bool {
        get throws {
            guard let directory = getpwuid(getuid())?.pointee.pw_dir else { throw CocoaError(.fileReadUnknown) }
            let plist = URL(fileURLWithPath: String(cString: directory), isDirectory: true)
                .appendingPathComponent("Library/Preferences", isDirectory: true)
                .appendingPathComponent(suite + ".plist")
            var status = stat()
            if lstat(plist.path, &status) == 0 { return true }
            guard errno == ENOENT else { throw CocoaError(.fileReadUnknown) }
            return false
        }
    }

    /// Storage is in memory, so cleanup completes before teardown returns;
    /// CLEANED is recorded only after the synthetic suite has been released.
    func remove() throws {
        TestUserDefaults.release(suite: suite)
        try Self.emit("CLEANED", suite: suite)
    }
}

/// An unstructured completion observer permits the deadline to report failure
/// even when the observed task ignores cancellation. Callers then preserve the
/// fixture instead of deleting files while an owned writer can still run.
@MainActor
enum TestTaskLifetime {
    enum Failure: Error { case timedOut }

    /// Generous on a loaded machine (parallel hosts, background disk work) yet
    /// well inside XCTest's 120 s per-test allowance, so a join that never
    /// finishes still fails here and preserves its fixture instead of being
    /// killed by the allowance. Timeouts still throw; nothing is skipped.
    nonisolated static let defaultTimeout: Duration = .seconds(30)

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
        _ task: Task<Value, TaskFailure>, timeout: Duration = TestTaskLifetime.defaultTimeout
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
    private func auditEvents(for suite: String) throws -> [String] {
        let events = TestFixtureDirectory.root.appendingPathComponent("test-preferences.events")
        return try String(contentsOf: events, encoding: .utf8)
            .split(separator: "\n").map(String.init).filter { $0.hasSuffix(" suite=\(suite)") }
    }

    func testInMemoryCleanupReleasesSuitesAndRecordsAuditEvents() throws {
        for _ in 0..<2 {
            let suite = "LiveLingo-Test-\(UUID().uuidString)"
            let cleanup = try TestPreferenceCleanup(suite: suite)
            let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
            defaults.set("synthetic preference", forKey: "value")
            let reopened = try XCTUnwrap(TestUserDefaults(suiteName: suite))
            XCTAssertEqual(reopened.string(forKey: "value"), "synthetic preference")
            XCTAssertEqual(try auditEvents(for: suite), ["TEST_PREFERENCE_CREATED suite=\(suite)"])
            try cleanup.remove(defaults)
            XCTAssertTrue(defaults.persistentDomain(forName: suite)?.isEmpty != false)
            // Cleanup is complete before teardown returns: a new handle starts empty.
            let fresh = try XCTUnwrap(TestUserDefaults(suiteName: suite))
            XCTAssertNil(fresh.object(forKey: "value"))
            XCTAssertEqual(try auditEvents(for: suite), ["TEST_PREFERENCE_CREATED suite=\(suite)",
                                                         "TEST_PREFERENCE_CLEANED suite=\(suite)"])
            XCTAssertFalse(try cleanup.hasPlistForTesting)
            TestUserDefaults.release(suite: suite)
        }
    }

    func testReadOnlyDomainCleanupDoesNotManufactureAPlist() throws {
        let suite = "LiveLingo-Test-\(UUID().uuidString)"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        XCTAssertNil(defaults.object(forKey: "absent"))
        try cleanup.remove(defaults)
        XCTAssertFalse(try cleanup.hasPlistForTesting)
    }

    func testCleanupRejectsTheRealPreferenceStore() throws {
        let suite = "LiveLingo-Test-\(UUID().uuidString)"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        // Only the in-memory store is accepted; a cfprefsd-backed handle is
        // refused before any domain is touched. Nothing is written to it.
        XCTAssertThrowsError(try cleanup.remove(UserDefaults.standard))
        try cleanup.remove()
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
        let deadline = ContinuousClock.now.advanced(by: TestTaskLifetime.defaultTimeout)
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
        let deadline = ContinuousClock.now.advanced(by: TestTaskLifetime.defaultTimeout)
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
