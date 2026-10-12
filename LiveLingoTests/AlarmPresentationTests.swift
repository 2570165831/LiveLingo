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
        XCTAssertEqual(warning.detail, "30 秒后保存本节，并另开新录音继续")
        XCTAssertEqual(warning.buttonTitle, "取消")
        XCTAssertEqual(AlarmBannerState(saved: true).title, AlarmPolicy.savedTitle)
        XCTAssertEqual(AlarmBannerState(liveOnly: true).buttonTitle, "知道了")
        XCTAssertTrue(AlarmBannerState(liveOnly: true).detail.contains("不自动保存"))
    }
    func testMainAndFloatingBannersLightDarkAndReducedMotionScreenshots() async throws {
        let (model, defaults, _) = try fixture()
        let controller = FloatingSubtitleWindowController(defaults: defaults)
        defer { controller.close() }
        let directory = TestFixtureDirectory.root.appendingPathComponent("alarm-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            for reduced in [false, true] {
                model.presentAlarmBannerForTesting(AlarmBannerState(secondsRemaining: 30))
                let style = (dark ? "dark" : "light") + (reduced ? "-reduced" : "-breathing")
                let main = AnyView(ContentView().environmentObject(model).defaultAppStorage(defaults)
                    .environment(\.colorScheme, dark ? .dark : .light))
                try await capture(main, size: NSSize(width: 1050, height: 760), dark: dark,
                    border: reduced, directory: directory, name: "alarm-main-" + style)
                let floating = AnyView(FloatingSubtitleView(windowController: controller).environmentObject(model)
                    .defaultAppStorage(defaults).environment(\.colorScheme, .dark))
                try await capture(floating, size: NSSize(width: 670, height: 425), dark: true,
                    border: nil, directory: directory, name: "alarm-floating-" + style)
            }
        }
        model.presentAlarmBannerForTesting(AlarmBannerState(saved: true))
        try await capture(AnyView(AlarmBanner(state: model.alarmBanner!, dismiss: {})),
            size: NSSize(width: 1050, height: 100), dark: false, border: nil,
            directory: directory, name: "alarm-saved-banner")
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
