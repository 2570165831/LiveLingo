import Foundation
import XCTest
@testable import LiveLingo

/// Authored sentences only. Public calibration records are never test fixtures.
final class LatinTargetAcceptanceTests: XCTestCase {
    private actor RequestCounter {
        private var count = 0
        func increment() { count += 1 }
        func snapshot() -> Int { count }
    }
    private func reject(_ candidate: String, source: String = "The solution contains water and the temperature increases.",
                        target: LatinTargetAcceptance.Target = .spanish, language: String = "en") -> LatinTargetAcceptance.Rejection? {
        LatinTargetAcceptance.rejection(candidate: candidate, source: source, target: target, sourceLanguage: language)
    }
    func testSpanishTranslation() {
        XCTAssertNil(reject("La solución contiene agua y la temperatura aumenta."))
    }
    func testFrenchTranslation() {
        XCTAssertNil(reject("La solution contient de l’eau et la température augmente.", target: .french))
        XCTAssertNil(reject("La température augmente.", source: "The temperature increases.", target: .french))
        XCTAssertNil(reject("La presión aumenta.", source: "The pressure increases."))
    }
    func testEnglishTranslationFromSpanish() {
        XCTAssertNil(reject("The solution contains water and the temperature increases.",
                            source: "La solución contiene agua y la temperatura aumenta.", target: .english, language: "es"))
    }
    func testEnglishTranslationFromChinese() {
        XCTAssertNil(reject("The solution contains water and the temperature increases.",
                            source: "溶液含水，而且温度正在升高。", target: .english, language: "zh"))
    }
    func testEnglishSourceIsLegalForEnglishTarget() {
        let source = "The solution contains water and the temperature increases."
        XCTAssertNil(reject(source, source: source, target: .english, language: "en"))
    }
    func testEnglishEchoAndParaphraseAreRejected() {
        XCTAssertEqual(reject("The solution contains water and the temperature increases."), .sourceEcho)
        XCTAssertEqual(reject("Water is present in the solution and it gets warmer."), .wrongLanguage)
        XCTAssertEqual(reject("The solution contains water and the temperature increases.", target: .french), .sourceEcho)
    }
    func testSourceCopyAndWrongRomanceLanguage() {
        XCTAssertEqual(reject("La solution contient de l’eau et la température augmente.",
                              source: "La solution contient de l’eau et la température augmente.", language: "fr"), .sourceEcho)
        XCTAssertEqual(reject("Le comité demande un rapport et nous présentons les résultats.", target: .english, language: "zh"), .wrongLanguage)
        XCTAssertEqual(reject("El comité solicita un informe y nosotros presentamos los resultados.", target: .english, language: "zh"), .wrongLanguage)
        XCTAssertEqual(reject("Le comité demande un rapport et nous présentons les résultats."), .wrongLanguage)
        XCTAssertEqual(reject("El comité solicita un informe y nosotros presentamos los resultados.", target: .french), .wrongLanguage)
    }
    func testMixedEnglishClauses() {
        let source = "The solution contains water and the temperature increases. The pressure increases in the second vessel."
        let candidate = "La solución contiene agua y la temperatura aumenta. La presión aumenta en el segundo recipiente, but it is not stable."
        XCTAssertEqual(reject(candidate, source: source), .mixedEnglishProse)
        let french = "La solution contient de l’eau et la température augmente. La pression augmente dans le second récipient, but it is not stable."
        XCTAssertEqual(reject(french, source: source, target: .french), .mixedEnglishProse)
    }
    func testUnpunctuatedEnglishClause() {
        let source = "The solution contains water and the temperature increases but it is not stable."
        XCTAssertEqual(reject("La solución contiene agua y la temperatura aumenta but it is not stable.", source: source), .mixedEnglishProse)
    }
    func testAccentsAndCanonicalNormalization() {
        XCTAssertEqual(LatinTargetAcceptance.languageIdentificationText("SÍ, acción; où, ÉTÉ"), "sí, acción; où, été")
        XCTAssertEqual(LatinTargetAcceptance.languageIdentificationText("e\u{301}"), "é")
        XCTAssertNotEqual(LatinTargetAcceptance.languageIdentificationText("si"), LatinTargetAcceptance.languageIdentificationText("sí"))
        XCTAssertNotEqual(LatinTargetAcceptance.languageIdentificationText("ou"), LatinTargetAcceptance.languageIdentificationText("où"))
    }
    func testRecognitionCandidateSetIsRestricted() {
        XCTAssertEqual(LatinTargetAcceptance.candidateLanguages(target: .spanish, sourceLanguage: "fr-FR"), ["en", "es", "fr"])
        XCTAssertEqual(LatinTargetAcceptance.candidateLanguages(target: .french, sourceLanguage: "zh-Hans"), ["en", "fr", "zh"])
        XCTAssertEqual(LatinTargetAcceptance.candidateLanguages(target: .english, sourceLanguage: nil), ["en"])
        let result = LatinTargetAcceptance.identifyLanguage("La solución contiene agua y la temperatura aumenta.", target: .spanish)
        XCTAssertEqual(result.detectedLanguage, "es")
        XCTAssertTrue(result.candidateLanguages.contains(result.detectedLanguage ?? ""))
    }
    func testEastAsianResidueIncludingHalfwidthAndSupplementaryScripts() {
        for residue in ["水", "𠮷", "かな", "カナ", "ｶﾅ", "한글", "한"] {
            XCTAssertEqual(reject("La solución contiene agua y la temperatura aumenta. " + residue), .nonLatinScript, residue)
        }
    }
    func testOtherScriptsCannotMasqueradeAsLatin() {
        for prose in ["Вода находится в сосуде.", "الماء موجود في الوعاء."] {
            XCTAssertEqual(reject(prose), .nonLatinScript)
        }
    }
    func testLatinOrdinalLettersAndLigaturesAreNotForeignResidue() {
        XCTAssertNil(reject("El informe de la 1.ª sesión y el 2.º comité está listo.",
                            source: "The report from the first session and the second committee is ready."))
        XCTAssertNil(reject("The report is ﬁnal and the ﬁgure is clear.",
                            source: "报告已定稿，而且图示很清楚。", target: .english, language: "zh"))
        XCTAssertEqual(reject("Τhe report is final and the figure is clear.",
                              source: "报告已定稿，而且图示很清楚。", target: .english, language: "zh"), .nonLatinScript)
    }
    func testTerminologyAndFormulaOnlyInputs() {
        for term in ["DNA", "pH 7.4", "O(VE)", "2H₂ + O₂ → 2H₂O", "α = 3.14", "ATP; DNA; pH 7.4"] {
            for target in LatinTargetAcceptance.Target.allCases {
                XCTAssertNil(reject(term, source: term, target: target), term)
            }
        }
    }
    func testFormulaVariablesEmbeddedInTargetProse() {
        XCTAssertNil(reject("El ángulo α aumenta y la temperatura sube.", source: "The angle α increases and the temperature rises."))
        XCTAssertNil(reject("L’angle α augmente et la température monte.", source: "The angle α increases and the temperature rises.", target: .french))
        XCTAssertEqual(reject("El agua aumenta y νερό queda en el recipiente."), .nonLatinScript)
    }
    func testTermListCannotReplaceAFullSentence() {
        XCTAssertEqual(reject("DNA; ATP; pH 7.4"), .incompleteProse)
        XCTAssertFalse(LatinTargetAcceptance.isTerminologyOnly("THIS IS THE ANSWER"))
        XCTAssertFalse(LatinTargetAcceptance.isTerminologyOnly("not valid"))
        XCTAssertEqual(reject("IT CAN FAIL", source: "IT CAN FAIL"), .sourceEcho)
        XCTAssertEqual(reject("WATER REMAINS LIQUID", source: "WATER REMAINS LIQUID"), .sourceEcho)
        XCTAssertNotNil(reject("!!!", source: "DNA"))
        XCTAssertFalse(LatinTargetAcceptance.isTerminologyOnly("!!!"))
    }
    func testShortImperativesNeedNoFunctionWord() {
        XCTAssertNil(reject("Detente.", source: "Stop."))
        XCTAssertNil(reject("Arrête.", source: "Stop.", target: .french))
        XCTAssertNil(reject("Stop.", source: "Detente.", target: .english, language: "es"))
        // The unconstrained recognizer is uncertain about this single word;
        // a forced English class alone must not veto an ambiguous short caption.
        XCTAssertNil(reject("Detente.", source: "停下来。", target: .english, language: "zh"))
        XCTAssertEqual(reject("La temperatura aumenta e noi chiudiamo tutte le finestre.",
                              source: "温度升高，我们关上所有窗户。", target: .english, language: "zh"), .wrongLanguage)
    }
    func testEnglishActionClauseWithoutFunctionWordsIsRejected() {
        let source = "The solution contains water and the temperature increases. Water remains liquid."
        XCTAssertEqual(reject("La solución contiene agua y la temperatura aumenta, water remains liquid.", source: source), .mixedEnglishProse)
        XCTAssertEqual(reject("La solution contient de l’eau et la température augmente, water remains liquid.", source: source, target: .french), .mixedEnglishProse)
    }
    func testSharedStructuralChecks() {
        XCTAssertEqual(reject(""), .empty)
        XCTAssertEqual(reject("<think>La solución contiene agua."), .controlMarker)
        XCTAssertEqual(reject("Here is the translation: La solución contiene agua."), .promptLeak)
        XCTAssertEqual(reject("{\"value\": 9}", source: "{\"value\": 4}"), .jsonStructure)
    }
    func testTargetLanguageInstructionLeaksAndModelSelfDescriptions() {
        XCTAssertEqual(reject("Idioma de origen: inglés. La solución contiene agua."), .promptLeak)
        XCTAssertEqual(reject("Langue source: anglais. La solution contient de l’eau.", target: .french), .promptLeak)
        XCTAssertEqual(reject("Como un modelo de lenguaje, no puedo traducir esta frase."), .modelReply)
        XCTAssertEqual(reject("En tant que modèle de langage, je ne peux pas traduire cette phrase.", target: .french), .modelReply)
        XCTAssertEqual(reject("As a language model, I cannot translate this."), .modelReply)
    }
    func testLectureCanDiscussAModelWithoutBecomingASelfReply() {
        XCTAssertNil(reject("Como un modelo de lenguaje, el sistema produce palabras y no piensa.",
            source: "As a language model, the system produces words and does not think."))
    }
    func testLengthCountsLettersRatherThanDigitsOrPunctuation() {
        XCTAssertEqual(LatinTargetLengthGuard.letterCount("É e\u{301} 中文 123.,!?"), 4)
        let source = String(repeating: "a", count: 100)
        XCTAssertTrue(LatinTargetLengthGuard.isPlausible(candidate: String(repeating: "é", count: 162) + " 123456789 !?",
            source: source, target: .spanish, maximumRatio: 1.5))
        XCTAssertFalse(LatinTargetLengthGuard.isPlausible(candidate: String(repeating: "é", count: 163),
            source: source, target: .spanish, maximumRatio: 1.5))
        XCTAssertEqual(LatinTargetLengthGuard.maximumOutputLetters(source: "DNA", target: .spanish, maximumRatio: 1.5), 48)
        XCTAssertFalse(LatinTargetLengthGuard.isPlausible(candidate: "abc", source: "abc", target: .english, maximumRatio: .nan))
        XCTAssertFalse(LatinTargetLengthGuard.isPlausible(candidate: "abc", source: "abc", target: .english, maximumRatio: 0))
        for ratio in [0.5, 1, 1.5] {
            let limits = [23, 24, 25, 79, 80, 81, 99, 100].map {
                LatinTargetLengthGuard.maximumOutputLetters(source: String(repeating: "a", count: $0), target: .spanish, maximumRatio: ratio)
            }
            XCTAssertEqual(limits, limits.sorted(), "Length allowance must never decrease as the source grows")
        }
    }
    func testLengthPolicyIsSpecificToSourceAndTarget() {
        XCTAssertGreaterThan(LatinTargetLengthGuard.maximumRatio(target: .english, sourceLanguage: "zh"),
                             LatinTargetLengthGuard.maximumRatio(target: .english, sourceLanguage: "es"))
        XCTAssertGreaterThan(LatinTargetLengthGuard.maximumRatio(target: .spanish, sourceLanguage: "zh"),
                             LatinTargetLengthGuard.maximumRatio(target: .spanish, sourceLanguage: "en"))
        XCTAssertEqual(reject(String(repeating: "La solución contiene agua y la temperatura aumenta. ", count: 8)), .disproportionateLength)
    }
    func testStablePrefixKeepsEarlierSentencesAndLeavesRepairableTail() {
        XCTAssertEqual(LatinStableTranslationPrefix.prefix("La temperatura aumenta. La presión baja"), "La temperatura aumenta.")
        XCTAssertEqual(LatinStableTranslationPrefix.prefix("La temperatura aumenta. La presión baja."), "La temperatura aumenta.")
        XCTAssertEqual(LatinStableTranslationPrefix.prefix("La température augmente."), "")
        XCTAssertEqual(LatinStableTranslationPrefix.prefix(" \"La température augmente.\" La suite"), "\"La température augmente.\"")
    }
    func testStablePrefixExcludesDecimalPoints() {
        for value in ["3.14", ".5", "-.5", "1.000", "1.000,50", "3,14"] {
            XCTAssertEqual(LatinStableTranslationPrefix.prefix("La valeur est \(value) et augmente"), "", value)
            XCTAssertEqual(LatinStableTranslationPrefix.prefix("La valeur est \(value). Elle augmente"), "La valeur est \(value).", value)
        }
    }
    func testStablePrefixExcludesAbbreviations() {
        for abbreviation in ["e.g.", "i.e.", "p. ej.", "p. ex.", "Dr.", "U.S.", "Mme."] {
            XCTAssertEqual(LatinStableTranslationPrefix.prefix("\(abbreviation) la valeur augmente"), "", abbreviation)
            XCTAssertEqual(LatinStableTranslationPrefix.prefix("Début. \(abbreviation) la valeur augmente"), "Début.", abbreviation)
        }
    }
    func testInvertedQuestionAndExclamationAreNotSentenceEndings() {
        XCTAssertEqual(LatinStableTranslationPrefix.prefix("¿La presión aumenta"), "")
        XCTAssertEqual(LatinStableTranslationPrefix.prefix("¡La presión aumenta"), "")
        XCTAssertEqual(LatinStableTranslationPrefix.prefix("¿La presión aumenta? ¡La temperatura baja"), "¿La presión aumenta?")
        XCTAssertEqual(LatinStableTranslationPrefix.prefix("¿La presión aumenta? ¡La temperatura baja!"), "¿La presión aumenta?")
    }
    func testNumbersUseLanguageSpecificDecimalAndGrouping() {
        XCTAssertEqual(LatinNumericParser.numbers(in: "3,14; 1.000; 1.000,50", language: "es"), ["314e-2", "1e3", "10005e-1"])
        XCTAssertEqual(LatinNumericParser.numbers(in: "3,14; 1\u{202F}000,50; 1\u{00A0}000; 1 000", language: "fr"),
                       ["314e-2", "10005e-1", "1e3", "1e3"])
        XCTAssertEqual(LatinNumericParser.numbers(in: "3.14; 1,000.50; 1.000", language: "en"), ["314e-2", "10005e-1", "1e0"])
        XCTAssertEqual(LatinNumericParser.numbers(in: "1.000", language: "fr"), ["1e0"])
    }
    func testNumericIdentityPreservesSignAndLargeIntegers() {
        XCTAssertEqual(LatinNumericParser.numbers(in: "-0,010; +1,25e3; 9007199254740992; 9007199254740993", language: "es"),
                       ["-1e-2", "125e1", "9007199254740992e0", "9007199254740993e0"])
        XCTAssertEqual(LatinNumericParser.numbers(in: "−0.0; .5; -2.5e-3", language: "en"), ["0e0", "5e-1", "-25e-4"])
        XCTAssertEqual(LatinNumericParser.numbers(in: "3.14; e.g.; p. ej.", language: "es"), ["314e-2"])
        XCTAssertEqual(LatinNumericParser.numbers(in: "2.3eV; 2.3E-4", language: "en"), ["23e-1", "23e-5"])
    }
    func testInvalidNumericGroupingIsNotPartiallySalvaged() {
        XCTAssertEqual(LatinNumericParser.numbers(in: "1.2.3; 12,34", language: "en"), [])
        XCTAssertEqual(LatinNumericParser.numbers(in: "1e999999999999999999999999", language: "en"), [])
        for invalid in ["1e+", "1E-", "2.3e", "1e-999999999999999999999"] {
            XCTAssertEqual(LatinNumericParser.numbers(in: invalid, language: "en"), [], invalid)
        }
    }

