import AppKit
import SwiftUI
import XCTest
@testable import LiveLingo

/// Synthetic hosted views only; no capture, model, translation service or real preferences.
@MainActor
final class FloatingSubtitleDisplayTests: XCTestCase {
    private let artifacts = FileManager.default.temporaryDirectory
        .appendingPathComponent("display-options", isDirectory: true)

    private func defaults() throws -> (UserDefaults, String) {
        let suite = "FloatingSubtitleDisplay-\(UUID().uuidString)"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { try cleanup.remove() }
        return (defaults, suite)
    }

    func testFreshDefaultsMatchTheOriginalAppearance() throws {
        let (store, suite) = try defaults()
        let preferences = FloatingSubtitlePreferences(store: store)
        XCTAssertEqual(preferences.displayMode, .bilingual)
        XCTAssertEqual(preferences.sizePreset, 24)
        XCTAssertEqual(preferences.sourceTextSize, 21)
        XCTAssertEqual(preferences.translationTextSize, 24)
        XCTAssertEqual(preferences.backgroundOpacity, 1)
        XCTAssertTrue(store.persistentDomain(forName: suite)?.isEmpty ?? true,
                      "Reading defaults must not migrate or rewrite old preferences")
    }

    func testExistingSizePresetsAreInheritedWithoutMigration() throws {
        let (store, _) = try defaults()
        for (preset, sourceSize) in [(24.0, 21.0), (28.0, 25.0), (32.0, 29.0)] {
            store.set(preset, forKey: "floatingTextSize")
            let preferences = FloatingSubtitlePreferences(store: store)
            XCTAssertEqual(preferences.sourceTextSize, sourceSize)
            XCTAssertEqual(preferences.translationTextSize, preset)
            XCTAssertNil(store.object(forKey: "floatingSourceTextSize"))
            XCTAssertNil(store.object(forKey: "floatingTranslationTextSize"))
        }
    }

    func testIndependentSizesPersistWithoutChangingTheLegacyPreset() throws {
        let (store, suite) = try defaults()
        store.set(28.0, forKey: "floatingTextSize")
        let preferences = FloatingSubtitlePreferences(store: store)
        preferences.sourceTextSize = 18
        XCTAssertEqual(preferences.translationTextSize, 28)
        preferences.translationTextSize = 36
        let reopened = FloatingSubtitlePreferences(store: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reopened.sourceTextSize, 18)
        XCTAssertEqual(reopened.translationTextSize, 36)
        XCTAssertEqual(store.double(forKey: "floatingTextSize"), 28,
                       "Older versions must still find their unchanged usable preset")
        XCTAssertEqual(store.double(forKey: "floatingSourceTextSize"), 18)
        XCTAssertEqual(store.double(forKey: "floatingTranslationTextSize"), 36)
    }

    func testOriginalMenuPresetsStillSetBothSizes() throws {
        let (store, suite) = try defaults()
        let preferences = FloatingSubtitlePreferences(store: store)
        for (preset, sourceSize) in [(24.0, 21.0), (28.0, 25.0), (32.0, 29.0)] {
            preferences.sourceTextSize = 16
            preferences.translationTextSize = 40
            XCTAssertNil(preferences.sizePresetBinding.wrappedValue)
            preferences.sizePresetBinding.wrappedValue = preset
            let reopened = FloatingSubtitlePreferences(store: try XCTUnwrap(UserDefaults(suiteName: suite)))
            XCTAssertEqual(reopened.sizePreset, preset)
            XCTAssertEqual(reopened.sourceTextSize, sourceSize)
            XCTAssertEqual(reopened.translationTextSize, preset)
        }
    }

    func testModeAndBackgroundOpacityPersist() throws {
        let (store, suite) = try defaults()
        let preferences = FloatingSubtitlePreferences(store: store)
        for mode in FloatingSubtitleDisplayMode.allCases {
            preferences.displayMode = mode
            preferences.backgroundOpacity = 0.75
            let reopened = FloatingSubtitlePreferences(store: try XCTUnwrap(UserDefaults(suiteName: suite)))
            XCTAssertEqual(reopened.displayMode, mode)
            XCTAssertEqual(reopened.backgroundOpacity, 0.75)
            XCTAssertEqual(store.string(forKey: "floatingDisplayMode"), mode.rawValue)
            XCTAssertEqual(store.double(forKey: "floatingBackgroundOpacity"), 0.75)
        }
    }

    func testUnknownModeAndOutOfRangeValuesRemainUsable() throws {
        let (store, _) = try defaults()
        store.set("future-mode", forKey: "floatingDisplayMode")
        store.set(-10.0, forKey: "floatingSourceTextSize")
        store.set(200.0, forKey: "floatingTranslationTextSize")
        store.set(-0.1, forKey: "floatingBackgroundOpacity")
        let preferences = FloatingSubtitlePreferences(store: store)
        XCTAssertEqual(preferences.displayMode, .bilingual)
        XCTAssertEqual(preferences.sourceTextSize, 16)
        XCTAssertEqual(preferences.translationTextSize, 40)
        XCTAssertEqual(preferences.backgroundOpacity, 0.7)
        store.set(0.5, forKey: "floatingBackgroundOpacity")
        XCTAssertEqual(preferences.backgroundOpacity, 0.7, "Previously stored low opacity must also be bounded")
        preferences.backgroundOpacity = 5
        XCTAssertEqual(preferences.backgroundOpacity, 1)
        preferences.sourceTextSize = .nan
        preferences.translationTextSize = .infinity
        preferences.backgroundOpacity = .nan
        XCTAssertEqual(preferences.sourceTextSize, 21)
        XCTAssertEqual(preferences.translationTextSize, 24)
        XCTAssertEqual(preferences.backgroundOpacity, 1)
    }

    func testEnglishModesSelectOnlyTheirRequestedBodyText() {
        let source = "The water is cold."
        let translation = "初译 · 水很冷。"
        let bilingual = FloatingSubtitlePresentation(sourceText: source, translatedText: translation,
                                                      caption: nil, mode: .bilingual)
        XCTAssertEqual(bilingual.source, .init(text: source, languageName: nil))
        XCTAssertEqual(bilingual.translation, .init(text: translation, languageName: nil))
        let translated = FloatingSubtitlePresentation(sourceText: source, translatedText: translation,
                                                       caption: nil, mode: .translationOnly)
        XCTAssertNil(translated.source)
        XCTAssertEqual(translated.translation, .init(text: "初译 · 水很冷。", languageName: nil))
        let original = FloatingSubtitlePresentation(sourceText: source, translatedText: translation,
                                                     caption: nil, mode: .sourceOnly)
        XCTAssertEqual(original.source, .init(text: "The water is cold.", languageName: nil))
        XCTAssertNil(original.translation)
    }

