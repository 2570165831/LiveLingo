import Foundation

/// Decisions about a source belong to the generation target. The distinction
/// between an implicit English segment and a raw "en" gate input is frozen.
struct CaptionSourcePolicy: Equatable, Sendable {
    let keepsSourceAsCaption: Bool
    let usesEnglishTranslationPipeline: Bool
    let hasAutomaticNoteGateRisk: Bool
    let targetEvidenceLanguage: String

    var learningEvidenceLanguages: [String] {
        usesEnglishTranslationPipeline ? ["en", targetEvidenceLanguage] : [targetEvidenceLanguage]
    }
    var includesReviewWarning: Bool { usesEnglishTranslationPipeline }
    var usesIndexedPendingEvidence: Bool { !usesEnglishTranslationPipeline }
}

extension CaptionTranslationTarget {
    func sourcePolicy(for sourceLanguage: String?) -> CaptionSourcePolicy {
        let keepsSource = keepsSourceAsCaption(language: sourceLanguage)
        return .init(keepsSourceAsCaption: keepsSource,
            usesEnglishTranslationPipeline: (sourceLanguage == nil || (isSpanishOrFrench && sourceLanguage == "en")) && !keepsSource,
            hasAutomaticNoteGateRisk: (sourceLanguage == nil || sourceLanguage == "en") && !keepsSource,
            targetEvidenceLanguage: rawValue == "zh-Hans" ? "zh" : rawValue)
    }
}

enum SourceLanguagePolicy {
    // Mirrored by qwen_asr_service.py; the Python test reads these declarations.
    static let nonLatinMinProbability = 0.90
    static let nonLatinMaxEnglishProbability = 0.05
    static let latinMinProbability = 0.55
    static let latinMaxEnglishProbability = 0.01
    static let triggerPolicy = "few"
    static let fewMeanThreshold = 0.90
    static let fewMinThreshold = 0.05
    static let latinConsensus = true
    static let nonLatinConsensus = false
    // Frozen trigger-eval-v1 classification, including explicit script subtags.
    // This is separate from the supported decoder table (e.g. fil is non-Latin
    // in the frozen evaluator even though its usual writing system is Latin).
    static let latinLanguages: Set<String> = [
        "af", "bs", "ca", "cs", "cy", "da", "de", "en", "es", "et", "eu",
        "fi", "fr", "ga", "gl", "hr", "hu", "id", "is", "it", "la", "lt",
        "lv", "ms", "mt", "nb", "nl", "nn", "no", "pl", "pt", "ro", "sk",
        "sl", "sq", "sv", "sw", "tr", "vi", "zu",
    ]
    static let hanMinimum = 2
    static let kanaMinimum = 1
    static let hangulMinimum = 2
    static let eastAsianMinimumShare = 0.50
    static let otherScriptMinimumShare = 0.60
    static func languageAndScript(_ code: String) -> (code: String, latin: Bool) {
        let parts = code.lowercased().split(separator: "-").map(String.init)
        let script = parts.dropFirst().first { $0.count == 4 && $0.allSatisfy(\.isLetter) }
        return (parts.first ?? "", script.map { $0 == "latn" } ?? latinLanguages.contains(parts.first ?? ""))
    }

    struct ProbePlan: Equatable, Sendable {
        let baseEligible: Bool
        let followup: Bool
        let prior: String?
        var selected: Bool { baseEligible || followup }
    }

    struct Decision: Equatable, Codable, Sendable {
        let selected: Bool
        let baseEligible: Bool
        let followup: Bool
        let qualifiedLanguage: String?
        let language: String?
        let reason: String
    }

    /// One causal stream per configured session. Repairs cannot confirm themselves;
    /// skips, failed probes and missing ordinals clear the previous candidate.
    struct TriggerState: Equatable, Codable, Sendable {
        private var previousIndex: Int?
        private var previousLanguage: String?

        func plan(index: Int, parakeetAccepted: Bool, mean: Double?, minimum: Double?) -> ProbePlan {
            let prior = previousIndex.map { $0 + 1 == index } == true ? previousLanguage : nil
            let lowConfidence = (mean.map { $0.isFinite && $0 < fewMeanThreshold } ?? false)
                || (minimum.map { $0.isFinite && $0 < fewMinThreshold } ?? false)
            return ProbePlan(baseEligible: !parakeetAccepted || lowConfidence, followup: prior != nil, prior: prior)
        }

        mutating func advance(index: Int, decision: Decision?) {
            previousIndex = index
            previousLanguage = decision?.qualifiedLanguage
        }
    }

    static func decide(_ plan: ProbePlan, language: String?, probability: Double?,
                       englishProbability: Double?, probeFailed: Bool = false) -> Decision {
        var qualified: String?, switched: String?
        var reason = "not_selected"
        if plan.selected {
            if probeFailed { reason = "probe_failed" }
            else if let language {
                let candidate = languageAndScript(language)
                if candidate.code == "en" { reason = "probe_english" }
                else if probability == nil { reason = "probe_label_probability_none" }
                else if englishProbability == nil { reason = "probe_english_probability_none" }
                else if let probability, let englishProbability {
                    if !probability.isFinite || !englishProbability.isFinite
                        || !(0...1).contains(probability) || !(0...1).contains(englishProbability) {
                        reason = "probe_failed"
                    } else if probability < (candidate.latin ? latinMinProbability : nonLatinMinProbability) {
                        reason = "below_language_threshold"
                    } else if englishProbability > (candidate.latin ? latinMaxEnglishProbability : nonLatinMaxEnglishProbability) {
                        reason = "above_english_probability_limit"
                    } else {
                        qualified = candidate.code
                        if (candidate.latin ? latinConsensus : nonLatinConsensus) && plan.prior != candidate.code {
                            reason = "pending_consensus"
                        } else { switched = candidate.code; reason = "confirmed" }
                    }
                }
            } else { reason = "probe_language_none" }
        }
        return Decision(selected: plan.selected, baseEligible: plan.baseEligible, followup: plan.followup,
                        qualifiedLanguage: qualified, language: switched, reason: reason)
    }

