import AppKit
import Combine
import SwiftUI
import XCTest
@testable import LiveLingo

/// All process policy, status-bar, subtitle-window and recording operations are
/// injected. The only native windows created here are never ordered onscreen.
@MainActor
final class FullScreenClassModeTests: XCTestCase {
    func testAllAppMenusLowerSubtitlesUntilTheLastMenuCloses() throws {
        let f = try FSCFixture(testCase: self)
        f.controller.setEnabled(true)
        f.subtitles.setLockedExternally(true)
        let behavior = f.subtitles.surface.collectionBehavior
        let menus = [f.controller.menu, NSMenu(title: "悬浮字幕字号"), NSMenu(title: "文本右键"),
                     NSMenu(title: "更多"), NSMenu(title: "字号子菜单")]
        for menu in menus {
            f.notifications.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            XCTAssertEqual(f.subtitles.surface.level, .floating, menu.title)
            XCTAssertTrue(f.subtitles.surface.ignoresMouseEvents)
            XCTAssertEqual(f.subtitles.surface.collectionBehavior, behavior)
        }
        // Duplicate delegate/notification delivery must not extend tracking.
        f.controller.menuWillOpen(f.controller.menu)
        f.controller.menuDidClose(f.controller.menu)
        for menu in menus.dropLast() {
            f.notifications.post(name: NSMenu.didEndTrackingNotification, object: menu)
            XCTAssertEqual(f.subtitles.surface.level, .floating)
        }
        f.notifications.post(name: NSMenu.didEndTrackingNotification, object: menus.last!)
        XCTAssertEqual(f.subtitles.surface.level, FloatingSubtitleWindowSettings.fullScreenLevel)
        XCTAssertTrue(f.subtitles.isLocked)
        XCTAssertTrue(f.subtitles.surface.ignoresMouseEvents)
    }

    func testPopoverAndMenuOverlapKeepsProtectionAcrossModeChanges() throws {
        let f = try FSCFixture(testCase: self)
        let popover = NSPopover()
        let menu = NSMenu(title: "导出格式")
        f.notifications.post(name: NSPopover.willShowNotification, object: popover)
        f.controller.setEnabled(true)
        XCTAssertEqual(f.subtitles.surface.level, .floating)
        f.notifications.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        f.notifications.post(name: NSPopover.didCloseNotification, object: popover)
        XCTAssertEqual(f.subtitles.surface.level, .floating)
        f.controller.setEnabled(false)
        f.controller.setEnabled(true)
        XCTAssertEqual(f.subtitles.surface.level, .floating)
        f.notifications.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertEqual(f.subtitles.surface.level, FloatingSubtitleWindowSettings.fullScreenLevel)
        f.controller.shutdown()
        f.notifications.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        assertRestored(f.subtitles.surface, f.subtitles.original)
    }

    func testPresentedPopupsOverlapNativeMenuTrackingWithoutChangingLock() throws {
        let f = try FSCFixture(testCase: self)
        f.controller.setEnabled(true)
        f.subtitles.setLockedExternally(true)
        let summary = UUID(), export = UUID(), status = UUID(), shortcuts = UUID()
        let confirmation = UUID(), queueConfirmation = UUID(), sheet = UUID(), chooser = UUID()
        for identity in [summary, export, status, shortcuts, confirmation, queueConfirmation, sheet, chooser] {
            f.controller.setPresentedPopup(identity, isPresented: true)
            XCTAssertEqual(f.subtitles.surface.level, .floating)
        }
        f.controller.setPresentedPopup(summary, isPresented: true)
        f.notifications.post(name: NSMenu.didBeginTrackingNotification, object: f.controller.menu)
        for identity in [status, summary, shortcuts, export, sheet, queueConfirmation, chooser, confirmation] {
            f.controller.setPresentedPopup(identity, isPresented: false)
            XCTAssertEqual(f.subtitles.surface.level, .floating)
        }
        f.notifications.post(name: NSMenu.didEndTrackingNotification, object: f.controller.menu)
        XCTAssertEqual(f.subtitles.surface.level, FloatingSubtitleWindowSettings.fullScreenLevel)
        XCTAssertTrue(f.subtitles.surface.ignoresMouseEvents)
    }

    func testDelayedRestorationRespectsNewFocusAndCloseDecisionsWithinTheSameMode() throws {
        for closesWindow in [false, true] {
            let f = try FSCFixture(testCase: self)
            f.application.mainWindowVisible = true
            f.application.mainWindowKey = true
            f.controller.setEnabled(true)
            let activations = f.application.activateCount
            f.application.userDecisionGeneration += 1
            f.application.mainWindowKey = false
            if closesWindow { f.application.mainWindowVisible = false }
            f.scheduler.drain()
            XCTAssertEqual(f.application.restoredSnapshots, [1])
            XCTAssertEqual(f.application.activateCount, activations)
            XCTAssertFalse(f.application.mainWindowKey)
            XCTAssertEqual(f.application.mainWindowVisible, !closesWindow)
        }
    }