    func testShortEnglishSubtitlesHaveNoMandatoryFunctionWord() {
        let pairs = [
            ("Gracias.", "Thank you."), ("Sí.", "Yes."), ("Buenos días.", "Good morning."),
            ("Exactamente.", "Exactly."), ("Gracias, señor Presidente.", "Thank you, Mr. President."),
            ("¿Qué piensas?", "What do you think?"), ("No lo sé.", "I don't know."),
            ("Vale.", "OK."), ("Hola.", "Hi."), ("Non.", "No."), ("Vete.", "Go.")
        ]
        for (source, candidate) in pairs {
            XCTAssertNil(reject(candidate, source: source, target: .english, language: "es"), candidate)
            XCTAssertFalse(LatinTargetAcceptance.isTerminologyOnly(candidate), candidate)
        }
        XCTAssertNil(reject("Gracias, señor Presidente.", source: "Thank you, Mr. President."))
        XCTAssertEqual(reject("La temperatura aumenta y nosotros cerramos la puerta.",
                              source: "温度升高，我们关上门。", target: .english, language: "zh"), .wrongLanguage)
    }

    func testRomanceSharedWordsNeverCreateAnAsymmetricVeto() {
        for (candidate, source) in [
            ("Veamos un ejemplo.", "Let us see an example."), ("Hay un error.", "There is an error."),
            ("Tengo un problema.", "I have a problem."), ("Un momento.", "One moment."),
            ("Le doy un ejemplo.", "I give you an example.")
        ] { XCTAssertNil(reject(candidate, source: source), candidate) }
        for (candidate, source) in [
            ("Il y a deux méthodes.", "There are two methods."),
            ("Il y a beaucoup de chaleur.", "There is a lot of heat.")
        ] { XCTAssertNil(reject(candidate, source: source, target: .french), candidate) }
        XCTAssertEqual(reject("Nous vous présentons notre méthode et les résultats."), .wrongLanguage)
        XCTAssertEqual(reject("Nosotros hemos preparado este informe para ustedes.", target: .french), .wrongLanguage)
    }

