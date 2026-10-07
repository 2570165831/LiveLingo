import SwiftUI

enum FloatingSubtitleDisplayMode: String, CaseIterable, Identifiable {
    case bilingual
    case translationOnly
    case sourceOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .bilingual: "双语"
        case .translationOnly: "仅中文译文"
        case .sourceOnly: "仅原文"
        }
    }
}

/// Additive preferences: old apps still read their original size preset.
/// Missing independent sizes inherit that preset, including existing 28/32 users.
struct FloatingSubtitlePreferences: DynamicProperty {
    static let fontSizeRange = 16.0...40.0
    static let opacityRange = 0.5...1.0

    @AppStorage private var legacyTextSize: Double
    @AppStorage private var storedSourceSize: Double
    @AppStorage private var storedTranslationSize: Double
    @AppStorage private var storedDisplayMode: String
    @AppStorage private var storedOpacity: Double

    init(store: UserDefaults? = nil) {
        _legacyTextSize = AppStorage(wrappedValue: 24, "floatingTextSize", store: store)
        _storedSourceSize = AppStorage(wrappedValue: 0, "floatingSourceTextSize", store: store)
        _storedTranslationSize = AppStorage(wrappedValue: 0, "floatingTranslationTextSize", store: store)
        _storedDisplayMode = AppStorage(wrappedValue: FloatingSubtitleDisplayMode.bilingual.rawValue,
                                       "floatingDisplayMode", store: store)
        _storedOpacity = AppStorage(wrappedValue: 1, "floatingBackgroundOpacity", store: store)
    }

    var displayMode: FloatingSubtitleDisplayMode {
        get { FloatingSubtitleDisplayMode(rawValue: storedDisplayMode) ?? .bilingual }
        nonmutating set { storedDisplayMode = newValue.rawValue }
    }

    var sourceTextSize: Double {
        get { bounded(storedSourceSize == 0 ? legacyTextSize - 3 : storedSourceSize,
                      to: Self.fontSizeRange, fallback: 21) }
        nonmutating set { storedSourceSize = bounded(newValue, to: Self.fontSizeRange, fallback: 21) }
    }

    var translationTextSize: Double {
        get { bounded(storedTranslationSize == 0 ? legacyTextSize : storedTranslationSize,
                      to: Self.fontSizeRange, fallback: 24) }
        nonmutating set { storedTranslationSize = bounded(newValue, to: Self.fontSizeRange, fallback: 24) }
    }

    var backgroundOpacity: Double {
        get { bounded(storedOpacity, to: Self.opacityRange, fallback: 1) }
        nonmutating set { storedOpacity = bounded(newValue, to: Self.opacityRange, fallback: 1) }
    }

    var sizePreset: Double {
        get { legacyTextSize }
        nonmutating set {
            legacyTextSize = newValue
            storedSourceSize = 0
            storedTranslationSize = 0
        }
    }

    private func bounded(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

/// Select only the visible body text; language metadata never joins a copy/export string.
struct FloatingSubtitlePresentation: Equatable {
    struct Line: Equatable {
        let text: String
        let languageName: String?
    }

    let source: Line?
    let translation: Line?

    init(sourceText: String, translatedText: String, caption: CaptionPresentation?,
         mode: FloatingSubtitleDisplayMode) {
        let language = caption?.languageName
        let sourceOnlyChinese = caption?.isSourceOnly == true
        source = mode == .translationOnly || (mode == .bilingual && sourceOnlyChinese)
            ? nil : Line(text: sourceOnlyChinese ? translatedText : sourceText, languageName: language)
        translation = mode == .sourceOnly ? nil
            : Line(text: translatedText,
                   languageName: mode == .translationOnly || sourceOnlyChinese ? language : nil)
    }
}
