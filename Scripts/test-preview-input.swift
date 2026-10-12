import Foundation
import Darwin

private struct AudioPacket: Equatable, Sendable {
    let start: Double?
    let frames: Int
}

@main
struct PreviewInputQueueTests {
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "PreviewInputQueueTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() async {
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

        // A stalled consumer must retain more than one converter's output.
        let stalled = SpeechPreviewInputQueue.makeStream(of: Int.self)
        for value in 0..<2000 {
            if case .dropped = stalled.continuation.yield(value) {
                throw NSError(domain: "PreviewInputQueueTests", code: 2)
            }
        }
        stalled.continuation.finish()
        var values: [Int] = []
        for await value in stalled.stream { values.append(value) }
        try check(values == Array(0..<2000), "A delayed consumer lost or reordered audio")
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
        let cancelled = SpeechPreviewInputQueue.makeStream(of: Int.self)
        for value in 0..<1000 { cancelled.continuation.yield(value) }
        let consumer = Task { for await _ in cancelled.stream { await Task.yield() } }
        consumer.cancel()
        await consumer.value
        if case .terminated = cancelled.continuation.yield(1000) {} else {
            try check(false, "Cancelled consumer still retains incoming audio")
        }
        print("preview_input_checks_passed=7")
    }
}
