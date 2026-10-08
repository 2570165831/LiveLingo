import Foundation

struct ExitDeadlineExceeded: Error, Sendable {}

/// A hard limit for control messages, or an inactivity limit for application
/// exit. Only actual storage progress renews an inactivity lease.
final class ExitDeadline: @unchecked Sendable {
    @TaskLocal static var current: ExitDeadline?
    @TaskLocal static var storageProgress: StorageProgress?

    /// Writers already running when quit is requested can publish real byte
    /// progress through this shared binding without inheriting a new TaskLocal.
    final class StorageProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var deadline: ExitDeadline?
        func attach(_ deadline: ExitDeadline?) { lock.withLock { self.deadline = deadline } }
        func record() { lock.withLock { deadline }?.recordProgress() }
    }

    static func storageDidProgress() {
        current?.recordProgress()
        storageProgress?.record()
    }
    static let applicationTimeout: TimeInterval = 15
    private var end: ContinuousClock.Instant
    private let inactivityTimeout: TimeInterval?
    private let parent: ExitDeadline?
    private let lock = NSLock()
    private var revoked = false
    private var pending = 0

    init(seconds: TimeInterval = applicationTimeout) {
        end = ContinuousClock.now.advanced(by: .seconds(max(0, seconds)))
        inactivityTimeout = nil
        parent = nil
    }

    init(inactivityTimeout: TimeInterval) {
        self.inactivityTimeout = max(0, inactivityTimeout)
        end = ContinuousClock.now.advanced(by: .seconds(max(0, inactivityTimeout)))
        parent = nil
    }

    private init(end: ContinuousClock.Instant, parent: ExitDeadline) {
        self.end = end
        inactivityTimeout = nil
        self.parent = parent
    }

    /// A local control limit can only shorten the inherited absolute deadline.
    func limited(to seconds: TimeInterval) -> ExitDeadline {
        ExitDeadline(end: min(lock.withLock { end }, ContinuousClock.now.advanced(by: .seconds(max(0, seconds)))), parent: self)
    }

    var remaining: TimeInterval {
        let components = ContinuousClock.now.duration(to: lock.withLock { end }).components
        return max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    var hasPendingOperations: Bool { lock.withLock { pending > 0 } }
    var isExpired: Bool { lock.withLock { revoked || ContinuousClock.now >= end } || parent?.isExpired == true }
    func revoke() { lock.withLock { revoked = true } }
    func recordProgress() {
        lock.withLock {
            // A synchronous successful write can finish after the clock limit
            // while the main actor's timer has not run. Publish that fact. A
            // timer which already revoked the lease cannot be resurrected.
            if !revoked, let inactivityTimeout {
                end = ContinuousClock.now.advanced(by: .seconds(inactivityTimeout))
            }
        }
        parent?.recordProgress()
    }
    func check(ignoringTaskCancellation: Bool = false) throws {
        guard !isExpired else { throw ExitDeadlineExceeded() }
        if !ignoringTaskCancellation { try Task.checkCancellation() }
    }

    /// Keep every pre-existing writer visible even if an earlier stage times
    /// out before the sequential join reaches it. Tracking never mutates data.
    func track<Failure: Error>(_ task: Task<Void, Failure>?) {
        guard let task else { return }
        lock.withLock { pending += 1 }
        Task {
            _ = await task.result
            self.lock.withLock { self.pending -= 1 }
        }
    }

    /// Only join a writer or run an operation whose later mutation boundaries
    /// check this lease. A destructive opaque operation must never be raced.
    @MainActor
    func wait<Value: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        try check()
        let completion = Completion<Value>()
        lock.withLock { pending += 1 }
        let work = Task { @MainActor in
            defer { self.lock.withLock { self.pending -= 1 } }
            try self.check()
            return try await ExitDeadline.$current.withValue(self) { try await operation() }
        }
        let observer = Task { completion.resolve(await work.result) }
        let timer = Task {
            while !Task.isCancelled {
                do { try await ContinuousClock().sleep(until: self.lock.withLock { self.end }) }
                catch { return }
                let expired = self.lock.withLock {
                    if self.revoked || ContinuousClock.now >= self.end { self.revoked = true; return true }
                    return false
                }
                if expired || self.parent?.isExpired == true {
                    completion.resolve(.failure(ExitDeadlineExceeded()))
                    work.cancel()
                    return
                }
            }
        }
        defer { timer.cancel() }
        let value = try await withTaskCancellationHandler {
            try await completion.value()
        } onCancel: {
            self.revoke()
            completion.resolve(.failure(CancellationError()))
            work.cancel()
        }
        // The observer intentionally only joins; it never performs cleanup.
        _ = observer
        try check()
        return value
    }

    @MainActor
    static func waiting<Value: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        if let current { return try await current.wait(operation) }
        return try await operation()
    }

    private final class Completion<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Value, Error>?
        private var waiter: CheckedContinuation<Value, Error>?
        func resolve(_ result: Result<Value, Error>) {
            let waiter = lock.withLock { () -> CheckedContinuation<Value, Error>? in
                guard self.result == nil else { return nil }
                self.result = result
                let waiter = self.waiter
                self.waiter = nil
                return waiter
            }
            waiter?.resume(with: result)
        }
        func value() async throws -> Value {
            try await withCheckedThrowingContinuation { continuation in
                let result = lock.withLock { () -> Result<Value, Error>? in
                    if let result { return result }
                    waiter = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        }
    }
}
