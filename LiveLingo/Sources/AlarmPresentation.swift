#if !LIVELINGO_CLI
import AppKit
import Combine
import QuartzCore
import SwiftUI
import UserNotifications

/// App activation and nonactivating subtitle-panel key focus are separate.
/// Observe only local AppKit notifications; never monitor another app's keys.
@MainActor
final class AlarmKeyboardFocus: ObservableObject {
    @Published private(set) var hasKeyboardFocus: Bool
    private let readFocus: @MainActor () -> Bool
    private var subscription: AnyCancellable?

    nonisolated static func ownsKeyboard(applicationActive: Bool, keyWindowIsKey: Bool,
                                         keyWindowIsNonactivatingPanel: Bool) -> Bool {
        applicationActive || (keyWindowIsKey && keyWindowIsNonactivatingPanel)
    }

    init(center: NotificationCenter = .default, readFocus: @escaping @MainActor () -> Bool = {
        let app = NSApplication.shared
        let window = app.keyWindow
        return AlarmKeyboardFocus.ownsKeyboard(applicationActive: app.isActive,
            keyWindowIsKey: window?.isKeyWindow == true,
            keyWindowIsNonactivatingPanel: (window as? NSPanel)?.styleMask.contains(.nonactivatingPanel) == true)
    }) {
        self.readFocus = readFocus
        hasKeyboardFocus = readFocus()
        let events = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        subscription = Publishers.MergeMany(events.map { center.publisher(for: $0) }).sink { [weak self] event in
            let becameInactive = event.name == NSApplication.didResignActiveNotification
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A normal key window can remain remembered after deactivation.
                self.hasKeyboardFocus = becameInactive ? false : self.readFocus()
            }
        }
    }
}

struct AlarmBanner: View {
    let state: AlarmBannerState
    let dismiss: () -> Void
    var compact = false
    var keyboardFocusOverride: Bool?
    @StateObject private var keyboardFocus = AlarmKeyboardFocus()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.red).font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.title).font(.system(size: compact ? 14 : 16, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(state.detail).font(.system(size: compact ? 12 : 14))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Button(action: dismiss) {
                VStack(spacing: 2) {
                    Text(state.buttonTitle).font(.system(size: compact ? 15 : 17, weight: .semibold))
                        .monospacedDigit()
                    Text(state.buttonDetail(hasKeyboardFocus: keyboardFocusOverride ?? keyboardFocus.hasKeyboardFocus))
                        .font(.system(size: compact ? 11 : 12))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
                .buttonStyle(AlarmActionButtonStyle()).controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(state.buttonTitle)
                .accessibilityHint(state.accessibilityHint)
                .accessibilityIdentifier("alarm-dismiss")
        }
        .foregroundStyle(Color.primary)
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) { Rectangle().fill(Color.red).frame(width: 4) }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("alarm-banner")
    }
}