    func testForcedClassificationNeedsHighConfidenceOutsideCandidateSet() {
        func assessment(_ language: String, _ confidence: Double) -> LatinTargetAcceptance.LanguageAssessment {
            .init(candidateLanguages: ["en", "zh"], detectedLanguage: "en", detectedConfidence: 1,
                  unconstrainedLanguage: language, unconstrainedConfidence: confidence)
        }
        XCTAssertTrue(LatinTargetAcceptance.isForcedClassification(assessment("es", 0.99)))
        XCTAssertFalse(LatinTargetAcceptance.isForcedClassification(assessment("es", 0.6)))
        XCTAssertFalse(LatinTargetAcceptance.isForcedClassification(assessment("en", 0.99)))
    }

    func testOnlyRealElementSymbolsAndDisambiguatedChemicalWordsAreTerms() {
        for term in ["Fe", "Og", "Fe₂O₃", "No₂", "NaCl", "He2", "CoCl₂", "118 Og"] {
            XCTAssertTrue(LatinTargetAcceptance.isTerminologyOnly(term), term)
        }
        for word in ["Hi", "Ok", "OK", "Go", "It", "Is", "No", "In", "As", "At", "He", "Am", "Xx", "Aa"] {
            XCTAssertFalse(LatinTargetAcceptance.isTerminologyOnly(word), word)
        }
    }

