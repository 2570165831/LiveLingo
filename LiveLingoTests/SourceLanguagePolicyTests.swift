import AVFoundation
import Foundation
import XCTest
@testable import LiveLingo

private final class SourceTriggerReplayCalls: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let predecessor: SourceLanguagePolicy.TriggerState?
        let decision: SourceLanguagePolicy.Decision?
        let after: SourceLanguagePolicy.TriggerState?
        let progress: SourceLanguagePolicy.TriggerState
    }
    struct Call: Sendable {
        let index: Int
        let model: String
        let enhanced: Bool
        let mode: ASRLanguageMode
        let automatic: Int
        let manual: Int
        let confirmedLanguage: String?
        let snapshot: Snapshot?
        var isInitial: Bool { automatic == 0 && manual == 0 }
    }
    private let lock = NSLock()
    private var storage: [Call] = []
    private weak var observedQueue: DurableTranscriptionQueue?
    var value: [Call] { lock.withLock { storage } }
    func append(_ call: Call) { lock.withLock { storage.append(call) } }
    func observe(_ queue: DurableTranscriptionQueue) { lock.withLock { observedQueue = queue } }
    func snapshot(index: Int) -> Snapshot? {
        guard let queue = lock.withLock({ observedQueue }) else { return nil }
        let records = queue.records
        guard let record = records.first(where: { $0.ordinal == index }) else { return nil }
        return Snapshot(predecessor: record.sourceTriggerPredecessor, decision: record.sourceTriggerDecision,
            after: record.sourceTriggerAfter, progress: DurableTranscriptionQueue.restoredSourceTrigger(records))
    }
}

final class SourceLanguagePolicyTests: XCTestCase, @unchecked Sendable {
    private func result(_ code: String = "zh", text: String = "\u{4E00}\u{4E01}",
                        p: Double = 0.90, pEnglish: Double = 0.05) -> ASRTranscription {
        .init(text: text, languageMode: .auto, language: code, decode: .detected,
              detectedLabel: SpokenLanguage.find(code)?.qwenLabel, languageProbability: p,
              englishProbability: pEnglish, generatedTokens: 2, policy: 1)
    }

    private func accepts(_ value: ASRTranscription, duration: TimeInterval = 1) -> Bool {
        SourceLanguagePolicy.accepts(value, audioDuration: duration)
    }

    // All strings below are constructed from artificial scalar sequences, never ASR output.
    private func letters(_ start: UInt32, _ count: Int) -> String {
        String(String.UnicodeScalarView((0..<count).map { UnicodeScalar(start + UInt32($0))! }))
    }

    func testNonLatinProbabilityBoundaries() {
        XCTAssertFalse(accepts(result(p: 0.8999)))
        XCTAssertTrue(accepts(result(p: 0.90)))
        XCTAssertTrue(accepts(result(p: 0.9001)))
        XCTAssertTrue(accepts(result(pEnglish: 0.0499)))
        XCTAssertTrue(accepts(result(pEnglish: 0.05)))
        XCTAssertFalse(accepts(result(pEnglish: 0.0501)))
    }

    func testLatinProbabilityBoundaries() {
        let text = "a b c d"
        XCTAssertFalse(accepts(result("es", text: text, p: 0.5499, pEnglish: 0.01)))
        XCTAssertTrue(accepts(result("es", text: text, p: 0.55, pEnglish: 0.01)))
        XCTAssertTrue(accepts(result("es", text: text, p: 0.5501, pEnglish: 0.0099)))
        XCTAssertFalse(accepts(result("es", text: text, p: 0.55, pEnglish: 0.0101)))
    }

    func testEnglishNoneInvalidMetadataAndTruncationAreRejected() {
        XCTAssertFalse(accepts(result("en")))
        let mutations: [(inout ASRTranscription) -> Void] = [
            { (v: inout ASRTranscription) in v.detectedLabel = "None" },
            { v in v.language = "xx" }, { v in v.languageMode = .english },
            { v in v.decode = .forced }, { v in v.truncated = true }, { v in v.policy = 2 },
            { v in v.languageProbability = nil }, { v in v.languageProbability = .nan },
            { v in v.languageProbability = 1.0001 }, { v in v.englishProbability = -.infinity },
            { v in v.englishProbability = -0.0001 },
        ]
        for mutate in mutations {
            var value = result()
            mutate(&value)
            XCTAssertFalse(accepts(value))
        }
        XCTAssertFalse(SourceLanguagePolicy.accepts(result(), audioDuration: 1, requestedMode: .english))
    }

