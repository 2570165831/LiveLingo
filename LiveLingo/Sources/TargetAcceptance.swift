import Foundation
import NaturalLanguage

/// Standalone policies for future Latin targets. No production caller selects
/// them yet; CaptionTranslationTarget and the zh-Hans path remain unchanged.
enum LatinTargetAcceptance {
    enum Target: String, CaseIterable, Codable, Sendable {
        case english = "en", spanish = "es", french = "fr"
        var language: NLLanguage { NLLanguage(rawValue: rawValue) }
    }

    enum Rejection: String, Error, Sendable {
        case empty, controlMarker, promptLeak, modelReply, jsonStructure
        case sourceEcho, wrongLanguage, mixedEnglishProse, sourceProse
        case nonLatinScript, incompleteProse, disproportionateLength
        var reason: String {
            switch self {
            case .empty: return "返回内容为空"
            case .controlMarker: return "返回内容含模型控制标记"
            case .promptLeak: return "返回内容含提示词或结构泄漏"
            case .modelReply: return "返回模型自身的回复，而非原文译文"
            case .jsonStructure: return "返回内容改变了原文 JSON 的字段、层级或数据"
            case .sourceEcho: return "返回内容为原语言原样复述"
            case .wrongLanguage: return "返回内容不是目标语言"
            case .mixedEnglishProse: return "返回内容含未翻译的英文语句"
            case .sourceProse: return "返回内容含未翻译的原语言语句"
            case .nonLatinScript: return "返回内容含非拉丁文字残留"
            case .incompleteProse: return "返回内容只保留术语，遗漏了原文语句"
            case .disproportionateLength: return "译文字母数与原文不成比例"
            }
        }
    }

    struct LanguageAssessment: Equatable, Sendable {
        let candidateLanguages: [String]
        let detectedLanguage: String?
        let detectedConfidence: Double
        let unconstrainedLanguage: String?
        let unconstrainedConfidence: Double
    }

