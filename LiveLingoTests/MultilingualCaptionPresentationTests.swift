import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import LiveLingo

final class MultilingualCaptionPresentationTests: XCTestCase {
    private func caption(_ language: String? = nil, source: String? = nil,
                         chinese: String = "水很冷。") -> TranscriptSegment {
        TranscriptSegment(startTime: 0, endTime: 2,
                          english: source ?? (language == "zh" ? "這本書放在桌上。" : "The water is cold."),
                          chinese: chinese, sourceLanguage: language)
    }

    func testSimplifiedChineseNamesUseInterfaceLanguage() {
        let expected = ["zh": "中文", "yue": "粤语", "es": "西班牙语", "fr": "法语",
                        "ru": "俄语", "ar": "阿拉伯语", "ja": "日语", "ko": "韩语"]
        for (code, name) in expected {
            XCTAssertEqual(CaptionLanguageNames.name(for: code), name)
        }
    }

    func testEverySupportedLanguageUsesTheCentralChineseName() throws {
        for language in SpokenLanguage.all {
            let name = try XCTUnwrap(CaptionLanguageNames.name(for: language.code))
            XCTAssertEqual(language.chineseName, name, language.code)
            XCTAssertNotEqual(name, language.code)
            XCTAssertNotEqual(name, language.qwenLabel)
            XCTAssertTrue(name.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) })
        }
    }

    func testSimplifiedChineseNameFallsBackWhenTheTableHasNoEntry() {
        // English intentionally has no caption-table entry, but compatibility callers need its name.
        XCTAssertEqual(CaptionLanguageNames.name(for: "en"), "英语")
        XCTAssertNil(CaptionPresentation(caption("en")).languageName)
    }

    func testOtherInterfaceLocalesUseLiteralLocalizedNamesRatherThanAutonyms() {
        XCTAssertEqual(CaptionLanguageNames.name(for: "es", locale: Locale(identifier: "en")), "Spanish")
        for (identifier, expected) in [("zh-Hant-TW", "日文"), ("fr", "japonais")] {
            let name = CaptionLanguageNames.name(for: "ja", locale: Locale(identifier: identifier))
            XCTAssertEqual(name, expected)
            XCTAssertNotEqual(name, "日本語")
        }
    }

    func testEnglishAndUnknownCodesHaveNoCaptionLanguageLabel() {
        for code in [nil, "en", "unsupported"] as [String?] {
            XCTAssertNil(CaptionPresentation(caption(code)).languageName)
        }
        XCTAssertNil(CaptionLanguageNames.name(for: nil))
        XCTAssertNil(CaptionLanguageNames.name(for: "unsupported"))
    }

    func testChineseRowPrefersStoredCaptionOverNormalizedSource() {
        let presentation = CaptionPresentation(caption("zh", source: "這本書放在桌上。", chinese: "这本书在桌上。"))
        XCTAssertEqual(presentation.languageName, "中文")
        XCTAssertTrue(presentation.isSourceOnly)
        XCTAssertEqual(presentation.primaryText, "这本书在桌上。")
        XCTAssertNotEqual(presentation.primaryText, "这本书放在桌上。")
    }

    func testChineseWithoutTranslationUsesNormalizedSourceOnce() {
        let presentation = CaptionPresentation(caption("zh", source: "這本書放在桌上。", chinese: ""))
        XCTAssertTrue(presentation.isSourceOnly)
        XCTAssertEqual(presentation.primaryText, "这本书放在桌上。")
    }

    func testFailedChineseStillUsesNormalizedSourceOnce() {
        var segment = caption("zh", source: "這本書放在桌上。", chinese: "这本书在桌上。")
        segment.failTranslation("synthetic failure")
        let presentation = CaptionPresentation(segment)
        XCTAssertTrue(presentation.isSourceOnly)
        XCTAssertEqual(presentation.primaryText, "这本书放在桌上。")
    }

    func testEveryLanguageUsesTheSameSourceOnlyPolicyAsThePipeline() {
        let target = CaptionTranslationTarget.simplifiedChinese
        for language in SpokenLanguage.all {
            let presentation = CaptionPresentation(caption(language.code))
            XCTAssertEqual(presentation.isSourceOnly, target.keepsSourceAsCaption(language: language.code), language.code)
        }
    }

    func testCantoneseAndOtherRowsKeepTheirActualSourceAndTranslationText() {
        for (code, source) in [("yue", "啲水好凍。"), ("es", "El agua está fría."), ("ja", "水は冷たい。")] {
            let segment = caption(code, source: source)
            let presentation = CaptionPresentation(segment)
            XCTAssertFalse(presentation.isSourceOnly)
            XCTAssertEqual(presentation.primaryText, source)
            XCTAssertEqual(segment.displayChinese, "水很冷。")
        }
    }

    func testEnglishRowUsesFrozenSourceTranslationAndPendingStatusStrings() {
        let completed = caption()
        let pending = caption(chinese: "")
        var translating = pending
        translating.beginTranslation()
        var failed = pending
        failed.failTranslation("synthetic failure")
        for segment in [completed, pending, translating, failed] {
            let presentation = CaptionPresentation(segment)
            XCTAssertNil(presentation.languageName)
            XCTAssertFalse(presentation.isSourceOnly)
            XCTAssertEqual(presentation.primaryText, "The water is cold.")
        }
        // These are the functions used by the row and its pending-status view.
        XCTAssertEqual(completed.displayChinese, "水很冷。")
        XCTAssertEqual(failed.displayChinese, "（本段翻译未完成，可对照英文）")
        XCTAssertEqual(CaptionPresentation.translationStatus(isTranslating: false), "等待翻译…")
        XCTAssertEqual(CaptionPresentation.translationStatus(isTranslating: true), "翻译中…")
    }

    func testSavedSummaryCountsChineseCantoneseAndOtherLanguagesSeparately() {
        let segments = [caption(), caption("zh"), caption("zh"), caption("yue"), caption("es")]
        XCTAssertEqual(SavedProcessingPresentation.languageSummary(segments: segments, untranscribedCount: 3),
                       "中文发言 2 段 · 其他语言 2 段 · 非英语讲话（未转写）3 段")
    }

    func testSavedSummaryOmitsEveryZeroCountItem() {
        XCTAssertEqual(SavedProcessingPresentation.languageSummary(segments: [caption("zh")]), "中文发言 1 段")
        XCTAssertEqual(SavedProcessingPresentation.languageSummary(segments: [caption("yue")]), "其他语言 1 段")
        XCTAssertEqual(SavedProcessingPresentation.languageSummary(segments: [], untranscribedCount: 1),
                       "非英语讲话（未转写）1 段")
        XCTAssertNil(SavedProcessingPresentation.languageSummary(segments: []))
    }

    func testPureEnglishSavedSummaryRemainsExactlyTheSame() {
        XCTAssertNil(SavedProcessingPresentation.languageSummary(segments: [caption(), caption("en")]))
        XCTAssertEqual(SavedProcessingPresentation.workSummary(processingState(), segments: [caption()]),
                       "等待转写 2 段 · 待确认或失败 1 段")
    }

    func testSavedWorkSummaryIncludesOnlyConfirmedCaptionLanguagesAndTerminalFailures() {
        XCTAssertEqual(SavedProcessingPresentation.workSummary(processingState(otherLanguageCount: 1),
                                                              segments: [caption("zh"), caption("es")]),
                       "等待转写 2 段 · 待确认或失败 1 段 · 中文发言 1 段 · 其他语言 1 段 · 非英语讲话（未转写）1 段")
    }

    private func processingState(otherLanguageCount: Int = 0) -> TranscriptionProcessingState {
        .init(sessionID: UUID(), isCapturing: false, isPaused: true, activeCount: 0,
              pendingCount: 2, backlogSeconds: 4, unresolvedCount: 1, otherLanguageCount: otherLanguageCount)
    }
}