/// Native prominent buttons become gray in a nonactivating panel. Keep this
/// action visible while slides/browser own activation and keyboard focus.
private struct AlarmActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.78, green: 0.08, blue: 0.12).opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Non-activating, non-key, click-through windows on every connected display.
@MainActor
final class AlarmReminderPresenter: NSObject, UNUserNotificationCenterDelegate {
    private(set) var panels: [NSPanel] = []
    private var screenObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?
    private var escapeMonitor: Any?
    private var subtitleVisibilitySubscription: AnyCancellable?
    private var dismissAction: (() -> Void)?
    private var requestingPermission = false
    private var notificationSent = false
    private var notificationBody = AlarmPolicy.notification
    private weak var subtitleController: FloatingSubtitleWindowController?
    private let notificationID = "LiveLingo.AlarmReminder"
    private var visible = false
    private var presentationID = UUID()
    var reduceMotionOverride: Bool?
    var reducedMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(dismiss: @escaping () -> Void, notifications: Bool = true, announce: Bool = true,
              notificationBody: String = AlarmPolicy.notification,
              subtitles: FloatingSubtitleWindowController = .shared) {
        dismissAction = dismiss
        presentationID = UUID()
        self.notificationBody = notificationBody
        subtitleController = subtitles
        notificationSent = false
        visible = true
        rebuildPanels()
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.rebuildPanels() } }
            motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) {
                [weak self] _ in Task { @MainActor in self?.rebuildPanels() }
            }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    self?.handleEscape(event) ?? false
                }
                return handled ? nil : event
            }
        }
        if announce {
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                userInfo: [.announcement: notificationBody,
                           .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        subtitleVisibilitySubscription?.cancel()
        if notifications {
            subtitleVisibilitySubscription = subtitles.$isVisible.removeDuplicates().sink { [weak self] isVisible in
                // Use the emitted value: @Published sends it before its getter changes.
                self?.subtitleVisibilityChanged(isVisible)
            }
        }
    }

    /// Only events delivered to this app are eligible; no global key monitor or
    /// accessibility permission is needed. A clicked subtitle banner may be key.
    @discardableResult
    func handleEscape(_ event: NSEvent) -> Bool {
        guard visible, event.keyCode == 53, event.window != nil else { return false }
        dismissAction?()
        return true
    }

    private func subtitleVisibilityChanged(_ isVisible: Bool) {
        guard visible else { return }
        if isVisible {
            removeNotifications()
            return
        }
        guard !notificationSent, !requestingPermission else { return }
        #if DEBUG
        if let requestNotificationForTesting {
            notificationSent = true
            requestNotificationForTesting(notificationBody)
            return
        }
        #endif
        guard !AppRuntimeEnvironment.isUnitTesting else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        requestingPermission = true
        let identity = presentationID
        Task { @MainActor [weak self] in
            var settings = await center.notificationSettings()
            guard let self else { return }
            defer {
                requestingPermission = false
                if presentationID != identity, visible {
                    subtitleVisibilityChanged(subtitleController?.isVisible ?? true)
                }
            }
            guard visible, presentationID == identity, subtitleController?.isVisible == false else { return }
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
                  visible, presentationID == identity, !notificationSent,
                  subtitleController?.isVisible == false else { return }
            let content = UNMutableNotificationContent()
            content.title = "检测到警报声"
            content.body = notificationBody
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: notificationID, content: content, trigger: nil))
                guard presentationID == identity else { removeNotifications(); return }
                notificationSent = true
                if !visible || subtitleController?.isVisible == true { removeNotifications() }
            } catch { /* A denied/unavailable notification never blocks recording. */ }
        }
    }

    #if DEBUG
    var requestNotificationForTesting: ((String) -> Void)?
    #endif

    private func removeNotifications() {
        guard !AppRuntimeEnvironment.isUnitTesting else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [notificationID])
    }

    func hide() {
        visible = false
        presentationID = UUID()
        dismissAction = nil
        panels.forEach { $0.orderOut(nil) }; panels.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
        screenObserver = nil; motionObserver = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        subtitleVisibilitySubscription?.cancel(); subtitleVisibilitySubscription = nil
        removeNotifications()
    }

    private func rebuildPanels() {
        guard visible else { return }
        panels.forEach { $0.orderOut(nil) }; panels.removeAll()
        for screen in NSScreen.screens {
            let panel = AlarmBorderPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.contentView = AlarmBorderView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                                reducedMotion: reducedMotion)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run {
            visible && subtitleController?.isVisible == false ? [.banner, .sound] : []
        }
    }
}

private final class AlarmBorderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AlarmBorderView: NSView {
    init(frame: NSRect, reducedMotion: Bool) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderColor = NSColor.systemRed.cgColor
        layer?.borderWidth = 6
        layer?.cornerRadius = 12
        layer?.opacity = reducedMotion ? 0.9 : 0.55
        if !reducedMotion {
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = 0.5; breath.toValue = 0.95
            breath.duration = AlarmPolicy.breathingPeriod / 2
            breath.autoreverses = true; breath.repeatCount = .infinity
            breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(breath, forKey: "alarm-breath")
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#endif