    func testFormulaPrefixesSuperscriptsDerivativesAndUnitsStayPortable() {
        for formula in ["2πr", "ΔH = −286 kJ/mol", "Δx", "10 μm", "10 µF", "2 Ω", "2 Ω", "λx",
                        "E = mc²", "x² + y² = r²", "O(n²)", "dy/dx", "500 nm", "−286 kJ/mol",
                        "x³⁺", "2 eV", "20 dB", "λ²", "μ₀"] {
            XCTAssertTrue(LatinTargetAcceptance.isTerminologyOnly(formula), formula)
            for target in LatinTargetAcceptance.Target.allCases {
                XCTAssertNil(reject(formula, source: formula, target: target), formula)
            }
        }
        for symbol in ["2πr", "ΔH", "Δx", "10 μm", "10 µF", "Ωm", "Ωm", "λx"] {
            XCTAssertNil(reject("La medida es \(symbol) y la temperatura aumenta.",
                                source: "The measurement is \(symbol) and the temperature increases."), symbol)
        }
        for residue in ["Τhe", "νερό", "Δelta", "λambda", "μικρό"] {
            XCTAssertEqual(reject("La medida es \(residue) y la temperatura aumenta."), .nonLatinScript, residue)
        }
    }

    func testShortNamesHomographsAndUnitsAreNotSourceEchoes() {
        for text in ["Dijkstra.", "Excellent.", "Question?", "Isaac Newton", "DNA ATP FTIR", "500 nm"] {
            XCTAssertNil(reject(text, source: text, target: .french), text)
        }
        XCTAssertNil(reject("Question ?", source: "Question?", target: .french))
        XCTAssertEqual(reject("The pressure remains constant.", source: "The pressure remains constant."), .sourceEcho)
        XCTAssertEqual(reject("La presión permanece constante.", source: "La presión permanece constante.",
                              target: .french, language: "es"), .sourceEcho)
    }