    static func accepts(_ result: ASRTranscription, audioDuration: TimeInterval,
                        requestedMode: ASRLanguageMode = .auto) -> Bool {
        guard requestedMode == .auto, result.languageMode == requestedMode,
              result.decode == .detected, !result.truncated, result.policy == 1,
              let language = SpokenLanguage.find(result.language), language.code != "en",
              language.qwenLabel == result.detectedLabel,
              let probability = result.languageProbability, probability.isFinite,
              let englishProbability = result.englishProbability, englishProbability.isFinite,
              (0...1).contains(probability), (0...1).contains(englishProbability) else { return false }
        let latin = languageAndScript(language.code).latin
        guard probability >= (latin ? latinMinProbability : nonLatinMinProbability),
              englishProbability <= (latin ? latinMaxEnglishProbability : nonLatinMaxEnglishProbability),
              scriptAccepts(result.text, language: language) else { return false }
        switch SourceQualityGate.fallbackReason(for: result.text, language: language, audioDuration: audioDuration) {
        case nil, .implausiblyShort: return true
        default: return false
        }
    }

    private static func scriptAccepts(_ text: String, language: SpokenLanguage) -> Bool {
        let counts = ScriptCounts(text)
        switch language.writingSystem {
        case .han:
            return counts.han >= hanMinimum && share(counts.han, counts.han + counts.latin) >= eastAsianMinimumShare
        case .japanese:
            return counts.kana >= kanaMinimum
                && share(counts.kana + counts.han, counts.kana + counts.han + counts.latin) >= eastAsianMinimumShare
        case .hangul:
            return counts.hangul >= hangulMinimum
                && share(counts.hangul, counts.hangul + counts.latin) >= eastAsianMinimumShare
        case .cyrillic, .arabic, .thai, .devanagari, .greek:
            return share(counts.count(language.writingSystem), counts.letters) >= otherScriptMinimumShare
        case .latin:
            // NL metadata is diagnostic in the frozen evaluator, never another
            // switch gate. The causal two-segment confirmation supplies evidence.
            return true
        }
    }

    private static func share(_ numerator: Int, _ denominator: Int) -> Double {
        denominator > 0 ? Double(numerator) / Double(denominator) : 0
    }

    private struct ScriptCounts {
        var han = 0, kana = 0, hangul = 0, latin = 0, letters = 0
        var other: [SpokenLanguage.WritingSystem: Int] = [:]

        init(_ text: String) {
            for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
                letters += 1
                switch scalar.value {
                case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                     0x20000...0x2EE5F, 0x30000...0x323AF: han += 1
                case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,
                     0x1B000...0x1B16F: kana += 1
                case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F,
                     0xAC00...0xD7AF, 0xD7B0...0xD7FF, 0xFFA0...0xFFDC: hangul += 1
                case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F,
                     0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF,
                     0xAB30...0xAB6F, 0xFF21...0xFF3A, 0xFF41...0xFF5A,
                     0x10780...0x107BF: latin += 1
                case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
                    other[.cyrillic, default: 0] += 1
                case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF,
                     0xFB50...0xFDFF, 0xFE70...0xFEFF, 0x10EC0...0x10EFF, 0x1EE00...0x1EEFF:
                    other[.arabic, default: 0] += 1
                case 0x0E00...0x0E7F: other[.thai, default: 0] += 1
                case 0x0900...0x097F, 0xA8E0...0xA8FF: other[.devanagari, default: 0] += 1
                case 0x0370...0x03FF, 0x1F00...0x1FFF: other[.greek, default: 0] += 1
                default: break
                }
            }
        }

        func count(_ script: SpokenLanguage.WritingSystem) -> Int { other[script, default: 0] }
    }
}

enum SourceQualityGate {
    static let characterFloor = 60
    static let charactersPerSecond = 12.0
    static let loopMinimumCharacters = 12
    static let loopMinimumShare = 0.60
    static let loopMaximumUnit = 4

    static func fallbackReason(for text: String, language: SpokenLanguage,
                               audioDuration: TimeInterval) -> ASRFallbackReason? {
        guard audioDuration.isFinite, audioDuration >= 0 else { return .invalidText }
        guard [.han, .japanese, .thai].contains(language.writingSystem) else {
            return ASRQualityGate.fallbackReason(for: text, audioDuration: audioDuration)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .emptyTranscript }
        guard !trimmed.contains("\u{FFFD}") else { return .invalidText }
        let characters = Array(trimmed.filter { $0.isLetter || $0.isNumber })
        guard !characters.isEmpty else { return .invalidText }
        guard Double(characters.count) <= max(Double(characterFloor), charactersPerSecond * audioDuration) else {
            return .runawayText
        }
        if characters.count >= loopMinimumCharacters {
            for width in 1...min(loopMaximumUnit, characters.count / 2) {
                var occurrences: [String: (end: Int, count: Int)] = [:]
                for start in 0...(characters.count - width) {
                    let unit = String(characters[start..<(start + width)])
                    var previous = occurrences[unit] ?? (end: 0, count: 0)
                    guard start >= previous.end else { continue } // overlapping matches count only once
                    previous = (end: start + width, count: previous.count + 1)
                    occurrences[unit] = previous
                    if previous.count >= 2,
                       Double(previous.count * width) / Double(characters.count) >= loopMinimumShare {
                        return .repeatedLoop
                    }
                }
            }
        }
        return nil
    }
}