    func testHanMinimumAndShareForChineseAndCantonese() {
        for code in ["zh", "yue"] {
            XCTAssertFalse(accepts(result(code, text: letters(0x4E00, 1))))
            XCTAssertTrue(accepts(result(code, text: letters(0x4E00, 2))))
            XCTAssertTrue(accepts(result(code, text: letters(0x4E00, 2) + "ab")))
            XCTAssertFalse(accepts(result(code, text: letters(0x4E00, 2) + "abc")))
            XCTAssertTrue(accepts(result(code, text: letters(0x4E00, 3) + "ab")))
        }
    }

    func testKanaMinimumAndCombinedShare() {
        XCTAssertFalse(accepts(result("ja", text: letters(0x4E00, 2))))
        XCTAssertTrue(accepts(result("ja", text: "\u{3042}")))
        XCTAssertTrue(accepts(result("ja", text: "\u{3042}\u{3044}")))
        XCTAssertTrue(accepts(result("ja", text: "\u{3042}\u{4E00}ab")))
        XCTAssertFalse(accepts(result("ja", text: "\u{3042}\u{4E00}abc")))
        XCTAssertTrue(accepts(result("ja", text: "\u{3042}\u{4E00}\u{4E01}ab")))
    }

    func testHangulMinimumAndShare() {
        XCTAssertFalse(accepts(result("ko", text: letters(0xAC00, 1))))
        XCTAssertTrue(accepts(result("ko", text: letters(0xAC00, 2))))
        XCTAssertTrue(accepts(result("ko", text: letters(0xAC00, 2) + "ab")))
        XCTAssertFalse(accepts(result("ko", text: letters(0xAC00, 2) + "abc")))
        XCTAssertTrue(accepts(result("ko", text: letters(0xAC00, 3) + "ab")))
    }

    func testOtherScriptSixtyPercentBoundaries() {
        for (code, scalar) in [("ru", UInt32(0x0410)), ("mk", 0x0410), ("ar", 0x0627),
                               ("fa", 0x0627), ("th", 0x0E01), ("hi", 0x0915), ("el", 0x03B1)] {
            XCTAssertFalse(accepts(result(code, text: letters(scalar, 2) + "abc")), code)
            XCTAssertTrue(accepts(result(code, text: letters(scalar, 3) + "ab")), code)
            XCTAssertTrue(accepts(result(code, text: letters(scalar, 4) + "a")), code)
            XCTAssertFalse(accepts(result(code, text: "123!?")), code)
        }
    }

    func testLatinTextRecognitionIsNotAnExtraProbabilityGate() {
        XCTAssertTrue(accepts(result("es", text: "a b c", p: 0.55, pEnglish: 0.01)))
        XCTAssertTrue(accepts(result("es", text: "a b c d e", p: 0.55, pEnglish: 0.01)))
        for (code, recognized) in [("id", "ms"), ("ms", "id")] {
            XCTAssertTrue(accepts(result(code, text: recognized, p: 0.55, pEnglish: 0.01)))
        }
    }

    func testNaturalLanguageEnglishPreferenceDoesNotOverrideConfirmedProbe() {
        let value = result("es", text: "This artificial example contains several English words.", p: 0.99, pEnglish: 0)
        XCTAssertTrue(accepts(value))
    }

    func testCharacterFloorAndRateBoundaries() {
        XCTAssertTrue(accepts(result(text: letters(0x4E00, 59)), duration: 1))
        XCTAssertTrue(accepts(result(text: letters(0x4E00, 60)), duration: 1))
        XCTAssertFalse(accepts(result(text: letters(0x4E00, 61)), duration: 1))
        XCTAssertTrue(accepts(result(text: letters(0x4E00, 72)), duration: 6))
        XCTAssertFalse(accepts(result(text: letters(0x4E00, 73)), duration: 6))
        XCTAssertTrue(accepts(result(text: letters(0x4E00, 71)), duration: 6))
        XCTAssertFalse(accepts(result(), duration: .nan))
        XCTAssertFalse(accepts(result(), duration: -1))
    }