    func testPausedStatusButtonHasOrangeDotAndCaptionGlyph() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 18))
            button.appearance = NSAppearance(named: appearance)
            for state in [FullScreenStatusAppearance(hasActiveSession: false, isPaused: false),
                          FullScreenStatusAppearance(hasActiveSession: true, isPaused: false),
                          FullScreenStatusAppearance(hasActiveSession: true, isPaused: true)] {
                state.configure(button)
                let image = try XCTUnwrap(button.image)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                var orange = 0, glyph = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              color.alphaComponent > 0.5 else { continue }
                        let imageX = Double(x) * 24 / Double(bitmap.pixelsWide)
                        if imageX < 16 { glyph += 1 }
                        if imageX >= 17, color.redComponent > 0.7, color.greenComponent > 0.2,
                           color.redComponent - color.greenComponent > 0.1,
                           color.greenComponent - color.blueComponent > 0.15 { orange += 1 }
                    }
                }
                XCTAssertGreaterThan(glyph, 0, "The caption bubble must remain visible in every recording state")
                if state.hasActiveSession && state.isPaused {
                    XCTAssertGreaterThan(orange, 0, "Paused recording must have an actual orange dot")
                } else { XCTAssertEqual(orange, 0) }
            }
        }
    }

    func testREADMEIdentifiesExperimentalModeAsAbsentFromDownloadVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let line = try XCTUnwrap(readme.split(separator: "\n").first { $0.contains("**可选全屏网课模式**") })
        XCTAssertTrue(line.contains("实验分支"))
        XCTAssertTrue(line.contains("0.2.0"))
        XCTAssertTrue(line.contains("不含"))
    }

    func testNativeStatusButtonHasAccessibleStateAndVisibleRecordingDot() throws {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 18))
        button.appearance = NSAppearance(named: .darkAqua)
        var recordingPixels = 0
        for state in [FullScreenStatusAppearance(hasActiveSession: false, isPaused: false),
                      FullScreenStatusAppearance(hasActiveSession: true, isPaused: false),
                      FullScreenStatusAppearance(hasActiveSession: true, isPaused: true)] {
            state.configure(button)
            XCTAssertEqual(button.accessibilityLabel(), state.accessibilityLabel)
            XCTAssertEqual(button.toolTip, state.accessibilityLabel)
            let image = try XCTUnwrap(button.image)
            XCTAssertEqual(image.isTemplate, !state.hasActiveSession)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            var red = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    // System colors vary with appearance and color profiles;
                    // require visibly dominant red, rather than fixed RGB values.
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                       color.alphaComponent > 0.5, color.redComponent > 0.7,
                       color.redComponent - color.greenComponent > 0.4,
                       color.redComponent - color.blueComponent > 0.4 { red += 1 }
                }
            }
            if state.hasActiveSession && !state.isPaused {
                recordingPixels = red
                XCTAssertGreaterThan(red, 0, "Recording must have visible red pixels, not only a changed label")
            } else { XCTAssertEqual(red, 0) }
        }
        XCTAssertGreaterThan(recordingPixels, 0)
    }

    func testFreshControllerAndRepeatedStartLeaveModeOffWithoutPersisting() throws {
        let f = try FSCFixture(testCase: self)
        XCTAssertFalse(f.controller.isEnabled)
        XCTAssertNil(f.defaults.object(forKey: FullScreenClassModeController.preferenceKey))
        XCTAssertEqual(f.controller.actionTitle, "开启全屏网课模式")
        f.controller.start()
        f.controller.start()
        XCTAssertFalse(f.controller.isEnabled)
        XCTAssertNil(f.defaults.object(forKey: FullScreenClassModeController.preferenceKey))
        XCTAssertTrue(f.application.policies.isEmpty)
        XCTAssertEqual(f.status.installCount, 0)
        XCTAssertTrue(f.subtitles.modeChanges.isEmpty)
        XCTAssertEqual(f.scheduler.pendingCount, 0)
        XCTAssertFalse(try item(.disableMode, in: f).isEnabled)
        XCTAssertEqual(f.model.phase, .idle)
    }

    func testEnableAndDisableAreIdempotentAndPersistOnlyTheMode() throws {
        let f = try FSCFixture(testCase: self)
        f.controller.start()
        f.controller.setEnabled(true)
        f.scheduler.drain()
        XCTAssertTrue(f.controller.isEnabled)
        XCTAssertEqual(f.application.activationPolicy, .accessory)
        XCTAssertTrue(f.status.isInstalled)
        XCTAssertTrue(f.status.menu === f.controller.menu)
        XCTAssertEqual(f.subtitles.surface.level, FloatingSubtitleWindowSettings.fullScreenLevel)
        XCTAssertTrue(f.subtitles.surface.collectionBehavior.contains(.canJoinAllSpaces))
        let enabledDomain = domain(f)
        let policies = f.application.policies
        let modeChanges = f.subtitles.modeChanges
        f.controller.setEnabled(true)
        f.controller.setEnabled(true)
        XCTAssertEqual(f.application.policies, policies)
        XCTAssertEqual(f.subtitles.modeChanges, modeChanges)
        XCTAssertEqual(f.status.installCount, 1)
        XCTAssertEqual(f.scheduler.pendingCount, 0)
        XCTAssertTrue(NSDictionary(dictionary: domain(f)).isEqual(to: enabledDomain))

        f.controller.setEnabled(false)
        f.scheduler.drain()
        XCTAssertFalse(f.controller.isEnabled)
        XCTAssertEqual(f.application.activationPolicy, .regular)
        XCTAssertFalse(f.status.isInstalled)
        XCTAssertEqual(f.subtitles.surface.level, .floating)
        XCTAssertEqual(f.subtitles.surface.collectionBehavior, f.subtitles.original.behavior)
        XCTAssertFalse(f.defaults.bool(forKey: FullScreenClassModeController.preferenceKey))
        let disabledPolicies = f.application.policies
        let disabledChanges = f.subtitles.modeChanges
        let removals = f.status.removeCount
        f.controller.setEnabled(false)
        f.controller.setEnabled(false)
        XCTAssertEqual(f.application.policies, disabledPolicies)
        XCTAssertEqual(f.subtitles.modeChanges, disabledChanges)
        XCTAssertEqual(f.status.removeCount, removals)
        XCTAssertEqual(f.scheduler.pendingCount, 0)
        XCTAssertEqual(Set(domain(f).keys), Set([FullScreenClassModeController.preferenceKey]))
        XCTAssertEqual(f.recording.toggleCount, 0)
    }

    func testBindingAndAppMenuTitleUseTheSameController() throws {
        let f = try FSCFixture(testCase: self)
        let binding = f.controller.binding
        XCTAssertFalse(binding.wrappedValue)
        binding.wrappedValue = true
        XCTAssertTrue(f.controller.isEnabled)
        XCTAssertEqual(f.controller.actionTitle, "关闭全屏网课模式")
        f.controller.toggle()
        XCTAssertFalse(binding.wrappedValue)
        XCTAssertEqual(f.controller.actionTitle, "开启全屏网课模式")
        XCTAssertFalse(f.defaults.bool(forKey: FullScreenClassModeController.preferenceKey))
    }

    func testSavedPreferenceIsAppliedOnlyAtStartAndSurvivesRestart() throws {
        let f = try FSCFixture(testCase: self, savedEnabled: true)
        let saved = domain(f)
        XCTAssertFalse(f.controller.isEnabled)
        XCTAssertTrue(f.application.policies.isEmpty)
        f.controller.start()
        f.controller.start()
        f.scheduler.drain()
        XCTAssertTrue(f.controller.isEnabled)
        XCTAssertEqual(f.status.installCount, 1)
        XCTAssertTrue(NSDictionary(dictionary: domain(f)).isEqual(to: saved))
        f.controller.shutdown()
        XCTAssertTrue(f.defaults.bool(forKey: FullScreenClassModeController.preferenceKey))

        let application = FSCApplication()
        let status = FSCStatusItem()
        let subtitles = FSCSubtitles()
        let scheduler = FSCScheduler()
        let restarted = FullScreenClassModeController(defaults: f.defaults, application: application,
            statusItem: status, subtitles: subtitles, schedule: { scheduler.enqueue($0) })
        restarted.connect(model: f.model, recording: f.recording.commands)
        addTeardownBlock { @MainActor in
            restarted.shutdown()
            scheduler.drain()
            await Task.yield()
        }
        XCTAssertFalse(restarted.isEnabled)
        XCTAssertFalse(subtitles.isLocked)
        restarted.start()
        XCTAssertTrue(restarted.isEnabled)
        XCTAssertTrue(status.isInstalled)
        XCTAssertEqual(application.activationPolicy, .accessory)
        XCTAssertTrue(NSDictionary(dictionary: domain(f)).isEqual(to: saved))
    }

    func testLockedSubtitleRemainsClickThroughAcrossModeAndMenuTracking() throws {
        let f = try FSCFixture(testCase: self)
        f.subtitles.setLockedExternally(true)
        f.scheduler.drain()
        XCTAssertTrue(f.subtitles.surface.ignoresMouseEvents)
        f.controller.setEnabled(true)
        XCTAssertTrue(f.subtitles.isLocked)
        XCTAssertTrue(f.subtitles.surface.ignoresMouseEvents)
        f.controller.menuWillOpen(f.controller.menu)
        XCTAssertEqual(f.subtitles.surface.level, .floating)
        XCTAssertTrue(f.subtitles.surface.ignoresMouseEvents)
        f.controller.menuDidClose(f.controller.menu)
        XCTAssertEqual(f.subtitles.surface.level, FloatingSubtitleWindowSettings.fullScreenLevel)
        f.controller.setEnabled(false)
        XCTAssertTrue(f.subtitles.isLocked)
        XCTAssertTrue(f.subtitles.surface.ignoresMouseEvents)
        XCTAssertEqual(try item(.toggleLock, in: f).title, "解锁浮动字幕")
        f.subtitles.setLockedExternally(false)
        f.scheduler.drain()
        XCTAssertFalse(f.subtitles.surface.ignoresMouseEvents)
        XCTAssertEqual(Set(domain(f).keys), Set([FullScreenClassModeController.preferenceKey]))
    }

    func testWindowConfigurationRestoresNonDefaultAndNilOriginalProperties() {
        for ignoresMouseEvents in [false, true] {
            for color in [NSColor.systemPurple, nil] as [NSColor?] {
                let surface = FSCSurface(level: .statusBar,
                    behavior: [.moveToActiveSpace, .fullScreenPrimary, .primary, .stationary, .ignoresCycle],
                    ignoresMouseEvents: ignoresMouseEvents, isOpaque: !ignoresMouseEvents, color: color)
                let original = FSCWindowValues(surface)
                let configuration = FloatingSubtitleWindowConfiguration(window: surface)
                var settings = FloatingSubtitleWindowSettings(showsAcrossSpaces: false, isLocked: true,
                    backgroundOpacity: 0.75, fullScreenClassMode: true)
                configuration.apply(settings)
                XCTAssertEqual(surface.level, FloatingSubtitleWindowSettings.fullScreenLevel)
                XCTAssertTrue(surface.ignoresMouseEvents)
                XCTAssertFalse(surface.isOpaque)
                XCTAssertEqual(surface.subtitleBackgroundColor, .clear)
                XCTAssertTrue(surface.collectionBehavior.contains(.canJoinAllSpaces))
                XCTAssertTrue(surface.collectionBehavior.contains(.fullScreenAuxiliary))
                XCTAssertTrue(surface.collectionBehavior.contains(.canJoinAllApplications))
                XCTAssertTrue(surface.collectionBehavior.contains(.stationary))
                XCTAssertTrue(surface.collectionBehavior.contains(.ignoresCycle))
                XCTAssertTrue(surface.collectionBehavior.intersection(
                    [.moveToActiveSpace, .fullScreenPrimary, .fullScreenNone, .primary, .auxiliary]).isEmpty)
                settings.isLocked = false
                settings.backgroundOpacity = 1
                settings.fullScreenClassMode = false
                configuration.apply(settings)
                XCTAssertEqual(surface.collectionBehavior, original.behavior)
                XCTAssertEqual(surface.ignoresMouseEvents, original.ignoresMouseEvents)
                XCTAssertEqual(surface.isOpaque, original.isOpaque)
                XCTAssertEqual(surface.subtitleBackgroundColor, original.color)
                configuration.restore()
                assertRestored(surface, original)
                configuration.restore()
                assertRestored(surface, original)
            }
        }
    }

    func testAllSpacesPreferenceStillAppliesAfterLeavingFullScreenMode() throws {
        let f = try FSCFixture(testCase: self)
        f.subtitles.setAcrossSpaces(true)
        f.controller.setEnabled(true)
        f.controller.setEnabled(false)
        XCTAssertEqual(f.subtitles.surface.level, .floating)
        XCTAssertTrue(f.subtitles.surface.collectionBehavior.contains(.canJoinAllSpaces))
        f.subtitles.setAcrossSpaces(false)
        XCTAssertEqual(f.subtitles.surface.collectionBehavior, f.subtitles.original.behavior)
    }

    func testFailedStatusInstallationLeavesPreferencesPolicyAndWindowUntouched() throws {
        let f = try FSCFixture(testCase: self, savedEnabled: false)
        let before = domain(f)
        let window = FSCWindowValues(f.subtitles.surface)
        f.status.installSucceeds = false
        f.controller.setEnabled(true)
        XCTAssertFalse(f.controller.isEnabled)
        XCTAssertEqual(f.controller.errorMessage, "菜单栏图标未能显示，全屏网课模式未开启。")
        XCTAssertFalse(f.status.isInstalled)
        XCTAssertTrue(f.application.policies.isEmpty)
        XCTAssertTrue(f.subtitles.modeChanges.isEmpty)
        XCTAssertEqual(f.scheduler.pendingCount, 0)
        XCTAssertTrue(NSDictionary(dictionary: domain(f)).isEqual(to: before))
        assertRestored(f.subtitles.surface, window)
    }

    func testFailedActivationRemovesInstalledStatusItemWithoutPersisting() throws {
        let f = try FSCFixture(testCase: self, savedEnabled: false)
        let before = domain(f)
        let window = FSCWindowValues(f.subtitles.surface)
        f.application.rejectedPolicy = .accessory
        f.controller.setEnabled(true)
        XCTAssertFalse(f.controller.isEnabled)
        XCTAssertEqual(f.controller.errorMessage, "macOS 未能切换 App 显示方式，请重试。")
        XCTAssertEqual(f.application.activationPolicy, .regular)
        XCTAssertEqual(f.application.policies, [.accessory])
        XCTAssertEqual(f.status.installCount, 1)
        XCTAssertEqual(f.status.removeCount, 1)
        XCTAssertFalse(f.status.isInstalled)
        XCTAssertTrue(f.subtitles.modeChanges.isEmpty)
        XCTAssertEqual(f.scheduler.pendingCount, 0)
        XCTAssertTrue(NSDictionary(dictionary: domain(f)).isEqual(to: before))
        assertRestored(f.subtitles.surface, window)
    }

    func testFailedDisableRetainsTheEnabledRecoveryEntryAndPreference() throws {
        let f = try FSCFixture(testCase: self)
        f.controller.setEnabled(true)
        f.scheduler.drain()
        let before = domain(f)
        let window = FSCWindowValues(f.subtitles.surface)
        let removals = f.status.removeCount
        f.application.rejectedPolicy = .regular
        f.controller.setEnabled(false)
        XCTAssertTrue(f.controller.isEnabled)
        XCTAssertNotNil(f.controller.errorMessage)
        XCTAssertEqual(f.application.activationPolicy, .accessory)
        XCTAssertTrue(f.status.isInstalled)
        XCTAssertEqual(f.status.removeCount, removals)
        XCTAssertTrue(try item(.disableMode, in: f).isEnabled)
        XCTAssertEqual(f.scheduler.pendingCount, 0)
        XCTAssertTrue(NSDictionary(dictionary: domain(f)).isEqual(to: before))
        assertRestored(f.subtitles.surface, window)
    }

    func testSuccessfulRetryClearsErrorAndAppliesMode() throws {
        let f = try FSCFixture(testCase: self)
        f.application.rejectedPolicy = .accessory
        f.controller.setEnabled(true)
        XCTAssertNotNil(f.controller.errorMessage)
        f.application.rejectedPolicy = nil
        f.controller.setEnabled(true)
        XCTAssertTrue(f.controller.isEnabled)
        XCTAssertNil(f.controller.errorMessage)
        XCTAssertTrue(f.status.isInstalled)
        XCTAssertTrue(f.defaults.bool(forKey: FullScreenClassModeController.preferenceKey))
        XCTAssertEqual(f.subtitles.modeChanges, [true])
    }

    func testSavedEnabledPreferenceSurvivesFailedStartup() throws {
        let f = try FSCFixture(testCase: self, savedEnabled: true)
        let before = domain(f)
        f.status.installSucceeds = false
        f.controller.start()
        XCTAssertFalse(f.controller.isEnabled)
        XCTAssertNotNil(f.controller.errorMessage)
        XCTAssertTrue(NSDictionary(dictionary: domain(f)).isEqual(to: before))
        f.status.installSucceeds = true
        f.controller.setEnabled(true)
        XCTAssertTrue(f.controller.isEnabled)
        XCTAssertNil(f.controller.errorMessage)
    }

    func testDelayedRestorationCannotApplyAnOlderModeGeneration() throws {
        let f = try FSCFixture(testCase: self)
        f.application.mainWindowVisible = true
        f.application.mainWindowKey = true
        f.controller.setEnabled(true)
        f.controller.setEnabled(false)
        f.controller.setEnabled(true)
        XCTAssertEqual(f.application.restoredSnapshots, [1, 2, 3])
        f.scheduler.drain()
        XCTAssertEqual(f.application.restoredSnapshots, [1, 2, 3, 3],
                       "Only the final transition may run its delayed window restoration")
        XCTAssertTrue(f.controller.isEnabled)
        XCTAssertEqual(f.application.activationPolicy, .accessory)
        XCTAssertTrue(f.application.mainWindowVisible)
        XCTAssertTrue(f.application.mainWindowKey)
    }

    func testEnablingFromVisibleNonKeyWindowDoesNotActivateTheApplication() throws {
        let f = try FSCFixture(testCase: self)
        f.application.mainWindowVisible = true
        f.application.mainWindowKey = false
        f.controller.setEnabled(true)
        f.scheduler.drain()
        XCTAssertEqual(f.application.restoredSnapshots, [1, 1])
        XCTAssertEqual(f.application.activateCount, 0)
        XCTAssertTrue(f.application.mainWindowVisible)
        XCTAssertFalse(f.application.mainWindowKey)
        f.controller.setEnabled(false)
        f.scheduler.drain()
        XCTAssertGreaterThan(f.application.activateCount, 0)
    }

    func testDelayedMainWindowRegistrationIsCancelledByDisable() throws {
        let f = try FSCFixture(testCase: self, savedEnabled: true)
        f.controller.start()
        f.scheduler.drain()
        let window = hiddenWindow(size: NSSize(width: 400, height: 300))
        defer { window.close() }
        f.controller.registerMainWindow(window, reopen: {})
        XCTAssertGreaterThan(f.scheduler.pendingCount, 0)
        f.controller.setEnabled(false)
        let shows = f.application.showCount
        f.scheduler.drain()
        XCTAssertEqual(f.application.showCount, shows)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    func testDelayedMainWindowRegistrationRespectsANewerUserFocusDecision() throws {
        let f = try FSCFixture(testCase: self, savedEnabled: true)
        f.controller.start()
        f.scheduler.drain()
        let window = hiddenWindow(size: NSSize(width: 400, height: 300))
        defer { window.close() }
        f.controller.registerMainWindow(window, reopen: {})
        let activations = f.application.activateCount
        f.application.userDecisionGeneration += 1
        f.scheduler.drain()
        XCTAssertEqual(f.application.showCount, 0)
        XCTAssertEqual(f.application.activateCount, activations)
        XCTAssertFalse(window.isVisible)
    }

    func testShowingAnExistingMainWindowDoesNotLeaveADeferredFocusRequest() throws {
        let f = try FSCFixture(testCase: self)
        let window = hiddenWindow(size: NSSize(width: 400, height: 300))
        defer { window.close() }
        f.controller.registerMainWindow(window, reopen: {})
        f.controller.setEnabled(true)
        f.scheduler.drain()
        try dispatch(.showMainWindow, in: f)
        XCTAssertEqual(f.application.showCount, 1)
        f.controller.registerMainWindow(window, reopen: {})
        f.scheduler.drain()
        XCTAssertEqual(f.application.showCount, 1,
                       "A SwiftUI registration update must not bring a previously shown window forward again")
        f.controller.showMainWindowAfterLaunch()
        let shows = f.application.showCount
        f.controller.registerMainWindow(window, reopen: {})
        f.scheduler.drain()
        XCTAssertEqual(f.application.showCount, shows)
        XCTAssertFalse(window.isVisible)
    }

    func testShutdownPreservesPreferenceAndRestoresOriginalPolicyAndWindowProperties() throws {
        let f = try FSCFixture(testCase: self, policy: .prohibited)
        f.controller.setEnabled(true)
        f.subtitles.setVisibleExternally(true)
        f.subtitles.setLockedExternally(true)
        let before = domain(f)
        f.controller.shutdown()
        f.scheduler.drain()
        XCTAssertFalse(f.controller.isEnabled)
        XCTAssertEqual(f.application.activationPolicy, .prohibited)
        XCTAssertFalse(f.status.isInstalled)
        XCTAssertEqual(f.subtitles.shutdownCount, 1)
        XCTAssertFalse(f.subtitles.isVisible)
        XCTAssertFalse(f.subtitles.isLocked)
        assertRestored(f.subtitles.surface, f.subtitles.original)
        XCTAssertTrue(NSDictionary(dictionary: domain(f)).isEqual(to: before))
        XCTAssertTrue(f.defaults.bool(forKey: FullScreenClassModeController.preferenceKey))
        let policies = f.application.policies
        let removals = f.status.removeCount
        let menuChanges = f.subtitles.menuTrackingChanges
        f.controller.shutdown()
        f.controller.start()
        f.controller.setEnabled(true)
        f.controller.menuWillOpen(f.controller.menu)
        f.controller.menuDidClose(f.controller.menu)
        f.controller.perform(.quit)
        XCTAssertEqual(f.application.policies, policies)
        XCTAssertEqual(f.status.removeCount, removals)
        XCTAssertEqual(f.subtitles.shutdownCount, 1)
        XCTAssertEqual(f.subtitles.menuTrackingChanges, menuChanges)
        XCTAssertEqual(f.application.terminateCount, 0)
        XCTAssertEqual(f.scheduler.pendingCount, 0)
    }

    func testShutdownInvalidatesQueuedWindowRecoveryAndDisconnectsObservers() throws {
        let f = try FSCFixture(testCase: self, savedEnabled: true)
        f.controller.start()
        let window = hiddenWindow(size: NSSize(width: 400, height: 300))
        defer { window.close() }
        f.controller.registerMainWindow(window, reopen: {})
        f.controller.shutdown()
        let shows = f.application.showCount
        let activations = f.application.activateCount
        f.scheduler.drain()
        XCTAssertEqual(f.application.showCount, shows)
        XCTAssertEqual(f.application.activateCount, activations)
        f.subtitles.setVisibleExternally(true)
        f.model.manualTranslationInput = "Synthetic observer teardown"
        XCTAssertEqual(f.scheduler.pendingCount, 0)
        XCTAssertFalse(f.status.isInstalled)
        XCTAssertFalse(window.isVisible)
    }

    func testMenuHasSevenIdentifiedActionsAndCorrectRecordingPausedAndLockStates() throws {
        let f = try FSCFixture(testCase: self)
        let actions = f.controller.menu.items.filter { !$0.isSeparatorItem }
        XCTAssertEqual(actions.count, 7)
        XCTAssertEqual(actions.compactMap { $0.identifier?.rawValue }, FullScreenMenuAction.allCases.map(\.rawValue))
        XCTAssertEqual(actions.map(\.title), ["显示主窗口", "显示浮动字幕", "锁定浮动字幕",
            "浮动字幕移到屏幕底部", "开始记录", "关闭全屏网课模式", "退出 LiveLingo"])
        XCTAssertFalse(f.controller.menu.autoenablesItems)
        XCTAssertEqual(try item(.toggleSubtitles, in: f).state, .off)
        XCTAssertEqual(try item(.toggleLock, in: f).state, .off)
        f.controller.setEnabled(true)
        for paused in [false, true] {
            f.recording.state = FullScreenRecordingState(hasActiveSession: true, isPaused: paused,
                actionTitle: "停止并保存", canToggle: true)
            f.subtitles.setVisibleExternally(true)
            f.subtitles.setLockedExternally(paused)
            f.scheduler.drain()
            f.controller.refresh()
            XCTAssertEqual(try item(.toggleRecording, in: f).title, "停止并保存")
            XCTAssertTrue(try item(.toggleRecording, in: f).isEnabled)
            XCTAssertEqual(try item(.toggleSubtitles, in: f).title, "隐藏浮动字幕")
            XCTAssertEqual(try item(.toggleSubtitles, in: f).state, .on)
            XCTAssertEqual(try item(.toggleLock, in: f).title, paused ? "解锁浮动字幕" : "锁定浮动字幕")
            XCTAssertEqual(try item(.toggleLock, in: f).state, paused ? .on : .off)
            let appearance = try XCTUnwrap(f.status.appearance)
            XCTAssertEqual(appearance, FullScreenStatusAppearance(hasActiveSession: true, isPaused: paused))
            XCTAssertEqual(appearance.accessibilityLabel,
                           paused ? "LiveLingo，全屏网课模式，记录已暂停" : "LiveLingo，全屏网课模式，正在记录")
        }
    }

    func testNativeMenuActionAndTargetRouteAllSevenCommandsToFakes() throws {
        let f = try FSCFixture(testCase: self)
        f.recording.state.canToggle = true
        f.controller.setEnabled(true)
        f.scheduler.drain()
        try dispatch(.showMainWindow, in: f)
        XCTAssertEqual(f.application.showCount, 1)
        XCTAssertEqual(f.application.activateCount, 1)
        try dispatch(.toggleSubtitles, in: f)
        XCTAssertTrue(f.subtitles.isVisible)
        XCTAssertTrue(f.subtitles.shownModel === f.model)
        try dispatch(.toggleSubtitles, in: f)
        XCTAssertFalse(f.subtitles.isVisible)
        XCTAssertEqual(f.subtitles.hideCount, 1)
        try dispatch(.toggleLock, in: f)
        XCTAssertTrue(f.subtitles.isLocked)
        try dispatch(.moveSubtitlesToBottom, in: f)
        XCTAssertEqual(f.subtitles.moveCount, 1)
        XCTAssertTrue(f.subtitles.isVisible)
        XCTAssertTrue(f.subtitles.isLocked)
        try dispatch(.toggleRecording, in: f)
        XCTAssertEqual(f.recording.toggleCount, 1)
        XCTAssertEqual(f.model.phase, .idle, "A menu command must never invoke live AppModel recording")
        try dispatch(.disableMode, in: f)
        XCTAssertFalse(f.controller.isEnabled)
        XCTAssertFalse(f.status.isInstalled)
        try dispatch(.quit, in: f)
        XCTAssertEqual(f.application.terminateCount, 1)
    }

    func testDisabledRecordingActionCannotInvokeCommandsEvenWhenDispatchedDirectly() throws {
        let f = try FSCFixture(testCase: self)
        f.recording.state.canToggle = false
        f.controller.refresh()
        XCTAssertFalse(try item(.toggleRecording, in: f).isEnabled)
        try dispatch(.toggleRecording, in: f)
        XCTAssertEqual(f.recording.toggleCount, 0)
        XCTAssertEqual(f.model.phase, .idle)
    }

    func testExternalSubtitleChangesRefreshMenuWithoutManualRefresh() throws {
        let f = try FSCFixture(testCase: self)
        f.controller.setEnabled(true)
        f.scheduler.drain()
        f.subtitles.setVisibleExternally(true)
        XCTAssertEqual(try item(.toggleSubtitles, in: f).title, "显示浮动字幕",
                       "The publisher fires before mutation; refresh must be scheduled")
        f.scheduler.drain()
        XCTAssertEqual(try item(.toggleSubtitles, in: f).title, "隐藏浮动字幕")
        XCTAssertEqual(try item(.toggleSubtitles, in: f).state, .on)
        f.subtitles.setLockedExternally(true)
        f.scheduler.drain()
        XCTAssertEqual(try item(.toggleLock, in: f).title, "解锁浮动字幕")
        XCTAssertEqual(try item(.toggleLock, in: f).state, .on)
        f.subtitles.setVisibleExternally(false)
        f.subtitles.setLockedExternally(false)
        f.scheduler.drain()
        XCTAssertEqual(try item(.toggleSubtitles, in: f).state, .off)
        XCTAssertEqual(try item(.toggleLock, in: f).state, .off)
    }

    func testExternalModelPresentationChangesRefreshRecordingAppearanceAutomatically() throws {
        let f = try FSCFixture(testCase: self)
        let model = f.model
        let recording = f.recording
        f.controller.connect(model: model, recording: FullScreenRecordingCommands(state: {
            FullScreenRecordingState(hasActiveSession: model.hasActiveSession, isPaused: model.isPaused,
                actionTitle: model.hasActiveSession ? model.stopRecordingTitle : "开始记录", canToggle: true)
        }, toggle: { recording.toggleCount += 1 }))
        f.controller.setEnabled(true)
        f.scheduler.drain()
        XCTAssertEqual(try item(.toggleRecording, in: f).title, "开始记录")
        for phase in [AppPhase.recording, .paused, .idle] {
            model.loadPresentationForTesting(phase: phase, evidence: [])
            f.scheduler.drain()
            XCTAssertEqual(try item(.toggleRecording, in: f).title,
                           model.hasActiveSession ? model.stopRecordingTitle : "开始记录")
            XCTAssertEqual(f.status.appearance,
                FullScreenStatusAppearance(hasActiveSession: model.hasActiveSession, isPaused: model.isPaused))
        }
        XCTAssertEqual(recording.toggleCount, 0)
        XCTAssertEqual(model.phase, .idle)
    }

    func testRefreshUpdatesRecordingTitleWhenAppearanceIsUnchanged() throws {
        let f = try FSCFixture(testCase: self)
        f.controller.setEnabled(true)
        f.recording.state = FullScreenRecordingState(hasActiveSession: true, isPaused: false,
            actionTitle: "停止并保存", canToggle: true)
        f.controller.refresh()
        let appearance = f.status.appearance
        f.recording.state.actionTitle = "停止并清空"
        f.recording.state.canToggle = false
        f.controller.refresh()
        XCTAssertEqual(try item(.toggleRecording, in: f).title, "停止并清空")
        XCTAssertFalse(try item(.toggleRecording, in: f).isEnabled)
        XCTAssertEqual(f.status.appearance, appearance)
    }

    func testSettingsPageRendersOffscreenWithTheInjectedController() async throws {
        let f = try FSCFixture(testCase: self)
        let host = NSHostingView(rootView: AnyView(ClassroomSettingsView(fullScreenMode: f.controller)
            .environmentObject(f.model).defaultAppStorage(f.defaults).environment(\.colorScheme, .light)))
        let window = hiddenWindow(size: NSSize(width: 520, height: 1600))
        window.contentView = host
        window.setContentSize(NSSize(width: 520, height: 1600))
        defer { window.close() }
        let before = domain(f)
        try await settle(host)
        let off = try bitmap(host)
        try saveScreenshot(off, name: "fullscreen-settings-off", fixture: f)
        XCTAssertTrue(NSDictionary(dictionary: domain(f)).isEqual(to: before),
                      "Rendering settings must not write defaults")
        f.controller.binding.wrappedValue = true
        f.scheduler.drain()
        try await settle(host)
        let on = try bitmap(host)
        try saveScreenshot(on, name: "fullscreen-settings-on", fixture: f)
        XCTAssertNotEqual(try pixels(off), try pixels(on), "The actual observed settings toggle must redraw")
        XCTAssertTrue(f.controller.isEnabled)
        XCTAssertTrue(f.status.isInstalled)
        XCTAssertEqual(f.recording.toggleCount, 0)
        XCTAssertEqual(f.model.phase, .idle)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    func testRealMenuItemCellsRenderIdleRecordingAndPausedLockedStatesOffscreen() async throws {
        let f = try FSCFixture(testCase: self)
        f.controller.setEnabled(true)
        let states: [(String, FullScreenRecordingState, Bool)] = [
            ("fullscreen-menu-idle", .init(actionTitle: "开始记录", canToggle: true), false),
            ("fullscreen-menu-recording", .init(hasActiveSession: true, actionTitle: f.model.stopRecordingTitle, canToggle: true), false),
            ("fullscreen-menu-paused-locked", .init(hasActiveSession: true, isPaused: true,
                actionTitle: f.model.stopRecordingTitle, canToggle: true), true)
        ]
        var captures: [Data] = []
        for (name, state, locked) in states {
            f.recording.state = state
            f.subtitles.setVisibleExternally(state.hasActiveSession)
            f.subtitles.setLockedExternally(locked)
            f.scheduler.drain()
            f.controller.refresh()
            let view = FSCNativeMenuView(menu: f.controller.menu)
            XCTAssertEqual(view.cells.count, f.controller.menu.items.count)
            for (cell, actualItem) in zip(view.cells, f.controller.menu.items) {
                XCTAssertTrue(cell.menuItem === actualItem, "Render the controller's real native item, not copied text")
                XCTAssertEqual(cell.state, actualItem.state)
                XCTAssertEqual(cell.isEnabled, actualItem.isEnabled)
            }
            let window = hiddenWindow(size: view.frame.size)
            window.contentView = view
            window.setContentSize(view.frame.size)
            try await settle(view)
            let image = try bitmap(view)
            captures.append(try pixels(image))
            try saveScreenshot(image, name: name, fixture: f)
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)
            window.close()
        }
        XCTAssertNotEqual(captures[0], captures[1])
        XCTAssertNotEqual(captures[1], captures[2])
        XCTAssertEqual(f.recording.toggleCount, 0)
        XCTAssertTrue(f.subtitles.menuTrackingChanges.isEmpty, "Offscreen cells must not open a real menu")
    }

    private func item(_ action: FullScreenMenuAction, in fixture: FSCFixture) throws -> NSMenuItem {
        try XCTUnwrap(fixture.controller.item(for: action))
    }

    private func dispatch(_ action: FullScreenMenuAction, in fixture: FSCFixture) throws {
        let nativeItem = try item(action, in: fixture)
        XCTAssertEqual(nativeItem.identifier?.rawValue, action.rawValue)
        XCTAssertEqual(nativeItem.representedObject as? String, action.rawValue)
        XCTAssertTrue(nativeItem.target as? FullScreenClassModeController === fixture.controller)
        let selector = try XCTUnwrap(nativeItem.action)
        XCTAssertTrue(fixture.controller.responds(to: selector))
        XCTAssertTrue(NSApplication.shared.sendAction(selector, to: nativeItem.target, from: nativeItem))
    }

    private func domain(_ fixture: FSCFixture) -> [String: Any] {
        fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]
    }

    private func assertRestored(_ window: FSCSurface, _ original: FSCWindowValues,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(window.level, original.level, file: file, line: line)
        XCTAssertEqual(window.collectionBehavior, original.behavior, file: file, line: line)
        XCTAssertEqual(window.ignoresMouseEvents, original.ignoresMouseEvents, file: file, line: line)
        XCTAssertEqual(window.isOpaque, original.isOpaque, file: file, line: line)
        XCTAssertEqual(window.subtitleBackgroundColor, original.color, file: file, line: line)
    }

    private func hiddenWindow(size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        return window
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        XCTAssertGreaterThan(image.pixelsWide, 0)
        XCTAssertGreaterThan(image.pixelsHigh, 0)
        var colors = Set<UInt32>()
        for y in stride(from: 0, to: image.pixelsHigh, by: max(1, image.pixelsHigh / 80)) {
            for x in stride(from: 0, to: image.pixelsWide, by: max(1, image.pixelsWide / 80)) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let red = UInt32(min(255, max(0, color.redComponent * 255)))
                let green = UInt32(min(255, max(0, color.greenComponent * 255)))
                let blue = UInt32(min(255, max(0, color.blueComponent * 255)))
                colors.insert(red << 16 | green << 8 | blue)
            }
        }
        XCTAssertGreaterThan(colors.count, 4, "A blank or flat bitmap is not rendering evidence")
        return image
    }

    private func pixels(_ image: NSBitmapImageRep) throws -> Data {
        Data(bytes: try XCTUnwrap(image.bitmapData), count: image.bytesPerRow * image.pixelsHigh)
    }

    private func saveScreenshot(_ image: NSBitmapImageRep, name: String, fixture: FSCFixture) throws {
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5_000, "The PNG must contain a rendered native view")
        let reopened = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(reopened.pixelsWide, image.pixelsWide)
        XCTAssertEqual(reopened.pixelsHigh, image.pixelsHigh)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let environment = ProcessInfo.processInfo.environment
        guard let configured = environment["LIVELINGO_FULLSCREEN_SCREENSHOTS"] else { return }
        guard let requestedRoot = environment["LIVELINGO_TEST_WORKSPACE"], requestedRoot.hasPrefix("/"),
              requestedRoot != "/", configured.hasPrefix("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let root = URL(fileURLWithPath: requestedRoot, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let directory = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let expected = root.appendingPathComponent("screenshots", isDirectory: true).standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let testHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath()
        guard root == fixture.root, directory.path == expected.path,
              temporary.path.hasPrefix(root.path + "/"), testHome.path.hasPrefix(root.path + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard directory.resolvingSymlinksInPath().path == expected.path else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}

/// The production window adapter runs against an injected window graph, so
/// multiwindow/sheet restoration is exercised without showing native windows.
@MainActor
final class FullScreenWindowRestorationTests: XCTestCase {
    func testPollingBeforeOwnActivationDoesNotConsumeItsFutureFocus() {
        let system = FSCWindowSystem()
        system.isActive = false
        system.foregroundPID = 20
        system.keyWindow = nil
        system.defersActivation = true
        let application = LiveFullScreenApplication(environment: system.environment, notifications: system.notifications)
        let snapshot = application.windowSnapshot()
        defer { snapshot.cancel() }
        XCTAssertTrue(application.setActivationPolicy(.regular))
        snapshot.restore()
        application.activate()
        snapshot.armDelayedRestoration(true)
        XCTAssertTrue(snapshot.canRestore(), "Polling before activation must leave its future focus available")
        system.completeActivation(keyWindow: system.settings)
        system.main.orderOut(nil)
        system.settings.orderOut(nil)
        system.subtitles.orderOut(nil)
        system.keyWindow = nil
        system.mainWindow = nil
        XCTAssertTrue(snapshot.canRestore())
        snapshot.restore()
        XCTAssertEqual(system.orderedNumbers, [3, 2, 1])
        XCTAssertTrue(system.keyWindow === system.settings)
    }

    func testDeferredOwnActivationAllowsPolicyRecoveryButNeverRevivesAUserCancelledCallback() throws {
        for decision in 0..<3 {
            let f = try FSCFixture(testCase: self)
            let system = FSCWindowSystem()
            system.isActive = false
            system.foregroundPID = 20
            system.keyWindow = nil
            system.defersActivation = true
            let application = LiveFullScreenApplication(environment: system.environment, notifications: system.notifications)
            let controller = FullScreenClassModeController(defaults: f.defaults, application: application,
                statusItem: f.status, subtitles: f.subtitles, notifications: f.notifications,
                schedule: { f.scheduler.enqueue($0) })
            defer { controller.shutdown() }
            controller.setEnabled(true)
            f.scheduler.drain()
            controller.setEnabled(false)
            XCTAssertEqual(system.activationCalls, 1)
            XCTAssertFalse(system.isActive)
            system.completeActivation(keyWindow: system.settings)
            if decision != 0 {
                if decision == 1 { system.userInput.send(()) }
                system.keyWindow = system.main
                if decision == 2 {
                    system.notifications.post(name: NSWindow.didBecomeKeyNotification, object: system.main)
                }
                system.settings.orderOut(nil)
            } else {
                system.main.orderOut(nil)
                system.settings.orderOut(nil)
                system.subtitles.orderOut(nil)
                system.keyWindow = nil
                system.mainWindow = nil
            }
            f.scheduler.drain()
            if decision != 0 {
                XCTAssertEqual(system.activationCalls, 1)
                XCTAssertTrue(system.keyWindow === system.main)
                XCTAssertFalse(system.settings.isVisible)
            } else {
                XCTAssertEqual(system.activationCalls, 2)
                XCTAssertEqual(system.orderedNumbers, [3, 2, 1])
                XCTAssertTrue(system.keyWindow === system.settings)
            }
            XCTAssertFalse(controller.isEnabled)
        }
    }

    func testEveryVisibleWindowIsRestoredInItsOriginalOrderEvenWhenAppIsInactive() {
        let system = FSCWindowSystem()
        system.isActive = false
        system.keyWindow = nil
        let application = LiveFullScreenApplication(environment: system.environment, notifications: system.notifications)
        let snapshot = application.windowSnapshot()
        XCTAssertTrue(application.setActivationPolicy(.accessory))
        snapshot.restore()
        XCTAssertEqual(system.orderedNumbers, [3, 2, 1])
        XCTAssertTrue(system.main.isVisible)
        XCTAssertTrue(system.settings.isVisible)
        XCTAssertTrue(system.subtitles.isVisible)
        XCTAssertNil(system.keyWindow)
    }

    func testSheetAndChildWindowRestoreTheirParentsWithoutReattachingOrCompletingTheSheet() {
        let system = FSCWindowSystem()
        let chooser = system.addWindow(number: 4, parent: system.settings)
        let child = system.addWindow(number: 5, parent: system.main)
        system.enumeratedWindows = [chooser, system.main, system.subtitles]
        system.keyWindow = chooser
        system.orderedNumbers = [3, 4, 2, 5, 1]
        let application = LiveFullScreenApplication(environment: system.environment, notifications: system.notifications)
        let snapshot = application.windowSnapshot()
        XCTAssertTrue(application.setActivationPolicy(.regular))
        snapshot.restore()
        XCTAssertEqual(system.orderedNumbers, [3, 4, 2, 5, 1])
        XCTAssertTrue(system.settings.isVisible)
        XCTAssertTrue(chooser.isVisible)
        XCTAssertTrue(child.isVisible)
        XCTAssertTrue(chooser.parent === system.settings)
        XCTAssertTrue(system.settings.children.first === chooser)
        XCTAssertTrue(system.keyWindow === chooser)
    }

    func testHiddenAndMinimizedWindowsRetainTheirOriginalStates() {
        let system = FSCWindowSystem()
        let hidden = system.addWindow(number: 4, visible: false)
        let minimized = system.addWindow(number: 5, visible: false)
        minimized.isMiniaturized = true
        system.orderedNumbers = [3, 2, 1]
        system.unhideShowsAllWindows = true
        let application = LiveFullScreenApplication(environment: system.environment, notifications: system.notifications)
        let snapshot = application.windowSnapshot()
        XCTAssertTrue(application.setActivationPolicy(.accessory))
        snapshot.restore()
        XCTAssertFalse(hidden.isVisible)
        XCTAssertFalse(hidden.isMiniaturized)
        XCTAssertFalse(minimized.isVisible)
        XCTAssertTrue(minimized.isMiniaturized)
        XCTAssertEqual(system.orderedNumbers, [3, 2, 1])
    }

    func testHiddenChildWindowsRemainHiddenWhenTheirParentIsRevealed() {
        let system = FSCWindowSystem()
        system.parentsRevealChildren = true
        let child = system.addWindow(number: 4, visible: false, parent: system.main)
        let application = LiveFullScreenApplication(environment: system.environment, notifications: system.notifications)
        let snapshot = application.windowSnapshot()
        XCTAssertTrue(application.setActivationPolicy(.accessory))
        snapshot.restore()
        XCTAssertFalse(child.isVisible)
        XCTAssertTrue(child.parent === system.main)
        XCTAssertEqual(system.orderedNumbers, [3, 2, 1])
        snapshot.cancel()
    }

    func testKeyWindowInputResponderAndMainWindowAreRestoredSeparately() {
        let system = FSCWindowSystem()
        let input = NSResponder()
        system.settings.firstResponder = input
        system.keyWindow = system.settings
        let application = LiveFullScreenApplication(environment: system.environment, notifications: system.notifications)
        let snapshot = application.windowSnapshot()
        XCTAssertTrue(application.setActivationPolicy(.accessory))
        snapshot.restore()
        XCTAssertTrue(system.keyWindow === system.settings)
        XCTAssertTrue(system.mainWindow === system.main)
        XCTAssertTrue(system.settings.firstResponder === input)
        XCTAssertEqual(system.orderedNumbers, [3, 2, 1], "Restoring focus must not reorder the saved windows")
    }

    func testDelayedSnapshotIsInvalidatedByNewAppOrWindowFocus() {
        for deactivates in [false, true] {
            let system = FSCWindowSystem()
            let snapshot = restoredSnapshot(system)
            if deactivates { system.isActive = false }
            else { system.keyWindow = system.settings }
            XCTAssertFalse(snapshot.canRestore())
            snapshot.cancel()
        }
    }

    func testDelayedSnapshotIsInvalidatedByCloseHideMinimizeOrNewInputResponder() {
        for decision in 0..<4 {
            let system = FSCWindowSystem()
            let snapshot = restoredSnapshot(system)
            switch decision {
            case 0: system.notifications.post(name: NSWindow.willCloseNotification, object: system.settings)
            case 1:
                system.userInput.send(())
                system.settings.isVisible = false
            case 2:
                system.userInput.send(())
                system.settings.isMiniaturized = true
            default: system.main.firstResponder = NSResponder()
            }
            XCTAssertFalse(snapshot.canRestore(), "Decision \(decision) must invalidate delayed recovery")
            snapshot.cancel()
        }
    }

    func testDelayedSnapshotRejectsAWindowFocusRoundTripAndNewWindows() {
        for opensWindow in [false, true] {
            let system = FSCWindowSystem()
            let snapshot = restoredSnapshot(system)
            if opensWindow { _ = system.addWindow(number: 4) }
            else {
                system.notifications.post(name: NSWindow.didBecomeKeyNotification, object: system.settings)
                system.notifications.post(name: NSWindow.didBecomeKeyNotification, object: system.main)
            }
            XCTAssertFalse(snapshot.canRestore())
            snapshot.cancel()
        }
    }

    func testUnchangedDelayedSnapshotRemainsValidAndCancellationIsPermanent() {
        let system = FSCWindowSystem()
        let snapshot = restoredSnapshot(system)
        XCTAssertTrue(snapshot.canRestore())
        snapshot.restore()
        XCTAssertEqual(system.orderedNumbers, [3, 2, 1])
        snapshot.cancel()
        XCTAssertFalse(snapshot.canRestore())
    }

    func testPolicyGeneratedDelayedHidingAndKeyClearingStillRestoreEveryWindow() {
        let system = FSCWindowSystem()
        let snapshot = restoredSnapshot(system)
        system.main.orderOut(nil)
        system.settings.orderOut(nil)
        system.subtitles.orderOut(nil)
        system.keyWindow = nil
        system.mainWindow = nil
        system.notifications.post(name: NSWindow.didResignKeyNotification, object: system.main)
        XCTAssertTrue(snapshot.canRestore(), "Policy side effects without user input still need recovery")
        snapshot.restore()
        XCTAssertEqual(system.orderedNumbers, [3, 2, 1])
        XCTAssertTrue(system.keyWindow === system.main)
        XCTAssertTrue(system.mainWindow === system.main)
        snapshot.cancel()
    }

    func testUserInputOrExternalAppFocusRoundTripPermanentlyCancelsDelayedRecovery() {
        for externalFocus in [false, true] {
            let system = FSCWindowSystem()
            let snapshot = restoredSnapshot(system)
            if externalFocus {
                system.foregroundChanges.send(20)
                system.foregroundChanges.send(system.foregroundPID)
            } else { system.userInput.send(()) }
            XCTAssertFalse(snapshot.canRestore(), "Returning to the old state must not revive a cancelled token")
            snapshot.cancel()
        }
    }

    func testAWindowClosedDuringThePolicyTransformIsNeverReopened() {
        let system = FSCWindowSystem()
        system.onPolicyChange = {
            system.notifications.post(name: NSWindow.willCloseNotification, object: system.main)
        }
        defer { system.onPolicyChange = nil }
        let application = LiveFullScreenApplication(environment: system.environment, notifications: system.notifications)
        let snapshot = application.windowSnapshot()
        XCTAssertTrue(application.setActivationPolicy(.accessory))
        snapshot.restore()
        XCTAssertFalse(system.main.isVisible)
        XCTAssertNil(system.keyWindow)
        XCTAssertEqual(system.orderedNumbers, [3, 2])
        snapshot.cancel()
    }

    func testDelayedSnapshotTracksAnotherAppsFocusWhileThisAppStaysInactive() {
        let system = FSCWindowSystem()
        system.isActive = false
        system.keyWindow = nil
        let application = LiveFullScreenApplication(environment: system.environment, notifications: system.notifications)
        let snapshot = application.windowSnapshot()
        snapshot.restore()
        snapshot.armDelayedRestoration(false)
        XCTAssertTrue(snapshot.canRestore())
        system.foregroundPID = 20
        XCTAssertFalse(system.isActive)
        XCTAssertFalse(snapshot.canRestore())
        snapshot.cancel()
    }

    private func restoredSnapshot(_ system: FSCWindowSystem) -> FullScreenApplicationWindowSnapshot {
        let application = LiveFullScreenApplication(environment: system.environment, notifications: system.notifications)
        let snapshot = application.windowSnapshot()
        XCTAssertTrue(application.setActivationPolicy(.accessory))
        snapshot.restore()
        application.activate()
        snapshot.armDelayedRestoration(false)
        return snapshot
    }
}

@MainActor
private final class FSCWindowSystem {
    let notifications = NotificationCenter()
    let userInput = PassthroughSubject<Void, Never>()
    let foregroundChanges = PassthroughSubject<Int32?, Never>()
    let main = FSCWindow(number: 1)
    let settings = FSCWindow(number: 2)
    let subtitles = FSCWindow(number: 3)
    var allWindows: [FSCWindow] = []
    var enumeratedWindows: [FSCWindow]?
    var orderedNumbers = [3, 2, 1]
    var mainWindow: FSCWindow?
    var keyWindow: FSCWindow?
    var isActive = true
    var foregroundPID: Int32 = 10
    var policy: NSApplication.ActivationPolicy = .regular
    var unhideShowsAllWindows = false
    var parentsRevealChildren = false
    var onPolicyChange: (() -> Void)?
    var defersActivation = false
    var activationCalls = 0

    init() {
        allWindows = [main, settings, subtitles]
        mainWindow = main
        keyWindow = main
        allWindows.forEach { $0.system = self }
    }

    func addWindow(number: Int, visible: Bool = true, parent: FSCWindow? = nil) -> FSCWindow {
        let window = FSCWindow(number: number)
        window.isVisible = visible
        window.parent = parent
        parent?.children.append(window)
        window.system = self
        allWindows.append(window)
        if visible { orderedNumbers.insert(number, at: 0) }
        return window
    }

    func completeActivation(keyWindow: FSCWindow) {
        isActive = true
        foregroundPID = 10
        self.keyWindow = keyWindow
        mainWindow = keyWindow
        foregroundChanges.send(10)
        notifications.post(name: NSWindow.didBecomeKeyNotification, object: keyWindow)
        notifications.post(name: NSWindow.didBecomeMainNotification, object: keyWindow)
    }

    var environment: FullScreenApplicationEnvironment {
        FullScreenApplicationEnvironment(windows: { self.enumeratedWindows ?? self.allWindows },
            orderedWindowNumbers: { self.orderedNumbers }, mainWindow: { self.mainWindow },
            keyWindow: { self.keyWindow }, isActive: { self.isActive }, activationPolicy: { self.policy },
            setActivationPolicy: { policy in
                self.onPolicyChange?()
                self.policy = policy
                for window in self.allWindows {
                    window.isVisible = false
                    window.isMiniaturized = false
                    window.firstResponder = nil
                }
                self.orderedNumbers = []
                self.keyWindow = nil
                self.mainWindow = nil
                return true
            }, unhide: {
                if self.unhideShowsAllWindows { self.allWindows.forEach { $0.orderFrontRegardless() } }
            }, activate: {
                self.activationCalls += 1
                if !self.defersActivation { self.isActive = true; self.foregroundPID = 10 }
            }, foregroundApplicationPID: { self.foregroundPID },
            applicationPID: 10,
            observeUserInput: { action in self.userInput.sink { action() } },
            observeForegroundChanges: { action in self.foregroundChanges.sink { action($0) } })
    }
}

@MainActor
private final class FSCWindow: FullScreenRestorableWindow {
    let windowNumber: Int
    var isVisible = true
    var isMiniaturized = false
    var firstResponder: NSResponder?
    weak var parent: FSCWindow?
    var children: [FSCWindow] = []
    weak var system: FSCWindowSystem?
    var restorationParent: (any FullScreenRestorableWindow)? { parent }
    var restorationChildren: [any FullScreenRestorableWindow] { children }
    init(number: Int) { windowNumber = number }
    func orderFrontRegardless() {
        isVisible = true
        system?.orderedNumbers.removeAll { $0 == windowNumber }
        system?.orderedNumbers.insert(windowNumber, at: 0)
        if system?.parentsRevealChildren == true { children.forEach { $0.orderFrontRegardless() } }
    }
    func orderOut(_ sender: Any?) {
        isVisible = false
        system?.orderedNumbers.removeAll { $0 == windowNumber }
    }
    func order(_ place: NSWindow.OrderingMode, relativeTo otherWindowNumber: Int) {
        guard let system else { return }
        system.orderedNumbers.removeAll { $0 == windowNumber }
        isVisible = true
        if let index = system.orderedNumbers.firstIndex(of: otherWindowNumber) {
            system.orderedNumbers.insert(windowNumber, at: index + (place == .below ? 1 : 0))
        } else { system.orderedNumbers.insert(windowNumber, at: 0) }
    }
    func makeKey() { system?.keyWindow = self }
    func makeMain() { system?.mainWindow = self }
    func makeFirstResponder(_ responder: NSResponder?) -> Bool { firstResponder = responder; return true }
    func miniaturize(_ sender: Any?) { isMiniaturized = true; orderOut(sender) }
    func deminiaturize(_ sender: Any?) { isMiniaturized = false; orderFrontRegardless() }
}

@MainActor
private final class FSCFixture {
    let suite: String
    let defaults: UserDefaults
    let model: AppModel
    let root: URL
    let application: FSCApplication
    let status: FSCStatusItem
    let subtitles: FSCSubtitles
    let recording: FSCRecording
    let scheduler: FSCScheduler
    let controller: FullScreenClassModeController
    let notifications = NotificationCenter()

    init(testCase: XCTestCase, savedEnabled: Bool? = nil,
         policy: NSApplication.ActivationPolicy = .regular) throws {
        let base = try FloatingSubtitleWindowTestFixture(testCase: testCase)
        model = base.model
        root = base.ddOverlay.resolvingSymlinksInPath()
        // Synthetic presentation phases must not acquire an actual idle-sleep assertion.
        base.model.preventIdleSleepWhileRecording = false
        let suite = "FullScreenClassMode-\(UUID().uuidString)"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        testCase.addTeardownBlock { try cleanup.remove() }
        if let savedEnabled { defaults.set(savedEnabled, forKey: FullScreenClassModeController.preferenceKey) }
        self.suite = suite
        self.defaults = defaults
        let application = FSCApplication(policy: policy)
        let status = FSCStatusItem()
        let subtitles = FSCSubtitles()
        let recording = FSCRecording()
        let scheduler = FSCScheduler()
        let controller = FullScreenClassModeController(defaults: defaults, application: application,
            statusItem: status, subtitles: subtitles, notifications: notifications,
            schedule: { scheduler.enqueue($0) })
        controller.connect(model: base.model, recording: recording.commands)
        self.application = application
        self.status = status
        self.subtitles = subtitles
        self.recording = recording
        self.scheduler = scheduler
        self.controller = controller
        testCase.addTeardownBlock { @MainActor in
            controller.shutdown()
            scheduler.drain()
            await base.model.resetTranslationSessionForTesting()?.value
        }
    }
}

@MainActor
private final class FSCScheduler {
    private var pending: [@MainActor () -> Void] = []
    var pendingCount: Int { pending.count }
    func enqueue(_ action: @escaping @MainActor () -> Void) { pending.append(action) }
    func drain() {
        while !pending.isEmpty { pending.removeFirst()() }
    }
}

@MainActor
private final class FSCApplication: FullScreenApplicationControlling {
    var activationPolicy: NSApplication.ActivationPolicy
    var rejectedPolicy: NSApplication.ActivationPolicy?
    var mainWindowVisible = false
    var mainWindowKey = false
    var userDecisionGeneration = 0
    private(set) var policies: [NSApplication.ActivationPolicy] = []
    private(set) var restoredSnapshots: [Int] = []
    private(set) var showCount = 0
    private(set) var activateCount = 0
    private(set) var terminateCount = 0
    private var snapshotCount = 0
    private weak var registeredWindow: NSWindow?
    private var reopen: (() -> Void)?

    init(policy: NSApplication.ActivationPolicy = .regular) { activationPolicy = policy }
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        policies.append(policy)
        guard policy != rejectedPolicy else { return false }
        activationPolicy = policy
        mainWindowVisible = false
        mainWindowKey = false
        return true
    }
    func windowSnapshot() -> FullScreenApplicationWindowSnapshot {
        snapshotCount += 1
        let identity = snapshotCount, visible = mainWindowVisible, key = mainWindowKey
        let decision = userDecisionGeneration
        var cancelled = false
        return FullScreenApplicationWindowSnapshot(hasWindows: visible, wasKey: key) { [weak self] in
            guard let self else { return }
            self.restoredSnapshots.append(identity)
            self.mainWindowVisible = visible
            self.mainWindowKey = key
        } canRestore: { [weak self] in !cancelled && self?.userDecisionGeneration == decision }
          cancel: { cancelled = true }
    }
    func registerMainWindow(_ window: NSWindow, reopen: @escaping () -> Void) {
        registeredWindow = window
        self.reopen = reopen
    }
    func showMainWindow() { showCount += 1; mainWindowVisible = true }
    func activate() { activateCount += 1 }
    func requestTermination() { terminateCount += 1 }
}

