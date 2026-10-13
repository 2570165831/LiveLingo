import Foundation
import AVFoundation
import SoundAnalysis
import Darwin

// Numeric-only standalone probe. The built-in classifier has no public
// computeUnits setting. Never claim that CoreML hardware selection is CPU-only.
private final class Observer: NSObject, SNResultsObserving {
    var windows: [[String: Double]] = []
    var failed = false
    var nonfinite = false
    var completed = false
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { failed = true; return }
        guard let c = r.classification(forIdentifier: "speech")?.confidence else { failed = true; return }
        let s = r.timeRange.start.seconds
        let d = r.timeRange.duration.seconds
        guard c.isFinite, (0...1).contains(c), s.isFinite, d.isFinite, d > 0 else { nonfinite = true; return }
        windows.append(["start": s, "duration": d, "speech": c])
    }
    func request(_ request: SNRequest, didFailWithError error: Error) { failed = true }
    func requestDidComplete(_ request: SNRequest) { completed = true }
}

private func cpu() -> Double {
    var r = rusage()
    getrusage(RUSAGE_SELF, &r)
    return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec)
        + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1_000_000
}

@main
private enum Probe {
    static func main() {
        while let line = readLine() {
            let c0 = cpu(), t0 = ProcessInfo.processInfo.systemUptime
            var out: [String: Any] = ["schema": "nsfilter-probe-v1", "windows": [],
                                     "error": 0, "nonfinite": 0, "short": 0,
                                     "completed": 0, "production_maximum": NSNull()]
            do {
                guard let bytes = line.data(using: .utf8),
                      let j = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let path = j["path"] as? String else { throw NSError(domain: "probe", code: 1) }
                let original = URL(fileURLWithPath: path)
                let file = try AVAudioFile(forReading: original)
                let rate = file.processingFormat.sampleRate
                let total = Double(file.length) / rate
                let start = (j["start"] as? Double) ?? 0
                let end = (j["end"] as? Double) ?? total
                guard rate.isFinite, rate > 0, start.isFinite, end.isFinite,
                      start >= 0, end > start, end <= total + 1 / rate else {
                    throw NSError(domain: "probe", code: 2)
                }
                let first = Int64((start * rate).rounded())
                let last = min(file.length, Int64((end * rate).rounded()))
                let duration = Double(last - first) / rate
                out["duration"] = duration
                if duration < SpeechPresenceGate.windowSeconds {
                    out["short"] = 1
                } else {
                    var url = original
                    if j["start"] != nil || j["end"] != nil {
                        guard let scratch = j["scratch"] as? String,
                              last > first, last - first <= Int64(UInt32.max),
                              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                  frameCapacity: AVAudioFrameCount(last - first)) else {
                            throw NSError(domain: "probe", code: 3)
                        }
                        file.framePosition = first
                        try file.read(into: buffer, frameCount: AVAudioFrameCount(last - first))
                        guard Int64(buffer.frameLength) == last - first else {
                            throw NSError(domain: "probe", code: 4)
                        }
                        let directory = URL(fileURLWithPath: scratch, isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                            attributes: [.posixPermissions: 0o700])
                        url = directory.appendingPathComponent("probe-" + UUID().uuidString + ".wav")
                        let output = try AVAudioFile(forWriting: url, settings: file.processingFormat.settings)
                        try output.write(from: buffer)
                        // No deletion: generated clips are retained under caller-owned scratch.
                    }
                    let c1 = cpu()
                    if (j["mode"] as? String) != "windows" {
                        // Actual product source; no duplicate classifier execution.
                        let maximum = try SpeechPresenceGate.maximumSpeechConfidence(url)
                        out["production_maximum"] = maximum.map { $0 as Any } ?? NSNull()
                        out["production_suppressed"] = [0.05, 0.1, 0.2, 0.3].map {
                            SpeechPresenceGate.shouldSuppress(maximum, threshold: $0) ? 1 : 0
                        }
                        out["mode"] = "product-source-v1"
                    } else {
                        // Private coverage diagnostic only: mirrors gate nil semantics.
                        let analyzer = try SNAudioFileAnalyzer(url: url)
                        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                        guard request.knownClassifications.contains("speech") else {
                            throw NSError(domain: "probe", code: 5)
                        }
                        request.windowDuration = CMTime(seconds: SpeechPresenceGate.windowSeconds, preferredTimescale: 16_000)
                        request.overlapFactor = SpeechPresenceGate.overlapFactor
                        out["effective_window_seconds"] = request.windowDuration.seconds
                        let observer = Observer()
                        try analyzer.add(request, withObserver: observer)
                        analyzer.analyze()
                        out["windows"] = observer.windows
                        out["error"] = observer.failed || !observer.completed ? 1 : 0
                        out["completed"] = observer.completed ? 1 : 0
                        out["nonfinite"] = observer.nonfinite ? 1 : 0
                        out["mode"] = "private-window-coverage-v1"
                    }
                    out["classification_cpu_seconds"] = cpu() - c1
                }
            } catch { out["error"] = 1 }
            out["cpu_seconds"] = cpu() - c0
            out["wall_seconds"] = ProcessInfo.processInfo.systemUptime - t0
            if let bytes = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
               let text = String(data: bytes, encoding: .utf8) { print(text) }
            else { print("{\"schema\":\"nsfilter-probe-v1\",\"error\":1,\"windows\":[]}") }
            fflush(stdout)
        }
    }
}
