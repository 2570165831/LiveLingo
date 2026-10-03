import Combine
import Foundation

/// Audio samples already redraw the waveform. Only a change between receiving
/// and waiting needs an additional notification when no new sample arrives.
@MainActor
final class WaveformFreshnessState: ObservableObject {
    static let freshnessSeconds: TimeInterval = 0.6
    @Published private(set) var isReceiving = false

    private let now: @MainActor () -> Date
    private let sleep: @MainActor (TimeInterval) async throws -> Void
    private var mounted = false
    private var expiry: Date?
    private var task: Task<Void, Never>?
    private var taskToken: UUID?

    #if DEBUG
    struct Diagnostics {
        var tasksStarted = 0
        var tasksCancelled = 0
        var sleepsArmed = 0
        var wakes = 0
        var stateChanges = 0
    }
    private(set) var diagnostics = Diagnostics()
    var taskForTesting: Task<Void, Never>? { task }
    #endif

    init(now: @escaping @MainActor () -> Date = { Date() },
         sleep: @escaping @MainActor (TimeInterval) async throws -> Void = {
             try await Task.sleep(for: .seconds($0))
         }) {
        self.now = now
        self.sleep = sleep
    }

    deinit { task?.cancel() }

    func mount(active: Bool, lastUpdate: Date?) {
        mounted = true
        update(active: active, lastUpdate: lastUpdate)
    }

    func update(active: Bool, lastUpdate: Date?) {
        // Keep the original event's deadline. Duplicate publications, view
        // remounts and pause/resume must not make an old event fresh again.
        expiry = active ? lastUpdate?.addingTimeInterval(Self.freshnessSeconds) : nil
        let instant = now()
        guard mounted, let expiry, expiry.timeIntervalSince(instant).isFinite,
              expiry > instant else {
            stopTask()
            setReceiving(false)
            return
        }
        setReceiving(true)
        guard task == nil else { return }
        let token = UUID()
        taskToken = token
        #if DEBUG
        diagnostics.tasksStarted += 1
        #endif
        // Do not retain the view's owner across a suspension. A disappearing
        // view can cancel the task, and a late wake cannot own its successor.
        let sleep = self.sleep
        task = Task { @MainActor [weak self] in
            defer { self?.finish(token: token) }
            while !Task.isCancelled {
                guard let delay = self?.remaining(for: token) else { return }
                guard delay > 0 else { return }
                self?.recordSleep()
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
                guard !Task.isCancelled, self?.taskToken == token else { return }
                self?.recordWake()
                // New samples only change expiry. Reuse this task and check
                // the latest deadline instead of cancelling it per sample.
            }
        }
    }

    func unmount() {
        mounted = false
        expiry = nil
        stopTask()
        setReceiving(false)
    }

    private func remaining(for token: UUID) -> TimeInterval? {
        guard mounted, taskToken == token, let expiry else { return nil }
        return expiry.timeIntervalSince(now())
    }

    private func finish(token: UUID) {
        guard taskToken == token else { return }
        taskToken = nil
        task = nil
        setReceiving(false)
    }

    private func stopTask() {
        taskToken = nil
        if let task {
            #if DEBUG
            diagnostics.tasksCancelled += 1
            #endif
            task.cancel()
        }
        task = nil
    }

    private func setReceiving(_ value: Bool) {
        guard isReceiving != value else { return }
        #if DEBUG
        diagnostics.stateChanges += 1
        #endif
        isReceiving = value
    }

    private func recordSleep() {
        #if DEBUG
        diagnostics.sleepsArmed += 1
        #endif
    }

    private func recordWake() {
        #if DEBUG
        diagnostics.wakes += 1
        #endif
    }
}
