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
    static let opacityRange = 0.7...1.0

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

    var sizePreset: Double? {
        get {
            storedSourceSize == 0 && storedTranslationSize == 0 && [24.0, 28.0, 32.0].contains(legacyTextSize)
                ? legacyTextSize : nil
        }
        nonmutating set {
            guard let newValue, [24.0, 28.0, 32.0].contains(newValue) else { return }
            legacyTextSize = newValue
            storedSourceSize = 0
            storedTranslationSize = 0
        }
    }

    // Shared by the real controls and binding tests; reading never writes a key.
    var displayModeBinding: Binding<FloatingSubtitleDisplayMode> {
        Binding(get: { displayMode }, set: { displayMode = $0 })
    }
    var sourceTextSizeBinding: Binding<Double> {
        Binding(get: { sourceTextSize }, set: { sourceTextSize = $0 })
    }
    var translationTextSizeBinding: Binding<Double> {
        Binding(get: { translationTextSize }, set: { translationTextSize = $0 })
    }
    var backgroundOpacityBinding: Binding<Double> {
        Binding(get: { backgroundOpacity }, set: { backgroundOpacity = $0 })
    }
    var sizePresetBinding: Binding<Double?> {
        Binding(get: { sizePreset }, set: { sizePreset = $0 })
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
         mode: FloatingSubtitleDisplayMode, hasUsableTranslation: Bool = true) {
        let language = caption?.languageName
        let sourceOnlyChinese = caption?.isSourceOnly == true
        if mode == .translationOnly && !sourceOnlyChinese && !hasUsableTranslation {
            source = Line(text: sourceText, languageName: language)
            translation = nil
            return
        }
        source = mode == .translationOnly || (mode == .bilingual && sourceOnlyChinese)
            ? nil : Line(text: sourceOnlyChinese ? translatedText : sourceText, languageName: language)
        translation = mode == .sourceOnly ? nil
            : Line(text: translatedText,
                   languageName: mode == .translationOnly || sourceOnlyChinese ? language : nil)
    }
}

/// Opaque defaults remain identical. Translucent colors meet contrast targets
/// even when the dark surface is composited over a white slide at 70% opacity.
struct FloatingSubtitlePalette {
    static let backgroundWhite = 0.08
    let sourceWhite: Double
    let languageWhite: Double
    let headerWhite: Double

    init(backgroundOpacity: Double) {
        sourceWhite = backgroundOpacity < 1 ? 0.95 : 0.9
        languageWhite = backgroundOpacity < 1 ? 0.8 : 0.6
        headerWhite = backgroundOpacity < 1 ? 0.9 : 0.8
    }
}
