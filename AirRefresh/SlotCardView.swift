import SwiftUI

struct SlotCardView: View {
    @Bindable var state: AppState
    /// Addressed by identity, never by position. A slot can be removed while
    /// SwiftUI still holds this view, and an index-based binding would then
    /// read past the end of the array — a crash, not a glitch.
    let slotID: UUID
    let position: Int

    @State private var showLog = false
    @State private var showAdvanced = false
    @State private var isRenaming = false
    @State private var isDropTargeted = false
    @FocusState private var renameFocused: Bool

    private var slot: ProjectSlot { state.slots.first { $0.id == slotID } ?? ProjectSlot() }
    private var runner: SlotRunner { state.runner(for: slotID) }
    private var stillExists: Bool { state.slots.contains { $0.id == slotID } }

    /// A binding that finds its slot by id on every read and write.
    private func field<Value>(_ keyPath: WritableKeyPath<ProjectSlot, Value>,
                              default fallback: Value) -> Binding<Value> {
        Binding(
            get: { state.slots.first { $0.id == slotID }?[keyPath: keyPath] ?? fallback },
            set: { newValue in
                guard let index = state.slots.firstIndex(where: { $0.id == slotID }) else { return }
                state.slots[index][keyPath: keyPath] = newValue
            }
        )
    }

    var body: some View {
        if stillExists { card }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleRow
            Divider()
            if slot.projectPath.isEmpty {
                emptyState
            } else {
                if case .failed(let message) = runner.phase {
                    failureBanner(message)
                }
                pathRow
                settingsRow
                automationRow
                if let problem = ipaProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else if let problem = state.schemeError(for: slot) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else if let hint = slot.configurationHint {
                    Label(hint, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                advancedSection
                logSection
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(runner.isRunning ? Color.accentColor.opacity(0.6)
                                               : Color(nsColor: .separatorColor))
        )
    }

    // MARK: - Rows

    private var titleRow: some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint))

            title

            // "Idle" is not news. A slot that has not run this launch says
            // everything it needs to through the expiry pill next to it.
            if runner.phase != .idle { StatusPill(phase: runner.phase) }
            if slot.isConfigured { ExpiryPill(slot: slot, threshold: state.preferences.refreshWhenDaysRemaining) }

            Spacer()

