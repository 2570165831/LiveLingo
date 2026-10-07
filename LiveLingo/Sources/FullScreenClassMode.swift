#if !LIVELINGO_CLI
import AppKit
import Combine
import SwiftUI

@MainActor
struct FullScreenApplicationWindowSnapshot {
    var hasWindows: Bool
    var wasKey: Bool
    var restore: () -> Void
    var armDelayedRestoration: (Bool) -> Void = { _ in }
    var canRestore: () -> Bool = { true }
    var cancel: () -> Void = {}
}

@MainActor
protocol FullScreenRestorableWindow: AnyObject {
    var isVisible: Bool { get }
    var isMiniaturized: Bool { get }
    var windowNumber: Int { get }
    var restorationParent: (any FullScreenRestorableWindow)? { get }
    var restorationChildren: [any FullScreenRestorableWindow] { get }
    var firstResponder: NSResponder? { get }
    func orderFrontRegardless()
    func orderOut(_ sender: Any?)
    func order(_ place: NSWindow.OrderingMode, relativeTo otherWindowNumber: Int)
    func makeKey()
    func makeMain()
    func makeFirstResponder(_ responder: NSResponder?) -> Bool
    func miniaturize(_ sender: Any?)
    func deminiaturize(_ sender: Any?)
}

extension NSWindow: FullScreenRestorableWindow {
    var restorationParent: (any FullScreenRestorableWindow)? { sheetParent ?? parent }
    var restorationChildren: [any FullScreenRestorableWindow] {
        var children = childWindows ?? []
        if let attachedSheet, !children.contains(where: { $0 === attachedSheet }) { children.append(attachedSheet) }
        return children
    }
}

/// Tests inject window state and process operations, never transform NSApp.
@MainActor
struct FullScreenApplicationEnvironment {
    var windows: () -> [any FullScreenRestorableWindow]
    var orderedWindowNumbers: () -> [Int]
    var mainWindow: () -> (any FullScreenRestorableWindow)?
    var keyWindow: () -> (any FullScreenRestorableWindow)?
    var isActive: () -> Bool
    var activationPolicy: () -> NSApplication.ActivationPolicy
    var setActivationPolicy: (NSApplication.ActivationPolicy) -> Bool
    var unhide: () -> Void
    var activate: () -> Void
    var foregroundApplicationPID: () -> Int32? = { nil }
    var applicationPID: Int32 = ProcessInfo.processInfo.processIdentifier
    var observeUserInput: (@escaping @MainActor () -> Void) -> AnyCancellable = { _ in AnyCancellable {} }
    var observeForegroundChanges: (@escaping @MainActor (Int32?) -> Void) -> AnyCancellable = { _ in AnyCancellable {} }

    static var live: Self {
        Self(windows: { NSApp.windows },
             orderedWindowNumbers: { (NSWindow.windowNumbers(options: .allSpaces) ?? []).map(\.intValue) },
             mainWindow: { NSApp.mainWindow }, keyWindow: { NSApp.keyWindow }, isActive: { NSApp.isActive },
             activationPolicy: { NSApp.activationPolicy() }, setActivationPolicy: {
                 precondition(!AppRuntimeEnvironment.isUnitTesting, "Tests must inject activation policy")
                 return NSApp.setActivationPolicy($0)
             }, unhide: { NSApp.unhideWithoutActivation() }, activate: {
                 precondition(!AppRuntimeEnvironment.isUnitTesting, "Tests must inject app activation")
                 NSApp.activate(ignoringOtherApps: true)
             }, foregroundApplicationPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
             observeUserInput: { action in
                 precondition(!AppRuntimeEnvironment.isUnitTesting, "Tests must inject user input")
                 // A local monitor needs no system permission and leaves events
                 // untouched. The click/key that triggered this switch has
                 // already passed it before the recovery checkpoint is armed.
                 let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown,
                     .otherMouseDown, .keyDown, .scrollWheel]) { event in
                     MainActor.assumeIsolated { action() }
                     return event
                 }
                 return AnyCancellable {
                     guard let monitor else { return }
                     if Thread.isMainThread { MainActor.assumeIsolated { NSEvent.removeMonitor(monitor) } }
                     else { DispatchQueue.main.async { NSEvent.removeMonitor(monitor) } }
                 }
             }, observeForegroundChanges: { action in
                 NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
                     .sink { event in
                         let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                         MainActor.assumeIsolated { action(app?.processIdentifier) }
                     }
             })
    }
}

