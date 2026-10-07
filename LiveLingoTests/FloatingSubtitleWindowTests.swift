import AppKit
import SwiftUI
import XCTest
@testable import LiveLingo

/// Real AppKit panels with synthetic captions and isolated preferences. Only the
/// orderFront regression orders a panel, at zero alpha and without activation.
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

    func testPreparingWindowCreatesAnOwnedNonactivatingFixedSizePanelWithoutShowingIt() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let controller = FloatingSubtitleWindowController(defaults: fixture.defaults)
        XCTAssertNil(controller.window)
        XCTAssertNil(controller.panel)
        let panel = controller.prepareWindow(model: fixture.model)
        defer { controller.close() }
        let view = try XCTUnwrap(panel.contentView as? NSHostingView<AnyView>)
        try await settle(view)
        XCTAssertTrue(controller.window === panel)
        XCTAssertTrue(controller.panel === panel)
        XCTAssertTrue(panel.windowController === controller)
        XCTAssertTrue(panel.delegate === controller)
        let requiredStyles: [NSWindow.StyleMask] = [.titled, .closable, .miniaturizable, .nonactivatingPanel]
        for style in requiredStyles {
            XCTAssertTrue(panel.styleMask.contains(style))
        }
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.isRestorable)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
        XCTAssertTrue(panel.collectionBehavior.intersection(
            [.moveToActiveSpace, .fullScreenPrimary, .fullScreenNone, .primary, .auxiliary]).isEmpty)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(view.bounds.width, 640)
        XCTAssertGreaterThan(view.bounds.height, 0)
        XCTAssertEqual(view.bounds.size, view.fittingSize)
        XCTAssertEqual(panel.contentMinSize, view.bounds.size)
        XCTAssertEqual(panel.contentMaxSize, view.bounds.size)
        XCTAssertTrue(controller.prepareWindow(model: fixture.model) === panel)
        XCTAssertTrue(panel.contentView === view)
    }

    func testControllerTogglesMouseEventsImmediatelyWhilePanelRemainsHidden() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let controller = FloatingSubtitleWindowController(defaults: fixture.defaults)
        let panel = controller.prepareWindow(model: fixture.model)
        defer { controller.close() }
        try await settle(try XCTUnwrap(panel.contentView))
        XCTAssertEqual(controller.lockActionTitle, "锁定浮动字幕")
        controller.toggleLock()
        XCTAssertTrue(controller.isLocked)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(controller.lockActionTitle, "解锁浮动字幕")
        controller.toggleLock()
        XCTAssertFalse(controller.isLocked)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.level, .floating)
    }

    func testLockIsRuntimeOnlyAndFreshControllerStartsUnlocked() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let store = fixture.defaults
        // Even an obsolete stored lock value must never lock a new launch.
        store.set(true, forKey: "floatingSubtitleLocked")
        FloatingSubtitlePreferences(store: store).showsAcrossSpaces = false
        let before = try XCTUnwrap(store.persistentDomain(forName: fixture.suite))
        let firstLaunch = FloatingSubtitleWindowController(defaults: store)
        XCTAssertFalse(firstLaunch.isLocked)
        firstLaunch.toggleLock()
        XCTAssertTrue(firstLaunch.isLocked)
        XCTAssertNil(firstLaunch.window)
        let secondLaunch = FloatingSubtitleWindowController(defaults: store)
        XCTAssertFalse(secondLaunch.isLocked)
        XCTAssertNil(secondLaunch.window)
        XCTAssertTrue(NSDictionary(dictionary: before).isEqual(
            to: try XCTUnwrap(store.persistentDomain(forName: fixture.suite))))
        let reopened = FloatingSubtitlePreferences(store: try XCTUnwrap(UserDefaults(suiteName: fixture.suite)))
        let panel = secondLaunch.prepareWindow(model: fixture.model)
        defer { secondLaunch.close() }
        try await settle(try XCTUnwrap(panel.contentView))
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertFalse(reopened.showsAcrossSpaces)
        XCTAssertTrue(store.bool(forKey: "floatingSubtitleLocked"), "Runtime locking must not rewrite obsolete preferences")
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.isVisible)
    }

    func testLockAndUnlockWorkBeforePreparingSubtitlePanel() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let controller = FloatingSubtitleWindowController(defaults: fixture.defaults)
        controller.toggleLock()
        XCTAssertNil(controller.window)
        let panel = controller.prepareWindow(model: fixture.model)
        defer { controller.close() }
        try await settle(try XCTUnwrap(panel.contentView))
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isVisible)
        controller.close()
        XCTAssertNil(controller.window)
        XCTAssertNil(controller.panel)
        XCTAssertNil(panel.contentView)
        XCTAssertTrue(panel.ignoresMouseEvents)
        controller.toggleLock()
        let reopened = controller.prepareWindow(model: fixture.model)
        XCTAssertFalse(reopened === panel)
        XCTAssertFalse(reopened.ignoresMouseEvents)
        XCTAssertFalse(reopened.isVisible)

        let another = FloatingSubtitleWindowController(defaults: fixture.defaults)
        another.toggleLock()
        another.toggleLock()
        XCTAssertNil(another.window)
        let unlockedPanel = another.prepareWindow(model: fixture.model)
        defer { another.close() }
        XCTAssertFalse(unlockedPanel.ignoresMouseEvents)
        XCTAssertFalse(unlockedPanel.isVisible)
    }

    func testRepeatedControllerUpdatesPreserveTheOwnedPanelsOriginalProperties() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        FloatingSubtitlePreferences(store: fixture.defaults).showsAcrossSpaces = false
        let controller = FloatingSubtitleWindowController(defaults: fixture.defaults)
        let panel = controller.prepareWindow(model: fixture.model)
        defer { controller.close() }
        try await settle(try XCTUnwrap(panel.contentView))
        let original = WindowSnapshot(panel)
        for _ in 0..<3 {
            controller.updateSettings(showsAcrossSpaces: true, backgroundOpacity: 0.75)
            controller.toggleLock()
            XCTAssertTrue(panel.ignoresMouseEvents)
            XCTAssertFalse(panel.isOpaque)
            XCTAssertEqual(panel.backgroundColor, .clear)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            controller.updateSettings(showsAcrossSpaces: false, backgroundOpacity: 1)
            XCTAssertTrue(panel.ignoresMouseEvents, "Preference updates must preserve the runtime lock")
            XCTAssertEqual(panel.collectionBehavior, original.behavior)
            controller.toggleLock()
            assertWindow(panel, matches: original)
            XCTAssertEqual(panel.level, .floating)
        }
    }

    func testShowAndHideReuseThePanelWithoutActivatingAndCloseReopensANewLockedPanel() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let preferences = FloatingSubtitlePreferences(store: fixture.defaults)
        preferences.showsAcrossSpaces = true
        preferences.backgroundOpacity = 0.7
        let controller = FloatingSubtitleWindowController(defaults: fixture.defaults)
        let panel = controller.prepareWindow(model: fixture.model)
        defer { controller.close() }
        let view = try XCTUnwrap(panel.contentView)
        try await settle(view)
        controller.toggleLock()
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        // Exercise the real orderFront path without a visible or active window.
        panel.alphaValue = 0
        let before = WindowSnapshot(panel)
        let app = NSApplication.shared
        let active = app.isActive
        let keyWindow = app.keyWindow
        let activationPolicy = app.activationPolicy()
        for _ in 0..<2 {
            controller.show(model: fixture.model)
            try await settle(view)
            XCTAssertTrue(panel.isVisible)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertEqual(panel.alphaValue, 0)
            XCTAssertFalse(panel.isKeyWindow)
            XCTAssertTrue(app.keyWindow === keyWindow)
            XCTAssertEqual(app.isActive, active)
            XCTAssertEqual(app.activationPolicy(), activationPolicy)
            controller.hide()
            try await settle(view)
            assertWindow(panel, matches: before)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertTrue(controller.isLocked)
            XCTAssertTrue(controller.panel === panel)
            XCTAssertTrue(controller.window === panel)
            XCTAssertTrue(controller.prepareWindow(model: fixture.model) === panel)
            XCTAssertTrue(panel.contentView === view)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        }
        // AppKit ordering itself must keep the policy, with no controller
        // reapplication between orderOut and orderFront.
        panel.orderOut(nil)
        panel.orderFront(nil)
        try await settle(view)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.collectionBehavior, before.behavior)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        panel.orderOut(nil)
        try await settle(view)
        assertWindow(panel, matches: before)
        controller.close()
        assertWindow(panel, matches: before)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertNil(controller.window)
        XCTAssertNil(controller.panel)
        XCTAssertNil(panel.contentView)
        XCTAssertTrue(controller.isLocked)
        let reopened = controller.prepareWindow(model: fixture.model)
        let reopenedView = try XCTUnwrap(reopened.contentView)
        try await settle(reopenedView)
        XCTAssertFalse(reopened === panel)
        XCTAssertFalse(reopened.contentView === view)
        XCTAssertFalse(reopened.isVisible)
        XCTAssertTrue(reopened.ignoresMouseEvents)
        XCTAssertEqual(reopened.level, .floating)
        XCTAssertEqual(reopened.collectionBehavior, before.behavior)
        XCTAssertTrue(reopened.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(reopened.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(reopened.frame.minX, before.frame.minX, accuracy: 1)
        XCTAssertEqual(reopened.frame.maxY, before.frame.maxY, accuracy: 1)
        XCTAssertFalse(reopened.isOpaque)
        XCTAssertEqual(reopened.backgroundColor, .clear)
        reopened.alphaValue = 0
        controller.show(model: fixture.model)
        try await settle(reopenedView)
        XCTAssertTrue(controller.panel === reopened)
        XCTAssertTrue(reopened.isVisible)
        XCTAssertTrue(reopened.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(reopened.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(reopened.alphaValue, 0)
        XCTAssertFalse(reopened.isKeyWindow)
        XCTAssertTrue(app.keyWindow === keyWindow)
        XCTAssertEqual(app.isActive, active)
        XCTAssertEqual(app.activationPolicy(), activationPolicy)
        controller.hide()
        try await settle(reopenedView)
        XCTAssertTrue(reopened.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(reopened.collectionBehavior.contains(.fullScreenAuxiliary))
        controller.toggleLock()
        XCTAssertFalse(reopened.ignoresMouseEvents)
        XCTAssertFalse(reopened.isVisible)
        XCTAssertFalse(reopened.isOpaque)
        XCTAssertEqual(reopened.backgroundColor, .clear)
        XCTAssertTrue(reopened.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(reopened.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    func testTitlebarCloseSavesFrameAndReleasesTheHostWithoutResettingLockOrSettings() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let preferences = FloatingSubtitlePreferences(store: fixture.defaults)
        preferences.showsAcrossSpaces = false
        preferences.backgroundOpacity = 0.75
        let controller = FloatingSubtitleWindowController(defaults: fixture.defaults)
        let panel = controller.prepareWindow(model: fixture.model)
        defer { controller.close() }
        try await settle(try XCTUnwrap(panel.contentView))
        controller.toggleLock()
        let savedFrame = panel.frame
        let descriptor = panel.frameDescriptor
        panel.performClose(nil)
        XCTAssertNil(controller.window)
        XCTAssertNil(controller.panel)
        XCTAssertNil(panel.contentView)
        XCTAssertTrue(controller.isLocked)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(fixture.defaults.string(forKey: FloatingSubtitleWindowController.frameDefaultsKey), descriptor)
        let reopened = controller.prepareWindow(model: fixture.model)
        XCTAssertFalse(reopened === panel)
        XCTAssertTrue(reopened.ignoresMouseEvents)
        XCTAssertFalse(reopened.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(reopened.isOpaque)
        XCTAssertEqual(reopened.backgroundColor, .clear)
        XCTAssertEqual(reopened.frame.minX, savedFrame.minX, accuracy: 1)
        XCTAssertEqual(reopened.frame.maxY, savedFrame.maxY, accuracy: 1)
        XCTAssertFalse(reopened.isVisible)
    }

    func testClosingBreaksTheHostingViewControllerRetainCycle() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        weak var closedController: FloatingSubtitleWindowController?
        weak var closedHost: NSView?
        autoreleasepool {
            let controller = FloatingSubtitleWindowController(defaults: fixture.defaults)
            let panel = controller.prepareWindow(model: fixture.model)
            closedController = controller
            closedHost = panel.contentView
            XCTAssertNotNil(closedHost)
            controller.toggleLock()
            controller.close()
            XCTAssertNil(controller.window)
            XCTAssertNil(controller.panel)
            XCTAssertNil(panel.contentView)
            XCTAssertTrue(controller.isLocked)
            XCTAssertFalse(panel.isVisible)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(closedHost, "Closing must release the hosting view that observes its controller")
        XCTAssertNil(closedController, "The panel and hosted content must not keep a closed controller alive")
    }

    func testHideAndUnhideNotificationsReapplySettingsWithoutShowingOrUnlockingThePanel() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let preferences = FloatingSubtitlePreferences(store: fixture.defaults)
        preferences.showsAcrossSpaces = true
        preferences.backgroundOpacity = 0.7
        let center = NotificationCenter()
        let controller = FloatingSubtitleWindowController(defaults: fixture.defaults, notificationCenter: center)
        let panel = controller.prepareWindow(model: fixture.model)
        defer { controller.close() }
        try await settle(try XCTUnwrap(panel.contentView))
        controller.toggleLock()
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        let before = WindowSnapshot(panel)
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            panel.level = .normal
            panel.collectionBehavior = [.primary, .fullScreenNone]
            panel.ignoresMouseEvents = false
            panel.isOpaque = true
            panel.backgroundColor = .red
            center.post(name: name, object: NSApplication.shared)
            try await settle(try XCTUnwrap(panel.contentView))
            assertWindow(panel, matches: before)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertTrue(controller.isLocked)
            XCTAssertTrue(controller.panel === panel)
        }
    }

    func testNotificationsAndUnopenedActionsDoNotCreateAPanelOrWriteVisibility() throws {
        let (store, suite) = try defaults()
        let center = NotificationCenter()
        let controller = FloatingSubtitleWindowController(defaults: store, notificationCenter: center)
        controller.updateSettings(showsAcrossSpaces: false, backgroundOpacity: 0.7)
        controller.moveToScreenBottom()
        controller.hide()
        controller.close()
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.post(name: name, object: NSApplication.shared)
        }
        XCTAssertNil(controller.window)
        XCTAssertNil(controller.panel)
        XCTAssertFalse(controller.isLocked)
        XCTAssertTrue(store.persistentDomain(forName: suite)?.isEmpty ?? true)
    }

    func testHostedSubtitleViewCannotTakeOverOrModifyUnrelatedMainWindows() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let preferences = FloatingSubtitlePreferences(store: fixture.defaults)
        preferences.showsAcrossSpaces = false
        let center = NotificationCenter()
        let screens = FloatingSubtitleWindowScreens(
            windowVisibleFrame: { _ in NSRect(x: -1920, y: 42, width: 1920, height: 1015) },
            mainVisibleFrame: { NSRect(x: 0, y: 80, width: 1440, height: 820) },
            firstVisibleFrame: { NSRect(x: 1440, y: 100, width: 2560, height: 1415) })
        let controller = FloatingSubtitleWindowController(defaults: fixture.defaults, screens: screens,
                                                          notificationCenter: center)
        let panel = controller.prepareWindow(model: fixture.model)
        defer { controller.close() }
        let ownedView = try XCTUnwrap(panel.contentView)
        try await settle(ownedView)
        let main = window()
        let secondMain = window()
        defer { main.close(); secondMain.close() }
        for mainWindow in [main, secondMain] {
            mainWindow.level = .modalPanel
            mainWindow.collectionBehavior = [.moveToActiveSpace, .managed, .fullScreenNone, .auxiliary]
            mainWindow.ignoresMouseEvents = true
            mainWindow.isOpaque = false
            mainWindow.backgroundColor = .darkGray
        }
        secondMain.setFrameOrigin(NSPoint(x: 120, y: 160))
        let originalMain = WindowSnapshot(main)
        let originalSecondMain = WindowSnapshot(secondMain)
        let mainContent = try XCTUnwrap(main.contentView)
        let secondMainContent = try XCTUnwrap(secondMain.contentView)
        let host = NSHostingView(rootView: AnyView(FloatingSubtitleView(windowController: controller)
            .environmentObject(fixture.model).defaultAppStorage(fixture.defaults)))
        // The main window owns its layout. Keep caption intrinsic sizing from
        // changing these foreign hosts, so their frames catch controller writes.
        host.sizingOptions = []
        host.frame = mainContent.bounds
        host.autoresizingMask = [.width, .height]
        mainContent.addSubview(host)
        try await settle(host)
        assertWindow(main, matches: originalMain)
        assertWindow(secondMain, matches: originalSecondMain)

        preferences.showsAcrossSpaces = true
        preferences.backgroundOpacity = 0.75
        try await settle(host)
        try await settle(ownedView)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        controller.toggleLock()
        XCTAssertTrue(panel.ignoresMouseEvents)
        controller.moveToScreenBottom()
        XCTAssertEqual(panel.frame.midX, -960, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, 62, accuracy: 1)
        assertWindow(main, matches: originalMain)
        assertWindow(secondMain, matches: originalSecondMain)

        // Move the same live host to another ordinary window. Neither its old
        // nor its new host may replace the controller's self-owned panel.
        host.removeFromSuperview()
        host.frame = secondMainContent.bounds
        secondMainContent.addSubview(host)
        try await settle(host)
        preferences.showsAcrossSpaces = false
        preferences.backgroundOpacity = 1
        try await settle(host)
        try await settle(ownedView)
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.isOpaque)
        XCTAssertNotEqual(panel.backgroundColor, .clear)
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.post(name: name, object: NSApplication.shared)
            try await settle(ownedView)
            XCTAssertTrue(controller.isLocked)
            XCTAssertFalse(panel.isVisible)
            assertWindow(main, matches: originalMain)
            assertWindow(secondMain, matches: originalSecondMain)
        }
        host.removeFromSuperview()
        controller.toggleLock()
        XCTAssertFalse(panel.ignoresMouseEvents)
        controller.hide()
        controller.close()
        XCTAssertNil(controller.window)
        XCTAssertNil(controller.panel)
        XCTAssertNil(panel.contentView)
        let reopened = controller.prepareWindow(model: fixture.model)
        XCTAssertFalse(reopened === panel)
        XCTAssertFalse(reopened.contentView === ownedView)
        XCTAssertFalse(reopened.isVisible)
        assertWindow(main, matches: originalMain)
        assertWindow(secondMain, matches: originalSecondMain)
    }

    func testSavedFrameDoesNotCreateOrLockAPanelOnAFreshController() throws {
        let (store, suite) = try defaults()
        _ = try saveReferenceFrame(in: store)
        store.set(true, forKey: "floatingSubtitleLocked")
        let before = try XCTUnwrap(store.persistentDomain(forName: suite))
        let controller = FloatingSubtitleWindowController(defaults: store)
        XCTAssertEqual(FloatingSubtitleWindowController.frameAutosaveName, "subtitles")
        XCTAssertEqual(FloatingSubtitleWindowController.frameDefaultsKey, "NSWindow Frame subtitles")
        XCTAssertNil(controller.window)
        XCTAssertNil(controller.panel)
        XCTAssertFalse(controller.isLocked)
        XCTAssertEqual(controller.lockActionTitle, "锁定浮动字幕")
        XCTAssertTrue(NSDictionary(dictionary: before).isEqual(
            to: try XCTUnwrap(store.persistentDomain(forName: suite))))
    }

    func testPreparingRestoresSavedTopLeftButUsesTheFinalFixedContentSize() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let saved = try saveReferenceFrame(in: fixture.defaults)
        let controller = FloatingSubtitleWindowController(defaults: fixture.defaults)
        XCTAssertNil(controller.window)
        let panel = controller.prepareWindow(model: fixture.model)
        defer { controller.close() }
        let view = try XCTUnwrap(panel.contentView as? NSHostingView<AnyView>)
        try await settle(view)
        XCTAssertEqual(panel.frame.minX, saved.minX, accuracy: 1)
        XCTAssertEqual(panel.frame.maxY, saved.maxY, accuracy: 1)
        XCTAssertNotEqual(panel.frame.height, saved.height, "Restoration must not import an obsolete content height")
        XCTAssertEqual(view.bounds.size, view.fittingSize)
        XCTAssertEqual(panel.contentMinSize, view.bounds.size)
        XCTAssertEqual(panel.contentMaxSize, view.bounds.size)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.ignoresMouseEvents)
    }

    func testCloseSavesPositionInTheInjectedSuiteAndFreshControllerRestoresOnlyPosition() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let preferences = FloatingSubtitlePreferences(store: fixture.defaults)
        preferences.showsAcrossSpaces = false
        preferences.backgroundOpacity = 0.75
        let first = FloatingSubtitleWindowController(defaults: fixture.defaults)
        let panel = first.prepareWindow(model: fixture.model)
        defer { first.close() }
        try await settle(try XCTUnwrap(panel.contentView))
        let visible = try XCTUnwrap(NSScreen.screens.first?.visibleFrame)
        panel.setFrameTopLeftPoint(NSPoint(x: visible.minX + 40, y: visible.maxY - 50))
        let savedFrame = panel.frame
        let contentSize = try XCTUnwrap(panel.contentView).bounds.size
        let savedString = panel.frameDescriptor
        first.toggleLock()
        first.close()
        XCTAssertNil(first.window)
        XCTAssertNil(first.panel)
        XCTAssertNil(panel.contentView)
        XCTAssertTrue(first.isLocked)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(fixture.defaults.string(forKey: FloatingSubtitleWindowController.frameDefaultsKey), savedString)
        XCTAssertNil(fixture.defaults.object(forKey: "floatingSubtitleLocked"))
        XCTAssertEqual(fixture.defaults.persistentDomain(forName: fixture.suite)?.keys.sorted(),
                       ["NSWindow Frame subtitles", "floatingBackgroundOpacity", "floatingShowsAcrossSpaces"])

        let reopened = try XCTUnwrap(UserDefaults(suiteName: fixture.suite))
        let fresh = FloatingSubtitleWindowController(defaults: reopened)
        XCTAssertNil(fresh.window)
        XCTAssertNil(fresh.panel)
        XCTAssertFalse(fresh.isLocked)
        let restored = fresh.prepareWindow(model: fixture.model)
        defer { fresh.close() }
        try await settle(try XCTUnwrap(restored.contentView))
        XCTAssertFalse(restored === panel)
        XCTAssertEqual(restored.frame.minX, savedFrame.minX, accuracy: 1)
        XCTAssertEqual(restored.frame.maxY, savedFrame.maxY, accuracy: 1)
        XCTAssertEqual(restored.contentView?.bounds.size, contentSize)
        XCTAssertFalse(restored.isVisible)
        XCTAssertFalse(restored.ignoresMouseEvents)
        XCTAssertFalse(restored.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(restored.isOpaque)
        XCTAssertEqual(restored.backgroundColor, .clear)
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

    func testScreenSelectionUsesWindowThenMainThenFirstAndReturnsNilWhenAbsent() {
        let reference = window()
        defer { reference.close() }
        let windowFrame = NSRect(x: -1920, y: 42, width: 1920, height: 1015)
        let mainFrame = NSRect(x: 0, y: 80, width: 1440, height: 820)
        let firstFrame = NSRect(x: 1440, y: 100, width: 2560, height: 1415)
        let cases: [(NSRect?, NSRect?, NSRect?, NSRect?, [String])] = [
            (windowFrame, mainFrame, firstFrame, windowFrame, ["window"]),
            (nil, mainFrame, firstFrame, mainFrame, ["window", "main"]),
            (nil, nil, firstFrame, firstFrame, ["window", "main", "first"]),
            (nil, nil, nil, nil, ["window", "main", "first"])
        ]
        for (windowFrame, mainFrame, firstFrame, expected, expectedQueries) in cases {
            var queries: [String] = []
            let screens = FloatingSubtitleWindowScreens(windowVisibleFrame: { queriedWindow in
                XCTAssertTrue(queriedWindow === reference)
                queries.append("window")
                return windowFrame
            }, mainVisibleFrame: {
                queries.append("main")
                return mainFrame
            }, firstVisibleFrame: {
                queries.append("first")
                return firstFrame
            })
            XCTAssertEqual(screens.visibleFrame(for: reference), expected)
            XCTAssertEqual(queries, expectedQueries)
        }
    }

    func testMoveToBottomUsesTheInjectedSubtitleScreenAndKeepsThePanelHidden() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        var queriedWindow: NSWindow?
        var queries: [String] = []
        let screens = FloatingSubtitleWindowScreens(windowVisibleFrame: { panel in
            queriedWindow = panel
            queries.append("window")
            return NSRect(x: -1920, y: 42, width: 1920, height: 1015)
        }, mainVisibleFrame: {
            queries.append("main")
            return NSRect(x: 0, y: 80, width: 1440, height: 820)
        }, firstVisibleFrame: {
            queries.append("first")
            return NSRect(x: 1440, y: 100, width: 2560, height: 1415)
        })
        let controller = FloatingSubtitleWindowController(defaults: fixture.defaults, screens: screens)
        let panel = controller.prepareWindow(model: fixture.model)
        defer { controller.close() }
        try await settle(try XCTUnwrap(panel.contentView))
        let originalSize = panel.frame.size
        queries.removeAll()
        controller.moveToScreenBottom()
        XCTAssertTrue(queriedWindow === panel)
        XCTAssertEqual(queries, ["window"], "An available non-main panel screen must short-circuit both fallbacks")
        XCTAssertEqual(panel.frame.size, originalSize)
        XCTAssertEqual(panel.frame.midX, -960, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, 62, accuracy: 1)
        XCTAssertFalse(panel.isVisible)
    }

    func testControllerBottomPlacementUsesMainAndFirstScreenFallbacks() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let mainFrame = NSRect(x: 0, y: 80, width: 1440, height: 820)
        let firstFrame = NSRect(x: 1440, y: 100, width: 2560, height: 1415)
        let cases: [(NSRect?, CGFloat, CGFloat, [String])] = [
            (mainFrame, 720, 100, ["window", "main"]),
            (nil, 2720, 120, ["window", "main", "first"])
        ]
        for (mainFrame, expectedMidX, expectedBottom, expectedQueries) in cases {
            var queries: [String] = []
            let screens = FloatingSubtitleWindowScreens(windowVisibleFrame: { _ in
                queries.append("window")
                return nil
            }, mainVisibleFrame: {
                queries.append("main")
                return mainFrame
            }, firstVisibleFrame: {
                queries.append("first")
                return firstFrame
            })
            let controller = FloatingSubtitleWindowController(defaults: fixture.defaults, screens: screens)
            let panel = controller.prepareWindow(model: fixture.model)
            defer { controller.close() }
            try await settle(try XCTUnwrap(panel.contentView))
            let originalSize = panel.frame.size
            queries.removeAll()
            controller.moveToScreenBottom()
            XCTAssertEqual(queries, expectedQueries)
            XCTAssertEqual(panel.frame.size, originalSize)
            XCTAssertEqual(panel.frame.midX, expectedMidX, accuracy: 1)
            XCTAssertEqual(panel.frame.minY, expectedBottom, accuracy: 1)
            XCTAssertFalse(panel.isVisible)
        }
    }

    func testMoveRequestedBeforePreparingWinsOverSavedPositionAfterFinalLayout() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let saved = try saveReferenceFrame(in: fixture.defaults)
        var queriedWindow: NSWindow?
        let screens = FloatingSubtitleWindowScreens(windowVisibleFrame: { panel in
            queriedWindow = panel
            return NSRect(x: 1440, y: 100, width: 2560, height: 1415)
        }, mainVisibleFrame: { NSRect(x: 0, y: 80, width: 1440, height: 820) },
           firstVisibleFrame: { NSRect(x: -1920, y: 42, width: 1920, height: 1015) })
        let controller = FloatingSubtitleWindowController(defaults: fixture.defaults, screens: screens)
        controller.moveToScreenBottom()
        XCTAssertNil(controller.window)
        XCTAssertNil(queriedWindow)
        let panel = controller.prepareWindow(model: fixture.model)
        defer { controller.close() }
        let view = try XCTUnwrap(panel.contentView as? NSHostingView<AnyView>)
        let placedFrame = panel.frame
        try await settle(view)
        XCTAssertTrue(queriedWindow === panel)
        XCTAssertEqual(panel.frame, placedFrame, "Deferred placement must already use the final frame, without a later jump")
        XCTAssertEqual(view.bounds.size, view.fittingSize)
        XCTAssertEqual(panel.contentMinSize, view.bounds.size)
        XCTAssertEqual(panel.contentMaxSize, view.bounds.size)
        XCTAssertNotEqual(panel.frame.size, saved.size)
        XCTAssertEqual(panel.frame.midX, 2720, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, 120, accuracy: 1)
        XCTAssertFalse(panel.isVisible)
        let movedFrame = panel.frame
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + 30, y: panel.frame.minY + 40))
        let manuallyMoved = panel.frame
        XCTAssertNotEqual(manuallyMoved, movedFrame)
        XCTAssertTrue(controller.prepareWindow(model: fixture.model) === panel)
        XCTAssertEqual(panel.frame, manuallyMoved, "The consumed pending request must not reposition a reused panel")
    }

    func testMoveWithoutAnyScreenLeavesThePreparedPanelUnchangedAndHidden() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let screens = FloatingSubtitleWindowScreens(windowVisibleFrame: { _ in nil },
                                                    mainVisibleFrame: { nil }, firstVisibleFrame: { nil })
        let controller = FloatingSubtitleWindowController(defaults: fixture.defaults, screens: screens)
        let panel = controller.prepareWindow(model: fixture.model)
        defer { controller.close() }
        try await settle(try XCTUnwrap(panel.contentView))
        let original = WindowSnapshot(panel)
        controller.moveToScreenBottom()
        assertWindow(panel, matches: original)
    }

    func testHostedLockBadgePreservesCaptionPixelsAndWindowSize() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let model = fixture.model
        model.loadPresentationForTesting(phase: .recording, evidence: [
            TranscriptSegment(startTime: 0, endTime: 2, english: "El agua está fría.",
                              chinese: "水很冷。", sourceLanguage: "es")
        ])
        let controller = FloatingSubtitleWindowController(defaults: fixture.defaults)
        let panel = controller.prepareWindow(model: model)
        defer { controller.close() }
        let view = try XCTUnwrap(panel.contentView as? NSHostingView<AnyView>)
        try await settle(view)
        let frame = panel.frame
        let unlocked = try bitmap(view)
        controller.toggleLock()
        try await settle(view)
        let locked = try bitmap(view)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.frame, frame)
        XCTAssertEqual(unlocked.pixelsWide, locked.pixelsWide)
        XCTAssertEqual(unlocked.pixelsHigh, locked.pixelsHigh)
        XCTAssertNotEqual(try pixels(unlocked), try pixels(locked), "The locked badge must be visible")
        let bodyStart = Int(70 * CGFloat(locked.pixelsHigh) / view.bounds.height) * locked.bytesPerRow
        XCTAssertEqual(try pixels(unlocked).dropFirst(bodyStart), try pixels(locked).dropFirst(bodyStart),
                       "The badge must not change caption text or layout")
        controller.toggleLock()
        try await settle(view)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertEqual(try pixels(bitmap(view)), try pixels(unlocked))
        XCTAssertFalse(panel.isVisible)
        try saveOverlayScreenshot(unlocked, name: "floating-unlocked", fixture: fixture)
        try saveOverlayScreenshot(locked, name: "floating-locked", fixture: fixture)
    }

    func testSettingsOverlayUsesTheSamePreferencesAndRendersOffscreen() async throws {
        let fixture = try FloatingSubtitleWindowTestFixture(testCase: self)
        let preferences = FloatingSubtitlePreferences(store: fixture.defaults)
        preferences.backgroundOpacity = 0.75
        preferences.showsAcrossSpaces = true
        let before = try XCTUnwrap(fixture.defaults.persistentDomain(forName: fixture.suite))
        let host = NSHostingView(rootView: AnyView(ClassroomSettingsView()
            .environmentObject(fixture.model).defaultAppStorage(fixture.defaults)
            .environment(\.colorScheme, .dark)))
        let settings = window()
        defer { settings.close() }
        settings.appearance = NSAppearance(named: .darkAqua)
        settings.contentView = host
        settings.setContentSize(NSSize(width: 520, height: 1280))
        try await settle(host)
        XCTAssertFalse(settings.isVisible)
        XCTAssertFalse(settings.isKeyWindow)
        XCTAssertEqual(preferences.backgroundOpacity, 0.75)
        XCTAssertTrue(preferences.showsAcrossSpaces)
        XCTAssertTrue(NSDictionary(dictionary: before).isEqual(
            to: try XCTUnwrap(fixture.defaults.persistentDomain(forName: fixture.suite))))
        try saveOverlayScreenshot(bitmap(host), name: "settings-overlay", fixture: fixture)
    }

    private func saveReferenceFrame(in store: UserDefaults) throws -> NSRect {
        let reference = window()
        defer { reference.close() }
        let visible = try XCTUnwrap(NSScreen.screens.first?.visibleFrame)
        reference.setContentSize(NSSize(width: 640, height: 480))
        reference.setFrameTopLeftPoint(NSPoint(x: visible.minX + 40, y: visible.maxY - 50))
        XCTAssertTrue(visible.contains(reference.frame), "Saved test coordinates must fit a real screen")
        store.set(reference.frameDescriptor, forKey: FloatingSubtitleWindowController.frameDefaultsKey)
        return reference.frame
    }

    @MainActor
    private struct WindowSnapshot {
        let level: NSWindow.Level
        let behavior: NSWindow.CollectionBehavior
        let ignoresMouseEvents: Bool
        let isOpaque: Bool
        let backgroundColor: NSColor?
        let frame: NSRect
        let isVisible: Bool

        init(_ window: NSWindow) {
            level = window.level
            behavior = window.collectionBehavior
            ignoresMouseEvents = window.ignoresMouseEvents
            isOpaque = window.isOpaque
            backgroundColor = window.backgroundColor
            frame = window.frame
            isVisible = window.isVisible
        }
    }

    private func assertWindow(_ window: NSWindow, matches snapshot: WindowSnapshot,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(window.level, snapshot.level, file: file, line: line)
        XCTAssertEqual(window.collectionBehavior, snapshot.behavior, file: file, line: line)
        XCTAssertEqual(window.ignoresMouseEvents, snapshot.ignoresMouseEvents, file: file, line: line)
        XCTAssertEqual(window.isOpaque, snapshot.isOpaque, file: file, line: line)
        XCTAssertEqual(window.backgroundColor, snapshot.backgroundColor, file: file, line: line)
        XCTAssertEqual(window.frame, snapshot.frame, file: file, line: line)
        XCTAssertEqual(window.isVisible, snapshot.isVisible, file: file, line: line)
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private func saveOverlayScreenshot(_ bitmap: NSBitmapImageRep, name: String,
                                       fixture: FloatingSubtitleWindowTestFixture) throws {
        guard let configured = ProcessInfo.processInfo.environment["LIVELINGO_OVERLAY_SCREENSHOTS"] else { return }
        let directory = URL(fileURLWithPath: configured, isDirectory: true).resolvingSymlinksInPath()
        guard directory.path.hasPrefix(fixture.ddOverlay.path + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000, "A flat/unrendered image is not screenshot evidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
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

/// Also used by the one display-opacity regression that needs a real owned
/// panel. Services are disabled; data uses the supplied test root or temporary directory.
@MainActor
struct FloatingSubtitleWindowTestFixture {
    let defaults: UserDefaults
    let suite: String
    let model: AppModel
    let ddOverlay: URL

    init(testCase: XCTestCase) throws {
        XCTAssertTrue(AppRuntimeEnvironment.isUnitTesting)
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let dataRoot: URL
        if let requested = ProcessInfo.processInfo.environment["LIVELINGO_TEST_WORKSPACE"] {
            let root = URL(fileURLWithPath: requested, isDirectory: true).resolvingSymlinksInPath()
            let testHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().path
            guard temporary.path.hasPrefix(root.path + "/"), testHome.hasPrefix(root.path + "/") else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            dataRoot = root
        } else {
            dataRoot = temporary
        }
        ddOverlay = dataRoot
        let directory = dataRoot.appendingPathComponent("overlay-window-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "FloatingSubtitleDisplay-\(UUID().uuidString)"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
                                       observeSleep: false, diagnostics: .disabled) { _, _, _, _, _ in
            XCTFail("Window tests must never invoke a generator")
            throw CancellationError()
        }
        let model = AppModel(reviewQueue: queue, translation: .unavailable, notes: .unavailable,
                             backgroundServices: false, scheduledNotes: false, defaults: store)
        self.defaults = store
        self.suite = suite
        self.model = model
        testCase.addTeardownBlock {
            await model.resetTranslationSessionForTesting()?.value
            await queue.shutdownForTesting()
            try cleanup.remove()
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }
}
