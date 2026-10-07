import AppKit
import SwiftUI
import XCTest
@testable import LiveLingo

/// Real, never-ordered AppKit windows; no capture, permissions or model services.
@MainActor
final class FloatingSubtitleWindowTests: XCTestCase {
    private func defaults() throws -> (UserDefaults, String) {
        let suite = "FloatingSubtitleDisplay-\(UUID().uuidString)"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { try cleanup.remove() }
        return (defaults, suite)
    }

    private func window(panel: Bool = false) -> NSWindow {
        let frame = NSRect(x: 80, y: 100, width: 640, height: 350)
        let window = panel
            ? NSPanel(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func testAllSpacesDefaultsOnWithoutWritingPreferences() throws {
        let (store, suite) = try defaults()
        let preferences = FloatingSubtitlePreferences(store: store)
        XCTAssertTrue(preferences.showsAcrossSpaces)
        XCTAssertTrue(preferences.showsAcrossSpacesBinding.wrappedValue)
        XCTAssertTrue(store.persistentDomain(forName: suite)?.isEmpty ?? true)
    }

    func testAllSpacesBindingPersistsAndChangesNoOtherPreference() throws {
        let (store, suite) = try defaults()
        let preferences = FloatingSubtitlePreferences(store: store)
        preferences.showsAcrossSpacesBinding.wrappedValue = false
        let reopened = FloatingSubtitlePreferences(store: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertFalse(reopened.showsAcrossSpaces)
        XCTAssertEqual(store.persistentDomain(forName: suite)?.keys.sorted(), ["floatingShowsAcrossSpaces"])
        preferences.showsAcrossSpacesBinding.wrappedValue = true
        XCTAssertTrue(reopened.showsAcrossSpaces)
    }

    func testWindowUsesFloatingLevelAndAllSpacesWithoutConflictingRoles() {
        let window = window()
        defer { window.close() }
        let original: NSWindow.CollectionBehavior = [.moveToActiveSpace, .managed, .fullScreenPrimary,
                                                     .primary, .participatesInCycle]
        window.collectionBehavior = original
        let configuration = FloatingSubtitleWindowConfiguration(window: window)
        configuration.apply(FloatingSubtitleWindowSettings())
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(window.collectionBehavior,
                       [.managed, .participatesInCycle, .canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications])
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertFalse(window.isVisible)
        configuration.restore()
        XCTAssertEqual(window.level, .normal)
        XCTAssertEqual(window.collectionBehavior, original)
    }

    func testPanelReplacesAuxiliaryAndFullScreenNoneRoles() {
        let panel = window(panel: true)
        defer { panel.close() }
        let original: NSWindow.CollectionBehavior = [.auxiliary, .fullScreenNone, .transient, .ignoresCycle]
        panel.collectionBehavior = original
        let configuration = FloatingSubtitleWindowConfiguration(window: panel)
        configuration.apply(FloatingSubtitleWindowSettings())
        XCTAssertEqual(panel.level, .floating)
        XCTAssertEqual(panel.collectionBehavior,
                       [.transient, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications])
        XCTAssertFalse(panel.isVisible)
        configuration.apply(FloatingSubtitleWindowSettings(showsAcrossSpaces: false))
        XCTAssertEqual(panel.collectionBehavior, original)
        configuration.restore()
    }

    func testDisablingSettingsRestoresBehaviorMouseAndBackground() {
        for panel in [false, true] {
            let window = window(panel: panel)
            defer { window.close() }
            let originalBehavior = window.collectionBehavior
            let originalColor = NSColor.windowBackgroundColor
            window.backgroundColor = originalColor
            let configuration = FloatingSubtitleWindowConfiguration(window: window)
            for _ in 0..<3 {
                configuration.apply(.init(showsAcrossSpaces: true, isLocked: true, backgroundOpacity: 0.7))
                XCTAssertTrue(window.ignoresMouseEvents)
                XCTAssertFalse(window.isOpaque)
                XCTAssertEqual(window.backgroundColor, .clear)
                configuration.apply(.init(showsAcrossSpaces: false, isLocked: false, backgroundOpacity: 1))
                XCTAssertEqual(window.collectionBehavior, originalBehavior)
                XCTAssertFalse(window.ignoresMouseEvents)
                XCTAssertTrue(window.isOpaque)
                XCTAssertEqual(window.backgroundColor, originalColor)
                XCTAssertEqual(window.level, .floating, "Disabling cross-Space display still leaves a floating subtitle window")
            }
            configuration.restore()
            XCTAssertEqual(window.level, .normal)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testRestorePreservesNondefaultOriginalWindowProperties() {
        let panel = window(panel: true)
        defer { panel.close() }
        panel.level = .modalPanel
        panel.collectionBehavior = [.moveToActiveSpace, .auxiliary, .fullScreenNone]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .darkGray
        let configuration = FloatingSubtitleWindowConfiguration(window: panel)
        configuration.apply(.init(isLocked: true, backgroundOpacity: 0.75))
        configuration.restore()
        XCTAssertEqual(panel.level, .modalPanel)
        XCTAssertEqual(panel.collectionBehavior, [.moveToActiveSpace, .auxiliary, .fullScreenNone])
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .darkGray)
    }

    func testControllerTogglesMouseEventsImmediatelyWhileWindowRemainsHidden() {
        let window = window()
        defer { window.close() }
        let controller = FloatingSubtitleWindowController()
        controller.attach(to: window, showsAcrossSpaces: true, backgroundOpacity: 1)
        XCTAssertEqual(controller.lockActionTitle, "锁定浮动字幕")
        controller.toggleLock()
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertEqual(controller.lockActionTitle, "解锁浮动字幕")
        controller.toggleLock()
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertFalse(window.isVisible)
        controller.detach(from: window)
        XCTAssertEqual(window.level, .normal)
    }

    func testLockIsRuntimeOnlyAndFreshControllerStartsUnlocked() throws {
        let (store, suite) = try defaults()
        // Even an obsolete stored lock value must never lock a new launch.
        store.set(true, forKey: "floatingSubtitleLocked")
        FloatingSubtitlePreferences(store: store).showsAcrossSpaces = false
        let before = try XCTUnwrap(store.persistentDomain(forName: suite))
        let firstLaunch = FloatingSubtitleWindowController()
        XCTAssertFalse(firstLaunch.isLocked)
        firstLaunch.toggleLock()
        XCTAssertTrue(firstLaunch.isLocked)
        let secondLaunch = FloatingSubtitleWindowController()
        XCTAssertFalse(secondLaunch.isLocked)
        let window = window()
        defer { window.close() }
        let reopened = FloatingSubtitlePreferences(store: try XCTUnwrap(UserDefaults(suiteName: suite)))
        secondLaunch.attach(to: window, showsAcrossSpaces: reopened.showsAcrossSpaces, backgroundOpacity: 1)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertFalse(reopened.showsAcrossSpaces)
        XCTAssertTrue(NSDictionary(dictionary: before).isEqual(to: try XCTUnwrap(store.persistentDomain(forName: suite))))
        secondLaunch.detach(from: window)
    }

    func testLockAndUnlockWorkBeforeOpeningSubtitleWindow() {
        let controller = FloatingSubtitleWindowController()
        controller.toggleLock()
        let window = window()
        defer { window.close() }
        controller.attach(to: window, showsAcrossSpaces: true, backgroundOpacity: 1)
        XCTAssertTrue(window.ignoresMouseEvents)
        controller.detach(from: window)
        controller.toggleLock()
        controller.attach(to: window, showsAcrossSpaces: true, backgroundOpacity: 1)
        XCTAssertFalse(window.ignoresMouseEvents)
        controller.detach(from: window)
    }

    func testRepeatedControllerUpdatesDoNotReplaceTheOriginalSnapshot() {
        let window = window()
        defer { window.close() }
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        let controller = FloatingSubtitleWindowController()
        controller.attach(to: window, showsAcrossSpaces: true, backgroundOpacity: 0.75)
        controller.toggleLock()
        controller.attach(to: window, showsAcrossSpaces: false, backgroundOpacity: 1)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertEqual(window.collectionBehavior, [.moveToActiveSpace, .fullScreenNone])
        controller.toggleLock()
        controller.detach(from: window)
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertTrue(window.isOpaque)
        XCTAssertEqual(window.collectionBehavior, [.moveToActiveSpace, .fullScreenNone])
    }

    func testSwitchingSubtitleWindowRestoresOldWindowAndRetainsRuntimeLock() {
        let first = window()
        let second = window(panel: true)
        defer { first.close(); second.close() }
        let originalBehavior = first.collectionBehavior
        let controller = FloatingSubtitleWindowController()
        controller.attach(to: first, showsAcrossSpaces: true, backgroundOpacity: 0.7)
        controller.toggleLock()
        controller.attach(to: second, showsAcrossSpaces: true, backgroundOpacity: 1)
        XCTAssertEqual(first.level, .normal)
        XCTAssertEqual(first.collectionBehavior, originalBehavior)
        XCTAssertFalse(first.ignoresMouseEvents)
        XCTAssertTrue(first.isOpaque)
        XCTAssertTrue(second.ignoresMouseEvents)
        // A stale view detaching cannot release the new subtitle window.
        controller.detach(from: first)
        controller.toggleLock()
        XCTAssertFalse(second.ignoresMouseEvents)
        controller.detach(from: second)
    }

    func testSubtitleSettingsDoNotChangeTheMainWindow() {
        let main = window()
        let subtitle = window()
        defer { main.close(); subtitle.close() }
        let behavior = main.collectionBehavior
        let frame = main.frame
        let color = main.backgroundColor
        let controller = FloatingSubtitleWindowController()
        controller.attach(to: subtitle, showsAcrossSpaces: true, backgroundOpacity: 0.7)
        controller.toggleLock()
        XCTAssertEqual(main.level, .normal)
        XCTAssertEqual(main.collectionBehavior, behavior)
        XCTAssertFalse(main.ignoresMouseEvents)
        XCTAssertTrue(main.isOpaque)
        XCTAssertEqual(main.backgroundColor, color)
        XCTAssertEqual(main.frame, frame)
        controller.detach(from: subtitle)
    }

    func testBridgeReparentingRestoresOldWindowAndConfiguresNewWindow() {
        let first = window()
        let second = window(panel: true)
        defer { first.close(); second.close() }
        let controller = FloatingSubtitleWindowController()
        let bridge = FloatingSubtitleWindowBridge.View()
        bridge.controller = controller
        bridge.backgroundOpacity = 0.7
        first.contentView = bridge
        XCTAssertEqual(first.level, .floating)
        XCTAssertFalse(first.isOpaque)
        controller.toggleLock()
        second.contentView = bridge
        XCTAssertEqual(first.level, .normal)
        XCTAssertTrue(first.isOpaque)
        XCTAssertFalse(first.ignoresMouseEvents)
        XCTAssertEqual(second.level, .floating)
        XCTAssertTrue(second.ignoresMouseEvents)
        bridge.detach()
        XCTAssertFalse(second.ignoresMouseEvents)
        XCTAssertTrue(second.isOpaque)
        XCTAssertFalse(first.isVisible)
        XCTAssertFalse(second.isVisible)
    }

    func testBottomPlacementCentersWithinDifferentVisibleFrames() {
        let frames = [
            NSRect(x: 0, y: 68, width: 1440, height: 808),
            NSRect(x: -1920, y: 42, width: 1920, height: 1015),
            NSRect(x: 1440, y: 0, width: 2560, height: 1415),
            NSRect(x: -300, y: -1080, width: 1920, height: 1015),
            NSRect(x: 80, y: 900, width: 1200, height: 760),
            NSRect(x: 72, y: 0, width: 1368, height: 875)
        ]
        for visible in frames {
            let size = NSSize(width: 640, height: 350)
            let frame = FloatingSubtitleWindowPlacement.bottomFrame(windowSize: size, visibleFrame: visible)
            XCTAssertEqual(frame.size, size)
            XCTAssertEqual(frame.midX, visible.midX)
            XCTAssertEqual(frame.minY - visible.minY, 20)
            XCTAssertTrue(visible.contains(frame))
        }
    }

    func testBottomPlacementFitsShortVisibleAreaWithoutResizing() {
        let visible = NSRect(x: -1280, y: 64, width: 1280, height: 365)
        let size = NSSize(width: 640, height: 350)
        let frame = FloatingSubtitleWindowPlacement.bottomFrame(windowSize: size, visibleFrame: visible)
        XCTAssertEqual(frame.maxY, visible.maxY)
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY)
        XCTAssertEqual(frame.size, size)
        XCTAssertTrue(visible.contains(frame))
    }

    func testBottomPlacementPreservesLayoutOnAnUndersizedScreen() {
        let visible = NSRect(x: -500, y: -400, width: 500, height: 300)
        let size = NSSize(width: 640, height: 350)
        let frame = FloatingSubtitleWindowPlacement.bottomFrame(windowSize: size, visibleFrame: visible)
        XCTAssertEqual(frame.size, size)
        XCTAssertEqual(frame.midX, visible.midX)
        XCTAssertEqual(frame.minY, visible.minY)
    }

    func testBottomPlacementBoundsRequestedMargin() {
        let visible = NSRect(x: 100, y: 40, width: 1200, height: 800)
        let size = NSSize(width: 640, height: 350)
        let negative = FloatingSubtitleWindowPlacement.bottomFrame(windowSize: size, visibleFrame: visible, bottomInset: -20)
        XCTAssertEqual(negative.minY, visible.minY)
        let large = FloatingSubtitleWindowPlacement.bottomFrame(windowSize: size, visibleFrame: visible, bottomInset: 1000)
        XCTAssertEqual(large.maxY, visible.maxY)
    }

    func testMoveToBottomUsesTheSubtitleScreenAndKeepsTheWindowHidden() throws {
        let window = window()
        defer { window.close() }
        let controller = FloatingSubtitleWindowController()
        controller.attach(to: window, showsAcrossSpaces: true, backgroundOpacity: 1)
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main ?? NSScreen.screens.first)
        let originalSize = window.frame.size
        controller.moveToScreenBottom()
        XCTAssertEqual(window.frame.size, originalSize)
        XCTAssertEqual(window.frame.midX, screen.visibleFrame.midX, accuracy: 1)
        XCTAssertEqual(window.frame.minY, screen.visibleFrame.minY + 20, accuracy: 1)
        XCTAssertFalse(window.isVisible)
        controller.detach(from: window)
    }

    func testMoveRequestedBeforeOpeningWaitsForFinalWindowSize() async throws {
        let controller = FloatingSubtitleWindowController()
        controller.moveToScreenBottom()
        let window = window()
        defer { window.close() }
        controller.attach(to: window, showsAcrossSpaces: true, backgroundOpacity: 1)
        window.setContentSize(NSSize(width: 640, height: 390))
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main ?? NSScreen.screens.first)
        let finalSize = window.frame.size
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(window.frame.size, finalSize)
        XCTAssertEqual(window.frame.midX, screen.visibleFrame.midX, accuracy: 1)
        XCTAssertEqual(window.frame.minY, screen.visibleFrame.minY + 20, accuracy: 1)
        XCTAssertFalse(window.isVisible)
        controller.detach(from: window)
    }

    func testHostedLockBadgePreservesCaptionPixelsAndWindowSize() async throws {
        let temporary = FileManager.default.temporaryDirectory
        if let root = ProcessInfo.processInfo.environment["LIVELINGO_TEST_WORKSPACE"] {
            XCTAssertTrue(temporary.path.hasPrefix(root + "/"))
            guard temporary.path.hasPrefix(root + "/") else { throw CocoaError(.fileWriteInvalidFileName) }
        }
        let (store, _) = try defaults()
        let directory = temporary.appendingPathComponent("FloatingSubtitleDisplay-\(UUID().uuidString)")
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
                                       observeSleep: false, diagnostics: .disabled) { _, _, _, _ in
            XCTFail("Window tests must never invoke a generator")
            throw CancellationError()
        }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
                             backgroundServices: false, scheduledNotes: false, defaults: store)
        addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        model.loadPresentationForTesting(phase: .recording, evidence: [
            TranscriptSegment(startTime: 0, endTime: 2, english: "The water is cold.",
                              chinese: "水很冷。", sourceLanguage: "es")
        ])
        let controller = FloatingSubtitleWindowController()
        let host = NSHostingController(rootView: FloatingSubtitleView(windowController: controller)
            .environmentObject(model).defaultAppStorage(store))
        let window = window()
        defer { window.close() }
        window.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        window.setContentSize(host.view.fittingSize)
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutSubtreeIfNeeded()
        let frame = window.frame
        let unlocked = try bitmap(host.view)
        controller.toggleLock()
        try await Task.sleep(for: .milliseconds(150))
        host.view.layoutSubtreeIfNeeded()
        let locked = try bitmap(host.view)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(unlocked.pixelsWide, locked.pixelsWide)
        XCTAssertEqual(unlocked.pixelsHigh, locked.pixelsHigh)
        XCTAssertNotEqual(try pixels(unlocked), try pixels(locked), "The locked badge must be visible")
        let bodyStart = Int(70 * CGFloat(locked.pixelsHigh) / host.view.bounds.height) * locked.bytesPerRow
        XCTAssertEqual(try pixels(unlocked).dropFirst(bodyStart), try pixels(locked).dropFirst(bodyStart),
                       "The badge must not change caption text or layout")
        controller.toggleLock()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertEqual(try pixels(bitmap(host.view)), try pixels(unlocked))
        XCTAssertFalse(window.isVisible)
        if let screenshots = ProcessInfo.processInfo.environment["LIVELINGO_OVERLAY_SCREENSHOTS"] {
            let url = URL(fileURLWithPath: screenshots, isDirectory: true)
            try XCTUnwrap(locked.representation(using: .png, properties: [:]))
                .write(to: url.appendingPathComponent("floating-locked.png"))
            try XCTUnwrap(unlocked.representation(using: .png, properties: [:]))
                .write(to: url.appendingPathComponent("floating-unlocked.png"))
        }
        controller.detach(from: window)
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func pixels(_ bitmap: NSBitmapImageRep) throws -> Data {
        Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}
