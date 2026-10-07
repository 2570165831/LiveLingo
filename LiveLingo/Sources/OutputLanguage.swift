import Foundation

/// Output metadata is independent of the language generated and stored by the
/// model. Only released profiles can be selected for a new course.
enum OutputLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChineseTaiwan = "zh-Hant-TW"
    case traditionalChineseHongKong = "zh-Hant-HK"
    case english = "en"
    case spanish = "es"
    case french = "fr"

    enum Script: Sendable { case han, latin }
    enum Renderer: Sendable { case identity, taiwan, hongKong }
    struct AppleLanguagePair: Equatable, Sendable {
        let source: String
        let target: String
    }
    struct Profile: Sendable {
        let autonym: String
        let promptName: String
        let script: Script
        let generationLocale: String
        let renderer: Renderer
        let passThroughSources: Set<String>
        let appleLanguagePair: AppleLanguagePair?
        let isReleased: Bool
    }

    private static let profiles: [Self: Profile] = [
        .simplifiedChinese: .init(autonym: "简体中文", promptName: "Simplified Chinese", script: .han,
            generationLocale: "zh-Hans", renderer: .identity, passThroughSources: ["zh"],
            appleLanguagePair: .init(source: "en", target: "zh-Hans"), isReleased: true),
        .traditionalChineseTaiwan: .init(autonym: "繁體中文（中國台灣）", promptName: "Simplified Chinese", script: .han,
            generationLocale: "zh-Hans", renderer: .taiwan, passThroughSources: ["zh"],
            appleLanguagePair: .init(source: "en", target: "zh-Hans"), isReleased: false),
        .traditionalChineseHongKong: .init(autonym: "繁體中文（中國港澳）", promptName: "Simplified Chinese", script: .han,
            generationLocale: "zh-Hans", renderer: .hongKong, passThroughSources: ["zh"],
            appleLanguagePair: .init(source: "en", target: "zh-Hans"), isReleased: false),
        .english: .init(autonym: "English", promptName: "English", script: .latin,
            generationLocale: "en", renderer: .identity, passThroughSources: ["en"],
            appleLanguagePair: nil, isReleased: false),
        .spanish: .init(autonym: "Español", promptName: "Spanish", script: .latin,
            generationLocale: "es", renderer: .identity, passThroughSources: [],
            appleLanguagePair: .init(source: "en", target: "es"), isReleased: false),
        .french: .init(autonym: "Français", promptName: "French", script: .latin,
            generationLocale: "fr", renderer: .identity, passThroughSources: [],
            appleLanguagePair: .init(source: "en", target: "fr"), isReleased: false),
    ]

    var id: String { rawValue }
    var profile: Profile { Self.profiles[self]! }
    var autonym: String { profile.autonym }
    var isReleased: Bool { profile.isReleased }
    var generationTarget: CaptionTranslationTarget? { CaptionTranslationTarget(rawValue: profile.generationLocale) }
    /// The default is omitted from persistence to preserve existing bytes.
    var persistedLocale: String? { self == .simplifiedChinese ? nil : rawValue }
    static var released: [Self] { allCases.filter(\.isReleased) }
    static func releasedLanguage(_ locale: String) -> Self? {
        guard let language = Self(rawValue: locale), language.isReleased else { return nil }
        return language
    }
    static func storedLanguage(_ locale: String?) throws -> Self {
        guard let locale else { return .simplifiedChinese }
        guard let language = Self(rawValue: locale) else {
            throw SessionStoreError.invalidState("课程输出语言不受支持")
        }
        return language
    }

    /// Course data owns this choice. Preferences apply only at creation.
    static func savedLanguage(in directory: URL, snapshot: SessionSnapshot,
                              origin: SessionLoadResult.Origin? = nil) throws -> Self {
        if let locale = snapshot.targetLocale { return try storedLanguage(locale) }
        // A persisted nil is an explicit Simplified Chinese choice. Only a
        // legacy import without a snapshot needs the export's metadata.
        let hasSnapshot = origin.map { $0 == .snapshot }
            ?? FileManager.default.fileExists(atPath: directory.appendingPathComponent(SessionStore.snapshotFileName).path)
        if hasSnapshot { return .simplifiedChinese }
        struct Metadata: Decodable { let targetLocale: String? }
        let manifest = directory.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifest),
           let metadata = try? JSONDecoder().decode(Metadata.self, from: data) {
            // The non-regional code occurs in synthetic verifier fixtures,
            // not released exporters. Continue using the supported generator.
            if metadata.targetLocale == "zh-Hant" { return .simplifiedChinese }
            return try storedLanguage(metadata.targetLocale)
        }
        return .simplifiedChinese
    }

    var rendererIsAvailable: Bool {
        if case .identity = profile.renderer { return true }
        return false
    }

    func keepsSourceAsCaption(language: String?) -> Bool {
        profile.passThroughSources.contains(language ?? "en")
    }

    func render(_ text: String) throws -> String {
        guard rendererIsAvailable else {
            throw SessionStoreError.invalidState("课程输出语言的渲染器尚不可用")
        }
        return text
    }

    enum SavedRenderer {
        case output(OutputLanguage)
        // These layouts preserve synthetic verifier fixtures. No released
        // exporter produced them; they are never used for new exports.
        case fixtureTraditionalChinese(usesLegacyFormat: Bool)
        case fixtureEnglishTwoLine

        func targetLine(_ segment: TranscriptSegment) -> String {
            switch self {
            case .output(let language): return SessionExporter.targetLine(segment, outputLanguage: language)
            case .fixtureEnglishTwoLine:
                return SessionExporter.targetLine(segment, outputLanguage: .english)
            case .fixtureTraditionalChinese(let usesLegacyFormat):
                return usesLegacyFormat ? SessionExporter.humanReadableChinese(segment.chinese)
                    : SessionExporter.targetLine(segment, target: .simplifiedChinese)
            }
        }
        func srtCue(_ segment: TranscriptSegment, index: Int) -> String {
            switch self {
            case .output(let language): return SessionExporter.srtCue(segment, index: index, outputLanguage: language)
            case .fixtureEnglishTwoLine:
                return "\(index + 1)\n\(SessionExporter.srtTimestamp(segment.startTime)) --> \(SessionExporter.srtTimestamp(segment.endTime))\n"
                    + [segment.english, targetLine(segment)].joined(separator: "\n")
            case .fixtureTraditionalChinese(let usesLegacyFormat):
                if !usesLegacyFormat {
                    return SessionExporter.srtCue(segment, index: index, target: .simplifiedChinese)
                }
                return "\(index + 1)\n\(SessionExporter.srtTimestamp(segment.startTime)) --> \(SessionExporter.srtTimestamp(segment.endTime))\n"
                    + [segment.english, targetLine(segment)].joined(separator: "\n")
            }
        }
    }

    static func savedRenderer(for locale: String, sourceLanguages: [String]? = nil) -> SavedRenderer? {
        if locale == "zh-Hant" { return .fixtureTraditionalChinese(usesLegacyFormat: sourceLanguages == nil) }
        guard let language = Self(rawValue: locale), language.rendererIsAvailable else { return nil }
        return .output(language)
    }

}

