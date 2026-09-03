import SwiftUI

@main
struct LiveLingoApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1_260, height: 820)
        .windowResizability(.contentMinSize)

        Window("浮动字幕", id: "subtitles") {
            FloatingSubtitleView()
                .environmentObject(model)
        }
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        .defaultPosition(.top)
    }
}
