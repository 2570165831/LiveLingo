import CryptoKit
import Foundation
import XCTest
@testable import LiveLingo

/// Portable original waveforms and replies captured from the local recognizers.
private struct WordEvidenceFixture: Decodable, Sendable {
    let id: String
    let audioFile: String
    let sha256: String
    let duration: Double
    let truth: String
    let primary: Reply
    let automatic: Reply
    let fallback: Reply
    let probe: Reply

    struct Reply: Decodable, Sendable {
        let text: String
        let pk_mean_probability: Double?
        let pk_min_probability: Double?
        let pk_confidence_valid: Bool?
        let language_mode: String?
        let detected_label: String?
        let language_probability: Double?
        let english_probability: Double?
        let policy: Int?

        var recognition: ASRTranscription {
            .init(text: text, languageMode: language_mode == "probe" ? .probe : .english,
                  detectedLabel: detected_label, languageProbability: language_probability,
                  englishProbability: english_probability, policy: policy,
                  parakeetMeanProbability: pk_mean_probability, parakeetMinProbability: pk_min_probability,
                  parakeetConfidenceValid: pk_confidence_valid)
        }
        var negativeHead: Bool {
            SpeechPresenceGate.languageSuggestsNoSpeech(
                valid: text.isEmpty && language_mode == "probe" && policy == 1,
                noSpeechLabel: detected_label == "None", probability: language_probability,
                englishProbability: english_probability)
        }
    }

    func transcribe(model: String, enhanced: Bool, mode: ASRLanguageMode) throws -> ASRTranscription {
        if mode == .probe { return probe.recognition }
        // Detected-language bodies were not measured in this English control
        // corpus. Their existing failure path must preserve accepted English.
        if mode == .auto { throw CocoaError(.featureUnsupported) }
        return model == "parakeet" ? (enhanced ? automatic : primary).recognition : fallback.recognition
    }
}

private final class WordEvidenceCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var analyses = 0
    private var probes = 0
    var analysisCount: Int { lock.withLock { analyses } }
    var probeCount: Int { lock.withLock { probes } }
    func analyze(_ url: URL) throws -> Double? {
        lock.withLock { analyses += 1 }
        return try SpeechPresenceGate.maximumSpeechConfidence(url)
    }
    func transcribe(_ row: WordEvidenceFixture, model: String, enhanced: Bool,
                    mode: ASRLanguageMode) throws -> ASRTranscription {
        if mode == .probe { lock.withLock { probes += 1 } }
        return try row.transcribe(model: model, enhanced: enhanced, mode: mode)
    }
}

