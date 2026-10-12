#if !LIVELINGO_CLI
import AppKit
import QuartzCore
import SwiftUI
import UserNotifications


struct AlarmBanner: View {
    let state: AlarmBannerState
    let dismiss: () -> Void
    var compact = false
    var body: some View {
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
            Spacer(minLength: 8)
            Button(state.buttonTitle, action: dismiss).buttonStyle(.bordered)
                .accessibilityHint("关闭警报提醒并取消自动分段，录音继续")
                .accessibilityIdentifier("alarm-dismiss")
        }
        .foregroundStyle(Color.primary)
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) { Rectangle().fill(Color.red).frame(width: 4) }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("alarm-banner")
    }
}

/// Non-activating, non-key, click-through windows on every connected display.
@MainActor
final class AlarmReminderPresenter: NSObject, UNUserNotificationCenterDelegate {
    private(set) var panels: [NSPanel] = []
    private var screenObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?
    private var escapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var dismissAction: (() -> Void)?
    private var requestingPermission = false
    private var notificationRequested = false
    private let notificationID = "LiveLingo.AlarmReminder"
    private var visible = false
    var reduceMotionOverride: Bool?
    var reducedMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func prepareNotificationsAtRecordingStart() {
        guard !AppRuntimeEnvironment.isUnitTesting, !requestingPermission else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        requestingPermission = true
        Task { @MainActor [weak self] in
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined, self?.notificationRequested != true {
                self?.notificationRequested = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            self?.requestingPermission = false
        }
    }

    func show(dismiss: @escaping () -> Void, notifications: Bool = true, announce: Bool = true,
              notificationBody: String = AlarmPolicy.notification) {
        dismissAction = dismiss
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
                    guard event.keyCode == 53, self?.visible == true else { return false }
                    self?.dismissAction?()
                    return true
                }
                return handled ? nil : event
            }
            // AppKit only delivers keys from other apps if the user has already
            // granted accessibility access. Never request or change that permission.
            globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { Task { @MainActor in self?.dismissAction?() } }
            }
        }
        if announce {
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                userInfo: [.announcement: notificationBody,
                           .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        guard notifications, !AppRuntimeEnvironment.isUnitTesting else { return }
        let center = UNUserNotificationCenter.current()
        Task { [weak self] in
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
                  self?.visible == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "检测到警报声"
            content.body = notificationBody
            content.sound = .default
            guard let self else { return }
            try? await center.add(UNNotificationRequest(identifier: notificationID, content: content, trigger: nil))
            if !visible { center.removeDeliveredNotifications(withIdentifiers: [notificationID]) }
        }
    }

    func hide() {
        visible = false
        dismissAction = nil
        panels.forEach { $0.orderOut(nil) }; panels.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
        screenObserver = nil; motionObserver = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        escapeMonitor = nil; globalEscapeMonitor = nil
        if !AppRuntimeEnvironment.isUnitTesting {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [notificationID])
            center.removeDeliveredNotifications(withIdentifiers: [notificationID])
        }
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
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
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