    func testNonEnglishLabelFollowsTheVisibleLineWithoutJoiningBodyText() {
        for (code, source, label) in [("es", "El agua está fría.", "西班牙语"),
                                      ("yue", "啲水好凍。", "粤语"), ("ja", "水は冷たい。", "日语")] {
            let caption = TranscriptSegment(startTime: 0, endTime: 2, english: source,
                                            chinese: "水很冷。", sourceLanguage: code)
            for mode in FloatingSubtitleDisplayMode.allCases {
                let presentation = FloatingSubtitlePresentation(sourceText: source, translatedText: "水很冷。",
                                                                  caption: CaptionPresentation(caption), mode: mode)
                XCTAssertEqual(presentation.source?.text, mode == .translationOnly ? nil : source)
                XCTAssertEqual(presentation.translation?.text, mode == .sourceOnly ? nil : "水很冷。")
                XCTAssertEqual(presentation.source?.languageName, mode == .translationOnly ? nil : label)
                XCTAssertEqual(presentation.translation?.languageName, mode == .translationOnly ? label : nil)
            }
        }
    }

    func testChineseUsesNormalizedSourceExactlyOnceInEveryMode() throws {
        let (model, _) = try fixture()
        let caption = TranscriptSegment(startTime: 0, endTime: 2, english: "這本書放在桌上。",
                                        chinese: "这本书在桌上。", sourceLanguage: "zh")
        model.loadPresentationForTesting(phase: .recording, evidence: [caption])
        for mode in FloatingSubtitleDisplayMode.allCases {
            let presentation = select(model, mode: mode)
            let lines = [presentation.source, presentation.translation].compactMap { $0 }
            XCTAssertEqual(lines, [.init(text: "这本书放在桌上。", languageName: "中文")])
            XCTAssertEqual(presentation.source == nil, mode != .sourceOnly)
            XCTAssertEqual(presentation.translation == nil, mode == .sourceOnly)
        }
        XCTAssertEqual(model.segments.first?.english, "這本書放在桌上。")
        XCTAssertEqual(model.segments.first?.chinese, "这本书在桌上。")
    }

    func testChinesePendingAndFailedStatesDoNotAddATranslationPlaceholder() throws {
        let (model, _) = try fixture()
        let pending = TranscriptSegment(startTime: 0, endTime: 2, english: "這裡很冷。", sourceLanguage: "zh")
        var translating = pending
        translating.beginTranslation()
        var failed = pending
        failed.failTranslation("synthetic failure")
        var completed = pending
        completed.completeTranslation("这里好冷。")
        XCTAssertEqual(pending.translationState, .pending)
        for caption in [pending, translating, failed, completed] {
            model.loadPresentationForTesting(phase: .recording, evidence: [caption])
            for mode in FloatingSubtitleDisplayMode.allCases {
                let presentation = select(model, mode: mode)
                XCTAssertEqual([presentation.source, presentation.translation].compactMap { $0?.text }, ["这里很冷。"])
            }
        }
    }

    func testEnglishTranslationOnlyFallsBackUntilPreviewOrFormalTranslationIsUsable() throws {
        let (model, _) = try fixture()
        model.loadPresentationForTesting(phase: .recording, evidence: [], preview: "The water is cold.")
        model.receiveLivePreviewForTesting("The water is cold.", chinese: "")
        XCTAssertEqual(select(model, mode: .translationOnly).source, .init(text: "The water is cold.", languageName: nil))
        XCTAssertNil(select(model, mode: .translationOnly).translation)
        model.receiveLivePreviewForTesting("The water is cold.", chinese: "水很冷。")
        if model.supportsPreviewTranslation {
            XCTAssertEqual(select(model, mode: .translationOnly).translation?.text, "初译 · 水很冷。")
        }
        model.previewTranslationEnabled = false
        XCTAssertEqual(select(model, mode: .translationOnly).source, .init(text: "The water is cold.", languageName: nil))
        XCTAssertNil(select(model, mode: .translationOnly).translation)
        let formal = TranscriptSegment(startTime: 0, endTime: 2, english: "The water is cold.", chinese: "水很冷。")
        model.loadPresentationForTesting(phase: .recording, evidence: [formal])
        XCTAssertEqual(select(model, mode: .translationOnly).translation, .init(text: "水很冷。", languageName: nil))
        XCTAssertNil(select(model, mode: .translationOnly).source)
        model.receiveLivePreviewForTesting("A new untranslated sentence.", chinese: "")
        XCTAssertEqual(select(model, mode: .translationOnly).source?.text, "A new untranslated sentence.")
        XCTAssertNil(select(model, mode: .translationOnly).translation, "The preceding formal translation must not replace new speech")
    }

    func testEverySupportedLanguageKeepsItsSingleLineOrBilingualPolicy() {
        for language in SpokenLanguage.all {
            let segment = TranscriptSegment(startTime: 0, endTime: 2, english: "synthetic source",
                                            chinese: "合成译文。", sourceLanguage: language.code)
            let caption = CaptionPresentation(segment)
            for mode in FloatingSubtitleDisplayMode.allCases {
                let presentation = FloatingSubtitlePresentation(sourceText: segment.english, translatedText: segment.chinese,
                                                                  caption: caption, mode: mode)
                let lines = [presentation.source, presentation.translation].compactMap { $0 }
                let expectedCount = mode == .bilingual && language.code != "zh" ? 2 : 1
                XCTAssertEqual(lines.count, expectedCount, "\(language.code) / \(mode)")
                XCTAssertEqual(lines.filter { $0.languageName != nil }.count, language.code == "en" ? 0 : 1)
            }
        }
    }