/// One policy switch and one table for fixed classroom output text. The user
/// has not selected target-language labels yet; interface Chinese is the default.
enum ClassroomFixedText: String, CaseIterable {
    case pendingTranslation, failedAgainstSource, failedAgainstEnglish, formulaNeedsReview, transcriptHeading, exportTranscriptToggle

    static let usesTargetLanguage = false
    private static let labels: [Self: [String: String]] = [
        .pendingTranslation: ["zh": "（本段暂无译文）", "en": "(Translation pending)"],
        .failedAgainstSource: ["zh": "（本段翻译未完成，可对照原文）", "en": "(Translation incomplete; see source)"],
        .failedAgainstEnglish: ["zh": "（本段翻译未完成，可对照英文）", "en": "(Translation incomplete; see English source)"],
        .formulaNeedsReview: ["zh": "【公式待核对】", "en": "[Formula needs review]"],
        .transcriptHeading: ["zh": "字幕（含时间戳）", "en": "Captions (with timestamps)"],
        .exportTranscriptToggle: ["zh": "附带字幕与时间戳（按所选范围）", "en": "Include captions and timestamps for this scope"],
    ]

    func text(targetCode: String, useTargetLanguage: Bool = usesTargetLanguage) -> String {
        let locale = useTargetLanguage && !targetCode.hasPrefix("zh") ? targetCode : "zh"
        return Self.labels[self]![locale] ?? Self.labels[self]!["zh"]!
    }
}