@MainActor
protocol FullScreenApplicationControlling: AnyObject {
    var activationPolicy: NSApplication.ActivationPolicy { get }
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool
    func windowSnapshot() -> FullScreenApplicationWindowSnapshot
    func registerMainWindow(_ window: NSWindow, reopen: @escaping () -> Void)
    func showMainWindow()
    func activate()
    func requestTermination()
}

@MainActor
final class LiveFullScreenApplication: FullScreenApplicationControlling {
    private weak var mainWindow: NSWindow?
    private var reopen: (() -> Void)?
    private let environment: FullScreenApplicationEnvironment
    private let notifications: NotificationCenter
    var activationPolicy: NSApplication.ActivationPolicy { environment.activationPolicy() }

    init(environment: FullScreenApplicationEnvironment = .live, notifications: NotificationCenter = .default) {
        self.environment = environment
        self.notifications = notifications
    }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        environment.setActivationPolicy(policy)
    }

    func registerMainWindow(_ window: NSWindow, reopen: @escaping () -> Void) {
        mainWindow = window
        self.reopen = reopen
    }

    func windowSnapshot() -> FullScreenApplicationWindowSnapshot {
        let restoration = FullScreenWindowRestoration(environment: environment, notifications: notifications,
                                                      activationTarget: mainWindow)
        return FullScreenApplicationWindowSnapshot(hasWindows: restoration.hasWindows, wasKey: restoration.hadKeyWindow,
            restore: { restoration.restore() }, armDelayedRestoration: { restoration.arm(expectsActivation: $0) },
            canRestore: { restoration.canRestore }, cancel: { restoration.cancel() })
    }

    func showMainWindow() {
        NSApp.unhideWithoutActivation()
        if let mainWindow, mainWindow.contentView != nil {
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
        } else {
            reopen?()
        }
    }

    func activate() {
        environment.activate()
    }

    func requestTermination() { FilePanelPresentation.requestTermination() }
}

/// Capture the entire app-owned graph, including parents omitted from NSApp's
/// flat list. Never detach/re-present sheets: doing so can complete callbacks.
@MainActor
private final class FullScreenWindowRestoration {
    private struct Entry {
        weak var window: (any FullScreenRestorableWindow)?
        let identity: ObjectIdentifier
        let visible: Bool
        let minimized: Bool
        weak var responder: NSResponder?
    }

    private struct WindowState: Equatable {
        let identity: ObjectIdentifier
        let parent: ObjectIdentifier?
        let responder: ObjectIdentifier?
    }

    private struct Checkpoint: Equatable {
        let windows: [WindowState]
        let active: Bool
        let key: ObjectIdentifier?
        let main: ObjectIdentifier?
        let foregroundApplicationPID: Int32?
    }

    private let environment: FullScreenApplicationEnvironment
    private var entries: [Entry] = []
    private var frontToBack: [Entry] = []
    private weak var keyWindow: (any FullScreenRestorableWindow)?
    private weak var mainWindow: (any FullScreenRestorableWindow)?
    private weak var activationTarget: (any FullScreenRestorableWindow)?
    private weak var activationKeyWindow: (any FullScreenRestorableWindow)?
    private weak var activationMainWindow: (any FullScreenRestorableWindow)?
    private var activationExpected = false
    private var activationFocusMayChange = false
    private let wasActive: Bool
    private var closed: Set<ObjectIdentifier> = []
    private var observers: [AnyCancellable] = []
    private var checkpoint: Checkpoint?
    private var cancelled = false
    private var restoring = false
    var hasWindows: Bool { !entries.isEmpty }
    var hadKeyWindow: Bool { wasActive && keyWindow != nil }

