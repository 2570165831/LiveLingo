import AppKit
import CoreServices
import Darwin
import Foundation
import XCTest
@testable import LiveLingo

@MainActor
private final class PrivacyExitGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0; entered = true }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class PrivacyExitRetryState {
    var calls = 0
    var failed = true
}

@MainActor
private final class RecordingQuitConsent {
    var approved = false
}

@MainActor
final class PrivacyExitTests: XCTestCase {
    private enum Failure: Error { case synthetic }

    func testUnitTestPresentationSafetyKeepsUnshownWindowsTransparent() {
        XCTAssertTrue(UnitTestPresentationSafety.isInstalled)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.alphaValue = 1
        XCTAssertEqual(window.alphaValue, 0)
        window.alphaValue = 0.75
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertFalse(window.isVisible, "Safety tests must never order a real window onto the screen")
    }

    func testUnitTestPresentationSafetySuppressesActivationAndModalExecutionByInjection() {
        var activations = 0, modals = 0
        XCTAssertFalse(UnitTestPresentationSafety.performActivation(isUnitTesting: true) {
            activations += 1; return true
        })
        XCTAssertEqual(UnitTestPresentationSafety.performModal(isUnitTesting: true) {
            modals += 1; return .alertSecondButtonReturn
        }, .abort)
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(modals, 0)
        XCTAssertEqual(UnitTestPresentationSafety.alphaValue(requested: 1, isUnitTesting: true), 0)
    }

    func testUnitTestPresentationSafetyLeavesProductionPoliciesUnchangedByInjection() {
        var activations = 0, modals = 0
        XCTAssertTrue(UnitTestPresentationSafety.performActivation(isUnitTesting: false) {
            activations += 1; return true
        })
        XCTAssertEqual(UnitTestPresentationSafety.performModal(isUnitTesting: false) {
            modals += 1; return .alertSecondButtonReturn
        }, .alertSecondButtonReturn)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(modals, 1)
        XCTAssertEqual(UnitTestPresentationSafety.alphaValue(requested: 0.75, isUnitTesting: false), 0.75)
    }

