import AVFoundation
import CoreMedia
import Foundation
import SoundAnalysis

/// No suspicious-word list: "I." and "Yes." may both be real speech.
/// Rejecting a nonempty short result requires both acoustic and recognizer evidence.
enum SpeechPresenceGate {
    static let threshold = 0.1
    static let windowSeconds = 1.5
    static let overlapFactor = 0.5
    typealias Analyzer = @Sendable (URL) throws -> Double?

    /// A single short word over an analyzable sealed chunk merits an acoustic
    /// check, not rejection by itself. Short utterances and sentences pass.
    static func checksSingleWord(_ text: String, audioDuration: TimeInterval) -> Bool {
        guard audioDuration.isFinite, audioDuration >= windowSeconds else { return false }
        let words = text.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }
        guard words.count == 1, let word = words.first else { return false }
        return word.contains(where: \.isLetter) && word.count <= 8
    }

    /// A short word is only a candidate, never negative textual evidence.
    /// The current recognizer must independently report validated weak tokens;
    /// a missing score or another recognizer's empty result does not qualify.
    /// Every original 20 ms frame must be quiet (RMS below -40 dBFS). Taking
    /// the maximum, rather than whole-file RMS, protects a brief "Yes." amid
    /// silence. Invalid, missing and threshold-equal evidence passes through.
    static func quietSingleWord(_ text: String, audioDuration: TimeInterval,
                                maximumFrameRMS: Double?, speechConfidence: Double?,
                                recognizerSuggestsNoSpeech: Bool = false) -> Bool {
        guard recognizerSuggestsNoSpeech, checksSingleWord(text, audioDuration: audioDuration),
              let maximumFrameRMS, maximumFrameRMS.isFinite,
              maximumFrameRMS >= 0, maximumFrameRMS < 0.01 else { return false }
        return shouldSuppress(speechConfidence)
    }

    /// Reads only original sealed PCM. Never normalize, pad, record or write.
    static func maximumFrameRMS(_ url: URL) throws -> Double? {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0,
              format.commonFormat == .pcmFormatFloat32, format.channelCount > 0,
              Double(file.length) / format.sampleRate >= windowSeconds,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return nil }
        let window = max(1, Int((format.sampleRate * 0.02).rounded()))
        var frames = 0, sum = 0.0, maximum = 0.0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { return nil }
            for frame in 0..<Int(buffer.frameLength) {
                var power = 0.0
                for channel in 0..<Int(format.channelCount) {
                    let sample = Double(channels[channel][frame])
                    guard sample.isFinite else { return nil }
                    power = max(power, sample * sample)
                }
                sum += power; frames += 1
                if frames == window {
                    maximum = max(maximum, sqrt(sum / Double(frames)))
                    sum = 0; frames = 0
                }
            }
        }
        if frames > 0 { maximum = max(maximum, sqrt(sum / Double(frames))) }
        return maximum
    }

    // These conservative vetoes use the existing source-probe confidence
    // boundaries. A missing/invalid recognizer signal is never negative evidence.
    static func parakeetSuggestsNoSpeech(valid: Bool?, mean: Double?, minimum: Double?, emptyTranscript: Bool) -> Bool {
        guard valid == true else { return false }
        // The service validates the observed nonblank-token count against the
        // decoder. A valid zero-token result has no mean/minimum by definition;
        // keep that evidence distinct from missing/invalid legacy confidence.
        if mean == nil, minimum == nil { return emptyTranscript }
        guard let mean, let minimum,
              mean.isFinite, minimum.isFinite, (0...1).contains(mean), (0...1).contains(minimum) else { return false }
        return mean < 0.90 && minimum < 0.05
    }

    static func languageSuggestsNoSpeech(valid: Bool, noSpeechLabel: Bool,
                                        probability: Double?, englishProbability: Double?) -> Bool {
        guard valid, let probability, let englishProbability,
              probability.isFinite, englishProbability.isFinite,
              (0...1).contains(probability), (0...1).contains(englishProbability) else { return false }
        // A weak spoken-language label is uncertainty, not absence of speech.
        // Only an explicit, confident "None" head supports suppression.
        return noSpeechLabel && probability >= 0.55 && englishProbability < 0.55
    }

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
        tailRequest.overlapFactor = request.overlapFactor
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