    init(environment: FullScreenApplicationEnvironment, notifications: NotificationCenter,
         activationTarget: (any FullScreenRestorableWindow)?) {
        self.environment = environment
        self.activationTarget = activationTarget
        wasActive = environment.isActive()
        keyWindow = wasActive ? environment.keyWindow() : nil
        mainWindow = environment.mainWindow()
        entries = Self.windows(in: environment, including: activationTarget).map {
            Entry(window: $0, identity: ObjectIdentifier($0), visible: $0.isVisible,
                  minimized: $0.isMiniaturized, responder: $0.firstResponder)
        }
        let ranks = Dictionary(environment.orderedWindowNumbers().enumerated().map { ($1, $0) },
                               uniquingKeysWith: { first, _ in first })
        frontToBack = entries.filter { $0.visible && !$0.minimized }.sorted {
            (ranks[$0.window?.windowNumber ?? -1] ?? Int.max) < (ranks[$1.window?.windowNumber ?? -1] ?? Int.max)
        }
        // A real close must never be undone, even if it occurs synchronously
        // during the policy transform. Other policy-generated events are ignored
        // until the immediate recovery and intentional activation have finished.
        observers.append(notifications.publisher(for: NSWindow.willCloseNotification).sink { [weak self] event in
            guard let self, let window = event.object as? any FullScreenRestorableWindow else { return }
            self.closed.insert(ObjectIdentifier(window))
            if self.checkpoint != nil { self.cancel() }
        })
        for name in [NSApplication.didResignActiveNotification, NSApplication.didHideNotification] {
            observers.append(notifications.publisher(for: name).sink { [weak self] _ in
                guard let self, self.checkpoint != nil, !self.restoring else { return }
                if name == NSApplication.didResignActiveNotification,
                   self.activationExpected, self.checkpoint?.active == false { return }
                self.cancel()
            })
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(notifications.publisher(for: name).sink { [weak self] event in
                guard let self, let checkpoint = self.checkpoint, !self.restoring,
                      let window = event.object as? any FullScreenRestorableWindow else { return }
                let isMain = name == NSWindow.didBecomeMainNotification
                let activationFocus = isMain ? self.activationMainWindow : self.activationKeyWindow
                let expected = activationFocus.map(ObjectIdentifier.init) ?? (isMain ? checkpoint.main : checkpoint.key)
                let identity = ObjectIdentifier(window)
                if self.acceptsActivationFocus(identity, isMain: isMain) {
                    if name == NSWindow.didBecomeKeyNotification { self.activationKeyWindow = window }
                    else { self.activationMainWindow = window }
                } else if identity != expected { self.cancel() }
            })
        }
        observers.append(environment.observeUserInput { [weak self] in
            guard let self, self.checkpoint != nil, !self.restoring else { return }
            self.cancel()
        })
        observers.append(environment.observeForegroundChanges { [weak self] pid in
            guard let self, self.checkpoint != nil, !self.restoring, pid != environment.applicationPID else { return }
            self.cancel()
        })
    }

    private static func windows(in environment: FullScreenApplicationEnvironment,
                                including additional: (any FullScreenRestorableWindow)?) -> [any FullScreenRestorableWindow] {
        var windows: [any FullScreenRestorableWindow] = []
        var seen: Set<ObjectIdentifier> = []
        func visit(_ window: any FullScreenRestorableWindow) {
            guard seen.insert(ObjectIdentifier(window)).inserted else { return }
            windows.append(window)
            if let parent = window.restorationParent { visit(parent) }
            window.restorationChildren.forEach(visit)
        }
        environment.windows().forEach(visit)
        if let main = environment.mainWindow() { visit(main) }
        if let key = environment.keyWindow() { visit(key) }
        if let additional { visit(additional) }
        return windows
    }

    func restore() {
        guard !cancelled else { return }
        restoring = true
        defer { restoring = false }
        if entries.contains(where: { $0.visible && !$0.minimized }) { environment.unhide() }
        // Preserve hidden/minimized windows too: unhide can reveal windows that
        // were deliberately ordered out before the transition.
        for entry in entries {
            guard let window = entry.window, !closed.contains(entry.identity) else { continue }
            if entry.minimized {
                if !window.isMiniaturized { window.miniaturize(nil) }
            } else if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            if !entry.visible || entry.minimized { window.orderOut(nil) }
        }
        // Reveal parents before children, retaining the existing sheet graph.
        var shown: Set<ObjectIdentifier> = []
        func show(_ entry: Entry) {
            guard let window = entry.window, !closed.contains(entry.identity),
                  shown.insert(entry.identity).inserted else { return }
            if let parent = window.restorationParent,
               let parentEntry = frontToBack.first(where: { $0.identity == ObjectIdentifier(parent) }) { show(parentEntry) }
            window.orderFrontRegardless()
        }
        frontToBack.reversed().forEach(show)
        // Focus restoration uses makeKey/makeMain, not makeKeyAndOrderFront.
        let keyToRestore = wasActive ? keyWindow : activationKeyWindow
        if let keyToRestore, !closed.contains(ObjectIdentifier(keyToRestore)) { keyToRestore.makeKey() }
        let mainToRestore = mainWindow ?? activationMainWindow
        if let mainToRestore, !closed.contains(ObjectIdentifier(mainToRestore)) { mainToRestore.makeMain() }
        // Relative ordering restores z-order without activating the application.
        var previous: (any FullScreenRestorableWindow)?
        for entry in frontToBack.reversed() {
            guard let window = entry.window, !closed.contains(entry.identity) else { continue }
            if let previous { window.order(.above, relativeTo: previous.windowNumber) }
            previous = window
        }
        // Ordering a parent can also reveal its child windows. Enforce the
        // saved hidden/minimized states after the whole graph has been ordered.
        for entry in entries {
            guard let window = entry.window, !closed.contains(entry.identity) else { continue }
            if entry.minimized {
                if !window.isMiniaturized { window.miniaturize(nil) }
            } else if window.isMiniaturized { window.deminiaturize(nil) }
            if !entry.visible || entry.minimized { window.orderOut(nil) }
            if let responder = entry.responder { _ = window.makeFirstResponder(responder) }
        }
    }