/// Native SwiftUI hosts use synthetic text, volatile preferences and unavailable services.
@MainActor
final class MultilingualPreviewPresentationTests: XCTestCase {
    private var presentationDefaults: UserDefaults?
    private var artifactDirectory: URL?

    private func model() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("step9-presentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        artifactDirectory = directory
        let suite = "MultilingualPreview-\(UUID().uuidString)"
        let preferenceCleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        // Avoid changing any persistent app or system preference.
        defaults.setVolatileDomain(["transcriptTextSize": 18.0, "floatingTextSize": 24.0], forName: suite)
        presentationDefaults = defaults
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
                                       observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
            XCTFail("Presentation tests must not start a language model")
            throw CancellationError()
        }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
                             backgroundServices: false, scheduledNotes: false, defaults: defaults)
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            try preferenceCleanup.remove()
        }
        return model
    }

    func testChinesePreviewNormalizesSourceRatherThanUsingTheStoredRowCaption() throws {
        let model = try model()
        let segment = TranscriptSegment(startTime: 0, endTime: 2, english: "這本書放在桌上。",
                                       chinese: "这本书在桌上。", sourceLanguage: "zh")
        model.loadPresentationForTesting(phase: .idle, evidence: [segment])
        XCTAssertEqual(model.previewChineseDisplay, "这本书放在桌上。")
        XCTAssertNotEqual(model.previewChineseDisplay, "这本书在桌上。")
    }

    func testEnglishPreviewHasNoPreviousNonEnglishLanguageMetadata() throws {
        let model = try model()
        XCTAssertNil(model.nonEnglishPreviewPresentation)
        let segment = TranscriptSegment(startTime: 0, endTime: 2, english: "這本書放在桌上。",
                                       chinese: "这本书在桌上。", sourceLanguage: "zh")
        model.loadPresentationForTesting(phase: .idle, evidence: [segment])
        XCTAssertEqual(model.nonEnglishPreviewPresentation?.languageName, "中文")
        model.receiveLivePreviewForTesting("A new English sentence.")
        XCTAssertNil(model.nonEnglishPreviewPresentation)
    }

    func testEnglishGateRejectionsPreserveFrozenSavedTitleSummaryAndRecordLabel() throws {
        let model = try model()
        let english = TranscriptSegment(startTime: 0, endTime: 2, english: "The water is cold.", chinese: "水很冷。")
        let state = TranscriptionProcessingState(sessionID: UUID(), isCapturing: false, isPaused: true,
            activeCount: 0, pendingCount: 0, backlogSeconds: 0, unresolvedCount: 0, otherLanguageCount: 2)
        model.loadPresentationForTesting(phase: .saved(try XCTUnwrap(artifactDirectory)), evidence: [english], processing: state)
        XCTAssertEqual(model.savedProcessingStatus, "已保存 · 2 段为非英语讲话（未转写）")
        XCTAssertEqual(SavedProcessingPresentation.workSummary(state, segments: model.segments),
                       "等待转写 0 段 · 待确认或失败 0 段 · 非英语讲话 2 段")
        XCTAssertEqual(SavedProcessingPresentation.recordLabel(.otherLanguage), "非英语讲话（未转写）")
    }

    func testHostedMultilingualRowsAndStablePreviewGeometry() async throws {
        let model = try model()
        let zh = TranscriptSegment(startTime: 0, endTime: 2, english: "這裡很冷。", chinese: "这里很冷。", sourceLanguage: "zh")
        let yue = TranscriptSegment(startTime: 10, endTime: 12, english: "呢度好凍。", chinese: "这里很冷。", sourceLanguage: "yue")
        let en = TranscriptSegment(startTime: 20, endTime: 22, english: "It is cold.", chinese: "这里很冷。")
        let es = TranscriptSegment(startTime: 30, endTime: 32, english: "El agua está fría.", chinese: "水很冷。", sourceLanguage: "es")
        let captions = [zh, yue, en, es]
        XCTAssertEqual(zh.english.count, yue.english.count)
        model.loadPresentationForTesting(phase: .recording, evidence: captions)
        let (classroomWindow, classroom) = try window(model: model)
        defer { classroomWindow.close() }
        let (floatingWindow, floating) = try window(model: model, floating: true)
        defer { floatingWindow.close() }
        try await settle(classroom)
        try await resizeAndSettle(floatingWindow, view: floating)
        var heights: [CGFloat] = []
        for caption in captions {
            let row = try probe("classroom-caption-\(caption.id)", in: classroom)
            XCTAssertGreaterThan(row.bounds.height, 0)
            XCTAssertTrue(classroom.bounds.intersects(classroom.convert(row.bounds, from: row)), "The caption must be visible")
            heights.append(row.bounds.height)
        }
        XCTAssertLessThan(heights[0], heights[1], "A source-only Chinese row must be shorter than a same-length Cantonese row")
        verifySpanishAccessibility(in: classroom, scope: "MULTILINGUAL_CLASSROOM")
        verifySpanishAccessibility(in: floating, scope: "MULTILINGUAL_FLOATING")
        verifyLabelSelection(in: classroom, scope: "MULTILINGUAL_CLASSROOM")
        verifyLabelSelection(in: floating, scope: "MULTILINGUAL_FLOATING")
        try capture(classroom, name: "multilingual-classroom-light")
        try capture(floating, name: "multilingual-floating-spanish")

        model.loadPresentationForTesting(phase: .recording, evidence: [en])
        try await settle(classroom)
        try await resizeAndSettle(floatingWindow, view: floating)
        let englishFloatingHeight = floating.bounds.height
        let englishWindowHeight = floatingWindow.frame.height
        let englishPreview = try probeFrame("classroom-live-preview", in: classroom)
        let englishList = try transcriptScrollFrame(in: classroom)
        try capture(floating, name: "multilingual-floating-english")
        for caption in [zh, yue, es, en, zh] {
            model.loadPresentationForTesting(phase: .recording, evidence: [caption])
            try await settle(classroom)
            try await resizeAndSettle(floatingWindow, view: floating)
            XCTAssertEqual(floating.bounds.height, englishFloatingHeight, accuracy: 0.5)
            XCTAssertEqual(floatingWindow.frame.height, englishWindowHeight, accuracy: 0.5)
            let preview = try probeFrame("classroom-live-preview", in: classroom)
            XCTAssertEqual(preview.height, englishPreview.height, accuracy: 0.5)
            XCTAssertEqual(preview.minY, englishPreview.minY, accuracy: 0.5)
            let list = try transcriptScrollFrame(in: classroom)
            XCTAssertEqual(list.minY, englishList.minY, accuracy: 0.5)
            XCTAssertEqual(list.height, englishList.height, accuracy: 0.5)
        }
        try capture(floating, name: "multilingual-floating-chinese")
        // Volatile English is the other transition that previously removed/restored a slot.
        model.receiveLivePreviewForTesting("A fresh English sentence.")
        try await settle(classroom)
        try await resizeAndSettle(floatingWindow, view: floating)
        XCTAssertEqual(floatingWindow.frame.height, englishWindowHeight, accuracy: 0.5)
        XCTAssertEqual(try probeFrame("classroom-live-preview", in: classroom).height, englishPreview.height, accuracy: 0.5)
        print("MULTILINGUAL_FRAME_PROBE rowHeights=\(heights) floatingHeight=\(englishFloatingHeight) previewHeight=\(englishPreview.height)")

        model.loadPresentationForTesting(phase: .recording, evidence: captions)
        let (darkWindow, darkClassroom) = try window(model: model, dark: true)
        defer { darkWindow.close() }
        try await settle(darkClassroom)
        try capture(darkClassroom, name: "multilingual-classroom-dark")
    }

    func testHostedChineseTranslationStatesStaySingleLine() async throws {
        let model = try model()
        let completed = TranscriptSegment(startTime: 0, endTime: 2, english: "這裡很冷。", chinese: "这里很冷。", sourceLanguage: "zh")
        let pending = TranscriptSegment(startTime: 10, endTime: 12, english: "這裡很冷。", sourceLanguage: "zh")
        var translating = TranscriptSegment(startTime: 20, endTime: 22, english: "這裡很冷。", sourceLanguage: "zh")
        translating.beginTranslation()
        var failed = TranscriptSegment(startTime: 30, endTime: 32, english: "這裡很冷。", sourceLanguage: "zh")
        failed.failTranslation("synthetic failure")
        model.loadPresentationForTesting(phase: .recording, evidence: [completed, pending, translating, failed])
        let (window, view) = try window(model: model)
        defer { window.close() }
        try await settle(view)
        let completedHeight = try probe("classroom-caption-\(completed.id)", in: view).bounds.height
        for caption in [pending, translating, failed] {
            XCTAssertEqual(try probe("classroom-caption-\(caption.id)", in: view).bounds.height, completedHeight, accuracy: 0.5,
                           "Chinese must not mount a second translation/status line")
        }
        try capture(view, name: "multilingual-chinese-translation-states")
    }

    private func window(model: AppModel, floating: Bool = false, dark: Bool = false) throws -> (NSWindow, NSView) {
        let defaults = try XCTUnwrap(presentationDefaults)
        let root: AnyView
        if floating {
            root = AnyView(FloatingSubtitleView().environmentObject(model).defaultAppStorage(defaults))
        } else {
            root = AnyView(ContentView().environmentObject(model).defaultAppStorage(defaults)
                .environment(\.colorScheme, dark ? .dark : .light)
                .accessibilityElement(children: .contain))
        }
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: floating ? 640 : 1260, height: floating ? 390 : 1000),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: floating || dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        return (window, controller.view)
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

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func probe(_ identifier: String, in view: NSView) throws -> NSView {
        try XCTUnwrap(descendants(view).first { $0.identifier?.rawValue == identifier }, "Missing mounted frame probe: \(identifier)")
    }

    private func probeFrame(_ identifier: String, in view: NSView) throws -> NSRect {
        let probe = try probe(identifier, in: view)
        return view.convert(probe.bounds, from: probe)
    }

    private func transcriptScrollFrame(in view: NSView) throws -> NSRect {
        let scroll = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 600 }
            .max { $0.bounds.height < $1.bounds.height })
        return view.convert(scroll.bounds, from: scroll)
    }

    private struct AccessibleNode {
        let object: NSObject
        func value(_ name: String) -> Any? {
            guard object.responds(to: NSSelectorFromString(name)) else { return nil }
            return object.value(forKey: name)
        }
    }

    private func elements(_ root: Any, depth: Int = 0) -> [AccessibleNode] {
        guard depth < 24, let object = root as? NSObject else { return [] }
        let node = AccessibleNode(object: object)
        return [node] + ((node.value("accessibilityChildren") as? [Any]) ?? []).flatMap { elements($0, depth: depth + 1) }
    }

    private func verifySpanishAccessibility(in view: NSView, scope: String) {
        let texts = elements(view).flatMap { node in
            ["accessibilityValue", "accessibilityLabel"].compactMap { key -> String? in
                let value = node.value(key)
                return value as? String ?? (value as? NSAttributedString)?.string
            }
        }.filter { !$0.isEmpty }
        guard !texts.isEmpty else {
            print("\(scope)_AX_UNAVAILABLE: language label and caption-body accessibility assertions were not run")
            return
        }
        XCTAssertTrue(texts.contains("语种：西班牙语"), "The language label must be separate: \(texts)")
        XCTAssertTrue(texts.contains("El agua está fría."), "The selectable caption body must have no language prefix: \(texts)")
        XCTAssertFalse(texts.contains { $0.hasPrefix("西班牙语") && $0.contains("El agua está fría.") },
                       "The caption must not start with its language name")
        XCTAssertFalse(texts.contains { $0.contains("语种：西班牙语") && $0.contains("El agua está fría.") },
                       "Language metadata and caption body must not become one accessibility element")
    }

    private func verifyLabelSelection(in view: NSView, scope: String) {
        let fields = descendants(view).compactMap { $0 as? NSTextField }.filter { $0.stringValue == "西班牙语" }
        let textViews = descendants(view).compactMap { $0 as? NSTextView }.filter { $0.string == "西班牙语" }
        guard !fields.isEmpty || !textViews.isEmpty else {
            print("\(scope)_LABEL_SELECTION_UNAVAILABLE: no native text control exposes the language label")
            return
        }
        for field in fields { XCTAssertFalse(field.isSelectable) }
        for textView in textViews { XCTAssertFalse(textView.isSelectable) }
    }

    private func capture(_ view: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000, "The capture must contain a rendered view")
        let directory = try XCTUnwrap(artifactDirectory)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("MULTILINGUAL_ATTACHMENT \(directory.lastPathComponent)/\(name).png")
    }
}