    func testTranslationOnlyMissingStatesAlwaysShowSourceAndReturnToTranslation() throws {
        let (model, _) = try fixture()
        for (code, source, label) in [("es", "El agua está fría.", "西班牙语"), ("yue", "啲水好凍。", "粤语")] {
            let pending = TranscriptSegment(startTime: 0, endTime: 2, english: source, sourceLanguage: code)
            var translating = pending
            translating.beginTranslation()
            var failed = pending
            failed.failTranslation("synthetic failure")
            for caption in [pending, translating, failed] {
                model.loadPresentationForTesting(phase: .recording, evidence: [caption])
                let presentation = select(model, mode: .translationOnly)
                XCTAssertEqual(presentation.source, .init(text: source, languageName: label))
                XCTAssertNil(presentation.translation)
            }
            var completed = pending
            completed.completeTranslation("水很冷。")
            model.loadPresentationForTesting(phase: .recording, evidence: [completed])
            XCTAssertNil(select(model, mode: .translationOnly).source)
            XCTAssertEqual(select(model, mode: .translationOnly).translation, .init(text: "水很冷。", languageName: label))
        }
        for status in ["初译已关闭", "当前系统不支持初译；正式译文随后显示", "等待初译…", "等待正式译文…", "本段翻译未完成"] {
            let presentation = FloatingSubtitlePresentation(sourceText: "The water is cold.", translatedText: status,
                                                            caption: nil, mode: .translationOnly, hasUsableTranslation: false)
            XCTAssertEqual(presentation.source, .init(text: "The water is cold.", languageName: nil))
            XCTAssertNil(presentation.translation)
        }
    }

    func testSettingsBindingsWriteOnlyTheirIntendedKeysAndMenuRestoresInheritance() throws {
        let (store, _) = try defaults()
        store.set(28.0, forKey: "floatingTextSize")
        let preferences = FloatingSubtitlePreferences(store: store)
        XCTAssertEqual(preferences.sourceTextSizeBinding.wrappedValue, 25)
        XCTAssertEqual(preferences.translationTextSizeBinding.wrappedValue, 28)
        preferences.sourceTextSizeBinding.wrappedValue = 18
        XCTAssertEqual(store.double(forKey: "floatingSourceTextSize"), 18)
        XCTAssertNil(store.object(forKey: "floatingTranslationTextSize"))
        XCTAssertNil(preferences.sizePresetBinding.wrappedValue)
        preferences.translationTextSizeBinding.wrappedValue = 36
        XCTAssertEqual(store.double(forKey: "floatingTranslationTextSize"), 36)
        XCTAssertEqual(store.double(forKey: "floatingSourceTextSize"), 18)
        preferences.displayModeBinding.wrappedValue = .translationOnly
        XCTAssertEqual(store.string(forKey: "floatingDisplayMode"), "translationOnly")
        preferences.backgroundOpacityBinding.wrappedValue = 0.75
        XCTAssertEqual(store.double(forKey: "floatingBackgroundOpacity"), 0.75)
        XCTAssertEqual(store.double(forKey: "floatingTextSize"), 28)
        preferences.sizePresetBinding.wrappedValue = 28
        XCTAssertEqual(preferences.sizePresetBinding.wrappedValue, 28)
        XCTAssertEqual(preferences.sourceTextSizeBinding.wrappedValue, 25)
        XCTAssertEqual(preferences.translationTextSizeBinding.wrappedValue, 28)
        XCTAssertEqual(store.double(forKey: "floatingSourceTextSize"), 0)
        XCTAssertEqual(store.double(forKey: "floatingTranslationTextSize"), 0)
        XCTAssertEqual(store.string(forKey: "floatingDisplayMode"), "translationOnly")
        XCTAssertEqual(store.double(forKey: "floatingBackgroundOpacity"), 0.75)
    }