    private func currentCheckpoint() -> Checkpoint {
        Checkpoint(windows: Self.windows(in: environment, including: activationTarget).map {
            WindowState(identity: ObjectIdentifier($0), parent: $0.restorationParent.map(ObjectIdentifier.init),
                        responder: $0.firstResponder.map(ObjectIdentifier.init))
        }, active: environment.isActive(),
           key: environment.keyWindow().map(ObjectIdentifier.init), main: environment.mainWindow().map(ObjectIdentifier.init),
           foregroundApplicationPID: environment.foregroundApplicationPID())
    }

    func arm(expectsActivation: Bool) {
        guard !cancelled else { return }
        let checkpoint = currentCheckpoint()
        self.checkpoint = checkpoint
        activationExpected = expectsActivation
        activationFocusMayChange = expectsActivation && (!checkpoint.active || checkpoint.key == nil)
    }

    private func acceptsActivationFocus(_ identity: ObjectIdentifier, isMain: Bool) -> Bool {
        guard activationFocusMayChange, !closed.contains(identity) else { return false }
        // Own activation may establish one key/main focus. Once known, a
        // different non-nil focus is a newer decision even without mouse input.
        let established = isMain ? activationMainWindow : activationKeyWindow
        if let established { return ObjectIdentifier(established) == identity }
        return entries.contains { $0.identity == identity && !$0.minimized
                && ($0.visible || identity == activationTarget.map(ObjectIdentifier.init)) }
    }
    var canRestore: Bool {
        guard !cancelled, let checkpoint else { return false }
        let current = currentCheckpoint()
        let expectedKey = activationKeyWindow.map(ObjectIdentifier.init) ?? checkpoint.key
        let expectedMain = activationMainWindow.map(ObjectIdentifier.init) ?? checkpoint.main
        guard current.active == checkpoint.active || activationExpected && !checkpoint.active && current.active,
              current.foregroundApplicationPID == checkpoint.foregroundApplicationPID
                || activationExpected && current.foregroundApplicationPID == environment.applicationPID,
              current.key == nil || current.key == expectedKey
                || current.key.map({ acceptsActivationFocus($0, isMain: false) }) == true,
              current.main == nil || current.main == expectedMain
                || current.main.map({ acceptsActivationFocus($0, isMain: true) }) == true,
              current.windows.count == checkpoint.windows.count else { return false }
        for old in checkpoint.windows {
            guard let new = current.windows.first(where: { $0.identity == old.identity }),
                  old.parent == new.parent,
                  new.responder == nil || new.responder == old.responder || new.responder == new.identity else { return false }
        }
        // Polling while activation is still pending must not consume its one
        // future focus with the inactive app's existing main window.
        if current.active {
            if let key = environment.keyWindow(), acceptsActivationFocus(ObjectIdentifier(key), isMain: false) { activationKeyWindow = key }
            if let main = environment.mainWindow(), acceptsActivationFocus(ObjectIdentifier(main), isMain: true) { activationMainWindow = main }
        }
        // Policy-generated orderOut/key clearing is exactly why this second
        // pass exists. Input, close and focus tokens distinguish it from a user's
        // hide/minimize/order decision; comparing visibility alone cannot.
        return true
    }
    func cancel() { cancelled = true; observers.removeAll() }
}

@MainActor
protocol FullScreenSubtitleControlling: AnyObject {
    var isLocked: Bool { get }
    var isVisible: Bool { get }
    var stateChanges: AnyPublisher<Void, Never> { get }
    func setFullScreenClassMode(_ enabled: Bool)
    func setPopupIsOpen(_ open: Bool)
    func show(model: AppModel)
    func hide()
    func toggleLock()
    func moveToScreenBottom()
    func shutdown()
}

