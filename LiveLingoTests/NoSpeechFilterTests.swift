import AVFoundation
import Foundation
import XCTest
@testable import LiveLingo

final class NoSpeechFilterTests: XCTestCase, @unchecked Sendable {
    func testThresholdAndMissingEvidence() {
        for value in [0.0, 0.05, 0.099999] { XCTAssertTrue(SpeechPresenceGate.shouldSuppress(value)) }
        for value in [0.1, 0.2, 0.3, 1.0] { XCTAssertFalse(SpeechPresenceGate.shouldSuppress(value)) }
        for value in [nil, Double.nan, .infinity, -0.1, 1.1] {
            XCTAssertFalse(SpeechPresenceGate.shouldSuppress(value))
        }
        XCTAssertFalse(SpeechPresenceGate.shouldSuppress(0.01, threshold: .nan))
        XCTAssertFalse(SpeechPresenceGate.shouldSuppress(0.01, threshold: 1.1))
        XCTAssertTrue(SpeechPresenceGate.shouldSuppress(0.15, threshold: 0.2))
        XCTAssertFalse(SpeechPresenceGate.shouldSuppress(0.15, threshold: 0.1))
    }

    private func audio(seconds: Double, kind: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoSpeech-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let url = root.appendingPathComponent("synthetic.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        var seed: UInt64 = 11
        for i in 0..<Int(frames) {
            switch kind {
            case 1:
                seed = 6364136223846793005 &* seed &+ 1
                samples[i] = Float(Double(seed >> 33) / Double(UInt32.max) - 0.25) * 0.2
            case 2:
                let t = Double(i) / 16_000
                let on = Int(t * 4) % 2 == 0
                samples[i] = on ? Float(0.2 * sin(2 * .pi * 3_100 * t)) : 0
            default: samples[i] = 0
            }
        }
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings)
        try writer?.write(from: buffer)
        writer = nil // AVAudioFile.close() requires macOS 15; deployment is 14.
        // Retain owned fixtures for the dispatcher's cleanup; never use Trash.
        return url
    }

    func testSyntheticDigitalSilenceHasLowSpeechConfidence() throws {
        let confidence = try XCTUnwrap(SpeechPresenceGate.maximumSpeechConfidence(audio(seconds: 3, kind: 0)))
        XCTAssertTrue(SpeechPresenceGate.shouldSuppress(confidence))
    }
    func testSyntheticNoiseHasLowSpeechConfidence() throws {
        let confidence = try XCTUnwrap(SpeechPresenceGate.maximumSpeechConfidence(audio(seconds: 3, kind: 1)))
        XCTAssertTrue(SpeechPresenceGate.shouldSuppress(confidence))
    }
    func testSyntheticAlarmHasLowSpeechConfidence() throws {
        let confidence = try XCTUnwrap(SpeechPresenceGate.maximumSpeechConfidence(audio(seconds: 3, kind: 2)))
        XCTAssertTrue(SpeechPresenceGate.shouldSuppress(confidence))
    }
    func testShortAudioFailsOpen() throws {
        XCTAssertNil(try SpeechPresenceGate.maximumSpeechConfidence(audio(seconds: 0.5, kind: 2)))
    }