    func testTranslucentLanguageAndBodyColorsMeetContrastOverLightContent() {
        func luminance(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        func contrast(_ foreground: Double, _ background: Double) -> Double {
            (luminance(foreground) + 0.05) / (luminance(background) + 0.05)
        }
        for opacity in [0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 1] {
            let palette = FloatingSubtitlePalette(backgroundOpacity: opacity)
            for slide in [0.0, 0.5, 1.0] {
                let background = FloatingSubtitlePalette.backgroundWhite * opacity + slide * (1 - opacity)
                XCTAssertGreaterThanOrEqual(contrast(palette.languageWhite, background), 3,
                                            "Language tag: opacity=\(opacity), underlying white=\(slide)")
                XCTAssertGreaterThanOrEqual(contrast(palette.sourceWhite, background), 4.5)
                XCTAssertGreaterThanOrEqual(contrast(1, background), 4.5)
            }
        }
        let worst = 0.08 * 0.7 + 1 * 0.3
        print("FLOATING_CONTRAST white-slide/70-percent tag=\(contrast(0.8, worst)) source=\(contrast(0.95, worst)) translation=\(contrast(1, worst))")
    }

    func testHostedMissingTranslationShowsOnlyTheTaggedSourceThenOnlyTranslation() async throws {
        let (model, store) = try fixture()
        FloatingSubtitlePreferences(store: store).displayMode = .translationOnly
        var caption = TranscriptSegment(startTime: 0, endTime: 2, english: "El agua está fría.", sourceLanguage: "es")
        model.loadPresentationForTesting(phase: .recording, evidence: [caption])
        let (window, controller) = host(floating(model, store: store))
        defer { window.close() }
        try await resizeAndSettle(window, view: controller.view)
        let pending = try bitmap(controller.view)
        let scale = CGFloat(pending.pixelsHigh) / controller.view.bounds.height
        XCTAssertTrue(hasVisibleText(pending, scale: scale, rows: 50..<130))
        XCTAssertFalse(hasVisibleText(pending, scale: scale, rows: 160..<280))
        try capture(controller.view, name: "floating-es-translationOnly-pending")
        caption.completeTranslation("水很冷。")
        model.loadPresentationForTesting(phase: .recording, evidence: [caption])
        try await settle(controller.view)
        let completed = try bitmap(controller.view)
        XCTAssertFalse(hasVisibleText(completed, scale: scale, rows: 50..<130))
        XCTAssertTrue(hasVisibleText(completed, scale: scale, rows: 160..<280))
    }

    func testLongSpanishCaptionStaysAtBottomWhenLanguageLabelMovesBetweenSlots() async throws {
        let (model, store) = try fixture()
        let preferences = FloatingSubtitlePreferences(store: store)
        model.loadPresentationForTesting(phase: .recording, evidence: [])
        let (window, controller) = host(floating(model, store: store))
        defer { window.close() }
        try await resizeAndSettle(window, view: controller.view)
        let caption = TranscriptSegment(startTime: 0, endTime: 2,
            english: String(repeating: "Una oración larga para comprobar el desplazamiento. ", count: 40),
            chinese: String(repeating: "这是用于验证语种标签换行后仍然贴底的长字幕。", count: 40), sourceLanguage: "es")
        model.loadPresentationForTesting(phase: .recording, evidence: [caption])
        try await settle(controller.view)
        let original = subtitleScrollViews(controller.view)
        XCTAssertEqual(original.count, 2)
        let translation = try XCTUnwrap(original.last)
        try assertScrolledToBottom(translation)
        let bilingualHeight = try XCTUnwrap(translation.documentView).bounds.height
        for mode in [FloatingSubtitleDisplayMode.translationOnly, .bilingual, .translationOnly, .bilingual] {
            preferences.displayMode = mode
            try await settle(controller.view)
            let current = subtitleScrollViews(controller.view)
            XCTAssertEqual(current.count, 2)
            XCTAssertTrue(current.last === translation)
            try assertScrolledToBottom(translation)
            if mode == .translationOnly {
                XCTAssertGreaterThan(try XCTUnwrap(translation.documentView).bounds.height, bilingualHeight,
                                     "The language label must reduce text width and actually exercise reflow")
                try capture(controller.view, name: "floating-es-long-translationOnly")
            }
        }
        try capture(controller.view, name: "floating-es-long-bilingual")
    }

    func testNativeSizeMenuShowsCustomAndCanReselectThePreviousPreset() async throws {
        let (model, store) = try fixture()
        let preferences = FloatingSubtitlePreferences(store: store)
        model.loadPresentationForTesting(phase: .recording, evidence: [])
        let (window, controller) = host(floating(model, store: store))
        defer { window.close() }
        preferences.sourceTextSizeBinding.wrappedValue = 18
        preferences.translationTextSizeBinding.wrappedValue = 36
        try await resizeAndSettle(window, view: controller.view)
        let items = try inspectSizeMenu(in: controller.view, selecting: "标准")
        let custom = try XCTUnwrap(items.first { $0.title == "自定义" })
        XCTAssertFalse(custom.enabled)
        for title in ["标准", "大", "特大"] {
            XCTAssertEqual(try XCTUnwrap(items.first { $0.title == title }).state, .off)
        }
        try await settle(controller.view)
        XCTAssertEqual(store.double(forKey: "floatingSourceTextSize"), 0)
        XCTAssertEqual(store.double(forKey: "floatingTranslationTextSize"), 0)
        let reopened = FloatingSubtitlePreferences(store: store)
        XCTAssertEqual(reopened.sourceTextSize, 21)
        XCTAssertEqual(reopened.translationTextSize, 24)
        XCTAssertEqual(try XCTUnwrap(inspectSizeMenu(in: controller.view).first { $0.title == "标准" }).state, .on)
    }

    func testHostedAccessibilitySeparatesLanguageLabelAndHidesUnselectedCaption() async throws {
        try enableHostAccessibility()
        let (model, store) = try fixture()
        let preferences = FloatingSubtitlePreferences(store: store)
        model.loadPresentationForTesting(phase: .recording, evidence: [
            TranscriptSegment(startTime: 0, endTime: 2, english: "El agua está fría.", chinese: "水很冷。", sourceLanguage: "es")
        ])
        let (window, controller) = host(floating(model, store: store))
        defer { window.close() }
        try await resizeAndSettle(window, view: controller.view)
        for (mode, visible, hidden) in [(FloatingSubtitleDisplayMode.translationOnly, "水很冷。", "El agua está fría."),
                                        (.sourceOnly, "El agua está fría.", "水很冷。") ] {
            preferences.displayMode = mode
            try await settle(controller.view)
            let nodes = accessibleNodes(in: controller.view)
            let text = nodes.flatMap { node in
                [node.value("accessibilityLabel") as? String, node.value("accessibilityValue") as? String].compactMap { $0 }
            }
            XCTAssertTrue(text.contains("语种：西班牙语"), "A separate nonselectable language element must be exposed; actual=\(text)")
            XCTAssertTrue(text.contains(visible), "The visible caption must be exposed independently")
            XCTAssertFalse(text.contains(hidden), "The hidden caption must not be exposed")
        }
    }

    func testSettingsSliderAccessibilityValuesMatchVisibleNumbers() async throws {
        try enableHostAccessibility()
        let (model, store) = try fixture()
        let preferences = FloatingSubtitlePreferences(store: store)
        preferences.sourceTextSizeBinding.wrappedValue = 21
        preferences.translationTextSizeBinding.wrappedValue = 36
        preferences.backgroundOpacityBinding.wrappedValue = 0.75
        model.previewTranslationEnabled = false
        let (window, controller) = host(AnyView(ClassroomSettingsView().environmentObject(model).defaultAppStorage(store)),
                                      width: 520, height: 1080)
        defer { window.close() }
        try await settle(controller.view)
        let nodes = accessibleNodes(in: controller.view)
        for (title, value) in [("原文字号", "21 pt"), ("译文字号", "36 pt"), ("背景不透明度", "75%")] {
            let matches = nodes.filter { $0.value("accessibilityIdentifier") as? String == "floating-\(title)" }
            print("FLOATING_SLIDER_AX \(title) \(matches.map { [String(describing: $0.value("accessibilityRole")), String(describing: $0.value("accessibilityValue")), String(describing: $0.value("accessibilityValueDescription"))] })")
            let node = try XCTUnwrap(matches.first { $0.value("accessibilityRole") as? String == "AXSlider" })
            XCTAssertEqual(node.value("accessibilityValueDescription") as? String, value)
            XCTAssertFalse(nodes.contains { $0.value("accessibilityLabel") as? String == value },
                           "The visible number must not become a duplicate accessibility text element")
        }
        let labels = nodes.flatMap { [$0.value("accessibilityLabel") as? String, $0.value("accessibilityValue") as? String].compactMap { $0 } }
        XCTAssertTrue(labels.contains("“仅中文译文”在译文可用前显示原文。"))
        try capture(controller.view, name: "settings-preview-off-custom")
        try setSlider("原文字号", to: 30, in: controller.view)
        try await settle(controller.view)
        XCTAssertEqual(store.double(forKey: "floatingSourceTextSize"), 30)
        XCTAssertEqual(store.double(forKey: "floatingTranslationTextSize"), 36)
        XCTAssertEqual(store.double(forKey: "floatingBackgroundOpacity"), 0.75)
        try setSlider("译文字号", to: 32, in: controller.view)
        try await settle(controller.view)
        XCTAssertEqual(store.double(forKey: "floatingSourceTextSize"), 30)
        XCTAssertEqual(store.double(forKey: "floatingTranslationTextSize"), 32)
        try setSlider("背景不透明度", to: 0.9, in: controller.view)
        try await settle(controller.view)
        XCTAssertEqual(store.double(forKey: "floatingBackgroundOpacity"), 0.9, accuracy: 0.001)
        XCTAssertEqual(store.double(forKey: "floatingSourceTextSize"), 30)
        XCTAssertEqual(store.double(forKey: "floatingTranslationTextSize"), 32)
        for (title, expected) in [("原文字号", "30 pt"), ("译文字号", "32 pt"), ("背景不透明度", "90%")] {
            let node = try XCTUnwrap(accessibleNodes(in: controller.view).first {
                $0.value("accessibilityIdentifier") as? String == "floating-\(title)"
                    && $0.value("accessibilityRole") as? String == "AXSlider"
            })
            XCTAssertEqual(node.value("accessibilityValueDescription") as? String, expected)
        }
    }

    func testHostedModeLanguageAndSizeSwitchesKeepWindowHeightAndProduceScreenshots() async throws {
        let (model, store) = try fixture()
        let preferences = FloatingSubtitlePreferences(store: store)
        let english = TranscriptSegment(startTime: 0, endTime: 2, english: "The water is cold.", chinese: "水很冷。")
        model.loadPresentationForTesting(phase: .recording, evidence: [english], preview: english.english)
        let (window, controller) = host(floating(model, store: store))
        defer { window.close() }
        try await resizeAndSettle(window, view: controller.view)
        let contentHeight = controller.view.bounds.height
        let frameHeight = window.frame.height
        let captions = [
            TranscriptSegment(startTime: 0, endTime: 2, english: "El agua está fría.", chinese: "水很冷。", sourceLanguage: "es"),
            TranscriptSegment(startTime: 0, endTime: 2, english: "這本書放在桌上。", chinese: "这本书在桌上。", sourceLanguage: "zh"),
            TranscriptSegment(startTime: 0, endTime: 2, english: "啲水好凍。", chinese: "水很冷。", sourceLanguage: "yue")
        ]
        var lightBodies: [String: Data] = [:]
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            controller.rootView = floating(model, store: store, dark: dark)
            for caption in captions {
                model.loadPresentationForTesting(phase: .recording, evidence: [caption])
                for mode in FloatingSubtitleDisplayMode.allCases {
                    preferences.displayMode = mode
                    try await resizeAndSettle(window, view: controller.view)
                    XCTAssertEqual(controller.view.bounds.height, contentHeight, accuracy: 0.5)
                    XCTAssertEqual(window.frame.height, frameHeight, accuracy: 0.5)
                    let image = try bitmap(controller.view)
                    let scale = CGFloat(image.pixelsHigh) / controller.view.bounds.height
                    let sourceVisible = mode == .sourceOnly || (mode == .bilingual && caption.sourceLanguage != "zh")
                    let translationVisible = mode != .sourceOnly
                    XCTAssertEqual(hasVisibleText(image, scale: scale, rows: 50..<130), sourceVisible,
                                   "The mounted source slot must actually follow the display mode")
                    XCTAssertEqual(hasVisibleText(image, scale: scale, rows: 160..<280), translationVisible,
                                   "The mounted translation slot must actually follow the display mode")
                    // Ignore the legacy native menu in the header. Caption bodies,
                    // including grey language metadata, must stay readable in either host appearance.
                    let bodyStart = Int(70 * scale) * image.bytesPerRow
                    let body = try pixels(image).subdata(in: bodyStart..<(image.bytesPerRow * image.pixelsHigh))
                    let key = "\(caption.sourceLanguage!)-\(mode.rawValue)"
                    if dark {
                        XCTAssertTrue(body == lightBodies[key], "The dark caption surface needs the same readable labels in a light host")
                    } else {
                        lightBodies[key] = body
                    }
                    try capture(controller.view, name: "floating-\(caption.sourceLanguage!)-\(mode.rawValue)-\(dark ? "dark" : "light")")
                }
            }
        }
        for size in [16.0, 40.0] {
            preferences.sourceTextSize = size
            preferences.translationTextSize = 56 - size
            for mode in FloatingSubtitleDisplayMode.allCases {
                preferences.displayMode = mode
                model.loadPresentationForTesting(phase: .recording, evidence: [english], preview: String(repeating: english.english + " ", count: 20))
                try await resizeAndSettle(window, view: controller.view)
                XCTAssertEqual(controller.view.bounds.height, contentHeight, accuracy: 0.5)
                XCTAssertEqual(window.frame.height, frameHeight, accuracy: 0.5)
            }
        }
        print("FLOATING_DISPLAY_GEOMETRY content=\(contentHeight) frame=\(frameHeight) modes/languages/font-extremes stable")
    }