extension FloatingSubtitleWindowController: FullScreenSubtitleControlling {
    var stateChanges: AnyPublisher<Void, Never> { objectWillChange.eraseToAnyPublisher() }
}

struct FullScreenRecordingState: Equatable {
    var hasActiveSession = false
    var isPaused = false
    var actionTitle = "开始记录"
    var canToggle = false
}

@MainActor
struct FullScreenRecordingCommands {
    var state: () -> FullScreenRecordingState
    var toggle: () -> Void

    static func live(model: AppModel) -> Self {
        Self(state: {
            FullScreenRecordingState(hasActiveSession: model.hasActiveSession, isPaused: model.isPaused,
                                     actionTitle: model.hasActiveSession ? model.stopRecordingTitle : "开始记录",
                                     canToggle: model.canToggleRecording)
        }, toggle: { model.toggleRecording() })
    }
}

struct FullScreenStatusAppearance: Equatable {
    var hasActiveSession: Bool
    var isPaused: Bool

    var accessibilityLabel: String {
        let state = hasActiveSession ? (isPaused ? "记录已暂停" : "正在记录") : "未记录"
        return "LiveLingo，全屏网课模式，\(state)"
    }

    @MainActor
    func configure(_ button: NSButton) {
        let symbol = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: nil)
        let image = NSImage(size: NSSize(width: 24, height: 18))
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            let glyphRect = NSRect(x: 1, y: 1, width: 18, height: 16)
            symbol?.draw(in: glyphRect)
            // A recording image is not a template (its dot must stay colored).
            // Resolve the glyph explicitly so it also remains legible in dark menus.
            NSColor.labelColor.setFill()
            glyphRect.fill(using: .sourceAtop)
            if hasActiveSession {
                // NSRect's explicit compositing operation affects subsequent
                // path fills too. The dot must draw outside the glyph's alpha.
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                (isPaused ? NSColor.systemOrange : NSColor.systemRed).setFill()
                NSBezierPath(ovalIn: NSRect(x: 17, y: 0, width: 7, height: 7)).fill()
            }
            image.unlockFocus()
        }
        image.isTemplate = !hasActiveSession
        button.image = image
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
    }
}

@MainActor
protocol FullScreenStatusItemPresenting: AnyObject {
    func install(menu: NSMenu, appearance: FullScreenStatusAppearance) -> Bool
    func update(appearance: FullScreenStatusAppearance)
    func remove()
}

@MainActor
final class LiveFullScreenStatusItem: FullScreenStatusItemPresenting {
    private var item: NSStatusItem?

    func install(menu: NSMenu, appearance: FullScreenStatusAppearance) -> Bool {
        precondition(!AppRuntimeEnvironment.isUnitTesting, "Tests must inject the status bar")
        if item == nil { item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        guard let item, let button = item.button else { remove(); return false }
        item.menu = menu
        // This is the only recovery entry while the Dock icon is absent.
        item.behavior = []
        appearance.configure(button)
        return true
    }

    func update(appearance: FullScreenStatusAppearance) {
        if let button = item?.button { appearance.configure(button) }
    }

    func remove() {
        guard let item else { return }
        item.menu = nil
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
    }
}

enum FullScreenMenuAction: String, CaseIterable {
    case showMainWindow, toggleSubtitles, toggleLock, moveSubtitlesToBottom
    case toggleRecording, disableMode, quit
}

/// All three entry points (Settings, app menu, status menu) share this owner.
/// Construction only reads preferences; starting/changing policy is explicit.
@MainActor
final class FullScreenClassModeController: NSObject, ObservableObject, NSMenuDelegate {
    static let preferenceKey = "fullScreenClassModeEnabled"
    static let explanation = "开启后 Dock 图标和 App 菜单栏消失，⌘Tab 中不再出现；用顶部菜单栏的 LiveLingo 图标操作。用于尝试在其他 App 的原生全屏中显示字幕，真机效果以实际为准。字幕可能遮挡系统菜单或通知，可移到底部或隐藏。"

