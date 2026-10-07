#if !LIVELINGO_CLI
import AppKit
import SwiftUI

struct FloatingSubtitleWindowSettings: Equatable {
    var showsAcrossSpaces = true
    var isLocked = false
    var backgroundOpacity = 1.0

    func collectionBehavior(restoring original: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
        guard showsAcrossSpaces else { return original }
        var behavior = original
        // Join every desktop, including during Space switches. Auxiliary roles
        // make the panel eligible for compatible window sets; they do not let a
        // regular foreground app cover another app's full-screen Space. We keep
        // the app's regular activation policy, Dock icon and menu bar.
        // Remove mutually exclusive roles; moveToActiveSpace is unnecessary
        // when the same panel already joins every desktop.
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

/// Screen queries are separate so non-main displays and missing-window-screen
/// fallbacks can be exercised without changing the user's display arrangement.
@MainActor
struct FloatingSubtitleWindowScreens {
    var windowVisibleFrame: (NSWindow) -> NSRect?
    var mainVisibleFrame: () -> NSRect?
    var firstVisibleFrame: () -> NSRect?

    static let live = Self(windowVisibleFrame: { $0.screen?.visibleFrame },
                           mainVisibleFrame: { NSScreen.main?.visibleFrame },
                           firstVisibleFrame: { NSScreen.screens.first?.visibleFrame })

    func visibleFrame(for window: NSWindow) -> NSRect? {
        windowVisibleFrame(window) ?? mainVisibleFrame() ?? firstVisibleFrame()
    }
}

/// Owns one nonactivating panel, rather than borrowing a SwiftUI scene window.
/// SwiftUI hosts only its content and cannot rewrite scene-level window policy.
/// Locking and visibility are memory-only; every launch starts closed/unlocked.
@MainActor
final class FloatingSubtitleWindowController: NSWindowController, ObservableObject, NSWindowDelegate {
    static let shared = FloatingSubtitleWindowController()
    static let frameAutosaveName = "subtitles"
    static let frameDefaultsKey = "NSWindow Frame subtitles"

    @Published private(set) var isLocked = false
    private let defaults: UserDefaults
    private let screens: FloatingSubtitleWindowScreens
    private let notificationCenter: NotificationCenter
    private var configuration: FloatingSubtitleWindowConfiguration?
    private var settings = FloatingSubtitleWindowSettings()
    private var pendingBottomPlacement = false

    #if DEBUG
    // Tests can observe the owned panel without replacing its configuration or content.
    var panelFactoryForTesting: ((NSRect, NSWindow.StyleMask) -> NSPanel)?
    #endif

    var panel: NSPanel? { window as? NSPanel }
    var lockActionTitle: String { isLocked ? "解锁浮动字幕" : "锁定浮动字幕" }

    init(defaults: UserDefaults = .standard, screens: FloatingSubtitleWindowScreens = .live,
         notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.screens = screens
        self.notificationCenter = notificationCenter
        super.init(window: nil)
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            notificationCenter.addObserver(self, selector: #selector(applicationVisibilityChanged(_:)),
                                           name: name, object: NSApp)
        }
    }

    required init?(coder: NSCoder) { fatalError("Subtitle panels are created programmatically") }

    deinit { notificationCenter.removeObserver(self) }

    /// Also used for offscreen verification; creating the content never orders
    /// the panel onscreen, activates the app or starts any model service.
    @discardableResult
    func prepareWindow(model: AppModel) -> NSPanel {
        let preferences = FloatingSubtitlePreferences(store: defaults)
        updateSettings(showsAcrossSpaces: preferences.showsAcrossSpaces,
                       backgroundOpacity: preferences.backgroundOpacity)
        if let panel { return panel }

        let panel = makePanel()
        panel.title = "浮动字幕"
        panel.identifier = NSUserInterfaceItemIdentifier(Self.frameAutosaveName)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        // Keep frame persistence, but deliberately drop the old SwiftUI scene's
        // cross-launch reopening. Subtitles open only through explicit commands.
        panel.isRestorable = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let host = NSHostingView(rootView: AnyView(FloatingSubtitleView(windowController: self)
            .environmentObject(model).defaultAppStorage(defaults)))
        panel.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.contentMinSize = size
        panel.contentMaxSize = size

        if let visible = screens.mainVisibleFrame() ?? screens.firstVisibleFrame() {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                         y: visible.maxY - panel.frame.height - 20))
        }
        // Native AppKit uses this exact key for the former Window(id: "subtitles").
        // Injected preference suites use the same frame format/key without ever
        // registering native autosave against the production defaults domain.
        let savedFrame = defaults.string(forKey: Self.frameDefaultsKey)
        if defaults === UserDefaults.standard {
            windowFrameAutosaveName = Self.frameAutosaveName
            panel.setFrameAutosaveName(Self.frameAutosaveName)
        }
        if let savedFrame { panel.setFrame(from: savedFrame) }
        // Restore the old top-left position, keeping the content's fixed size.
        panel.setContentSize(size)
        window = panel
        configuration = FloatingSubtitleWindowConfiguration(window: panel)
        configuration?.apply(settings)
        panel.delegate = self
        if pendingBottomPlacement {
            pendingBottomPlacement = false
            moveToScreenBottom()
        }
        return panel
    }

    private func makePanel() -> NSPanel {
        let rect = NSRect(x: 0, y: 0, width: 640, height: 350)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .nonactivatingPanel]
        #if DEBUG
        if let panelFactoryForTesting { return panelFactoryForTesting(rect, style) }
        #endif
        return NSPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: false)
    }

    func show(model: AppModel) {
        let panel = prepareWindow(model: model)
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.orderFront(nil)
        configuration?.apply(settings)
    }

    func hide() {
        panel?.orderOut(nil)
        configuration?.apply(settings)
    }

    override func close() {
        saveFrame()
        super.close()
    }

    func toggleLock() {
        isLocked.toggle()
        settings.isLocked = isLocked
        configuration?.apply(settings)
    }

    /// Content reports preferences, never its enclosing window. Hosting this
    /// view elsewhere must not let it configure the classroom/main window.
    func updateSettings(showsAcrossSpaces: Bool, backgroundOpacity: Double) {
        settings = FloatingSubtitleWindowSettings(showsAcrossSpaces: showsAcrossSpaces,
                                                  isLocked: isLocked, backgroundOpacity: backgroundOpacity)
        configuration?.apply(settings)
    }

    @objc private func applicationVisibilityChanged(_ notification: Notification) {
        // Never order a closed panel front on unhide. AppKit handles visibility;
        // our owned policy stays identical before and after either notification.
        configuration?.apply(settings)
    }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        // Unregister the native name before a replacement panel is created,
        // even if AppKit still retains the just-closed panel for this runloop.
        if defaults === UserDefaults.standard { panel?.setFrameAutosaveName("") }
        // The hosted view observes this controller. Release that content when
        // closing to break the controller -> panel -> view -> controller cycle.
        // Reopening creates a panel at the saved frame with the same runtime lock.
        panel?.contentView = nil
        configuration = nil
        window = nil
    }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let panel else { return }
        defaults.set(panel.frameDescriptor, forKey: Self.frameDefaultsKey)
    }

    func moveToScreenBottom() {
        guard let panel else {
            pendingBottomPlacement = true
            return
        }
        guard let visibleFrame = screens.visibleFrame(for: panel) else { return }
        panel.setFrame(FloatingSubtitleWindowPlacement.bottomFrame(windowSize: panel.frame.size,
                                                                   visibleFrame: visibleFrame), display: false)
        saveFrame()
    }
}
#endif
