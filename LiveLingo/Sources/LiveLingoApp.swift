import AppKit
import SwiftUI

/// Keep file-panel keyboard commands in the owning application window.
/// A detached open-panel service can consume Command-Q even when modeless.
@MainActor
enum FilePanelPresentation {
    static func begin(_ panel: NSSavePanel,
                      completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
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