    static let shared = FullScreenClassModeController(
        defaults: AppRuntimeEnvironment.preferences, application: LiveFullScreenApplication(),
        statusItem: LiveFullScreenStatusItem(), subtitles: FloatingSubtitleWindowController.shared)

    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?
    let menu = NSMenu(title: "LiveLingo")
    private let defaults: UserDefaults
    private let application: any FullScreenApplicationControlling
    private let statusItem: any FullScreenStatusItemPresenting
    private let subtitles: any FullScreenSubtitleControlling
    private let schedule: (@escaping @MainActor () -> Void) -> Void
    private let originalActivationPolicy: NSApplication.ActivationPolicy
    private var model: AppModel?
    private var recording = FullScreenRecordingCommands(state: { FullScreenRecordingState() }, toggle: {})
    private var observers: [AnyCancellable] = []
    private var recordingObserver: AnyCancellable?
    private var generation = 0
    private var started = false
    private var terminated = false
    private var needsMainWindow = false
    private weak var registeredMainWindow: NSWindow?
    private var lastAppearance: FullScreenStatusAppearance?
    private var openNativePopups: Set<ObjectIdentifier> = []
    private var openPresentedPopups: Set<UUID> = []
    private var popupProtectionIsActive = false
    private var cancelWindowRestoration: (() -> Void)?
    private var cancelMainWindowRegistration: (() -> Void)?

