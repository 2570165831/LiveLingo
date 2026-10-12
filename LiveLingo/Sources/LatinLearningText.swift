import Foundation

/// Locale-aware retrieval and Arabic-number provenance for the unreleased targets.
/// Overlap and matching values never prove a subject or a scientific claim.
enum LatinLearningText {
    private static let spanishStop = Set("el la los las un una unos unas de del al en y o a por para con sin que qué es son está están se su sus este esta estos estas como más muy no ni lo le les nos nuestro nuestra sus también porque cuando donde todos todas todo".split(separator: " ").map(String.init))
    private static let frenchStop = Set("le la les un une des du de au aux en et ou où à pour par avec sans qui que est sont ce cet cette ces se son sa ses leur leurs nous vous ils elles ne pas plus très tout tous toutes notre nos votre vos dans sur dont aussi".split(separator: " ").map(String.init))
    private static let words = try! NSRegularExpression(pattern: #"[\p{Latin}\p{M}]{2,}|[\p{Han}]{2}"#)
    static func terms(_ text: String, target: CaptionTranslationTarget) -> Set<String> {
        let text = text.precomposedStringWithCanonicalMapping.lowercased()
        let tokens = words.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
        return Set(tokens).subtracting(target == .spanish ? spanishStop : frenchStop)
    }
    static func referencePattern(language: String, atEnd: Bool = false) -> String {
        let alternatives: String
        switch language {
        case "es": alternatives = "su|sus"
        case "fr": alternatives = "son|sa|ses|leur|leurs"
        default: alternatives = "its|their"
        }
        return #"(?i)\b(?:"# + alternatives + #")\b"# + (atEnd ? #"\s*$"# : "")
    }
    private static let attributes: [String: Set<String>] = [
        "es": Set("temperatura presión presion volumen masa velocidad densidad tiempo frecuencia energía longitud ángulo concentración potencia corriente voltaje puntuación".split(separator: " ").map(String.init)),
        "fr": Set("température pression volume masse vitesse densité temps fréquence énergie longueur angle concentration puissance courant tension score".split(separator: " ").map(String.init)),
        "en": Set("temperature pressure volume mass speed velocity density time frequency energy length angle concentration power current voltage score".split(separator: " ").map(String.init))
    ]
    private static let designators: [String: Set<String>] = [
        "es": Set("capítulo sección figura tabla ecuación paso número versión".split(separator: " ").map(String.init)),
        "fr": Set("chapitre section figure tableau équation étape numéro version".split(separator: " ").map(String.init)),
        "en": Set("chapter section figure table equation step number version".split(separator: " ").map(String.init))
    ]
    private static let countNouns: [String: Set<String>] = [
        "es": Set("ejemplo ejemplos caso casos elemento elementos punto puntos pregunta preguntas".split(separator: " ").map(String.init)),
        "fr": Set("exemple exemples cas élément éléments point points question questions".split(separator: " ").map(String.init)),
        "en": Set("example examples case cases element elements point points question questions".split(separator: " ").map(String.init))
    ]
    private static let unitAliases: [String: [(String, String)]] = [
        "es": [("grados celsius", "C"), ("grado celsius", "C"), ("kilopascales", "kPa"), ("kilopascal", "kPa"),
            ("mililitros", "mL"), ("mililitro", "mL"), ("litros", "L"), ("litro", "L"),
            ("minutos", "min"), ("minuto", "min"), ("segundos", "s"), ("segundo", "s"),
            ("kilogramos", "kg"), ("kilogramo", "kg"), ("gramos", "g"), ("gramo", "g")],
        "fr": [("degrés celsius", "C"), ("degré celsius", "C"), ("kilopascals", "kPa"), ("kilopascal", "kPa"),
            ("millilitres", "mL"), ("millilitre", "mL"), ("litres", "L"), ("litre", "L"),
            ("minutes", "min"), ("minute", "min"), ("secondes", "s"), ("seconde", "s"),
            ("kilogrammes", "kg"), ("kilogramme", "kg"), ("grammes", "g"), ("gramme", "g")]
    ]
    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter }.map(String.init)
    }
    // Adapt only note-provenance input. Keep the shared alias table, caption
    // acceptance and every default/English note path on their frozen rules.
    private static let unitWords: [String: [String: String]] = {
        var result = unitAliases.mapValues { Dictionary(uniqueKeysWithValues: $0) }
        let extra: [String: [(String, String)]] = [
            "es": [("metro", "m"), ("metros", "m"), ("centímetro", "cm"), ("centímetros", "cm"),
                ("milímetro", "mm"), ("milímetros", "mm"), ("kilómetro", "km"), ("kilómetros", "km"),
                ("hora", "h"), ("horas", "h"), ("milisegundo", "ms"), ("milisegundos", "ms"),
                ("pascal", "Pa"), ("pascales", "Pa"), ("megapascal", "MPa"), ("megapascales", "MPa"),
                ("mol", "mol"), ("moles", "mol"), ("voltio", "V"), ("voltios", "V"),
                ("amperio", "A"), ("amperios", "A"), ("vatio", "W"), ("vatios", "W"),
                ("julio", "J"), ("julios", "J"), ("newton", "N"), ("newtons", "N"),
                ("por", "per"), ("al cuadrado", "squared"), ("cuadrado", "squared"), ("cuadrados", "squared"),
                ("cuadrada", "squared"), ("cuadradas", "squared"), ("al cubo", "cubed"),
                ("cúbico", "cubed"), ("cúbicos", "cubed"), ("cúbica", "cubed"), ("cúbicas", "cubed")],
            "fr": [("mètre", "m"), ("mètres", "m"), ("centimètre", "cm"), ("centimètres", "cm"),
                ("millimètre", "mm"), ("millimètres", "mm"), ("kilomètre", "km"), ("kilomètres", "km"),
                ("heure", "h"), ("heures", "h"), ("milliseconde", "ms"), ("millisecondes", "ms"),
                ("pascal", "Pa"), ("pascals", "Pa"), ("mégapascal", "MPa"), ("mégapascals", "MPa"),
                ("mole", "mol"), ("moles", "mol"), ("ampère", "A"), ("ampères", "A"),
                ("volt", "V"), ("volts", "V"), ("watt", "W"), ("watts", "W"),
                ("joule", "J"), ("joules", "J"), ("newton", "N"), ("newtons", "N"),
                ("par", "per"), ("carré", "squared"), ("carrés", "squared"),
                ("carrée", "squared"), ("carrées", "squared"), ("cube", "cubed"), ("cubes", "cubed"),
                ("cubique", "cubed"), ("cubiques", "cubed")]
        ]
        for (language, entries) in extra {
            for (word, canonical) in entries { result[language, default: [:]][word] = canonical }
        }
        // C is not the Celsius symbol in the shared table; use its full symbol.
        for language in ["es", "fr"] {
            for (word, family) in unitAliases[language, default: []] where family == "C" {
                result[language]?[word] = "°C"
            }
        }
        return result
    }()
    private static let unitWordExpressions = unitWords.mapValues { words in
        let alternatives = words.keys.sorted { $0.count > $1.count }.map {
            NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"[\t \u00A0\u202F]+"#)
        }.joined(separator: "|")
        return try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{M}])(?:"# + alternatives + #")(?![\p{L}\p{M}])|\s*[/·⋅]\s*"#)
    }

    private static func unit(after: String, language: String) -> (token: String, family: String)? {
        // Character offsets bind the normalized unit back to the exact source
        // spelling. Neither the note body nor a source quote is rewritten.
        var canonical = "", ends: [String.Index] = []
        func append(_ range: Range<String.Index>, replacement: String? = nil) {
            if let replacement {
                canonical += replacement
                ends += Array(repeating: range.upperBound, count: replacement.count)
            } else {
                for index in after[range].indices {
                    let character = after[index]
                    canonical.append(character.isWhitespace ? " " : character)
                    ends.append(after.index(after: index))
                }
            }
        }
        var cursor = after.startIndex
        if let expression = unitWordExpressions[language] {
            for match in expression.matches(in: after, range: NSRange(after.startIndex..., in: after)) {
                guard let range = Range(match.range, in: after) else { continue }
                append(cursor..<range.lowerBound)
                let raw = String(after[range]).lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let replacement = unitWords[language]?[raw] ?? raw.filter { !$0.isWhitespace }
                append(range, replacement: replacement)
                cursor = range.upperBound
            }
        }
        append(cursor..<after.endIndex)
        guard let unit = LearningNumericProvenance.provenanceUnit(after: canonical),
              unit.token.count > 0, unit.token.count <= ends.count else { return nil }
        return (String(after[..<ends[unit.token.count - 1]]), unit.family)
    }

    private static let minusMarks = Set("-−－﹣")
    private static let signOpeners = Set("([{=：:,;~≈<>≤≥\"'“‘")
    private static let signWords = ["es": #"menos|negativo|negativa"#, "fr": #"moins|négatif|négative"#, "en": #"minus|negative"#]
    private static func negativeSign(before: String, language: String) -> String {
        if let mark = before.last, minusMarks.contains(mark) {
            guard let prior = before.dropLast().last else { return String(mark) }
            return prior.isWhitespace || signOpeners.contains(prior) ? String(mark) : ""
        }
        let pattern = #"(?i)(?<![\p{L}\p{N}_])(?:"# + (signWords[language] ?? signWords["en"]!) + #")[ \t]+$"#
        guard let range = before.range(of: pattern, options: .regularExpression) else { return "" }
        let head = String(before[..<range.lowerBound])
        if head.range(of: #"(?i)(?:más\s+o|plus\s+ou|plus\s+or)\s+$"#, options: .regularExpression) != nil { return "" }
        let token = head.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        if token.contains(where: \.isNumber) || unit(after: token, language: language)?.token == token { return "" }
        return String(before[range])
    }

    private static let superscripts = Dictionary(uniqueKeysWithValues: zip(Array("⁰¹²³⁴⁵⁶⁷⁸⁹⁻⁺"), Array("0123456789-+")))
    private static let scientificTail = try! NSRegularExpression(pattern:
        #"^(?:[ \t]*[×xX*·⋅][ \t]*10[ \t]*(?:\^[ \t]*([+\-−]?[0-9]+)|([⁻⁺]?[⁰¹²³⁴⁵⁶⁷⁸⁹]+))|[ \t]*\^[ \t]*([+\-−]?[0-9]+)|([⁻⁺]?[⁰¹²³⁴⁵⁶⁷⁸⁹]+))(?![0-9A-Za-z_])"#)
    private static func scientificValue(_ literal: LatinNumericParser.Literal, tail: String) -> (value: String, length: Int)? {
        guard let match = scientificTail.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) else { return nil }
        let ns = tail as NSString
        let group = (1...4).first { match.range(at: $0).location != NSNotFound }!
        let rawPower = ns.substring(with: match.range(at: group)).map { superscripts[$0] ?? ($0 == "−" ? "-" : $0) }
        let rawValue = String(literal.text.drop { "+-−".contains($0) }) + ns.substring(with: match.range)
        guard let exponent = Int(String(rawPower)), (-30...30).contains(exponent) else {
            return (rawValue.filter { !$0.isWhitespace }, match.range.length)
        }
        let magnitude = literal.value.hasPrefix("-") ? String(literal.value.dropFirst()) : literal.value
        let parts = magnitude.split(separator: "e")
        let value: String
        if group <= 2, parts.count == 2, let oldPower = Int(parts[1]) {
            let (power, overflow) = oldPower.addingReportingOverflow(exponent)
            guard !overflow else { return (rawValue.filter { !$0.isWhitespace }, match.range.length) }
            value = parts[0] == "0" ? "0e0" : parts[0] + "e" + String(power)
        } else if magnitude == "1e1" { value = "1e" + String(exponent) }
        else { value = rawValue.filter { !$0.isWhitespace } }
        return (value, match.range.length)
    }
    static func mentions(in text: String, language: String, excluding: [NSRange]) -> [LearningNumericProvenance.Mention] {
        let ns = text as NSString
        var coveredEnd = 0
        return LatinNumericParser.literals(in: text, language: language).compactMap { literal in
            guard literal.range.location >= coveredEnd,
                  !excluding.contains(where: { NSIntersectionRange($0, literal.range).length > 0 }) else { return nil }
            let start = literal.range.location
            var end = NSMaxRange(literal.range)
            let before = ns.substring(with: NSRange(location: max(0, start - 40), length: min(start, 40)))
            if before.last?.isUppercase == true || (before.hasSuffix("-") && before.dropLast().last?.isUppercase == true)
                || tokens(before).last.map({ designators[language, default: []].contains($0) }) == true {
                return .init(value: literal.value, unit: nil, role: .designator, excerpt: "编号" + literal.text)
            }
            var value = literal.value.hasPrefix("-") ? String(literal.value.dropFirst()) : literal.value
            if let scientific = scientificValue(literal, tail: ns.substring(from: end)) {
                value = scientific.value; end += scientific.length
            }
            var unitStart = end
            while unitStart < ns.length, let scalar = UnicodeScalar(ns.character(at: unitStart)), CharacterSet.whitespacesAndNewlines.contains(scalar) { unitStart += 1 }
            let after = ns.substring(from: unitStart)
            let prior = tokens(before), following = tokens(after)
            let measure = unit(after: after, language: language)
            coveredEnd = measure.map { unitStart + $0.token.utf16.count } ?? end
            let hasAttribute = prior.contains { attributes[language, default: []].contains($0) }
            let isCount = measure == nil && !hasAttribute
                && following.first.map({ countNouns[language, default: []].contains($0) }) == true
            let role: LearningNumericProvenance.Mention.Role = measure != nil || hasAttribute ? .measurement : (isCount ? .count : .ambiguous)
            let writtenSign = literal.text.first.map { "+-−".contains($0) } == true
            var signText = negativeSign(before: before + (writtenSign ? String(literal.text.prefix(1)) : ""), language: language)
            if measure?.family == "C" {
                let rest = after.dropFirst(measure!.token.count)
                let below = language == "es" ? #"^\s+bajo\s+cero\b"# : #"^\s+(?:au-dessous\s+de|en\s+dessous\s+de|sous)\s+zéro\b"#
                if rest.range(of: below, options: [.regularExpression, .caseInsensitive]) != nil { signText = "-" }
            }
            let raw = ns.substring(with: NSRange(location: start, length: end - start))
            let signed = (writtenSign ? "" : signText) + raw
            let excerpt = measure.map { signed + $0.token }
                ?? (hasAttribute ? before.trimmingCharacters(in: .whitespaces) + raw : signed)
            return .init(value: value, unit: measure?.family, role: role, excerpt: excerpt,
                         sign: signText.isEmpty || value == "0e0" ? "" : "-")
        }
    }
}