    func testCharacterLoopsAtMinimumLengthAndShare() {
        let unit = "\u{4E00}"
        XCTAssertTrue(accepts(result(text: String(repeating: unit, count: 11))))
        XCTAssertFalse(accepts(result(text: String(repeating: unit, count: 12))))
        XCTAssertFalse(accepts(result(text: String(repeating: unit, count: 13))))
        XCTAssertFalse(accepts(result(text: String(repeating: unit, count: 12) + letters(0x4E10, 8))))
        XCTAssertTrue(accepts(result(text: String(repeating: unit, count: 11) + letters(0x4E10, 9))))
        XCTAssertFalse(accepts(result(text: String(repeating: unit, count: 13) + letters(0x4E10, 7))))
        for width in 2...4 {
            XCTAssertFalse(accepts(result(text: String(repeating: letters(0x4E00, width), count: 12 / width))))
        }
    }

    func testSpacedLanguagesUseTheExistingQualityGate() {
        let code = "ru"
        XCTAssertTrue(accepts(result(code, text: letters(0x0410, 2)), duration: 8)) // implausiblyShort is usable
        let loop = Array(repeating: "\u{0410}", count: 12).joined(separator: " ")
        XCTAssertFalse(accepts(result(code, text: loop)))
        XCTAssertFalse(accepts(result(text: "\u{4E00}\u{4E01}\u{FFFD}")))
    }

    func testFewTriggerBoundariesAndMissingConfidence() {
        let state = SourceLanguagePolicy.TriggerState()
        for (mean, minimum, expected) in [
            (0.90, 0.05, false), (0.8999, 0.05, true), (0.90, 0.0499, true),
            (nil, nil, false), (nil, 0.0499, true), (0.8999, nil, true),
        ] as [(Double?, Double?, Bool)] {
            XCTAssertEqual(state.plan(index: 0, parakeetAccepted: true, mean: mean, minimum: minimum).selected, expected)
        }
        XCTAssertTrue(state.plan(index: 0, parakeetAccepted: false, mean: nil, minimum: nil).selected)
        XCTAssertFalse(state.plan(index: 0, parakeetAccepted: true, mean: .nan, minimum: .infinity).selected)
    }

    private func step(_ state: inout SourceLanguagePolicy.TriggerState, index: Int,
                      language: String?, accepted: Bool = true, mean: Double? = 0.99,
                      minimum: Double? = 0.2, p: Double? = 0.95, en: Double? = 0.01,
                      failed: Bool = false) -> SourceLanguagePolicy.Decision {
        let plan = state.plan(index: index, parakeetAccepted: accepted, mean: mean, minimum: minimum)
        let decision = SourceLanguagePolicy.decide(plan, language: language, probability: p,
            englishProbability: en, probeFailed: failed)
        state.advance(index: index, decision: decision)
        return decision
    }

    func testLatinConfirmationIsCausalAndFollowupContinuesAfterConfirmation() {
        var state = SourceLanguagePolicy.TriggerState()
        let first = step(&state, index: 0, language: "es", mean: 0.8, p: 0.55)
        XCTAssertNil(first.language); XCTAssertEqual(first.qualifiedLanguage, "es")
        XCTAssertEqual(first.reason, "pending_consensus")
        for index in 1...3 {
            let next = step(&state, index: index, language: "es", p: 0.55)
            XCTAssertFalse(next.baseEligible); XCTAssertTrue(next.followup)
            XCTAssertEqual(next.language, "es")
        }
        let different = step(&state, index: 4, language: "fr", p: 0.55)
        XCTAssertEqual(different.qualifiedLanguage, "fr"); XCTAssertNil(different.language)
        XCTAssertEqual(step(&state, index: 5, language: "fr", p: 0.55).language, "fr")
    }

    func testNonLatinDoesNotRequireConfirmationButAlsoRequestsFollowup() {
        var state = SourceLanguagePolicy.TriggerState()
        XCTAssertEqual(step(&state, index: 0, language: "zh", mean: 0.8, p: 0.90, en: 0.05).language, "zh")
        let next = step(&state, index: 1, language: "ar", p: 0.90, en: 0.05)
        XCTAssertTrue(next.followup); XCTAssertEqual(next.language, "ar")
    }