    func testLatinSelfReplyExpressionKeepsPluralLectureSubjects() {
        for text in ["As AI models become more capable, they produce longer reports.",
                     "As AI assistants improve, they provide clearer explanations.",
                     "Being language models, these systems predict the next word."] {
            XCTAssertNil(reject(text, source: "随着人工智能进步，这些系统会生成更详细的报告。", target: .english, language: "zh"), text)
        }
        for text in ["As an AI model, I cannot translate this.", "I am an artificial intelligence assistant.",
                     "Being a large language model, I cannot answer."] {
            XCTAssertEqual(reject(text, target: .english), .modelReply, text)
        }
    }

    func testLatinLeakExpressionRequiresAWrapperAndHonorsSourceQuotation() {
        for (text, source, target) in [
            ("Los estudiantes hablan su idioma de origen en casa.", "Students speak their native language at home.", LatinTargetAcceptance.Target.spanish),
            ("Le mot a pour langue d'origine le latin.", "The word originates in Latin.", .french),
            ("The source language has a different word order.", "源语言有不同的语序。", .english)
        ] { XCTAssertNil(reject(text, source: source, target: target, language: target == .english ? "zh" : "en"), text) }
        for wrapper in ["Source language: Spanish", "Idioma de origen: inglés", "Langue d’origine: anglais",
                        "--- END TRANSLATION METADATA ---", #"{"translation_instruction":"translate"}"#] {
            XCTAssertEqual(reject(wrapper, target: .english), .promptLeak, wrapper)
        }
        XCTAssertNil(reject("Source language: English", source: "Source language: English", target: .english))
        XCTAssertNil(reject("Idioma de origen: inglés", source: "Idioma de origen: inglés", language: "es"))
    }