final class SingleWordEvidenceTests: XCTestCase, @unchecked Sendable {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/NoSpeech/SingleWord")
    }
    private func fixtures() throws -> [WordEvidenceFixture] {
        struct Manifest: Decodable { let rows: [WordEvidenceFixture] }
        let rows = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("fixtures.json"))).rows
        for row in rows {
            let digest = SHA256.hash(data: try Data(contentsOf: root.appendingPathComponent(row.audioFile)))
                .map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, row.sha256, row.id)
        }
        return rows
    }
    private func record(_ row: WordEvidenceFixture, attempt: TranscriptionWorkRecord.Attempt) -> TranscriptionWorkRecord {
        var record = TranscriptionWorkRecord(id: UUID(), sessionID: UUID(), ordinal: 0, audioFile: row.audioFile,
            startFrame: 0, endFrame: Int64((row.duration * 16_000).rounded()), sampleRate: 16_000,
            start: 0, end: row.duration, captureStart: nil, captureEnd: nil,
            modelKey: "parakeet", fallbackModelKey: "1.7b", appleEvidence: "")
        record.attempt = attempt
        return record
    }

    func testFourOfFiveCapturedNonSilentHallucinationsHaveIndependentNegativeEvidence() throws {
        let rows = Dictionary(uniqueKeysWithValues: try fixtures().map { ($0.id, $0) })
        let cases = [("breath-3", false), ("breath-4", true), ("breath-4", false),
                     ("breath-5", false), ("floor-5", false)]
        var rejected = 0
        for (id, primary) in cases {
            let row = try XCTUnwrap(rows[id])
            let url = root.appendingPathComponent(row.audioFile)
            let text = (primary ? row.primary : row.fallback).text
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(try DigitalSilenceGate.isSilent(url))
            let clear = SpeechPresenceGate.quietSingleWord(text, audioDuration: row.duration,
                maximumFrameRMS: try SpeechPresenceGate.maximumFrameRMS(url),
                speechConfidence: try SpeechPresenceGate.maximumSpeechConfidence(url),
                languageHeadSuggestsNoSpeech: row.probe.negativeHead)
            if clear { rejected += 1 }
            XCTAssertEqual(clear, id != "floor-5", id)
        }
        XCTAssertEqual(rejected, 4, "The uncertain floor-noise head must still fail open")
    }

    func testMeasuredQuietAnswersReachTheAcousticCheckAndKeepTheirReplies() throws {
        let rows = try fixtures().filter { $0.truth == "speech" }
        XCTAssertEqual(rows.count, 17)
        var weakAcousticCandidates = 0
        for row in rows {
            let url = root.appendingPathComponent(row.audioFile)
            let energy = try XCTUnwrap(SpeechPresenceGate.maximumFrameRMS(url))
            let confidence = try XCTUnwrap(SpeechPresenceGate.maximumSpeechConfidence(url))
            XCTAssertLessThan(energy, 0.01, row.id)
            XCTAssertTrue(SpeechPresenceGate.checksSingleWord(row.fallback.text, audioDuration: row.duration), row.id)
            if confidence < 0.1 { weakAcousticCandidates += 1 }
            XCTAssertFalse(SpeechPresenceGate.quietSingleWord(row.fallback.text, audioDuration: row.duration,
                maximumFrameRMS: energy, speechConfidence: confidence,
                languageHeadSuggestsNoSpeech: row.probe.negativeHead), row.id)
        }
        XCTAssertGreaterThanOrEqual(weakAcousticCandidates, 12,
            "These controls must exercise weak original acoustics, not just bypass that condition")
    }

    func testCapturedNoiseIsNoSpeechAndRealAnswersSurviveProductionSelection() async throws {
        for row in try fixtures() {
            let url = root.appendingPathComponent(row.audioFile)
            let before = try TranscriptionAttemptCache.fingerprint(url)
            for attempt: TranscriptionWorkRecord.Attempt in [.initial, .automaticRetry] {
                let calls = WordEvidenceCalls()
                let output = try await DurableTranscriptionQueue.recognize(record(row, attempt: attempt),
                    audioURL: url, recordingURL: nil, formulaContext: "", attempts: .init(),
                    transcriber: { _, model, enhanced, mode in
                        try calls.transcribe(row, model: model, enhanced: enhanced, mode: mode)
                    }, speechAnalyzer: { try calls.analyze($0) })
                let rejectedNoise = row.truth == "no-speech" && row.id != "floor-5"
                if rejectedNoise {
                    XCTAssertTrue(output.text.isEmpty, row.id)
                    XCTAssertEqual(output.failureReason, .noSpeech, row.id)
                    XCTAssertNil(output.candidate, row.id)
                    XCTAssertGreaterThan(calls.analysisCount, 0, row.id)
                    XCTAssertEqual(calls.probeCount, 1, "The quality and source checks reuse the exact-range head")
                } else {
                    XCTAssertFalse(output.text.isEmpty, row.id)
                }
                XCTAssertEqual(output.noSpeech, rejectedNoise, "Rejected noise is terminal; real answers must survive")
                XCTAssertEqual(try TranscriptionAttemptCache.fingerprint(url), before, row.id)
            }
        }
    }
}