    func testFailuresEnglishMissingProbabilitiesAndGapsBreakConfirmation() {
        for interruption in 0..<7 {
            var state = SourceLanguagePolicy.TriggerState()
            _ = step(&state, index: 0, language: "es", mean: 0.8)
            switch interruption {
            case 0: _ = step(&state, index: 1, language: "es", failed: true)
            case 1: _ = step(&state, index: 1, language: "en")
            case 2: _ = step(&state, index: 1, language: nil)
            case 3: _ = step(&state, index: 1, language: "es", p: nil)
            case 4: _ = step(&state, index: 1, language: "es", en: nil)
            case 5: _ = step(&state, index: 1, language: "es", p: 0.5499)
            default: _ = step(&state, index: 1, language: "es", en: 0.0101)
            }
            XCTAssertFalse(step(&state, index: 2, language: "es").selected)
            XCTAssertNil(step(&state, index: 3, language: "es", mean: 0.8).language)
        }
        var state = SourceLanguagePolicy.TriggerState()
        _ = step(&state, index: 0, language: "es", mean: 0.8)
        XCTAssertFalse(step(&state, index: 2, language: "es").selected)
        // A retry of an ordinal cannot be its own predecessor.
        _ = step(&state, index: 3, language: "es", mean: 0.8)
        XCTAssertNil(step(&state, index: 3, language: "es", mean: 0.8).language)
    }

    func testExplicitScriptsAndFrozenLanguageClassification() {
        var state = SourceLanguagePolicy.TriggerState()
        XCTAssertNil(step(&state, index: 0, language: "zh-Latn", mean: 0.8, p: 0.55).language)
        XCTAssertEqual(step(&state, index: 1, language: "zh-Latn", p: 0.55).language, "zh")
        XCTAssertEqual(step(&state, index: 2, language: "es-Cyrl", p: 0.90, en: 0.05).language, "es")
        XCTAssertEqual(step(&state, index: 3, language: "fil", p: 0.90, en: 0.05).language, "fil")
        XCTAssertEqual(step(&state, index: 4, language: "xx", p: 0.90, en: 0.05).language, "xx")
    }