    func testSpanishLeadingZeroDecimalIsNotThousandsGrouping() {
        for value in ["0.001", "0.250", "-0.001", "+0.250", "0.000", "0.001e3", "00.001"] {
            XCTAssertEqual(LatinNumericParser.numbers(in: value, language: "es"),
                           LatinNumericParser.numbers(in: value, language: "en"), value)
        }
        XCTAssertEqual(LatinNumericParser.numbers(in: "1.001; 250.001; 0,001; 0,250", language: "es"),
                       ["1001e0", "250001e0", "1e-3", "25e-2"])
    }

    func testOrdinalAndAbbreviationDotsNeverFreezeHalfASentence() {
        for ordinal in ["1.º", "2.ª", "3.er"] {
            let sentence = "La \(ordinal) sesión terminó en 1945."
            XCTAssertEqual(LatinStableTranslationPrefix.prefix(sentence + " Luego seguimos"), sentence, ordinal)
            XCTAssertEqual(LatinStableTranslationPrefix.prefix("La \(ordinal) sesión continúa"), "", ordinal)
        }
        for abbreviation in ["Dra.", "Ud.", "Uds.", "pág.", "p.", "Ec.", "Eq.", "Éq.", "Pr.", "aprox.", "approx."] {
            let sentence = "Véase \(abbreviation) García en el informe."
            XCTAssertEqual(LatinStableTranslationPrefix.prefix(sentence + " Luego seguimos"), sentence, abbreviation)
            XCTAssertEqual(LatinStableTranslationPrefix.prefix("Véase \(abbreviation) García"), "", abbreviation)
        }
        XCTAssertEqual(LatinStableTranslationPrefix.prefix("La sesión terminó en 1945. Luego seguimos"), "La sesión terminó en 1945.")
        XCTAssertEqual(LatinStableTranslationPrefix.prefix("La sesión terminó. Error nuevo"), "La sesión terminó.")
    }