@MainActor
private final class FSCStatusItem: FullScreenStatusItemPresenting {
    var installSucceeds = true
    private(set) var isInstalled = false
    private(set) var installCount = 0
    private(set) var removeCount = 0
    private(set) var menu: NSMenu?
    private(set) var appearance: FullScreenStatusAppearance?
    func install(menu: NSMenu, appearance: FullScreenStatusAppearance) -> Bool {
        installCount += 1
        guard installSucceeds else { return false }
        isInstalled = true
        self.menu = menu
        self.appearance = appearance
        return true
    }
    func update(appearance: FullScreenStatusAppearance) { self.appearance = appearance }
    func remove() { removeCount += 1; isInstalled = false; menu = nil }
}

@MainActor
private final class FSCRecording {
    var state = FullScreenRecordingState()
    var toggleCount = 0
    var commands: FullScreenRecordingCommands {
        FullScreenRecordingCommands(state: { self.state }, toggle: { self.toggleCount += 1 })
    }
}

@MainActor
private final class FSCSurface: FloatingSubtitleWindowSurface {
    var level: NSWindow.Level
    var collectionBehavior: NSWindow.CollectionBehavior
    var ignoresMouseEvents: Bool
    var isOpaque: Bool
    var subtitleBackgroundColor: NSColor?
    private(set) var shadowInvalidations = 0
    init(level: NSWindow.Level = .modalPanel, behavior: NSWindow.CollectionBehavior = [.managed, .ignoresCycle],
         ignoresMouseEvents: Bool = false, isOpaque: Bool = true, color: NSColor? = .systemTeal) {
        self.level = level
        collectionBehavior = behavior
        self.ignoresMouseEvents = ignoresMouseEvents
        self.isOpaque = isOpaque
        subtitleBackgroundColor = color
    }
    func invalidateShadow() { shadowInvalidations += 1 }
}

