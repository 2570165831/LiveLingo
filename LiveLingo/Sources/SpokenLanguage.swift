import Foundation

enum ASRLanguageMode: String, Sendable { case english, auto }

struct SpokenLanguage: Equatable, Sendable {
    enum WritingSystem: Hashable, Sendable {
        case han, japanese, hangul, cyrillic, arabic, thai, devanagari, greek, latin
    }

    let code: String
    let qwenLabel: String
    let writingSystem: WritingSystem
    /// Compatibility for existing callers; the target owns the decision.
    var avoidsTranslation: Bool { avoidsTranslation(target: .simplifiedChinese) }
    func avoidsTranslation(target: CaptionTranslationTarget = .simplifiedChinese) -> Bool {
        target.sourcePolicy(for: code).keepsSourceAsCaption
    }
    var chineseName: String {
        CaptionLanguageNames.name(for: code) ?? qwenLabel
    }

    static let all: [Self] = [
        .init(code: "zh", qwenLabel: "Chinese", writingSystem: .han),
        .init(code: "en", qwenLabel: "English", writingSystem: .latin),
        .init(code: "yue", qwenLabel: "Cantonese", writingSystem: .han),
        .init(code: "ar", qwenLabel: "Arabic", writingSystem: .arabic),
        .init(code: "de", qwenLabel: "German", writingSystem: .latin),
        .init(code: "fr", qwenLabel: "French", writingSystem: .latin),
        .init(code: "es", qwenLabel: "Spanish", writingSystem: .latin),
        .init(code: "pt", qwenLabel: "Portuguese", writingSystem: .latin),
        .init(code: "id", qwenLabel: "Indonesian", writingSystem: .latin),
        .init(code: "it", qwenLabel: "Italian", writingSystem: .latin),
        .init(code: "ko", qwenLabel: "Korean", writingSystem: .hangul),
        .init(code: "ru", qwenLabel: "Russian", writingSystem: .cyrillic),
        .init(code: "th", qwenLabel: "Thai", writingSystem: .thai),
        .init(code: "vi", qwenLabel: "Vietnamese", writingSystem: .latin),
        .init(code: "ja", qwenLabel: "Japanese", writingSystem: .japanese),
        .init(code: "tr", qwenLabel: "Turkish", writingSystem: .latin),
        .init(code: "hi", qwenLabel: "Hindi", writingSystem: .devanagari),
        .init(code: "ms", qwenLabel: "Malay", writingSystem: .latin),
        .init(code: "nl", qwenLabel: "Dutch", writingSystem: .latin),
        .init(code: "sv", qwenLabel: "Swedish", writingSystem: .latin),
        .init(code: "da", qwenLabel: "Danish", writingSystem: .latin),
        .init(code: "fi", qwenLabel: "Finnish", writingSystem: .latin),
        .init(code: "pl", qwenLabel: "Polish", writingSystem: .latin),
        .init(code: "cs", qwenLabel: "Czech", writingSystem: .latin),
        .init(code: "fil", qwenLabel: "Filipino", writingSystem: .latin),
        .init(code: "fa", qwenLabel: "Persian", writingSystem: .arabic),
        .init(code: "el", qwenLabel: "Greek", writingSystem: .greek),
        .init(code: "ro", qwenLabel: "Romanian", writingSystem: .latin),
        .init(code: "hu", qwenLabel: "Hungarian", writingSystem: .latin),
        .init(code: "mk", qwenLabel: "Macedonian", writingSystem: .cyrillic),
    ]

    static func find(_ code: String?) -> Self? { all.first { $0.code == code } }
    static func nonEnglishCode(_ code: String?) -> String? {
        guard let language = find(code), language.code != "en" else { return nil }
        return language.code
    }

    /// Source script identity is separate from the target's acceptance policy.
    func containsSourceScalar(_ scalar: Unicode.Scalar) -> Bool {
        guard CharacterSet.letters.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) else {
            return false
        }
        switch writingSystem {
        case .han: return TranslationAcceptance.isHan(scalar)
        case .japanese:
            return TranslationAcceptance.isHan(scalar) || (0x3040...0x30FF).contains(scalar.value)
        case .hangul:
            return (0x1100...0x11FF).contains(scalar.value) || (0x3130...0x318F).contains(scalar.value)
                || (0xA960...0xA97F).contains(scalar.value) || (0xAC00...0xD7FF).contains(scalar.value)
        case .cyrillic: return (0x0400...0x052F).contains(scalar.value)
        case .arabic:
            return (0x0600...0x06FF).contains(scalar.value) || (0x0750...0x077F).contains(scalar.value)
                || (0x08A0...0x08FF).contains(scalar.value)
        case .thai: return (0x0E00...0x0E7F).contains(scalar.value)
        case .devanagari: return (0x0900...0x097F).contains(scalar.value)
        case .greek: return (0x0370...0x03FF).contains(scalar.value) || (0x1F00...0x1FFF).contains(scalar.value)
        case .latin:
            return (0x0041...0x005A).contains(scalar.value) || (0x0061...0x007A).contains(scalar.value)
                || (0x00C0...0x02AF).contains(scalar.value) || (0x1E00...0x1EFF).contains(scalar.value)
        }
    }
}

struct ASRTranscription: Equatable, Sendable {
    enum Decode: String, Decodable, Sendable { case forced, detected }
    let text: String
    var languageMode: ASRLanguageMode = .english
    var language = "en"
    var decode: Decode = .forced
    var detectedLabel: String?
    var languageProbability: Double?
    var englishProbability: Double?
    var generatedTokens = 0
    var truncated = false
    var policy: Int?

    private struct AutoResponse: Decodable {
        let language_mode: String
        let language: String
        let decode: Decode
        let detected_label: String?
        let language_probability: Double?
        let english_probability: Double?
        let generated_tokens: Int
        let truncated: Bool
        let policy: Int
    }

    static func validated(text: String, data: Data, requestedLanguage: ASRLanguageMode) throws -> Self {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requestedLanguage == .auto else { return Self(text: trimmed) }
        guard let response = try? JSONDecoder().decode(AutoResponse.self, from: data),
              response.language_mode == "auto", response.policy == 1,
              (0...256).contains(response.generated_tokens) else { throw QwenRuntimeError.invalidResponse }
        let probabilities = [response.language_probability, response.english_probability]
        guard probabilities.allSatisfy({ $0.map { $0.isFinite && (0...1).contains($0) } ?? true }) else {
            throw QwenRuntimeError.invalidResponse
        }
        if let label = response.detected_label {
            guard label == "None" || SpokenLanguage.all.contains(where: { $0.qwenLabel == label }),
                  probabilities.allSatisfy({ $0 != nil }) else { throw QwenRuntimeError.invalidResponse }
        } else {
            guard probabilities.allSatisfy({ $0 == nil }) else { throw QwenRuntimeError.invalidResponse }
        }
        switch response.decode {
        case .forced:
            guard response.language == "en" else { throw QwenRuntimeError.invalidResponse }
        case .detected:
            guard let language = SpokenLanguage.find(response.language), language.code != "en",
                  language.qwenLabel == response.detected_label,
                  probabilities.allSatisfy({ $0 != nil }) else { throw QwenRuntimeError.invalidResponse }
        }
        return Self(text: trimmed, languageMode: .auto, language: response.language, decode: response.decode,
                    detectedLabel: response.detected_label, languageProbability: response.language_probability,
                    englishProbability: response.english_probability, generatedTokens: response.generated_tokens,
                    truncated: response.truncated, policy: response.policy)
    }
}
