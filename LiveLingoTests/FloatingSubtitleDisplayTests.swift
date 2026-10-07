import AppKit
import SwiftUI
import XCTest
@testable import LiveLingo

/// Synthetic hosted views only; no capture, model, translation service or real preferences.
@MainActor
final class FloatingSubtitleDisplayTests: XCTestCase {
    private let artifacts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("work/display-options", isDirectory: true)

    private func defaults() throws -> (UserDefaults, String) {
        let suite = "FloatingSubtitleDisplay-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
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
        for preset in [24.0, 28.0, 32.0] {
            store.set(preset, forKey: "floatingTextSize")
            let preferences = FloatingSubtitlePreferences(store: store)
            XCTAssertEqual(preferences.sourceTextSize, preset - 3)
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
        for preset in [24.0, 28.0, 32.0] {
            preferences.sourceTextSize = 16
            preferences.translationTextSize = 40
            preferences.sizePreset = preset
            let reopened = FloatingSubtitlePreferences(store: try XCTUnwrap(UserDefaults(suiteName: suite)))
            XCTAssertEqual(reopened.sizePreset, preset)
            XCTAssertEqual(reopened.sourceTextSize, preset - 3)
            XCTAssertEqual(reopened.translationTextSize, preset)
        }
    }

    func testModeAndBackgroundOpacityPersist() throws {
        let (store, suite) = try defaults()
        let preferences = FloatingSubtitlePreferences(store: store)
        for mode in FloatingSubtitleDisplayMode.allCases {
            preferences.displayMode = mode
            preferences.backgroundOpacity = 0.65
            let reopened = FloatingSubtitlePreferences(store: try XCTUnwrap(UserDefaults(suiteName: suite)))
            XCTAssertEqual(reopened.displayMode, mode)
            XCTAssertEqual(reopened.backgroundOpacity, 0.65)
            XCTAssertEqual(store.string(forKey: "floatingDisplayMode"), mode.rawValue)
            XCTAssertEqual(store.double(forKey: "floatingBackgroundOpacity"), 0.65)
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
        XCTAssertEqual(preferences.backgroundOpacity, 0.5)
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
        XCTAssertEqual(translated.translation, bilingual.translation)
        let original = FloatingSubtitlePresentation(sourceText: source, translatedText: translation,
                                                     caption: nil, mode: .sourceOnly)
        XCTAssertEqual(original.source, bilingual.source)
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
                for line in [presentation.source, presentation.translation].compactMap({ $0 }) {
                    XCTAssertFalse(line.text.contains(label))
                }
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
        var pending = TranscriptSegment(startTime: 0, endTime: 2, english: "這裡很冷。", sourceLanguage: "zh")
        var translating = pending
        translating.beginTranslation()
        var failed = pending
        failed.failTranslation("synthetic failure")
        pending.completeTranslation("这里好冷。")
        for caption in [pending, translating, failed] {
            model.loadPresentationForTesting(phase: .recording, evidence: [caption])
            for mode in FloatingSubtitleDisplayMode.allCases {
                let presentation = select(model, mode: mode)
                XCTAssertEqual([presentation.source, presentation.translation].compactMap { $0?.text }, ["这里很冷。"])
            }
        }
    }

    func testInitialTranslationMarkersAndStatusTextArePreserved() throws {
        let (model, _) = try fixture()
        model.loadPresentationForTesting(phase: .recording, evidence: [], preview: "The water is cold.")
        model.receiveLivePreviewForTesting("The water is cold.", chinese: "水很冷。")
        XCTAssertEqual(select(model, mode: .translationOnly).translation?.text, model.previewChineseDisplay)
        if model.supportsPreviewTranslation {
            XCTAssertEqual(select(model, mode: .translationOnly).translation?.text, "初译 · 水很冷。")
        }
        model.previewTranslationEnabled = false
        XCTAssertEqual(select(model, mode: .translationOnly).translation?.text, "初译已关闭")
        var failed = TranscriptSegment(startTime: 0, endTime: 2, english: "El agua está fría.", sourceLanguage: "es")
        failed.failTranslation("synthetic failure")
        model.loadPresentationForTesting(phase: .recording, evidence: [failed])
        XCTAssertEqual(select(model, mode: .translationOnly).translation?.text, "本段翻译未完成")
        XCTAssertEqual(select(model, mode: .translationOnly).translation?.languageName, "西班牙语")
        XCTAssertEqual(select(model, mode: .sourceOnly).source?.text, "El agua está fría.")
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
                let expectedCount = mode == .bilingual && !caption.isSourceOnly ? 2 : 1
                XCTAssertEqual(lines.count, expectedCount, "\(language.code) / \(mode)")
                XCTAssertEqual(lines.filter { $0.languageName != nil }.count, language.code == "en" ? 0 : 1)
            }
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
                    let presentation = select(model, mode: mode)
                    XCTAssertEqual(hasVisibleText(image, scale: scale, rows: 50..<130), presentation.source != nil,
                                   "The mounted source slot must actually follow the display mode")
                    XCTAssertEqual(hasVisibleText(image, scale: scale, rows: 160..<280), presentation.translation != nil,
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
        let (model, store) = try fixture()
        let preferences = FloatingSubtitlePreferences(store: store)
        model.loadPresentationForTesting(phase: .recording, evidence: [], preview: "The water is cold.")
        let (window, controller) = host(floating(model, store: store))
        defer { window.close() }
        try await resizeAndSettle(window, view: controller.view)
        let originalIsOpaque = window.isOpaque
        let originalBackground = window.backgroundColor
        let initial = try bitmap(controller.view)
        XCTAssertEqual(try XCTUnwrap(initial.colorAt(x: 2, y: 2)).alphaComponent, 1, accuracy: 0.02)
        preferences.backgroundOpacity = 0.5
        try await settle(controller.view)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        let translucent = try bitmap(controller.view)
        XCTAssertEqual(try XCTUnwrap(translucent.colorAt(x: 2, y: 2)).alphaComponent, 0.5, accuracy: 0.02)
        var opaqueWhitePixels = 0
        for y in stride(from: 30, to: translucent.pixelsHigh - 30, by: 2) {
            for x in stride(from: 30, to: translucent.pixelsWide - 30, by: 2) {
                guard let color = translucent.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.98 && color.greenComponent > 0.98 && color.blueComponent > 0.98
                    && color.alphaComponent > 0.98 { opaqueWhitePixels += 1 }
            }
        }
        XCTAssertGreaterThan(opaqueWhitePixels, 0, "Only the background may fade; caption glyphs must remain opaque")
        try capture(controller.view, name: "floating-opacity-50")
        preferences.backgroundOpacity = 1
        try await settle(controller.view)
        XCTAssertEqual(window.isOpaque, originalIsOpaque)
        XCTAssertEqual(window.backgroundColor, originalBackground)
        XCTAssertTrue(try pixels(bitmap(controller.view)) == pixels(initial), "Restoring 100% must restore the original pixels")
    }

    func testHostedIndependentSizesUpdateTheActualSubtitlePixels() async throws {
        let (model, store) = try fixture()
        model.loadPresentationForTesting(phase: .recording, evidence: [], preview: "The water is cold.")
        let preferences = FloatingSubtitlePreferences(store: store)
        let (window, controller) = host(floating(model, store: store))
        defer { window.close() }
        try await resizeAndSettle(window, view: controller.view)
        let initial = try pixels(bitmap(controller.view))
        preferences.sourceTextSize = 36
        try await settle(controller.view)
        let sourceChanged = try pixels(bitmap(controller.view))
        XCTAssertNotEqual(sourceChanged, initial)
        preferences.translationTextSize = 40
        try await settle(controller.view)
        XCTAssertNotEqual(try pixels(bitmap(controller.view)), sourceChanged)
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
        let positions = original.map { $0.contentView.bounds.origin }
        XCTAssertTrue(positions.contains { $0.y > 0 }, "The test must exercise a genuinely scrolled caption")
        for mode in [FloatingSubtitleDisplayMode.translationOnly, .bilingual, .sourceOnly, .bilingual] {
            preferences.displayMode = mode
            try await settle(controller.view)
            let current = scrollViews()
            XCTAssertEqual(current.count, original.count)
            for (index, scroll) in current.enumerated() where original.indices.contains(index) {
                XCTAssertTrue(scroll === original[index], "Mode switching must preserve each scroll container")
                XCTAssertEqual(scroll.contentView.bounds.origin.y, positions[index].y, accuracy: 0.5)
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
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let queue = LearningReviewQueue(journalURL: artifacts.appendingPathComponent("fixtures/\(UUID().uuidString)/queue.json"),
                                       observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
            XCTFail("Display tests must never invoke a generator")
            throw CancellationError()
        }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
                             backgroundServices: false, scheduledNotes: false, defaults: store)
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
        }
        return (model, store)
    }

    private func select(_ model: AppModel, mode: FloatingSubtitleDisplayMode) -> FloatingSubtitlePresentation {
        FloatingSubtitlePresentation(sourceText: model.previewEnglishDisplay, translatedText: model.previewChineseDisplay,
                                     caption: model.nonEnglishPreviewPresentation, mode: mode)
    }

    private func floating(_ model: AppModel, store: UserDefaults, dark: Bool = true) -> AnyView {
        AnyView(FloatingSubtitleView().environmentObject(model).defaultAppStorage(store)
            .environment(\.colorScheme, dark ? .dark : .light))
    }

    private func host(_ root: AnyView, width: CGFloat = 640, height: CGFloat = 390,
                      dark: Bool = true) -> (NSWindow, NSHostingController<AnyView>) {
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
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
