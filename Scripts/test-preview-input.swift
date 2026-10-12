import Foundation
import Darwin

private struct AudioPacket: Equatable, Sendable {
    let start: Double?
    let frames: Int
}

private final class TerminationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var reasons: [String] = []
    func record(_ reason: String) { lock.withLock { reasons.append(reason) } }
    var snapshot: [String] { lock.withLock { reasons } }
}

@main
struct PreviewInputQueueTests {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "PreviewInputQueueTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() async {
        // A broken cancellation/finish must fail this CLI instead of hanging CI.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { Darwin.exit(124) }
        do { try await run() }
        catch { print("preview_input_checks_failed: \(error.localizedDescription)"); Darwin.exit(1) }
    }

    static func run() async throws {
        // A converter burst with an anchored first packet and three implicit
        // continuation packets must survive before a consumer is scheduled.
        let packets = [AudioPacket(start: 0, frames: 1601), AudioPacket(start: nil, frames: 64),
                       AudioPacket(start: nil, frames: 64), AudioPacket(start: nil, frames: 64)]
        let burst = SpeechPreviewInputQueue.makeStream(of: AudioPacket.self)
        var dropped = 0
        for value in packets {
            if case .dropped = burst.continuation.yield(value) { dropped += 1 }
        }
        burst.continuation.finish()
        var received: [AudioPacket] = []
        for await value in burst.stream { received.append(value) }
        try check(dropped == 0, "Converter burst silently discarded audio")
        try check(received == packets, "Anchored/implicit audio order changed")
        try check(received.reduce(0) { $0 + $1.frames } == 1793, "Audio frames were lost")

        // Exactly 900 queued packets fit; the next yield evicts the oldest.
        try check(SpeechPreviewInputQueue.capacity == 900, "Preview packet cap is not exactly 900")
        let exact = SpeechPreviewInputQueue.makeStream(of: Int.self)
        for value in 0..<900 {
            guard case .enqueued(let remaining) = exact.continuation.yield(value) else {
                try check(false, "A packet below the cap was discarded"); return
            }
            try check(remaining == 899 - value, "Queue remaining capacity is incorrect")
        }
        exact.continuation.finish()
        var exactValues: [Int] = []
        for await value in exact.stream { exactValues.append(value) }
        try check(exactValues == Array(0..<900), "The exact-cap queue lost or reordered audio")

        // A stalled consumer retains the newest 900, reporting the evicted
        // value (not the incoming value) for every overflowing yield.
        let stalled = SpeechPreviewInputQueue.makeStream(of: Int.self)
        var evicted: [Int] = []
        for value in 0..<2000 {
            switch stalled.continuation.yield(value) {
            case .dropped(let oldest): evicted.append(oldest)
            case .enqueued: break
            case .terminated: try check(false, "Open queue terminated during overflow")
            @unknown default: try check(false, "Unknown yield result")
            }
        }
        stalled.continuation.finish()
        var values: [Int] = []
        for await value in stalled.stream { values.append(value) }
        try check(evicted == Array(0..<1100), "Overflow did not discard exactly the oldest 1100")
        try check(values == Array(1100..<2000), "Overflow did not retain the newest 900 in order")
        stalled.continuation.finish() // Finishing twice remains harmless.
        if case .terminated = stalled.continuation.yield(2000) {} else {
            try check(false, "Finished stream still accepts audio")
        }

        let concurrent = SpeechPreviewInputQueue.makeStream(of: Int.self)
        let producer = Task {
            for value in 0..<256 { concurrent.continuation.yield(value) }
            concurrent.continuation.finish()
        }
        var concurrentValues: [Int] = []
        for await value in concurrent.stream {
            concurrentValues.append(value)
            await Task.yield()
        }
        await producer.value
        try check(concurrentValues == Array(0..<256), "Concurrent delivery changed audio")

        let multi = SpeechPreviewInputQueue.makeStream(of: Int.self)
        await withTaskGroup(of: Void.self) { group in
            for producerID in 0..<3 {
                group.addTask {
                    for value in 0..<256 {
                        multi.continuation.yield(producerID * 1000 + value)
                        await Task.yield()
                    }
                }
            }
        }
        multi.continuation.finish()
        var multiValues: [Int] = []
        for await value in multi.stream { multiValues.append(value) }
        try check(multiValues.count == 768 && Set(multiValues).count == 768,
                  "Concurrent producers lost or duplicated packets")
        for producerID in 0..<3 {
            try check(multiValues.filter { $0 / 1000 == producerID } ==
                      (0..<256).map { producerID * 1000 + $0 }, "Per-producer order changed")
        }

        let cancelled = SpeechPreviewInputQueue.makeStream(of: Int.self)
        let termination = TerminationProbe()
        cancelled.continuation.onTermination = { reason in
            termination.record(String(describing: reason))
        }
        for value in 0..<900 { cancelled.continuation.yield(value) }
        let consumer = Task { for await _ in cancelled.stream { await Task.yield() } }
        consumer.cancel()
        await consumer.value
        if case .terminated = cancelled.continuation.yield(1000) {} else {
            try check(false, "Cancelled consumer still retains incoming audio")
        }
        try check(termination.snapshot == ["cancelled"], "Cancellation was not reported exactly once")

        // Finish wakes a consumer already waiting for its next packet, and a
        // normal finish drains buffered packets before returning nil.
        let ended = SpeechPreviewInputQueue.makeStream(of: Int.self)
        let endTermination = TerminationProbe()
        ended.continuation.onTermination = { reason in endTermination.record(String(describing: reason)) }
        let waiter = Task { () -> [Int] in
            var output: [Int] = []
            for await value in ended.stream { output.append(value) }
            return output
        }
        await Task.yield()
        for value in 0..<4 { ended.continuation.yield(value) }
        ended.continuation.finish()
        let endedValues = await waiter.value
        try check(endedValues == Array(0..<4), "Finish did not wake and drain the consumer")
        try check(endTermination.snapshot == ["finished"], "Normal termination was not reported exactly once")
        if case .terminated = ended.continuation.yield(4) {} else {
            try check(false, "Normally ended queue accepted more packets")
        }
        print("{\"checks\":[\"four_packet_burst_order_frames\",\"exact_900_capacity\",\"oldest_eviction\",\"finish_rejects\",\"concurrent_delivery\",\"cancellation\",\"normal_end_drains\"],\"passed\":7,\"capacity\":900}")
        print("preview_input_checks_passed=7")
    }
}
