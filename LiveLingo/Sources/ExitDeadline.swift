import Foundation

struct ExitDeadlineExceeded: Error, Sendable {}

/// One monotonic budget shared by capture, writer joins, persistence and service
/// retirement. Expiration permanently revokes this attempt's cleanup permission.
final class ExitDeadline: @unchecked Sendable {
    @TaskLocal static var current: ExitDeadline?
    static let applicationTimeout: TimeInterval = 15
    private let end: ContinuousClock.Instant
    private let parent: ExitDeadline?
    private let lock = NSLock()
    private var revoked = false
    private var pending = 0

    init(seconds: TimeInterval = applicationTimeout) {
        end = ContinuousClock.now.advanced(by: .seconds(max(0, seconds)))
        parent = nil
    }

    private init(end: ContinuousClock.Instant, parent: ExitDeadline) {
        self.end = end
        self.parent = parent
    }

    /// A local control limit can only shorten the inherited absolute deadline.
    func limited(to seconds: TimeInterval) -> ExitDeadline {
        ExitDeadline(end: min(end, ContinuousClock.now.advanced(by: .seconds(max(0, seconds)))), parent: self)
    }

    var remaining: TimeInterval {
        let components = ContinuousClock.now.duration(to: end).components
        return max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    var hasPendingOperations: Bool { lock.withLock { pending > 0 } }
    var isExpired: Bool { lock.withLock { revoked } || parent?.isExpired == true || ContinuousClock.now >= end }
    func revoke() { lock.withLock { revoked = true } }
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
            do { try await ContinuousClock().sleep(until: end) }
            catch { return }
            self.revoke()
            completion.resolve(.failure(ExitDeadlineExceeded()))
            work.cancel()
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
