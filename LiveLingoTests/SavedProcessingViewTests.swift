import AppKit
import SwiftUI
import XCTest
@testable import LiveLingo

/// Synthetic candidates in unshown windows; no playback or generation.
@MainActor
final class SavedProcessingViewTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows.removeAll()
        try await super.tearDown()
    }

    private func fixture() throws -> AppModel {
        let suite = "LiveLingo-Test-\(UUID().uuidString)"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        let root = TestFixtureDirectory.root.appendingPathComponent(suite, isDirectory: true)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
                XCTFail("Candidate layout tests must never invoke generation")
                throw CancellationError()
            }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
            backgroundServices: false, scheduledNotes: false, defaults: defaults)
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            try cleanup.remove()
        }
        return model
    }

    private func candidate(_ text: String = "Synthetic candidate") -> TranscriptionCandidate {
        .init(id: UUID(), sessionID: UUID(), originalText: "Synthetic original", text: text,
            start: 10, end: 20,
            audioURL: TestFixtureDirectory.root.appendingPathComponent("synthetic-unopened.wav"),
            origin: "context")
    }

    private func host(model: AppModel, candidate: TranscriptionCandidate, height: CGFloat,
                      dark: Bool = false) async throws -> NSHostingController<AnyView> {
        let controller = NSHostingController(rootView: AnyView(
            TranscriptionCandidateEditor(model: model, candidate: candidate, revision: 1)
                .environment(\.colorScheme, dark ? .dark : .light)))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 820, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(.init(width: 820, height: height))
        windows.append(window)
        try await settle(controller.view)
        XCTAssertFalse(window.isVisible)
        return controller
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func editor(in view: NSView) throws -> NSTextView {
        let editors = descendants(view).compactMap { $0 as? NSTextView }.filter(\.isEditable)
        XCTAssertEqual(editors.count, 1)
        return try XCTUnwrap(editors.first)
    }

    func testEditorUsesFullColumnWidthAndBoundedHeightInTallWindows() async throws {
        let model = try fixture()
        for dark in [false, true] {
            for height in [CGFloat(520), CGFloat(920)] {
                let controller = try await host(model: model, candidate: candidate(), height: height, dark: dark)
                let scroll = try XCTUnwrap(editor(in: controller.view).enclosingScrollView)
                let viewport = scroll.convert(scroll.bounds, to: controller.view)
                // Measure the native scroll view, including any reserved scroller
                // lane, then include the six-point SwiftUI inset on each edge.
                let surface = viewport.insetBy(dx: -6, dy: -6)
                XCTAssertGreaterThanOrEqual(surface.height, 100 - 0.5)
                XCTAssertLessThanOrEqual(surface.height, 200 + 0.5,
                    "The card must not stretch to fill a tall snapshot host")
                let contentWidth = controller.view.bounds.width - 28
                XCTAssertEqual(surface.width, (contentWidth - 14) / 2, accuracy: 0.5,
                    "Original and candidate columns must have equal width")
                XCTAssertEqual(surface.maxX, controller.view.bounds.maxX - 14, accuracy: 0.5,
                    "The editor surface must reach the card's content edge")
            }
        }
    }

    func testLongCandidateRemainsScrollableAndEditableWithinBoundedViewport() async throws {
        let model = try fixture()
        let text = (1...100).map { "Synthetic candidate line \($0)" }.joined(separator: "\n")
        let source = candidate(text)
        let controller = try await host(model: model, candidate: source, height: 920)
        let editor = try editor(in: controller.view)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertEqual(editor.string, text, "Height limits must not truncate the draft")
        XCTAssertLessThanOrEqual(scroll.bounds.height + 12, 200 + 0.5)
        XCTAssertGreaterThan(scroll.documentVisibleRect.height, 0)
        XCTAssertGreaterThan(editor.bounds.height, scroll.documentVisibleRect.height,
            "Long text must remain available by scrolling inside the bounded editor")
        let window = try XCTUnwrap(controller.view.window)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("\nSynthetic user edit", replacementRange: .init(location: text.utf16.count, length: 0))
        try await settle(controller.view)
        XCTAssertEqual(try self.editor(in: controller.view).string, text + "\nSynthetic user edit")
        XCTAssertFalse(window.isVisible)
    }

    func testEditorOutlineIsVisibleAgainstItsActualFillInBothAppearances() async throws {
        let model = try fixture()
        for dark in [false, true] {
            let controller = try await host(model: model, candidate: candidate(), height: 520, dark: dark)
            let view = controller.view
            let scroll = try XCTUnwrap(editor(in: view).enclosingScrollView)
            let surface = view.convert(scroll.bounds, from: scroll).insetBy(dx: -6, dy: -6)
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            let scale = CGFloat(image.pixelsWide) / view.bounds.width
            func sample(_ y: CGFloat) throws -> NSColor {
                try XCTUnwrap(image.colorAt(x: Int(surface.midX * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
            }
            let outline = try sample(surface.minY + 0.25)
            let fill = try sample(surface.minY + 4)
            XCTAssertGreaterThan(abs(outline.redComponent - fill.redComponent), 0.18,
                                 "A declared stroke must be visibly different from the real editor surface")
        }
    }
}