@MainActor
private struct FSCWindowValues {
    let level: NSWindow.Level
    let behavior: NSWindow.CollectionBehavior
    let ignoresMouseEvents: Bool
    let isOpaque: Bool
    let color: NSColor?
    init(_ window: FSCSurface) {
        level = window.level
        behavior = window.collectionBehavior
        ignoresMouseEvents = window.ignoresMouseEvents
        isOpaque = window.isOpaque
        color = window.subtitleBackgroundColor
    }
}

@MainActor
private final class FSCSubtitles: FullScreenSubtitleControlling {
    let surface = FSCSurface()
    let original: FSCWindowValues
    private let configuration: FloatingSubtitleWindowConfiguration
    private var settings = FloatingSubtitleWindowSettings(showsAcrossSpaces: false)
    private let changes = PassthroughSubject<Void, Never>()
    var stateChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
    var isLocked: Bool { settings.isLocked }
    private(set) var isVisible = false
    private(set) var modeChanges: [Bool] = []
    private(set) var menuTrackingChanges: [Bool] = []
    private(set) var hideCount = 0
    private(set) var moveCount = 0
    private(set) var shutdownCount = 0
    private(set) weak var shownModel: AppModel?
    init() {
        original = FSCWindowValues(surface)
        configuration = FloatingSubtitleWindowConfiguration(window: surface)
    }
    func setFullScreenClassMode(_ enabled: Bool) {
        modeChanges.append(enabled)
        settings.fullScreenClassMode = enabled
        configuration.apply(settings)
    }
    func setPopupIsOpen(_ open: Bool) {
        menuTrackingChanges.append(open)
        settings.popupIsOpen = open
        configuration.apply(settings)
    }
    func show(model: AppModel) { shownModel = model; setVisibleExternally(true) }
    func hide() { hideCount += 1; setVisibleExternally(false) }
    func toggleLock() { setLockedExternally(!isLocked) }
    func moveToScreenBottom() { moveCount += 1 }
    func shutdown() {
        shutdownCount += 1
        configuration.restore()
        changes.send(())
        isVisible = false
        settings = FloatingSubtitleWindowSettings()
    }
    func setVisibleExternally(_ visible: Bool) {
        changes.send(())
        isVisible = visible
    }
    func setLockedExternally(_ locked: Bool) {
        changes.send(())
        settings.isLocked = locked
        configuration.apply(settings)
    }
    func setAcrossSpaces(_ enabled: Bool) {
        settings.showsAcrossSpaces = enabled
        configuration.apply(settings)
    }
}