    func testParakeetConfidenceResponseKeepsLegacyTextAndRejectsInvalidStatistics() throws {
        for (json, mean, minimum) in [
            (#"{"pk_mean_probability":0.9,"pk_min_probability":0.05}"#, 0.9, 0.05),
            (#"{"pk_mean_probability":null,"pk_min_probability":0.03}"#, nil, 0.03),
            (#"{"pk_mean_probability":1.1,"pk_min_probability":0.03}"#, nil, nil),
            (#"{"text":"x"}"#, nil, nil),
        ] as [(String, Double?, Double?)] {
            let decoded = try ASRTranscription.validated(text: " x ", data: Data(json.utf8), requestedLanguage: .english)
            XCTAssertEqual(decoded.text, "x"); XCTAssertEqual(decoded.languageMode, .english)
            XCTAssertEqual(decoded.parakeetMeanProbability, mean); XCTAssertEqual(decoded.parakeetMinProbability, minimum)
        }
    }

    func testFrozenParametersMatchAppDeclarations() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/source-language-trigger-parameters.json")
        let parameters = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(parameters["policy"] as? String, SourceLanguagePolicy.triggerPolicy)
        for (key, value) in [
            "latin_threshold": SourceLanguagePolicy.latinMinProbability,
            "latin_english_max": SourceLanguagePolicy.latinMaxEnglishProbability,
            "nonlatin_threshold": SourceLanguagePolicy.nonLatinMinProbability,
            "nonlatin_english_max": SourceLanguagePolicy.nonLatinMaxEnglishProbability,
            "few_mean_threshold": SourceLanguagePolicy.fewMeanThreshold,
            "few_min_threshold": SourceLanguagePolicy.fewMinThreshold,
        ] { XCTAssertEqual(parameters[key] as? Double, value) }
        XCTAssertEqual(parameters["latin_consensus"] as? Bool, SourceLanguagePolicy.latinConsensus)
        XCTAssertEqual(parameters["nonlatin_consensus"] as? Bool, SourceLanguagePolicy.nonLatinConsensus)
        XCTAssertEqual(Set(try XCTUnwrap(parameters["latin_languages"] as? [String])), SourceLanguagePolicy.latinLanguages)
    }

    private struct ConformanceGroup: Decodable, Equatable {
        let name: String
        let rows: [Row]
        struct Row: Decodable, Equatable {
            let index: Int
            let parakeetAccepted: Bool
            let mean: Double?
            let minimum: Double?
            let probeLanguage: String?
            let probability: Double?
            let englishProbability: Double?
            let probeFailed: Bool
            let expected: SourceLanguagePolicy.Decision
        }
    }

    private struct BundledConformance: Decodable {
        let schema: Int
        let simulatorSHA256: String
        let parametersSHA256: String
        let syntheticGroups: [ConformanceGroup]
        let queueGroups: [QueueConformanceGroup]
    }

    private struct QueueConformanceGroup: Decodable, Sendable {
        let name: String
        let rows: [Row]
        struct Row: Decodable, Sendable {
            let index: Int
            let parakeetAccepted: Bool
            let mean: Double?
            let minimum: Double?
            let initialFailure: Bool
            let formalErrors: Bool
            let probe: Probe
            let expected: SourceLanguagePolicy.Decision?
            let oracleDecision: SourceLanguagePolicy.Decision
            let expectedBefore: SourceLanguagePolicy.TriggerState
            let expectedAfter: SourceLanguagePolicy.TriggerState
        }
        struct Probe: Decodable, Sendable {
            let label: String?
            let mode: String
            let policy: Int?
            let probability: Double?
            let englishProbability: Double?
            let throwsError: Bool
            let validated: Bool
            private enum CodingKeys: String, CodingKey {
                case label, mode, policy, probability, englishProbability, validated
                case throwsError = "throws"
            }
        }
    }

    private func bundledConformance() throws -> BundledConformance {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/source-trigger-conformance-synthetic.json")
        let data = try Data(contentsOf: fixture)
        let homePathPrefix = ["", "Users", ""].joined(separator: "/")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(homePathPrefix))
        let bundled = try JSONDecoder().decode(BundledConformance.self, from: data)
        XCTAssertEqual(bundled.schema, 1)
        XCTAssertEqual(bundled.simulatorSHA256, "ef55acac98c08f2fccfa3b11cfd6ffd7aee81d9508f3202d3cef52494d152459")
        XCTAssertEqual(bundled.parametersSHA256, "ae05eb38a3c49a983db1f8403da7fc0bd8e36d8da9405672b9012d7fb9db26dc")
        XCTAssertEqual(bundled.syntheticGroups.reduce(0) { $0 + $1.rows.count }, 4_125)
        XCTAssertEqual(bundled.queueGroups.map(\.name),
            ["labels", "confidence-and-errors", "abnormal-heads", "formal-errors-stop-probe", "initial-failure"])
        return bundled
    }

    func testOfflineEvaluatorConformance() throws {
        // The original full 22,315-row public/synthetic comparison remains.
        // The checked-in synthetic oracle is mandatory even on a fresh checkout.
        let bundled = try bundledConformance()
        var groups = bundled.syntheticGroups
        let fixture = FileManager.default.temporaryDirectory.deletingLastPathComponent()
            .appendingPathComponent("source-trigger-conformance.json")
        if FileManager.default.fileExists(atPath: fixture.path) {
            groups = try JSONDecoder().decode([ConformanceGroup].self, from: Data(contentsOf: fixture))
            XCTAssertEqual(groups.filter { $0.name.hasPrefix("synthetic:") }, bundled.syntheticGroups)
            XCTAssertEqual(groups.reduce(0) { $0 + $1.rows.count }, 22_315)
        } else {
            print("TRIGGER_CONFORMANCE external=absent mandatory_synthetic=4125")
        }
        XCTAssertFalse(groups.isEmpty)
        for group in groups {
            var state = SourceLanguagePolicy.TriggerState(), matched = 0, mismatched = 0
            for row in group.rows {
                let decision = step(&state, index: row.index, language: row.probeLanguage,
                    accepted: row.parakeetAccepted, mean: row.mean, minimum: row.minimum,
                    p: row.probability, en: row.englishProbability, failed: row.probeFailed)
                if decision == row.expected { matched += 1 } else { mismatched += 1 }
            }
            print("TRIGGER_CONFORMANCE group=\(group.name) matched=\(matched) mismatched=\(mismatched)")
            XCTAssertEqual(mismatched, 0, "\(group.name): per-segment decisions differ from simulate.py")
        }
    }

    private enum ReplaySchedule { case sequential, backlog, reopen, initialFailure }

    // Only synthetic PCM and artificial text are used. No service or model runs.
    private func replayAudio(_ directory: URL, index: Int) throws -> URL {
        let url = directory.appendingPathComponent("chunk-\(index).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<16_000 { channel[frame] = 0.05 }
        let audio = try AVAudioFile(forWriting: url, settings: format.settings)
        try audio.write(from: buffer)
        return url
    }

    private static func replayProbe(_ probe: QueueConformanceGroup.Probe) throws -> ASRTranscription {
        if probe.throwsError { throw URLError(.timedOut) }
        if probe.validated {
            let payload: [String: Any] = ["language_mode": probe.mode,
                "detected_label": probe.label.map { $0 as Any } ?? NSNull(),
                "language_probability": probe.probability.map { $0 as Any } ?? NSNull(),
                "english_probability": probe.englishProbability.map { $0 as Any } ?? NSNull(),
                "policy": probe.policy.map { $0 as Any } ?? NSNull()]
            return try ASRTranscription.validated(text: "",
                data: JSONSerialization.data(withJSONObject: payload), requestedLanguage: .probe)
        }
        // Explicitly unchecked heads exercise queue defenses too, rather than
        // silently treating unsupported raw codes as real Qwen language labels.
        let mode = try XCTUnwrap(ASRLanguageMode(rawValue: probe.mode))
        return ASRTranscription(text: "", languageMode: mode, detectedLabel: probe.label,
            languageProbability: probe.probability, englishProbability: probe.englishProbability,
            policy: probe.policy)
    }

    private static func replayBody(_ language: String) throws -> ASRTranscription {
        let source = try XCTUnwrap(SpokenLanguage.find(language))
        let text: String
        switch source.writingSystem {
        case .han: text = "\u{4E00}\u{4E01}"
        case .japanese: text = "\u{3042}\u{3044}"
        case .hangul: text = "\u{AC00}\u{AC01}"
        case .cyrillic: text = "\u{0410}\u{0411}"
        case .arabic: text = "\u{0627}\u{0628}"
        case .thai: text = "\u{0E01}\u{0E02}"
        case .devanagari: text = "\u{0915}\u{0916}"
        case .greek: text = "\u{03B1}\u{03B2}"
        case .latin: text = "a b c d"
        }
        return ASRTranscription(text: text, languageMode: .auto, language: language, decode: .detected,
            detectedLabel: source.qwenLabel, languageProbability: 1, englishProbability: 0,
            generatedTokens: 4, policy: 1)
    }

    private func replay(_ group: QueueConformanceGroup, schedule: ReplaySchedule) async throws {
        XCTAssertEqual(group.rows.map(\.index), Array(group.rows.indices))
        let root = TestFixtureDirectory.root.appendingPathComponent("SourceTriggerReplay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let session = UUID(), calls = SourceTriggerReplayCalls(), rows = group.rows
        let english = "The blue cart stops beside the metal gate."
        let transcriber: DurableTranscriptionQueue.Transcriber = { url, model, enhanced, mode in
            let index = try XCTUnwrap(Int(url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "chunk-", with: "")))
            guard rows.indices.contains(index) else { throw URLError(.badURL) }
            let row = rows[index]
            let fields = try XCTUnwrap(ASRRequestContext.requestID).split(separator: "_")
            guard fields.count == 6, fields[2].first == "a", fields[3].first == "m" else {
                throw URLError(.badServerResponse)
            }
            let automatic = try XCTUnwrap(Int(fields[2].dropFirst()))
            let manual = try XCTUnwrap(Int(fields[3].dropFirst()))
            calls.append(.init(index: index, model: model, enhanced: enhanced, mode: mode,
                automatic: automatic, manual: manual, confirmedLanguage: ASRRequestContext.confirmedSourceLanguage,
                snapshot: automatic > 0 || manual > 0 ? calls.snapshot(index: index) : nil))
            if model == "primary" {
                if !enhanced, row.formalErrors { throw URLError(.timedOut) }
                var result = ASRTranscription(text: row.parakeetAccepted || enhanced ? english : "")
                result.parakeetMeanProbability = row.mean
                result.parakeetMinProbability = row.minimum
                return result
            }
            if mode == .english {
                if row.formalErrors {
                    // Both formal recognizers throw. Report either ordinary
                    // errors or non-task cancellation before any language head.
                    if row.initialFailure { throw CancellationError() }
                    throw URLError(.timedOut)
                }
                return ASRTranscription(text: english)
            }
            if mode == .probe { return try Self.replayProbe(row.probe) }
            return try Self.replayBody(XCTUnwrap(ASRRequestContext.confirmedSourceLanguage))
        }
        var queue = DurableTranscriptionQueue(transcriber: transcriber)
        calls.observe(queue)
        try await queue.configure(directory: root, sessionID: session, persistent: true, identified: true,
            startPaused: true, handler: { _ in })
        func submit(_ index: Int) throws {
            queue.submit(.init(audioURL: try replayAudio(root, index: index), modelKey: "primary",
                fallbackModelKey: "fallback", start: Double(index), end: Double(index + 1),
                appleEvidence: "", recordingURL: nil, sessionID: session), handler: { _ in })
            XCTAssertEqual(queue.records.count, index + 1)
        }
        let primeCount = schedule == .initialFailure ? 1 : schedule == .reopen ? 3 : 0
        for index in rows.indices {
            try submit(index)
            if schedule == .sequential || index < primeCount {
                try queue.resume(); await queue.finish(); try await queue.pause()
            }
            if schedule == .reopen, index + 1 == primeCount {
                // This reads the persisted state through configure/restoration,
                // not a test-created TriggerState fed back into recognition.
                queue = DurableTranscriptionQueue(transcriber: transcriber)
                calls.observe(queue)
                try await queue.configure(directory: root, sessionID: session, persistent: true,
                    identified: true, restoring: true, startPaused: true, handler: { _ in })
            }
        }
        try queue.resume(); await queue.finish()
        let records = try DurableTranscriptionJournal(sessionDirectory: root, sessionID: session).records
            .sorted { $0.ordinal < $1.ordinal }
        XCTAssertEqual(records, queue.records)
        XCTAssertEqual(records.count, rows.count)
        var matched = 0, mismatched = 0
        for (record, row) in zip(records, rows) {
            let matches = record.sourceTriggerDecision == row.expected
                && record.sourceTriggerPredecessor == row.expectedBefore
                && record.sourceTriggerAfter == row.expectedAfter
            if matches { matched += 1 } else { mismatched += 1 }
            XCTAssertEqual(record.ordinal, row.index)
            XCTAssertEqual(record.status, .completed, "\(group.name) status ordinal=\(row.index)")
            XCTAssertEqual(record.textLanguage, row.expected?.language, "\(group.name) caption ordinal=\(row.index)")
            XCTAssertEqual(record.sourceTriggerDecision, row.expected, "\(group.name) ordinal=\(row.index)")
            XCTAssertEqual(record.sourceTriggerPredecessor, row.expectedBefore, "\(group.name) predecessor ordinal=\(row.index)")
            XCTAssertEqual(record.sourceTriggerAfter, row.expectedAfter, "\(group.name) after ordinal=\(row.index)")
            let rowCalls = calls.value.filter { $0.index == row.index }
            let initialCalls = rowCalls.filter(\.isInitial)
            XCTAssertEqual(initialCalls.filter { $0.mode == .probe }.count,
                row.expected?.selected == true ? 1 : 0, "\(group.name) probe ordinal=\(row.index)")
            XCTAssertEqual(initialCalls.filter { $0.mode == .auto }.count,
                row.expected?.language != nil ? 1 : 0, "\(group.name) body ordinal=\(row.index)")
            if row.formalErrors {
                XCTAssertTrue(rowCalls.contains { $0.model == "primary" && !$0.enhanced })
                XCTAssertTrue(rowCalls.contains { $0.model == "fallback" && $0.mode == .english })
            }
            if row.formalErrors {
                XCTAssertNil(record.sourceProbeInput)
                XCTAssertGreaterThan(record.automaticRetryCount, 0)
                XCTAssertNil(row.expected)
                XCTAssertEqual(row.oracleDecision.reason, "probe_failed")
                let repairCalls = rowCalls.filter { !$0.isInitial }
                let repairProbes = repairCalls.filter { $0.mode == .probe }
                let repairBodies = repairCalls.filter { $0.mode == .auto }
                XCTAssertEqual(repairProbes.count, 1)
                XCTAssertEqual(repairBodies.count, 1)
                XCTAssertTrue(repairCalls.allSatisfy { $0.automatic == 1 && $0.manual == 0 })
                let probeSnapshot = try XCTUnwrap(repairProbes.first?.snapshot)
                let bodySnapshot = try XCTUnwrap(repairBodies.first?.snapshot)
                // Repair may confirm from its immutable first predecessor, but
                // must retain the initial failure's decision/after and live chain.
                XCTAssertEqual(probeSnapshot.predecessor, row.expectedBefore)
                XCTAssertEqual(probeSnapshot.after, row.expectedAfter)
                XCTAssertNil(probeSnapshot.decision)
                XCTAssertEqual(bodySnapshot, probeSnapshot)
                XCTAssertEqual(probeSnapshot.progress, schedule == .sequential ? row.expectedAfter : rows.last?.expectedAfter)
                let predecessor = try XCTUnwrap(rows.first { $0.index == row.index - 1 })
                XCTAssertEqual(repairBodies.first?.confirmedLanguage, predecessor.oracleDecision.qualifiedLanguage)
            } else {
                if let input = record.sourceProbeInput {
                    XCTAssertEqual(input, SourceLanguagePolicy.ProbeInput(parakeetAccepted: row.parakeetAccepted,
                        mean: row.mean, minimum: row.minimum))
                    XCTAssertEqual(record.sourceProbeFinished, true)
                } else {
                    // A resolved, high-confidence English predecessor needs no
                    // optional lane; unresolved backlog heads remain ordered.
                    XCTAssertEqual(row.expected?.selected, false)
                }
            }
        }
        if let last = rows.last {
            XCTAssertEqual(DurableTranscriptionQueue.restoredSourceTrigger(records), last.expectedAfter)
        }
        if schedule != .sequential {
            let tailCalls = calls.value.filter { $0.index >= primeCount }
            let firstProbe = try XCTUnwrap(tailCalls.firstIndex { $0.mode == .probe })
            let initialPrimary = tailCalls.enumerated().filter { $0.element.model == "primary" && !$0.element.enhanced }
            XCTAssertEqual(initialPrimary.count, rows.count - primeCount)
            XCTAssertTrue(initialPrimary.allSatisfy { $0.offset < firstProbe }, "formal backlog must precede source claims")
        }
        print("TRIGGER_CONFORMANCE group=queue:\(group.name):\(schedule) matched=\(matched) mismatched=\(mismatched)")
        XCTAssertEqual(mismatched, 0)
    }

    func testDurableQueueSequentialGoldenReplay() async throws {
        for group in try bundledConformance().queueGroups where group.name != "initial-failure" {
            try await replay(group, schedule: .sequential)
        }
    }

    func testDurableQueueFormalBacklogGoldenReplay() async throws {
        for group in try bundledConformance().queueGroups where group.name != "initial-failure" {
            try await replay(group, schedule: .backlog)
        }
    }

    func testDurableQueueReopenGoldenReplay() async throws {
        let group = try XCTUnwrap(try bundledConformance().queueGroups.first { $0.name == "confidence-and-errors" })
        try await replay(group, schedule: .reopen)
    }

    func testDurableQueueInitialFailureGoldenReplay() async throws {
        let group = try XCTUnwrap(try bundledConformance().queueGroups.first { $0.name == "initial-failure" })
        try await replay(group, schedule: .initialFailure)
    }
}
