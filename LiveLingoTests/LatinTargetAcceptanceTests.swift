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
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
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

extension LatinTargetAcceptanceTests {
    func testForeignCopyRecognitionThresholdAndShortTextPolicy() {
        func assessment(_ constrained: Double, _ unconstrained: Double,
                        detected: String = "es", unrestricted: String = "es") -> LatinTargetAcceptance.LanguageAssessment {
            .init(candidateLanguages: ["en", "es"], detectedLanguage: detected,
                detectedConfidence: constrained, unconstrainedLanguage: unrestricted,
                unconstrainedConfidence: unconstrained)
        }
        let samples: [(LatinTargetAcceptance.LanguageAssessment, Int, Bool)] = [
            (assessment(0.98, 0.98), 3, true),
            (assessment(0.9799, 1), 3, false),
            (assessment(1, 0.9799), 3, false),
            (assessment(1, 1), 2, false),
            (assessment(1, 1, unrestricted: "pt"), 4, false),
            (assessment(1, 1, detected: "en"), 4, false)
        ]
        for (language, count, expected) in samples {
            XCTAssertEqual(LatinTargetAcceptance.hasConfidentForeignCopyLanguage(language,
                target: .english, sourceLanguage: "es-MX", tokenCount: count), expected)
        }
        XCTAssertFalse(LatinTargetAcceptance.hasConfidentForeignCopyLanguage(assessment(1, 1),
            target: .spanish, sourceLanguage: "es", tokenCount: 4))
    }

    func testReviewedEnglishPortableCopiesSurviveProductionClient() async throws {
        let samples: [(String, String)] = [
            ("Los Angeles", "es"), ("La Paz", "es"), ("Agua Prieta", "es"),
            ("Le Havre", "fr"), ("La Rochelle", "fr"), ("Jean de La Fontaine", "fr"),
            ("Pardon.", "fr"), ("Dijkstra", "es"), ("Isaac Newton", "fr"),
            ("Buenos Aires", "es"), ("Radio", "es"), ("frame_index", "fr")
        ]
        for (text, language) in samples {
            XCTAssertNil(TranslationAcceptance.rejection(candidate: text, source: text,
                sourceLanguage: language, target: .english), text)
            let capture = B1RequestCapture()
            do {
                let result = try await QwenTranslationClient.translate(text,
                    modelName: QwenModelProfile.energySaver.translationModel,
                    sourceLanguage: language, target: .english,
                    request: { _, prompt, _ in await capture.reply(prompt: prompt, text: text) })
                XCTAssertEqual(result, text, text)
            } catch { XCTFail("Portable English copy rejected: \(text): \(error)") }
            let prompts = await capture.snapshot()
            XCTAssertEqual(prompts.count, 1, text)
        }
    }

    func testReviewedTitleCaseForeignProseIsRejectedByProductionClient() async throws {
        let samples = [
            ("Continuamos Estudiando Funciones Lineales", "es"),
            ("Aprendemos Conceptos Matemáticos Fundamentales Nuevamente", "es"),
            ("Étudiants Étudient Lentement", "fr"),
            ("La Rochelle Est Belle.", "fr"),
            ("Newton Est Un Scientifique.", "fr")
        ]
        for (title, language) in samples {
            // Case changes cannot turn the same prose into a portable name.
            for text in [title, title.lowercased()] {
                XCTAssertEqual(TranslationAcceptance.rejection(candidate: text, source: text,
                    sourceLanguage: language, target: .english), .sourceCopy, text)
                let capture = B1RequestCapture()
                do {
                    _ = try await QwenTranslationClient.translate(text,
                        modelName: QwenModelProfile.energySaver.translationModel,
                        sourceLanguage: language, target: .english,
                        request: { _, prompt, _ in await capture.reply(prompt: prompt, text: text) })
                    XCTFail("Copied foreign prose reached an English caption: \(text)")
                } catch QwenRuntimeError.translationRejected { }
                let prompts = await capture.snapshot()
                XCTAssertEqual(prompts.count, 1, text)
            }
        }
    }

    private static let b1ForeignShortCaptions: [(source: String, language: String, translation: String)] = [
        ("Hola.", "es", "Hello."),
        ("Buenos días.", "es", "Good morning."),
        ("No sé.", "es", "I do not know."),
        ("La presión.", "es", "The pressure."),
        ("Bonjour.", "fr", "Hello."),
        ("Merci beaucoup.", "fr", "Thank you very much."),
        ("C’est faux.", "fr", "That is false.")
    ]

    private actor B1RequestCapture {
        private var prompts: [String] = []
        func reply(prompt: String, text: String) -> String {
            prompts.append(prompt)
            return text
        }
        func snapshot() -> [String] { prompts }
    }

    func testB1ShortForeignEchoesAreRejectedByEnglishAcceptance() {
        for sample in Self.b1ForeignShortCaptions {
            XCTAssertNotNil(LatinTargetAcceptance.rejection(candidate: sample.source,
                source: sample.source, target: .english, sourceLanguage: sample.language), sample.source)
            XCTAssertNotNil(TranslationAcceptance.rejection(candidate: sample.source,
                source: sample.source, sourceLanguage: sample.language, target: .english), sample.source)
        }
    }

    func testB1ProductionClientRejectsShortForeignEchoAndAcceptsContentRetry() async throws {
        for model in [QwenModelProfile.energySaver.translationModel, QwenModelProfile.highQuality.translationModel] {
            for sample in Self.b1ForeignShortCaptions {
                let requests = B1RequestCapture()
                do {
                    _ = try await QwenTranslationClient.translate(sample.source, modelName: model,
                        sourceLanguage: sample.language, target: .english,
                        request: { _, prompt, _ in
                            await requests.reply(prompt: prompt, text: sample.source)
                        })
                    XCTFail("Foreign source copy reached an English caption: \(sample.source)")
                } catch QwenRuntimeError.translationRejected { }

                // Exercise the production client's content-retry attempt with
                // a new request, after the first output has failed acceptance.
                let translated = try await QwenTranslationClient.translate(sample.source, modelName: model,
                    sourceLanguage: sample.language, target: .english, attempt: .repairContent,
                    request: { _, prompt, _ in
                        await requests.reply(prompt: prompt, text: sample.translation)
                    })
                XCTAssertEqual(translated, sample.translation, sample.source)
                let prompts = await requests.snapshot()
                XCTAssertEqual(prompts.count, 2, sample.source)
                XCTAssertFalse(prompts.first?.contains(QwenTranslationClient.englishRecoverySuffix) == true)
                XCTAssertTrue(prompts.last?.contains(QwenTranslationClient.englishRecoverySuffix) == true)
            }
        }
    }

    func testB1ProductionClientPreservesNamesIdentifiersAndSharedWords() async throws {
        let portable: [(String, String)] = [
            ("Dijkstra.", "es"), ("Isaac Newton", "fr"), ("Buenos Aires", "es"),
            ("DNA ATP FTIR", "fr"), ("500 nm", "es"),
            ("frame_index", "fr"), ("nodeID42", "es"),
            ("Radio.", "es"), ("Hotel.", "es"), ("Internet.", "fr"),
            ("Excellent.", "fr"), ("Question?", "fr")
        ]
        for (text, language) in portable {
            let requests = B1RequestCapture()
            let output = try await QwenTranslationClient.translate(text,
                modelName: QwenModelProfile.energySaver.translationModel,
                sourceLanguage: language, target: .english,
                request: { _, prompt, _ in await requests.reply(prompt: prompt, text: text) })
            XCTAssertEqual(output, text, text)
            let prompts = await requests.snapshot()
            XCTAssertEqual(prompts.count, 1, text)
        }
    }

    func testEnglishHanLengthGuardUsesProductionNFCUnicodeLetterUnit() {
        let mixed = String(repeating: "汉", count: 30) + " DNA e\u{301} 42。"
        XCTAssertEqual(LatinTargetLengthGuard.letterCount(mixed), 34)
        XCTAssertEqual(LatinTargetLengthGuard.letterCount("汉Ａe\u{301}𠮷 123。"), 4)
        XCTAssertEqual(LatinTargetLengthGuard.maximumOutputLetters(source: mixed,
            target: .english, sourceLanguage: "zh"), 34 * 3.84 + 12, accuracy: 1e-12)
        XCTAssertGreaterThan(LatinTargetLengthGuard.maximumOutputLetters(source: mixed,
            target: .english, sourceLanguage: "zh"),
            LatinTargetLengthGuard.maximumOutputLetters(source: String(repeating: "汉", count: 30),
                target: .english, sourceLanguage: "zh"))
    }

    func testEnglishHanCalibratedLengthBoundAcceptsEdgeAndRejectsNextLetter() {
        // 3.84 comes from 2,346 TED training talks with 1,222 held-out talks.
        // The effective p99.5 incorporates the retained floor/allowance.
        XCTAssertEqual(LatinTargetLengthGuard.englishFromHanMaximumRatio, 3.84)
        for source in ["汉", String(repeating: "汉", count: 24),
                       String(repeating: "汉", count: 233),
                       String(repeating: "汉", count: 30) + " DNA"] {
            let limit = LatinTargetLengthGuard.maximumOutputLetters(source: source,
                target: .english, sourceLanguage: "zh")
            let edge = Int(limit.rounded(.down))
            XCTAssertTrue(LatinTargetLengthGuard.isPlausible(candidate: String(repeating: "é", count: edge),
                source: source, target: .english, sourceLanguage: "zh"))
            XCTAssertFalse(LatinTargetLengthGuard.isPlausible(candidate: String(repeating: "é", count: edge + 1),
                source: source, target: .english, sourceLanguage: "zh"))
        }
    }
}

