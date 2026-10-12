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

    private func record(_ url: URL, attempt: TranscriptionWorkRecord.Attempt = .initial) -> TranscriptionWorkRecord {
        var record = TranscriptionWorkRecord(id: UUID(), sessionID: UUID(), ordinal: 0,
            audioFile: url.lastPathComponent, startFrame: 0, endFrame: 48_000, sampleRate: 16_000,
            start: 0, end: 3, captureStart: nil, captureEnd: nil,
            modelKey: "primary", fallbackModelKey: "fallback", appleEvidence: "")
        record.attempt = attempt
        return record
    }

    func testNoSpeechSkipsAllRecognizersAndPublications() async throws {
        let url = try audio(seconds: 3, kind: 2)
        let output = try await DurableTranscriptionQueue.recognize(record(url), audioURL: url, recordingURL: nil,
            formulaContext: "", attempts: .init(), transcriber: { _, _, _, _ in
                XCTFail("No recognizer may run for suppressed audio")
                return .init(text: "I'm sorry, but I can't help you with that.")
            }, speechAnalyzer: { _ in 0.05 }, commitEnglish: { _ in XCTFail("Must not publish a caption") })
        XCTAssertTrue(output.noSpeech)
        XCTAssertEqual(output.speechConfidence, 0.05)
        XCTAssertTrue(output.text.isEmpty)
        XCTAssertNil(output.candidate)
        XCTAssertNil(output.sourceInput)
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
        let queue = DurableTranscriptionQueue(transcriber: { _, _, _, mode in
            .init(text: mode == .probe ? "" : "Yes.")
        }, speechAnalyzer: { _ in 0.05 })
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true) { _ in }
        let job = SpeechPipeline.ChunkJob(audioURL: url, modelKey: "primary", fallbackModelKey: nil,
            start: 0, end: 3, appleEvidence: "", recordingURL: nil, sessionID: session,
            startFrame: 0, endFrame: 48_000, sampleRate: 16_000)
        queue.submit(job) { _ in }
        await queue.finish(sessionID: session)
        let suppressed = try XCTUnwrap(queue.records.first)
        XCTAssertEqual(suppressed.status, .noSpeech)
        XCTAssertEqual(queue.state?.noSpeechCount, 1)
        XCTAssertEqual(queue.state?.unresolvedCount, 0)
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
}