            if runner.isRunning {
                ProgressView().controlSize(.small)
                Button(role: .destructive) { runner.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .accessibilityLabel("Stop refreshing \(slot.displayName)")
                .help("Stop this refresh. Nothing already installed on the iPhone is undone.")
            } else if !slot.projectPath.isEmpty {
                // An empty slot has nothing to refresh; its one action is the
                // Choose Project button in the drop zone below.
                // One button: reset signing, rebuild, reinstall, relaunch.
                Button {
                    showLog = true
                    state.resync(slot)
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                        .frame(minWidth: 74)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Refresh \(slot.displayName)")
                .disabled(!slot.isConfigured || state.isAnyRunning)
                .help(slot.isIPA
                      ? "Fetch a fresh profile, re-sign the .ipa, reinstall and relaunch on \(slot.deviceName.isEmpty ? "the device" : slot.deviceName)."
                      : "Reset signing, rebuild, reinstall and relaunch on \(slot.deviceName.isEmpty ? "the device" : slot.deviceName).")
                .keyboardShortcut(shortcutKey, modifiers: [.command])
            }

            Menu {
                Button("Rename") { beginRenaming() }
                Button("Clear Log") { runner.clearLog() }
                    .disabled(runner.isRunning || runner.lines.isEmpty)
                Button(slot.isIPA ? "Reveal .ipa in Finder" : "Reveal Project in Finder") {
                    guard !slot.projectPath.isEmpty else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: slot.projectPath)])
                }
                .disabled(slot.projectPath.isEmpty)
                Divider()
                Button("Remove Project", role: .destructive) { state.removeSlot(slot) }
                    .disabled(runner.isRunning)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .accessibilityLabel("More actions for \(slot.displayName)")
            .help("More actions for this project")
        }
    }

    /// A label until you ask for a field.
    ///
    /// This used to be a permanently live `TextField`, which made it the
    /// window's first responder: opening AirRefresh greeted you with your
    /// project's name selected, one keystroke from being replaced.
    private var title: some View {
        Group {
            if isRenaming {
                TextField("Project name", text: field(\.name, default: ""), prompt: Text(slot.displayName))
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFocused)
                    .onSubmit { endRenaming() }
                    .onExitCommand { endRenaming() }
                    .onChange(of: renameFocused) { if !renameFocused { isRenaming = false } }
                    .frame(width: 220)
            } else {
                // Capped, but only as wide as the name itself. A plain
                // `maxWidth` frame always took the full 220pt, which left
                // short names like "Budget" with their pills floating off to
                // the right.
                Text(slot.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 220, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginRenaming() }
                    .help("Double-click to rename. Leave it empty to use the project file's own name.")
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .accessibilityLabel("Project name")
    }

    private func beginRenaming() {
        isRenaming = true
        // The field has to exist before it can take focus.
        DispatchQueue.main.async { renameFocused = true }
    }

    private func endRenaming() {
        renameFocused = false
        isRenaming = false
    }

    private var shortcutKey: KeyEquivalent {
        switch position {
        case 1: return "1"
        case 2: return "2"
        default: return "3"
        }
    }

    private var pathRow: some View {
        HStack(spacing: 8) {
            Image(systemName: slot.isIPA ? "shippingbox" : slot.isWorkspace ? "square.stack.3d.up" : "hammer")
                .foregroundStyle(.secondary)
            Text(slot.projectPath.isEmpty ? "No project selected" : abbreviate(slot.projectPath))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(slot.projectPath.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer()
            Button("Change…") {
                guard let path = ProjectPicker.choose() else { return }
                Task { await state.setProjectPath(path, for: slot) }
            }
            .disabled(runner.isRunning)
            .accessibilityLabel("Choose a different project or .ipa")
            .help("Pick a different .xcodeproj, .xcworkspace or .ipa for this slot.")
        }
    }

    /// What an empty slot is for: getting a project into it. Everything else
    /// on a card — scheme, device, automation, a disabled Refresh — is noise
    /// until there is a project to apply it to.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "hammer.circle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            Text("Drop an Xcode project or .ipa here")
                .font(.headline)
            Text("An .xcodeproj, .xcworkspace or .ipa, or the folder that holds one.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Choose Project…") {
                guard let path = ProjectPicker.choose() else { return }
                Task { await state.setProjectPath(path, for: slot) }
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                              style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 4]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, let path = ProjectPicker.resolve(url) else { return false }
            Task { await state.setProjectPath(path, for: slot) }
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    /// The reason a run failed, and what to do about it, where you are already
    /// looking. The status pill only had room for "Failed"; the rest was in a
    /// tooltip and at the bottom of a collapsed log.
    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.callout.weight(.semibold))
                ForEach(runner.hints, id: \.self) { hint in
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 8)
            if !showLog {
                Button("Show Log") { showLog = true }
                    .buttonStyle(.link)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.red.opacity(0.3))
        )
        .accessibilityElement(children: .combine)
    }

    private var settingsRow: some View {
        HStack(spacing: 12) {
            if slot.isIPA {
                ipaFields
            } else {
                schemeField
            }

            LabeledField(label: "iPhone") {
                Picker("", selection: deviceSelection) {
                    // A remembered device that is not currently reachable still
                    // needs a row, or the picker would silently reset itself.
                    if state.devices.device(withIdentifier: slot.deviceIdentifier) == nil {
                        Text(slot.deviceName.isEmpty ? "Choose a device…" : "\(slot.deviceName) (not reachable)")
                            .tag(slot.deviceIdentifier)
                    }
                    ForEach(state.devices.devices) { device in
                        Text("\(device.name) — \(device.subtitle)").tag(device.identifier)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 240)
                .accessibilityLabel("iPhone")
            }
            Spacer()
        }
        .disabled(runner.isRunning)
    }

    /// An `.ipa` has no scheme. What it needs instead is a team to sign for,
    /// and — because a free Apple ID cannot register a bundle id another
    /// developer owns — usually a bundle id of its own.
    @ViewBuilder
    private var ipaFields: some View {
        LabeledField(label: "Team") {
            HStack(spacing: 6) {
                Picker("", selection: field(\.teamID, default: "")) {
                    if state.team(withID: slot.teamID) == nil {
                        Text(slot.teamID.isEmpty ? "Choose a team…" : slot.teamID).tag(slot.teamID)
                    }
                    ForEach(state.teams) { team in
                        Text(team.label).tag(team.id)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 180)
                .accessibilityLabel("Signing team")
                Button {
                    Task { await state.refreshTeams() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reload teams")
                .help("Re-read the teams of the Apple IDs signed in to Xcode.")
            }
        }

        LabeledField(label: "Bundle ID") {
            TextField("", text: field(\.bundleIDOverride, default: ""),
                      prompt: Text(slot.sourceBundleIdentifier.isEmpty ? "Same as the .ipa"
                                                                        : slot.sourceBundleIdentifier))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 200)
                .accessibilityLabel("Bundle ID to sign as")
                .help("Leave empty to keep the .ipa's own bundle ID. A free Apple ID cannot use an ID "
                      + "another developer registered, so for someone else's app pick your own, "
                      + "e.g. com.yourname.appname.")
        }
    }

    /// Why an `.ipa` slot cannot run yet, when it is something to fix rather
    /// than a field still to fill in.
    private var ipaProblem: String? {
        guard slot.isIPA else { return nil }
        let override = slot.bundleIDOverride.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty, !IPASigning.isValidBundleID(override) {
            return "“\(override)” is not a valid bundle ID — letters, digits, hyphens and dots, like com.yourname.app."
        }
        if slot.teamID.isEmpty, state.teams.isEmpty {
            return "No signing team found. Sign in with your Apple ID in Xcode ▸ Settings ▸ Accounts, then reload teams."
        }
        return nil
    }

    private var schemeField: some View {
            LabeledField(label: "Scheme") {
                HStack(spacing: 6) {
                    Picker("", selection: field(\.scheme, default: "")) {
                        // Only stand in for the current value when the real list
                        // does not contain it — duplicate tags confuse Picker.
                        // And only call it missing once the list has actually
                        // been read: on launch every card briefly claimed its
                        // perfectly good scheme was "not in project".
                        if !state.schemes(for: slot).contains(slot.scheme) {
                            Text(slot.scheme.isEmpty ? "—"
                                 : state.hasLoadedSchemes(slot) ? "\(slot.scheme) (not in project)"
                                 : slot.scheme)
                                .tag(slot.scheme)
                        }
                        ForEach(state.schemes(for: slot), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Scheme")
                    if state.isLoadingSchemes(slot) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Reading schemes")
                    } else {
                        Button {
                            Task { await state.loadSchemes(for: slot) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(slot.projectPath.isEmpty)
                        .accessibilityLabel("Reload schemes")
                        .help("Re-read the scheme list from the project.")
                    }
                }
            }
    }

    private var deviceSelection: Binding<String> {
        Binding(
            get: { slot.deviceIdentifier },
            set: { identifier in
                guard let device = state.devices.device(withIdentifier: identifier) else { return }
                state.apply(device: device, toSlotWithID: slotID)
            }
        )
    }

    private var automationRow: some View {
        HStack(spacing: 8) {
            Toggle("Keep this signed automatically", isOn: field(\.autoRefresh, default: true))
                .toggleStyle(.checkbox)
                .disabled(runner.isRunning)
            if slot.isConfigured {
                Text("· \(state.scheduler.explanation(for: slot))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            HStack(spacing: 18) {
                Toggle("Reset signing before building", isOn: field(\.resetSigning, default: true))
                Toggle("Clean build", isOn: field(\.cleanBuild, default: false))
                Toggle("Launch after install", isOn: field(\.launchAfterInstall, default: true))
                Spacer()
                // An .ipa is already built; there is no configuration to pick.
                if !slot.isIPA {
                    LabeledField(label: "Configuration") {
                        Picker("", selection: field(\.configuration, default: "Debug")) {
                            Text("Debug").tag("Debug")
                            Text("Release").tag("Release")
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .disabled(runner.isRunning)
            .padding(.top, 6)
        } label: {
            Text("Advanced")
                .font(.callout.weight(.medium))
        }
    }

    private var logSection: some View {
        DisclosureGroup(isExpanded: $showLog) {
            VStack(alignment: .leading, spacing: 6) {
                LogView(lines: runner.lines)
                    .frame(height: 220)
                HStack {
                    Text("\(runner.lines.count) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Log") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(runner.plainLog, forType: .string)
                    }
                    .buttonStyle(.link)
                    .disabled(runner.lines.isEmpty)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Log")
                .font(.callout.weight(.medium))
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
    }
}

/// How much life the signing profile has left.
struct ExpiryPill: View {
    let slot: ProjectSlot
    let threshold: Int

    var body: some View {
        Label(slot.expiryDescription, systemImage: icon)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .help(slot.expiryDetail ?? "No provisioning profile for this app has been found yet.")
            .accessibilityLabel("Signing: \(slot.expiryDescription)")
    }

    private var icon: String {
        guard let days = slot.daysUntilExpiry else { return "questionmark.circle" }
        if slot.hasExpired { return "xmark.seal.fill" }
        return days <= threshold ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
    }

    private var color: Color {
        guard let days = slot.daysUntilExpiry else { return .secondary }
        if slot.hasExpired || days == 0 { return .red }
        return days <= threshold ? .orange : .green
    }
}

struct StatusPill: View {
    let phase: SyncPhase

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .help(phase.label)
            .accessibilityLabel("Status: \(phase.label)")
    }

    private var text: String {
        switch phase {
        case .succeeded(let when):
            return "Synced \(when.formatted(date: .omitted, time: .shortened))"
        case .failed:
            return "Failed"
        default:
            return phase.label
        }
    }

    private var color: Color {
        switch phase {
        case .idle: return .secondary
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        default: return .accentColor
        }
    }
}
