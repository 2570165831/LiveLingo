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
private final class PrivacyExitClock {
    var now: TimeInterval = 100
}

@MainActor
final class PrivacyExitTests: XCTestCase {
    private enum Failure: Error { case synthetic }

    func testIssue50ManualLiveOnlyStopDefaultsToContinueWithoutLosingContent() throws {
        let (model, root, _) = try makeModel()
        for phase: AppPhase in [.recording, .paused] {
            model.loadPresentationForTesting(phase: phase, evidence: model.segments,
                                            preview: "synthetic preview", storageMode: .liveOnly)
            let segments = model.segments, notes = model.lectureSummary
            model.toggleRecording()
            XCTAssertEqual(model.phase, phase, "An unconfirmed manual stop must keep capture unchanged")
            XCTAssertEqual(model.segments, segments)
            XCTAssertEqual(model.lectureSummary, notes)
            XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, root)
        }
    }

    func testIssue50ManualStopAlertKeepsContinueAsDefaultOffscreen() {
        for phase: AppPhase in [.recording, .paused] {
            let alert = RecordingQuitConfirmation.makeLiveStopAlert(phase: phase)
            XCTAssertEqual(alert.buttons.map(\.title), ["继续", "转为录音", "结束并清空"])
            XCTAssertTrue(alert.informativeText.contains("录音、字幕和笔记"))
            XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
            XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
            XCTAssertEqual(alert.buttons[2].keyEquivalent, "")
            alert.layout()
            XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[0].cell)
            XCTAssertFalse(alert.window.isVisible)
        }
    }

    func testIssue50CancelledFolderChoiceKeepsRecordingAndPausedContent() async throws {
        for paused in [false, true] {
            let (model, staging, _, _) = try await makeLiveQuitModel(paused: paused, savedFolder: false)
            let phase = model.phase, evidence = model.segments
            var selections = 0
            model.confirmLiveStopForTesting = { .saveAndQuit }
            model.chooseOutputDirectoryForTesting = { selections += 1; return nil }
            model.toggleRecording()
            await waitForQuitReply { selections == 1 && !model.manualStopPendingForTesting }
            XCTAssertEqual(model.phase, phase)
            XCTAssertEqual(model.segments, evidence)
            XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, staging)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        }
    }

    func testIssue50ConversionFailureNeverContinuesToStopOrDiscard() async throws {
        let (model, staging, output, initial) = try await makeLiveQuitModel()
        var config = initial, discards = 0
        config.flush = { throw Failure.synthetic }
        config.discardTemporarySession = { _ in discards += 1 }
        model.configurePrivacyExitForTesting(config)
        let phase = model.phase, evidence = model.segments
        model.confirmLiveStopForTesting = { .saveAndQuit }
        model.chooseOutputDirectoryForTesting = { output }
        model.stop()
        await waitForQuitReply { !model.manualStopPendingForTesting }
        XCTAssertNotNil(model.archiveError)
        XCTAssertEqual(model.phase, phase)
        XCTAssertEqual(model.segments, evidence)
        XCTAssertEqual(discards, 0)
        XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, staging)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    func testIssue50SuccessfulConversionStopsAndPreservesExactCaptionText() async throws {
        for paused in [false, true] {
            let (model, _, output, initial) = try await makeLiveQuitModel(paused: paused)
            var configuration = initial
            configuration.pauseTranscription = nil
            model.configurePrivacyExitForTesting(configuration)
            let english = model.segments.map(\.english), chinese = model.segments.map(\.chinese)
            var selections = 0, prompts = 0
            model.confirmLiveStopForTesting = { prompts += 1; return .saveAndQuit }
            model.chooseOutputDirectoryForTesting = { selections += 1; return output }
            model.toggleRecording()
            model.stop()
            await waitForQuitReply {
                if case .saved = model.phase { return true }
                if case .failed = model.phase { return true }
                return !model.manualStopPendingForTesting && model.archiveError != nil
            }
            XCTAssertEqual(prompts, 1, "Repeated stop commands must not open another confirmation")
            XCTAssertEqual(selections, 1)
            guard case .saved(let directory) = model.phase else {
                return XCTFail("Manual conversion did not stop: \(model.phase); \(model.archiveError ?? "no archive error")")
            }
            let saved = try XCTUnwrap(SessionStore(directory: directory).load())
            XCTAssertEqual(saved.segments.map(\.english), english)
            XCTAssertEqual(saved.segments.map(\.chinese), chinese)
            XCTAssertNil(model.temporarySessionForPrivacyExitTesting)
        }
    }

    func testIssue50OnlyConfirmedDiscardClearsLiveContent() async throws {
        for paused in [false, true] {
            let (model, staging, _, initial) = try await makeLiveQuitModel(paused: paused)
            var config = initial, discarded: [URL] = []
            config.discardTemporarySession = { discarded.append($0) }
            model.configurePrivacyExitForTesting(config)
            model.confirmLiveStopForTesting = { .continueSession }
            model.stop()
            XCTAssertEqual(model.phase, paused ? .paused : .recording)
            XCTAssertFalse(model.segments.isEmpty)
            XCTAssertTrue(discarded.isEmpty)
            model.confirmLiveStopForTesting = { .quitWithoutSaving }
            model.chooseOutputDirectoryForTesting = { XCTFail("Discard must not choose a folder"); return nil }
            model.toggleRecording()
            await waitForQuitReply { model.phase == .liveEnded }
            XCTAssertEqual(discarded, [staging])
            XCTAssertTrue(model.segments.isEmpty)
        }
    }

    func testIssue50AutomaticCaptureFailureDoesNotAskForManualStopConfirmation() async throws {
        let (model, _, _) = try makeModel()
        model.confirmLiveStopForTesting = { XCTFail("Automatic capture failures must not prompt"); return .continueSession }
        model.receiveTranscriptionNoticeForTesting(.failure("Synthetic capture interruption"))
        await waitForQuitReply { model.phase == .failed("Synthetic capture interruption") }
    }

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

    func testUnitTestPresentationSafetyRequiresExactNativeFocusOptInByInjection() {
        XCTAssertFalse(UnitTestPresentationSafety.nativeFocusTestsEnabled(environment: [:]))
        for value in ["", "0", "true", "yes", " 1", "1 "] {
            XCTAssertFalse(UnitTestPresentationSafety.nativeFocusTestsEnabled(
                environment: ["LIVELINGO_NATIVE_FOCUS_TESTS": value]))
        }
        XCTAssertTrue(UnitTestPresentationSafety.nativeFocusTestsEnabled(
            environment: ["LIVELINGO_NATIVE_FOCUS_TESTS": "1"]))
    }

    func testUnitTestPresentationSafetyDisablesKeyMethodsByDefaultUsingMockMethodTable() {
        var methods = ["makeKeyAndOrderFront:": "original-order-and-key",
                       "makeKeyWindow": "original-key"]
        var exchanged: [String] = []
        UnitTestPresentationSafety.installKeyWindowGuards { name, replacement in
            exchanged.append(name)
            methods[name] = NSStringFromSelector(replacement)
        }
        XCTAssertEqual(exchanged, ["makeKeyAndOrderFront:", "makeKeyWindow"])
        XCTAssertEqual(methods["makeKeyAndOrderFront:"], "isolatedTestMakeKeyAndOrderFront:")
        XCTAssertEqual(methods["makeKeyWindow"], "isolatedTestMakeKeyWindow")
    }

    func testUnitTestPresentationSafetyPreservesAuthorizedKeyMethodsUsingMockMethodTable() {
        let originalMethods = ["makeKeyAndOrderFront:": "original-order-and-key",
                               "makeKeyWindow": "original-key"]
        var methods = originalMethods
        var exchanges = 0
        let enabled = UnitTestPresentationSafety.nativeFocusTestsEnabled(
            environment: ["LIVELINGO_NATIVE_FOCUS_TESTS": "1"])
        UnitTestPresentationSafety.installKeyWindowGuards(nativeFocusTestsEnabled: enabled) { name, replacement in
            exchanges += 1
            methods[name] = NSStringFromSelector(replacement)
        }
        XCTAssertEqual(exchanges, 0)
        XCTAssertEqual(methods, originalMethods)
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
            (.recording, false, true, "正在实时字幕（不保存）。退出前要保存这节课吗？", ["继续", "保存并退出", "退出不保存"]),
            (.paused, false, true, "实时字幕已暂停（不保存）。退出前要保存这节课吗？", ["继续", "保存并退出", "退出不保存"]),
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

    func testLiveQuitResponsesAndEscapeChooseContinueOffscreen() throws {
        XCTAssertEqual(RecordingQuitConfirmation.choice(for: .alertFirstButtonReturn, liveOnly: true), .continueSession)
        XCTAssertEqual(RecordingQuitConfirmation.choice(for: .alertSecondButtonReturn, liveOnly: true), .saveAndQuit)
        XCTAssertEqual(RecordingQuitConfirmation.choice(for: .alertThirdButtonReturn, liveOnly: true), .quitWithoutSaving)
        for response: NSApplication.ModalResponse in [.abort, .cancel] {
            XCTAssertEqual(RecordingQuitConfirmation.choice(for: response, liveOnly: true), .continueSession)
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        var response = NSApplication.ModalResponse.alertThirdButtonReturn
        XCTAssertTrue(RecordingQuitConfirmation.handleEscape(event) { response = .alertFirstButtonReturn })
        XCTAssertEqual(RecordingQuitConfirmation.choice(for: response, liveOnly: true), .continueSession)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertFalse(RecordingQuitConfirmation.handleEscape(enter) { XCTFail("Enter is handled by the default button") })
    }

    private func makeLiveQuitModel(paused: Bool = false, savedFolder: Bool = true,
                                  translation: CaptionTranslationDependencies? = nil,
                                  notes: LearningGenerationDependencies? = nil)
        async throws -> (AppModel, URL, URL, AppModel.PrivacyExitConfiguration) {
        let root = TestFixtureDirectory.root.appendingPathComponent("livequit-\(UUID())", isDirectory: true)
        let output = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let staging = try SessionWorkspace.makeTemporarySessionDirectory()
        let suite = "LiveLingo-Test-\(UUID())"
        let cleanup = try TestPreferenceCleanup(suite: suite)
        let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
        addTeardownBlock { try cleanup.remove(defaults) }
        let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Synthetic audio." }, enableAudioAnalysis: false)
        let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("queue.json"),
            observeSleep: false, diagnostics: .disabled, generate: { _, _, _, _, _ in throw Failure.synthetic })
        let model = AppModel(reviewQueue: queue, pipeline: pipeline, translation: translation, notes: notes,
            backgroundServices: false, scheduledNotes: notes != nil, defaults: defaults, recoveryDirectory: root)
        addTeardownBlock { @MainActor in
            let tasks = [model.translationTaskForTesting, model.summaryTaskForTesting, model.summaryWakeTaskForTesting].compactMap { $0 }
            for task in tasks { task.cancel() }
            for task in tasks { await task.value }
            await pipeline.stopCapture(continueTranscribing: false)
            await queue.shutdownForTesting()
            if FileManager.default.fileExists(atPath: staging.path) {
                try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent("retained-recording"))
            }
        }
        try await model.beginLiveCourseForTesting(directory: staging, outputRoot: output)
        if !savedFolder { model.outputDirectory = nil }
        model.loadPresentationForTesting(phase: paused ? .paused : .recording, evidence: [
            .init(startTime: 0, endTime: 1, english: "Synthetic final caption.", chinese: "合成尾段。",
                  sessionID: model.captureHealthSessionIDForTesting)
        ], preview: "synthetic preview")
        var config = AppModel.PrivacyExitConfiguration()
        config.timeout = ExitDeadline.applicationTimeout
        config.stopCapture = { await pipeline.stopCapture(continueTranscribing: $0) }
        config.pauseTranscription = {}
        config.pauseReview = {}
        config.retryTemporarySessions = {}
        // Preserve the synthetic audio while checking the requested discard.
        config.discardTemporarySession = { _ in }
        model.configurePrivacyExitForTesting(config)
        return (model, staging, output, config)
    }

    private func liveQuitDelegate(_ model: AppModel, choice: RecordingQuitConfirmation.Choice) -> AppLifecycleDelegate {
        let previous = AppLifecycleDelegate.model
        AppLifecycleDelegate.model = model
        addTeardownBlock { @MainActor in AppLifecycleDelegate.model = previous }
        let delegate = AppLifecycleDelegate()
        delegate.recordingStateForTesting = { (model.phase, model.isImportingFile) }
        delegate.recordingQuitChoiceForTesting = { choice }
        delegate.cleanupForTesting = { await model.prepareForApplicationExit(deadline: ExitDeadline.current) }
        delegate.terminationTimeoutForTesting = ExitDeadline.applicationTimeout
        delegate.confirmExitWithoutSavingForTesting = {
            XCTFail("Save and Quit must never offer an unsaved exit after a failure"); return true
        }
        delegate.liveSessionSaveFailureForTesting = { XCTFail("The synthetic save must succeed: \(model.archiveError ?? "no archive error")") }
        return delegate
    }

    private func waitForQuitReply(_ completed: () -> Bool) async {
        let until = ContinuousClock.now.advanced(by: .seconds(20))
        while !completed(), ContinuousClock.now < until { await Task.yield() }
        XCTAssertTrue(completed(), "The injected termination must finish within its deadline")
    }

    func testLiveQuitContinueLeavesRecordingAndPauseUnchanged() async throws {
        for paused in [false, true] {
            let (model, staging, _, _) = try await makeLiveQuitModel(paused: paused)
            let phase = model.phase, segments = model.segments, preview = model.volatileEnglish
            let delegate = liveQuitDelegate(model, choice: .continueSession)
            delegate.cleanupForTesting = { XCTFail("Continue must not prepare exit"); return true }
            delegate.replyForTesting = { _ in XCTFail("Continue must not reply asynchronously") }
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
            XCTAssertEqual(model.phase, phase)
            XCTAssertTrue(model.isLiveOnly)
            XCTAssertEqual(model.segments, segments)
            XCTAssertEqual(model.volatileEnglish, preview)
            XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, staging)
        }
    }

    func testLiveQuitSaveReusesFolderAndPersistsRecordingAndPausedCourseBeforeReply() async throws {
        for paused in [false, true] {
            let (model, staging, output, _) = try await makeLiveQuitModel(paused: paused)
            let segments = model.segments
            model.chooseOutputDirectoryForTesting = { XCTFail("A configured folder must be reused"); return nil }
            let delegate = liveQuitDelegate(model, choice: .saveAndQuit)
            var replies: [Bool] = [], prompts = 0
            delegate.recordingQuitChoiceForTesting = { prompts += 1; return .saveAndQuit }
            delegate.replyForTesting = { replies.append($0) }
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            await waitForQuitReply { !replies.isEmpty }
            XCTAssertEqual(replies, [true])
            XCTAssertEqual(prompts, 1)
            XCTAssertFalse(model.isLiveOnly)
            guard case .saved(let saved) = model.phase else { return XCTFail("The course must be saved before the reply") }
            XCTAssertEqual(saved.deletingLastPathComponent().standardizedFileURL, output.standardizedFileURL)
            XCTAssertEqual(try SessionStore(directory: saved).load()?.segments, segments)
            XCTAssertTrue(FileManager.default.fileExists(atPath: saved.appendingPathComponent(SessionWorkspace.recordingFileName).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        }
    }

    func testLiveQuitSaveChoosesOneFolderWhenUnconfigured() async throws {
        let (model, _, output, _) = try await makeLiveQuitModel(savedFolder: false)
        var selections = 0, replies: [Bool] = []
        model.chooseOutputDirectoryForTesting = { selections += 1; return output }
        let delegate = liveQuitDelegate(model, choice: .saveAndQuit)
        delegate.replyForTesting = { replies.append($0) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await waitForQuitReply { !replies.isEmpty }
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(model.outputDirectory, output)
        guard case .saved(let saved) = model.phase else { return XCTFail("The selected folder must receive the saved course") }
        XCTAssertNotNil(try SessionStore(directory: saved).load())
    }

    func testLiveQuitCancelledFolderSelectionPreservesLiveRecordingAndPause() async throws {
        for paused in [false, true] {
            let (model, staging, _, _) = try await makeLiveQuitModel(paused: paused, savedFolder: false)
            let phase = model.phase, segments = model.segments, preview = model.volatileEnglish
            var selections = 0, replies: [Bool] = []
            model.chooseOutputDirectoryForTesting = { selections += 1; return nil }
            let delegate = liveQuitDelegate(model, choice: .saveAndQuit)
            delegate.cleanupForTesting = { XCTFail("A cancelled folder choice must not end capture"); return true }
            delegate.replyForTesting = { replies.append($0) }
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            await waitForQuitReply { !replies.isEmpty }
            XCTAssertEqual(replies, [false])
            XCTAssertEqual(selections, 1)
            XCTAssertEqual(model.phase, phase)
            XCTAssertEqual(model.segments, segments)
            XCTAssertEqual(model.volatileEnglish, preview)
            XCTAssertTrue(model.isLiveOnly)
            XCTAssertNil(model.outputDirectory)
            XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, staging)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent(SessionWorkspace.recordingFileName).path))
        }
    }

    func testLiveQuitConversionFailureNotifiesAndRetainsAudioWithoutPreparingExit() async throws {
        let (model, staging, output, _) = try await makeLiveQuitModel()
        let index = output.deletingLastPathComponent().appendingPathComponent("pending-recordings.json")
        let original = Data(#"{"version":99,"recordings":[],"futureState":"SYNTHETIC_RETAIN"}"#.utf8)
        try original.write(to: index)
        let delegate = liveQuitDelegate(model, choice: .saveAndQuit)
        var failures = 0, replies: [Bool] = []
        delegate.liveSessionSaveFailureForTesting = { failures += 1 }
        delegate.cleanupForTesting = { XCTFail("Conversion failure must stop before exit cleanup"); return true }
        delegate.replyForTesting = { replies.append($0) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await waitForQuitReply { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
        XCTAssertEqual(failures, 1)
        XCTAssertNotNil(model.archiveError)
        XCTAssertEqual(try Data(contentsOf: index), original)
        XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, staging)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent(SessionWorkspace.recordingFileName).path))
    }

    func testLiveQuitFinalSaveFailureNotifiesAndDoesNotOfferForcedExit() async throws {
        let (model, staging, _, initial) = try await makeLiveQuitModel()
        var config = initial
        config.park = { throw Failure.synthetic }
        model.configurePrivacyExitForTesting(config)
        let delegate = liveQuitDelegate(model, choice: .saveAndQuit)
        var failures = 0, replies: [Bool] = []
        delegate.liveSessionSaveFailureForTesting = { failures += 1 }
        delegate.replyForTesting = { replies.append($0) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await waitForQuitReply { !replies.isEmpty }
        XCTAssertEqual(replies, [false])
        XCTAssertEqual(failures, 1)
        XCTAssertNotNil(model.archiveError)
        XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, staging)
        XCTAssertNotNil(try SessionStore(directory: staging).load())
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent(SessionWorkspace.recordingFileName).path))
    }

    func testLiveQuitConversionDeadlineCancelsQuitAndPreventsLateRecoveryWrites() async throws {
        let (model, staging, output, initial) = try await makeLiveQuitModel()
        let gate = PrivacyExitGate()
        var config = initial
        config.flush = { await gate.wait() }
        model.configurePrivacyExitForTesting(config)
        let delegate = liveQuitDelegate(model, choice: .saveAndQuit)
        var failures = 0, replies: [Bool] = []
        delegate.terminationTimeoutForTesting = 0.05
        delegate.liveSessionSaveFailureForTesting = { failures += 1 }
        delegate.cleanupForTesting = { XCTFail("Expired conversion must not prepare exit"); return true }
        delegate.replyForTesting = { replies.append($0) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await waitForQuitReply { !replies.isEmpty }
        XCTAssertTrue(gate.entered)
        XCTAssertEqual(replies, [false])
        XCTAssertEqual(failures, 1)
        let index = output.deletingLastPathComponent().appendingPathComponent("pending-recordings.json")
        let registered = try Data(contentsOf: index)
        let recovery = try XCTUnwrap(SessionWorkspace.recordingRecoveries(in: output.deletingLastPathComponent()).first)
        XCTAssertEqual(recovery.id, model.captureHealthSessionIDForTesting)
        XCTAssertEqual(recovery.directory, staging)
        XCTAssertEqual(recovery.outputRoot, output)
        XCTAssertEqual(try SessionStore(directory: staging).load()?.sessionID, recovery.id)
        let resume = model.conversionRecoveryTaskForTesting
        gate.release()
        await resume?.value
        XCTAssertEqual(try Data(contentsOf: index), registered, "The cancelled wait must not publish a late recovery update")
        XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, staging)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent(SessionWorkspace.recordingFileName).path))
    }

    func testTimedConversionRestoresTranslationAndNoteAdmissionAfterOldWaitDrains() async throws {
        var translations = 0, notes = 0, rejectedLateWrites = 0
        var dependencies = CaptionTranslationDependencies.unavailable
        dependencies.translate = { _, _, _, _, _ in
            XCTAssertNil(ExitDeadline.current, "New translation must not inherit the revoked exit lease")
            translations += 1
            return "小车以每秒两米的速度移动。"
        }
        let noteDependencies = LearningGenerationDependencies(generate: { _, _, _, _, _ in
            XCTAssertNil(ExitDeadline.current, "New notes must not inherit the revoked exit lease")
            notes += 1
            throw Failure.synthetic
        })
        let (model, staging, _, initial) = try await makeLiveQuitModel(translation: dependencies, notes: noteDependencies)
        model.loadPresentationForTesting(phase: .recording, evidence: [])
        let gate = PrivacyExitGate()
        var config = initial
        config.flush = {
            let old = try XCTUnwrap(ExitDeadline.current)
            await gate.wait()
            do { try old.check(); XCTFail("The old operation must stay revoked") }
            catch { rejectedLateWrites += 1; throw error }
        }
        model.configurePrivacyExitForTesting(config)
        let clock = PrivacyExitClock()
        model.configureNoteSchedulingForTesting(now: { clock.now }, sleep: { _ in throw CancellationError() })
        let lease = ExitDeadline(inactivityTimeout: 0.05)
        let conversion = await model.convertCurrentSessionToRecording(usingExistingOutputDirectory: true, deadline: lease)
        XCTAssertEqual(conversion, .failed)
        XCTAssertTrue(lease.hasPendingOperations)
        model.receiveCaptionForTesting("The cart moves at two metres per second.", start: 2, end: 8)
        model.scheduleSummaryForTesting(force: true)
        XCTAssertEqual(translations, 0)
        XCTAssertEqual(notes, 0)
        let resume = try XCTUnwrap(model.conversionRecoveryTaskForTesting)
        gate.release()
        await resume.value
        XCTAssertFalse(lease.hasPendingOperations)
        XCTAssertTrue(lease.isExpired)
        XCTAssertEqual(rejectedLateWrites, 1)
        let until = ContinuousClock.now.advanced(by: .seconds(5))
        while translations == 0, ContinuousClock.now < until { await Task.yield() }
        await model.translationTaskForTesting?.value
        clock.now += 100
        model.scheduleSummaryForTesting(force: true)
        while notes == 0, ContinuousClock.now < until { await Task.yield() }
        XCTAssertGreaterThan(translations, 0)
        XCTAssertGreaterThan(notes, 0)
        XCTAssertEqual(model.temporarySessionForPrivacyExitTesting, staging)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        model.configurePrivacyExitForTesting(initial)
    }

    func testTimedConversionIsDiscoverableAndOpenableByFreshModelWithAbsentOrEmptyIndex() async throws {
        for emptyIndex in [false, true] {
            let (model, staging, output, initial) = try await makeLiveQuitModel()
            let root = output.deletingLastPathComponent()
            if emptyIndex { try SessionWorkspace.saveRecordingRecoveries([], in: root) }
            let gate = PrivacyExitGate()
            var config = initial
            config.flush = { await gate.wait() }
            model.configurePrivacyExitForTesting(config)
            let result = await model.convertCurrentSessionToRecording(usingExistingOutputDirectory: true,
                deadline: ExitDeadline(inactivityTimeout: 0.05))
            XCTAssertEqual(result, .failed)
            let resume = model.conversionRecoveryTaskForTesting
            gate.release(); await resume?.value
            let suite = "LiveLingo-Test-\(UUID())"
            let cleanup = try TestPreferenceCleanup(suite: suite)
            let defaults = try XCTUnwrap(TestUserDefaults(suiteName: suite))
            addTeardownBlock { try cleanup.remove(defaults) }
            let queue = LearningReviewQueue(journalURL: root.appendingPathComponent("relaunched-queue.json"),
                observeSleep: false, diagnostics: .disabled, generate: { _, _, _, _, _ in throw Failure.synthetic })
            let pipeline = SpeechPipeline(transcriber: { _, _, _ in "Synthetic audio." }, enableAudioAnalysis: false)
            addTeardownBlock { await pipeline.stopCapture(continueTranscribing: false); await queue.shutdownForTesting() }
            let fresh = AppModel(reviewQueue: queue, pipeline: pipeline, backgroundServices: false,
                defaults: defaults, recoveryDirectory: root)
            let record = try XCTUnwrap(fresh.recoverableRecordings.first)
            XCTAssertEqual(record.id, model.captureHealthSessionIDForTesting)
            await fresh.recoverRecording(record)
            XCTAssertNil(fresh.archiveError)
            XCTAssertEqual(fresh.currentCourseDirectory?.standardizedFileURL, staging.standardizedFileURL)
            XCTAssertEqual(fresh.temporarySessionForPrivacyExitTesting?.standardizedFileURL, staging.standardizedFileURL)
            XCTAssertEqual(fresh.segments, model.segments)
            XCTAssertTrue(fresh.savedProcessingIsPaused)
        }
    }

    func testSaveFailureAlertCanBeAbortedBySystemTerminationOffscreen() {
        let alert = RecordingQuitConfirmation.makeSaveFailureAlert()
        alert.layout()
        XCTAssertFalse(alert.window.preventsApplicationTerminationWhenModal)
        XCTAssertFalse(alert.window.isVisible)
        XCTAssertEqual(alert.buttons.map(\.title), ["继续"])
    }

    func testSystemQuitAfterFailureModalOpensAbortsItAndRetriesExistingSaveOnce() async throws {
        for conversionFailure in [false, true] {
            for saveSucceeds in [false, true] {
                let (model, _, output, _) = try await makeLiveQuitModel()
                if conversionFailure {
                    try Data(#"{"version":99,"recordings":[]}"#.utf8).write(to:
                        output.deletingLastPathComponent().appendingPathComponent("pending-recordings.json"))
                }
                let delegate = liveQuitDelegate(model, choice: .saveAndQuit)
                var attempts = 0, modals = 0, aborts = 0, replies: [Bool] = []
                delegate.cleanupForTesting = { attempts += 1; return attempts > (conversionFailure ? 0 : 1) && saveSucceeds }
                delegate.abortLiveSessionSaveFailureForTesting = { aborts += 1 }
                delegate.liveSessionSaveFailureForTesting = {
                    modals += 1
                    delegate.terminationEventForTesting = self.quitEvent(reason: OSType(kAEReallyLogOut))
                    XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
                    XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
                    XCTAssertEqual(aborts, 1)
                }
                delegate.replyForTesting = { replies.append($0) }
                XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
                await waitForQuitReply { !replies.isEmpty }
                XCTAssertEqual(replies, [saveSucceeds])
                XCTAssertEqual(modals, 1)
                XCTAssertEqual(aborts, 1)
                XCTAssertEqual(attempts, conversionFailure ? 1 : 2)
            }
        }
    }

    func testCancelledFolderChoiceRestoresOriginalForegroundUnlessSystemQuitArrives() async throws {
        for systemQuit in [false, true] {
            let (model, _, _, _) = try await makeLiveQuitModel(savedFolder: false)
            let delegate = liveQuitDelegate(model, choice: .saveAndQuit)
            var actions: [String] = [], replies: [Bool] = []
            delegate.recordingConfirmationEnvironmentForTesting = .init(
                capturePreviousApplication: { actions.append("capture"); return { actions.append("restore") } },
                activateApplication: { actions.append("activate") })
            model.chooseOutputDirectoryForTesting = {
                actions.append("choose")
                if systemQuit {
                    delegate.terminationEventForTesting = self.quitEvent(reason: OSType(kAEShutDown))
                    XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
                }
                return nil
            }
            delegate.replyForTesting = { replies.append($0); actions.append("reply") }
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            await waitForQuitReply { !replies.isEmpty }
            XCTAssertEqual(replies, [systemQuit])
            XCTAssertEqual(actions, systemQuit ? ["capture", "activate", "choose", "reply"] : ["capture", "activate", "choose", "reply", "restore"])
        }
    }

    func testLiveQuitWithoutSavingUsesExistingDiscardForRecordingAndPause() async throws {
        for paused in [false, true] {
            let (model, staging, _, initial) = try await makeLiveQuitModel(paused: paused)
            var config = initial, discarded: [URL] = [], replies: [Bool] = []
            config.discardTemporarySession = { discarded.append($0) }
            model.configurePrivacyExitForTesting(config)
            model.chooseOutputDirectoryForTesting = { XCTFail("Discard must not choose a folder"); return nil }
            let delegate = liveQuitDelegate(model, choice: .quitWithoutSaving)
            delegate.replyForTesting = { replies.append($0) }
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            await waitForQuitReply { !replies.isEmpty }
            XCTAssertEqual(replies, [true])
            XCTAssertEqual(discarded, [staging])
            XCTAssertEqual(model.phase, .liveEnded)
            XCTAssertTrue(model.segments.isEmpty)
        }
    }

    func testLiveQuitSystemReasonsBypassSavingChoiceAndDiscardExistingLiveSession() async throws {
        for paused in [false, true] {
            for reason in [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut] {
                let (model, staging, _, initial) = try await makeLiveQuitModel(paused: paused, savedFolder: false)
                var config = initial, discarded: [URL] = [], replies: [Bool] = []
                config.discardTemporarySession = { discarded.append($0) }
                model.configurePrivacyExitForTesting(config)
                model.chooseOutputDirectoryForTesting = { XCTFail("System quit must not select a save folder"); return nil }
                let delegate = liveQuitDelegate(model, choice: .saveAndQuit)
                delegate.recordingQuitChoiceForTesting = { XCTFail("System quit must not show confirmation"); return .saveAndQuit }
                delegate.terminationEventForTesting = quitEvent(reason: reason)
                delegate.replyForTesting = { replies.append($0) }
                XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
                await waitForQuitReply { !replies.isEmpty }
                XCTAssertEqual(replies, [true])
                XCTAssertEqual(discarded, [staging])
                XCTAssertTrue(model.isLiveOnly)
                XCTAssertEqual(model.phase, .liveEnded)
            }
        }
    }

    func testLiveQuitMenuAuthorizationCarriesSaveChoiceIntoSynchronousTermination() async throws {
        let (model, _, _, _) = try await makeLiveQuitModel()
        let delegate = liveQuitDelegate(model, choice: .saveAndQuit)
        var prompts = 0, replies: [Bool] = []
        delegate.recordingQuitChoiceForTesting = { prompts += 1; return .saveAndQuit }
        delegate.replyForTesting = { replies.append($0) }
        XCTAssertTrue(delegate.authorizeRecordingTermination())
        delegate.withRecordingTerminationAuthorization {
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        }
        await waitForQuitReply { !replies.isEmpty }
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(replies, [true])
        XCTAssertFalse(model.isLiveOnly)
    }

    func testLiveQuitSystemSaveFailureCancelsSilentlyWithoutAnyConfirmation() async {
        for phase: AppPhase in [.recording, .paused] {
            for reason in [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut] {
                let delegate = AppLifecycleDelegate()
                var replies: [Bool] = []
                delegate.recordingStateForTesting = { (phase, false) }
                delegate.liveOnlyForTesting = true
                delegate.terminationEventForTesting = quitEvent(reason: reason)
                delegate.recordingQuitChoiceForTesting = { XCTFail("System quit must not ask to save"); return .saveAndQuit }
                delegate.cleanupForTesting = { false }
                delegate.confirmExitWithoutSavingForTesting = { XCTFail("System failure must not show a forced-exit confirmation"); return true }
                delegate.liveSessionSaveFailureForTesting = { XCTFail("System failure must not show a save-failure modal") }
                delegate.replyForTesting = { replies.append($0) }
                XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
                await waitForQuitReply { !replies.isEmpty }
                XCTAssertEqual(replies, [false])
            }
        }
    }

    func testLiveQuitSystemRequestDuringFolderChoiceJoinsExistingExitWithoutSaving() async throws {
        let (model, staging, _, initial) = try await makeLiveQuitModel(savedFolder: false)
        var config = initial, discarded: [URL] = [], replies: [Bool] = []
        config.discardTemporarySession = { discarded.append($0) }
        model.configurePrivacyExitForTesting(config)
        let delegate = liveQuitDelegate(model, choice: .saveAndQuit)
        delegate.terminationTimeoutForTesting = 0.05
        model.chooseOutputDirectoryForTesting = {
            try? await Task.sleep(for: .milliseconds(80))
            delegate.terminationEventForTesting = self.quitEvent(reason: OSType(kAEShutDown))
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
            return nil
        }
        delegate.replyForTesting = { replies.append($0) }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        await waitForQuitReply { !replies.isEmpty }
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(discarded, [staging])
        XCTAssertEqual(model.phase, .liveEnded)
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
