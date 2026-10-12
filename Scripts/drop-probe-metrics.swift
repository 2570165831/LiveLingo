// Compiled only by build-drop-probe.sh. No diagnostic code in normal builds.
#if LIVELINGO_DROP_PROBE
import AVFoundation
import Foundation
import Speech

final class PreviewDropProbe: @unchecked Sendable {
    static let shared = PreviewDropProbe()
    let lossless = CommandLine.arguments.contains("--lossless")
    let stallConsumer = CommandLine.arguments.contains("--stall-consumer")
    let blockSeconds: Double = {
        let value = CommandLine.arguments.first { $0.hasPrefix("--block-ms=") }
            .flatMap { Double($0.dropFirst("--block-ms=".count)) } ?? 50
        return value > 0 && value <= 200 ? value / 1000 : 0.05
    }()
    private let lock = NSLock()
    private var lines: [Data] = []
    private var sink: FileHandle?
    private var sinkURL: URL?
    private var sinkError: Error?
    private var droppedPackets = 0
    private var droppedFrames = 0
    private var droppedSeconds = 0.0
    private let origin = ProcessInfo.processInfo.systemUptime

    func record(_ fields: [String: Any]) {
        lock.withLock {
            var row = fields
            row["wall"] = ProcessInfo.processInfo.systemUptime - origin
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                if let sink {
                    do { try sink.write(contentsOf: data + Data([10])) }
                    catch { sinkError = error }
                } else { lines.append(data) }
            }
        }
    }

    /// Stream long-run evidence so diagnostic retention does not masquerade as
    /// an audio backlog. Only the dedicated probe executable calls this.
    func beginRecording(_ url: URL) throws {
        try lock.withLock {
            guard sink == nil else { throw CocoaError(.fileWriteFileExists) }
            try Data().write(to: url, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: url)
            for data in lines { try handle.write(contentsOf: data + Data([10])) }
            lines.removeAll()
            sink = handle
            sinkURL = url
        }
    }

    @available(macOS 27, *)
    private func metadata(_ value: AnalyzerInput) -> [String: Any] {
        let seconds = value.bufferDuration.seconds
        let rate = value.bufferFormat.sampleRate
        return ["duration": seconds, "frames": Int((seconds * rate).rounded()), "rate": rate,
                "start": value.bufferStartTime.map { $0.seconds as Any } ?? NSNull()]
    }

    @available(macOS 27, *)
    func input(_ event: String, _ value: AnalyzerInput) {
        var row = metadata(value); row["event"] = event; record(row)
    }

    @available(macOS 27, *)
    func dropped(_ value: AnalyzerInput) {
        let row = metadata(value)
        let first = lock.withLock { () -> Bool in
            droppedPackets += 1
            droppedFrames += row["frames"] as? Int ?? 0
            droppedSeconds += value.bufferDuration.seconds
            return droppedPackets == 1
        }
        if first {
            record(["event": "preview_buffer_cap", "capacity": lossless ? SpeechPreviewInputQueue.capacity : 2,
                    "diagnostic": "Analyzer input buffer full; oldest preview audio evicted"])
        }
        // Optional detailed transport evidence; the cap diagnostic itself is
        // emitted once per replay. Counters and all logging are probe-only.
        if CommandLine.arguments.contains("--trace-drops") { input("dropped", value) }
    }

    @available(macOS 27, *)
    func convert(_ inputs: [AnalyzerInput], sourceFrames: Int, sourceRate: Double, sourceEnd: Double) {
        record(["event": "convert", "inputs": inputs.map(metadata), "sourceFrames": sourceFrames,
                "sourceRate": sourceRate, "sourceEnd": sourceEnd])
    }

    func boundary(_ decision: CausalBoundaryDecision?) {
        if let decision {
            record(["event": "boundary", "start": decision.start, "end": decision.end,
                    "reason": decision.reason])
        }
    }

    func save(_ url: URL) throws {
        let counters = lock.withLock { ["event": "drop_totals", "packets": droppedPackets,
            "frames": droppedFrames, "seconds": droppedSeconds] as [String: Any] }
        record(counters)
        let streamed = try lock.withLock { () -> Bool in
            guard let sink else { return false }
            guard sinkURL == url else { throw CocoaError(.fileWriteInvalidFileName) }
            try sink.synchronize()
            try sink.close()
            self.sink = nil
            if let sinkError { throw sinkError }
            return true
        }
        if streamed { return }
        let bytes = lock.withLock { lines.reduce(into: Data()) { $0.append($1); $0.append(10) } }
        try bytes.write(to: url, options: .withoutOverwriting)
    }
}
#endif
