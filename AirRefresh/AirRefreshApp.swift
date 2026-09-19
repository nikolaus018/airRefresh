import SwiftUI
import AppKit
import UserNotifications

@main
struct AirRefreshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var state: AppState { AppState.shared }

    var body: some Scene {
        Window("AirRefresh", id: Self.mainWindowID) {
            ContentView(state: state)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 900, height: 640)
        .commands { AirRefreshCommands(state: state) }

        MenuBarExtra {
            MenuBarView(state: state)
        } label: {
            Image(systemName: state.menuBarSymbol)
                .accessibilityLabel(state.menuBarAccessibilityLabel)
        }

        Settings {
            SettingsView(state: state)
        }
    }

    static let mainWindowID = "main"
}

/// The app's own menu commands. A struct of its own so it can reach
/// `openWindow`: "Reset Signing Only" shows its log in the main window, and
/// with AirRefresh living in the menu bar that window is often closed.
struct AirRefreshCommands: Commands {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Project…") {
                openWindow(id: AirRefreshApp.mainWindowID)
                Task { await state.chooseAndAddProject() }
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(!state.canAddProject)
            Divider()
            Button("Refresh All Now") { state.resyncAll() }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(state.readySlots.isEmpty || state.isAnyRunning)
            Button("Reset Signing Only…") {
                guard SigningResetPrompt.confirm() else { return }
                openWindow(id: AirRefreshApp.mainWindowID)
                state.resetSigningOnly()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(state.isAnyRunning)
            Button("Stop Everything") { state.stopAll() }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!state.isAnyRunning)
        }
    }
}

/// Keeps the app alive with its window closed — that is the whole point of
/// living in the menu bar — and starts background work exactly once.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated {
            AppState.shared.startBackgroundWork()
        }
        // Starting at login should not throw a window in the user's face. The
        // scene has not built its window yet at this point, so hide it once the
        // first run loop turn is done.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Self.hideMainWindowIfMenuBarOnly() }
        }
    }

    @MainActor
    private static func hideMainWindowIfMenuBarOnly() {
        guard AppState.shared.preferences.menuBarOnly else { return }
        for window in NSApp.windows where window.styleMask.contains(.titled) && window.isVisible {
            window.close()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon brings the window back rather than doing nothing.
    ///
    /// `NSApp.windows.first` is not the main window: the status item, the
    /// settings pane and assorted AppKit scaffolding all live in that array, and
    /// which one comes first is not ours to decide.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        MainActor.assumeIsolated {
            Self.mainWindow()?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// The app's own document-style window, told apart from the status item and
    /// the settings pane by the identifier the `Window` scene gives it.
    @MainActor
    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains(AirRefreshApp.mainWindowID) == true }
            ?? NSApp.windows.first { $0.styleMask.contains(.titled) && $0.canBecomeMain }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {

    /// Without this, an automatic refresh that finishes while AirRefresh happens
    /// to be the frontmost app posts a notification nobody ever sees — and with
    /// the window closed, "frontmost" tells the user nothing.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// Tapping the notification should land you on the log it is about.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            Self.mainWindow()?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Asks before "Reset Signing Only" archives every profile on the Mac.
///
/// Every other signing reset AirRefresh does is scoped to one app. This one
/// takes out profiles for projects AirRefresh has never heard of, and it sits
/// one modifier key away from ⌘R — so it says what it is about to do first.
@MainActor
enum SigningResetPrompt {
    static func confirm() -> Bool {
        let count = SigningReset.profileCount()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 0
            ? "There are no provisioning profiles to archive"
            : "Archive all \(count) provisioning profile\(count == 1 ? "" : "s") on this Mac?"
        alert.informativeText = count == 0
            ? "The profile folders are already empty. Xcode will fetch fresh profiles the next time you build."
            : "This includes profiles for projects AirRefresh does not manage. Xcode fetches fresh ones "
            + "the next time each project builds. Nothing is deleted: the profiles are moved to "
            + "Profile Backups, and you can move them back."
        if count == 0 {
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
        alert.addButton(withTitle: "Archive Profiles").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Opens the standard panel for picking a project, with a little leniency:
/// selecting the enclosing folder works too.
@MainActor
enum ProjectPicker {
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose an Xcode Project"
        panel.message = "Select an .xcodeproj or .xcworkspace (or the folder containing one)."
        panel.prompt = "Use Project"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return resolve(url)
    }

    /// Turns whatever the user picked — or dropped on a slot — into a project
    /// path. A folder is searched for the obvious candidate; anything else
    /// gets an explanation rather than a beep.
    static func resolve(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "xcodeproj" || ext == "xcworkspace" { return url.path }

        // A plain folder was picked — look inside for the obvious candidate.
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        if let workspace = contents.first(where: { $0.pathExtension.lowercased() == "xcworkspace" }) {
            return workspace.path
        }
        if let project = contents.first(where: { $0.pathExtension.lowercased() == "xcodeproj" }) {
            return project.path
        }

        // A beep is not an explanation.
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = isFolder
            ? "No Xcode project in “\(url.lastPathComponent)”"
            : "“\(url.lastPathComponent)” is not an Xcode project"
        alert.informativeText = (isFolder ? "That folder holds no .xcodeproj or .xcworkspace. "
                                          : "AirRefresh needs an .xcodeproj or .xcworkspace. ")
                              + "Choose the project file itself, or the folder that contains it."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return nil
    }
}
