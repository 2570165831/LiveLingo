import AppKit
import SwiftUI

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