    func testSharedStructureKeepsChineseEmptyCheckNormalizationOrder() {
        // The original non-English gate checked emptiness before removing
        // diacritics; the English gate checked the folded body. Keep both.
        XCTAssertEqual(TranslationAcceptance.rejection(candidate: "\u{301}", source: "The leaf grows."), .incompleteProse)
        XCTAssertEqual(TranslationAcceptance.rejection(candidate: "\u{301}", source: "葉が育ちます。",
                                                       sourceLanguage: "ja"), .nonChineseText)
        XCTAssertEqual(TranslationAcceptance.rejection(candidate: " \t", source: "葉が育ちます。",
                                                       sourceLanguage: "ja"), .empty)
    }

    func testSharedRejectionMappingNeverAcceptsAnUnmappedFailure() {
        let pairs: [(TranslationAcceptance.Rejection, LatinTargetAcceptance.Rejection)] = [
            (.empty, .empty), (.controlMarker, .controlMarker), (.promptLeak, .promptLeak), (.modelReply, .modelReply),
            (.sourceEcho, .sourceEcho), (.englishProse, .wrongLanguage), (.mixedEnglishProse, .mixedEnglishProse),
            (.nonChineseText, .nonLatinScript), (.incompleteProse, .incompleteProse), (.jsonStructure, .jsonStructure),
            (.jsonQuantity, .jsonStructure), (.sourceProse, .sourceProse), (.sourceCopy, .sourceEcho),
            (.disproportionateLength, .disproportionateLength)
        ]
        for (shared, latin) in pairs { XCTAssertEqual(LatinTargetAcceptance.structuralRejection(shared), latin) }
    }

