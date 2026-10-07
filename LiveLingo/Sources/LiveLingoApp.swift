import AppKit
import OSLog
import SwiftUI

/// Close owned file choosers and SwiftUI sheets before asking AppKit to quit.
/// Otherwise AppKit can reject termination before the delegate sees it.
@MainActor
enum FilePanelPresentation {
    private static var panels: [UUID: NSSavePanel] = [:]
    private static var sheets: [UUID: @MainActor () -> Void] = [:]
    private static var quitMonitor: Any?
    private static var pendingTermination: (@MainActor @Sendable () -> Void)?
    private static var terminationScheduled = false
    private static let logger = Logger(subsystem: "com.jianhongli.LiveLingo", category: "FilePanel")

    nonisolated static func shouldHandleQuit(characters: String?, modifiers: NSEvent.ModifierFlags,
                                            hasOpenPanel: Bool) -> Bool {
        hasOpenPanel && characters?.lowercased() == "q"
            && modifiers.intersection([.command, .control, .option, .shift]) == .command
    }

    static func begin(_ panel: NSSavePanel,
                      completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard pendingTermination == nil else {
            completion(.cancel)
            return
        }
        // A chooser has no unsaved document to protect. Allow the app's quit
        // command to reach its cancellation/termination path while it is open.
        panel.preventsApplicationTerminationWhenModal = false
        let id = UUID()
        panels[id] = panel
        installQuitMonitor()
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            Task { @MainActor in
                let quitting = pendingTermination != nil
                panels[id] = nil
                if quitting { panel.orderOut(nil) }
                completion(quitting ? .cancel : response)
                finishIfDismissed()
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// Register the binding that dismisses a SwiftUI sheet. The onDismiss
    /// callback acknowledges that the modal window has actually gone away.
    static func registerSheet(id: UUID, dismiss: @escaping @MainActor () -> Void) {
        guard pendingTermination == nil else { dismiss(); return }
        sheets[id] = dismiss
        installQuitMonitor()
    }

    static func sheetDidDismiss(id: UUID) {
        sheets[id] = nil
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
                    DispatchQueue.main.async { requestTermination() }
                    return true
                }
                return handled ? nil : event
            }
        }
    }

    private static func finishIfDismissed() {
        guard panels.isEmpty, sheets.isEmpty else { return }
        if let monitor = quitMonitor {
            NSEvent.removeMonitor(monitor)
            quitMonitor = nil
        }
        guard let terminate = pendingTermination, !terminationScheduled else { return }
        terminationScheduled = true
        DispatchQueue.main.async {
            pendingTermination = nil
            terminationScheduled = false
            terminate()
        }
    }

    static func cancelAll() {
        for panel in Array(panels.values) { panel.cancel(nil) }
    }

    /// Dismiss owned choosers before asking AppKit to quit. AppKit can reject
    /// termination while a sheet is still active, before reaching the delegate.
    static func requestTermination(
        _ terminate: @escaping @MainActor @Sendable () -> Void = { NSApp.terminate(nil) }
    ) {
        guard pendingTermination == nil else { return }
        guard !panels.isEmpty || !sheets.isEmpty else {
            terminate()
            return
        }
        logger.info("modal event=quit_requested open_panels=\(panels.count, privacy: .public) open_sheets=\(sheets.count, privacy: .public)")
        pendingTermination = terminate
        cancelAll()
        for dismiss in Array(sheets.values) { dismiss() }
    }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        FilePanelPresentation.cancelAll()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !AppRuntimeEnvironment.isUnitTesting else { return }
        ASRRuntime.shared.stopBeforeApplicationExit()
    }
}

/// The test host owns no production model, queue, translation view or service.
@MainActor
private final class AppModelHolder: ObservableObject {
    let model: AppModel?
    init() { model = AppRuntimeEnvironment.isUnitTesting ? nil : AppModel() }
}

@main
struct LiveLingoApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle
    @StateObject private var holder = AppModelHolder()

    var body: some Scene {
        WindowGroup {
            if let model = holder.model {
                ContentView()
                    .environmentObject(model)
                    .task { await ASRRuntime.shared.warmUp() }
            } else {
                EmptyView()
            }
        }
        .defaultSize(width: 1_260, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 LiveLingo") { FilePanelPresentation.requestTermination() }
                    .keyboardShortcut("q", modifiers: .command)
            }
            // One classroom window: File › New Window is replaced by 打开课程.
            CommandGroup(replacing: .newItem) {
                OpenLessonMenuItem(model: holder.model)
            }
            CommandMenu("录音") {
                RecordingMenuItems(model: holder.model)
            }
        }

        Settings {
            if let model = holder.model {
                ClassroomSettingsView().environmentObject(model)
            } else {
                EmptyView()
            }
        }
    }
}
