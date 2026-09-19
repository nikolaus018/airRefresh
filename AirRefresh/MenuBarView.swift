import SwiftUI

/// The dropdown behind the menu bar icon — everything you need without
/// bringing the window forward.
struct MenuBarView: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(state.healthSummary)

        Divider()

        // Each project is a submenu, not a button. As a button its row read
        // like a status line — "Budget — Expires tomorrow" — and clicking it to
        // look closer quietly re-signed, rebuilt and reinstalled the app.
        ForEach(state.slots) { slot in
            if slot.isConfigured {
                Menu {
                    Button("Refresh Now") { state.resync(slot) }
                        .disabled(state.isAnyRunning)
                    Button("Show in AirRefresh") { openMainWindow() }
                } label: {
                    Label("\(slot.displayName) — \(subtitle(slot))", systemImage: statusSymbol(slot))
                }
            }
        }

        if state.readySlots.isEmpty {
            Text("No projects set up yet")
        }

        Divider()

        Button("Refresh All Now") { state.resyncAll() }
            .disabled(state.readySlots.isEmpty || state.isAnyRunning)

        if state.isAnyRunning {
            Button("Stop") { state.stopAll() }
        }

        Toggle("Refresh Automatically",
               isOn: Binding(get: { state.preferences.automaticRefreshEnabled },
                             set: { state.preferences.automaticRefreshEnabled = $0 }))

        Divider()

        // Neither of these forces `.regular`: doing so put a Dock icon back
        // that the user had explicitly asked to be rid of, and left it there
        // until the next launch. An accessory app can show and focus a window
        // perfectly well.
        Button("Open AirRefresh") { openMainWindow() }
        Button("Settings…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit AirRefresh") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openMainWindow() {
        openWindow(id: AirRefreshApp.mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// While a slot is running, what it is doing beats what its profile says.
    private func subtitle(_ slot: ProjectSlot) -> String {
        let runner = state.runner(for: slot.id)
        if runner.isRunning { return runner.phase.label }
        if runner.phase.isFailure { return "Refresh failed" }
        return slot.expiryDescription
    }

    /// The same symbols the window uses, rather than text glyphs standing in
    /// for icons.
    private func statusSymbol(_ slot: ProjectSlot) -> String {
        let runner = state.runner(for: slot.id)
        if runner.isRunning { return "arrow.triangle.2.circlepath" }
        if runner.phase.isFailure { return "xmark.octagon" }
        if slot.hasExpired { return "xmark.seal" }
        guard let days = slot.daysUntilExpiry else { return "circle.dashed" }
        return days <= state.preferences.refreshWhenDaysRemaining ? "exclamationmark.triangle" : "checkmark.seal"
    }
}
