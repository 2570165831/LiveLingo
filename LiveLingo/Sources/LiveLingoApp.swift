import AppKit
import Combine
import CoreServices
import OSLog
import SwiftUI
#if DEBUG
import Darwin
import ObjectiveC

/// A failed test-host guard must stop the process without a crash report.
private enum UnitTestSafetyFailure {
    enum Reason: String {
        case temporaryDirectory = "Cannot create the isolated test worker directory"
        case filePanelGuard = "Cannot install the isolated test file-panel guard"
        case presentationGuard = "Cannot install the isolated test presentation guard"
        case activationPolicy = "Cannot keep the test host out of foreground activation"
    }

    nonisolated static func stop(_ reason: Reason) -> Never {
        let message = "LiveLingo isolated test host stopped: \(reason.rawValue)\n"
        message.utf8CString.withUnsafeBytes {
            _ = Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count - 1)
        }
        Darwin.exit(EXIT_FAILURE)
    }
}

/// Darwin Foundation can choose its own per-user temporary directory despite
/// TMPDIR. The isolated test host redirects the getter before any fixtures run.
private enum UnitTestTemporaryDirectory {
    static let directory: URL? = {
        guard AppRuntimeEnvironment.isUnitTesting else { return nil }
        var base: URL?
        // Xcode may copy a parallel host away from Build/Products. The scheme
        // provides its invocation's scratch base; never derive it from HOME.
        if let path = ProcessInfo.processInfo.environment["LIVELINGO_TEST_TMPDIR"], path.hasPrefix("/") {
            base = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        } else {
            var directory = Bundle.main.bundleURL
            while directory.path != "/" {
                let parent = directory.deletingLastPathComponent()
                if directory.lastPathComponent == "Products", parent.lastPathComponent == "Build" {
                    base = parent.deletingLastPathComponent().appendingPathComponent("tmp", isDirectory: true)
                    break
                }
                directory = parent
            }
        }
        guard let base, base.path != "/" else { return nil }
        let directory = base.appendingPathComponent(
            "worker-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { UnitTestSafetyFailure.stop(.temporaryDirectory) }
        return directory
    }()
    private static let install: Void = {
        guard AppRuntimeEnvironment.isUnitTesting, directory != nil,
              let original = class_getInstanceMethod(FileManager.self, NSSelectorFromString("temporaryDirectory")),
              let replacement = class_getInstanceMethod(FileManager.self, #selector(getter: FileManager.isolatedTestTemporaryDirectory)) else { return }
        method_exchangeImplementations(original, replacement)
    }()
    @MainActor static func configure() {
        _ = install
        _ = UnitTestFilePanelSafety.isInstalled
        _ = UnitTestPresentationSafety.isInstalled
    }
}

extension AppRuntimeEnvironment {
    static var unitTestTemporaryDirectory: URL? { UnitTestTemporaryDirectory.directory }
}

private extension FileManager {
    @objc dynamic var isolatedTestTemporaryDirectory: URL {
        UnitTestTemporaryDirectory.directory!
    }
}

/// File choosers can be presented by a separate system process, so making an
/// app-owned window transparent cannot contain them. The XCTest host replaces
/// every open/save presentation entry point with cancellation before fixtures
/// run. No original AppKit implementation is called by these replacements.
@MainActor
enum UnitTestFilePanelSafety {
    static let isInstalled: Bool = {
        guard AppRuntimeEnvironment.isUnitTesting else { return false }
        for type: AnyClass in [NSSavePanel.self, NSOpenPanel.self] {
            replace(type, "beginWithCompletionHandler:", #selector(NSSavePanel.isolatedTestFilePanelBegin(completionHandler:)))
            replace(type, "beginSheetModalForWindow:completionHandler:", #selector(NSSavePanel.isolatedTestFilePanelBeginSheet(for:completionHandler:)))
            replace(type, "runModal", #selector(NSSavePanel.isolatedTestFilePanelRunModal))
        }
        return true
    }()

    private static func replace(_ type: AnyClass, _ name: String, _ replacement: Selector) {
        guard let original = class_getInstanceMethod(type, NSSelectorFromString(name)),
              let replacement = class_getInstanceMethod(NSSavePanel.self, replacement) else {
            UnitTestSafetyFailure.stop(.filePanelGuard)
        }
        // Install on each concrete class, including inherited methods. Exchanging
        // an inherited method twice could restore the unsafe superclass method.
        class_replaceMethod(type, NSSelectorFromString(name), method_getImplementation(replacement),
                            method_getTypeEncoding(original))
    }

    static func cancelPresentation(_ completion: (NSApplication.ModalResponse) -> Void) {
        completion(.cancel)
    }
}

private extension NSSavePanel {
    @objc(isolatedTestFilePanelBeginWithCompletionHandler:)
    dynamic func isolatedTestFilePanelBegin(completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
        UnitTestFilePanelSafety.cancelPresentation(handler)
    }

    @objc(isolatedTestFilePanelBeginSheetForWindow:completionHandler:)
    dynamic func isolatedTestFilePanelBeginSheet(for window: NSWindow,
                                                completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
        UnitTestFilePanelSafety.cancelPresentation(handler)
    }

    @objc dynamic func isolatedTestFilePanelRunModal() -> NSApplication.ModalResponse { .cancel }
}

/// Only the isolated XCTest host changes AppKit dispatch. Windows remain
/// transparent and cannot activate an app. Key methods are suppressed unless
/// native-focus tests are explicitly enabled; those tests still require an
/// already-foreground host. Default keyboard routing uses injected test owners.
/// Synchronous modals abort.
@MainActor
enum UnitTestPresentationSafety {
    static let isInstalled: Bool = {
        guard AppRuntimeEnvironment.isUnitTesting else { return false }
        exchange(NSWindow.self, NSStringFromSelector(#selector(NSWindow.order(_:relativeTo:))), #selector(NSWindow.isolatedTestOrder(_:relativeTo:)))
        exchange(NSWindow.self, "orderFront:", #selector(NSWindow.isolatedTestOrderFront(_:)))
        exchange(NSWindow.self, "orderFrontRegardless", #selector(NSWindow.isolatedTestOrderFrontRegardless))
        installKeyWindowGuards(nativeFocusTestsEnabled: nativeFocusTestsEnabled(
            environment: ProcessInfo.processInfo.environment)) { name, replacement in
            exchange(NSWindow.self, name, replacement)
        }
        exchange(NSWindow.self, "setAlphaValue:", #selector(NSWindow.isolatedTestSetAlphaValue(_:)))
        exchange(NSApplication.self, "activateIgnoringOtherApps:", #selector(NSApplication.isolatedTestActivate(ignoringOtherApps:)))
        exchange(NSApplication.self, "activate", #selector(NSApplication.isolatedTestActivateWithoutOptions), required: false)
        exchange(NSRunningApplication.self, "activateWithOptions:", #selector(NSRunningApplication.isolatedTestActivate(options:)))
        exchange(NSApplication.self, "runModalForWindow:", #selector(NSApplication.isolatedTestRunModal(for:)))
        exchange(NSAlert.self, "runModal", #selector(NSAlert.isolatedTestRunModal))
        let application = NSApplication.shared
        for window in application.windows { window.alphaValue = 0 }
        let policy = application.activationPolicy()
        if policy != .accessory && policy != .prohibited {
            _ = application.setActivationPolicy(.accessory)
        }
        guard application.activationPolicy() != .regular else {
            UnitTestSafetyFailure.stop(.activationPolicy)
        }
        return true
    }()

    private static func exchange(_ type: AnyClass, _ name: String, _ replacement: Selector, required: Bool = true) {
        guard let original = class_getInstanceMethod(type, NSSelectorFromString(name)),
              let replacement = class_getInstanceMethod(type, replacement) else {
            if required { UnitTestSafetyFailure.stop(.presentationGuard) }
            return
        }
        method_exchangeImplementations(original, replacement)
    }

    nonisolated static func nativeFocusTestsEnabled(environment: [String: String]) -> Bool {
        environment["LIVELINGO_NATIVE_FOCUS_TESTS"] == "1"
    }

    /// Inject dispatch changes so policy tests never call real key methods.
    static func installKeyWindowGuards(nativeFocusTestsEnabled: Bool = false,
                                       exchange: (String, Selector) -> Void) {
        guard !nativeFocusTestsEnabled else { return }
        exchange("makeKeyAndOrderFront:", #selector(NSWindow.isolatedTestMakeKeyAndOrderFront(_:)))
        exchange("makeKeyWindow", #selector(NSWindow.isolatedTestMakeKeyWindow))
    }

    nonisolated static func alphaValue(requested: CGFloat, isUnitTesting: Bool) -> CGFloat {
        isUnitTesting ? 0 : requested
    }

    nonisolated static func performActivation(isUnitTesting: Bool, _ activate: () -> Bool) -> Bool {
        isUnitTesting ? false : activate()
    }

    nonisolated static func performModal(isUnitTesting: Bool, _ run: () -> NSApplication.ModalResponse) -> NSApplication.ModalResponse {
        isUnitTesting ? .abort : run()
    }
}

private extension NSWindow {
    @objc dynamic func isolatedTestOrder(_ place: NSWindow.OrderingMode, relativeTo otherWindowNumber: Int) {
        alphaValue = 0
        isolatedTestOrder(place, relativeTo: otherWindowNumber)
    }

    @objc dynamic func isolatedTestOrderFront(_ sender: Any?) {
        alphaValue = 0
        isolatedTestOrderFront(sender)
    }

    @objc dynamic func isolatedTestOrderFrontRegardless() {
        alphaValue = 0
        isolatedTestOrderFrontRegardless()
    }

    @objc dynamic func isolatedTestMakeKeyAndOrderFront(_ sender: Any?) {
        alphaValue = 0
        // In particular a nonactivating panel must not borrow the keyboard
        // from whichever application the user is working in.
        orderFront(sender)
    }

    @objc dynamic func isolatedTestMakeKeyWindow() {}

    @objc dynamic func isolatedTestSetAlphaValue(_ value: CGFloat) {
        isolatedTestSetAlphaValue(UnitTestPresentationSafety.alphaValue(requested: value,
            isUnitTesting: AppRuntimeEnvironment.isUnitTesting))
    }
}

private extension NSApplication {
    @objc dynamic func isolatedTestActivate(ignoringOtherApps flag: Bool) {
        _ = UnitTestPresentationSafety.performActivation(isUnitTesting: AppRuntimeEnvironment.isUnitTesting) {
            isolatedTestActivate(ignoringOtherApps: flag)
            return true
        }
    }

    @objc dynamic func isolatedTestActivateWithoutOptions() {
        _ = UnitTestPresentationSafety.performActivation(isUnitTesting: AppRuntimeEnvironment.isUnitTesting) {
            isolatedTestActivateWithoutOptions()
            return true
        }
    }

    @objc dynamic func isolatedTestRunModal(for window: NSWindow) -> NSApplication.ModalResponse {
        UnitTestPresentationSafety.performModal(isUnitTesting: AppRuntimeEnvironment.isUnitTesting) {
            isolatedTestRunModal(for: window)
        }
    }
}

private extension NSRunningApplication {
    @objc dynamic func isolatedTestActivate(options: NSApplication.ActivationOptions) -> Bool {
        UnitTestPresentationSafety.performActivation(isUnitTesting: AppRuntimeEnvironment.isUnitTesting) {
            isolatedTestActivate(options: options)
        }
    }
}

private extension NSAlert {
    @objc dynamic func isolatedTestRunModal() -> NSApplication.ModalResponse {
        UnitTestPresentationSafety.performModal(isUnitTesting: AppRuntimeEnvironment.isUnitTesting) {
            isolatedTestRunModal()
        }
    }
}
#endif

/// Close owned file choosers and SwiftUI sheets before asking AppKit to quit.
/// Otherwise AppKit can reject termination before the delegate sees it.
@MainActor
enum FilePanelPresentation {
    /// A chooser's lifecycle boundary. Tests supply closures without creating
    /// an NSOpenPanel, NSSavePanel, window, or system-panel service.
    struct Chooser {
        var allowTermination: @MainActor () -> Void
        var present: @MainActor (@escaping (NSApplication.ModalResponse) -> Void) -> Void
        var cancel: @MainActor () -> Void
        var orderOut: @MainActor () -> Void

        static var cancelling: Self {
            Self(allowTermination: {}, present: { $0(.cancel) }, cancel: {}, orderOut: {})
        }

        static func live(_ panel: NSSavePanel) -> Self {
            Self(allowTermination: { panel.preventsApplicationTerminationWhenModal = false },
                 present: { finish in
                     if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                         panel.beginSheetModal(for: window, completionHandler: finish)
                     } else {
                         panel.begin(completionHandler: finish)
                     }
                 }, cancel: { panel.cancel(nil) }, orderOut: { panel.orderOut(nil) })
        }
    }

    static func chooser(isUnitTesting: Bool, live: () -> Chooser) -> Chooser {
        isUnitTesting ? .cancelling : live()
    }

    // Authorize before dismissing anything: cancelling quit must leave the
    // recording and its currently presented chooser/sheet untouched.
    static var authorizeTermination: (@MainActor () -> Bool)?
    // Consent is valid only during the synchronous AppKit terminate call.
    static var performAuthorizedTermination: (@MainActor (@MainActor @Sendable () -> Void) -> Void)?
    private static var panels: [UUID: Chooser] = [:]
    private static var sheets: [UUID: @MainActor () -> Void] = [:]
    private static var quitMonitor: Any?
    private static var pendingTermination: (@MainActor @Sendable () -> Void)?
    private static var terminationScheduled = false
    private static var quitCommandScheduled = false
    private static var requestingTermination = false
    #if DEBUG
    static var scheduleAfterEventForTesting: (@MainActor (@escaping @MainActor @Sendable () -> Void) -> Void)?
    #endif
    private static let logger = Logger(subsystem: "com.jianhongli.LiveLingo", category: "FilePanel")

    nonisolated static func shouldHandleQuit(characters: String?, modifiers: NSEvent.ModifierFlags,
                                            hasOpenPanel: Bool) -> Bool {
        hasOpenPanel && characters?.lowercased() == "q"
            && modifiers.intersection([.command, .control, .option, .shift]) == .command
    }

    static func begin(_ panel: NSSavePanel,
                      completion: @escaping (NSApplication.ModalResponse) -> Void) {
        begin(chooser(isUnitTesting: AppRuntimeEnvironment.isUnitTesting) { .live(panel) },
              completion: completion)
    }

    static func begin(_ panel: Chooser,
                      completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard pendingTermination == nil else {
            completion(.cancel)
            return
        }
        // A chooser has no unsaved document to protect. Allow the app's quit
        // command to reach its cancellation/termination path while it is open.
        panel.allowTermination()
        let id = UUID()
        panels[id] = panel
        FullScreenClassModeController.shared.setPresentedPopup(id, isPresented: true)
        installQuitMonitor()
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            Task { @MainActor in
                guard panels.removeValue(forKey: id) != nil else { return }
                let quitting = pendingTermination != nil
                if quitting { panel.orderOut() }
                completion(quitting ? .cancel : response)
                FullScreenClassModeController.shared.setPresentedPopup(id, isPresented: false)
                finishIfDismissed()
            }
        }
        panel.present(finish)
    }

    /// Register the binding that dismisses a SwiftUI sheet. The onDismiss
    /// callback acknowledges that the modal window has actually gone away.
    static func registerSheet(id: UUID, dismiss: @escaping @MainActor () -> Void) {
        guard pendingTermination == nil else { dismiss(); return }
        sheets[id] = dismiss
        FullScreenClassModeController.shared.setPresentedPopup(id, isPresented: true)
        installQuitMonitor()
    }

    static func sheetDidDismiss(id: UUID) {
        sheets[id] = nil
        FullScreenClassModeController.shared.setPresentedPopup(id, isPresented: false)
        finishIfDismissed()
    }

    private static func installQuitMonitor() {
        if quitMonitor == nil {
            quitMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let handled = MainActor.assumeIsolated {
                    guard shouldHandleQuit(characters: event.charactersIgnoringModifiers,
                                           modifiers: event.modifierFlags,
                                           hasOpenPanel: !panels.isEmpty || !sheets.isEmpty) else { return false }
                    logger.info("modal event=quit_command")
                    // Finish dispatching this event before dismissing its window.
                    if !event.isARepeat { scheduleTerminationRequest() }
                    return true
                }
                return handled ? nil : event
            }
        }
    }

    /// Coalesce key-downs until this attempt finishes, including events inside
    /// the confirmation's modal loop. A run-loop block avoids synchronously
    /// entering that modal loop from a main-dispatch-queue block.
    static func scheduleTerminationRequest(
        _ terminate: @escaping @MainActor @Sendable () -> Void = { NSApp.terminate(nil) }
    ) {
        guard !quitCommandScheduled, !requestingTermination, pendingTermination == nil else { return }
        quitCommandScheduled = true
        afterCurrentEvent {
            defer { quitCommandScheduled = false }
            requestTermination(terminate)
        }
    }

    private static func afterCurrentEvent(_ operation: @escaping @MainActor @Sendable () -> Void) {
        #if DEBUG
        if let scheduleAfterEventForTesting { scheduleAfterEventForTesting(operation); return }
        #endif
        RunLoop.main.perform(inModes: [.common, .modalPanel]) {
            MainActor.assumeIsolated { operation() }
        }
    }

    private static func performTermination(_ terminate: @MainActor @Sendable () -> Void) {
        if let performAuthorizedTermination { performAuthorizedTermination(terminate) }
        else { terminate() }
    }

    private static func finishIfDismissed() {
        guard panels.isEmpty, sheets.isEmpty else { return }
        if let monitor = quitMonitor {
            NSEvent.removeMonitor(monitor)
            quitMonitor = nil
        }
        guard let terminate = pendingTermination, !terminationScheduled else { return }
        terminationScheduled = true
        afterCurrentEvent {
            pendingTermination = nil
            terminationScheduled = false
            performTermination(terminate)
        }
    }

    static func cancelAll() {
        for panel in Array(panels.values) { panel.cancel() }
    }

    /// Dismiss owned choosers before asking AppKit to quit. AppKit can reject
    /// termination while a sheet is still active, before reaching the delegate.
    static func requestTermination(
        _ terminate: @escaping @MainActor @Sendable () -> Void = { NSApp.terminate(nil) }
    ) {
        guard pendingTermination == nil, !requestingTermination else { return }
        requestingTermination = true
        defer { requestingTermination = false }
        guard authorizeTermination?() != false else { return }
        guard !panels.isEmpty || !sheets.isEmpty else {
            performTermination(terminate)
            return
        }
        logger.info("modal event=quit_requested open_panels=\(panels.count, privacy: .public) open_sheets=\(sheets.count, privacy: .public)")
        pendingTermination = terminate
        cancelAll()
        for dismiss in Array(sheets.values) { dismiss() }
    }
}

@MainActor
enum RecordingQuitConfirmation {
    typealias FocusRestore = @MainActor () -> Void
    enum Choice { case continueSession, saveAndQuit, quitWithoutSaving }

    static func choice(for response: NSApplication.ModalResponse, liveOnly: Bool) -> Choice {
        if response == .alertSecondButtonReturn { return .saveAndQuit }
        if liveOnly, response == .alertThirdButtonReturn { return .quitWithoutSaving }
        return .continueSession
    }

    /// Escape must have the same effect as Continue, regardless of AppKit's
    /// automatic cancel-button assignment in a three-button alert.
    static func handleEscape(_ event: NSEvent, continueSession: () -> Void) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        continueSession()
        return true
    }

    struct PresentationEnvironment {
        var capturePreviousApplication: @MainActor () -> (@MainActor () -> Void)?
        var activateApplication: @MainActor () -> Void

        static var live: Self {
            Self(capturePreviousApplication: {
                guard let previous = NSWorkspace.shared.frontmostApplication,
                      previous.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
                return { if !previous.isTerminated { _ = previous.activate(options: []) } }
            }, activateApplication: { NSApp.activate(ignoringOtherApps: true) })
        }

        static var inert: Self { Self(capturePreviousApplication: { nil }, activateApplication: {}) }
    }

    static func present(environment: PresentationEnvironment, shouldRestore: () -> Bool,
                        confirm: () -> Bool, onConfirmed: ((FocusRestore?) -> Void)? = nil) -> Bool {
        let restorePrevious = environment.capturePreviousApplication()
        environment.activateApplication()
        let confirmed = confirm()
        if confirmed { onConfirmed?(restorePrevious) }
        if !confirmed, shouldRestore() { restorePrevious?() }
        return confirmed
    }

    static func isNeeded(phase: AppPhase, importing: Bool) -> Bool {
        phase == .recording || phase == .paused || importing
    }

    static func isSystemTermination(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventID == kAEQuitApplication else { return false }
        // loginwindow supplies the reason as an attribute. Accept the
        // documented parameter representation too, without guessing from the
        // sender, an app's activation policy, or an ordinary Dock quit.
        let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
            ?? event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        guard let reason else { return false }
        return [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut].contains(reason.enumCodeValue)
    }

    static func makeAlert(phase: AppPhase = .recording, importing: Bool = false, liveOnly: Bool = false) -> NSAlert {
        let alert = NSAlert()
        let continueTitle: String, exitTitle: String
        if importing {
            alert.messageText = "正在导入文件。退出会停止导入并保存已完成的内容。"
            continueTitle = "继续导入"
            exitTitle = "保存并退出"
        } else if liveOnly {
            alert.messageText = phase == .paused
                ? "实时字幕已暂停（不保存）。退出前要保存这节课吗？"
                : "正在实时字幕（不保存）。退出前要保存这节课吗？"
            continueTitle = "继续"
            exitTitle = "保存并退出"
        } else {
            alert.messageText = phase == .paused
                ? "录音已暂停。退出会结束并保存这节课。"
                : "正在录音。退出会结束并保存这节课。"
            continueTitle = phase == .paused ? "保持暂停" : "继续录音"
            exitTitle = "保存并退出"
        }
        let continueButton = alert.addButton(withTitle: continueTitle)
        continueButton.keyEquivalent = "\r"
        continueButton.keyEquivalentModifierMask = []
        alert.addButton(withTitle: exitTitle).keyEquivalent = ""
        if liveOnly, !importing { alert.addButton(withTitle: "退出不保存").keyEquivalent = "" }
        alert.window.preventsApplicationTerminationWhenModal = false
        return alert
    }

    static func makeLiveStopAlert(phase: AppPhase) -> NSAlert {
        let alert = makeAlert(phase: phase, liveOnly: true)
        alert.messageText = phase == .paused
            ? "实时字幕已暂停（不保存）。结束前要保存这节课吗？"
            : "正在实时字幕（不保存）。结束前要保存这节课吗？"
        alert.informativeText = "结束并清空会删除这节课的录音、字幕和笔记，无法撤销。"
        alert.buttons[1].title = "转为录音"
        alert.buttons[2].title = "结束并清空"
        return alert
    }

    static func presentLiveStop(phase: AppPhase) -> Choice {
        let alert = makeLiveStopAlert(phase: phase)
        let popupID = UUID()
        if !AppRuntimeEnvironment.isUnitTesting {
            FullScreenClassModeController.shared.setPresentedPopup(popupID, isPresented: true)
        }
        defer {
            if !AppRuntimeEnvironment.isUnitTesting {
                FullScreenClassModeController.shared.setPresentedPopup(popupID, isPresented: false)
            }
        }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.modalWindow === alert.window else { return event }
            return handleEscape(event) { NSApp.stopModal(withCode: .alertFirstButtonReturn) } ? nil : event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        var selection = Choice.continueSession
        _ = present(environment: AppRuntimeEnvironment.isUnitTesting ? .inert : .live,
                    shouldRestore: { true }, confirm: {
            selection = choice(for: alert.runModal(), liveOnly: true)
            return selection != .continueSession
        })
        return selection
    }

    static func makeSaveFailureAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "保存未完成，已取消退出"
        alert.informativeText = "临时录音与现有文件已保留，请重试保存。"
        alert.addButton(withTitle: "继续")
        alert.window.preventsApplicationTerminationWhenModal = false
        return alert
    }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    private var terminationTask: Task<Void, Never>?
    private var recordingQuitAuthorized = false
    private var saveLiveSessionOnQuit = false
    private var recordingConfirmationAlert: NSAlert?
    private var presentingRecordingConfirmation = false
    private var systemQuitRequested = false
    private var cancelledQuitFocusRestore: RecordingQuitConfirmation.FocusRestore?
    private var presentingLiveSessionSaveFailure = false
    private var liveSessionSaveFailureAlert: NSAlert?
    #if DEBUG
    var cleanupForTesting: (@MainActor @Sendable () async -> Bool)?
    var replyForTesting: (@MainActor @Sendable (Bool) -> Void)?
    var terminationTimeoutForTesting: TimeInterval?
    var confirmExitWithoutSavingForTesting: (@MainActor @Sendable () -> Bool)?
    var recordingStateForTesting: (@MainActor () -> (AppPhase, Bool))?
    var confirmRecordingQuitForTesting: (@MainActor () -> Bool)?
    var recordingQuitChoiceForTesting: (@MainActor () -> RecordingQuitConfirmation.Choice)?
    var liveOnlyForTesting: Bool?
    var liveSessionSaveFailureForTesting: (@MainActor () -> Void)?
    var abortLiveSessionSaveFailureForTesting: (@MainActor () -> Void)?
    var recordingConfirmationEnvironmentForTesting: RecordingQuitConfirmation.PresentationEnvironment?
    var abortRecordingConfirmationForTesting: (@MainActor () -> Void)?
    var terminationEventForTesting: NSAppleEventDescriptor?
    // Both regression suites inject the same bounded termination path.
    var prepareToTerminate: (@MainActor @Sendable () async -> Bool)? {
        get { cleanupForTesting }
        set { cleanupForTesting = newValue }
    }
    var terminationReply: (@MainActor @Sendable (Bool) -> Void)? {
        get { replyForTesting }
        set { replyForTesting = newValue }
    }
    #endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        UnitTestTemporaryDirectory.configure()
        #endif
        guard !AppRuntimeEnvironment.isUnitTesting else { return }
        FilePanelPresentation.authorizeTermination = { [weak self] in
            self?.authorizeRecordingTermination() ?? true
        }
        FilePanelPresentation.performAuthorizedTermination = { [weak self] terminate in
            if let self { self.withRecordingTerminationAuthorization(terminate) }
            else { terminate() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppRuntimeEnvironment.isUnitTesting else { return }
        FullScreenClassModeController.shared.start()
        FullScreenClassModeController.shared.showMainWindowAfterLaunch()
    }

    // Closing the classroom only hides its view. AppModelHolder owns capture
    // for the application lifetime, including when no classroom window exists.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func authorizeRecordingTermination() -> Bool {
        guard terminationTask == nil, !presentingRecordingConfirmation else { return false }
        if recordingQuitAuthorized {
            recordingQuitAuthorized = false
            return true
        }
        saveLiveSessionOnQuit = false
        cancelledQuitFocusRestore = nil
        let state: (AppPhase, Bool)
        #if DEBUG
        if let recordingStateForTesting { state = recordingStateForTesting() }
        else { state = (Self.model?.phase ?? .idle, Self.model?.isImportingFile ?? false) }
        #else
        state = (Self.model?.phase ?? .idle, Self.model?.isImportingFile ?? false)
        #endif
        guard RecordingQuitConfirmation.isNeeded(phase: state.0, importing: state.1) else { return true }
        let liveOnly: Bool
        #if DEBUG
        liveOnly = (liveOnlyForTesting ?? Self.model?.isLiveOnly ?? false) && !state.1
        #else
        liveOnly = (Self.model?.isLiveOnly ?? false) && !state.1
        #endif
        presentingRecordingConfirmation = true
        defer { presentingRecordingConfirmation = false; recordingConfirmationAlert = nil }
        var choice = RecordingQuitConfirmation.Choice.continueSession
        #if DEBUG
        if recordingQuitChoiceForTesting != nil || confirmRecordingQuitForTesting != nil {
            _ = RecordingQuitConfirmation.present(
                environment: recordingConfirmationEnvironmentForTesting ?? .inert,
                shouldRestore: { !self.systemQuitRequested && self.terminationTask == nil },
                confirm: {
                    choice = self.recordingQuitChoiceForTesting?()
                        ?? (self.confirmRecordingQuitForTesting?() == true
                            ? (liveOnly ? .quitWithoutSaving : .saveAndQuit) : .continueSession)
                    return choice != .continueSession
                }, onConfirmed: { restore in
                    if liveOnly, choice == .saveAndQuit { self.cancelledQuitFocusRestore = restore }
                })
        }
        else if !AppRuntimeEnvironment.isUnitTesting {
            choice = presentRecordingConfirmation(phase: state.0, importing: state.1, liveOnly: liveOnly)
        }
        #else
        choice = presentRecordingConfirmation(phase: state.0, importing: state.1, liveOnly: liveOnly)
        #endif
        saveLiveSessionOnQuit = liveOnly && choice == .saveAndQuit && !systemQuitRequested
        return choice != .continueSession || systemQuitRequested
    }

    /// AppKit calls its delegate synchronously from terminate:. If it rejects
    /// that call before reaching us, defer still clears the one-attempt consent.
    func withRecordingTerminationAuthorization(_ terminate: @MainActor () -> Void) {
        recordingQuitAuthorized = true
        defer { recordingQuitAuthorized = false; saveLiveSessionOnQuit = false }
        terminate()
    }

    private func presentRecordingConfirmation(phase: AppPhase, importing: Bool,
                                              liveOnly: Bool) -> RecordingQuitConfirmation.Choice {
        let alert = RecordingQuitConfirmation.makeAlert(phase: phase, importing: importing,
            liveOnly: liveOnly)
        recordingConfirmationAlert = alert
        let popupID = UUID()
        FullScreenClassModeController.shared.setPresentedPopup(popupID, isPresented: true)
        defer { FullScreenClassModeController.shared.setPresentedPopup(popupID, isPresented: false) }
        // The app may be an accessory app with its main window hidden. Bring
        // the confirmation forward without changing the full-screen preference.
        let escapeMonitor = liveOnly ? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.modalWindow === alert.window else { return event }
            return RecordingQuitConfirmation.handleEscape(event, continueSession: {
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
            }) ? nil : event
        } : nil
        defer { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) } }
        var choice = RecordingQuitConfirmation.Choice.continueSession
        _ = RecordingQuitConfirmation.present(environment: .live,
            shouldRestore: { !self.systemQuitRequested && self.terminationTask == nil },
            confirm: {
                choice = RecordingQuitConfirmation.choice(for: alert.runModal(), liveOnly: liveOnly)
                return choice != .continueSession
            }, onConfirmed: { restore in
                if liveOnly, choice == .saveAndQuit { self.cancelledQuitFocusRestore = restore }
            })
        return choice
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        if AppRuntimeEnvironment.isUnitTesting, cleanupForTesting == nil { return .terminateNow }
        let event = terminationEventForTesting ?? NSAppleEventManager.shared().currentAppleEvent
        #else
        let event = NSAppleEventManager.shared().currentAppleEvent
        #endif
        let systemTermination = RecordingQuitConfirmation.isSystemTermination(event)
        let abortConfirmation = systemTermination && presentingRecordingConfirmation && !systemQuitRequested
        let abortSaveFailure = systemTermination && presentingLiveSessionSaveFailure && !systemQuitRequested
        if systemTermination {
            systemQuitRequested = true
            // A system quit also cancels a folder chooser from Save and Quit.
            FilePanelPresentation.cancelAll()
        }
        if abortConfirmation {
            #if DEBUG
            if let abortRecordingConfirmationForTesting { abortRecordingConfirmationForTesting() }
            else if let recordingConfirmationAlert {
                sender.abortModal()
                recordingConfirmationAlert.window.orderOut(nil)
            }
            #else
            if let recordingConfirmationAlert {
                sender.abortModal()
                recordingConfirmationAlert.window.orderOut(nil)
            }
            #endif
        }
        if abortSaveFailure {
            #if DEBUG
            if let abortLiveSessionSaveFailureForTesting { abortLiveSessionSaveFailureForTesting() }
            else if let liveSessionSaveFailureAlert {
                sender.abortModal()
                liveSessionSaveFailureAlert.window.orderOut(nil)
            }
            #else
            if let liveSessionSaveFailureAlert {
                sender.abortModal()
                liveSessionSaveFailureAlert.window.orderOut(nil)
            }
            #endif
        }
        guard terminationTask == nil else { return .terminateLater }
        guard systemTermination || authorizeRecordingTermination() else { return .terminateCancel }
        // A system quit can arrive inside the confirmation's modal loop and
        // start saving before that loop returns. Join that existing attempt.
        guard terminationTask == nil else { return .terminateLater }
        let saveLiveSession = saveLiveSessionOnQuit && !systemQuitRequested
        let restoreCancelledQuit = cancelledQuitFocusRestore
        cancelledQuitFocusRestore = nil
        recordingQuitAuthorized = false
        saveLiveSessionOnQuit = false
        FilePanelPresentation.cancelAll()
        #if DEBUG
        let deadline = ExitDeadline(inactivityTimeout: terminationTimeoutForTesting ?? ExitDeadline.applicationTimeout)
        #else
        let deadline = ExitDeadline(inactivityTimeout: ExitDeadline.applicationTimeout)
        #endif
        terminationTask = Task { [self] in
            let prepare: @MainActor @Sendable (ExitDeadline) async -> Bool = { lease in
                let retireServices: @MainActor @Sendable () async throws -> Void = {
                    guard !AppRuntimeEnvironment.isUnitTesting else { return }
                    await ASRRuntime.shared.stop()
                    guard !lease.isExpired else { return }
                    await MLXRuntime.shared.shutdown()
                    guard await !ASRRuntime.shared.isRunning, await MLXRuntime.shared.resourceStates().isEmpty else {
                        throw ExitDeadlineExceeded()
                    }
                }
                #if DEBUG
                if let cleanupForTesting = self.cleanupForTesting {
                    do { return try await lease.wait { await cleanupForTesting() } }
                    catch { return false }
                }
                #endif
                if let model = Self.model {
                    return await model.prepareForApplicationExit(deadline: lease, retireServices: retireServices)
                }
                do { try await lease.wait { try await retireServices() }; return true }
                catch { return false }
            }
            var shouldExit = false
            var mayPrepareExit = true
            var cancelledFolderSelection = false
            var systemArrivedDuringFailure = false
            if saveLiveSession {
                let conversion = await Self.model?.convertCurrentSessionToRecording(
                    usingExistingOutputDirectory: true, deadline: deadline) ?? .failed
                if systemQuitRequested, conversion == .cancelled {
                    deadline.recordProgress()
                }
                if !systemQuitRequested {
                    switch conversion {
                    case .converted: break
                    case .cancelled:
                        mayPrepareExit = false
                        cancelledFolderSelection = true
                    case .failed:
                        mayPrepareExit = false
                        notifyLiveSessionSaveFailure()
                        systemArrivedDuringFailure = systemQuitRequested
                    }
                }
            }
            if mayPrepareExit { shouldExit = await prepare(deadline) }
            if !shouldExit, mayPrepareExit, saveLiveSession, !systemQuitRequested {
                notifyLiveSessionSaveFailure()
                systemArrivedDuringFailure = systemQuitRequested
            } else if !shouldExit, mayPrepareExit, !systemQuitRequested {
                #if DEBUG
                if let confirmExitWithoutSavingForTesting {
                    shouldExit = confirmExitWithoutSavingForTesting()
                } else if !AppRuntimeEnvironment.isUnitTesting {
                    shouldExit = confirmExitWithoutSaving()
                }
                #else
                shouldExit = confirmExitWithoutSaving()
                #endif
                if shouldExit { deadline.revoke() }
            }
            if systemArrivedDuringFailure {
                // A system request closes the failure modal and makes one
                // fresh bounded save attempt. The failed lease stays revoked.
                #if DEBUG
                let systemDeadline = ExitDeadline(inactivityTimeout: terminationTimeoutForTesting ?? ExitDeadline.applicationTimeout)
                #else
                let systemDeadline = ExitDeadline(inactivityTimeout: ExitDeadline.applicationTimeout)
                #endif
                shouldExit = await prepare(systemDeadline)
            }
            let restoreFocus = !shouldExit && cancelledFolderSelection && !systemQuitRequested ? restoreCancelledQuit : nil
            terminationTask = nil
            recordingQuitAuthorized = false
            systemQuitRequested = false
            #if DEBUG
            if let replyForTesting {
                replyForTesting(shouldExit)
                if !systemQuitRequested { restoreFocus?() }
                return
            }
            #endif
            sender.reply(toApplicationShouldTerminate: shouldExit)
            if !systemQuitRequested { restoreFocus?() }
        }
        return .terminateLater
    }

    private func notifyLiveSessionSaveFailure() {
        guard !systemQuitRequested else { return }
        presentingLiveSessionSaveFailure = true
        defer { presentingLiveSessionSaveFailure = false; liveSessionSaveFailureAlert = nil }
        #if DEBUG
        if let liveSessionSaveFailureForTesting { liveSessionSaveFailureForTesting(); return }
        guard !AppRuntimeEnvironment.isUnitTesting else { return }
        #endif
        let alert = RecordingQuitConfirmation.makeSaveFailureAlert()
        liveSessionSaveFailureAlert = alert
        _ = alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !AppRuntimeEnvironment.isUnitTesting else { return }
        FullScreenClassModeController.shared.shutdown()
        // Service retirement was awaited before the affirmative AppKit reply.
    }

    private func confirmExitWithoutSaving() -> Bool {
        let alert = NSAlert()
        alert.messageText = "退出前的保存或清理未完成"
        alert.informativeText = "磁盘上现有文件会保留。仍要退出可能丢失尚未写入的进度；临时文件可在下次启动后重试清理。"
        alert.addButton(withTitle: "留在应用")
        alert.addButton(withTitle: "仍要退出")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// Observe only recording-start transitions; resuming or refreshing a session
/// cannot reopen a panel the user deliberately hid.
@MainActor
final class FloatingSubtitleRecordStartObserver {
    private var subscription: AnyCancellable?
    private var previousPhase: AppPhase

    init(model: AppModel, windowController: FloatingSubtitleWindowController = .shared,
         defaults: UserDefaults = .standard) {
        previousPhase = model.phase
        subscription = model.$phase.sink { [weak self, weak model, weak windowController] phase in
            guard let self, let model, let windowController else { return }
            let previous = previousPhase
            previousPhase = phase
            if Self.shouldShow(previous: previous, next: phase, importing: model.isImportingFile,
                               enabled: FloatingSubtitlePreferences(store: defaults).showsOnRecordStart,
                               visible: windowController.isVisible, alarmRollover: model.alarmRolloverIsActive) {
                windowController.show(model: model)
            }
        }
    }

    static func shouldShow(previous: AppPhase, next: AppPhase, importing: Bool,
                           enabled: Bool, visible: Bool, alarmRollover: Bool = false) -> Bool {
        previous == .preparing && next == .recording && !importing && enabled && !visible && !alarmRollover
    }
}

/// The test host owns no production model, queue, translation view or service.
@MainActor
private final class AppModelHolder: ObservableObject {
    let model: AppModel?
    private var floatingRecordStart: FloatingSubtitleRecordStartObserver?
    private var modelPreclone: ModelPrecloneController?
    init() {
        #if DEBUG
        UnitTestTemporaryDirectory.configure()
        #endif
        model = AppRuntimeEnvironment.isUnitTesting ? nil : AppModel()
        if let model {
            FullScreenClassModeController.shared.connect(model: model)
            floatingRecordStart = FloatingSubtitleRecordStartObserver(model: model)
            modelPreclone = ModelPrecloneController(model: model)
        }
        AppLifecycleDelegate.model = model
    }
}

@main
struct LiveLingoApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle
    @StateObject private var holder = AppModelHolder()

    var body: some Scene {
        WindowGroup("LiveLingo", id: "classroom") {
            if let model = holder.model {
                ContentView()
                    .environmentObject(model)
                    .background(FullScreenMainWindowRegistration())
                    #if !LIVELINGO_PREVIEW
                    .task { await ASRRuntime.shared.warmUp() }
                    #endif
            } else {
                EmptyView()
            }
        }
        .defaultSize(width: 1_260, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appSettings) {
                if holder.model != nil { FullScreenClassModeMenuItem(controller: .shared) }
            }
            CommandGroup(replacing: .appTermination) {
                Button("退出 LiveLingo") { FilePanelPresentation.requestTermination() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            // One classroom window: File › New Window is replaced by 打开课程.
            CommandGroup(replacing: .newItem) {
                OpenLessonMenuItem(model: holder.model)
            }
            CommandGroup(after: .toolbar) {
                ReadingSizeMenuItems()
            }
            CommandMenu("录音") {
                RecordingMenuItems(model: holder.model)
            }
        }

        Settings {
            if let model = holder.model {
                ClassroomSettingsView(fullScreenMode: .shared).environmentObject(model)
            } else {
                EmptyView()
            }
        }
    }
}

private struct ReadingSizeMenuItems: View {
    @AppStorage("transcriptTextSize") private var textSize = ReadingTypography.defaultTextSize

    private var largerSize: Double? {
        ReadingTypography.steppedTextSize(textSize, direction: .increase)
    }
    private var smallerSize: Double? {
        ReadingTypography.steppedTextSize(textSize, direction: .decrease)
    }

    var body: some View {
        Button("放大字号") {
            if let largerSize { textSize = largerSize }
        }
        .keyboardShortcut("=", modifiers: .command)
        .disabled(largerSize == nil)
        .help("也会缩放悬浮字幕")

        Button("缩小字号") {
            if let smallerSize { textSize = smallerSize }
        }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(smallerSize == nil)
        .help("也会缩放悬浮字幕")

        Button("默认字号") {
            textSize = ReadingTypography.defaultTextSize
        }
        .keyboardShortcut("0", modifiers: .command)
        .help("也会缩放悬浮字幕")
    }
}
