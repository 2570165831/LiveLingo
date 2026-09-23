import AppKit
import SwiftUI
import XCTest
@testable import LiveLingo

/// Real SwiftUI views, synthetic classroom, isolated preferences and queue.
/// No microphone, language model, system translation, or real classroom data.
@MainActor
final class ClassroomPresentationTests: XCTestCase {
    private var presentationDefaults: UserDefaults?

    private func fixture() throws -> (AppModel, [TranscriptSegment], LearningNotebook) {
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
        let model = AppModel(reviewQueue: queue, backgroundServices: false, defaults: defaults)
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

    private func window(model: AppModel, width: CGFloat, height: CGFloat = 820,
                        dark: Bool = false, notes: Bool = false) throws -> (NSWindow, NSHostingView<AnyView>) {
        let defaults = try XCTUnwrap(presentationDefaults)
        let root = AnyView(ContentView(showWholeLessonNotes: notes)
            .environmentObject(model)
            .defaultAppStorage(defaults)
            .environment(\.colorScheme, dark ? .dark : .light)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("classroom-test-root"))
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.title = "LiveLingo · 合成界面验收"
        window.contentView = view
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
        try click(window, content: view, x: view.bounds.width - 30, yFromTop: view.bounds.height - 49)
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
        try click(window, content: view, x: view.bounds.width - 95, yFromTop: view.bounds.height - 49)
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
        try click(window, content: view, x: view.bounds.width - 105, yFromTop: view.bounds.height - 123)
        try await Task.sleep(for: .milliseconds(300))
        let popover = try XCTUnwrap(NSApp.windows.first { $0.isVisible && !visible.contains($0.windowNumber) })
        XCTAssertNotNil(popover.contentView)
        XCTAssertEqual(model.exportScope, .wholeLesson)
        XCTAssertFalse(model.isExporting, "Opening options must not write files")
        XCTAssertFalse(model.noteReviewQueue.hasWork)
        XCTAssertEqual(model.segments, evidence)
    }

    func testSettingsEntryOpensAndClosesWithoutChangingRecording() async throws {
        let (model, evidence, notebook) = try fixture()
        model.loadPresentationForTesting(phase: .recording, evidence: evidence, notebook: notebook)
        let (window, view) = try window(model: model, width: 1260)
        defer { window.close() }
        try await settle(view)
        // The point belongs to this test window's visible settings button,
        // checked against the retained 1260-wide render; no system-wide input.
        try click(window, content: view, x: view.bounds.width - 65, yFromTop: 24)
        try await Task.sleep(for: .milliseconds(300))
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        try await settle(content)
        try capture(content, name: "classroom-settings-sheet")
        let form = try XCTUnwrap(descendants(content).compactMap { $0 as? NSScrollView }
            .first { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height })
        let document = try XCTUnwrap(form.documentView)
        form.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - form.contentView.bounds.height))
        form.reflectScrolledClipView(form.contentView)
        try await settle(content)
        XCTAssertGreaterThan(form.contentView.bounds.minY, 0, "The lower settings must be reachable by scrolling")
        try capture(content, name: "classroom-settings-scrolled")
        try await closeSheet(sheet)
        XCTAssertNil(window.attachedSheet)
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
            try click(window, content: view, x: view.bounds.width - 168, yFromTop: 24)
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

    func testReviewAndNestedQueueManagerRemainReachable() async throws {
        let (model, evidence, notebook) = try fixture()
        model.loadPresentationForTesting(phase: .saved(URL(fileURLWithPath: "/synthetic-classroom")),
                                         evidence: evidence, notebook: notebook)
        let (window, view) = try window(model: model, width: 820, height: 700, notes: true)
        defer { window.close() }
        try await settle(view)
        XCTAssertTrue(model.canManuallyReview)
        XCTAssertEqual(model.reviewBatchChoices.count, notebook.batches.count)
        try click(window, content: view, x: 83, yFromTop: view.bounds.height - 123)
        try await Task.sleep(for: .milliseconds(300))
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        try await settle(content)
        try capture(content, name: "classroom-review-sheet")
        try click(sheet, content: content, x: content.bounds.width - 53, yFromTop: 88)
        try await Task.sleep(for: .milliseconds(300))
        let manager = try XCTUnwrap(sheet.attachedSheet)
        let managerContent = try XCTUnwrap(manager.contentView)
        try await settle(managerContent)
        try capture(managerContent, name: "classroom-review-queue-manager")
        try await closeSheet(manager)
        XCTAssertNil(sheet.attachedSheet)
        XCTAssertNotNil(window.attachedSheet)
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
        try click(window, content: view, x: 439, yFromTop: 132)
        try await settle(view)
        let notes = scrollFrames(in: view)
        XCTAssertLessThan(notes.count, before.count, "The compact notes tab must replace the caption view")
        try click(window, content: view, x: 382, yFromTop: 132)
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
        try click(window, content: view, x: historyFrame.maxX - 47, yFromTop: 152)
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
        try click(window, content: view, x: historyFrame.maxX - 47, yFromTop: 152)
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
        let nodes = elements(view)
        guard nodes.count > 2 else {
            throw XCTSkip("This in-process SwiftUI host exposes only the menu node; full keyboard and VoiceOver acceptance remains unverified")
        }
        for id in ["classroom-settings", "classroom-typed-translation", "classroom-record-stop", "classroom-status-details"] {
            _ = try element(id, in: view)
        }
    }
}
