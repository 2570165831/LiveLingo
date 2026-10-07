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
    private static func unit(after: String, language: String) -> (token: String, family: String)? {
        let text = after.lowercased()
        for (alias, family) in unitAliases[language, default: []] where text.hasPrefix(alias) {
            let end = text.index(text.startIndex, offsetBy: alias.count)
            if end == text.endIndex || !text[end].isLetter { return (String(after.prefix(alias.count)), family) }
        }
        return LearningNumericProvenance.unitToken(after: after)
    }
    static func mentions(in text: String, language: String, excluding: [NSRange]) -> [LearningNumericProvenance.Mention] {
        let ns = text as NSString
        return LatinNumericParser.literals(in: text, language: language).compactMap { literal in
            guard !excluding.contains(where: { NSIntersectionRange($0, literal.range).length > 0 }) else { return nil }
            let start = literal.range.location, end = NSMaxRange(literal.range)
            let before = ns.substring(with: NSRange(location: max(0, start - 40), length: min(start, 40)))
            let after = ns.substring(from: end).trimmingCharacters(in: .whitespacesAndNewlines)
            let prior = tokens(before), following = tokens(after)
            if prior.last.map({ designators[language, default: []].contains($0) }) == true {
                return .init(value: literal.value, unit: nil, role: .designator, excerpt: "编号" + literal.text)
            }
            let measure = unit(after: after, language: language)
            let hasAttribute = prior.contains { attributes[language, default: []].contains($0) }
            let isCount = measure == nil && !hasAttribute
                && following.first.map({ countNouns[language, default: []].contains($0) }) == true
            let role: LearningNumericProvenance.Mention.Role = measure != nil || hasAttribute ? .measurement : (isCount ? .count : .ambiguous)
            let excerpt = measure.map { literal.text + $0.token }
                ?? (hasAttribute ? before.trimmingCharacters(in: .whitespaces) + literal.text : literal.text)
            return .init(value: literal.value, unit: measure?.family, role: role, excerpt: excerpt)
        }
    }
}
