import Foundation
import Darwin
import os

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

/// The app's own scheduling policy for "let LiveLingo take priority".
///
/// Background review shares one language-model process with live translation, so
/// the only real way to prioritise live work is to keep the review off the
/// worker while anything live is waiting. This policy only reorders *this app's*
/// work: it never changes system-wide scheduling, never kills another app,
/// never resumes a paused review and never blocks a new recording.
enum ProcessingFocusPolicy {
    static let focusReserveBytes: UInt64 = 6 * 1_024 * 1_024 * 1_024
    static let focusRecordingReserveBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    static let standardRecordingReserveBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    static let standardIdleReserveBytes: UInt64 = 4 * 1_024 * 1_024 * 1_024

    struct Context: Equatable {
        let focusMode: Bool
        let recording: Bool
        let memoryNormal: Bool
        let hasCaptionBacklog: Bool
        /// A caption translation, the typed translator or the summary is using
        /// the shared language worker right now.
        let liveWorkPending: Bool
        let availableBytes: UInt64
        /// Existing latency-based rule for running review during recording.
        let latencyAllowsConcurrency: Bool
    }

    struct Decision: Equatable {
        /// Whether background review may run while a recording session is active.
        let allowConcurrentReview: Bool
        /// Whether the review queue may start another batch at all.
        let resourcesAvailable: Bool
    }

    static func decision(_ context: Context) -> Decision {
        let allowConcurrent = context.focusMode ? false : context.latencyAllowsConcurrency
        let reserve = context.focusMode
            ? (context.recording ? focusRecordingReserveBytes : focusReserveBytes)
            : (context.recording ? standardRecordingReserveBytes : standardIdleReserveBytes)
        var available = context.memoryNormal
            && !context.hasCaptionBacklog
            && context.availableBytes >= reserve
        if context.focusMode {
            // Live work wins the shared worker: the review waits for a genuinely
            // idle app instead of only for a caption backlog.
            available = available && !context.liveWorkPending
        }
        return Decision(allowConcurrentReview: allowConcurrent, resourcesAvailable: available)
    }

    static func statusLine(focusMode: Bool) -> String {
        focusMode
            ? "专注模式：录音与实时翻译优先，摘要让位，后台复查仅在完全空闲时运行"
            : "标准：字幕积压时让出摘要，条件允许时并行复查"
    }

    static let explanation = """
    只调整 LiveLingo 自己的任务顺序：录音采集、实时转写与翻译优先；摘要让位；\
    后台复查只在没有实时任务、内存充足且未在录音时运行，让出与实时翻译共用的语言模型进程。\
    本机实测 LiveLingo 的进程已经在系统最高默认优先级（BSD 31），没有继续提高的空间，\
    所以这里不提供“提高进程优先级”的开关；也不会修改系统全局调度、结束其他应用或阻止系统睡眠。\
    实测同一音频下并发复查没有拖慢字幕翻译（0.44 秒/句，与空闲时相同），因此不承诺更快。\
    关闭开关即恢复标准调度，用户手动暂停的复查不会被自动恢复。
    """
}
