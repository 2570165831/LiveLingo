import Foundation
import NaturalLanguage

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
    static let latinMinProbability = 0.97
    static let latinMaxEnglishProbability = 0.01
    static let hanMinimum = 2
    static let kanaMinimum = 1
    static let hangulMinimum = 2
    static let eastAsianMinimumShare = 0.50
    static let otherScriptMinimumShare = 0.60
    static let latinMinimumWords = 4
    static let latinRecognitionMinimumConfidence = 0.80

    struct Recognition: Sendable {
        let code: String
        let confidence: Double
    }

    static func accepts(_ result: ASRTranscription, audioDuration: TimeInterval,
                        requestedMode: ASRLanguageMode = .auto,
                        recognition: Recognition? = nil) -> Bool {
        guard requestedMode == .auto, result.languageMode == requestedMode,
              result.decode == .detected, !result.truncated, result.policy == 1,
              let language = SpokenLanguage.find(result.language), language.code != "en",
              language.qwenLabel == result.detectedLabel,
              let probability = result.languageProbability, probability.isFinite,
              let englishProbability = result.englishProbability, englishProbability.isFinite,
              (0...1).contains(probability), (0...1).contains(englishProbability) else { return false }
        let latin = language.writingSystem == .latin
        guard probability >= (latin ? latinMinProbability : nonLatinMinProbability),
              englishProbability <= (latin ? latinMaxEnglishProbability : nonLatinMaxEnglishProbability),
              scriptAccepts(result.text, language: language, recognition: recognition) else { return false }
        switch SourceQualityGate.fallbackReason(for: result.text, language: language, audioDuration: audioDuration) {
        case nil, .implausiblyShort: return true
        default: return false
        }
    }

    private static func scriptAccepts(_ text: String, language: SpokenLanguage, recognition: Recognition?) -> Bool {
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
            let words = text.split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            guard words.count >= latinMinimumWords, let detected = recognition ?? recognize(text),
                  detected.code != "en", detected.confidence.isFinite,
                  (latinRecognitionMinimumConfidence...1).contains(detected.confidence) else { return false }
            return detected.code == language.code
                || (["id", "ms"].contains(detected.code) && ["id", "ms"].contains(language.code))
        }
    }

    private static func share(_ numerator: Int, _ denominator: Int) -> Double {
        denominator > 0 ? Double(numerator) / Double(denominator) : 0
    }

    private static func recognize(_ text: String) -> Recognition? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] else { return nil }
        let code = language.rawValue == "tl" ? "fil" : language.rawValue
        return Recognition(code: code, confidence: confidence)
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
