import AppKit
import Combine
import SwiftUI
import XCTest
@testable import LiveLingo

/// Real SwiftUI views, synthetic classroom, isolated preferences and queue.
/// No microphone, language model, system translation, or real classroom data.
@MainActor
final class ClassroomPresentationTests: XCTestCase {
    private var presentationDefaults: UserDefaults?

    func testLiveDraftUpdatesStayInTheirReadingViews() async throws {
        var update: CaptionTranslationDependencies.Update?
        var pendingTranslation: CheckedContinuation<String, Error>?
        var pendingAdjacent: CheckedContinuation<QwenTranslationClient.AdjacentTranslation, Error>?
        let (model, evidence, notebook) = try fixture(translation: .init(
            translate: { _, _, _, _, callback in
                update = callback
                return try await withCheckedThrowingContinuation { pendingTranslation = $0 }
            },
            adjacent: { _, _, _, _, _, _, _, callback, _ in
                update = callback
                return try await withCheckedThrowingContinuation { pendingAdjacent = $0 }
            }))
        defer {
            pendingTranslation?.resume(throwing: CancellationError())
            pendingAdjacent?.resume(throwing: CancellationError())
        }
        model.loadPresentationForTesting(phase: .recording, evidence: evidence, notebook: notebook)
        let originalNotes = model.lectureSummary
        let (window, view) = try window(model: model, width: 1260, notes: true)
        defer { window.close() }
        let floatingController = NSHostingController(rootView: FloatingSubtitleView().environmentObject(model)
            .defaultAppStorage(try XCTUnwrap(presentationDefaults)))
        let floatingWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 390),
            styleMask: [.titled], backing: .buffered, defer: false)
        floatingWindow.isReleasedWhenClosed = false
        floatingWindow.contentViewController = floatingController
        let floating = floatingController.view
        floatingWindow.setContentSize(floating.fittingSize)
        floatingWindow.makeKeyAndOrderFront(nil)
        defer { floatingWindow.close() }
        try await settle(view)
        try await settle(floating)

        var notifications = 0
        let observer = model.objectWillChange.sink { notifications += 1 }
        defer { observer.cancel() }
        SummaryRenderingDiagnostics.reset()
        for index in 0..<12 {
            model.receiveLivePreviewForTesting("Synthetic live preview update \(index).",
                                               chinese: "合成初译更新：第 \(index) 次。")
            try await Task.sleep(for: .milliseconds(25))
            view.layoutSubtreeIfNeeded()
            floating.layoutSubtreeIfNeeded()
        }
        try await settle(view)
        try await settle(floating)
        let preview = SummaryRenderingDiagnostics.counts
        let previewNotifications = notifications
        XCTAssertEqual(previewNotifications, 0)
        XCTAssertEqual(preview.rootBodies, 0, "Live preview must not invalidate the whole classroom")
        XCTAssertEqual(preview.summaryBodies, 0)
        XCTAssertEqual(preview.inlineParses, 0)
        XCTAssertGreaterThan(preview.previewBodies, 0, "The visible preview must still redraw")
        XCTAssertGreaterThan(preview.floatingBodies, 0, "Floating subtitles must observe the same live state")
        XCTAssertEqual(model.previewEnglishDisplay, "Synthetic live preview update 11.")
        XCTAssertEqual(model.previewChineseDisplay, model.supportsPreviewTranslation
            ? "初译 · 合成初译更新：第 11 次。" : "当前系统不支持初译；正式译文随后显示")
        XCTAssertEqual(model.segments, evidence)
        XCTAssertEqual(model.lectureSummary, originalNotes)
        try capture(view, name: "live-draft-updated-preview")
        try capture(floating, name: "live-draft-updated-floating")

        model.receiveLivePreviewForTesting("Replacement preview after a source rewrite.")
        try await settle(view)
        XCTAssertEqual(model.previewChinese, "", "A source rewrite must clear its stale initial translation")

        model.receiveCaptionForTesting("and the temperature rises in this synthetic example.", start: 80, end: 89)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while update == nil, ContinuousClock.now < deadline { await Task.yield() }
        let callback = try XCTUnwrap(update, "The real caption worker must supply its streaming callback")
        try await settle(view)
        SummaryRenderingDiagnostics.reset()
        notifications = 0
        for index in 0..<12 {
            await callback("合成课堂：温度随之升高" + String(repeating: "。", count: index + 1))
            try await Task.sleep(for: .milliseconds(25))
            view.layoutSubtreeIfNeeded()
        }
        try await settle(view)
        let streaming = SummaryRenderingDiagnostics.counts
        let streamingNotifications = notifications
        XCTAssertEqual(streamingNotifications, 0)
        XCTAssertEqual(streaming.rootBodies, 0, "Streaming a caption must not rebuild unrelated classroom regions")
        XCTAssertEqual(streaming.summaryBodies, 0)
        XCTAssertEqual(streaming.inlineParses, 0)
        XCTAssertGreaterThan(streaming.streamingBodies, 0, "The active caption must still show streamed text")
        XCTAssertEqual(model.translatingSegmentID, model.segments.last?.id)
        XCTAssertFalse(try XCTUnwrap(model.segments.last).hasUsableTranslation)
        XCTAssertTrue(model.streamingChinese.hasSuffix(String(repeating: "。", count: 12)))
        XCTAssertEqual(model.lectureSummary, originalNotes)
        try capture(view, name: "live-draft-updated-streaming-caption")
        let probe = LiveDraftProbe(preview: preview, streaming: streaming,
            previewModelNotifications: previewNotifications, streamingModelNotifications: streamingNotifications)
        print("LIVE_DRAFT_RENDER_PROBE " + String(decoding: try JSONEncoder().encode(probe), as: UTF8.self))
        SummaryRenderingDiagnostics.reset()
        let finalText = "合成课堂：温度随之升高。"
        let translation = pendingTranslation; pendingTranslation = nil
        let adjacent = pendingAdjacent; pendingAdjacent = nil
        translation?.resume(returning: finalText)
        adjacent?.resume(returning: .init(previous: nil, current: finalText,
                                        previousRejection: nil, currentRejection: nil))
        await model.translationTaskForTesting?.value
        try await settle(view)
        XCTAssertTrue(try XCTUnwrap(model.segments.last).hasUsableTranslation)
        XCTAssertEqual(model.segments.last?.displayChinese, finalText)
        XCTAssertGreaterThan(SummaryRenderingDiagnostics.counts.rootBodies, 0,
                             "Durable caption completion must still update the classroom")
        try capture(view, name: "live-draft-completed-caption")
    }

    private struct LiveDraftProbe: Codable {
        let preview: SummaryRenderingDiagnostics.Counts
        let streaming: SummaryRenderingDiagnostics.Counts
        let previewModelNotifications: Int
        let streamingModelNotifications: Int
    }

    func testFilePanelQuitCommandDoesNotConsumeOtherShortcutsOrClosedPanels() {
        XCTAssertTrue(FilePanelPresentation.shouldHandleQuit(characters: "q", modifiers: .command, hasOpenPanel: true))
        XCTAssertTrue(FilePanelPresentation.shouldHandleQuit(characters: "Q", modifiers: [.command, .capsLock], hasOpenPanel: true))
        XCTAssertFalse(FilePanelPresentation.shouldHandleQuit(characters: "q", modifiers: .command, hasOpenPanel: false))
        for modifiers: NSEvent.ModifierFlags in [.shift, .control, [], [.command, .shift], [.command, .option], [.command, .control]] {
            XCTAssertFalse(FilePanelPresentation.shouldHandleQuit(characters: "q", modifiers: modifiers, hasOpenPanel: true))
        }
        XCTAssertFalse(FilePanelPresentation.shouldHandleQuit(characters: "w", modifiers: .command, hasOpenPanel: true))
        XCTAssertFalse(FilePanelPresentation.shouldHandleQuit(characters: nil, modifiers: .command, hasOpenPanel: true))
    }

    func testNotesRenderingDuringUnrelatedPublishedUpdates() async throws {
        let (model, evidence, notebook) = try fixture()
        model.loadPresentationForTesting(phase: .recording, evidence: evidence, notebook: notebook)
        let originalNotes = model.lectureSummary
        SummaryRenderingDiagnostics.reset()
        let (window, view) = try window(model: model, width: 1260, notes: true)
        defer { window.close() }
        try await settle(view)
        let initial = SummaryRenderingDiagnostics.counts
        XCTAssertGreaterThan(initial.rootBodies, 0)
        XCTAssertGreaterThan(initial.inlineParses, 0, "The probe must render actual notes")

        SummaryRenderingDiagnostics.reset()
        for index in 0..<12 {
            model.manualTranslationInput = "Synthetic unrelated update \(index)"
            try await Task.sleep(for: .milliseconds(25))
            view.layoutSubtreeIfNeeded()
        }
        try await settle(view)
        let unrelated = SummaryRenderingDiagnostics.counts
        XCTAssertGreaterThan(unrelated.rootBodies, 0, "Updates must reach the real classroom root")
        XCTAssertEqual(model.lectureSummary, originalNotes)
        XCTAssertEqual(unrelated.inlineParses, 0, "Unchanged captions must not parse Markdown on unrelated updates")
        XCTAssertEqual(unrelated.summaryBodies, 0)

        SummaryRenderingDiagnostics.reset()
        for index in 0..<12 {
            model.captureMeter.elapsedSeconds = Double(index)
            model.captureMeter.waveformSamples = Array(repeating: Float(index) / 12, count: 24)
            try await Task.sleep(for: .milliseconds(25))
            view.layoutSubtreeIfNeeded()
        }
        try await settle(view)
        let meter = SummaryRenderingDiagnostics.counts
        XCTAssertEqual(meter.rootBodies, 0)
        XCTAssertEqual(meter.inlineParses, 0)

        var correctedEvidence = evidence
        correctedEvidence[correctedEvidence.count - 1].completeTranslation("修改后的合成字幕：保留 $v = 2\\,m/s$ 与 **条件**。")
        SummaryRenderingDiagnostics.reset()
        model.loadPresentationForTesting(phase: .recording, evidence: correctedEvidence, notebook: notebook)
        try await settle(view)
        let corrected = SummaryRenderingDiagnostics.counts
        XCTAssertGreaterThan(corrected.inlineParses, 0, "Corrected text with the same caption ID must render")
        XCTAssertLessThan(corrected.inlineParses, initial.inlineParses, "Unchanged neighboring captions must remain reusable")
        XCTAssertEqual(model.lectureSummary, originalNotes)
        try capture(view, name: "notes-rendering-corrected-caption")

        let added = TranscriptSegment(startTime: 100, endTime: 109,
            english: "An additional synthetic point changes the notebook.",
            chinese: "新增的合成要点需要立即显示，不能复用过期笔记。")
        var updatedNotebook = notebook
        try updatedNotebook.append(evidence: [added], note: .init(topic: "新增合成笔记", points: [
            .init(kind: "核心结论", text: "新增内容必须重新解析并显示。", sourceIDs: ["en0s0"])
        ], sourceVersion: 2))
        SummaryRenderingDiagnostics.reset()
        model.loadPresentationForTesting(phase: .recording, evidence: correctedEvidence + [added], notebook: updatedNotebook)
        try await settle(view)
        let changed = SummaryRenderingDiagnostics.counts
        XCTAssertNotEqual(model.lectureSummary, originalNotes)
        XCTAssertGreaterThan(changed.inlineParses, 0)
        let counts = ["initial": initial, "unrelated": unrelated, "meter": meter, "captionCorrected": corrected, "notesChanged": changed]
        print("SUMMARY_RENDER_PROBE " + String(decoding: try JSONEncoder().encode(counts), as: UTF8.self))
        try capture(view, name: "notes-rendering-updated-content")
    }

    private func fixture(translation: CaptionTranslationDependencies? = nil) throws -> (AppModel, [TranscriptSegment], LearningNotebook) {
        XCTAssertTrue(AppRuntimeEnvironment.isUnitTesting)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassroomPresentation-\(UUID().uuidString)")
        let suite = "ClassroomPresentation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        presentationDefaults = defaults
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
                                        observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
            XCTFail("Presentation tests must never invoke a generator")
            throw CancellationError()
        }
        addTeardownBlock {
            await queue.shutdownForTesting()
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let model = AppModel(reviewQueue: queue, translation: translation, backgroundServices: false, defaults: defaults)
        let evidence = (0..<8).map { index in
            TranscriptSegment(startTime: Double(index * 10), endTime: Double(index * 10 + 9),
                english: "Synthetic classroom \(index + 1): compare the quantities and keep the stated conditions with the formula.",
                chinese: "合成课堂第 \(index + 1) 段：比较物理量时需要保留公式的适用条件。较长的中文用于检查换行及字幕阅读位置。")
        }
        var notebook = LearningNotebook()
        for segment in evidence {
            try notebook.append(evidence: [segment], note: .init(topic: "合成课堂 · 公式与适用条件", points: [
                .init(kind: "核心结论", text: "整理时保留对象、数值、单位和条件。", sourceIDs: ["en0s0"]),
                .init(kind: "例子", text: "这是用于界面验收的合成说明；检查较长段落在窄窗口中的阅读宽度。", sourceIDs: ["en0s0"])
            ], sourceVersion: 2))
        }
        return (model, evidence, notebook)
    }

    func testCurrentTranslationIsVisibleBeforePreviousRepairFinishes() async throws {
        var repair: CheckedContinuation<QwenTranslationClient.AdjacentTranslation, Error>?
        let (model, _, _) = try fixture(translation: .init(
            translate: { _, _, _, _, _ in "合成课堂：系统吸收热能。" },
            adjacent: { _, _, _, _, _, _, _, onCurrent, shouldDefer in
                await onCurrent?("合成课堂：温度随之升高。")
                return try await withCheckedThrowingContinuation { repair = $0 }
            }))
        defer { repair?.resume(throwing: CancellationError()) }
        model.resetTranslationSessionForTesting()
        model.receiveCaptionForTesting("The synthetic lecture describes thermal energy.", start: 0, end: 10)
        await model.translationTaskForTesting?.value
        model.receiveCaptionForTesting("and the temperature rises in this synthetic example.", start: 10, end: 18)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while repair == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(repair)
        let (window, view) = try window(model: model, width: 1000)
        defer { window.close() }
        try await settle(view)
        let labels = elements(view).flatMap { node in
            ["accessibilityValue", "accessibilityLabel"].compactMap { key -> String? in
                let value = node.value(key)
                return value as? String ?? (value as? NSAttributedString)?.string
            }
        }
        // Some native test hosts render SwiftUI but expose no AX descendants.
        // Keep the screenshot for visual inspection; do not call that an AX pass.
        if labels.isEmpty {
            print("PREVIEW_AX_UNAVAILABLE: inspect accepted-current-before-repair attachment")
        } else {
            XCTAssertTrue(labels.contains { $0.contains("合成课堂：温度随之升高。") }, "Missing accepted preview in accessibility text: \(labels)")
        }
        XCTAssertEqual(model.streamingChinese, "合成课堂：温度随之升高。")
        XCTAssertEqual(model.translatingSegmentID, model.segments[1].id)
        XCTAssertFalse(model.segments[1].hasUsableTranslation)
        try capture(view, name: "accepted-current-before-repair")
        let pending = repair; repair = nil
        pending?.resume(returning: .init(previous: nil, current: "合成课堂：温度随之升高。", previousRejection: nil, currentRejection: nil))
        await model.translationTaskForTesting?.value
        XCTAssertTrue(model.segments[1].hasUsableTranslation)
    }

    private func window(model: AppModel, width: CGFloat, height: CGFloat = 820,
                        dark: Bool = false, notes: Bool = false) throws -> (NSWindow, NSView) {
        let defaults = try XCTUnwrap(presentationDefaults)
        let root = AnyView(ContentView(showWholeLessonNotes: notes)
            .environmentObject(model)
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, dark ? .dark : .light)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("classroom-test-root"))
        // A hosting controller bridges the SwiftUI toolbar and title into this window.
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        let view = controller.view
        window.setContentSize(NSSize(width: width, height: height))
        window.makeKeyAndOrderFront(nil)
        return (window, view)
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private func capture(_ view: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var colors = Set<UInt32>()
        var opaqueSamples = 0
        var samples = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 32)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 32)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                samples += 1
                if color.alphaComponent > 0.9 { opaqueSamples += 1 }
                let red = UInt32(min(255, max(0, color.redComponent * 255)))
                let green = UInt32(min(255, max(0, color.greenComponent * 255)))
                let blue = UInt32(min(255, max(0, color.blueComponent * 255)))
                colors.insert(red << 16 | green << 8 | blue)
            }
        }
        XCTAssertGreaterThan(colors.count, 4, "A flat or unrendered capture is not visual evidence: \(name)")
        XCTAssertGreaterThan(opaqueSamples, samples * 4 / 5, "Capture is mostly transparent: \(name)")
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 5_000, "Capture must contain a rendered view")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The window frame view includes the title bar and toolbar. Off-screen
    /// capture shows layout only; toolbar glass must be judged in the real app.
    private func captureWindow(_ window: NSWindow, name: String) throws {
        let frameView = try XCTUnwrap(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        try capture(frameView, name: name)
    }

    /// Menus reachable from the bridged toolbar (the 更多 menu).
    private func toolbarMenus(in window: NSWindow) throws -> [NSMenu] {
        let toolbar = try XCTUnwrap(window.toolbar, "The classroom toolbar must be bridged into the window")
        var menus = toolbar.items.compactMap { ($0 as? NSMenuToolbarItem)?.menu }
        for item in toolbar.items {
            if let view = item.view {
                menus += descendants(view).compactMap { ($0 as? NSPopUpButton)?.menu ?? $0.menu }
            }
            if let submenu = item.menuFormRepresentation?.submenu { menus.append(submenu) }
        }
        menus.forEach { $0.update() }
        return menus
    }

    /// Runs one item of the toolbar 更多 menu without system-wide input.
    private func performMoreMenuItem(_ title: String, in window: NSWindow) throws {
        let menus = try toolbarMenus(in: window)
        for menu in menus {
            let index = menu.indexOfItem(withTitle: title)
            if index >= 0 {
                menu.performActionForItem(at: index)
                return
            }
        }
        XCTFail("Missing menu item \(title); menus: \(menus.map { $0.items.map(\.title) })")
    }

    private struct AccessibleNode {
        let object: NSObject
        func value(_ name: String) -> Any? {
            guard object.responds(to: NSSelectorFromString(name)) else { return nil }
            return object.value(forKey: name)
        }
        func accessibilityIdentifier() -> String? { value("accessibilityIdentifier") as? String }
        func accessibilityFrame() -> NSRect { (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        func accessibilityPerformPress() -> Bool {
            guard object.responds(to: NSSelectorFromString("accessibilityPerformPress")) else { return false }
            object.accessibilityPerformAction(.press)
            return true
        }
    }

    private func elements(_ root: Any, depth: Int = 0) -> [AccessibleNode] {
        guard depth < 24, let object = root as? NSObject else { return [] }
        let node = AccessibleNode(object: object)
        return [node] + ((node.value("accessibilityChildren") as? [Any]) ?? []).flatMap { elements($0, depth: depth + 1) }
    }

    private func element(_ id: String, in view: NSView) throws -> AccessibleNode {
        let nodes = elements(view)
        if !nodes.contains(where: { $0.accessibilityIdentifier() == id }) {
            print("AX_TREE", nodes.map { "\(type(of: $0.object)):\($0.accessibilityIdentifier() ?? "-")" })
        }
        return try XCTUnwrap(nodes.first { $0.accessibilityIdentifier() == id }, "Missing accessible element: \(id)")
    }

    private func scrollFrames(in root: NSView) -> [NSRect] {
        return descendants(root).compactMap { view in
            guard view is NSScrollView, !view.isHiddenOrHasHiddenAncestor else { return nil }
            return root.convert(view.bounds, from: view)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func closeSheet(_ sheet: NSWindow) async throws {
        let content = try XCTUnwrap(sheet.contentView)
        try click(sheet, content: content, x: content.bounds.width - 40, yFromTop: 29)
        try await Task.sleep(for: .milliseconds(300))
    }

    private func click(_ window: NSWindow, content: NSView, x: CGFloat, yFromTop: CGFloat) throws {
        let local = NSPoint(x: x, y: content.isFlipped ? yFromTop : content.bounds.height - yFromTop)
        let location = content.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    func testResponsiveReadingAndLargeCaptionsRender() async throws {
        let (model, evidence, notebook) = try fixture()
        let defaults = try XCTUnwrap(presentationDefaults)
        for (width, height, dark, notes, size) in [(1260.0, 820.0, false, false, 18.0),
                                                   (820.0, 700.0, false, false, 24.0),
                                                   (1440.0, 900.0, true, true, 18.0),
                                                   (820.0, 700.0, true, true, 24.0)] {
            defaults.set(size, forKey: "transcriptTextSize")
            model.loadPresentationForTesting(phase: notes ? .saved(URL(fileURLWithPath: "/synthetic-classroom")) : .recording,
                evidence: evidence, notebook: notebook, preview: notes ? "" : "A synthetic preview that grows while the class continues.")
            let (window, view) = try window(model: model, width: width, height: height, dark: dark, notes: notes)
            defer { window.close() }
            try await settle(view)
            try capture(view, name: "classroom-\(Int(width))-\(dark ? "dark" : "light")-\(notes ? "notes" : "captions")-\(Int(size))")
            try captureWindow(window, name: "window-\(Int(width))-\(dark ? "dark" : "light")-\(notes ? "notes" : "captions")-\(Int(size))")
            XCTAssertEqual(view.bounds.width, width, accuracy: 1)
            XCTAssertEqual(view.bounds.height, height, accuracy: 1)
            let frames = scrollFrames(in: view)
            XCTAssertFalse(frames.isEmpty, "Expected an actual native reading viewport")
            for frame in frames {
                XCTAssertTrue(view.bounds.insetBy(dx: -1, dy: -1).contains(frame), "Reading viewport is clipped: \(frame)")
            }
        }
        XCTAssertFalse(model.noteReviewQueue.hasWork)
    }

    func testLongNoticeDoesNotMoveReadingWorkspace() async throws {
        let (model, evidence, notebook) = try fixture()
        model.loadPresentationForTesting(phase: .recording, evidence: evidence, notebook: notebook)
        let (window, view) = try window(model: model, width: 1260)
        defer { window.close() }
        try await settle(view)
        let before = scrollFrames(in: view)
        XCTAssertFalse(before.isEmpty)
        let notice = String(repeating: "这是一条很长的合成提示，录音仍在继续；完整说明应在详情中读取。", count: 8)
        model.loadPresentationForTesting(phase: .recording, evidence: evidence, notebook: notebook, notice: notice)
        try await settle(view)
        let after = scrollFrames(in: view)
        XCTAssertEqual(before, after, "Notice must not shift or resize the reading workspace")
        XCTAssertEqual(model.errorMessage, notice)
        try capture(view, name: "classroom-long-notice-stable")
        try click(window, content: view, x: view.bounds.width - 30, yFromTop: view.bounds.height - 18)
        try await settle(view)
        XCTAssertNil(model.sessionNotice)
        XCTAssertEqual(before, scrollFrames(in: view))
    }

    func testStatusDetailsOpenWithoutMovingReadingSpace() async throws {
        let (model, evidence, notebook) = try fixture()
        let notice = String(repeating: "合成提示：完整错误应可在详情中阅读。", count: 16)
        model.loadPresentationForTesting(phase: .recording, evidence: evidence, notebook: notebook, notice: notice)
        let (window, view) = try window(model: model, width: 1260)
        defer { window.close() }
        try await settle(view)
        let before = scrollFrames(in: view)
        let visible = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        try click(window, content: view, x: view.bounds.width - 76, yFromTop: view.bounds.height - 18)
        try await Task.sleep(for: .milliseconds(300))
        let popover = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !visible.contains($0.windowNumber) })
        let content = try XCTUnwrap(popover.contentView)
        try await settle(content)
        XCTAssertFalse(scrollFrames(in: content).isEmpty, "Full status must have a scrollable reading area")
        XCTAssertEqual(before, scrollFrames(in: view))
        XCTAssertEqual(model.errorMessage, notice)
        XCTAssertEqual(model.phase, .recording)
    }

    func testExportEntryUsesTheSelectedNotebookScope() async throws {
        let (model, evidence, notebook) = try fixture()
        model.loadPresentationForTesting(phase: .saved(URL(fileURLWithPath: "/synthetic-classroom")),
                                         evidence: evidence, notebook: notebook)
        model.exportScope = .latest
        let (window, view) = try window(model: model, width: 820, height: 700, notes: true)
        defer { window.close() }
        try await settle(view)
        let visible = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        try click(window, content: view, x: view.bounds.width - 105, yFromTop: view.bounds.height - 91)
        try await Task.sleep(for: .milliseconds(300))
        let popover = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !visible.contains($0.windowNumber) })
        XCTAssertNotNil(popover.contentView)
        XCTAssertEqual(model.exportScope, .wholeLesson)
        XCTAssertFalse(model.isExporting, "Opening options must not write files")
        XCTAssertFalse(model.noteReviewQueue.hasWork)
        XCTAssertEqual(model.segments, evidence)
    }

    func testSettingsWindowRendersAndScrollsWithoutChangingRecording() async throws {
        let (model, evidence, notebook) = try fixture()
        model.loadPresentationForTesting(phase: .recording, evidence: evidence, notebook: notebook)
        let (window, view) = try window(model: model, width: 1260)
        defer { window.close() }
        try await settle(view)
        let titles = try toolbarMenus(in: window).flatMap { $0.items.map(\.title) }
        XCTAssertTrue(titles.contains("课堂设置…"), "更多 must keep an entry to the Settings window: \(titles)")
        // The Settings scene hosts this same view; render it in an isolated window.
        let defaults = try XCTUnwrap(presentationDefaults)
        let settings = NSHostingController(rootView: AnyView(ClassroomSettingsView()
            .environmentObject(model)
            .defaultAppStorage(defaults)))
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.contentViewController = settings
        settingsWindow.setContentSize(NSSize(width: 520, height: 480))
        settingsWindow.makeKeyAndOrderFront(nil)
        defer { settingsWindow.close() }
        let content = settings.view
        try await settle(content)
        try capture(content, name: "classroom-settings-window")
        let form = try XCTUnwrap(descendants(content).compactMap { $0 as? NSScrollView }
            .first { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height })
        let document = try XCTUnwrap(form.documentView)
        form.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - form.contentView.bounds.height))
        form.reflectScrolledClipView(form.contentView)
        try await settle(content)
        XCTAssertGreaterThan(form.contentView.bounds.minY, 0, "The lower settings must be reachable by scrolling")
        try capture(content, name: "classroom-settings-scrolled")
        XCTAssertNil(window.attachedSheet, "Settings no longer opens a sheet over the classroom")
        XCTAssertEqual(model.phase, .recording)
        XCTAssertEqual(model.segments, evidence)
        XCTAssertFalse(model.noteReviewQueue.hasWork)
    }

    func testTypedTranslationEntryRetainsInputAcrossClosing() async throws {
        let (model, evidence, notebook) = try fixture()
        model.loadPresentationForTesting(phase: .recording, evidence: evidence, notebook: notebook)
        model.manualTranslationInput = "A synthetic question retained while the class continues."
        let (window, view) = try window(model: model, width: 1260)
        defer { window.close() }
        try await settle(view)
        for attempt in 0..<2 {
            try performMoreMenuItem("文字翻译…", in: window)
            try await Task.sleep(for: .milliseconds(300))
            let sheet = try XCTUnwrap(window.attachedSheet)
            let content = try XCTUnwrap(sheet.contentView)
            try await settle(content)
            let editor = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextView }
                .first { $0.isEditable })
            XCTAssertEqual(editor.string, model.manualTranslationInput)
            if attempt == 0 { try capture(content, name: "classroom-typed-translation-sheet") }
            try await closeSheet(sheet)
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(model.phase, .recording)
            XCTAssertEqual(model.segments, evidence)
            XCTAssertFalse(model.isManualTranslating)
        }
        XCTAssertFalse(model.noteReviewQueue.hasWork)
    }

    func testReviewQueueManagerStaysInsideTheReviewSheet() async throws {
        let (model, evidence, notebook) = try fixture()
        model.loadPresentationForTesting(phase: .saved(URL(fileURLWithPath: "/synthetic-classroom")),
                                         evidence: evidence, notebook: notebook)
        let (window, view) = try window(model: model, width: 820, height: 700, notes: true)
        defer { window.close() }
        try await settle(view)
        XCTAssertTrue(model.canManuallyReview)
        XCTAssertEqual(model.reviewBatchChoices.count, notebook.batches.count)
        try click(window, content: view, x: 83, yFromTop: view.bounds.height - 91)
        try await Task.sleep(for: .milliseconds(300))
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        try await settle(content)
        try capture(content, name: "classroom-review-sheet")
        let overview = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: overview)
        try click(sheet, content: content, x: content.bounds.width - 53, yFromTop: 88)
        try await settle(content)
        // Queue management replaces the overview in place: no second modal.
        XCTAssertNil(sheet.attachedSheet)
        XCTAssertTrue(window.attachedSheet === sheet)
        let managed = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: managed)
        XCTAssertNotEqual(overview.representation(using: .png, properties: [:]),
                          managed.representation(using: .png, properties: [:]),
                          "管理队列 must switch the sheet to the queue manager")
        try capture(content, name: "classroom-review-queue-manager")
        try await closeSheet(sheet)
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(model.noteReviewQueue.hasWork)
        XCTAssertEqual(model.segments, evidence)
    }

    func testPreviewGrowthAndCompactTabsPreserveReadingSpace() async throws {
        let (model, evidence, notebook) = try fixture()
        try XCTUnwrap(presentationDefaults).set(24.0, forKey: "transcriptTextSize")
        model.loadPresentationForTesting(phase: .recording, evidence: evidence, notebook: notebook,
                                         preview: "A short synthetic preview.")
        let (window, view) = try window(model: model, width: 820, height: 700)
        defer { window.close() }
        try await settle(view)
        let before = scrollFrames(in: view)
        XCTAssertGreaterThanOrEqual(before.count, 3)
        model.loadPresentationForTesting(phase: .recording, evidence: evidence, notebook: notebook,
            preview: String(repeating: "A much longer synthetic preview with its original conditions. ", count: 20))
        try await settle(view)
        XCTAssertEqual(before, scrollFrames(in: view), "Preview growth must stay inside the reserved reading slots")
        try click(window, content: view, x: 439, yFromTop: 72)
        try await settle(view)
        let notes = scrollFrames(in: view)
        XCTAssertLessThan(notes.count, before.count, "The compact notes tab must replace the caption view")
        try click(window, content: view, x: 382, yFromTop: 72)
        try await settle(view)
        XCTAssertEqual(before, scrollFrames(in: view))
        XCTAssertEqual(model.segments, evidence)
    }

    func testFollowLatestCanHoldHistoryAndReturnToNewest() async throws {
        let (model, evidence, notebook) = try fixture()
        let phase = AppPhase.saved(URL(fileURLWithPath: "/synthetic-classroom"))
        model.loadPresentationForTesting(phase: phase, evidence: evidence, notebook: notebook)
        let (window, view) = try window(model: model, width: 1260, height: 700)
        defer { window.close() }
        try await settle(view)
        let history = try XCTUnwrap(descendants(view).compactMap { $0 as? NSScrollView }
            .first { $0.bounds.width > 600 })
        // The follow control is in the top right of this synthetic transcript panel.
        let historyFrame = view.convert(history.bounds, from: history)
        try click(window, content: view, x: historyFrame.maxX - 47, yFromTop: 96)
        history.contentView.scroll(to: NSPoint(x: 0, y: 200))
        history.reflectScrolledClipView(history.contentView)
        try await settle(view)
        let oldOffset = history.contentView.bounds.minY
        XCTAssertGreaterThan(oldOffset, 100)
        let anchorID = "classroom-caption-\(evidence[evidence.count - 2].id)"
        func anchorFrame() throws -> NSRect {
            let row = try XCTUnwrap(descendants(view).first { $0.identifier?.rawValue == anchorID })
            return view.convert(row.bounds, from: row)
        }
        let before = try anchorFrame()
        XCTAssertTrue(view.convert(history.bounds, from: history).intersects(before))
        try capture(view, name: "classroom-history-before-insertion")
        let newSegment = TranscriptSegment(startTime: 80, endTime: 89,
            english: "A newly arriving synthetic caption.", chinese: "新到达的一段合成字幕。")
        model.loadPresentationForTesting(phase: phase, evidence: evidence + [newSegment], notebook: notebook)
        try await settle(view)
        let after = try anchorFrame()
        try capture(view, name: "classroom-history-after-insertion")
        print("HISTORY_ROW_FRAMES", before, after)
        // A lazy stack estimates offscreen height. Measure the visible row,
        // not changes to the estimated height of the entire document.
        XCTAssertEqual(after.minY, before.minY, accuracy: 1,
                       "The visible earlier caption must stay at the same screen position")
        try click(window, content: view, x: historyFrame.maxX - 47, yFromTop: 96)
        try await settle(view)
        XCTAssertEqual(history.contentView.bounds.minY, 0, accuracy: 3,
                       "Re-enabling follow must return to the newest caption")
        XCTAssertFalse(model.noteReviewQueue.hasWork)
    }

    func testAccessibleControlTreeWhenTheHostExposesIt() async throws {
        let (model, _, _) = try fixture()
        let (window, view) = try window(model: model, width: 1260)
        defer { window.close() }
        try await settle(view)
        // Toolbar controls live in the window, outside the content view.
        let ids = Set((elements(window) + elements(view)).compactMap { $0.accessibilityIdentifier() })
        guard ids.contains("classroom-test-root") else {
            throw XCTSkip("This in-process SwiftUI host exposes no SwiftUI identifiers; full keyboard and VoiceOver acceptance remains unverified")
        }
        for id in ["classroom-more", "classroom-record-stop", "classroom-status-details"] {
            XCTAssertTrue(ids.contains(id), "Missing accessible element: \(id); found: \(ids.sorted())")
        }
    }
}
