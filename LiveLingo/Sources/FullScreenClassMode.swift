#if !LIVELINGO_CLI
import AppKit
import Combine
import SwiftUI

@MainActor
struct FullScreenMainWindowSnapshot {
    var wasVisible: Bool
    var wasKey: Bool
    var restore: () -> Void
}

@MainActor
protocol FullScreenApplicationControlling: AnyObject {
    var activationPolicy: NSApplication.ActivationPolicy { get }
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool
    func mainWindowSnapshot() -> FullScreenMainWindowSnapshot
    func registerMainWindow(_ window: NSWindow, reopen: @escaping () -> Void)
    func showMainWindow()
    func activate()
    func requestTermination()
}

@MainActor
final class LiveFullScreenApplication: FullScreenApplicationControlling {
    private weak var mainWindow: NSWindow?
    private var reopen: (() -> Void)?
    var activationPolicy: NSApplication.ActivationPolicy { NSApp.activationPolicy() }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        precondition(!AppRuntimeEnvironment.isUnitTesting, "Tests must inject activation policy")
        return NSApp.setActivationPolicy(policy)
    }

    func registerMainWindow(_ window: NSWindow, reopen: @escaping () -> Void) {
        mainWindow = window
        self.reopen = reopen
    }

    func mainWindowSnapshot() -> FullScreenMainWindowSnapshot {
        let window = mainWindow
        let mainWasVisible = window?.isVisible == true
        // The mode switch normally originates in Settings. Preserve that key
        // window too, rather than making the classroom steal its focus.
        let keyWindow = NSApp.isActive ? NSApp.keyWindow : nil
        let keyWasVisible = keyWindow?.isVisible == true
        return FullScreenMainWindowSnapshot(wasVisible: mainWasVisible || keyWasVisible,
                                            wasKey: keyWindow != nil) { [weak window, weak keyWindow] in
            NSApp.unhideWithoutActivation()
            if mainWasVisible { window?.orderFrontRegardless() }
            if keyWasVisible {
                keyWindow?.orderFrontRegardless()
                keyWindow?.makeKey()
            }
        }
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
        precondition(!AppRuntimeEnvironment.isUnitTesting, "Tests must inject app activation")
        NSApp.activate(ignoringOtherApps: true)
    }

    func requestTermination() { FilePanelPresentation.requestTermination() }
}

@MainActor
protocol FullScreenSubtitleControlling: AnyObject {
    var isLocked: Bool { get }
    var isVisible: Bool { get }
    var stateChanges: AnyPublisher<Void, Never> { get }
    func setFullScreenClassMode(_ enabled: Bool)
    func setStatusMenuIsOpen(_ open: Bool)
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

    init(defaults: UserDefaults, application: any FullScreenApplicationControlling,
         statusItem: any FullScreenStatusItemPresenting, subtitles: any FullScreenSubtitleControlling,
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
        schedule { [weak self] in
            guard let self, !self.terminated, self.generation == expected else { return }
            self.application.showMainWindow()
            self.application.activate()
        }
    }

    func toggle() { setEnabled(!isEnabled) }

    func setEnabled(_ enabled: Bool, persist: Bool = true) {
        guard !terminated, enabled != isEnabled else { return }
        let snapshot = application.mainWindowSnapshot()
        if enabled && !statusItem.install(menu: menu, appearance: appearance) {
            errorMessage = "菜单栏图标未能显示，全屏网课模式未开启。"
            return
        }
        guard application.setActivationPolicy(enabled ? .accessory : .regular) else {
            if enabled { statusItem.remove() }
            errorMessage = "macOS 未能切换 App 显示方式，请重试。"
            return
        }
        generation += 1
        let expected = generation
        isEnabled = enabled
        errorMessage = nil
        subtitles.setFullScreenClassMode(enabled)
        if !enabled {
            needsMainWindow = false
            statusItem.remove()
            lastAppearance = nil
        }
        if persist { defaults.set(enabled, forKey: Self.preferenceKey) }
        // Transforming a foreground process can order its windows out later in
        // this runloop. Restore now and once more after AppKit's transformation.
        // Do not steal another app's focus when enabling from a non-key window.
        if snapshot.wasVisible { snapshot.restore() }
        if !enabled || snapshot.wasKey { application.activate() }
        schedule { [weak self] in
            guard let self, !self.terminated, self.generation == expected else { return }
            if snapshot.wasVisible { snapshot.restore() }
            if !enabled || snapshot.wasKey { self.application.activate() }
        }
        refresh()
    }

    func shutdown() {
        guard !terminated else { return }
        terminated = true
        generation += 1
        needsMainWindow = false
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
        subtitles.setStatusMenuIsOpen(true)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard !terminated else { return }
        subtitles.setStatusMenuIsOpen(false)
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
