// Compiled only by build-drop-probe.sh. No diagnostic code in normal builds.
import AVFoundation
import Foundation
import Speech

final class PreviewDropProbe: @unchecked Sendable {
    static let shared = PreviewDropProbe()
    let lossless = CommandLine.arguments.contains("--lossless")
    private let lock = NSLock()
    private var lines: [Data] = []
    private let origin = ProcessInfo.processInfo.systemUptime

    func record(_ fields: [String: Any]) {
        lock.withLock {
            var row = fields
            row["wall"] = ProcessInfo.processInfo.systemUptime - origin
            if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                lines.append(data)
            }
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
        let bytes = lock.withLock { lines.reduce(into: Data()) { $0.append($1); $0.append(10) } }
        try bytes.write(to: url, options: .withoutOverwriting)
    }
}
