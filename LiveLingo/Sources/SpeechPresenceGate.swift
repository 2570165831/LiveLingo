import AVFoundation
import CoreMedia
import Foundation
import SoundAnalysis

/// Independent of transcript text: a weak classifier result must never be
/// replaced by a list of suspicious words ("Yes." may be real speech).
enum SpeechPresenceGate {
    static let threshold = 0.1
    static let windowSeconds = 1.5
    static let overlapFactor = 0.5
    typealias Analyzer = @Sendable (URL) throws -> Double?

    /// nil means unavailable, not zero confidence. Equality passes the gate.
    static func shouldSuppress(_ confidence: Double?, threshold: Double = Self.threshold) -> Bool {
        guard let confidence, confidence.isFinite, (0...1).contains(confidence),
              threshold.isFinite, (0...1).contains(threshold) else { return false }
        return confidence < threshold
    }

    /// Analyze only the sealed chunk. No session text, neighbour audio, model
    /// weights, network, temporary file or recognizer is needed.
    static func maximumSpeechConfidence(_ url: URL) throws -> Double? {
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        // Do not dilute a short utterance by padding it with synthetic silence.
        guard duration.isFinite, duration >= windowSeconds else { return nil }
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        guard request.knownClassifications.contains("speech") else { return nil }
        request.windowDuration = CMTime(seconds: windowSeconds, preferredTimescale: 16_000)
        request.overlapFactor = overlapFactor
        let observer = SpeechConfidenceObserver()
        let analyzer = try SNAudioFileAnalyzer(url: url)
        try analyzer.add(request, withObserver: observer)
        analyzer.analyze()
        guard let maximum = observer.maximum else { return nil }
        let tolerance = 1 / file.processingFormat.sampleRate
        if observer.covers(duration, tolerance: tolerance) { return maximum }
        // File analysis drops an incomplete trailing hop: a two-second file
        // can have only [0, 1.5], missing a real "Yes." in its last half-second.
        // Reuse the original final window without zero-padding or writing a
        // temporary file. Any unobserved prefix/gap still conservatively passes.
        let frames = AVAudioFrameCount((windowSeconds * file.processingFormat.sampleRate).rounded(.up))
        let firstFrame = file.length - Int64(frames)
        guard firstFrame >= 0,
              observer.covers(Double(firstFrame) / file.processingFormat.sampleRate, tolerance: tolerance) else { return nil }
        file.framePosition = firstFrame
        let tailRequest = try SNClassifySoundRequest(classifierIdentifier: .version1)
        guard tailRequest.knownClassifications.contains("speech") else { return nil }
        tailRequest.windowDuration = request.windowDuration
        tailRequest.overlapFactor = overlapFactor
        let tailObserver = SpeechConfidenceObserver()
        let stream = SNAudioStreamAnalyzer(format: file.processingFormat)
        try stream.add(tailRequest, withObserver: tailObserver)
        var supplied: AVAudioFrameCount = 0
        var retainedBuffers: [AVAudioPCMBuffer] = []
        while supplied < frames {
            let capacity = min(frames - supplied, 16_384)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return nil }
            try file.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0 else { return nil }
            retainedBuffers.append(buffer)
            stream.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(supplied))
            supplied += buffer.frameLength
        }
        stream.completeAnalysis()
        withExtendedLifetime(retainedBuffers) {}
        guard let tailMaximum = tailObserver.maximum,
              tailObserver.covers(Double(frames) / file.processingFormat.sampleRate, tolerance: tolerance) else { return nil }
        return max(maximum, tailMaximum)
    }
}

private final class SpeechConfidenceObserver: NSObject, SNResultsObserving {
    private let lock = NSLock()
    private var confidence: Double?
    private var failed = false
    private var completed = false
    private var windows: [(start: Double, end: Double)] = []
    var maximum: Double? { lock.withLock { failed || !completed ? nil : confidence } }

    func covers(_ duration: Double, tolerance: Double) -> Bool {
        lock.withLock {
            guard !failed, completed else { return false }
            var end = 0.0
            for window in windows.sorted(by: { $0.start < $1.start }) {
                if end >= duration - tolerance { return true }
                guard window.start <= end + tolerance else { return false }
                end = max(end, window.end)
            }
            return end >= duration - tolerance
        }
    }

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        lock.withLock {
            guard let result = result as? SNClassificationResult,
                  let value = result.classification(forIdentifier: "speech")?.confidence,
                  value.isFinite, (0...1).contains(value),
                  result.timeRange.start.seconds.isFinite, result.timeRange.end.seconds.isFinite,
                  result.timeRange.duration.seconds > 0 else { failed = true; return }
            confidence = max(confidence ?? 0, value)
            windows.append((result.timeRange.start.seconds, result.timeRange.end.seconds))
        }
    }
    func request(_ request: any SNRequest, didFailWithError error: any Error) {
        lock.withLock { failed = true }
    }
    func requestDidComplete(_ request: any SNRequest) { lock.withLock { completed = true } }
}