    @MainActor
    func testAppModelDefaultCaptionPipelineDoesNotCallLatinPolicies() async throws {
        #if DEBUG
        let before = LatinAcceptanceInstrumentation.callCounts
        let directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("LatinDefaultPipeline-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LiveLingo-LatinDefaultPipeline-\(UUID())"
        let preferenceCleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
                XCTFail("Caption tests must not load models or create notes")
                throw CancellationError()
            }
        await queue.shutdownForTesting()
        let requests = RequestCounter()
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translate = { text, model, hints, attempt, update in
            try await QwenTranslationClient.translate(text, modelName: model, hints: hints, attempt: attempt,
                onUpdate: update, request: { _, _, _ in await requests.increment(); return "温度升高。" })
        }
        dependencies.adjacent = { previous, translated, current, context, model, repair, hints, update, deferRepair in
            try await QwenTranslationClient.translateAdjacent(previous: previous, previousChinese: translated,
                current: current, context: context, modelName: model, repairPrevious: repair,
                currentHints: hints, onCurrent: update, deferRepair: deferRepair, request: { input, _, _ in
                    await requests.increment()
                    return input.contains("target_translate_only") ? "温度升高。" : "压力降低。"
                })
        }
        let model = AppModel(reviewQueue: queue, translation: dependencies,
            notes: .unavailable, backgroundServices: false, scheduledNotes: false, defaults: defaults)
        model.resetTranslationSessionForTesting()
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            try preferenceCleanup.remove()
            try FileManager.default.removeItem(at: directory)
        }
        model.receiveCaptionForTesting("The temperature increases.", start: 0, end: 1)
        await model.translationTaskForTesting?.value
        model.receiveCaptionForTesting("The pressure decreases.", start: 2, end: 3)
        await model.translationTaskForTesting?.value
        let requestCount = await requests.snapshot()
        XCTAssertGreaterThanOrEqual(requestCount, 2)
        XCTAssertEqual(model.segments.map(\.chinese), ["温度升高。", "压力降低。"])
        XCTAssertTrue(model.segments.allSatisfy(\.hasUsableTranslation))
        XCTAssertEqual(LatinAcceptanceInstrumentation.callCounts, before)
        #else
        throw XCTSkip("Call instrumentation is present only in Debug builds.")
        #endif
    }

    @MainActor
    func testZhHansProductionPathsDoNotCallAnyLatinPolicy() async throws {
        #if DEBUG
        // Positive control: each counter must actually work before asserting 0.
        _ = reject("La solución contiene agua y la temperatura aumenta.")
        _ = LatinStableTranslationPrefix.prefix("Début. Fin")
        _ = LatinNumericParser.numbers(in: "3,14", language: "fr")
        let before = LatinAcceptanceInstrumentation.callCounts
        for key in LatinAcceptanceInstrumentation.Function.allCases { XCTAssertGreaterThan(before[key.rawValue, default: 0], 0) }

        let source = "The temperature increases."
        for model in [QwenModelProfile.energySaver.translationModel, QwenModelProfile.highQuality.translationModel] {
            let output = try await QwenTranslationClient.translate(source, modelName: model,
                request: { _, _, _ in "温度升高。" })
            XCTAssertEqual(output, "温度升高。")
            let typed = try await QwenTranslationClient.translateTypedText(source, modelName: model,
                request: { _, _, _ in "温度升高。" })
            XCTAssertEqual(typed, "温度升高。")
            let foreign = try await QwenTranslationClient.translate("La temperatura aumenta.", modelName: model, sourceLanguage: "es",
                request: { _, _, _ in "温度升高。" })
            XCTAssertEqual(foreign, "温度升高。")
        }
        for profile in [QwenModelProfile.energySaver, .highQuality] {
            let previous = "Check the direction. The force acts."
            let previousChinese = "先检查方向。力起作用。"
            let current = "toward the center."
            let repairRequests = RequestCounter()
            let repair = try await QwenTranslationClient.repairPreviousCaption(previous: previous,
                previousChinese: previousChinese, current: current, context: "Earlier lecture context.",
                modelName: profile.translationModel, request: { _, _, _ in
                    await repairRequests.increment()
                    return "力朝向中心起作用。"
                })
            XCTAssertEqual(repair.previous, "先检查方向。力朝向中心起作用。")
            let repairCount = await repairRequests.snapshot()
            XCTAssertEqual(repairCount, 1)
            let deferredRequests = RequestCounter()
            let deferred = try await QwenTranslationClient.translateAdjacent(previous: previous,
                previousChinese: previousChinese, current: current, context: "Earlier lecture context.",
                modelName: profile.translationModel, deferRepair: { true }, request: { _, _, _ in
                    await deferredRequests.increment()
                    return "朝向中心。"
                })
            XCTAssertTrue(deferred.previousRepairDeferred)
            let deferredCount = await deferredRequests.snapshot()
            XCTAssertEqual(deferredCount, 1)
            for (source, initial, prompt, response, expected) in [
                (#"Translate "the door is closed" into French."#, #"把"the door is closed"译成法语。"#,
                 TranslationAcceptance.QuotedTranslationRepairPlan.prompt, #"{"q0":"门关着"}"#, #"把"门关着"译成法语。"#),
                (#"He wrote {"state":"ready","count":28}."#, #"他写了{"state":"ready","count":28}。"#,
                 TranslationAcceptance.JSONStatusRepairPlan.prompt, #"{"0":"就绪"}"#, #"他写了{"state":"就绪","count":28}。"#)
            ] {
                let requests = RequestCounter()
                let result = try await QwenTranslationClient.translate(source, modelName: profile.translationModel,
                    request: { _, actualPrompt, _ in
                        await requests.increment()
                        return actualPrompt == prompt ? response : initial
                    })
                XCTAssertEqual(result, expected)
                let requestCount = await requests.snapshot()
                XCTAssertEqual(requestCount, 2, "Both the first pass and targeted repair must be exercised")
            }
        }
        XCTAssertNil(TranslationAcceptance.rejection(candidate: "温度升高。", source: source))
        XCTAssertTrue(TranslationLengthGuard.isPlausible(chinese: "温度升高。", english: source))
        XCTAssertEqual(QwenTranslationClient.stableTranslationPrefix("温度升高。压力降低。"), "温度升高。")
        _ = RepairNumericNovelty.assess(candidate: "温度为 7.4。", support: ["Temperature is 7.4."])
        XCTAssertEqual(LatinAcceptanceInstrumentation.callCounts, before)
        #else
        throw XCTSkip("Call instrumentation is present only in Debug builds.")
        #endif
    }
}
