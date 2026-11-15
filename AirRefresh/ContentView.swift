import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            slotList
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .task {
            await state.devices.refresh()
            state.autoAssignSingleDevice()
            await state.refreshTeams()
            // Three `xcodebuild -list` calls take a second each; there is no
            // reason to make the user watch them go one after another.
            await withTaskGroup(of: Void.self) { group in
                for slot in state.slots where !slot.projectPath.isEmpty && !slot.isIPA {
                    group.addTask { await state.loadSchemes(for: slot) }
                }
            }
            state.scheduler.evaluateNow()
        }
        .sheet(isPresented: $state.isShowingSigningResetLog) {
            MaintenanceSheet(runner: state.maintenance) { state.isShowingSigningResetLog = false }
        }
    }

    // MARK: - Header

    /// The window's title bar already says "AirRefresh". The header's job is to
    /// answer the only question the app exists to answer — how much life is left
    /// in your signing — so that is what it says, in the largest type on screen.
    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: healthSymbol)
                    .font(.system(size: 20))
                    .foregroundStyle(healthColor)
                    .accessibilityHidden(true)
                Text(state.healthSummary)
                    .font(.system(size: 19, weight: .semibold))
                    // Only trouble is coloured. Painting the good news green
                    // too would spend the one bit of attention colour buys.
                    .foregroundStyle(healthColor == .orange || healthColor == .red
                                     ? healthColor : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 12)
                controls
            }
            deviceBar
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.bar)
    }

    private var healthSymbol: String {
        if state.readySlots.isEmpty { return "arrow.triangle.2.circlepath.circle.fill" }
        if state.readySlots.contains(where: \.hasExpired) { return "xmark.seal.fill" }
        return state.slotsNeedingAttention.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
    }

    private var healthColor: Color {
        if state.readySlots.isEmpty { return .secondary }
        if state.readySlots.contains(where: \.hasExpired) { return .red }
        return state.slotsNeedingAttention.isEmpty ? .green : .orange
    }

    private var controls: some View {
        HStack(spacing: 8) {
            // With one project set up there is nothing to refresh "all" of, and
            // two prominent blue buttons doing the same thing is one too many.
            if state.readySlots.count > 1 {
                Button {
                    state.resyncAll()
                } label: {
                    Label("Refresh All", systemImage: "bolt.horizontal.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Refresh all projects")
                .disabled(state.isAnyRunning)
                .help("Re-sign, rebuild and reinstall every configured project, one after another.")
            }

            if state.isAnyRunning {
                Button(role: .destructive) {
                    state.stopAll()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .accessibilityLabel("Stop everything")
            }

            Menu {
                Toggle("Refresh Automatically",
                       isOn: Binding(get: { state.preferences.automaticRefreshEnabled },
                                     set: { state.preferences.automaticRefreshEnabled = $0 }))
                Divider()
                Button("Reset Signing Only…") {
                    guard SigningResetPrompt.confirm() else { return }
                    state.resetSigningOnly()
                }
                .disabled(state.isAnyRunning)
                .help("Archive every provisioning profile without building anything.")
                Button("Open Profile Backups") {
                    // Created on demand: before the first reset there is nothing
                    // there, and opening a folder that does not exist used to be
                    // a menu item that visibly did nothing at all.
                    let root = SigningReset.backupRoot
                    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(root)
                }
                Divider()
                Button("Settings…") { openSettings() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .accessibilityLabel("More actions")
            .help("Signing tools and settings")
        }
    }

    private var deviceBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone.gen3")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if state.devices.isRefreshing {
                Text("Looking for devices…")
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            } else if state.devices.devices.isEmpty {
                Text(state.devices.lastError ?? "No devices found.")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                // One line, truncated, with the whole list in the tooltip. The
                // old version pasted every device end to end and let the window
                // decide where to cut it off.
                Text(deviceSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(state.devices.devices.map { "\($0.name) — \($0.subtitle)" }
                          .joined(separator: "\n"))
            }
            Spacer(minLength: 12)
            Button {
                Task { await state.devices.refresh() }
            } label: {
                Label("Scan Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.link)
            .disabled(state.devices.isRefreshing)
            .accessibilityLabel("Look for devices again")
            .help("Ask devicectl for the paired devices again.")
        }
        .font(.callout)
    }

    private var deviceSummary: String {
        let devices = state.devices.devices
        let names = devices.map(\.name).joined(separator: ", ")
        return devices.count == 1
            ? "\(devices[0].name) · \(devices[0].subtitle)"
            : "\(devices.count) devices: \(names)"
    }

    // MARK: - Slots

    private var slotList: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(Array(state.slots.enumerated()), id: \.element.id) { index, slot in
                    SlotCardView(state: state, slotID: slot.id, position: index + 1)
                        .id(slot.id)
                }

                // An empty card already says "drop a project here"; a second
                // button offering the same thing just below it is one too many.
                if state.slots.contains(where: { $0.projectPath.isEmpty }) {
                    EmptyView()
                } else if state.canAddSlot {
                    Button {
                        Task { await state.chooseAndAddProject() }
                    } label: {
                        Label("Add Project… (\(state.slots.count) of \(AppState.maxSlots))",
                              systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Add a project")
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first, let path = ProjectPicker.resolve(url) else { return false }
                        Task { await state.addProject(at: path) }
                        return true
                    }
                } else {
                    Text("Three is the maximum: a free Apple ID can only sign three apps at a time. Remove one to add another.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(20)
        }
    }
}

/// Log window for the standalone "Reset Signing" action.
private struct MaintenanceSheet: View {
    @Bindable var runner: SlotRunner
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lock.rotation")
                Text("Reset Signing").font(.headline)
                Spacer()
                StatusPill(phase: runner.phase)
            }
            LogView(lines: runner.lines)
                .frame(width: 640, height: 280)
            HStack {
                Text("Profiles are moved to ~/Library/Application Support/AirRefresh/ProfileBackups, never deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