/// Draws the actual NSMenuItem instances using AppKit's native cells. It never
/// calls popup/context-menu APIs or creates an NSStatusItem.
@MainActor
private final class FSCNativeMenuView: NSView {
    let cells: [NSMenuItemCell]
    private let rowHeights: [CGFloat]
    override var isFlipped: Bool { true }
    init(menu: NSMenu) {
        cells = menu.items.map { item in
            let cell = NSMenuItemCell(textCell: item.title)
            cell.menuItem = item
            cell.state = item.state
            cell.isEnabled = item.isEnabled
            cell.font = NSFont.menuFont(ofSize: 14)
            // A plain offscreen view has no menu-view cache. Populate the
            // native cell's drawing title from the same real controller item.
            cell.attributedTitle = item.attributedTitle ?? NSAttributedString(string: item.title,
                attributes: [.font: NSFont.menuFont(ofSize: 14), .foregroundColor: NSColor.controlTextColor])
            cell.calcSize()
            return cell
        }
        rowHeights = menu.items.map { $0.isSeparatorItem ? 10 : 30 }
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: rowHeights.reduce(0, +) + 16))
        appearance = NSAppearance(named: .aqua)
    }
    required init?(coder: NSCoder) { fatalError("Native menu fixtures are created in code") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        var y: CGFloat = 8
        for (cell, height) in zip(cells, rowHeights) {
            let row = NSRect(x: 10, y: y, width: bounds.width - 20, height: height)
            if cell.menuItem?.isSeparatorItem == true { cell.drawSeparatorItem(withFrame: row, in: self) }
            else {
                cell.draw(withFrame: row, in: self)
                // The menu-view state-image cache is absent too; use the real
                // item's native image in the rectangle computed by its cell.
                if cell.state == .on {
                    cell.menuItem?.onStateImage?.draw(in: cell.stateImageRect(forBounds: row))
                }
            }
            y += height
        }
    }
}
