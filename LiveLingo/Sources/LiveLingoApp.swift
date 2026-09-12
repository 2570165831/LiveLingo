import AppKit
import SwiftUI

/// Ends the supervised ASR child when the app quits. The service also exits by
/// itself when this process disappears or closes its stdin, so this hook is the
/// orderly path rather than the only one.
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        ASRRuntime.shared.stopBeforeApplicationExit()
    }
}

@main
struct LiveLingoApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var lifecycle
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task {
                    // Warm the bundled ASR service in the background. Failures
                    // stay in the log; the readiness check owns user-visible
                    // diagnostics.
                    await ASRRuntime.shared.warmUp()
                }
        }
        .defaultSize(width: 1_260, height: 820)
        .windowResizability(.contentMinSize)

        Window("浮动字幕", id: "subtitles") {
            FloatingSubtitleView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.top)

    }
}