    private func quitEvent(reason: OSType?, attribute: Bool = true,
                           eventID: OSType = OSType(kAEQuitApplication)) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: OSType(kCoreEventClass), eventID: eventID,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        if let reason {
            let value = NSAppleEventDescriptor(enumCode: reason)
            if attribute { event.setAttribute(value, forKeyword: AEKeyword(kAEQuitReason)) }
            else { event.setParam(value, forKeyword: AEKeyword(kAEQuitReason)) }
        }
        return event
    }

    func testRecordingQuitConfirmationIncludesPausedAndImportingSessions() {
        for phase: AppPhase in [.recording, .paused] {
            XCTAssertTrue(RecordingQuitConfirmation.isNeeded(phase: phase, importing: false))
        }
        for phase: AppPhase in [.idle, .preparing, .stopping, .liveEnded, .failed("synthetic"),
                                .saved(TestFixtureDirectory.root)] {
            XCTAssertFalse(RecordingQuitConfirmation.isNeeded(phase: phase, importing: false))
            XCTAssertTrue(RecordingQuitConfirmation.isNeeded(phase: phase, importing: true))
        }
    }

    func testRecordingQuitContinuePreservesModelAndDoesNotBeginSaving() async throws {
        let (model, _, _) = try makeModel()
        for phase: AppPhase in [.recording, .paused] {
            model.loadPresentationForTesting(phase: phase, evidence: model.segments, preview: "synthetic preview")
            let segments = model.segments, preview = model.volatileEnglish
            let root = model.temporarySessionForPrivacyExitTesting
            let delegate = AppLifecycleDelegate()
            var saves = 0, prompts = 0
            delegate.recordingStateForTesting = { (model.phase, model.isImportingFile) }
            delegate.confirmRecordingQuitForTesting = { prompts += 1; return false }
            delegate.cleanupForTesting = { saves += 1; return true }
            delegate.replyForTesting = { _ in XCTFail("A cancelled quit must not produce an asynchronous reply") }
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
            await Task.yield()
            XCTAssertEqual(prompts, 1)
            XCTAssertEqual(saves, 0)
            XCTAssertEqual(model.phase, phase)
            XCTAssertEqual(model.segments, segments)
            XCTAssertEqual(model.volatileEnglish, preview)
            XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, root)
        }
    }

    func testRecordingQuitImportingCancelReturnsCancelWithoutStartingCleanup() {
        let delegate = AppLifecycleDelegate()
        var saves = 0
        delegate.recordingStateForTesting = { (.preparing, true) }
        delegate.confirmRecordingQuitForTesting = { false }
        delegate.cleanupForTesting = { saves += 1; return true }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(saves, 0)
    }

    func testRecordingQuitConfirmedUsesExistingAsynchronousSaveOnce() async throws {
        let delegate = AppLifecycleDelegate(), gate = PrivacyExitGate()
        var prompts = 0, saves = 0, replies: [Bool] = []
        delegate.recordingStateForTesting = { (.recording, false) }
        delegate.confirmRecordingQuitForTesting = { prompts += 1; return true }
        delegate.cleanupForTesting = { saves += 1; await gate.wait(); return true }
        delegate.replyForTesting = { replies.append($0) }
        delegate.terminationTimeoutForTesting = 5
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        let until = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.entered, ContinuousClock.now < until { await Task.yield() }
        XCTAssertTrue(gate.entered)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(saves, 1)
        XCTAssertTrue(replies.isEmpty)
        gate.release()
        while replies.isEmpty, ContinuousClock.now < until { await Task.yield() }
        XCTAssertEqual(replies, [true])
    }

    func testRecordingQuitFailedSaveRetainsExistingFailureDecisionAndRequiresFreshConsent() async throws {
        let delegate = AppLifecycleDelegate()
        var prompts = 0, failurePrompts = 0, replies: [Bool] = []
        delegate.recordingStateForTesting = { (.paused, false) }
        delegate.confirmRecordingQuitForTesting = { prompts += 1; return true }
        delegate.cleanupForTesting = { false }
        delegate.confirmExitWithoutSavingForTesting = { failurePrompts += 1; return false }
        delegate.replyForTesting = { replies.append($0) }
        for expected in 1...2 {
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            let until = ContinuousClock.now.advanced(by: .seconds(2))
            while replies.count < expected, ContinuousClock.now < until { await Task.yield() }
            XCTAssertEqual(replies, Array(repeating: false, count: expected))
            XCTAssertEqual(prompts, expected)
            XCTAssertEqual(failurePrompts, expected)
        }
    }

    func testRecordingQuitInactiveSessionDoesNotPrompt() async throws {
        let delegate = AppLifecycleDelegate()
        var replies: [Bool] = []
        delegate.recordingStateForTesting = { (.idle, false) }
        delegate.confirmRecordingQuitForTesting = { XCTFail("Idle quit must not prompt"); return false }
        delegate.cleanupForTesting = { true }
        delegate.replyForTesting = { replies.append($0) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        let until = ContinuousClock.now.advanced(by: .seconds(2))
        while replies.isEmpty, ContinuousClock.now < until { await Task.yield() }
        XCTAssertEqual(replies, [true])
    }

    func testRecordingQuitSystemReasonsBypassConfirmationAndStillSave() async throws {
        for reason in [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut] {
            for attribute in [true, false] {
                let delegate = AppLifecycleDelegate()
                var saves = 0, replies: [Bool] = []
                delegate.recordingStateForTesting = { (.recording, false) }
                delegate.terminationEventForTesting = quitEvent(reason: reason, attribute: attribute)
                delegate.confirmRecordingQuitForTesting = { XCTFail("System quit must not prompt"); return false }
                delegate.cleanupForTesting = { saves += 1; return true }
                delegate.replyForTesting = { replies.append($0) }
                XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
                let until = ContinuousClock.now.advanced(by: .seconds(2))
                while replies.isEmpty, ContinuousClock.now < until { await Task.yield() }
                XCTAssertEqual(saves, 1)
                XCTAssertEqual(replies, [true])
            }
        }
    }

    func testRecordingQuitDockOrOrdinaryAppleEventStillPrompts() {
        XCTAssertFalse(RecordingQuitConfirmation.isSystemTermination(nil))
        XCTAssertFalse(RecordingQuitConfirmation.isSystemTermination(quitEvent(reason: nil)))
        XCTAssertFalse(RecordingQuitConfirmation.isSystemTermination(quitEvent(reason: OSType(kAEOpenApplication))))
        XCTAssertFalse(RecordingQuitConfirmation.isSystemTermination(
            quitEvent(reason: OSType(kAEShutDown), eventID: OSType(kAEOpenApplication))))
        let delegate = AppLifecycleDelegate()
        var prompts = 0
        delegate.terminationEventForTesting = quitEvent(reason: nil)
        delegate.recordingStateForTesting = { (.recording, false) }
        delegate.confirmRecordingQuitForTesting = { prompts += 1; return false }
        delegate.cleanupForTesting = { XCTFail("Cancelled Dock quit must not save"); return true }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(prompts, 1)
    }

    func testRecordingQuitSystemRequestWhileConfirmingDoesNotStartDuplicateSave() async throws {
        let delegate = AppLifecycleDelegate(), gate = PrivacyExitGate()
        var saves = 0, aborts = 0, replies: [Bool] = []
        delegate.recordingStateForTesting = { (.paused, false) }
        delegate.abortRecordingConfirmationForTesting = { aborts += 1 }
        delegate.confirmRecordingQuitForTesting = {
            delegate.terminationEventForTesting = self.quitEvent(reason: OSType(kAEShutDown))
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            XCTAssertEqual(aborts, 1, "A system request must dismiss the confirmation only once")
            return false
        }
        delegate.cleanupForTesting = { saves += 1; await gate.wait(); return true }
        delegate.replyForTesting = { replies.append($0) }
        delegate.terminationTimeoutForTesting = 5
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        let until = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.entered, ContinuousClock.now < until { await Task.yield() }
        XCTAssertEqual(saves, 1)
        gate.release()
        while replies.isEmpty, ContinuousClock.now < until { await Task.yield() }
        XCTAssertEqual(replies, [true])
    }

    func testRecordingQuitContinueKeepsPresentedSheetAndApprovedQuitPromptsOnlyOnce() async throws {
        let delegate = AppLifecycleDelegate()
        let consent = RecordingQuitConsent()
        var prompts = 0, dismissals = 0, replies: [Bool] = []
        let previous = FilePanelPresentation.authorizeTermination
        let previousAttempt = FilePanelPresentation.performAuthorizedTermination
        FilePanelPresentation.authorizeTermination = { delegate.authorizeRecordingTermination() }
        FilePanelPresentation.performAuthorizedTermination = { delegate.withRecordingTerminationAuthorization($0) }
        let id = UUID()
        defer {
            FilePanelPresentation.sheetDidDismiss(id: id)
            FilePanelPresentation.authorizeTermination = previous
            FilePanelPresentation.performAuthorizedTermination = previousAttempt
        }
        FilePanelPresentation.registerSheet(id: id) { dismissals += 1 }
        delegate.recordingStateForTesting = { (.recording, false) }
        delegate.confirmRecordingQuitForTesting = { prompts += 1; return consent.approved }
        delegate.cleanupForTesting = { true }
        delegate.replyForTesting = { replies.append($0) }
        FilePanelPresentation.requestTermination { _ = delegate.applicationShouldTerminate(NSApplication.shared) }
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(dismissals, 0)
        XCTAssertTrue(replies.isEmpty)
        consent.approved = true
        FilePanelPresentation.requestTermination { _ = delegate.applicationShouldTerminate(NSApplication.shared) }
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(dismissals, 1)
        FilePanelPresentation.sheetDidDismiss(id: id)
        let until = ContinuousClock.now.advanced(by: .seconds(2))
        while replies.isEmpty, ContinuousClock.now < until { await Task.yield() }
        XCTAssertEqual(prompts, 2, "The delegate must consume the consent collected before dismissing the sheet")
        XCTAssertEqual(replies, [true])
    }

    func testRecordingQuitLastWindowPolicyDoesNotTerminateOrChangeInjectedSession() async throws {
        let (model, _, _) = try makeModel()
        let delegate = AppLifecycleDelegate()
        for phase: AppPhase in [.recording, .paused] {
            model.loadPresentationForTesting(phase: phase, evidence: model.segments)
            XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
            XCTAssertEqual(model.phase, phase)
            XCTAssertTrue(model.hasActiveSession)
        }
    }

    func testRecordingQuitAlertDefaults() {
        let alert = RecordingQuitConfirmation.makeAlert()
        XCTAssertEqual(alert.messageText, "正在录音。退出会结束并保存这节课。")
        XCTAssertEqual(alert.buttons.map(\.title), ["继续录音", "保存并退出"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertTrue(alert.buttons[0].keyEquivalentModifierMask.isEmpty)
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
        XCTAssertFalse(alert.window.preventsApplicationTerminationWhenModal)
        alert.layout()
        let window = alert.window
        XCTAssertTrue(window.defaultButtonCell === alert.buttons[0].cell)
    }

    func testRecordingQuitAlertCopyMatchesPausedLiveOnlyAndImportBehaviorOffscreen() {
        let cases: [(AppPhase, Bool, Bool, String, [String])] = [
            (.recording, false, false, "正在录音。退出会结束并保存这节课。", ["继续录音", "保存并退出"]),
            (.paused, false, false, "录音已暂停。退出会结束并保存这节课。", ["保持暂停", "保存并退出"]),
            (.recording, false, true, "正在实时字幕（不保存）。退出会结束本次字幕，内容不会保存。", ["继续", "退出"]),
            (.paused, false, true, "实时字幕已暂停（不保存）。退出会结束本次字幕，内容不会保存。", ["保持暂停", "退出"]),
            (.preparing, true, true, "正在导入文件。退出会停止导入并保存已完成的内容。", ["继续导入", "保存并退出"]),
            (.recording, true, false, "正在导入文件。退出会停止导入并保存已完成的内容。", ["继续导入", "保存并退出"])
        ]
        for (phase, importing, liveOnly, message, titles) in cases {
            let alert = RecordingQuitConfirmation.makeAlert(phase: phase, importing: importing, liveOnly: liveOnly)
            XCTAssertEqual(alert.messageText, message)
            XCTAssertEqual(alert.buttons.map(\.title), titles)
            XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
            XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
            alert.layout()
            XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[0].cell)
            XCTAssertFalse(alert.window.isVisible, "Copy/default-button checks must never show a window")
        }
    }

    func testRecordingQuitRejectedBeforeDelegateRequiresFreshConsentWithAndWithoutSheet() async {
        for hasSheet in [false, true] {
            let delegate = AppLifecycleDelegate(), consent = RecordingQuitConsent()
            consent.approved = true
            var prompts = 0, attempts = 0
            let previous = FilePanelPresentation.authorizeTermination
            let previousAttempt = FilePanelPresentation.performAuthorizedTermination
            FilePanelPresentation.authorizeTermination = { delegate.authorizeRecordingTermination() }
            FilePanelPresentation.performAuthorizedTermination = { delegate.withRecordingTerminationAuthorization($0) }
            let id = UUID()
            defer {
                FilePanelPresentation.sheetDidDismiss(id: id)
                FilePanelPresentation.authorizeTermination = previous
                FilePanelPresentation.performAuthorizedTermination = previousAttempt
            }
            if hasSheet { FilePanelPresentation.registerSheet(id: id) {} }
            delegate.recordingStateForTesting = { (.recording, false) }
            delegate.confirmRecordingQuitForTesting = { prompts += 1; return consent.approved }
            delegate.cleanupForTesting = { XCTFail("The rejected request must not save"); return true }
            // Simulate AppKit rejecting terminate before calling the delegate.
            FilePanelPresentation.requestTermination { attempts += 1 }
            if hasSheet { FilePanelPresentation.sheetDidDismiss(id: id) }
            let until = ContinuousClock.now.advanced(by: .seconds(2))
            while attempts == 0, ContinuousClock.now < until { await Task.yield() }
            XCTAssertEqual(attempts, 1)
            consent.approved = false
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
            XCTAssertEqual(prompts, 2, "A rejected synchronous attempt must not authorize the next quit")
        }
    }

    func testRecordingQuitConsentIsConsumedOnlyBySynchronousDelegateCall() {
        let delegate = AppLifecycleDelegate()
        var prompts = 0
        delegate.recordingStateForTesting = { (.recording, false) }
        delegate.confirmRecordingQuitForTesting = { prompts += 1; return false }
        delegate.withRecordingTerminationAuthorization {
            XCTAssertTrue(delegate.authorizeRecordingTermination())
            XCTAssertFalse(delegate.authorizeRecordingTermination(), "The same consent cannot be used twice")
        }
        XCTAssertFalse(delegate.authorizeRecordingTermination())
        XCTAssertEqual(prompts, 2)
    }

    func testRecordingQuitRepeatedCommandsCoalesceBeforeAndDuringConfirmationOffscreen() {
        let delegate = AppLifecycleDelegate()
        var prompts = 0, scheduled: [@MainActor @Sendable () -> Void] = []
        let previous = FilePanelPresentation.authorizeTermination
        let previousScheduler = FilePanelPresentation.scheduleAfterEventForTesting
        FilePanelPresentation.authorizeTermination = { delegate.authorizeRecordingTermination() }
        FilePanelPresentation.scheduleAfterEventForTesting = { scheduled.append($0) }
        defer {
            FilePanelPresentation.authorizeTermination = previous
            FilePanelPresentation.scheduleAfterEventForTesting = previousScheduler
        }
        delegate.recordingStateForTesting = { (.recording, false) }
        delegate.confirmRecordingQuitForTesting = {
            prompts += 1
            FilePanelPresentation.scheduleTerminationRequest { XCTFail("Repeated quit must be swallowed") }
            FilePanelPresentation.requestTermination { XCTFail("Reentrant quit must be swallowed") }
            return false
        }
        for _ in 0..<3 {
            FilePanelPresentation.scheduleTerminationRequest { XCTFail("Cancelled quit must not terminate") }
        }
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(prompts, 0, "The event must finish before confirmation runs")
        scheduled.removeFirst()()
        XCTAssertTrue(scheduled.isEmpty, "No request may remain queued after cancelling the confirmation")
        XCTAssertEqual(prompts, 1)
        FilePanelPresentation.scheduleTerminationRequest { XCTFail("Cancelled quit must not terminate") }
        XCTAssertEqual(scheduled.count, 1, "A fresh quit after cancellation must still work")
        scheduled.removeFirst()()
        XCTAssertEqual(prompts, 2)
    }

    func testRecordingQuitCancelRestoresPreviousForegroundApplicationOffscreen() {
        for approved in [false, true] {
            let delegate = AppLifecycleDelegate()
            var actions: [String] = []
            delegate.recordingStateForTesting = { (.recording, false) }
            delegate.recordingConfirmationEnvironmentForTesting = .init(
                capturePreviousApplication: { actions.append("capture"); return { actions.append("restore") } },
                activateApplication: { actions.append("activate") })
            delegate.confirmRecordingQuitForTesting = { actions.append("confirm"); return approved }
            XCTAssertEqual(delegate.authorizeRecordingTermination(), approved)
            XCTAssertEqual(actions, approved ? ["capture", "activate", "confirm"] : ["capture", "activate", "confirm", "restore"])
        }
    }

    func testRecordingQuitCancelWithoutPreviousApplicationDoesNotRestoreOffscreen() {
        let delegate = AppLifecycleDelegate()
        var activations = 0
        delegate.recordingStateForTesting = { (.paused, false) }
        delegate.recordingConfirmationEnvironmentForTesting = .init(
            capturePreviousApplication: { nil }, activateApplication: { activations += 1 })
        delegate.confirmRecordingQuitForTesting = { false }
        XCTAssertFalse(delegate.authorizeRecordingTermination())
        XCTAssertEqual(activations, 1)
    }

    func testRecordingQuitSystemRequestDoesNotRestorePreviousApplicationOffscreen() async {
        let delegate = AppLifecycleDelegate()
        var restores = 0, replies: [Bool] = []
        delegate.recordingStateForTesting = { (.recording, false) }
        delegate.recordingConfirmationEnvironmentForTesting = .init(
            capturePreviousApplication: { { restores += 1 } }, activateApplication: {})
        delegate.abortRecordingConfirmationForTesting = {}
        delegate.confirmRecordingQuitForTesting = {
            delegate.terminationEventForTesting = self.quitEvent(reason: OSType(kAEShutDown))
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            return false
        }
        delegate.cleanupForTesting = { true }
        delegate.replyForTesting = { replies.append($0) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        let until = ContinuousClock.now.advanced(by: .seconds(2))
        while replies.isEmpty, ContinuousClock.now < until { await Task.yield() }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(restores, 0, "System termination must not reactivate the previous application")
    }

    private func makeModel() throws -> (AppModel, URL, AppModel.PrivacyExitConfiguration) {
        let evidence = TestFixtureDirectory.root.resolvingSymlinksInPath()
            .appendingPathComponent("privacy-followup/lifecycle")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let directory = evidence.appendingPathComponent("synthetic-exit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        addTeardownBlock { try cleanup.remove(defaults) }
        let queue = LearningReviewQueue(journalURL: directory.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled, generate: { _, _, _, _, _ in
                XCTFail("Synthetic exit tests must never start a model")
                throw Failure.synthetic
            })
        addTeardownBlock {
            let retired = evidence.appendingPathComponent("superseded", isDirectory: true)
            try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.moveItem(at: directory, to: retired.appendingPathComponent(directory.lastPathComponent))
            }
        }
        // XCTest runs these blocks in reverse order: settle the synthetic queue,
        // preserve its fixture, then remove this test's isolated preferences.
        addTeardownBlock { await queue.shutdownForTesting() }
        let model = AppModel(reviewQueue: queue, backgroundServices: false, scheduledNotes: false, defaults: defaults)
        var configuration = AppModel.PrivacyExitConfiguration()
        configuration.timeout = 0.05
        configuration.stopCapture = { _ in }
        configuration.pauseTranscription = {}
        configuration.pauseReview = {}
        configuration.retryTemporarySessions = {}
        configuration.discardTemporarySession = { _ in }
        model.configurePrivacyExitForTesting(configuration)
        model.beginLiveOnlyCourseForTesting(directory: directory)
        model.loadPresentationForTesting(phase: .recording, evidence: [
            .init(startTime: 0, endTime: 1, english: "SYNTHETIC_PRIVATE_CONTENT", chinese: "合成课堂内容")
        ], preview: "SYNTHETIC_PREVIEW")
        return (model, directory, configuration)
    }

    func testExitDeadlineCoversAllWaits() async throws {
        let stages = ["manual", "refresh", "import", "translation", "summary", "processing", "start",
                      "readiness", "power", "finalization", "capture", "transcription", "review", "park", "flush", "services"]
        for stage in stages {
            let (model, directory, initial) = try makeModel()
            var configuration = initial
            let gate = PrivacyExitGate()
            var deleted = false
            configuration.discardTemporarySession = { _ in deleted = true }
            switch stage {
            case "finalization": model.setPrivacyExitFinalizationForTesting(true)
            case "capture": configuration.stopCapture = { _ in await gate.wait() }
            case "transcription": configuration.pauseTranscription = { await gate.wait() }
            case "review": configuration.pauseReview = { await gate.wait() }
            case "park": configuration.park = { await gate.wait() }
            case "flush":
                configuration.flush = { await gate.wait() }
                configuration.park = { try await model.flushSavedCourseForTesting() }
            case "services": break
            default: model.setPrivacyExitTaskForTesting(Task { await gate.wait() }, stage: stage)
            }
            model.configurePrivacyExitForTesting(configuration)
            var reply: Bool?
            let exit = Task {
                reply = await model.prepareForApplicationExit(retireServices: {
                    if stage == "services" { await gate.wait() }
                })
            }
            try await Task.sleep(for: .milliseconds(150))
            let timedReply = reply
            let preservedBeforeRelease = !model.segments.isEmpty && model.temporarySessionForPrivacyExitTesting == directory
            model.setPrivacyExitFinalizationForTesting(false)
            gate.release()
            await exit.value
            XCTAssertEqual(timedReply, false, "Unbounded exit stage: \(stage)")
            XCTAssertTrue(preservedBeforeRelease, stage)
            XCTAssertFalse(deleted, "Late cleanup after timeout: \(stage)")
            XCTAssertFalse(model.segments.isEmpty, stage)
            XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, directory, stage)
        }
    }

    func testSlowSuccessfulNormalStopHasNoExitBudget() async throws {
        let (model, directory, initial) = try makeModel()
        try await model.beginSavedCourseForTesting(directory: directory)
        var configuration = initial
        let state = PrivacyExitRetryState()
        configuration.flush = {
            state.calls += 1
            if state.calls == 1 { try await Task.sleep(for: .milliseconds(15_100)) }
        }
        model.configurePrivacyExitForTesting(configuration)
        await model.stopSavedCourseForTesting()
        XCTAssertEqual(model.phase, .saved(directory))
        XCTAssertNil(model.archiveError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript-en.txt").path))
    }

    func testSlowSaveWithProgressCanFinishWithinOneExitAttempt() async throws {
        let (model, directory, initial) = try makeModel()
        try await model.beginSavedCourseForTesting(directory: directory)
        var configuration = initial
        configuration.flush = {
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(20))
                try SensitiveFileIO.atomicWrite(Data("synthetic save progress".utf8),
                    to: directory.appendingPathComponent("progress.txt"))
            }
        }
        model.configurePrivacyExitForTesting(configuration)
        let allowed = await model.prepareForApplicationExit()
        XCTAssertTrue(allowed)
        XCTAssertEqual(model.phase, .saved(directory))
        XCTAssertNil(model.archiveError)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("progress.txt"), encoding: .utf8),
                       "synthetic save progress")
    }

    func testUnchangedSaveConfirmationDoesNotRenewExitDeadline() async throws {
        let (model, directory, initial) = try makeModel()
        try await model.beginSavedCourseForTesting(directory: directory)
        var configuration = initial
        let gate = PrivacyExitGate()
        configuration.stopCapture = { _ in await gate.wait() }
        model.configurePrivacyExitForTesting(configuration)
        let deadline = ExitDeadline(inactivityTimeout: 10)
        let exit = Task { await model.prepareForApplicationExit(deadline: deadline) }
        defer { gate.release() }
        let enteredBy = ContinuousClock.now.advanced(by: .seconds(2))
        while !gate.entered, ContinuousClock.now < enteredBy { await Task.yield() }
        XCTAssertTrue(gate.entered)

        // Persist the exit's paused state first. The following submission must
        // reach the real saver callback without another durable write.
        try await model.flushSavedCourseForTesting()
        let snapshotURL = directory.appendingPathComponent(SessionStore.snapshotFileName)
        let journalURL = directory.appendingPathComponent(SessionStore.journalFileName)
        let snapshot = try Data(contentsOf: snapshotURL)
        let journal = try Data(contentsOf: journalURL)
        let remaining = deadline.remaining
        try await Task.sleep(for: .milliseconds(50))
        try await SensitiveFileIO.$operationObserver.withValue({ operation in
            if operation == .directorySync { XCTFail("An unchanged save must not sync storage") }
        }) {
            try await model.flushSavedCourseForTesting()
        }
        XCTAssertLessThanOrEqual(deadline.remaining, remaining,
                                 "Acknowledging unchanged content must not renew the exit lease")
        XCTAssertEqual(try Data(contentsOf: snapshotURL), snapshot)
        XCTAssertEqual(try Data(contentsOf: journalURL), journal)

        // A genuine course update still renews the shared storage binding.
        model.loadPresentationForTesting(phase: .recording, evidence: [
            .init(startTime: 0, endTime: 1, english: "Synthetic exit storage progress.")
        ])
        let beforeWrite = deadline.remaining
        try await model.flushSavedCourseForTesting()
        XCTAssertGreaterThan(deadline.remaining, beforeWrite)
        XCTAssertNotEqual(try Data(contentsOf: snapshotURL), snapshot)
        gate.release()
        let allowed = await exit.value
        XCTAssertTrue(allowed)
    }

    func testPreexistingDetachedWriterRenewsOnlyWithActualStorageProgress() async throws {
        let (_, directory, _) = try makeModel()
        let binding = ExitDeadline.StorageProgress(), gate = PrivacyExitGate()
        let writer = Task.detached {
            await gate.wait()
            try ExitDeadline.$storageProgress.withValue(binding) {
                for index in 0..<6 {
                    Thread.sleep(forTimeInterval: 0.02)
                    try SensitiveFileIO.atomicWrite(Data("synthetic chunk \(index)".utf8),
                        to: directory.appendingPathComponent("background.txt"))
                }
            }
        }
        while !gate.entered { await Task.yield() }
        let deadline = ExitDeadline(inactivityTimeout: 0.05)
        binding.attach(deadline)
        gate.release()
        try await deadline.wait { try await writer.value }
        XCTAssertFalse(deadline.isExpired)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("background.txt"), encoding: .utf8),
                       "synthetic chunk 5")
    }

    func testCompletedSynchronousDiskCleanupDoesNotLeaveStaleRoot() async throws {
        let (model, directory, initial) = try makeModel()
        // Keep the queue journal outside the discarded course, as it is in
        // production. A queue shutdown must not recreate that course fixture.
        let course = directory.appendingPathComponent("temporary-course", isDirectory: true)
        try FileManager.default.createDirectory(at: course, withIntermediateDirectories: false)
        model.beginLiveOnlyCourseForTesting(directory: course)
        var configuration = initial
        configuration.discardTemporarySession = { root in
            try FileManager.default.removeItem(at: root)
            Thread.sleep(forTimeInterval: 0.08)
        }
        model.configurePrivacyExitForTesting(configuration)
        let first = await model.prepareForApplicationExit()
        XCTAssertFalse(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: course.path))
        XCTAssertNil(model.temporarySessionForPrivacyExitTesting)
        try await Task.sleep(for: .milliseconds(20))
        let second = await model.prepareForApplicationExit()
        XCTAssertTrue(second)
    }

    func testAppKitAllowsExplicitExitAfterHungCleanup() async throws {
        let delegate = AppLifecycleDelegate(), gate = PrivacyExitGate()
        delegate.terminationTimeoutForTesting = 0.05
        delegate.cleanupForTesting = { await gate.wait(); return true }
        delegate.confirmExitWithoutSavingForTesting = { true }
        var replies: [Bool] = []
        delegate.replyForTesting = { replies.append($0) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(replies, [true])
        gate.release()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(replies, [true])
    }

    func testLateCompletionCannotClearAfterTimeout() async throws {
        let (model, directory, initial) = try makeModel()
        var configuration = initial
        let gate = PrivacyExitGate()
        configuration.stopCapture = { _ in await gate.wait() }
        var deleted = false
        configuration.discardTemporarySession = { _ in deleted = true }
        model.configurePrivacyExitForTesting(configuration)
        let stop = Task { await model.stopSavedCourseForTesting() }
        let until = ContinuousClock.now.advanced(by: .seconds(1))
        while !gate.entered, ContinuousClock.now < until { await Task.yield() }
        XCTAssertTrue(gate.entered)
        let reply = await model.prepareForApplicationExit()
        XCTAssertFalse(reply)
        XCTAssertFalse(model.resetSessionForPrivacyExitTesting(), "A live old writer must block a new run")
        gate.release()
        await stop.value
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(deleted)
        XCTAssertFalse(model.segments.isEmpty)
        XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, directory)
    }

    func testStopCleanupFailurePreservesContentAndCanRetry() async throws {
        let (model, directory, initial) = try makeModel()
        var configuration = initial
        var calls = 0
        configuration.discardTemporarySession = { _ in
            calls += 1
            if calls == 1 { throw Failure.synthetic }
        }
        model.configurePrivacyExitForTesting(configuration)
        await model.stopSavedCourseForTesting()
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(model.segments.isEmpty)
        XCTAssertEqual(model.volatileEnglish, "SYNTHETIC_PREVIEW")
        XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, directory)
        XCTAssertTrue(model.isLiveOnly)
        await model.stopSavedCourseForTesting()
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(model.segments.isEmpty)
        XCTAssertNil(model.temporarySessionForPrivacyExitTesting)
    }

    func testSynchronousCleanupRechecksDeadlineBeforeClearing() async throws {
        let (model, _, initial) = try makeModel()
        var configuration = initial
        configuration.discardTemporarySession = { _ in Thread.sleep(forTimeInterval: 0.08) }
        model.configurePrivacyExitForTesting(configuration)
        let allowed = await model.prepareForApplicationExit()
        XCTAssertFalse(allowed)
        XCTAssertFalse(model.segments.isEmpty)
        XCTAssertEqual(model.volatileEnglish, "SYNTHETIC_PREVIEW")
        XCTAssertNotNil(model.archiveError)
    }

    func testNewRunRetriesJournalBeforeReset() throws {
        let (model, directory, initial) = try makeModel()
        var configuration = initial
        let state = PrivacyExitRetryState()
        configuration.retryTemporarySessions = {
            state.calls += 1
            if state.failed { throw Failure.synthetic }
        }
        model.configurePrivacyExitForTesting(configuration)
        XCTAssertFalse(model.resetSessionForPrivacyExitTesting())
        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, directory)
        XCTAssertFalse(model.segments.isEmpty)
        XCTAssertEqual(model.volatileEnglish, "SYNTHETIC_PREVIEW")
        state.failed = false
        XCTAssertTrue(model.resetSessionForPrivacyExitTesting())
        XCTAssertEqual(state.calls, 2)
        XCTAssertNil(model.temporarySessionForPrivacyExitTesting)
        XCTAssertTrue(model.segments.isEmpty)
    }

    func testExitUsesSingleBudgetAcrossStages() async throws {
        let (model, directory, initial) = try makeModel()
        var configuration = initial
        configuration.timeout = 0.06
        configuration.stopCapture = { _ in try? await Task.sleep(for: .milliseconds(40)) }
        configuration.park = { try? await Task.sleep(for: .milliseconds(40)) }
        var deleted = false
        configuration.discardTemporarySession = { _ in deleted = true }
        model.configurePrivacyExitForTesting(configuration)
        let reply = await model.prepareForApplicationExit()
        XCTAssertFalse(reply)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertFalse(deleted)
        XCTAssertFalse(model.segments.isEmpty)
        XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, directory)
    }

    private func fullPipe() throws -> Pipe {
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        let bytes = [UInt8](repeating: 65, count: 4096)
        while true {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
            if count > 0 { continue }
            if count < 0, errno == EINTR { continue }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else { throw POSIXError(.EIO) }
            return pipe
        }
    }

    func testControlDeadlineStartsBeforeBlockedSend() async throws {
        let pipe = try fullPipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let runtime = MLXRuntime()
        let start = ContinuousClock.now
        do {
            try await runtime.controlForExitTesting(to: pipe.fileHandleForWriting, timeout: 0.05)
            XCTFail("A full pipe cannot deliver shutdown")
        } catch {}
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }

    func testPipeSendSharesAbsoluteExitDeadline() async throws {
        let pipe = try fullPipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let runtime = MLXRuntime(), deadline = ExitDeadline(seconds: 0.06)
        try await Task.sleep(for: .milliseconds(40))
        let start = ContinuousClock.now
        await ExitDeadline.$current.withValue(deadline) {
            do {
                try await runtime.controlForExitTesting(to: pipe.fileHandleForWriting, timeout: 0.4)
                XCTFail("The inherited exit budget must expire first")
            } catch {}
        }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(180))
    }

    func testAppKitRejectsTimedOutExit() async throws {
        let delegate = AppLifecycleDelegate(), gate = PrivacyExitGate()
        delegate.terminationTimeoutForTesting = 0.05
        var reply: Bool?
        delegate.cleanupForTesting = { await gate.wait(); return true }
        delegate.replyForTesting = { reply = $0 }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        try await Task.sleep(for: .milliseconds(150))
        let timedReply = reply
        gate.release()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(timedReply, false)
        XCTAssertEqual(reply, false, "A late completion cannot authorize termination")
    }
}
