import Foundation
import Darwin

struct SummaryRefreshPolicy: Sendable {
    static let idleDuration: TimeInterval = 2
    static let minimumCycleInterval: TimeInterval = 180
    static let interruptedRetryInterval: TimeInterval = 10

    static func failureRetryDelay(consecutiveFailures: Int) -> TimeInterval {
        min(60, 10 * pow(2, Double(max(0, min(consecutiveFailures - 1, 3)))))
    }

    static let automaticBatchCharacters = 4_000
    // Initial bounded output budget; larger batches need room for later lecture facts.
    static func outputTokenBudget(inputCharacters: Int) -> Int {
        min(2_048, max(640, inputCharacters / 2))
    }

    static let backlogCount = 3
    static let backlogWait: TimeInterval = 8

    static func shouldYieldToCaptions(now: TimeInterval, pendingCount: Int, oldestEnqueuedAt: TimeInterval?) -> Bool {
        guard pendingCount > 0 else { return false }
        return pendingCount >= backlogCount
            || oldestEnqueuedAt.map { now - $0 >= backlogWait } == true
    }

    static func delay(
        now: TimeInterval,
        lastCaptionActivity: TimeInterval?,
        lastCycleStarted: TimeInterval?,
        allowConcurrent: Bool = false
    ) -> TimeInterval {
        let captionDelay = lastCaptionActivity.map {
            max(0, idleDuration - (now - $0))
        } ?? 0
        let summaryDelay = lastCycleStarted.map {
            max(0, minimumCycleInterval - (now - $0))
        } ?? 0
        return max(allowConcurrent ? 0 : captionDelay, summaryDelay)
    }
}

struct SummaryResourcePolicy {
    static func allowsConcurrency(lowPower: Bool, pressureNormal: Bool, availableBytes: UInt64, alreadyEnabled: Bool) -> Bool {
        let reserve: UInt64 = (alreadyEnabled ? 4 : 8) * 1_024 * 1_024 * 1_024
        // Low-power mode changes caption profiles, but does not starve due summaries.
        return pressureNormal && availableBytes >= reserve
    }

    static func estimatedAvailableBytes() -> UInt64? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Inactive pages are reclaimable estimates, not guaranteed free RAM.
        return (UInt64(statistics.free_count) + UInt64(statistics.inactive_count)) * UInt64(getpagesize())
    }

    static func pressureIsNormal() -> Bool {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 && level == 1
    }
}

struct SummaryEvidenceBatch: Equatable {
    let ids: Set<UUID>
    let text: String

    static func invalidating(_ id: UUID, in batches: [Self]) -> (remaining: [Self], invalidated: Set<UUID>) {
        let affected = batches.filter { $0.ids.contains(id) }
        return (batches.filter { !$0.ids.contains(id) }, Set(affected.flatMap { $0.ids }))
    }
}
