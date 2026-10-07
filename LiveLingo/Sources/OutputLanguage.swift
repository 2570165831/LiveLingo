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
}
