import XCTest
@testable import LiveLingo

final class SourceLanguagePolicyTests: XCTestCase {
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

    private struct ConformanceGroup: Decodable {
        let name: String
        let rows: [Row]
        struct Row: Decodable {
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

    func testOfflineEvaluatorConformance() throws {
        // prepare_source_trigger_conformance.py writes metadata-only public and
        // synthetic goldens next to worker directories, outside the checkout.
        let fixture = FileManager.default.temporaryDirectory.deletingLastPathComponent()
            .appendingPathComponent("source-trigger-conformance.json")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw XCTSkip("Optional external evaluator fixture was not prepared in DerivedData/tmp")
        }
        let groups = try JSONDecoder().decode([ConformanceGroup].self, from: Data(contentsOf: fixture))
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
}