    init(defaults: UserDefaults, application: any FullScreenApplicationControlling,
         statusItem: any FullScreenStatusItemPresenting, subtitles: any FullScreenSubtitleControlling,
         notifications: NotificationCenter = .default,
         schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
             DispatchQueue.main.async { action() }
         }) {
        self.defaults = defaults
        self.application = application
        self.statusItem = statusItem
        self.subtitles = subtitles
        self.schedule = schedule
        originalActivationPolicy = application.activationPolicy
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        for action in FullScreenMenuAction.allCases {
            if action == .toggleRecording || action == .disableMode { menu.addItem(.separator()) }
            let item = NSMenuItem(title: "", action: #selector(menuAction(_:)), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            item.representedObject = action.rawValue
            item.target = self
            menu.addItem(item)
        }
        observers.append(subtitles.stateChanges.sink { [weak self] in
            self?.schedule { [weak self] in self?.refresh() }
        })
        // Includes SwiftUI font/picker menus, selectable-text context menus,
        // the app/menu-bar menus and submenus without replacing their delegates.
        for name in [NSMenu.didBeginTrackingNotification, NSPopover.willShowNotification] {
            observers.append(notifications.publisher(for: name).sink { [weak self] event in
                guard let popup = event.object as AnyObject? else { return }
                self?.nativePopupChanged(popup, open: true)
            })
        }
        for name in [NSMenu.didEndTrackingNotification, NSPopover.didCloseNotification] {
            observers.append(notifications.publisher(for: name).sink { [weak self] event in
                guard let popup = event.object as AnyObject? else { return }
                self?.nativePopupChanged(popup, open: false)
            })
        }
        refresh()
    }

    var binding: Binding<Bool> { Binding(get: { self.isEnabled }, set: { self.setEnabled($0) }) }
    var actionTitle: String { isEnabled ? "关闭全屏网课模式" : "开启全屏网课模式" }

    func connect(model: AppModel, recording: FullScreenRecordingCommands? = nil) {
        self.model = model
        self.recording = recording ?? .live(model: model)
        recordingObserver = model.objectWillChange.sink { [weak self] in
            self?.schedule { [weak self] in self?.refresh() }
        }
        refresh()
    }

    func start() {
        guard !started, !terminated else { return }
        started = true
        if defaults.bool(forKey: Self.preferenceKey) {
            setEnabled(true, persist: false)
            needsMainWindow = isEnabled
        }
    }

    func showMainWindowAfterLaunch() {
        guard isEnabled, !terminated else { return }
        needsMainWindow = registeredMainWindow == nil
        application.showMainWindow()
        application.activate()
    }

    func registerMainWindow(_ window: NSWindow, reopen: @escaping () -> Void) {
        application.registerMainWindow(window, reopen: reopen)
        registeredMainWindow = window
        guard needsMainWindow, !terminated else { return }
        needsMainWindow = false
        let expected = generation
        cancelMainWindowRegistration?()
        let snapshot = application.windowSnapshot()
        snapshot.armDelayedRestoration(true)
        cancelMainWindowRegistration = snapshot.cancel
        schedule { [weak self] in
            defer { snapshot.cancel() }
            guard let self, !self.terminated, self.generation == expected else { return }
            self.cancelMainWindowRegistration = nil
            guard snapshot.canRestore() else { return }
            self.application.showMainWindow()
            self.application.activate()
        }
    }

    func toggle() { setEnabled(!isEnabled) }

    func setEnabled(_ enabled: Bool, persist: Bool = true) {
        guard !terminated, enabled != isEnabled else { return }
        cancelWindowRestoration?()
        cancelWindowRestoration = nil
        cancelMainWindowRegistration?()
        cancelMainWindowRegistration = nil
        let snapshot = application.windowSnapshot()
        if enabled && !statusItem.install(menu: menu, appearance: appearance) {
            snapshot.cancel()
            errorMessage = "菜单栏图标未能显示，全屏网课模式未开启。"
            return
        }
        guard application.setActivationPolicy(enabled ? .accessory : .regular) else {
            snapshot.cancel()
            if enabled { statusItem.remove() }
            errorMessage = "macOS 未能切换 App 显示方式，请重试。"
            return
        }
        generation += 1
        let expected = generation
        isEnabled = enabled
        errorMessage = nil
        subtitles.setFullScreenClassMode(enabled)
        updatePopupProtection()
        if !enabled {
            needsMainWindow = false
            statusItem.remove()
            lastAppearance = nil
        }
        if persist { defaults.set(enabled, forKey: Self.preferenceKey) }
        // Restore every captured window now. The second pass handles delayed
        // policy-generated hiding/key clearing only while the user-decision
        // token and focus/window-graph checks remain valid.
        if snapshot.hasWindows { snapshot.restore() }
        if !enabled || snapshot.wasKey { application.activate() }
        snapshot.armDelayedRestoration(!enabled || snapshot.wasKey)
        cancelWindowRestoration = snapshot.cancel
        schedule { [weak self] in
            defer { snapshot.cancel() }
            guard let self, !self.terminated, self.generation == expected else { return }
            self.cancelWindowRestoration = nil
            guard snapshot.canRestore() else { return }
            if snapshot.hasWindows { snapshot.restore() }
            if !enabled || snapshot.wasKey { self.application.activate() }
        }
        refresh()
    }

    func shutdown() {
        guard !terminated else { return }
        terminated = true
        generation += 1
        needsMainWindow = false
        cancelWindowRestoration?()
        cancelMainWindowRegistration?()
        cancelWindowRestoration = nil
        cancelMainWindowRegistration = nil
        openNativePopups.removeAll()
        openPresentedPopups.removeAll()
        popupProtectionIsActive = false
        subtitles.shutdown()
        statusItem.remove()
        lastAppearance = nil
        if application.activationPolicy != originalActivationPolicy {
            _ = application.setActivationPolicy(originalActivationPolicy)
        }
        isEnabled = false
        recordingObserver = nil
        observers.removeAll()
        // Keep the preference for the next launch; never persist runtime locks.
    }

    private var appearance: FullScreenStatusAppearance {
        let state = recording.state()
        return FullScreenStatusAppearance(hasActiveSession: state.hasActiveSession, isPaused: state.isPaused)
    }

    func item(for action: FullScreenMenuAction) -> NSMenuItem? {
        menu.items.first { $0.identifier?.rawValue == action.rawValue }
    }

    func refresh() {
        guard !terminated else { return }
        let state = recording.state()
        item(for: .showMainWindow)?.title = "显示主窗口"
        item(for: .toggleSubtitles)?.title = subtitles.isVisible ? "隐藏浮动字幕" : "显示浮动字幕"
        item(for: .toggleSubtitles)?.state = subtitles.isVisible ? .on : .off
        item(for: .toggleLock)?.title = subtitles.isLocked ? "解锁浮动字幕" : "锁定浮动字幕"
        item(for: .toggleLock)?.state = subtitles.isLocked ? .on : .off
        item(for: .moveSubtitlesToBottom)?.title = "浮动字幕移到屏幕底部"
        item(for: .toggleRecording)?.title = state.actionTitle
        item(for: .toggleRecording)?.isEnabled = state.canToggle
        item(for: .disableMode)?.title = "关闭全屏网课模式"
        item(for: .disableMode)?.isEnabled = isEnabled
        item(for: .quit)?.title = "退出 LiveLingo"
        let currentAppearance = appearance
        if isEnabled && currentAppearance != lastAppearance {
            statusItem.update(appearance: currentAppearance)
            lastAppearance = currentAppearance
        }
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = FullScreenMenuAction(rawValue: raw) else { return }
        perform(action)
    }

    func perform(_ action: FullScreenMenuAction) {
        guard !terminated else { return }
        switch action {
        case .showMainWindow:
            needsMainWindow = registeredMainWindow == nil
            application.showMainWindow()
            application.activate()
        case .toggleSubtitles:
            if subtitles.isVisible { subtitles.hide() }
            else if let model { subtitles.show(model: model) }
        case .toggleLock: subtitles.toggleLock()
        case .moveSubtitlesToBottom:
            subtitles.moveToScreenBottom()
            if let model { subtitles.show(model: model) }
        case .toggleRecording:
            if recording.state().canToggle { recording.toggle() }
        case .disableMode: setEnabled(false)
        case .quit: application.requestTermination()
        }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard !terminated else { return }
        refresh()
        nativePopupChanged(menu, open: true)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard !terminated else { return }
        nativePopupChanged(menu, open: false)
    }

    private func nativePopupChanged(_ popup: AnyObject, open: Bool) {
        guard !terminated else { return }
        let identity = ObjectIdentifier(popup)
        if open { openNativePopups.insert(identity) }
        else { openNativePopups.remove(identity) }
        updatePopupProtection()
    }

    func setPresentedPopup(_ identity: UUID, isPresented: Bool) {
        guard !terminated else { return }
        if isPresented { openPresentedPopups.insert(identity) }
        else { openPresentedPopups.remove(identity) }
        updatePopupProtection()
    }

    private func updatePopupProtection() {
        let open = !openNativePopups.isEmpty || !openPresentedPopups.isEmpty
        guard open != popupProtectionIsActive else { return }
        popupProtectionIsActive = open
        subtitles.setPopupIsOpen(open)
    }
}

/// SwiftUI can use a private popup window instead of NSPopover. Protect all
/// explicit popover content lifetimes as well as native tracking notifications.
@MainActor
private struct FullScreenPopoverProtection: ViewModifier {
    @State private var identity = UUID()
    let controller: FullScreenClassModeController
    func body(content: Content) -> some View {
        content.onAppear { controller.setPresentedPopup(identity, isPresented: true) }
            .onDisappear { controller.setPresentedPopup(identity, isPresented: false) }
    }
}

extension View {
    @MainActor
    func protectFullScreenPopover() -> some View {
        modifier(FullScreenPopoverProtection(controller: .shared))
    }