    func testEnglishDefaultPixelsMatchFrozenLegacyViewAtEveryPresetInBothAppearances() async throws {
        let (model, store) = try fixture()
        model.loadPresentationForTesting(phase: .recording, evidence: [],
                                        preview: "Compare the quantities and keep the stated conditions with the formula.")
        let (window, controller) = host(AnyView(EmptyView()))
        defer { window.close() }
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for preset in [24.0, 28.0, 32.0] {
                store.set(preset, forKey: "floatingTextSize")
                controller.rootView = AnyView(LegacyEnglishFloatingSubtitleView(model: model)
                    .defaultAppStorage(store).environment(\.colorScheme, dark ? .dark : .light))
                try await resizeAndSettle(window, view: controller.view)
                let legacy = try bitmap(controller.view)
                let legacyPixels = try pixels(legacy)
                let legacySize = controller.view.bounds.size
                let originalIsOpaque = window.isOpaque
                let originalBackground = window.backgroundColor
                controller.rootView = floating(model, store: store, dark: dark)
                try await resizeAndSettle(window, view: controller.view)
                let current = try bitmap(controller.view)
                XCTAssertEqual(controller.view.bounds.size, legacySize)
                XCTAssertEqual(window.isOpaque, originalIsOpaque)
                XCTAssertEqual(window.backgroundColor, originalBackground)
                XCTAssertEqual(current.pixelsWide, legacy.pixelsWide)
                XCTAssertEqual(current.pixelsHigh, legacy.pixelsHigh)
                XCTAssertTrue(try pixels(current) == legacyPixels,
                              "Every rendered pixel must match 1a59adc's English view: \(preset) / dark=\(dark)")
                try capture(controller.view, name: "english-default-\(Int(preset))-\(dark ? "dark" : "light")")
                print("FLOATING_ENGLISH_PIXELS preset=\(preset) dark=\(dark) identical=\(try pixels(current) == legacyPixels) size=\(current.pixelsWide)x\(current.pixelsHigh)")
            }
        }
    }

    func testHostedBackgroundOpacityLeavesTextOpaqueAndWindowTransparent() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let model = fixture.model
        let store = fixture.defaults
        let preferences = FloatingSubtitlePreferences(store: store)
        model.loadPresentationForTesting(phase: .recording, evidence: [], preview: "The water is cold.")
        let windowController = FloatingSubtitleWindowController(defaults: store)
        let window = windowController.prepareWindow(model: model)
        defer { windowController.close() }
        let view = try XCTUnwrap(window.contentView as? NSHostingView<AnyView>)
        try await settle(view)
        // The production controller owns a plain NSPanel. Count shadow refreshes
        // on the concrete production configuration with a separate hidden probe.
        let shadowWindow = ShadowTrackingWindow(contentRect: window.contentRect(forFrameRect: window.frame),
                                               styleMask: [.titled], backing: .buffered, defer: false)
        shadowWindow.isReleasedWhenClosed = false
        defer { shadowWindow.close() }
        let shadowConfiguration = FloatingSubtitleWindowConfiguration(window: shadowWindow)
        shadowConfiguration.apply(.init())
        let originalIsOpaque = window.isOpaque
        let originalBackground = window.backgroundColor
        let originalHasShadow = window.hasShadow
        let initial = try bitmap(view)
        XCTAssertEqual(try XCTUnwrap(initial.colorAt(x: 2, y: 2)).alphaComponent, 1, accuracy: 0.02)
        let shadowInvalidations = shadowWindow.shadowInvalidations
        preferences.backgroundOpacity = 0.7
        shadowConfiguration.apply(.init(backgroundOpacity: preferences.backgroundOpacity))
        try await settle(view)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertEqual(window.hasShadow, originalHasShadow)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(shadowWindow.isVisible)
        XCTAssertTrue(windowController.panel === window)
        XCTAssertTrue(window.contentView === view)
        let translucent = try bitmap(view)
        XCTAssertEqual(try XCTUnwrap(translucent.colorAt(x: 2, y: 2)).alphaComponent, 0.7, accuracy: 0.02)
        XCTAssertGreaterThan(shadowWindow.shadowInvalidations, shadowInvalidations)
        var opaqueWhitePixels = 0
        for y in stride(from: 30, to: translucent.pixelsHigh - 30, by: 2) {
            for x in stride(from: 30, to: translucent.pixelsWide - 30, by: 2) {
                guard let color = translucent.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.98 && color.greenComponent > 0.98 && color.blueComponent > 0.98
                    && color.alphaComponent > 0.98 { opaqueWhitePixels += 1 }
            }
        }
        XCTAssertGreaterThan(opaqueWhitePixels, 0, "Only the background may fade; caption glyphs must remain opaque")
        try captureOpacity(view, directory: fixture.ddOverlay)
        let translucentShadowInvalidations = shadowWindow.shadowInvalidations
        preferences.backgroundOpacity = 1
        shadowConfiguration.apply(.init(backgroundOpacity: preferences.backgroundOpacity))
        try await settle(view)
        XCTAssertEqual(window.isOpaque, originalIsOpaque)
        XCTAssertEqual(window.backgroundColor, originalBackground)
        XCTAssertEqual(window.hasShadow, originalHasShadow)
        XCTAssertGreaterThan(shadowWindow.shadowInvalidations, translucentShadowInvalidations)
        XCTAssertTrue(try pixels(bitmap(view)) == pixels(initial), "Restoring 100% must restore the original pixels")
    }

    private func captureOpacity(_ view: NSView, directory: URL) throws {
        let png = try XCTUnwrap(bitmap(view).representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000, "A flat/unrendered image is not review evidence")
        let screenshots = directory.appendingPathComponent("display-options/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        try png.write(to: screenshots.appendingPathComponent("floating-opacity-70.png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "floating-opacity-70"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHostedIndependentSizesUpdateTheActualSubtitlePixels() async throws {
        let (model, store) = try fixture()
        model.loadPresentationForTesting(phase: .recording, evidence: [], preview: "The water is cold.")
        let preferences = FloatingSubtitlePreferences(store: store)
        let (window, controller) = host(floating(model, store: store))
        defer { window.close() }
        try await resizeAndSettle(window, view: controller.view)
        let initial = try bitmap(controller.view)
        preferences.sourceTextSize = 36
        try await settle(controller.view)
        let sourceChanged = try bitmap(controller.view)
        XCTAssertNotEqual(try rowPixels(sourceChanged, view: controller.view, rows: 50..<140),
                          try rowPixels(initial, view: controller.view, rows: 50..<140))
        XCTAssertEqual(try rowPixels(sourceChanged, view: controller.view, rows: 150..<300),
                       try rowPixels(initial, view: controller.view, rows: 150..<300))
        preferences.translationTextSize = 40
        try await settle(controller.view)
        let translationChanged = try bitmap(controller.view)
        XCTAssertNotEqual(try rowPixels(translationChanged, view: controller.view, rows: 150..<300),
                          try rowPixels(sourceChanged, view: controller.view, rows: 150..<300))
        XCTAssertEqual(try rowPixels(translationChanged, view: controller.view, rows: 50..<140),
                       try rowPixels(sourceChanged, view: controller.view, rows: 50..<140))
        XCTAssertEqual(preferences.sourceTextSize, 36)
    }

    func testExistingSettingsWindowShowsDisplayControlsInBothAppearances() async throws {
        let (model, store) = try fixture()
        for dark in [false, true] {
            let root = AnyView(ClassroomSettingsView().environmentObject(model).defaultAppStorage(store)
                .environment(\.colorScheme, dark ? .dark : .light))
            let (window, controller) = host(root, width: 520, height: 1040, dark: dark)
            defer { window.close() }
            try await settle(controller.view)
            for key in ["floatingSourceTextSize", "floatingTranslationTextSize", "floatingDisplayMode", "floatingBackgroundOpacity"] {
                XCTAssertNil(store.object(forKey: key), "Opening Settings must not migrate or write \(key)")
            }
            try capture(controller.view, name: "settings-\(dark ? "dark" : "light")")
        }
    }

    func testLongCaptionScrollContainersSurviveModeSwitches() async throws {
        let (model, store) = try fixture()
        let preferences = FloatingSubtitlePreferences(store: store)
        model.loadPresentationForTesting(phase: .recording, evidence: [], preview: "Initial sentence.")
        let (window, controller) = host(floating(model, store: store))
        defer { window.close() }
        try await resizeAndSettle(window, view: controller.view)
        model.receiveLivePreviewForTesting(String(repeating: "A longer synthetic sentence for scrolling. ", count: 40),
                                          chinese: String(repeating: "这是用于检查滚动位置的长字幕。", count: 40))
        try await settle(controller.view)
        func scrollViews() -> [NSScrollView] {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            return descendants(controller.view).compactMap { $0 as? NSScrollView }
                .filter { [88.0, 138.0].contains(Double($0.bounds.height)) }
                .sorted { $0.bounds.height < $1.bounds.height }
        }
        let original = scrollViews()
        XCTAssertEqual(original.count, 2, "Both real reading containers must be mounted")
        XCTAssertTrue(original.contains { $0.contentView.bounds.origin.y > 0 }, "The test must exercise a genuinely scrolled caption")
        for mode in [FloatingSubtitleDisplayMode.translationOnly, .bilingual, .sourceOnly, .bilingual] {
            preferences.displayMode = mode
            try await settle(controller.view)
            let current = scrollViews()
            XCTAssertEqual(current.count, original.count)
            for (index, scroll) in current.enumerated() where original.indices.contains(index) {
                XCTAssertTrue(scroll === original[index], "Mode switching must preserve each scroll container")
                if (index == 0 && mode != .translationOnly) || (index == 1 && mode != .sourceOnly) {
                    try assertScrolledToBottom(scroll)
                }
            }
        }
    }

    private func fixture() throws -> (AppModel, UserDefaults) {
        XCTAssertTrue(AppRuntimeEnvironment.isUnitTesting)
        if let root = ProcessInfo.processInfo.environment["LIVELINGO_TEST_WORKSPACE"] {
            let temporary = FileManager.default.temporaryDirectory.path
            guard temporary.hasPrefix(root + "/"), NSHomeDirectory().hasPrefix(root + "/") else {
                throw NSError(domain: "FloatingSubtitleDisplayTests.PathIsolation", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Test paths escaped the requested workspace: \(temporary)"])
            }
            print("FLOATING_TEST_PATH_ISOLATION temporary=\(temporary) home=\(NSHomeDirectory())")
        }
        let (store, _) = try defaults()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloatingSubtitleDisplay-\(UUID().uuidString)",
                                                                                     isDirectory: true)
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
                                       observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
            XCTFail("Display tests must never invoke a generator")
            throw CancellationError()
        }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
                             backgroundServices: false, scheduledNotes: false, defaults: store)
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
        return (model, store)
    }

    private func select(_ model: AppModel, mode: FloatingSubtitleDisplayMode) -> FloatingSubtitlePresentation {
        model.floatingSubtitlePresentation(mode: mode)
    }

    private func floating(_ model: AppModel, store: UserDefaults, dark: Bool = true) -> AnyView {
        AnyView(FloatingSubtitleView().environmentObject(model).defaultAppStorage(store)
            .environment(\.colorScheme, dark ? .dark : .light))
    }

    private func host(_ root: AnyView, width: CGFloat = 640, height: CGFloat = 390,
                      dark: Bool = true) -> (NSWindow, NSHostingController<AnyView>) {
        let controller = NSHostingController(rootView: root)
        let window = ShadowTrackingWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
        window.makeKeyAndOrderFront(nil)
        return (window, controller)
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private func resizeAndSettle(_ window: NSWindow, view: NSView) async throws {
        try await settle(view)
        window.setContentSize(view.fittingSize)
        try await settle(view)
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func pixels(_ bitmap: NSBitmapImageRep) throws -> Data {
        Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func rowPixels(_ image: NSBitmapImageRep, view: NSView, rows: Range<Int>) throws -> Data {
        let scale = Double(image.pixelsHigh) / Double(view.bounds.height)
        let start = Int(Double(rows.lowerBound) * scale) * image.bytesPerRow
        let end = Int(Double(rows.upperBound) * scale) * image.bytesPerRow
        return try pixels(image).subdata(in: start..<end)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func subtitleScrollViews(_ view: NSView) -> [NSScrollView] {
        descendants(view).compactMap { $0 as? NSScrollView }
            .filter { [88.0, 138.0].contains(Double($0.bounds.height)) }
            .sorted { $0.bounds.height < $1.bounds.height }
    }

    private func assertScrolledToBottom(_ scroll: NSScrollView, file: StaticString = #filePath, line: UInt = #line) throws {
        let document = try XCTUnwrap(scroll.documentView, file: file, line: line)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height, file: file, line: line)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.bounds.maxY, accuracy: 1, file: file, line: line)
    }

    private struct SizeMenuItem {
        let title: String
        let enabled: Bool
        let state: NSControl.StateValue
    }

    @MainActor private final class MenuInspection: NSObject {
        var menu: NSMenu?
        var items: [SizeMenuItem]?
        var performedSelection = false
        var timedOut = false

        @objc func menuBegan(_ notification: NSNotification) {
            menu = notification.object as? NSMenu
        }
    }

    private func inspectSizeMenu(in view: NSView, selecting title: String? = nil) throws -> [SizeMenuItem] {
        let button = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first {
            String(describing: type(of: $0)) == "SwiftUIPopupButton"
        })
        let inspection = MenuInspection()
        NotificationCenter.default.addObserver(inspection, selector: #selector(MenuInspection.menuBegan(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        defer { NotificationCenter.default.removeObserver(inspection) }
        let deadline = Date().addingTimeInterval(3)
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                func sizeMenu(_ menu: NSMenu) -> NSMenu? {
                    if menu.indexOfItem(withTitle: "标准") >= 0 { return menu }
                    return menu.items.compactMap(\.submenu).compactMap(sizeMenu).first
                }
                if inspection.items == nil, let root = inspection.menu, let menu = sizeMenu(root) {
                    func items(_ menu: NSMenu) -> [SizeMenuItem] {
                        menu.items.flatMap { item in
                            [SizeMenuItem(title: item.title, enabled: item.isEnabled, state: item.state)]
                                + (item.submenu.map(items) ?? [])
                        }
                    }
                    inspection.items = items(root)
                    if let title {
                        let index = menu.indexOfItem(withTitle: title)
                        if index >= 0 {
                            menu.performActionForItem(at: index)
                            inspection.performedSelection = true
                        }
                    }
                    root.cancelTracking()
                } else if Date() >= deadline {
                    inspection.timedOut = true
                    inspection.menu?.cancelTracking()
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                        context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                        NSApp.postEvent(event, atStart: true)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        button.performClick(nil)
        XCTAssertFalse(inspection.timedOut, "The real size popup must expose its menu during native tracking")
        if title != nil { XCTAssertTrue(inspection.performedSelection, "The real native menu action must execute") }
        return try XCTUnwrap(inspection.items)
    }

    private struct AccessibleNode {
        let object: NSObject
        func value(_ name: String) -> Any? {
            guard object.responds(to: NSSelectorFromString(name)) else { return nil }
            return object.value(forKey: name)
        }
    }

    private func setSlider(_ title: String, to value: Double, in view: NSView) throws {
        let node = try XCTUnwrap(accessibleNodes(in: view).first {
            $0.value("accessibilityIdentifier") as? String == "floating-\(title)"
                && $0.value("accessibilityRole") as? String == "AXSlider"
        })
        XCTAssertTrue(node.object.responds(to: NSSelectorFromString("setAccessibilityValue:")))
        node.object.setValue(value, forKey: "accessibilityValue")
    }

    private func enableHostAccessibility() throws {
        // Activate SwiftUI's lazy accessibility tree in this test process only.
        // No AX trust request, VoiceOver launch or system preference change.
        let getter = NSSelectorFromString("accessibilityEnhancedUserInterfaceAttribute")
        let setter = NSSelectorFromString("setAccessibilityEnhancedUserInterface:")
        XCTAssertTrue(NSApp.responds(to: getter) && NSApp.responds(to: setter))
        let original = try XCTUnwrap(NSApp.perform(getter)?.takeUnretainedValue() as? NSNumber)
        NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        addTeardownBlock { @MainActor in
            NSApp.setValue(original, forKey: "accessibilityEnhancedUserInterface")
        }
    }

    private func accessibleNodes(in view: NSView) -> [AccessibleNode] {
        NSAccessibility.post(element: view, notification: .layoutChanged)
        var visited = Set<ObjectIdentifier>()
        func nodes(_ value: Any, depth: Int = 0) -> [AccessibleNode] {
            guard depth < 24, let object = value as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            let node = AccessibleNode(object: object)
            return [node] + ((node.value("accessibilityChildren") as? [Any]) ?? []).flatMap { nodes($0, depth: depth + 1) }
        }
        return descendants(view).flatMap { nodes($0) }
    }

    private func hasVisibleText(_ bitmap: NSBitmapImageRep, scale: CGFloat, rows: Range<Int>) -> Bool {
        for y in stride(from: Int(CGFloat(rows.lowerBound) * scale), to: Int(CGFloat(rows.upperBound) * scale), by: 2) {
            for x in stride(from: Int(22 * scale), to: bitmap.pixelsWide - Int(22 * scale), by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.3 { return true }
            }
        }
        return false
    }

    private func capture(_ view: NSView, name: String) throws {
        let png = try XCTUnwrap(bitmap(view).representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000, "A flat/unrendered image is not review evidence")
        let directory = artifacts.appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private final class ShadowTrackingWindow: NSWindow {
    private(set) var shadowInvalidations = 0
    override func invalidateShadow() {
        shadowInvalidations += 1
        super.invalidateShadow()
    }
}

/// Frozen English rendering from 1a59adc. Keep this independent of new preferences
/// and layout code so the pixel check catches changes in font, color and geometry.
private struct LegacyEnglishFloatingSubtitleView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var stream: LiveCaptionState
    @AppStorage("floatingTextSize") private var textSize = 24.0

    init(model: AppModel) {
        self.model = model
        stream = model.captionStream
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Circle().fill(model.isRecording ? ClassroomPalette.recording : .gray).frame(width: 8, height: 8)
                Text(model.isRecording ? "实时字幕 · 初译" : model.phaseLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(white: 0.8))
                Spacer()
                Menu {
                    Picker("悬浮字幕字号", selection: $textSize) {
                        Text("标准").tag(24.0)
                        Text("大").tag(28.0)
                        Text("特大").tag(32.0)
                    }
                } label: { Image(systemName: "textformat.size").foregroundStyle(.white) }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("悬浮字幕字号")
            }
            subtitle(model.previewEnglishDisplay, size: textSize - 3, weight: .regular,
                     color: Color(white: 0.9), height: 88)
            subtitle(model.previewChineseDisplay, size: textSize, weight: .medium, color: .white, height: 138)
        }
        .padding(22)
        .frame(minWidth: 640, maxWidth: 640, alignment: .leading)
        .background(Color(white: 0.08))
        .preferredColorScheme(.dark)
    }

    private func subtitle(_ text: String, size: Double, weight: Font.Weight, color: Color,
                          height: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text)
                        .font(.system(size: size, weight: weight))
                        .foregroundStyle(color)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("tail")
                }
            }
            .frame(height: height)
            .onChange(of: text) { proxy.scrollTo("tail", anchor: .bottom) }
        }
    }
}
