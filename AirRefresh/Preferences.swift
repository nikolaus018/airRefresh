import Foundation
import Observation
import ServiceManagement
import AppKit
import UserNotifications

/// User-facing settings, persisted to UserDefaults as they change.
@MainActor
@Observable
final class Preferences {

    /// Refresh a project automatically once its profile has this many days left.
    var refreshWhenDaysRemaining: Int {
        didSet { store(refreshWhenDaysRemaining, "refreshWhenDaysRemaining") }
    }

    var automaticRefreshEnabled: Bool {
        didSet { store(automaticRefreshEnabled, "automaticRefreshEnabled") }
    }

    /// Wait for the Mac to be unattended rather than interrupting the user.
    var onlyWhenIdle: Bool {
        didSet { store(onlyWhenIdle, "onlyWhenIdle") }
    }

    var idleMinutes: Int {
        didSet { store(idleMinutes, "idleMinutes") }
    }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, !isApplyingLoginItem else { return }
            applyLoginItem()
        }
    }

    /// Menu bar only — no Dock icon, no app switcher entry.
    var menuBarOnly: Bool {
        didSet {
            store(menuBarOnly, "menuBarOnly")
            applyActivationPolicy()
        }
    }

    var notifyOnCompletion: Bool {
        didSet {
            store(notifyOnCompletion, "notifyOnCompletion")
            // Asking only at launch would leave anyone who turns this on later
            // with a switch that is on and does nothing.
            if notifyOnCompletion, !oldValue {
                requestNotificationAuthorization()
            } else if !notifyOnCompletion {
                notificationsDenied = false
            }
        }
    }

    /// macOS said no. The switch stays where the user put it, but the settings
    /// pane says so out loud rather than leaving a toggle that is on and inert.
    private(set) var notificationsDenied = false

    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            Task { @MainActor in self.notificationsDenied = !granted }
        }
    }

    /// Re-reads Notification Centre, which the user can change behind our back.
    func refreshNotificationAuthorization() {
        guard notifyOnCompletion else {
            notificationsDenied = false
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            // `UNNotificationSettings` is not Sendable; the one bit we want is.
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in self.notificationsDenied = denied }
        }
    }

    private(set) var loginItemProblem: String?

    private let defaults = UserDefaults.standard
    /// `applyLoginItem` writes `launchAtLogin` back when macOS refuses, which
    /// would re-enter this didSet. One flag is cheaper than untangling that.
    private var isApplyingLoginItem = false

    init() {
        defaults.register(defaults: [
            "refreshWhenDaysRemaining": 2,
            "automaticRefreshEnabled": true,
            "onlyWhenIdle": true,
            "idleMinutes": 5,
            "menuBarOnly": false,
            "notifyOnCompletion": true
        ])
        refreshWhenDaysRemaining = defaults.integer(forKey: "refreshWhenDaysRemaining")
        automaticRefreshEnabled = defaults.bool(forKey: "automaticRefreshEnabled")
        onlyWhenIdle = defaults.bool(forKey: "onlyWhenIdle")
        idleMinutes = defaults.integer(forKey: "idleMinutes")
        menuBarOnly = defaults.bool(forKey: "menuBarOnly")
        notifyOnCompletion = defaults.bool(forKey: "notifyOnCompletion")
        // The real source of truth lives with launchd, not with us.
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - System integration

    private func applyLoginItem() {
        isApplyingLoginItem = true
        defer { isApplyingLoginItem = false }
        loginItemProblem = nil
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemProblem = "macOS refused to change the login item: \(error.localizedDescription). "
                             + "This usually means the app is not in /Applications yet."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
        if !menuBarOnly {
            NSApp.activate(ignoringOtherApps: false)
        }
    }

    /// Re-reads the login item state, which the user can change in System Settings.
    func refreshLoginItemStatus() {
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != launchAtLogin { launchAtLogin = enabled }
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
