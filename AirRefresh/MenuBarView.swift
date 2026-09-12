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

        ForEach(state.slots) { slot in
            if slot.isConfigured {
                Button {
                    state.resync(slot)
                } label: {
                    Text("\(statusMark(slot)) \(slot.displayName) — \(subtitle(slot))")
                }
                .disabled(state.isAnyRunning)
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
        Button("Open AirRefresh") {
            openWindow(id: AirRefreshApp.mainWindowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Settings…") {
            openSettings()
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit AirRefresh") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// While a slot is running, what it is doing beats what its profile says.
    private func subtitle(_ slot: ProjectSlot) -> String {
        let runner = state.runner(for: slot.id)
        if runner.isRunning { return runner.phase.label }
        if runner.phase.isFailure { return "Failed — open AirRefresh for the log" }
        return slot.expiryDescription
    }

    private func statusMark(_ slot: ProjectSlot) -> String {
        let runner = state.runner(for: slot.id)
        if runner.isRunning { return "⟳" }
        if runner.phase.isFailure { return "⚠︎" }
        guard let days = slot.daysUntilExpiry else { return "○" }
        return days <= state.preferences.refreshWhenDaysRemaining ? "⚠︎" : "●"
    }
}