    @MainActor
    func protectFullScreenPopup(isPresented: Bool) -> some View {
        modifier(FullScreenPresentedPopupProtection(isPresented: isPresented, controller: .shared))
    }
}

@MainActor
private struct FullScreenPresentedPopupProtection: ViewModifier {
    @State private var identity = UUID()
    let isPresented: Bool
    let controller: FullScreenClassModeController
    func body(content: Content) -> some View {
        content.onChange(of: isPresented, initial: true) { _, open in
            controller.setPresentedPopup(identity, isPresented: open)
        }.onDisappear { controller.setPresentedPopup(identity, isPresented: false) }
    }
}

/// Register only the classroom window, never Settings or the subtitle panel.
struct FullScreenMainWindowBridge: NSViewRepresentable {
    let controller: FullScreenClassModeController
    var reopen: () -> Void

    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.controller = controller
        view.reopen = reopen
        return view
    }

    func updateNSView(_ view: RegistrationView, context: Context) {
        view.controller = controller
        view.reopen = reopen
        view.register()
    }

    final class RegistrationView: NSView {
        weak var controller: FullScreenClassModeController?
        var reopen: () -> Void = {}
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); register() }
        func register() {
            if let window { controller?.registerMainWindow(window, reopen: reopen) }
        }
    }
}

struct FullScreenMainWindowRegistration: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        FullScreenMainWindowBridge(controller: .shared, reopen: { openWindow(id: "classroom") })
            .frame(width: 0, height: 0)
    }
}

struct FullScreenClassModeSettings: View {
    var controller: FullScreenClassModeController?
    var body: some View {
        if let controller { Control(controller: controller) }
        else { Toggle("全屏网课模式", isOn: .constant(false)).disabled(true) }
        Text(FullScreenClassModeController.explanation)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private struct Control: View {
        @ObservedObject var controller: FullScreenClassModeController
        var body: some View {
            Toggle("全屏网课模式", isOn: controller.binding)
                .accessibilityIdentifier("floating-fullscreen-class-mode")
            if let error = controller.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
        }
    }
}

struct FullScreenClassModeMenuItem: View {
    @ObservedObject var controller: FullScreenClassModeController
    var body: some View { Button(controller.actionTitle) { controller.toggle() } }
}
#endif