    /// Width/case normalization is useful for comparisons, but accents are
    /// evidence (e.g. si/sí and ou/où), not noise. Normalize canonically only.
    static func languageIdentificationText(_ text: String) -> String {
        LatinAcceptanceInstrumentation.record(.languageText)
        return text.precomposedStringWithCanonicalMapping
            .folding(options: [.widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    static func candidateLanguages(target: Target, sourceLanguage: String?) -> [String] {
        LatinAcceptanceInstrumentation.record(.candidates)
        let source = sourceCode(sourceLanguage)
        return Array(Set([target.rawValue, "en", source])).sorted()
    }

    static func identifyLanguage(_ text: String, target: Target,
                                 sourceLanguage: String? = nil) -> LanguageAssessment {
        LatinAcceptanceInstrumentation.record(.language)
        let candidates = candidateLanguages(target: target, sourceLanguage: sourceLanguage)
        let input = languageIdentificationText(text)
        func best(_ recognizer: NLLanguageRecognizer, constrained: Bool) -> (String?, Double) {
            recognizer.processString(input)
            let hypothesis = recognizer.languageHypotheses(withMaximum: 64)
                .filter { $0.value > 0 && (!constrained || candidates.contains(languageCode($0.key))) }
                .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
                .first
            return (hypothesis.map { languageCode($0.key) }, hypothesis?.value ?? 0)
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0 == "zh" ? "zh-Hans" : $0) }
        let constrained = best(recognizer, constrained: true)
        let unconstrained = best(NLLanguageRecognizer(), constrained: false)
        return .init(candidateLanguages: candidates, detectedLanguage: constrained.0,
                     detectedConfidence: constrained.1, unconstrainedLanguage: unconstrained.0,
                     unconstrainedConfidence: unconstrained.1)
    }

    private static func languageCode(_ language: NLLanguage) -> String {
        language.rawValue == "zh-Hans" || language.rawValue == "zh-Hant" ? "zh" : language.rawValue
    }

    static func rejection(candidate: String, source: String, target: Target,
                          sourceLanguage: String? = nil, maximumLengthRatio: Double? = nil) -> Rejection? {
        LatinAcceptanceInstrumentation.record(.acceptance)
        let text = languageIdentificationText(candidate).trimmingCharacters(in: .whitespacesAndNewlines)
        let original = languageIdentificationText(source)
        LatinAcceptanceInstrumentation.record(.sharedStructure)
        if let shared = TranslationAcceptance.structuralRejection(in: text, source: original,
            containsLeak: { hasInstructionLeak($0) && !hasInstructionLeak(original) },
            containsSelfReply: { hasSelfDescription($0) && !hasSelfDescription($1) }) {
            return structuralRejection(shared)
        }
        if source.contains("{"), !TranslationAcceptance.preservesSourceJSON(in: candidate, source: source) {
            return .jsonStructure
        }
        if hasEastAsianScript(candidate) { return .nonLatinScript }
        guard candidate.unicodeScalars.contains(where: {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.symbols.contains($0)
        }) else { return .empty }
        let terms = isTerminologyOnly(candidate)
        if terms {
            guard isTerminologyOnly(source) else { return .incompleteProse }
        } else {
            // Greek variables embedded in a Latin sentence are formulas too.
            // A Greek word cannot match the bounded one-symbol term pattern.
            let prose = termExpression.stringByReplacingMatches(in: candidate,
                range: NSRange(candidate.startIndex..., in: candidate), withTemplate: "")
            if nonLatinLetter.firstMatch(in: prose, range: NSRange(prose.startIndex..., in: prose)) != nil {
                return .nonLatinScript
            }
            let unchanged = echoForm(candidate) == echoForm(source)
            if sourceCode(sourceLanguage) != target.rawValue, unchanged,
               sourceContentWords(source).count >= 3 { return .sourceEcho }
            // Names and short homographs can legitimately remain unchanged.
            // Recognition cannot resolve a language from those portable tokens.
            if !unchanged || sourceContentWords(source).count >= 3 {
                let language = identifyLanguage(candidate, target: target, sourceLanguage: sourceLanguage)
                if isForcedClassification(language) {
                    return .wrongLanguage
                }
                // Short subtitles are ambiguous to the OS recognizer. A missing
                // function word, by itself, is never a reason to reject them.
                if words(candidate).count > 5, language.detectedLanguage != target.rawValue,
                   language.detectedConfidence >= 0.8 { return .wrongLanguage }
                if target != .english, containsEnglishClause(candidate, target: target, sourceLanguage: sourceLanguage) {
                    return .mixedEnglishProse
                }
                if hasCompetingEvidence(candidate, target: target) { return .wrongLanguage }
                if sourceCode(sourceLanguage) != target.rawValue,
                   containsCopiedProse(candidate: candidate, source: source) { return .sourceProse }
            }

        }
        guard LatinTargetLengthGuard.isPlausible(candidate: candidate, source: source, target: target,
                                                sourceLanguage: sourceLanguage, maximumRatio: maximumLengthRatio) else {
            return .disproportionateLength
        }
        return nil
    }

    /// Exhaustive mapping: adding a shared reason requires a compiler-visible
    /// decision here rather than silently accepting an unknown raw string.
    static func structuralRejection(_ rejection: TranslationAcceptance.Rejection) -> Rejection {
        switch rejection {
        case .empty: return .empty
        case .controlMarker: return .controlMarker
        case .promptLeak: return .promptLeak
        case .modelReply: return .modelReply
        case .jsonStructure, .jsonQuantity: return .jsonStructure
        case .sourceEcho, .sourceCopy: return .sourceEcho
        case .englishProse: return .wrongLanguage
        case .mixedEnglishProse: return .mixedEnglishProse
        case .nonChineseText: return .nonLatinScript
        case .incompleteProse: return .incompleteProse
        case .sourceProse: return .sourceProse
        case .disproportionateLength: return .disproportionateLength
        }
    }

    // Latin-only expressions. Keep the Chinese gate's historical expressions
    // byte-for-byte unchanged; ordinary mentions of language/model are prose.
    private static let instructionLeak = try! NSRegularExpression(pattern:
        #"(?im)^[ \t]*(?:[{"]?[ \t]*["']?(?:source language|idioma de origen|langue source|langue d['’]origine|translation_instruction|source_text_to_translate|target_translate_only|context_before_do_not_translate|context_after_do_not_translate)["']?[ \t]*[:=]|(?:here is the translation|aquí está la traducción|voici la traduction)[ \t]*:|---[ \t]*(?:end translation metadata|begin quoted lecture content|end quoted lecture content)\b|```)|(?<![\p{L}\p{N}_])["'](?:translation_instruction|source_text_to_translate|target_translate_only|context_before_do_not_translate|context_after_do_not_translate)["'][ \t]*:"#)
    private static func hasInstructionLeak(_ text: String) -> Bool {
        instructionLeak.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    private static let selfDescription = try! NSRegularExpression(pattern:
        #"(?i)(?:\b(?:as|being|i\s+am|i['’]m)\s+(?:(?:an?|the)\s+)?(?:(?:ai|artificial\s+intelligence)\s+(?:language\s+)?(?:assistant|model)\b|(?:large\s+)?language\s+model\b)|\b(?:como|soy)\s+(?:(?:un|una)\s+)?(?:modelo\b de lenguaje\b|modelo lingüístico\b|asistente\b de (?:ia|inteligencia artificial)\b)|\b(?:en tant que|je suis)\s+(?:(?:un|une)\s+)?(?:modèle\b (?:de langage|linguistique)\b|assistant\b (?:ia|d['’]intelligence artificielle)\b))"#)
    private static func hasSelfDescription(_ text: String) -> Bool {
        selfDescription.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    static func isForcedClassification(_ assessment: LanguageAssessment) -> Bool {
        guard let language = assessment.unconstrainedLanguage else { return false }
        return !assessment.candidateLanguages.contains(language) && assessment.unconstrainedConfidence >= 0.9
    }
    private static func sourceCode(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "en" }
        return code.lowercased().split(separator: "-").first.map(String.init) ?? "en"
    }

    fileprivate static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
        default: return false
        }
    }
    // ICU script properties cover Latin ordinal letters (ª/º), ligatures and
    // extended letters. Block-range guesses misclassify legitimate Latin text.
    private static let nonLatinLetter = try! NSRegularExpression(pattern: #"[\p{L}&&[^\p{Latin}]]"#)
    private static func hasEastAsianScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            if TranslationAcceptance.isHan(s) { return true }
            switch s.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F, 0x1B000...0x1B16F,
                 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF: return true
            default: return false
            }
        }
    }
    private static func echoForm(_ text: String) -> String {
        String(languageIdentificationText(text).unicodeScalars.filter { isLetter($0) || CharacterSet.decimalDigits.contains($0) })
    }
    private static let wordExpression = try! NSRegularExpression(pattern: #"\p{L}[\p{L}\p{M}]*(?:['’][\p{L}\p{M}]+)?"#)
    private static func words(_ text: String) -> [String] {
        let text = languageIdentificationText(text)
        return wordExpression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    // Function-word evidence supplements constrained OS recognition. Shared
    // Romance words need the constrained recognizer; a stronger competing
    // vocabulary vetoes forced classifications of unsupported Latin prose.
    private static let evidence: [Target: Set<String>] = [
        .english: Set("the and is are was were this that these those with from which their our they we have has had would should will but not for to of it its by been being can could must may about into between through because you i a an in on at do does did what how yes no he she your or as".split(separator: " ").map(String.init)),
        .spanish: Set("la de en el los las y o pero un le a una unos unas es son está están este esta estos estas que del al por para como con sin sobre desde hasta entre también se su sus nuestro nuestra nuestros nuestras nosotros ustedes ellos ellas hemos han ha muy más no lo les nos tanto ni sí porque cuando donde puede pueden debe deben cada todos todas todo será fueron hoy".split(separator: " ").map(String.init)),
        .french: Set("la de en le les y a il des du au aux un une et ou est sont été cette cet ces qui que dont dans sur avec sans pour par nous vous leur leurs notre nos votre vos ils elles ont avons avait mais pas ne plus aussi très tous toutes tout soit se ses son sa ce cela aujourd’hui".split(separator: " ").map(String.init))
    ]
    // Symmetric overlap contributes to neither competing language. In
    // particular Spanish/French shared words cannot veto either short subtitle.
    private static func score(_ tokens: [String], target: Target) -> Int {
        let others = Target.allCases.filter { $0 != target }
            .reduce(into: Set<String>()) { $0.formUnion(evidence[$1, default: []]) }
        return tokens.filter { evidence[target, default: []].contains($0) && !others.contains($0) }.count
    }
    private static let englishActions: Set<String> = Set("stop pause wait go start listen look check write read add remove use keep take increase increases decrease decreases rise rises grow grows fall falls remain remains stay stays contain contains produce produces move moves send sends equal equals fail fails work works".split(separator: " ").map(String.init))
    private static func hasCompetingEvidence(_ text: String, target: Target) -> Bool {
        let tokens = words(text), hits = score(tokens, target: target)
        return Target.allCases.contains { other in
            guard other != target else { return false }
            let competing = score(tokens, target: other)
            return competing - hits >= 2 && competing >= 2 * max(1, hits)
                && Double(competing) / Double(max(1, tokens.count)) >= 0.2
        }
    }
    private static func sourceContentWords(_ text: String) -> [String] {
        let tokens = wordExpression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        let lowered = tokens.map { $0.lowercased() }
        let grammatical = lowered.contains { token in
            Target.allCases.contains { evidence[$0, default: []].contains(token) } || englishActions.contains(token)
        }
        return tokens.enumerated().compactMap { index, token in
            guard token.count >= 3 || (grammatical && evidence[.english, default: []].contains(token.lowercased())) else { return nil }
            // Preserve names, symbols, units and acronyms. All-uppercase prose
            // still counts when a grammatical/action word establishes a clause.
            if token.allSatisfy({ !$0.isLowercase }) && !grammatical { return nil }
            if token.first?.isUppercase == true, token.dropFirst().contains(where: \.isLowercase),
               index > 0 || !grammatical { return nil }
            if isTerminologyOnly(token), !(grammatical && tokens.count >= 3 && token.allSatisfy({ !$0.isLowercase })) { return nil }
            return token
        }
    }
    private static func containsEnglishClause(_ text: String, target: Target, sourceLanguage: String?) -> Bool {
        let clauses = text.components(separatedBy: CharacterSet(charactersIn: ".!?;:,\n—"))
        for clause in clauses {
            let tokens = words(clause)
            guard tokens.count >= 3 else { continue }
            // Overlapping windows also catch English without a comma/boundary.
            for start in 0...max(0, tokens.count - 3) {
                let window = Array(tokens[start..<min(tokens.count, start + 8)])
                let english = score(window, target: .english)
                let functionClause = english >= 2 && english > score(window, target: target)
                    && Double(english) / Double(window.count) >= 0.3
                let actionClause = score(window, target: target) == 0 && window.contains(where: englishActions.contains)
                guard functionClause || actionClause else { continue }
                if identifyLanguage(window.joined(separator: " "), target: target,
                                    sourceLanguage: sourceLanguage).detectedLanguage == "en" { return true }
            }
        }
        return false
    }
    private static func containsCopiedProse(candidate: String, source: String) -> Bool {
        let original = words(source), output = words(candidate)
        guard original.count >= 4, output.count >= 4 else { return false }
        let grams = Set((0...(original.count - 4)).map { original[$0..<($0 + 4)].joined(separator: " ") })
        return (0...(output.count - 4)).contains { index in
            let span = Array(output[index..<index + 4])
            return grams.contains(span.joined(separator: " "))
                && Target.allCases.contains { score(span, target: $0) >= 2 }
        }
    }
    private static let elementSymbols = "H He Li Be B C N O F Ne Na Mg Al Si P S Cl Ar K Ca Sc Ti V Cr Mn Fe Co Ni Cu Zn Ga Ge As Se Br Kr Rb Sr Y Zr Nb Mo Tc Ru Rh Pd Ag Cd In Sn Sb Te I Xe Cs Ba La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho Er Tm Yb Lu Hf Ta W Re Os Ir Pt Au Hg Tl Pb Bi Po At Rn Fr Ra Ac Th Pa U Np Pu Am Cm Bk Cf Es Fm Md No Lr Rf Db Sg Bh Hs Mt Ds Rg Cn Nh Fl Mc Lv Ts Og"
        .split(separator: " ").map(String.init)
    private static let termExpression: NSRegularExpression = {
        let elements = elementSymbols.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }.joined(separator: "|")
        let indices = "[0-9₀-₉⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻]*"
        let units = "pH|pKa|pKb|mol|mmol|μmol|µmol|kg|mg|km|cm|mm|nm|ms|mL|Hz|kHz|MHz|GHz|Pa|kPa|J|kJ|MJ|eV|keV|MeV|dB|W|kW|mW|sin|cos|tan|log|ln|lim|sqrt"
        // No/He/In/As/At/Am and OK are words as well as possible symbols.
        // A numeric suffix or a larger formula disambiguates those elements.
        let chemical = "(?!(?:OK|No|He|In|As|At|Am)(?=$|[^\\p{L}\\p{N}_]))(?:(?:" + elements + ")" + indices + ")+"
        let acronym = "(?!(?:OK|HI|NO|GO|IT|IS)(?=$|[^\\p{L}\\p{N}_]))[A-Z][A-Z0-9]{1,11}"
        let symbols = "[πΔμµΩΩλ]" + indices + "[A-Za-z]{0,2}" + indices
            + "|[A-Za-z]{1,2}[0-9₀-₉⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻]+|[A-Za-zα-ωΑ-Ω]" + indices
            + "|d[A-Za-z](?=\\s*/)|(?<=/)d[A-Za-z]"
        return try! NSRegularExpression(pattern: "(?<![\\p{L}_])(?:" + acronym + "|" + chemical + "|" + units + "|" + symbols + ")(?=$|[^\\p{L}\\p{N}_])")
    }()
    static func isTerminologyOnly(_ text: String) -> Bool {
        LatinAcceptanceInstrumentation.record(.terms)
        let tokens = words(text)
        if tokens.count >= 2, score(tokens, target: .english) >= 2 { return false }
        if tokens.count >= 3, tokens.contains(where: englishActions.contains) { return false }
        let stripped = termExpression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        return text.unicodeScalars.contains(where: { isLetter($0) || (0x30...0x39).contains($0.value) })
            && !stripped.unicodeScalars.contains(where: { isLetter($0) || CharacterSet.nonBaseCharacters.contains($0) })
    }
}

enum LatinTargetLengthGuard {
    static let minimumSourceLetters = 24
    static let absoluteLetterAllowance = 12

    /// Four local UN meetings, 85 fully extracted aligned turns. Values follow
    /// the reference letter-ratio p99.5 rounded UP to 0.01, except the retained
    /// historical fr/ru 1.20: its empirical ceiling is 1.19 and the extra 0.01
    /// has no recovered derivation (Scripts/target_eval/PROVENANCE.md). This
    /// review changes no ratio. These are in-sample calibration parameters,
    /// not independent accuracy validation or a subtitle guarantee.
    static func maximumRatio(target: LatinTargetAcceptance.Target, sourceLanguage: String?) -> Double {
        LatinAcceptanceInstrumentation.record(.maximumRatio)
        let source = sourceLanguage?.lowercased().split(separator: "-").first.map(String.init) ?? "en"
        let ratios: [LatinTargetAcceptance.Target: [String: Double]] = [
            .english: ["es": 1.10, "fr": 1.13, "zh": 4.57, "ar": 1.89, "ru": 1.08],
            .spanish: ["en": 1.26, "fr": 1.23, "zh": 5.44, "ar": 2.25, "ru": 1.24],
            .french: ["en": 1.26, "es": 1.10, "zh": 4.96, "ar": 1.84, "ru": 1.20]
        ]
        return ratios[target]?[source] ?? (["zh", "ja", "ko", "yue"].contains(source) ? 6 : 2)
    }
    static func letterCount(_ text: String) -> Int {
        LatinAcceptanceInstrumentation.record(.letters)
        return text.precomposedStringWithCanonicalMapping.unicodeScalars.filter(LatinTargetAcceptance.isLetter).count
    }
    static func maximumOutputLetters(source: String, target: LatinTargetAcceptance.Target,
                                     sourceLanguage: String? = nil, maximumRatio: Double? = nil) -> Double {
        LatinAcceptanceInstrumentation.record(.maximumOutputLetters)
        let ratio = maximumRatio ?? self.maximumRatio(target: target, sourceLanguage: sourceLanguage)
        let count = letterCount(source)
        return Double(max(count, minimumSourceLetters)) * ratio + Double(absoluteLetterAllowance)
    }
    static func isPlausible(candidate: String, source: String, target: LatinTargetAcceptance.Target,
                            sourceLanguage: String? = nil, maximumRatio: Double? = nil) -> Bool {
        LatinAcceptanceInstrumentation.record(.length)
        let ratio = maximumRatio ?? self.maximumRatio(target: target, sourceLanguage: sourceLanguage)
        guard ratio.isFinite && ratio > 0 else { return false }
        let limit = maximumOutputLetters(source: source, target: target, sourceLanguage: sourceLanguage,
                                         maximumRatio: maximumRatio)
        return limit.isFinite && limit > 0 && Double(letterCount(candidate)) <= limit
    }
}

enum LatinStableTranslationPrefix {
    private static let abbreviation = try! NSRegularExpression(pattern:
        #"(?i)(?<!\p{L})(?:e\.g\.|i\.e\.|p\.\s*ej\.|p\.\s*ex\.|etc\.|vs\.|cf\.|mr\.|mrs\.|ms\.|dr\.|prof\.|sr\.|sra\.|srta\.|dra\.|ud\.|uds\.|pág\.|p\.|ec\.|eq\.|éq\.|pr\.|aprox\.|approx\.|mme\.|mlle\.|m\.|fig\.|vol\.|no\.|núm\.|nº\.|(?:[a-z]\.){2,})(?!\p{L})"#)

    /// Match the existing repair contract: the final sentence is still the
    /// repairable tail, even when it has a terminal mark. Keep earlier sentences.
    static func prefix(_ text: String) -> String {
        LatinAcceptanceInstrumentation.record(.prefix)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = text as NSString
        let protected = abbreviation.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        let characters = Array(text)
        var offset = 0, ends: [Int] = []
        for index in characters.indices {
            let c = characters[index], utf16Count = String(c).utf16.count
            defer { offset += utf16Count }
            guard ".!?。！？".contains(c) else { continue }
            if c == "." {
                if protected.contains(where: { NSLocationInRange(offset, $0) }) { continue }
                if index + 1 < characters.count, characters[index + 1].isNumber { continue }
                if index > 0, characters[index - 1].isNumber, index + 1 < characters.count {
                    if "ºª".contains(characters[index + 1]) { continue }
                    if index + 2 < characters.count, characters[index + 1] == "e", characters[index + 2] == "r",
                       index + 3 == characters.count || !characters[index + 3].isLetter { continue }
                }
                if index + 1 < characters.count, characters[index + 1] == "." { continue }
                if index > 0, index + 1 < characters.count,
                   characters[index - 1].isLetter, characters[index + 1].isLetter { continue }
            }
            if index + 1 < characters.count, "!?".contains(characters[index + 1]) { continue }
            var end = index + 1
            while end < characters.count, "\"'”’»)]}".contains(characters[end]) { end += 1 }
            ends.append(end)
        }
        if ends.last == characters.count { ends.removeLast() }
        guard let end = ends.last else { return "" }
        return String(characters[..<end])
    }
}

enum LatinNumericParser {
    private static func expression(group: String, decimal: String) -> NSRegularExpression {
        // A whole numeric token or nothing; do not salvage fragments of an
        // invalid grouping. Arabic digits only, as required by the Latin gate.
        let body = "(?:[0-9]{1,3}(?:[" + group + "][0-9]{3})+|[0-9]+)(?:[" + decimal + "][0-9]+)?|[" + decimal + "][0-9]+"
        return try! NSRegularExpression(pattern: "(?<![0-9.,])[-+−]?(?:" + body + ")(?:[eE][-+−]?[0-9]+)?(?![0-9]|[.,][0-9]|[eE](?:$|[-+−]|[0-9]))")
    }
    private static let english = expression(group: ", \u{00A0}\u{202F}", decimal: ".")
    private static let spanish = expression(group: ". \u{00A0}\u{202F}", decimal: ",.")
    private static let french = expression(group: " \u{00A0}\u{202F}", decimal: ",.")

    /// Exact signed coefficient/exponent strings, not floating point: nearby
    /// large integers and re-expressions of the same number stay distinguishable.
    static func numbers(in text: String, language: String) -> [String] {
        LatinAcceptanceInstrumentation.record(.numbers)
        let code = language.lowercased().split(separator: "-").first.map(String.init) ?? language
        let expression = code == "es" ? spanish : (["fr", "ru"].contains(code) ? french : english)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            var token = String(text[range]).replacingOccurrences(of: "−", with: "-")
                .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
                .replacingOccurrences(of: "\u{202F}", with: "").lowercased()
            if code == "es" {
                let mantissa = token.split(separator: "e", omittingEmptySubsequences: false).first.map(String.init) ?? token
                let grouped = mantissa.range(of: #"^[+-]?[1-9][0-9]{0,2}(?:\.[0-9]{3})+(?:,[0-9]+)?$"#, options: .regularExpression) != nil
                if grouped { token = token.replacingOccurrences(of: ".", with: "") }
                token = token.replacingOccurrences(of: ",", with: ".")
            } else if ["fr", "ru"].contains(code) { token = token.replacingOccurrences(of: ",", with: ".") }
            else { token = token.replacingOccurrences(of: ",", with: "") }
            return identity(token)
        }
    }
    private static func identity(_ token: String) -> String? {
        let pieces = token.split(separator: "e", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let exponent = pieces.count == 2 ? Int(pieces[1]) : 0 else { return nil }
        let sign = pieces[0].hasPrefix("-") ? "-" : ""
        let mantissa = pieces[0].hasPrefix("+") || pieces[0].hasPrefix("-") ? pieces[0].dropFirst() : pieces[0]
        let decimal = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard decimal.count <= 2 else { return nil }
        let digits = String(mantissa.filter { $0 != "." }.drop(while: { $0 == "0" }))
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if digits.isEmpty { return "0e0" }
        let zeros = digits.reversed().prefix(while: { $0 == "0" }).count
        let (scale, overflow1) = exponent.subtractingReportingOverflow(decimal.count == 2 ? decimal[1].count : 0)
        let (power, overflow2) = scale.addingReportingOverflow(zeros)
        guard !overflow1 && !overflow2 else { return nil }
        return sign + String(digits.dropLast(zeros)) + "e" + String(power)
    }
}

/// Debug-only, locked instrumentation. Release policies have no observable
/// side effects. Counting every policy family catches accidental zh-Hans calls.
enum LatinAcceptanceInstrumentation {
    enum Function: String, CaseIterable {
        case acceptance, sharedStructure, language, candidates, languageText, terms
        case letters, length, maximumRatio, maximumOutputLetters, prefix, numbers
    }
    #if DEBUG
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var counts: [String: Int] = [:]
        func record(_ key: String) { lock.lock(); defer { lock.unlock() }; counts[key, default: 0] += 1 }
        func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
    }
    private static let storage = Storage()
    static var callCounts: [String: Int] { storage.snapshot() }
    #endif
    static func record(_ function: Function) {
        #if DEBUG
        storage.record(function.rawValue)
        #endif
    }
}
