import AppKit
import SwiftUI
import XCTest
@testable import LiveLingo

@MainActor
final class AlarmPresentationTests: XCTestCase {
    private func fixture() throws -> (AppModel, TestUserDefaults, LearningReviewQueue) {
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        let root = TestFixtureDirectory.root.appendingPathComponent("AlarmUI-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("review.json"),
            observeSleep: false, diagnostics: .disabled, generate: { _, _, _, _, _ in throw CancellationError() })
        let model = AppModel(reviewQueue: queue, pipeline: SpeechPipeline(enableAudioAnalysis: false),
            backgroundServices: false, defaults: defaults)
        model.loadPresentationForTesting(phase: .recording, evidence: [
            TranscriptSegment(startTime: 0, endTime: 4, english: "This is a synthetic subtitle for interface testing.",
                              chinese: "这是用于界面测试的合成字幕。")
        ])
        model.configureAlarmForTesting(input: .microphone)
        addTeardownBlock { @MainActor in
            await model.retireAlarmTasksForTesting()
            try await TestTaskLifetime.stop(model, queue: queue)
            try cleanup.remove(defaults)
        }
        return (model, defaults, queue)
    }
    func testAllScreenPanelsAreNonKeyClickThroughAndWithdrawCompletely() throws {
        let presenter = AlarmReminderPresenter()
        presenter.reduceMotionOverride = true
        presenter.show(dismiss: {}, notifications: false, announce: false)
        defer { presenter.hide() }
        XCTAssertEqual(presenter.panels.count, NSScreen.screens.count)
        print("ALARM_UI_OVERLAY display_count=\(NSScreen.screens.count) click_through=true reduced_motion=true")
        for (panel, screen) in zip(presenter.panels, NSScreen.screens) {
            XCTAssertEqual(panel.frame, screen.frame)
            XCTAssertTrue(panel.ignoresMouseEvents)
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertFalse(panel.hidesOnDeactivate)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertEqual(panel.level.rawValue, Int(CGWindowLevelForKey(.screenSaverWindow)))
            XCTAssertNil(panel.contentView?.layer?.animation(forKey: "alarm-breath"))
        }
        presenter.hide()
        XCTAssertTrue(presenter.panels.isEmpty)
    }
    func testBreathingUsesContinuousOpacityAndReducedMotionRemovesAnimation() throws {
        let moving = AlarmBorderView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), reducedMotion: false)
        let animation = try XCTUnwrap(moving.layer?.animation(forKey: "alarm-breath") as? CABasicAnimation)
        XCTAssertEqual(animation.keyPath, "opacity")
        XCTAssertEqual(animation.duration * 2, AlarmPolicy.breathingPeriod)
        XCTAssertTrue(animation.autoreverses)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(animation.fromValue as? Double), 0.5)
        let still = AlarmBorderView(frame: moving.frame, reducedMotion: true)
        XCTAssertNil(still.layer?.animation(forKey: "alarm-breath"))
        XCTAssertEqual(still.layer?.opacity, 0.9)
    }
    func testExistingFloatingPanelExpandsForBannerAndReturnsToOriginalHeight() async throws {
        let (model, defaults, _) = try fixture()
        let controller = FloatingSubtitleWindowController(defaults: defaults)
        let panel = controller.prepareWindow(model: model)
        defer { controller.close() }
        let height = panel.frame.height
        let top = panel.frame.maxY
        model.presentAlarmBannerForTesting(.init(secondsRemaining: 30))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(panel.frame.height, height + 40)
        XCTAssertEqual(panel.frame.maxY, top, accuracy: 1)
        XCTAssertGreaterThanOrEqual(panel.frame.height, panel.contentView!.fittingSize.height)
        model.dismissAlarmReminder()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(panel.frame.height, height, accuracy: 1)
    }
    func testBannerTextsIncludeCountdownCancellationAndSavedConfirmation() {
        let warning = AlarmBannerState(secondsRemaining: 30)
        XCTAssertEqual(warning.title, AlarmPolicy.title)
        XCTAssertEqual(warning.detail, "倒计时结束后保存本节，并另开新录音继续。")
        XCTAssertEqual(warning.buttonTitle, "取消（30）")
        XCTAssertEqual(AlarmBannerState(secondsRemaining: 28).buttonTitle, "取消（28）")
        XCTAssertEqual(warning.buttonDetail, "不分段 · Esc")
        XCTAssertEqual(AlarmBannerState(secondsRemaining: 0, saved: true).buttonTitle, "知道了")
        XCTAssertEqual(AlarmBannerState(secondsRemaining: 0, saving: true).buttonTitle, "知道了")
        XCTAssertEqual(AlarmBannerState(saved: true).title, AlarmPolicy.savedTitle)
        XCTAssertEqual(AlarmBannerState(liveOnly: true).buttonTitle, "知道了")
        XCTAssertTrue(AlarmBannerState(liveOnly: true).detail.contains("不自动保存"))
    }
    func testLockedSubtitleBannerAcceptsClickAndKeyboardFocusThenRestoresClickThrough() async throws {
        let (model, defaults, _) = try fixture()
        let controller = FloatingSubtitleWindowController(defaults: defaults)
        let panel = controller.prepareWindow(model: model)
        defer { controller.shutdown() }
        controller.toggleLock()
        XCTAssertTrue(panel.ignoresMouseEvents)
        model.presentAlarmBannerForTesting(.init(secondsRemaining: 28))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(controller.isLocked)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(panel.canBecomeKey)
        // Preference changes during a reminder must retain its temporary policy.
        controller.updateSettings(showsAcrossSpaces: false, backgroundOpacity: 0.7)
        XCTAssertFalse(panel.ignoresMouseEvents)
        model.dismissAlarmReminder()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(controller.isLocked)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.isVisible)
    }
    func testBottomSubtitleExpansionKeepsWholeSubtitleAreaOnItsOwnScreen() async throws {
        let (model, defaults, _) = try fixture()
        let visible = NSRect(x: -1920, y: -1000, width: 1920, height: 900)
        let screens = FloatingSubtitleWindowScreens(windowVisibleFrame: { _ in visible },
            mainVisibleFrame: { visible }, firstVisibleFrame: { visible })
        let controller = FloatingSubtitleWindowController(defaults: defaults, screens: screens)
        let panel = controller.prepareWindow(model: model)
        defer { controller.shutdown() }
        controller.moveToScreenBottom()
        let original = panel.frame
        model.presentAlarmBannerForTesting(.init(secondsRemaining: 28))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(panel.frame.height, original.height)
        XCTAssertEqual(panel.frame.minY, original.minY, accuracy: 1)
        XCTAssertTrue(visible.contains(panel.frame), "Both the banner and subtitles must stay above the Dock")
        XCTAssertFalse(panel.isVisible)
        model.presentAlarmBannerForTesting(.init(saved: true))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(visible.contains(panel.frame))
        model.dismissAlarmReminder()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(panel.frame.height, original.height, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, original.minY, accuracy: 1)
    }
    func testNotificationsOnlyWhenSubtitlesBecomeHiddenAndOnlyOncePerReminder() throws {
        let (model, defaults, _) = try fixture()
        let center = NotificationCenter()
        let controller = FloatingSubtitleWindowController(defaults: defaults, notificationCenter: center)
        let panel = controller.prepareWindow(model: model)
        panel.alphaValue = 0
        let presenter = AlarmReminderPresenter()
        defer { presenter.hide(); controller.shutdown() }
        var bodies: [String] = []
        presenter.requestNotificationForTesting = { bodies.append($0) }
        controller.show(model: model)
        presenter.show(dismiss: {}, announce: false, subtitles: controller)
        XCTAssertTrue(bodies.isEmpty, "Visible subtitles must not send system alerts")
        controller.hide()
        XCTAssertEqual(bodies, [AlarmPolicy.notification])
        controller.show(model: model)
        controller.hide()
        XCTAssertEqual(bodies.count, 1)
        presenter.hide()
        presenter.show(dismiss: {}, announce: false, subtitles: controller)
        XCTAssertEqual(bodies.count, 2, "A new reminder may notify while already hidden")
        presenter.hide()
        controller.show(model: model)
        presenter.show(dismiss: {}, announce: false, subtitles: controller)
        center.post(name: NSApplication.didHideNotification, object: NSApplication.shared)
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(bodies.count, 3, "App hiding counts as hidden subtitles")
        center.post(name: NSApplication.didUnhideNotification, object: NSApplication.shared)
        XCTAssertTrue(controller.isVisible)
        controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification, object: panel))
        XCTAssertFalse(controller.isVisible)
        XCTAssertEqual(bodies.count, 3)
    }
    func testEscapeCancelsOnlyLocalWindowEventsAndStopsAfterHide() throws {
        let presenter = AlarmReminderPresenter()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { presenter.hide(); window.close() }
        var cancelled = 0
        presenter.show(dismiss: { cancelled += 1 }, notifications: false, announce: false)
        func event(code: UInt16, number: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: number, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: code))
        }
        XCTAssertFalse(presenter.handleEscape(try event(code: 53, number: 0)))
        XCTAssertFalse(presenter.handleEscape(try event(code: 0, number: window.windowNumber)))
        XCTAssertTrue(presenter.handleEscape(try event(code: 53, number: window.windowNumber)))
        XCTAssertEqual(cancelled, 1)
        presenter.hide()
        XCTAssertFalse(presenter.handleEscape(try event(code: 53, number: window.windowNumber)))
        XCTAssertEqual(cancelled, 1)
    }
    func testMainAndFloatingBannersLightDarkAndReducedMotionScreenshots() async throws {
        let (model, defaults, _) = try fixture()
        let controller = FloatingSubtitleWindowController(defaults: defaults)
        defer { controller.close() }
        let directory = TestFixtureDirectory.root.appendingPathComponent("alarm-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            for reduced in [false, true] {
                model.presentAlarmBannerForTesting(AlarmBannerState(secondsRemaining: 28))
                let style = (dark ? "dark" : "light") + (reduced ? "-reduced" : "-breathing")
                let main = AnyView(ContentView().environmentObject(model).defaultAppStorage(defaults)
                    .environment(\.colorScheme, dark ? .dark : .light))
                try await capture(main, size: NSSize(width: 1050, height: 760), dark: dark,
                    border: reduced, directory: directory, name: "alarm-main-" + style)
                let floating = AnyView(FloatingSubtitleView(windowController: controller).environmentObject(model)
                    .defaultAppStorage(defaults).environment(\.colorScheme, .dark))
                let floatingSize = NSHostingView(rootView: floating).fittingSize
                try await capture(floating, size: floatingSize, dark: true,
                    border: nil, directory: directory, name: "alarm-floating-" + style)
            }
        }
        model.presentAlarmBannerForTesting(AlarmBannerState(saved: true))
        try await capture(AnyView(AlarmBanner(state: model.alarmBanner!, dismiss: {})),
            size: NSSize(width: 1050, height: 160), dark: false, border: nil,
            directory: directory, name: "alarm-saved-banner")
        try await capture(AnyView(ClassroomSettingsView().environmentObject(model).defaultAppStorage(defaults)),
            size: NSSize(width: 860, height: 900), dark: false, border: nil,
            directory: directory, name: "alarm-reminder-settings")
    }
    private func capture(_ rootView: AnyView, size: NSSize, dark: Bool, border: Bool?,
                         directory: URL, name: String) async throws {
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.title = "LiveLingo · 合成界面测试"
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        hosting.frame = frame
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(200))
        window.setContentSize(size)
        hosting.setFrameSize(size)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        // Composite the production native red-border layer over this owned,
        // synthetic window only. No user's desktop or other app is captured.
        if let reduced = border {
            let nativeBorder = AlarmBorderView(frame: hosting.bounds, reducedMotion: reduced)
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            nativeBorder.layer?.render(in: context.cgContext)
            NSGraphicsContext.restoreGraphicsState()
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 5000, "Blank windows are not screenshot evidence")
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .withoutOverwriting)
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        print("ALARM_UI_SCREENSHOT name=\(name) width=\(bitmap.pixelsWide) height=\(bitmap.pixelsHigh) synthetic_only=true")
    }
}