// One review-derived matrix, shared by all three Latin targets. Each row names
// its source review and original probe ID; generated case/other-target variants
// are labelled explicitly. Ambiguous bare product/place names have no asserted
// verdict; four established academic borrowings are neutral translated controls.
// These tests assert final decisions, never an OS tag or confidence number.
extension LatinTargetAcceptanceTests {
    private struct ReviewedLatinCase: Decodable {
        let source: String
        let candidate: String
        let language: String
        let target: String
        let category: String
        let accepted: Bool
        let review: String
    }
    private static let reviewedLatinCasesJSON = #"""
    [
    {"source":"Dijkstra.","candidate":"Dijkstra.","language":"es","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-0"},
    {"source":"Isaac Newton","candidate":"Isaac Newton","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-1"},
    {"source":"Buenos Aires","candidate":"Buenos Aires","language":"es","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-2"},
    {"source":"Los Angeles","candidate":"Los Angeles","language":"es","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-3"},
    {"source":"La Paz","candidate":"La Paz","language":"es","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-4"},
    {"source":"Agua Prieta","candidate":"Agua Prieta","language":"es","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-5"},
    {"source":"Le Havre","candidate":"Le Havre","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-6"},
    {"source":"La Rochelle","candidate":"La Rochelle","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-7"},
    {"source":"Jean de La Fontaine","candidate":"Jean de La Fontaine","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-8"},
    {"source":"Pardon.","candidate":"Pardon.","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-10"},
    {"source":"Radio.","candidate":"Radio.","language":"es","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-11"},
    {"source":"frame_index","candidate":"frame_index","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-12"},
    {"source":"Continuamos Estudiando Funciones Lineales","candidate":"Continuamos Estudiando Funciones Lineales","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:prior-13"},
    {"source":"Continuamos Estudiando Funciones Lineales","candidate":"Continuamos Estudiando Funciones Lineales","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:prior-13 (other Latin target)"},
    {"source":"Aprendemos Conceptos Matemáticos Fundamentales Nuevamente","candidate":"Aprendemos Conceptos Matemáticos Fundamentales Nuevamente","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:prior-14"},
    {"source":"Aprendemos Conceptos Matemáticos Fundamentales Nuevamente","candidate":"Aprendemos Conceptos Matemáticos Fundamentales Nuevamente","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:prior-14 (other Latin target)"},
    {"source":"Étudiants Étudient Lentement","candidate":"Étudiants Étudient Lentement","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:prior-15; int-fix2:academic-copy-case-143"},
    {"source":"Étudiants Étudient Lentement","candidate":"Étudiants Étudient Lentement","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:prior-15 (other Latin target); int-fix2:academic-copy-case-143 (other Latin target)"},
    {"source":"Continuamos estudiando funciones lineales","candidate":"Continuamos estudiando funciones lineales","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:prior-16"},
    {"source":"Continuamos estudiando funciones lineales","candidate":"Continuamos estudiando funciones lineales","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:prior-16 (other Latin target)"},
    {"source":"Le cours a été enregistré à Université de la Polynésie française.","candidate":"The course was recorded at Université de la Polynésie française.","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-17; int-fix2:english-title-or-formula-32"},
    {"source":"Jean de La Fontaine a écrit des fables.","candidate":"Jean de La Fontaine wrote fables.","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-18"},
    {"source":"La charla es sobre Agua Prieta.","candidate":"The talk is about Agua Prieta.","language":"es","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-19"},
    {"source":"Hola.","candidate":"Hello.","language":"es","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-20"},
    {"source":"Merci beaucoup.","candidate":"Thank you very much.","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:prior-21"},
    {"source":"Hola.","candidate":"Hola.","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:b1-22; int-fix2:short-extra-10"},
    {"source":"Hola.","candidate":"Hola.","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:b1-22 (other Latin target); int-fix2:short-extra-10 (other Latin target); tl2526:fr-foreign-0"},
    {"source":"Buenos días.","candidate":"Buenos días.","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:b1-23"},
    {"source":"Buenos días.","candidate":"Buenos días.","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:b1-23 (other Latin target)"},
    {"source":"No sé.","candidate":"No sé.","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:b1-24"},
    {"source":"No sé.","candidate":"No sé.","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:b1-24 (other Latin target); tl2526:fr-foreign-2"},
    {"source":"La presión.","candidate":"La presión.","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:b1-25"},
    {"source":"La presión.","candidate":"La presión.","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:b1-25 (other Latin target)"},
    {"source":"Bonjour.","candidate":"Bonjour.","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:b1-26; int-fix2:short-extra-13; tl2526:en-copy-0"},
    {"source":"Bonjour.","candidate":"Bonjour.","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:b1-26 (other Latin target); int-fix2:short-extra-13 (other Latin target); tl2526:es-foreign-0"},
    {"source":"Merci beaucoup.","candidate":"Merci beaucoup.","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:b1-27; tl2526:en-copy-2"},
    {"source":"Merci beaucoup.","candidate":"Merci beaucoup.","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:b1-27 (other Latin target); tl2526:es-foreign-2"},
    {"source":"C’est faux.","candidate":"C’est faux.","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:b1-28"},
    {"source":"C’est faux.","candidate":"C’est faux.","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:b1-28 (other Latin target)"},
    {"source":"Introduction à Jean de La Fontaine","candidate":"Introduction to Jean de La Fontaine","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:english-title-or-formula-29"},
    {"source":"Jean de La Fontaine et la mécanique des fluides","candidate":"Jean de La Fontaine and Fluid Mechanics","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:english-title-or-formula-30"},
    {"source":"Étude de cas : Université de la Polynésie française","candidate":"Université de la Polynésie française: A Case Study","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:english-title-or-formula-31"},
    {"source":"Análisis de las mediciones de Río de Janeiro","candidate":"Analysis of Río de Janeiro Measurements","language":"es","target":"en","category":"accept","accepted":true,"review":"int-fix2:english-title-or-formula-33"},
    {"source":"Le théorème de Poincaré et la mécanique moderne","candidate":"The Poincaré Theorem and Modern Mechanics","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:english-title-or-formula-34"},
    {"source":"Introduction aux équations de Navier–Stokes","candidate":"Introduction to the Navier–Stokes Equations","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:english-title-or-formula-35"},
    {"source":"Análisis de datos de Los Angeles","candidate":"Analysis of Data from Los Angeles","language":"es","target":"en","category":"accept","accepted":true,"review":"int-fix2:english-title-or-formula-36"},
    {"source":"La loi de Le Chatelier et l’équilibre","candidate":"Le Chatelier’s Principle and Equilibrium","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:english-title-or-formula-37"},
    {"source":"Estimations a priori pour l’équation des ondes","candidate":"A Priori Estimates for the Wave Equation","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:english-title-or-formula-38"},
    {"source":"L’équation de Navier–Stokes : Re = ρvd/μ","candidate":"The Navier–Stokes Equation: Re = ρvd/μ","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:english-title-or-formula-39"},
    {"source":"La presión aumenta cuando T = 300 K.","candidate":"The pressure increases when T = 300 K.","language":"es","target":"en","category":"accept","accepted":true,"review":"int-fix2:english-title-or-formula-40"},
    {"source":"Équations différentielles linéaires","candidate":"LINEAR DIFFERENTIAL EQUATIONS","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:english-title-or-formula-41"},
    {"source":"La solution contient de l’eau et la température augmente.","candidate":"The solution contient de l’eau and la température augmente.","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:mixed-untranslated-clause-42"},
    {"source":"La pression augmente dans le récipient parce que la température augmente.","candidate":"The pressure increases because la température augmente dans le récipient.","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:mixed-untranslated-clause-43"},
    {"source":"Esto significa que la presión aumenta en el segundo recipiente.","candidate":"This means que la presión aumenta en el segundo recipiente.","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:mixed-untranslated-clause-44"},
    {"source":"La réponse est bonjour tout le monde, puis nous continuons.","candidate":"The answer is Bonjour tout le monde, then we continue.","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:mixed-untranslated-clause-45"},
    {"source":"La ecuación requiere que derivamos respecto al tiempo.","candidate":"The equation requires that derivamos respecto al tiempo.","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:mixed-untranslated-clause-46"},
    {"source":"La preuve utilise une intégration par parties et puis l’équation suit.","candidate":"The proof uses une intégration par parties and then the equation follows.","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:mixed-untranslated-clause-47"},
    {"source":"El resultado es correcto porque el sistema es estable.","candidate":"The result is correct porque el sistema es estable.","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:mixed-untranslated-clause-48"},
    {"source":"La pression est 10 Pa et la température augmente de 2 K.","candidate":"The pressure is 10 Pa and la température augmente de 2 K.","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:mixed-untranslated-clause-49"},
    {"source":"Teorema Fundamental","candidate":"Teorema Fundamental","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-50"},
    {"source":"Teorema Fundamental","candidate":"Teorema Fundamental","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-50 (other Latin target)"},
    {"source":"teorema fundamental","candidate":"teorema fundamental","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-51"},
    {"source":"teorema fundamental","candidate":"teorema fundamental","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-51 (other Latin target)"},
    {"source":"TEOREMA FUNDAMENTAL","candidate":"TEOREMA FUNDAMENTAL","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-52"},
    {"source":"TEOREMA FUNDAMENTAL","candidate":"TEOREMA FUNDAMENTAL","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-52 (other Latin target)"},
    {"source":"Espacio Vectorial","candidate":"Espacio Vectorial","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-53"},
    {"source":"Espacio Vectorial","candidate":"Espacio Vectorial","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-53 (other Latin target)"},
    {"source":"espacio vectorial","candidate":"espacio vectorial","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-54"},
    {"source":"espacio vectorial","candidate":"espacio vectorial","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-54 (other Latin target)"},
    {"source":"ESPACIO VECTORIAL","candidate":"ESPACIO VECTORIAL","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-55"},
    {"source":"ESPACIO VECTORIAL","candidate":"ESPACIO VECTORIAL","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-55 (other Latin target)"},
    {"source":"Matriz Inversa","candidate":"Matriz Inversa","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-56"},
    {"source":"Matriz Inversa","candidate":"Matriz Inversa","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-56 (other Latin target)"},
    {"source":"matriz inversa","candidate":"matriz inversa","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-57"},
    {"source":"matriz inversa","candidate":"matriz inversa","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-57 (other Latin target)"},
    {"source":"MATRIZ INVERSA","candidate":"MATRIZ INVERSA","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-58"},
    {"source":"MATRIZ INVERSA","candidate":"MATRIZ INVERSA","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-58 (other Latin target)"},
    {"source":"Función Continua","candidate":"Función Continua","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-59"},
    {"source":"Función Continua","candidate":"Función Continua","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-59 (other Latin target)"},
    {"source":"función continua","candidate":"función continua","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-60"},
    {"source":"función continua","candidate":"función continua","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-60 (other Latin target)"},
    {"source":"FUNCIÓN CONTINUA","candidate":"FUNCIÓN CONTINUA","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-61"},
    {"source":"FUNCIÓN CONTINUA","candidate":"FUNCIÓN CONTINUA","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-61 (other Latin target)"},
    {"source":"Variable Aleatoria","candidate":"Variable Aleatoria","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-62"},
    {"source":"Variable Aleatoria","candidate":"Variable Aleatoria","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-62 (other Latin target)"},
    {"source":"variable aleatoria","candidate":"variable aleatoria","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-63"},
    {"source":"variable aleatoria","candidate":"variable aleatoria","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-63 (other Latin target)"},
    {"source":"VARIABLE ALEATORIA","candidate":"VARIABLE ALEATORIA","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-64"},
    {"source":"VARIABLE ALEATORIA","candidate":"VARIABLE ALEATORIA","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-64 (other Latin target)"},
    {"source":"Ecuación Diferencial","candidate":"Ecuación Diferencial","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-65"},
    {"source":"Ecuación Diferencial","candidate":"Ecuación Diferencial","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-65 (other Latin target)"},
    {"source":"ecuación diferencial","candidate":"ecuación diferencial","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-66"},
    {"source":"ecuación diferencial","candidate":"ecuación diferencial","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-66 (other Latin target)"},
    {"source":"ECUACIÓN DIFERENCIAL","candidate":"ECUACIÓN DIFERENCIAL","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-67"},
    {"source":"ECUACIÓN DIFERENCIAL","candidate":"ECUACIÓN DIFERENCIAL","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-67 (other Latin target)"},
    {"source":"Producto Escalar","candidate":"Producto Escalar","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-68"},
    {"source":"Producto Escalar","candidate":"Producto Escalar","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-68 (other Latin target)"},
    {"source":"producto escalar","candidate":"producto escalar","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-69"},
    {"source":"producto escalar","candidate":"producto escalar","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-69 (other Latin target)"},
    {"source":"PRODUCTO ESCALAR","candidate":"PRODUCTO ESCALAR","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-70"},
    {"source":"PRODUCTO ESCALAR","candidate":"PRODUCTO ESCALAR","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-70 (other Latin target)"},
    {"source":"Convergencia Uniforme","candidate":"Convergencia Uniforme","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-71"},
    {"source":"Convergencia Uniforme","candidate":"Convergencia Uniforme","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-71 (other Latin target)"},
    {"source":"convergencia uniforme","candidate":"convergencia uniforme","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-72"},
    {"source":"convergencia uniforme","candidate":"convergencia uniforme","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-72 (other Latin target)"},
    {"source":"CONVERGENCIA UNIFORME","candidate":"CONVERGENCIA UNIFORME","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-73"},
    {"source":"CONVERGENCIA UNIFORME","candidate":"CONVERGENCIA UNIFORME","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-73 (other Latin target)"},
    {"source":"Probabilidad Condicional","candidate":"Probabilidad Condicional","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-74"},
    {"source":"Probabilidad Condicional","candidate":"Probabilidad Condicional","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-74 (other Latin target)"},
    {"source":"probabilidad condicional","candidate":"probabilidad condicional","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-75"},
    {"source":"probabilidad condicional","candidate":"probabilidad condicional","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-75 (other Latin target)"},
    {"source":"PROBABILIDAD CONDICIONAL","candidate":"PROBABILIDAD CONDICIONAL","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-76"},
    {"source":"PROBABILIDAD CONDICIONAL","candidate":"PROBABILIDAD CONDICIONAL","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-76 (other Latin target)"},
    {"source":"Análisis Numérico","candidate":"Análisis Numérico","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-77"},
    {"source":"Análisis Numérico","candidate":"Análisis Numérico","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-77 (other Latin target)"},
    {"source":"análisis numérico","candidate":"análisis numérico","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-78"},
    {"source":"análisis numérico","candidate":"análisis numérico","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-78 (other Latin target)"},
    {"source":"ANÁLISIS NUMÉRICO","candidate":"ANÁLISIS NUMÉRICO","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-79"},
    {"source":"ANÁLISIS NUMÉRICO","candidate":"ANÁLISIS NUMÉRICO","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-79 (other Latin target)"},
    {"source":"Série Convergente","candidate":"Série Convergente","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-80"},
    {"source":"Série Convergente","candidate":"Série Convergente","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-80 (other Latin target)"},
    {"source":"série convergente","candidate":"série convergente","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-81"},
    {"source":"série convergente","candidate":"série convergente","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-81 (other Latin target)"},
    {"source":"SÉRIE CONVERGENTE","candidate":"SÉRIE CONVERGENTE","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-82"},
    {"source":"SÉRIE CONVERGENTE","candidate":"SÉRIE CONVERGENTE","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-82 (other Latin target)"},
    {"source":"Fonction Continue","candidate":"Fonction Continue","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-83"},
    {"source":"Fonction Continue","candidate":"Fonction Continue","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-83 (other Latin target)"},
    {"source":"fonction continue","candidate":"fonction continue","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-84"},
    {"source":"fonction continue","candidate":"fonction continue","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-84 (other Latin target)"},
    {"source":"FONCTION CONTINUE","candidate":"FONCTION CONTINUE","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-85"},
    {"source":"FONCTION CONTINUE","candidate":"FONCTION CONTINUE","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-85 (other Latin target)"},
    {"source":"Matrice Inverse","candidate":"Matrice Inverse","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-86"},
    {"source":"Matrice Inverse","candidate":"Matrice Inverse","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-86 (other Latin target)"},
    {"source":"matrice inverse","candidate":"matrice inverse","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-87"},
    {"source":"matrice inverse","candidate":"matrice inverse","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-87 (other Latin target)"},
    {"source":"MATRICE INVERSE","candidate":"MATRICE INVERSE","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-88; int-fix2:name-or-short-control-157"},
    {"source":"MATRICE INVERSE","candidate":"MATRICE INVERSE","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-88 (other Latin target); int-fix2:name-or-short-control-157 (other Latin target)"},
    {"source":"Espace Vectoriel","candidate":"Espace Vectoriel","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-89"},
    {"source":"Espace Vectoriel","candidate":"Espace Vectoriel","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-89 (other Latin target)"},
    {"source":"espace vectoriel","candidate":"espace vectoriel","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-90"},
    {"source":"espace vectoriel","candidate":"espace vectoriel","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-90 (other Latin target)"},
    {"source":"ESPACE VECTORIEL","candidate":"ESPACE VECTORIEL","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-91"},
    {"source":"ESPACE VECTORIEL","candidate":"ESPACE VECTORIEL","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-91 (other Latin target)"},
    {"source":"Variable Aléatoire","candidate":"Variable Aléatoire","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-92"},
    {"source":"Variable Aléatoire","candidate":"Variable Aléatoire","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-92 (other Latin target)"},
    {"source":"variable aléatoire","candidate":"variable aléatoire","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-93"},
    {"source":"variable aléatoire","candidate":"variable aléatoire","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-93 (other Latin target)"},
    {"source":"VARIABLE ALÉATOIRE","candidate":"VARIABLE ALÉATOIRE","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-94"},
    {"source":"VARIABLE ALÉATOIRE","candidate":"VARIABLE ALÉATOIRE","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-94 (other Latin target)"},
    {"source":"Équation Différentielle","candidate":"Équation Différentielle","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-95"},
    {"source":"Équation Différentielle","candidate":"Équation Différentielle","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-95 (other Latin target)"},
    {"source":"équation différentielle","candidate":"équation différentielle","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-96"},
    {"source":"équation différentielle","candidate":"équation différentielle","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-96 (other Latin target)"},
    {"source":"ÉQUATION DIFFÉRENTIELLE","candidate":"ÉQUATION DIFFÉRENTIELLE","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-97"},
    {"source":"ÉQUATION DIFFÉRENTIELLE","candidate":"ÉQUATION DIFFÉRENTIELLE","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-97 (other Latin target)"},
    {"source":"Théorème Fondamental","candidate":"Théorème Fondamental","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-98"},
    {"source":"Théorème Fondamental","candidate":"Théorème Fondamental","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-98 (other Latin target)"},
    {"source":"théorème fondamental","candidate":"théorème fondamental","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-99"},
    {"source":"théorème fondamental","candidate":"théorème fondamental","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-99 (other Latin target)"},
    {"source":"THÉORÈME FONDAMENTAL","candidate":"THÉORÈME FONDAMENTAL","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-100"},
    {"source":"THÉORÈME FONDAMENTAL","candidate":"THÉORÈME FONDAMENTAL","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-100 (other Latin target)"},
    {"source":"Produit Scalaire","candidate":"Produit Scalaire","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-101"},
    {"source":"Produit Scalaire","candidate":"Produit Scalaire","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-101 (other Latin target)"},
    {"source":"produit scalaire","candidate":"produit scalaire","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-102"},
    {"source":"produit scalaire","candidate":"produit scalaire","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-102 (other Latin target)"},
    {"source":"PRODUIT SCALAIRE","candidate":"PRODUIT SCALAIRE","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-103"},
    {"source":"PRODUIT SCALAIRE","candidate":"PRODUIT SCALAIRE","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-103 (other Latin target)"},
    {"source":"Recherche Scientifique","candidate":"Recherche Scientifique","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-104"},
    {"source":"Recherche Scientifique","candidate":"Recherche Scientifique","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-104 (other Latin target)"},
    {"source":"recherche scientifique","candidate":"recherche scientifique","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-105"},
    {"source":"recherche scientifique","candidate":"recherche scientifique","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-105 (other Latin target)"},
    {"source":"RECHERCHE SCIENTIFIQUE","candidate":"RECHERCHE SCIENTIFIQUE","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-106"},
    {"source":"RECHERCHE SCIENTIFIQUE","candidate":"RECHERCHE SCIENTIFIQUE","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-106 (other Latin target)"},
    {"source":"Analyse Numérique","candidate":"Analyse Numérique","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-107"},
    {"source":"Analyse Numérique","candidate":"Analyse Numérique","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-107 (other Latin target)"},
    {"source":"analyse numérique","candidate":"analyse numérique","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-108"},
    {"source":"analyse numérique","candidate":"analyse numérique","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-108 (other Latin target)"},
    {"source":"ANALYSE NUMÉRIQUE","candidate":"ANALYSE NUMÉRIQUE","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-109"},
    {"source":"ANALYSE NUMÉRIQUE","candidate":"ANALYSE NUMÉRIQUE","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-109 (other Latin target)"},
    {"source":"Résultats Expérimentaux","candidate":"Résultats Expérimentaux","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-110"},
    {"source":"Résultats Expérimentaux","candidate":"Résultats Expérimentaux","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-110 (other Latin target)"},
    {"source":"résultats expérimentaux","candidate":"résultats expérimentaux","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-111"},
    {"source":"résultats expérimentaux","candidate":"résultats expérimentaux","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-111 (other Latin target)"},
    {"source":"RÉSULTATS EXPÉRIMENTAUX","candidate":"RÉSULTATS EXPÉRIMENTAUX","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-112"},
    {"source":"RÉSULTATS EXPÉRIMENTAUX","candidate":"RÉSULTATS EXPÉRIMENTAUX","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-112 (other Latin target)"},
    {"source":"Matrices Simétricas Definidas Positivas","candidate":"Matrices Simétricas Definidas Positivas","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-113"},
    {"source":"Matrices Simétricas Definidas Positivas","candidate":"Matrices Simétricas Definidas Positivas","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-113 (other Latin target)"},
    {"source":"matrices simétricas definidas positivas","candidate":"matrices simétricas definidas positivas","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-114"},
    {"source":"matrices simétricas definidas positivas","candidate":"matrices simétricas definidas positivas","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-114 (other Latin target)"},
    {"source":"MATRICES SIMÉTRICAS DEFINIDAS POSITIVAS","candidate":"MATRICES SIMÉTRICAS DEFINIDAS POSITIVAS","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-115"},
    {"source":"MATRICES SIMÉTRICAS DEFINIDAS POSITIVAS","candidate":"MATRICES SIMÉTRICAS DEFINIDAS POSITIVAS","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-115 (other Latin target)"},
    {"source":"Funciones Lineales Independientes","candidate":"Funciones Lineales Independientes","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-116"},
    {"source":"Funciones Lineales Independientes","candidate":"Funciones Lineales Independientes","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-116 (other Latin target)"},
    {"source":"funciones lineales independientes","candidate":"funciones lineales independientes","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-117"},
    {"source":"funciones lineales independientes","candidate":"funciones lineales independientes","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-117 (other Latin target)"},
    {"source":"FUNCIONES LINEALES INDEPENDIENTES","candidate":"FUNCIONES LINEALES INDEPENDIENTES","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-118"},
    {"source":"FUNCIONES LINEALES INDEPENDIENTES","candidate":"FUNCIONES LINEALES INDEPENDIENTES","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-118 (other Latin target)"},
    {"source":"Variables Aleatorias Independientes","candidate":"Variables Aleatorias Independientes","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-119"},
    {"source":"Variables Aleatorias Independientes","candidate":"Variables Aleatorias Independientes","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-119 (other Latin target)"},
    {"source":"variables aleatorias independientes","candidate":"variables aleatorias independientes","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-120"},
    {"source":"variables aleatorias independientes","candidate":"variables aleatorias independientes","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-120 (other Latin target)"},
    {"source":"VARIABLES ALEATORIAS INDEPENDIENTES","candidate":"VARIABLES ALEATORIAS INDEPENDIENTES","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-121"},
    {"source":"VARIABLES ALEATORIAS INDEPENDIENTES","candidate":"VARIABLES ALEATORIAS INDEPENDIENTES","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-121 (other Latin target)"},
    {"source":"Transformaciones Lineales Invertibles","candidate":"Transformaciones Lineales Invertibles","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-122"},
    {"source":"Transformaciones Lineales Invertibles","candidate":"Transformaciones Lineales Invertibles","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-122 (other Latin target)"},
    {"source":"transformaciones lineales invertibles","candidate":"transformaciones lineales invertibles","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-123"},
    {"source":"transformaciones lineales invertibles","candidate":"transformaciones lineales invertibles","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-123 (other Latin target)"},
    {"source":"TRANSFORMACIONES LINEALES INVERTIBLES","candidate":"TRANSFORMACIONES LINEALES INVERTIBLES","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-124"},
    {"source":"TRANSFORMACIONES LINEALES INVERTIBLES","candidate":"TRANSFORMACIONES LINEALES INVERTIBLES","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-124 (other Latin target)"},
    {"source":"Conceptos Matemáticos Fundamentales","candidate":"Conceptos Matemáticos Fundamentales","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-125"},
    {"source":"Conceptos Matemáticos Fundamentales","candidate":"Conceptos Matemáticos Fundamentales","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-125 (other Latin target)"},
    {"source":"conceptos matemáticos fundamentales","candidate":"conceptos matemáticos fundamentales","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-126"},
    {"source":"conceptos matemáticos fundamentales","candidate":"conceptos matemáticos fundamentales","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-126 (other Latin target)"},
    {"source":"CONCEPTOS MATEMÁTICOS FUNDAMENTALES","candidate":"CONCEPTOS MATEMÁTICOS FUNDAMENTALES","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-127"},
    {"source":"CONCEPTOS MATEMÁTICOS FUNDAMENTALES","candidate":"CONCEPTOS MATEMÁTICOS FUNDAMENTALES","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-127 (other Latin target)"},
    {"source":"Équations Différentielles Ordinaires","candidate":"Équations Différentielles Ordinaires","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-128"},
    {"source":"Équations Différentielles Ordinaires","candidate":"Équations Différentielles Ordinaires","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-128 (other Latin target)"},
    {"source":"équations différentielles ordinaires","candidate":"équations différentielles ordinaires","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-129"},
    {"source":"équations différentielles ordinaires","candidate":"équations différentielles ordinaires","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-129 (other Latin target)"},
    {"source":"ÉQUATIONS DIFFÉRENTIELLES ORDINAIRES","candidate":"ÉQUATIONS DIFFÉRENTIELLES ORDINAIRES","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-130"},
    {"source":"ÉQUATIONS DIFFÉRENTIELLES ORDINAIRES","candidate":"ÉQUATIONS DIFFÉRENTIELLES ORDINAIRES","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-130 (other Latin target)"},
    {"source":"Variables Aléatoires Indépendantes","candidate":"Variables Aléatoires Indépendantes","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-131"},
    {"source":"Variables Aléatoires Indépendantes","candidate":"Variables Aléatoires Indépendantes","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-131 (other Latin target)"},
    {"source":"variables aléatoires indépendantes","candidate":"variables aléatoires indépendantes","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-132"},
    {"source":"variables aléatoires indépendantes","candidate":"variables aléatoires indépendantes","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-132 (other Latin target)"},
    {"source":"VARIABLES ALÉATOIRES INDÉPENDANTES","candidate":"VARIABLES ALÉATOIRES INDÉPENDANTES","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-133"},
    {"source":"VARIABLES ALÉATOIRES INDÉPENDANTES","candidate":"VARIABLES ALÉATOIRES INDÉPENDANTES","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-133 (other Latin target)"},
    {"source":"Systèmes Linéaires Homogènes","candidate":"Systèmes Linéaires Homogènes","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-134"},
    {"source":"Systèmes Linéaires Homogènes","candidate":"Systèmes Linéaires Homogènes","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-134 (other Latin target)"},
    {"source":"systèmes linéaires homogènes","candidate":"systèmes linéaires homogènes","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-135"},
    {"source":"systèmes linéaires homogènes","candidate":"systèmes linéaires homogènes","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-135 (other Latin target)"},
    {"source":"SYSTÈMES LINÉAIRES HOMOGÈNES","candidate":"SYSTÈMES LINÉAIRES HOMOGÈNES","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-136"},
    {"source":"SYSTÈMES LINÉAIRES HOMOGÈNES","candidate":"SYSTÈMES LINÉAIRES HOMOGÈNES","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-136 (other Latin target)"},
    {"source":"Formes Quadratiques Positives","candidate":"Formes Quadratiques Positives","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-137"},
    {"source":"Formes Quadratiques Positives","candidate":"Formes Quadratiques Positives","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-137 (other Latin target)"},
    {"source":"formes quadratiques positives","candidate":"formes quadratiques positives","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-138"},
    {"source":"formes quadratiques positives","candidate":"formes quadratiques positives","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-138 (other Latin target)"},
    {"source":"FORMES QUADRATIQUES POSITIVES","candidate":"FORMES QUADRATIQUES POSITIVES","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-139"},
    {"source":"FORMES QUADRATIQUES POSITIVES","candidate":"FORMES QUADRATIQUES POSITIVES","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-139 (other Latin target)"},
    {"source":"Résultats Scientifiques Importants","candidate":"Résultats Scientifiques Importants","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-140"},
    {"source":"Résultats Scientifiques Importants","candidate":"Résultats Scientifiques Importants","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-140 (other Latin target)"},
    {"source":"résultats scientifiques importants","candidate":"résultats scientifiques importants","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-141"},
    {"source":"résultats scientifiques importants","candidate":"résultats scientifiques importants","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-141 (other Latin target)"},
    {"source":"RÉSULTATS SCIENTIFIQUES IMPORTANTS","candidate":"RÉSULTATS SCIENTIFIQUES IMPORTANTS","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-142"},
    {"source":"RÉSULTATS SCIENTIFIQUES IMPORTANTS","candidate":"RÉSULTATS SCIENTIFIQUES IMPORTANTS","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-142 (other Latin target)"},
    {"source":"étudiants étudient lentement","candidate":"étudiants étudient lentement","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-144"},
    {"source":"étudiants étudient lentement","candidate":"étudiants étudient lentement","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-144 (other Latin target)"},
    {"source":"ÉTUDIANTS ÉTUDIENT LENTEMENT","candidate":"ÉTUDIANTS ÉTUDIENT LENTEMENT","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-145; int-fix2:entity-extra-26; tl2526:en-copy-3"},
    {"source":"ÉTUDIANTS ÉTUDIENT LENTEMENT","candidate":"ÉTUDIANTS ÉTUDIENT LENTEMENT","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:academic-copy-case-145 (other Latin target); int-fix2:entity-extra-26 (other Latin target); tl2526:es-foreign-3"},
    {"source":"Función Continua f(x) = x² + 2","candidate":"Función Continua f(x) = x² + 2","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:foreign-copy-formula-146"},
    {"source":"Función Continua f(x) = x² + 2","candidate":"Función Continua f(x) = x² + 2","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:foreign-copy-formula-146 (other Latin target)"},
    {"source":"Équations Différentielles x = 2t","candidate":"Équations Différentielles x = 2t","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:foreign-copy-formula-147"},
    {"source":"Équations Différentielles x = 2t","candidate":"Équations Différentielles x = 2t","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:foreign-copy-formula-147 (other Latin target)"},
    {"source":"Variables Aleatorias X₁, X₂","candidate":"Variables Aleatorias X₁, X₂","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:foreign-copy-formula-148"},
    {"source":"Variables Aleatorias X₁, X₂","candidate":"Variables Aleatorias X₁, X₂","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:foreign-copy-formula-148 (other Latin target)"},
    {"source":"Matrice Inverse 2 × 2","candidate":"Matrice Inverse 2 × 2","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:foreign-copy-formula-149"},
    {"source":"Matrice Inverse 2 × 2","candidate":"Matrice Inverse 2 × 2","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:foreign-copy-formula-149 (other Latin target)"},
    {"source":"FÍSICA 101: CONCEPTOS FUNDAMENTALES","candidate":"FÍSICA 101: CONCEPTOS FUNDAMENTALES","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:foreign-copy-formula-150"},
    {"source":"FÍSICA 101: CONCEPTOS FUNDAMENTALES","candidate":"FÍSICA 101: CONCEPTOS FUNDAMENTALES","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:foreign-copy-formula-150 (other Latin target)"},
    {"source":"ÉTUDIANTS ÉTUDIENT LENTEMENT 2026","candidate":"ÉTUDIANTS ÉTUDIENT LENTEMENT 2026","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:foreign-copy-formula-151; int-fix2:entity-extra-27; tl2526:en-copy-4"},
    {"source":"ÉTUDIANTS ÉTUDIENT LENTEMENT 2026","candidate":"ÉTUDIANTS ÉTUDIENT LENTEMENT 2026","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:foreign-copy-formula-151 (other Latin target); int-fix2:entity-extra-27 (other Latin target); tl2526:es-foreign-4"},
    {"source":"LOS ANGELES","candidate":"LOS ANGELES","language":"es","target":"en","category":"accept","accepted":true,"review":"int-fix2:name-or-short-control-152"},
    {"source":"LE HAVRE","candidate":"LE HAVRE","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:name-or-short-control-153"},
    {"source":"JEAN DE LA FONTAINE","candidate":"JEAN DE LA FONTAINE","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:name-or-short-control-154"},
    {"source":"RADIO","candidate":"RADIO","language":"es","target":"en","category":"accept","accepted":true,"review":"int-fix2:name-or-short-control-155"},
    {"source":"PARDON.","candidate":"PARDON.","language":"fr","target":"en","category":"accept","accepted":true,"review":"int-fix2:name-or-short-control-156"},
    {"source":"Théorème de Pythagore","candidate":"Théorème de Pythagore","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:name-or-short-control-158"},
    {"source":"Théorème de Pythagore","candidate":"Théorème de Pythagore","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:name-or-short-control-158 (other Latin target)"},
    {"source":"Gracias","candidate":"Gracias","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:name-or-short-control-160; int-fix2:short-extra-0"},
    {"source":"Gracias","candidate":"Gracias","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:name-or-short-control-160 (other Latin target); int-fix2:short-extra-0 (other Latin target)"},
    {"source":"Salut","candidate":"Salut","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:name-or-short-control-161; int-fix2:short-extra-3"},
    {"source":"Salut","candidate":"Salut","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:name-or-short-control-161 (other Latin target); int-fix2:short-extra-3 (other Latin target)"},
    {"source":"Perdón","candidate":"Perdón","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:name-or-short-control-162; int-fix2:short-extra-6"},
    {"source":"Perdón","candidate":"Perdón","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:name-or-short-control-162 (other Latin target); int-fix2:short-extra-6 (other Latin target)"},
    {"source":"Merci","candidate":"Merci","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:name-or-short-control-163; int-fix2:short-extra-15"},
    {"source":"Merci","candidate":"Merci","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:name-or-short-control-163 (other Latin target); int-fix2:short-extra-15 (other Latin target)"},
    {"source":"Bonjour Monde","candidate":"Bonjour Monde","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:name-or-short-control-164; int-fix2:short-extra-21"},
    {"source":"Bonjour Monde","candidate":"Bonjour Monde","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:name-or-short-control-164 (other Latin target); int-fix2:short-extra-21 (other Latin target)"},
    {"source":"Hola Mundo","candidate":"Hola Mundo","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:name-or-short-control-165; int-fix2:short-extra-18"},
    {"source":"Hola Mundo","candidate":"Hola Mundo","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:name-or-short-control-165 (other Latin target); int-fix2:short-extra-18 (other Latin target)"},
    {"source":"Gracias.","candidate":"Gracias.","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-1"},
    {"source":"Gracias.","candidate":"Gracias.","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:short-extra-1 (other Latin target); tl2526:fr-foreign-1"},
    {"source":"Gracias!","candidate":"Gracias!","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-2"},
    {"source":"Gracias!","candidate":"Gracias!","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:short-extra-2 (other Latin target)"},
    {"source":"Salut.","candidate":"Salut.","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-4; tl2526:en-copy-1"},
    {"source":"Salut.","candidate":"Salut.","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:short-extra-4 (other Latin target); tl2526:es-foreign-1"},
    {"source":"Salut!","candidate":"Salut!","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-5"},
    {"source":"Salut!","candidate":"Salut!","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:short-extra-5 (other Latin target)"},
    {"source":"Perdón.","candidate":"Perdón.","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-7"},
    {"source":"Perdón.","candidate":"Perdón.","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:short-extra-7 (other Latin target)"},
    {"source":"Perdón!","candidate":"Perdón!","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-8"},
    {"source":"Perdón!","candidate":"Perdón!","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:short-extra-8 (other Latin target)"},
    {"source":"Hola","candidate":"Hola","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-9"},
    {"source":"Hola","candidate":"Hola","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:short-extra-9 (other Latin target)"},
    {"source":"Hola!","candidate":"Hola!","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-11"},
    {"source":"Hola!","candidate":"Hola!","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:short-extra-11 (other Latin target)"},
    {"source":"Bonjour","candidate":"Bonjour","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-12"},
    {"source":"Bonjour","candidate":"Bonjour","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:short-extra-12 (other Latin target)"},
    {"source":"Bonjour!","candidate":"Bonjour!","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-14"},
    {"source":"Bonjour!","candidate":"Bonjour!","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:short-extra-14 (other Latin target)"},
    {"source":"Merci.","candidate":"Merci.","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-16"},
    {"source":"Merci.","candidate":"Merci.","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:short-extra-16 (other Latin target)"},
    {"source":"Merci!","candidate":"Merci!","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-17"},
    {"source":"Merci!","candidate":"Merci!","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:short-extra-17 (other Latin target)"},
    {"source":"Hola Mundo.","candidate":"Hola Mundo.","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-19"},
    {"source":"Hola Mundo.","candidate":"Hola Mundo.","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:short-extra-19 (other Latin target)"},
    {"source":"Hola Mundo!","candidate":"Hola Mundo!","language":"es","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-20"},
    {"source":"Hola Mundo!","candidate":"Hola Mundo!","language":"es","target":"fr","category":"reject","accepted":false,"review":"int-fix2:short-extra-20 (other Latin target)"},
    {"source":"Bonjour Monde.","candidate":"Bonjour Monde.","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-22"},
    {"source":"Bonjour Monde.","candidate":"Bonjour Monde.","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:short-extra-22 (other Latin target)"},
    {"source":"Bonjour Monde!","candidate":"Bonjour Monde!","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:short-extra-23"},
    {"source":"Bonjour Monde!","candidate":"Bonjour Monde!","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:short-extra-23 (other Latin target)"},
    {"source":"Étudiants Étudient Lentement 2026","candidate":"Étudiants Étudient Lentement 2026","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:entity-extra-24"},
    {"source":"Étudiants Étudient Lentement 2026","candidate":"Étudiants Étudient Lentement 2026","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:entity-extra-24 (other Latin target)"},
    {"source":"étudiants étudient lentement 2026","candidate":"étudiants étudient lentement 2026","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:entity-extra-25"},
    {"source":"étudiants étudient lentement 2026","candidate":"étudiants étudient lentement 2026","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:entity-extra-25 (other Latin target)"},
    {"source":"ÉTUDIANTS ÉTUDIENT LENTEMENT 2026.","candidate":"ÉTUDIANTS ÉTUDIENT LENTEMENT 2026.","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:entity-extra-28"},
    {"source":"ÉTUDIANTS ÉTUDIENT LENTEMENT 2026.","candidate":"ÉTUDIANTS ÉTUDIENT LENTEMENT 2026.","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:entity-extra-28 (other Latin target)"},
    {"source":"ÉTUDIANTS ÉTUDIENT LENTEMENT 1 + 1 = 2","candidate":"ÉTUDIANTS ÉTUDIENT LENTEMENT 1 + 1 = 2","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:entity-extra-29"},
    {"source":"ÉTUDIANTS ÉTUDIENT LENTEMENT 1 + 1 = 2","candidate":"ÉTUDIANTS ÉTUDIENT LENTEMENT 1 + 1 = 2","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:entity-extra-29 (other Latin target)"},
    {"source":"Good morning.","candidate":"Good morning.","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-0"},
    {"source":"Thank you.","candidate":"Thank you.","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-1"},
    {"source":"Students study slowly.","candidate":"Students study slowly.","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-2; tl2526:es-boundary-4"},
    {"source":"STUDENTS STUDY SLOWLY","candidate":"STUDENTS STUDY SLOWLY","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-3"},
    {"source":"Students Study Slowly","candidate":"Students Study Slowly","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-4"},
    {"source":"PRESSURE INCREASES","candidate":"PRESSURE INCREASES","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-5"},
    {"source":"TEMPERATURE INCREASES 2026","candidate":"TEMPERATURE INCREASES 2026","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-6"},
    {"source":"Memory Management","candidate":"Memory Management","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-7"},
    {"source":"Read this.","candidate":"Read this.","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-8"},
    {"source":"Wait.","candidate":"Wait.","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-9; tl2526:es-boundary-2"},
    {"source":"Stop.","candidate":"Stop.","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-10"},
    {"source":"Please continue.","candidate":"Please continue.","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-11"},
    {"source":"Hello world.","candidate":"Hello world.","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-12"},
    {"source":"Good Morning","candidate":"Good Morning","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-13"},
    {"source":"Increase","candidate":"Increase","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-copy-14"},
    {"source":"DNA","candidate":"DNA","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-copy-15"},
    {"source":"pH 7.4","candidate":"pH 7.4","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-copy-16"},
    {"source":"O(VE)","candidate":"O(VE)","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-copy-17"},
    {"source":"FTIR","candidate":"FTIR","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-copy-18"},
    {"source":"NASA","candidate":"NASA","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-copy-19"},
    {"source":"New York","candidate":"New York","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-copy-20"},
    {"source":"The New York Times","candidate":"The New York Times","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-copy-21"},
    {"source":"British Museum","candidate":"British Museum","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-copy-22"},
    {"source":"World Health Organization","candidate":"World Health Organization","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-copy-23"},
    {"source":"Pression Température","candidate":"Pression Température","language":"fr","target":"es","category":"reject","accepted":false,"review":"tl2526:es-foreign-5"},
    {"source":"The course was recorded at The University of New South Wales.","candidate":"El curso se grabó en The University of New South Wales.","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-names-terms-0"},
    {"source":"World Health Organization published the report.","candidate":"World Health Organization publicó el informe.","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-names-terms-1"},
    {"source":"The lecture discusses DNA, ATP and NADH.","candidate":"La clase analiza DNA, ATP y NADH.","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-names-terms-2; tl2526:es-boundary-8"},
    {"source":"The algorithm has complexity O(VE).","candidate":"El algoritmo tiene complejidad O(VE).","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-names-terms-3"},
    {"source":"The value is 7.4 pH.","candidate":"El valor es pH 7,4.","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-names-terms-4"},
    {"source":"The current source discusses Newton’s Laws of Motion.","candidate":"La fuente actual explica Newton’s Laws of Motion.","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-names-terms-5"},
    {"source":"Good morning.","candidate":"Good morning.","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-0"},
    {"source":"Thank you.","candidate":"Thank you.","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-1"},
    {"source":"Students study slowly.","candidate":"Students study slowly.","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-2; tl2526:fr-boundary-4"},
    {"source":"STUDENTS STUDY SLOWLY","candidate":"STUDENTS STUDY SLOWLY","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-3"},
    {"source":"Students Study Slowly","candidate":"Students Study Slowly","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-4"},
    {"source":"PRESSURE INCREASES","candidate":"PRESSURE INCREASES","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-5"},
    {"source":"TEMPERATURE INCREASES 2026","candidate":"TEMPERATURE INCREASES 2026","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-6"},
    {"source":"Memory Management","candidate":"Memory Management","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-7"},
    {"source":"Read this.","candidate":"Read this.","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-8"},
    {"source":"Wait.","candidate":"Wait.","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-9; tl2526:fr-boundary-2"},
    {"source":"Stop.","candidate":"Stop.","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-10"},
    {"source":"Please continue.","candidate":"Please continue.","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-11"},
    {"source":"Hello world.","candidate":"Hello world.","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-12"},
    {"source":"Good Morning","candidate":"Good Morning","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-13"},
    {"source":"Increase","candidate":"Increase","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-copy-14"},
    {"source":"DNA","candidate":"DNA","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-copy-15"},
    {"source":"pH 7.4","candidate":"pH 7.4","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-copy-16"},
    {"source":"O(VE)","candidate":"O(VE)","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-copy-17"},
    {"source":"FTIR","candidate":"FTIR","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-copy-18"},
    {"source":"NASA","candidate":"NASA","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-copy-19"},
    {"source":"New York","candidate":"New York","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-copy-20"},
    {"source":"The New York Times","candidate":"The New York Times","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-copy-21"},
    {"source":"British Museum","candidate":"British Museum","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-copy-22"},
    {"source":"World Health Organization","candidate":"World Health Organization","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-copy-23"},
    {"source":"ESTUDIANTES ESTUDIAN LENTAMENTE","candidate":"ESTUDIANTES ESTUDIAN LENTAMENTE","language":"es","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-foreign-3"},
    {"source":"ESTUDIANTES ESTUDIAN LENTAMENTE 2026","candidate":"ESTUDIANTES ESTUDIAN LENTAMENTE 2026","language":"es","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-foreign-4"},
    {"source":"Presión Temperatura","candidate":"Presión Temperatura","language":"es","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-foreign-5"},
    {"source":"The course was recorded at The University of New South Wales.","candidate":"Le cours a été enregistré à The University of New South Wales.","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-names-terms-0"},
    {"source":"World Health Organization published the report.","candidate":"World Health Organization a publié le rapport.","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-names-terms-1"},
    {"source":"The lecture discusses DNA, ATP and NADH.","candidate":"Le cours analyse DNA, ATP et NADH.","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-names-terms-2; tl2526:fr-boundary-8"},
    {"source":"The algorithm has complexity O(VE).","candidate":"L’algorithme a une complexité O(VE).","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-names-terms-3"},
    {"source":"The value is 7.4 pH.","candidate":"La valeur est pH 7,4.","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-names-terms-4"},
    {"source":"The current source discusses Newton’s Laws of Motion.","candidate":"La source actuelle explique Newton’s Laws of Motion.","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-names-terms-5"},
    {"source":"Pression Température","candidate":"Pression Température","language":"fr","target":"en","category":"reject","accepted":false,"review":"tl2526:en-copy-5"},
    {"source":"Université de la Polynésie française","candidate":"Université de la Polynésie française","language":"fr","target":"en","category":"accept","accepted":true,"review":"tl2526:en-copy-6; int-fix2:institution name; tl2526:medium-2 (derived bare institution control)"},
    {"source":"DNA","candidate":"DNA","language":"fr","target":"en","category":"accept","accepted":true,"review":"tl2526:en-copy-7"},
    {"source":"pH 7.4","candidate":"pH 7.4","language":"fr","target":"en","category":"accept","accepted":true,"review":"tl2526:en-copy-8"},
    {"source":"O(VE)","candidate":"O(VE)","language":"fr","target":"en","category":"accept","accepted":true,"review":"tl2526:en-copy-9"},
    {"source":"The lecture discusses DNA, ATP and NADH.","candidate":"The lecture discusses DNA, ATP and NADH.","language":"en","target":"en","category":"accept","accepted":true,"review":"tl2526:en-names-terms-2"},
    {"source":"The algorithm has complexity O(VE).","candidate":"The algorithm has complexity O(VE).","language":"en","target":"en","category":"accept","accepted":true,"review":"tl2526:en-names-terms-3"},
    {"source":"The value is 7.4 pH.","candidate":"The value is pH 7.4.","language":"en","target":"en","category":"accept","accepted":true,"review":"tl2526:en-names-terms-4"},
    {"source":"The current source discusses Newton’s Laws of Motion.","candidate":"The current source discusses Newton’s Laws of Motion.","language":"en","target":"en","category":"accept","accepted":true,"review":"tl2526:en-names-terms-5"},
    {"source":"The book title is \"The Lord of the Rings\".","candidate":"El título del libro es \"The Lord of the Rings\".","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-boundary-0"},
    {"source":"The newspaper is The New York Times.","candidate":"El periódico es The New York Times.","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-boundary-1"},
    {"source":"wait.","candidate":"wait.","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-boundary-3"},
    {"source":"Students Study Slowly.","candidate":"Students Study Slowly.","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-boundary-5"},
    {"source":"STUDENTS STUDY SLOWLY 2026","candidate":"STUDENTS STUDY SLOWLY 2026","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-boundary-6"},
    {"source":"The pressure is 10 Pa and the temperature increases.","candidate":"La presión es 10 Pa y the temperature increases.","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:es-boundary-7"},
    {"source":"DNA ATP NADH","candidate":"DNA ATP NADH","language":"en","target":"es","category":"accept","accepted":true,"review":"tl2526:es-boundary-9"},
    {"source":"The book title is \"The Lord of the Rings\".","candidate":"Le titre du livre est « The Lord of the Rings ».","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-boundary-0"},
    {"source":"The newspaper is The New York Times.","candidate":"Le journal est The New York Times.","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-boundary-1"},
    {"source":"wait.","candidate":"wait.","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-boundary-3"},
    {"source":"Students Study Slowly.","candidate":"Students Study Slowly.","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-boundary-5"},
    {"source":"STUDENTS STUDY SLOWLY 2026","candidate":"STUDENTS STUDY SLOWLY 2026","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-boundary-6"},
    {"source":"The pressure is 10 Pa and the temperature increases.","candidate":"La pression est de 10 Pa et the temperature increases.","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:fr-boundary-7"},
    {"source":"DNA ATP NADH","candidate":"DNA ATP NADH","language":"en","target":"fr","category":"accept","accepted":true,"review":"tl2526:fr-boundary-9"},
    {"source":"The temperature increases.","candidate":"The temperature increases.","language":"en","target":"en","category":"control","accepted":true,"review":"tl2526:same-language control"},
    {"source":"La temperatura aumenta.","candidate":"La temperatura aumenta.","language":"es","target":"es","category":"control","accepted":true,"review":"tl2526:same-language control"},
    {"source":"La température augmente.","candidate":"La température augmente.","language":"fr","target":"fr","category":"control","accepted":true,"review":"tl2526:same-language control"},
    {"source":"LINEAR DIFFERENTIAL EQUATIONS","candidate":"LINEAR DIFFERENTIAL EQUATIONS","language":"en","target":"en","category":"control","accepted":true,"review":"int-fix2:english-title-or-formula-41 (same-language control)"},
    {"source":"Variables Aleatorias Independientes","candidate":"Variables Aleatorias Independientes","language":"es","target":"es","category":"control","accepted":true,"review":"int-fix2:L1 (same-language control)"},
    {"source":"Formes Quadratiques Positives","candidate":"Formes Quadratiques Positives","language":"fr","target":"fr","category":"control","accepted":true,"review":"int-fix2:L1 (same-language control)"},
    {"source":"Hola.","candidate":"Hello.","language":"es","target":"en","category":"control","accepted":true,"review":"int-fix2:prior-20 (translated control)"},
    {"source":"Hello.","candidate":"Hola.","language":"en","target":"es","category":"control","accepted":true,"review":"int-fix2:R1 (translated control)"},
    {"source":"Hello.","candidate":"Bonjour.","language":"en","target":"fr","category":"control","accepted":true,"review":"int-fix2:R1 (translated control)"},
    {"source":"Le résultat est vrai ceteris paribus.","candidate":"The result holds ceteris paribus.","language":"fr","target":"en","category":"control","accepted":true,"review":"int-fix2:borrowed-academic-control-166 (borrowed academic control)"},
    {"source":"Le raisonnement doit éviter un cercle vicieux.","candidate":"The argument should avoid petitio principii.","language":"fr","target":"en","category":"control","accepted":true,"review":"int-fix2:borrowed-academic-control-167 (borrowed academic control)"},
    {"source":"L’analyse exige une raison d’être claire.","candidate":"The analysis needs a clear raison d’être.","language":"fr","target":"en","category":"control","accepted":true,"review":"int-fix2:borrowed-academic-control-168 (borrowed academic control)"},
    {"source":"El análisis debe ser válido a priori.","candidate":"The analysis must be valid a priori.","language":"es","target":"en","category":"control","accepted":true,"review":"int-fix2:borrowed-academic-control-169 (borrowed academic control)"},
    {"source":"The University of New South Wales. Students Study Slowly.","candidate":"The University of New South Wales. Students Study Slowly.","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:medium 1/2 (name/quotation boundary control)"},
    {"source":"The teacher says \"The temperature increases\".","candidate":"El profesor dice \"The temperature increases\".","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:medium 1/2 (name/quotation boundary control)"},
    {"source":"The University of New South Wales. Students Study Slowly.","candidate":"The University of New South Wales. Students Study Slowly.","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:medium 1/2 (name/quotation boundary control)"},
    {"source":"The teacher says \"The temperature increases\".","candidate":"Le professeur dit « The temperature increases ».","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:medium 1/2 (name/quotation boundary control)"},
    {"source":"STUDY","candidate":"STUDY","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:medium 1 (short ordinary acronym-spelling variant)"},
    {"source":"REST","candidate":"REST","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:medium 1 (short ordinary acronym-spelling variant)"},
    {"source":"SLEEP","candidate":"SLEEP","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:medium 1 (short ordinary acronym-spelling variant)"},
    {"source":"STUDY","candidate":"STUDY","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:medium 1 (short ordinary acronym-spelling variant)"},
    {"source":"REST","candidate":"REST","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:medium 1 (short ordinary acronym-spelling variant)"},
    {"source":"SLEEP","candidate":"SLEEP","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:medium 1 (short ordinary acronym-spelling variant)"},
    {"source":"Introduction To New York","candidate":"Introduction To New York","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:medium 1/2 (capitalized prose before a real name)"},
    {"source":"Introduction To New York","candidate":"Introduction To New York","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:medium 1/2 (capitalized prose before a real name)"},
    {"source":"STOP2 = STOP2","candidate":"STOP2 = STOP2","language":"en","target":"en","category":"control","accepted":true,"review":"tl2526:academic abbreviation/identifier neutral control (numeric atom boundary)"},
    {"source":"DNA REST2","candidate":"DNA REST2","language":"en","target":"en","category":"control","accepted":true,"review":"tl2526:academic abbreviation/identifier neutral control (numeric atom boundary)"},
    {"source":"STOP2 = STOP2","candidate":"STOP2 = STOP2","language":"en","target":"es","category":"control","accepted":true,"review":"tl2526:academic abbreviation/identifier neutral control (numeric atom boundary)"},
    {"source":"DNA REST2","candidate":"DNA REST2","language":"en","target":"es","category":"control","accepted":true,"review":"tl2526:academic abbreviation/identifier neutral control (numeric atom boundary)"},
    {"source":"STOP2 = STOP2","candidate":"STOP2 = STOP2","language":"en","target":"fr","category":"control","accepted":true,"review":"tl2526:academic abbreviation/identifier neutral control (numeric atom boundary)"},
    {"source":"DNA REST2","candidate":"DNA REST2","language":"en","target":"fr","category":"control","accepted":true,"review":"tl2526:academic abbreviation/identifier neutral control (numeric atom boundary)"},
    {"source":"The book title is \"The temperature increases\". The temperature increases.","candidate":"El título del libro es \"The temperature increases\". The temperature increases.","language":"en","target":"es","category":"reject","accepted":false,"review":"tl2526:medium 1/2 (book title and identical ordinary prose occurrence)"},
    {"source":"The book title is \"The temperature increases\". The temperature increases.","candidate":"Le titre du livre est « The temperature increases ». The temperature increases.","language":"en","target":"fr","category":"reject","accepted":false,"review":"tl2526:medium 1/2 (book title and identical ordinary prose occurrence)"},
    {"source":"Le titre du livre est \"La température augmente\". La température augmente.","candidate":"The book title is \"La température augmente\". La température augmente.","language":"fr","target":"en","category":"reject","accepted":false,"review":"tl2526:medium 1/2 (book title and identical ordinary prose occurrence)"},
    {"source":"University Students","candidate":"University Students","language":"en","target":"es","category":"reject","accepted":false,"review":"int-fix2:R1; tl2526:medium-2 (derived institution-head ordinary-heading boundary)"},
    {"source":"University Students","candidate":"University Students","language":"en","target":"fr","category":"reject","accepted":false,"review":"int-fix2:R1; tl2526:medium-2 (derived institution-head ordinary-heading boundary)"},
    {"source":"UNIVERSITY STUDENTS","candidate":"UNIVERSITY STUDENTS","language":"en","target":"es","category":"reject","accepted":false,"review":"int-fix2:R1; tl2526:medium-2 (derived institution-head ordinary-heading boundary, uppercase variant)"},
    {"source":"UNIVERSITY STUDENTS","candidate":"UNIVERSITY STUDENTS","language":"en","target":"fr","category":"reject","accepted":false,"review":"int-fix2:R1; tl2526:medium-2 (derived institution-head ordinary-heading boundary, uppercase variant)"},
    {"source":"University Pressure","candidate":"University Pressure","language":"en","target":"es","category":"reject","accepted":false,"review":"int-fix2:R1; tl2526:medium-2 (derived institution-head ordinary-heading boundary)"},
    {"source":"University Pressure","candidate":"University Pressure","language":"en","target":"fr","category":"reject","accepted":false,"review":"int-fix2:R1; tl2526:medium-2 (derived institution-head ordinary-heading boundary)"},
    {"source":"UNIVERSITY PRESSURE","candidate":"UNIVERSITY PRESSURE","language":"en","target":"es","category":"reject","accepted":false,"review":"int-fix2:R1; tl2526:medium-2 (derived institution-head ordinary-heading boundary, uppercase variant)"},
    {"source":"UNIVERSITY PRESSURE","candidate":"UNIVERSITY PRESSURE","language":"en","target":"fr","category":"reject","accepted":false,"review":"int-fix2:R1; tl2526:medium-2 (derived institution-head ordinary-heading boundary, uppercase variant)"},
    {"source":"Université Étudiants","candidate":"Université Étudiants","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:R1; tl2526:medium-2 (derived institution-head ordinary-heading boundary)"},
    {"source":"Université Étudiants","candidate":"Université Étudiants","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:R1; tl2526:medium-2 (derived institution-head ordinary-heading boundary)"},
    {"source":"UNIVERSITÉ ÉTUDIANTS","candidate":"UNIVERSITÉ ÉTUDIANTS","language":"fr","target":"en","category":"reject","accepted":false,"review":"int-fix2:R1; tl2526:medium-2 (derived institution-head ordinary-heading boundary, uppercase variant)"},
    {"source":"UNIVERSITÉ ÉTUDIANTS","candidate":"UNIVERSITÉ ÉTUDIANTS","language":"fr","target":"es","category":"reject","accepted":false,"review":"int-fix2:R1; tl2526:medium-2 (derived institution-head ordinary-heading boundary, uppercase variant)"},
    {"source":"University of New South Wales","candidate":"University of New South Wales","language":"en","target":"es","category":"control","accepted":true,"review":"int-fix2:institution name; tl2526:medium-2 (derived bare institution control)"},
    {"source":"University of New South Wales","candidate":"University of New South Wales","language":"en","target":"fr","category":"control","accepted":true,"review":"int-fix2:institution name; tl2526:medium-2 (derived bare institution control)"}
    ]
    """#

    func testReviewedLatinCopyMatrixThroughAcceptanceAndProductionClient() async throws {
        let cases = try JSONDecoder().decode([ReviewedLatinCase].self, from: Data(Self.reviewedLatinCasesJSON.utf8))
        for sample in cases {
            let label = sample.review + " [" + sample.target + "] " + sample.candidate
            let target = try XCTUnwrap(CaptionTranslationTarget(rawValue: sample.target))
            let latin = try XCTUnwrap(LatinTargetAcceptance.Target(rawValue: sample.target))
            XCTAssertEqual(LatinTargetAcceptance.rejection(candidate: sample.candidate, source: sample.source,
                target: latin, sourceLanguage: sample.language) == nil, sample.accepted, label)
            XCTAssertEqual(TranslationAcceptance.rejection(candidate: sample.candidate, source: sample.source,
                sourceLanguage: sample.language, target: target) == nil, sample.accepted, label)
            let requests = RequestCounter()
            do {
                let result = try await QwenTranslationClient.translate(sample.source,
                    modelName: QwenModelProfile.energySaver.translationModel,
                    sourceLanguage: sample.language, target: target,
                    request: { _, _, _ in await requests.increment(); return sample.candidate })
                XCTAssertTrue(sample.accepted, label)
                XCTAssertEqual(result, target.keepsSourceAsCaption(language: sample.language)
                    ? target.renderPassThrough(sample.source) : sample.candidate, label)
            } catch QwenRuntimeError.translationRejected {
                XCTAssertFalse(sample.accepted, label)
            } catch { XCTFail(label + ": " + String(describing: error)) }
            let count = await requests.snapshot()
            XCTAssertEqual(count, target.keepsSourceAsCaption(language: sample.language) ? 0 : 1, label)
        }
        XCTAssertEqual(Set(cases.map(\.target)), Set(["en", "es", "fr"]))
        for category in ["reject", "accept", "control"] {
            XCTAssertTrue(cases.contains { $0.category == category })
        }
        for target in [OutputLanguage.english, .spanish, .french] { XCTAssertFalse(target.isReleased) }
    }

    func testStratifiedSpanishHanLengthBoundaryAndShortFloor() {
        XCTAssertEqual(LatinTargetLengthGuard.maximumRatio(target: .spanish, sourceLanguage: "zh-Hans"), 4.95)
        // tl2526 low 2: duplicate 16/87-letter template uses the 24 floor.
        XCTAssertTrue(LatinTargetLengthGuard.isPlausible(candidate: String(repeating: "a", count: 87),
            source: String(repeating: "汉", count: 16), target: .spanish, sourceLanguage: "zh"))
        // The stratified p99.5 is provisional: 10168:13 is 0.85 letters over.
        let source = String(repeating: "汉", count: 997)
        XCTAssertEqual(LatinTargetLengthGuard.maximumOutputLetters(source: source,
            target: .spanish, sourceLanguage: "zh"), 4947.15, accuracy: 1e-9)
        XCTAssertTrue(LatinTargetLengthGuard.isPlausible(candidate: String(repeating: "a", count: 4947),
            source: source, target: .spanish, sourceLanguage: "zh"))
        XCTAssertFalse(LatinTargetLengthGuard.isPlausible(candidate: String(repeating: "a", count: 4948),
            source: source, target: .spanish, sourceLanguage: "zh"))
    }
}
