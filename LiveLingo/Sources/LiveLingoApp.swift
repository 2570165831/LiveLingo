import AppKit
import OSLog
import SwiftUI

/// Keep file-panel keyboard commands in the owning application window.
/// A detached open-panel service can consume Command-Q even when modeless.
@MainActor
enum FilePanelPresentation {
    private static var panels: [UUID: NSSavePanel] = [:]
    private static var quitMonitor: Any?
    private static let logger = Logger(subsystem: "com.jianhongli.LiveLingo", category: "FilePanel")

    nonisolated static func shouldHandleQuit(characters: String?, modifiers: NSEvent.ModifierFlags,
                                            hasOpenPanel: Bool) -> Bool {
        hasOpenPanel && characters?.lowercased() == "q"
            && modifiers.intersection([.command, .control, .option, .shift]) == .command
    }

    static func begin(_ panel: NSSavePanel,
                      completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let id = UUID()
        panels[id] = panel
        if quitMonitor == nil {
            quitMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let handled = MainActor.assumeIsolated {
                    guard shouldHandleQuit(characters: event.charactersIgnoringModifiers,
                                           modifiers: event.modifierFlags,
                                           hasOpenPanel: !panels.isEmpty) else { return false }
                    logger.info("file_panel event=quit_command")
                    // Finish dispatching this event before cancelling the chooser.
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                    return true
                }
                return handled ? nil : event
            }
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            Task { @MainActor in
                panels[id] = nil
                if panels.isEmpty, let monitor = quitMonitor {
                    NSEvent.removeMonitor(monitor)
                    quitMonitor = nil
                }
                completion(response)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    static func cancelAll() {
        for panel in Array(panels.values) { panel.cancel(nil) }
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

        Window("浮动字幕", id: "subtitles") {
            if let model = holder.model {
                FloatingSubtitleView().environmentObject(model)
            } else {
                EmptyView()
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.top)
    }
}
