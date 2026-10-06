import XCTest
@testable import LiveLingo

final class SourceLanguagePolicyTests: XCTestCase {
    private func result(_ code: String = "zh", text: String = "\u{4E00}\u{4E01}",
                        p: Double = 0.90, pEnglish: Double = 0.05) -> ASRTranscription {
        .init(text: text, languageMode: .auto, language: code, decode: .detected,
              detectedLabel: SpokenLanguage.find(code)?.qwenLabel, languageProbability: p,
              englishProbability: pEnglish, generatedTokens: 2, policy: 1)
    }

    private func accepts(_ value: ASRTranscription, duration: TimeInterval = 1,
                         recognition: SourceLanguagePolicy.Recognition? = nil) -> Bool {
        SourceLanguagePolicy.accepts(value, audioDuration: duration, recognition: recognition)
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
        let recognition = SourceLanguagePolicy.Recognition(code: "es", confidence: 0.80)
        XCTAssertFalse(accepts(result("es", text: text, p: 0.9699, pEnglish: 0.01), recognition: recognition))
        XCTAssertTrue(accepts(result("es", text: text, p: 0.97, pEnglish: 0.01), recognition: recognition))
        XCTAssertTrue(accepts(result("es", text: text, p: 0.9701, pEnglish: 0.0099), recognition: recognition))
        XCTAssertFalse(accepts(result("es", text: text, p: 0.97, pEnglish: 0.0101), recognition: recognition))
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

    func testLatinWordCountRecognitionAndIndonesianMalayAgreement() {
        let es = SourceLanguagePolicy.Recognition(code: "es", confidence: 0.80)
        XCTAssertFalse(accepts(result("es", text: "a b c", p: 0.97, pEnglish: 0.01), recognition: es))
        let value = result("es", text: "a b c d", p: 0.97, pEnglish: 0.01)
        XCTAssertTrue(accepts(value, recognition: es))
        XCTAssertTrue(accepts(result("es", text: "a b c d e", p: 0.97, pEnglish: 0.01), recognition: es))
        XCTAssertFalse(accepts(value, recognition: .init(code: "es", confidence: 0.7999)))
        XCTAssertTrue(accepts(value, recognition: .init(code: "es", confidence: 0.8001)))
        XCTAssertFalse(accepts(value, recognition: .init(code: "en", confidence: 1)))
        XCTAssertFalse(accepts(value, recognition: .init(code: "fr", confidence: 1)))
        XCTAssertFalse(accepts(value, recognition: .init(code: "es", confidence: .nan)))
        for (code, recognized) in [("id", "ms"), ("ms", "id")] {
            XCTAssertTrue(accepts(result(code, text: "a b c d", p: 0.97, pEnglish: 0.01),
                                  recognition: .init(code: recognized, confidence: 0.80)))
        }
    }

    func testNaturalLanguageEnglishPreferenceRejectsLatinSwitch() {
        let value = result("es", text: "This artificial example contains several English words.", p: 0.99, pEnglish: 0)
        XCTAssertFalse(accepts(value))
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
}
