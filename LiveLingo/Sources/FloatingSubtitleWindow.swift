import AppKit
import SwiftUI

struct FloatingSubtitleWindowSettings: Equatable {
    var showsAcrossSpaces = true
    var isLocked = false
    var backgroundOpacity = 1.0

    func collectionBehavior(restoring original: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
        guard showsAcrossSpaces else { return original }
        var behavior = original
        // All Spaces keeps captions with desktop switches; fullScreenAuxiliary
        // lets them accompany a full-screen window. On macOS 14+, joining all
        // applications also permits OTHER apps' full-screen/Stage Manager sets.
        // Remove mutually exclusive roles; moveToActiveSpace is unnecessary
        // when the same overlay already joins every Space. No main window uses this policy.
        behavior.subtract([.moveToActiveSpace, .fullScreenPrimary, .fullScreenNone, .primary, .auxiliary])
        behavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications])
        return behavior
    }
}

/// Owns only the changes to one subtitle window, including its original values.
@MainActor
final class FloatingSubtitleWindowConfiguration {
    private(set) weak var window: NSWindow?
    private let originalLevel: NSWindow.Level
    private let originalCollectionBehavior: NSWindow.CollectionBehavior
    private let originalIgnoresMouseEvents: Bool
    private let originalIsOpaque: Bool
    private let originalBackgroundColor: NSColor

    init(window: NSWindow) {
        self.window = window
        originalLevel = window.level
        originalCollectionBehavior = window.collectionBehavior
        originalIgnoresMouseEvents = window.ignoresMouseEvents
        originalIsOpaque = window.isOpaque
        originalBackgroundColor = window.backgroundColor
    }

    func apply(_ settings: FloatingSubtitleWindowSettings) {
        guard let window else { return }
        window.level = .floating
        window.collectionBehavior = settings.collectionBehavior(restoring: originalCollectionBehavior)
        window.ignoresMouseEvents = settings.isLocked || originalIgnoresMouseEvents
        window.isOpaque = settings.backgroundOpacity < 1 ? false : originalIsOpaque
        window.backgroundColor = settings.backgroundOpacity < 1 ? .clear : originalBackgroundColor
        window.invalidateShadow()
    }

    func restore() {
        guard let window else { return }
        window.level = originalLevel
        window.collectionBehavior = originalCollectionBehavior
        window.ignoresMouseEvents = originalIgnoresMouseEvents
        window.isOpaque = originalIsOpaque
        window.backgroundColor = originalBackgroundColor
        window.invalidateShadow()
    }
}

enum FloatingSubtitleWindowPlacement {
    /// AppKit coordinates grow upwards. visibleFrame already excludes the Dock
    /// and menu bar, including on displays with negative or vertical origins.
    /// Preserve subtitle layout even if a display is smaller than the window.
    static func bottomFrame(windowSize: NSSize, visibleFrame: NSRect, bottomInset: CGFloat = 20) -> NSRect {
        let inset = min(max(0, bottomInset), max(0, visibleFrame.height - windowSize.height))
        return NSRect(x: visibleFrame.midX - windowSize.width / 2,
                      y: visibleFrame.minY + inset, width: windowSize.width, height: windowSize.height)
    }
}

/// A single SwiftUI subtitle Window shares this controller with the toolbar
/// and Commands. Locking is deliberately memory-only: every launch is unlocked.
@MainActor
final class FloatingSubtitleWindowController: ObservableObject {
    static let shared = FloatingSubtitleWindowController()

    @Published private(set) var isLocked = false
    private var configuration: FloatingSubtitleWindowConfiguration?
    private var settings = FloatingSubtitleWindowSettings()
    private var pendingBottomPlacement = false

    var lockActionTitle: String { isLocked ? "解锁浮动字幕" : "锁定浮动字幕" }

    func toggleLock() {
        isLocked.toggle()
        settings.isLocked = isLocked
        configuration?.apply(settings)
    }

    func attach(to window: NSWindow, showsAcrossSpaces: Bool, backgroundOpacity: Double) {
        if configuration?.window !== window {
            configuration?.restore()
            configuration = FloatingSubtitleWindowConfiguration(window: window)
        }
        settings = FloatingSubtitleWindowSettings(showsAcrossSpaces: showsAcrossSpaces,
                                                  isLocked: isLocked, backgroundOpacity: backgroundOpacity)
        configuration?.apply(settings)
        if pendingBottomPlacement {
            pendingBottomPlacement = false
            // An unopened SwiftUI Window attaches before its final content size
            // is laid out. Wait until this pass ends before using its frame.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.configuration?.window === window else { return }
                self.moveToScreenBottom()
            }
        }
    }

    func detach(from window: NSWindow) {
        guard configuration?.window === window else { return }
        configuration?.restore()
        configuration = nil
    }

    func moveToScreenBottom() {
        guard let window = configuration?.window,
              let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            pendingBottomPlacement = true
            return
        }
        window.setFrame(FloatingSubtitleWindowPlacement.bottomFrame(windowSize: window.frame.size,
                                                                    visibleFrame: screen.visibleFrame),
                        display: false)
    }
}

struct FloatingSubtitleWindowBridge: NSViewRepresentable {
    let controller: FloatingSubtitleWindowController
    let showsAcrossSpaces: Bool
    let backgroundOpacity: Double

    final class View: NSView {
        var controller: FloatingSubtitleWindowController?
        var showsAcrossSpaces = true
        var backgroundOpacity = 1.0
        private weak var configuredWindow: NSWindow?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if configuredWindow !== newWindow { detach() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            configuredWindow = window
            controller?.attach(to: window, showsAcrossSpaces: showsAcrossSpaces, backgroundOpacity: backgroundOpacity)
        }

        func detach() {
            if let configuredWindow { controller?.detach(from: configuredWindow) }
            configuredWindow = nil
        }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.controller = controller
        view.showsAcrossSpaces = showsAcrossSpaces
        view.backgroundOpacity = backgroundOpacity
        return view
    }

    func updateNSView(_ nsView: View, context: Context) {
        if nsView.controller !== controller { nsView.detach() }
        nsView.controller = controller
        nsView.showsAcrossSpaces = showsAcrossSpaces
        nsView.backgroundOpacity = backgroundOpacity
        nsView.configureWindow()
    }

    static func dismantleNSView(_ nsView: View, coordinator: ()) {
        nsView.detach()
    }
}