    func testPublicCaptionedYesAtTailOfTwoSecondChunkIsNotLost() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/NoSpeech/yes.wav")
        let source = try AVAudioFile(forReading: fixture)
        let duration = Double(source.length) / source.processingFormat.sampleRate
        XCTAssertEqual(duration, 0.55, accuracy: 0.0001)
        XCTAssertNil(try SpeechPresenceGate.maximumSpeechConfidence(fixture))
        let tail = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat,
            frameCapacity: AVAudioFrameCount(source.length)))
        try source.read(into: tail)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoSpeech-Tail-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let url = root.appendingPathComponent("public-tail.wav")
        let prefix = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat,
            frameCapacity: 23_200))
        prefix.frameLength = 23_200
        for channel in 0..<Int(prefix.format.channelCount) {
            try XCTUnwrap(prefix.floatChannelData)[channel].initialize(repeating: 0, count: 23_200)
        }
        var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: source.processingFormat.settings)
        try writer?.write(from: prefix)
        try writer?.write(from: tail)
        writer = nil
        let confidence = try XCTUnwrap(SpeechPresenceGate.maximumSpeechConfidence(url))
        XCTAssertFalse(SpeechPresenceGate.shouldSuppress(confidence),
            "The classifier must observe the final 0.5 seconds, not call an unobserved tail silent")
    }

    private func record(_ url: URL, attempt: TranscriptionWorkRecord.Attempt = .initial,
                        appleEvidence: String = "", fallbackModelKey: String? = "fallback") -> TranscriptionWorkRecord {
        var record = TranscriptionWorkRecord(id: UUID(), sessionID: UUID(), ordinal: 0,
            audioFile: url.lastPathComponent, startFrame: 0, endFrame: 48_000, sampleRate: 16_000,
            start: 0, end: 3, captureStart: nil, captureEnd: nil,
            modelKey: "primary", fallbackModelKey: fallbackModelKey, appleEvidence: appleEvidence)
        record.attempt = attempt
        return record
    }

    private static func negativeRecognition(_ model: String, mode: ASRLanguageMode) -> ASRTranscription {
        if mode == .probe {
            return .init(text: "", languageMode: .probe, detectedLabel: "None",
                languageProbability: 0.99, englishProbability: 0.001, policy: 1)
        }
        return .init(text: "", parakeetMeanProbability: model == "primary" ? 0.3 : nil,
            parakeetMinProbability: model == "primary" ? 0.01 : nil,
            parakeetConfidenceValid: model == "primary" ? true : nil)
    }

    private final class Observed: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.withLock { values.append(value) } }
        var all: [String] { lock.withLock { values } }
        func receive(_ event: SpeechPipeline.Event) {
            switch event {
            case .transcriptionIssue: add("issue")
            case .volatile(let text, _, _, _): if text.isEmpty { add("clearPreview") }
            case .identifiedFinal, .final: add("final")
            default: break
            }
        }
    }

    func testNoSpeechRequiresAllRecognizerSignalsAndNeverPublishes() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let calls = Observed()
        let output = try await DurableTranscriptionQueue.recognize(record(url), audioURL: url, recordingURL: nil,
            formulaContext: "", attempts: .init(), transcriber: { _, model, _, mode in
                calls.add(mode == .probe ? "probe" : model)
                return Self.negativeRecognition(model, mode: mode)
            }, speechAnalyzer: { _ in 0.05 }, commitEnglish: { _ in XCTFail("Must not publish a caption") })
        XCTAssertEqual(calls.all, ["primary", "fallback", "probe"])
        XCTAssertTrue(output.noSpeech)
        XCTAssertEqual(output.speechConfidence, 0.05)
        XCTAssertTrue(output.text.isEmpty)
        XCTAssertNil(output.candidate)
        XCTAssertNil(output.sourceInput)
    }

    func testAppleTextForThisChunkVetoesNoSpeech() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let item = record(url, appleEvidence: "OK, that's the precipitate.")
        let output = try await DurableTranscriptionQueue.recognize(item, audioURL: url, recordingURL: nil,
            formulaContext: "", attempts: .init(),
            transcriber: { _, model, _, mode in Self.negativeRecognition(model, mode: mode) },
            speechAnalyzer: { _ in XCTFail("Apple text must avoid duplicate classification"); return 0 })
        XCTAssertFalse(output.noSpeech)
    }

    func testValidatedZeroTokenParakeetAndNoneHeadAreConsistentAbsence() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let output = try await DurableTranscriptionQueue.recognize(record(url), audioURL: url, recordingURL: nil,
            formulaContext: "", attempts: .init(), transcriber: { _, model, _, mode in
                if mode == .probe {
                    return .init(text: "", languageMode: .probe, detectedLabel: "None",
                        languageProbability: 0.99, englishProbability: 0.001, policy: 1)
                }
                return .init(text: "", parakeetConfidenceValid: model == "primary" ? true : nil)
            }, speechAnalyzer: { _ in 0.05 })
        XCTAssertTrue(output.noSpeech)
        XCTAssertEqual(output.speechConfidence, 0.05)
    }

    func testAcceptedPrimaryAndFallbackSpeechVetoLowClassifierConfidence() async throws {
        let url = try audio(seconds: 3, kind: 2)
        for acceptedModel in ["primary", "fallback"] {
            let output = try await DurableTranscriptionQueue.recognize(record(url), audioURL: url, recordingURL: nil,
                formulaContext: "", attempts: .init(), transcriber: { _, model, _, mode in
                    if mode == .probe { return Self.negativeRecognition(model, mode: mode) }
                    var result = Self.negativeRecognition(model, mode: mode)
                    if model == acceptedModel {
                        result = .init(text: "Yes.", parakeetMeanProbability: 0.3,
                            parakeetMinProbability: 0.01, parakeetConfidenceValid: true)
                    }
                    return result
                }, speechAnalyzer: { _ in XCTFail("Accepted speech must avoid classification"); return 0 })
            XCTAssertFalse(output.noSpeech)
            XCTAssertEqual(output.text, "Yes.")
        }
    }

    func testParakeetPositiveMissingAndInvalidConfidenceFailOpen() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let signals: [(Bool?, Double?, Double?)] = [
            (true, 0.9, 0.01), (true, 0.3, 0.05), (nil, 0.3, 0.01), (false, 0.3, 0.01),
            (true, nil, 0.01), (true, 0.3, nil), (true, .nan, 0.01),
            (true, 0.3, .infinity), (true, -0.1, 0.01), (true, 0.3, 1.1), (nil, nil, nil), (false, nil, nil)]
        for (valid, mean, minimum) in signals {
            let output = try await DurableTranscriptionQueue.recognize(record(url), audioURL: url, recordingURL: nil,
                formulaContext: "", attempts: .init(), transcriber: { _, model, _, mode in
                    if mode == .probe || model != "primary" { return Self.negativeRecognition(model, mode: mode) }
                    return .init(text: "", parakeetMeanProbability: mean,
                        parakeetMinProbability: minimum, parakeetConfidenceValid: valid)
                }, speechAnalyzer: { _ in XCTFail("Uncertain Parakeet signal must fail open"); return 0 })
            XCTAssertFalse(output.noSpeech)
        }
    }

    func testLanguageEvidenceIncludingPendingConsensusVetoesSuppression() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let heads: [ASRTranscription] = [
            .init(text: "", languageMode: .probe, detectedLabel: "English", languageProbability: 0.2, englishProbability: 0.2, policy: 1),
            .init(text: "", languageMode: .probe, detectedLabel: "French", languageProbability: 0.2, englishProbability: 0.001, policy: 1),
            .init(text: "", languageMode: .probe, detectedLabel: "None", languageProbability: 0.54, englishProbability: 0.001, policy: 1),
            .init(text: "", languageMode: .probe, detectedLabel: "English", languageProbability: 0.55, englishProbability: 0.55, policy: 1),
            .init(text: "", languageMode: .probe, detectedLabel: "French", languageProbability: 0.8, englishProbability: 0.001, policy: 1),
            .init(text: "", languageMode: .probe, detectedLabel: "Chinese", languageProbability: 0.8, englishProbability: 0.01, policy: 1),
            .init(text: "", languageMode: .probe, detectedLabel: "French", languageProbability: 0.2, englishProbability: 0.7, policy: 1),
            .init(text: "", languageMode: .probe, detectedLabel: "None", languageProbability: 0.9, englishProbability: 0.55, policy: 1),
            .init(text: "", languageMode: .probe, policy: 1),
            .init(text: "", languageMode: .probe, detectedLabel: "English", languageProbability: .nan, englishProbability: 0.1, policy: 1),
            .init(text: "", languageMode: .probe, detectedLabel: "English", languageProbability: 0.1, englishProbability: 0.1, policy: 2),
            .init(text: "", detectedLabel: "English", languageProbability: 0.1, englishProbability: 0.1, policy: 1),
            .init(text: "", languageMode: .probe, detectedLabel: "unsupported", languageProbability: 0.1, englishProbability: 0.1, policy: 1)]
        for head in heads {
            let output = try await DurableTranscriptionQueue.recognize(record(url), audioURL: url, recordingURL: nil,
                formulaContext: "", attempts: .init(), transcriber: { _, model, _, mode in
                    mode == .probe ? head : Self.negativeRecognition(model, mode: mode)
                }, speechAnalyzer: { _ in 0.05 })
            XCTAssertFalse(output.noSpeech)
        }
    }

    func testDigitalSilenceKeepsOriginalVerdictWithoutClassifierOrASR() async throws {
        let url = try audio(seconds: 3, kind: 0)
        let output = try await DurableTranscriptionQueue.recognize(record(url), audioURL: url, recordingURL: nil,
            formulaContext: "", attempts: .init(), transcriber: { _, _, _, _ in
                XCTFail("Digital silence must not run ASR"); return .init(text: "")
            }, speechAnalyzer: { _ in XCTFail("Digital silence must not run classification"); return 0 })
        XCTAssertTrue(output.silent)
        XCTAssertFalse(output.noSpeech)
        XCTAssertNil(output.speechConfidence)
    }

    func testAutomaticRepairsOfManualRequestAlwaysBypassClassifier() async throws {
        let url = try audio(seconds: 3, kind: 2)
        var item = record(url, attempt: .automaticRetry)
        item.manualRetryCount = 1
        let output = try await DurableTranscriptionQueue.recognize(item, audioURL: url, recordingURL: nil,
            formulaContext: "", attempts: .init(),
            transcriber: { _, model, _, mode in Self.negativeRecognition(model, mode: mode) },
            speechAnalyzer: { _ in XCTFail("The entire manual repair chain must bypass the classifier"); return 0 })
        XCTAssertFalse(output.noSpeech)
    }

    func testClassifierCacheReusesSameAudioButInvalidatesChangedBytes() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let item = record(url)
        let cache = TranscriptionAttemptCache()
        let calls = Observed()
        let transcribe: DurableTranscriptionQueue.Transcriber = { _, model, _, mode in
            return Self.negativeRecognition(model, mode: mode)
        }
        for _ in 0..<2 {
            let output = try await DurableTranscriptionQueue.recognize(item, audioURL: url, recordingURL: nil,
                formulaContext: "", attempts: cache, transcriber: transcribe,
                speechAnalyzer: { _ in calls.add("analysis"); return 0.2 })
            XCTAssertFalse(output.noSpeech)
        }
        XCTAssertEqual(calls.all.count, 1)
        // Only this test's synthetic file changes; the digest must invalidate it.
        let replacement = try audio(seconds: 3, kind: 1)
        try Data(contentsOf: replacement).write(to: url)
        _ = try await DurableTranscriptionQueue.recognize(item, audioURL: url, recordingURL: nil,
            formulaContext: "", attempts: cache, transcriber: transcribe,
            speechAnalyzer: { _ in calls.add("analysis"); return 0.2 })
        XCTAssertEqual(calls.all.count, 2)
    }

    func testUnavailableClassifierIsCachedAndNeverSuppresses() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let item = record(url)
        let cache = TranscriptionAttemptCache()
        let calls = Observed()
        for _ in 0..<2 {
            let output = try await DurableTranscriptionQueue.recognize(item, audioURL: url, recordingURL: nil,
                formulaContext: "", attempts: cache,
                transcriber: { _, model, _, mode in Self.negativeRecognition(model, mode: mode) },
                speechAnalyzer: { _ in calls.add("analysis"); throw URLError(.cannotOpenFile) })
            XCTAssertFalse(output.noSpeech)
        }
        XCTAssertEqual(calls.all.count, 1)
    }

    func testProbeFailureRemainsAnErrorInsteadOfNoSpeech() async throws {
        let url = try audio(seconds: 3, kind: 2)
        do {
            _ = try await DurableTranscriptionQueue.recognize(record(url), audioURL: url, recordingURL: nil,
                formulaContext: "", attempts: .init(), transcriber: { _, model, _, mode in
                    if mode == .probe { throw URLError(.timedOut) }
                    return Self.negativeRecognition(model, mode: mode)
                }, speechAnalyzer: { _ in XCTFail("A failed probe is not negative evidence"); return 0.05 })
            XCTFail("The existing recognition error must remain visible")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }

    func testMissingFallbackCannotSupplyNegativeLanguageEvidence() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let output = try await DurableTranscriptionQueue.recognize(record(url, fallbackModelKey: nil),
            audioURL: url, recordingURL: nil, formulaContext: "", attempts: .init(),
            transcriber: { _, model, _, mode in Self.negativeRecognition(model, mode: mode) },
            speechAnalyzer: { _ in XCTFail("Missing probe must fail open before classification"); return 0.05 })
        XCTAssertFalse(output.noSpeech)
    }

    func testDeferredCausalHeadNeverStartsClassifierOrProbeEarly() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let output = try await DurableTranscriptionQueue.recognize(record(url), audioURL: url, recordingURL: nil,
            formulaContext: "", attempts: .init(), deferSource: true,
            transcriber: { _, model, _, mode in
                if mode == .probe { XCTFail("An unresolved predecessor must defer its language head") }
                return Self.negativeRecognition(model, mode: mode)
            }, speechAnalyzer: { _ in XCTFail("No duplicate classifier before deferred causality resolves"); return 0 })
        XCTAssertFalse(output.noSpeech)
        XCTAssertNotNil(output.sourceInput)
    }

    func testNonEnglishRecognizerTextRemainsSpeechEvidence() async throws {
        let url = try audio(seconds: 3, kind: 2)
        for languageText in ["这是沉淀。", "これは沈殿です。", "Это осадок.", "123", "٣"] {
          for spokenModel in ["primary", "fallback"] {
            let output = try await DurableTranscriptionQueue.recognize(record(url), audioURL: url, recordingURL: nil,
                formulaContext: "", attempts: .init(), transcriber: { _, model, _, mode in
                    if mode == .probe { return Self.negativeRecognition(model, mode: mode) }
                    if model == spokenModel { return .init(text: languageText, parakeetMeanProbability: 0.3,
                        parakeetMinProbability: 0.01, parakeetConfidenceValid: true) }
                    return Self.negativeRecognition(model, mode: mode)
                }, speechAnalyzer: { _ in XCTFail("Recognizer text, including numbers, must veto suppression"); return 0 })
            XCTAssertFalse(output.noSpeech)
          }
        }
    }

    func testExplicitNoneLanguageThresholdIsInclusiveAndFinite() {
        XCTAssertTrue(SpeechPresenceGate.languageSuggestsNoSpeech(valid: true, noSpeechLabel: true,
            probability: 0.55, englishProbability: 0.549))
        for probability in [nil, .nan, .infinity, -0.1, 0.549, 1.1] as [Double?] {
            XCTAssertFalse(SpeechPresenceGate.languageSuggestsNoSpeech(valid: true, noSpeechLabel: true,
                probability: probability, englishProbability: 0.001))
        }
        for englishProbability in [nil, .nan, .infinity, -0.1, 0.55, 1.1] as [Double?] {
            XCTAssertFalse(SpeechPresenceGate.languageSuggestsNoSpeech(valid: true, noSpeechLabel: true,
                probability: 0.99, englishProbability: englishProbability))
        }
    }

    func testChangingAudioDuringAnalysisCannotBeSuppressed() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let replacement = try audio(seconds: 3, kind: 1)
        let bytes = try Data(contentsOf: replacement)
        let output = try await DurableTranscriptionQueue.recognize(record(url), audioURL: url, recordingURL: nil,
            formulaContext: "", attempts: .init(),
            transcriber: { _, model, _, mode in Self.negativeRecognition(model, mode: mode) },
            speechAnalyzer: { path in try bytes.write(to: path); return 0.01 })
        XCTAssertFalse(output.noSpeech)
    }

    private actor ProbeLatch {
        private(set) var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func hold() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    func testEditDuringRecognitionSurvivesNoSpeechWriteback() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let root = url.deletingLastPathComponent()
        let session = UUID()
        let latch = ProbeLatch()
        let queue = DurableTranscriptionQueue(transcriber: { _, model, _, mode in
            if mode == .probe { await latch.hold() }
            return Self.negativeRecognition(model, mode: mode)
        }, speechAnalyzer: { _ in 0.05 })
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true) { _ in }
        let job = SpeechPipeline.ChunkJob(audioURL: url, modelKey: "primary", fallbackModelKey: "fallback",
            start: 0, end: 3, appleEvidence: "", recordingURL: nil, sessionID: session,
            startFrame: 0, endFrame: 48_000, sampleRate: 16_000)
        queue.submit(job) { _ in }
        do {
            for _ in 0..<200 {
                if await latch.entered { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            if await latch.entered { try queue.retainExistingText(id: job.id, text: "User confirmed this speech.") }
        } catch {
            await latch.release()
            await queue.cancel()
            throw error
        }
        let entered = await latch.entered
        await latch.release()
        XCTAssertTrue(entered)
        // Old single-signal gating completes before the latch: it must fail
        // without waiting forever or starting a second manual/source request.
        await queue.finish(sessionID: session)
        if entered {
            XCTAssertEqual(queue.records.first?.status, .completed)
            XCTAssertEqual(queue.records.first?.text, "User confirmed this speech.")
            XCTAssertNil(queue.records.first?.speechConfidence)
        }
        await queue.cancel()
    }

    func testManualRetryBypassesClassifierAndRecoversShortSpeech() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let output = try await DurableTranscriptionQueue.recognize(record(url, attempt: .manual),
            audioURL: url, recordingURL: nil, formulaContext: "", attempts: .init(),
            transcriber: { _, _, _, mode in .init(text: mode == .probe ? "" : "Yes.") },
            speechAnalyzer: { _ in XCTFail("Manual retry must bypass the gate"); return 0 })
        XCTAssertFalse(output.noSpeech)
        XCTAssertEqual(output.text, "Yes.")
    }

    func testAdmittedAndUnavailableAnalysisPreserveRecognitionBytes() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let item = record(url)
        let transcribe: DurableTranscriptionQueue.Transcriber = { _, _, _, mode in
            .init(text: mode == .probe ? "" : "The acceleration is zero, but the velocity is not zero.")
        }
        let baseline = try await DurableTranscriptionQueue.recognize(item, audioURL: url, recordingURL: nil,
            formulaContext: "", attempts: .init(), transcriber: transcribe)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for value in [nil, 0.1, 0.7, .nan, .infinity, -0.1, 1.1] as [Double?] {
            let output = try await DurableTranscriptionQueue.recognize(item, audioURL: url, recordingURL: nil,
                formulaContext: "", attempts: .init(), transcriber: transcribe, speechAnalyzer: { _ in value })
            XCTAssertEqual(try encoder.encode(output), try encoder.encode(baseline))
        }
        let errorOutput = try await DurableTranscriptionQueue.recognize(item, audioURL: url, recordingURL: nil,
            formulaContext: "", attempts: .init(), transcriber: transcribe,
            speechAnalyzer: { _ in throw NSError(domain: "SyntheticAnalysis", code: 1) })
        XCTAssertEqual(try encoder.encode(errorOutput), try encoder.encode(baseline))
    }

    func testQueueRetainsAudioAndManualRetrySurvivesReopen() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let root = url.deletingLastPathComponent()
        let session = UUID()
        let events = Observed()
        let queue = DurableTranscriptionQueue(transcriber: { _, model, _, mode in
            Self.negativeRecognition(model, mode: mode)
        }, speechAnalyzer: { _ in 0.05 })
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true) { events.receive($0) }
        let job = SpeechPipeline.ChunkJob(audioURL: url, modelKey: "primary", fallbackModelKey: "fallback",
            start: 0, end: 3, appleEvidence: "", recordingURL: url, sessionID: session,
            startFrame: 0, endFrame: 48_000, sampleRate: 16_000)
        queue.submit(job) { _ in }
        await queue.finish(sessionID: session)
        let suppressed = try XCTUnwrap(queue.records.first)
        XCTAssertEqual(suppressed.status, .noSpeech)
        XCTAssertEqual(queue.state?.noSpeechCount, 1)
        XCTAssertEqual(queue.state?.unresolvedCount, 0)
        XCTAssertEqual(events.all, [], "A no-speech terminal must neither warn nor clear the existing preview")
        let diagnostics = try String(contentsOf: root.appendingPathComponent("transcription-issues.jsonl"), encoding: .utf8)
        let rows = try diagnostics.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["event"] as? String, "transcription_no_speech")
        let journal = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try journal.audioURL(for: suppressed).path))
        await queue.cancel()
        let reopened = DurableTranscriptionQueue(transcriber: { _, _, _, _ in .init(text: "Yes.") },
            speechAnalyzer: { _ in XCTFail("Manual retry after reopen must bypass filtering"); return 0 })
        try await reopened.configure(directory: root, sessionID: session, persistent: true, identified: true,
            restoring: true, startPaused: true) { _ in }
        XCTAssertEqual(reopened.records.first?.status, .noSpeech)
        try reopened.retry(id: suppressed.id)
        try reopened.resume()
        await reopened.finish(sessionID: session)
        XCTAssertEqual(reopened.records.first?.status, .completed)
        XCTAssertEqual(reopened.records.first?.text, "Yes.")
        XCTAssertEqual(reopened.records.first?.attempt, .manual)
        XCTAssertNil(reopened.records.first?.speechConfidence)
        await reopened.cancel()
    }

    func testFailedManualRetryContinuesThroughAutomaticContextRepair() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let root = url.deletingLastPathComponent()
        let session = UUID()
        let queue = DurableTranscriptionQueue(transcriber: { _, model, _, mode in
            Self.negativeRecognition(model, mode: mode)
        }, speechAnalyzer: { _ in 0.05 })
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true) { _ in }
        queue.submit(.init(audioURL: url, modelKey: "primary", fallbackModelKey: "fallback",
            start: 0, end: 3, appleEvidence: "", recordingURL: url, sessionID: session,
            startFrame: 0, endFrame: 48_000, sampleRate: 16_000)) { _ in }
        await queue.finish(sessionID: session)
        let original = try XCTUnwrap(queue.records.first)
        XCTAssertEqual(original.status, .noSpeech)
        await queue.cancel()
        let stages = Observed()
        let repaired = DurableTranscriptionQueue(transcriber: { clip, model, enhanced, mode in
            stages.add(clip.lastPathComponent.hasPrefix("LiveLingo-retry-") ? "context" : enhanced ? "enhanced" : "raw")
            if clip.lastPathComponent.hasPrefix("LiveLingo-retry-") { return .init(text: "Yes.") }
            return Self.negativeRecognition(model, mode: mode)
        }, speechAnalyzer: { _ in XCTFail("No later automatic pass may reapply the gate"); return 0 })
        try await repaired.configure(directory: root, sessionID: session, persistent: true, identified: true,
            restoring: true, startPaused: true) { _ in }
        try repaired.retry(id: original.id)
        try repaired.resume()
        await repaired.finish(sessionID: session)
        let result = try XCTUnwrap(repaired.records.first)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.manualRetryCount, 1)
        XCTAssertEqual(result.automaticRetryCount, DurableTranscriptionJournal.maximumAutomaticRetries)
        XCTAssertEqual(result.candidateText, "Yes.")
        XCTAssertEqual(result.candidateOrigin, "context")
        XCTAssertNil(result.speechConfidence)
        XCTAssertEqual(repaired.state?.noSpeechCount, 0)
        XCTAssertEqual(stages.all.filter { $0 == "context" }.count, 1)
        await repaired.cancel()
    }
}
