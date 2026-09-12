import AVFoundation
import CoreMedia
import Foundation
import SoundAnalysis

struct SpeechActivityObservation: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let speech: Bool
}

final class SpeechActivityDetector: NSObject, SNResultsObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var analyzer: SNAudioStreamAnalyzer?
    private var framePosition: AVAudioFramePosition = 0
    private var suppliedAudioEnd: TimeInterval = 0
    private var speechLabels: Set<String> = []
    private var handler: (@Sendable (SpeechActivityObservation) -> Void)?

    func start(
        format: AVAudioFormat,
        handler: @escaping @Sendable (SpeechActivityObservation) -> Void
    ) throws {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 16_000)
        request.overlapFactor = 0.5
        let allowed: Set<String> = ["speech", "narration", "conversation", "speech_synthesizer"]
        let labels = Set(request.knownClassifications).intersection(allowed)
        guard labels.contains("speech") else {
            throw NSError(
                domain: "LiveLingo.SpeechActivityDetector",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "系统声音分类器不提供 speech 标签。"]
            )
        }
        let analyzer = SNAudioStreamAnalyzer(format: format)
        try analyzer.add(request, withObserver: self)
        lock.withLock {
            self.analyzer = analyzer
            framePosition = 0
            suppliedAudioEnd = 0
            speechLabels = labels
            self.handler = handler
        }
    }

    func analyze(_ buffer: AVAudioPCMBuffer) {
        let state = lock.withLock { () -> (SNAudioStreamAnalyzer, AVAudioFramePosition)? in
            guard let analyzer else { return nil }
            let position = framePosition
            framePosition += AVAudioFramePosition(buffer.frameLength)
            suppliedAudioEnd = Double(framePosition) / buffer.format.sampleRate
            return (analyzer, position)
        }
        guard let state else { return }
        state.0.analyze(buffer, atAudioFramePosition: state.1)
    }

    func finish() {
        let analyzer = lock.withLock { () -> SNAudioStreamAnalyzer? in
            let value = self.analyzer
            self.analyzer = nil
            handler = nil
            return value
        }
        analyzer?.completeAnalysis()
    }

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let classification = result as? SNClassificationResult else { return }
        let state = lock.withLock { () -> (Set<String>, TimeInterval, (@Sendable (SpeechActivityObservation) -> Void)?) in
            (speechLabels, suppliedAudioEnd, handler)
        }
        let confidence = classification.classifications
            .filter { state.0.contains($0.identifier) }
            .map(\.confidence)
            .max() ?? 0
        let start = classification.timeRange.start.seconds
        let end = classification.timeRange.end.seconds
        guard start.isFinite, end.isFinite, end <= state.1 + 0.001 else { return }
        state.2?(SpeechActivityObservation(start: start, end: end, speech: confidence >= 0.5))
    }

    func request(_ request: any SNRequest, didFailWithError error: any Error) {
        finish()
    }

    func requestDidComplete(_ request: any SNRequest) {}
}
