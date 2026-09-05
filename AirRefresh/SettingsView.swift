import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState

    private var preferences: Preferences { state.preferences }

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            automatic.tabItem { Label("Automatic", systemImage: "clock.arrow.2.circlepath") }
        }
        // Width is fixed the way a settings window's is; height is a floor, not
        // a ceiling, so the "Right now" list can grow to three projects without
        // the last one being clipped off the bottom.
        .frame(width: 540)
        .frame(minHeight: 420)
        .task {
            preferences.refreshLoginItemStatus()
            preferences.refreshNotificationAuthorization()
            state.scheduler.evaluateNow()
        }
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section {
                Toggle("Start AirRefresh at login", isOn: bind(\.launchAtLogin))
                Toggle("Keep in the menu bar only (no Dock icon)", isOn: bind(\.menuBarOnly))
                Toggle("Notify me when an automatic refresh finishes", isOn: bind(\.notifyOnCompletion))
            } footer: {
                Text("Closing the window leaves AirRefresh running in the menu bar. Quit from the menu bar icon to stop it entirely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let problem = preferences.loginItemProblem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }

            if preferences.notificationsDenied {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Notifications are turned off for AirRefresh in System Settings, so this switch cannot do anything yet.")
                                .foregroundStyle(.orange)
                            Button("Open Notification Settings") {
                                let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
                                NSWorkspace.shared.open(url)
                            }
                            .buttonStyle(.link)
                        }
                    } icon: {
                        Image(systemName: "bell.slash")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
            }

            Section {
                LabeledContent("Version", value: Self.versionString)
                LabeledContent("Profile backups") {
                    Button("Show in Finder") {
                        let root = SigningReset.backupRoot
                        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(root)
                    }
                    .buttonStyle(.link)
                }
            } footer: {
                Text("Provisioning profiles are moved into that folder, never deleted. If a refresh ever makes things worse, move them back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }

    // MARK: - Automatic

    private var automatic: some View {
        Form {
            Section {
                Toggle("Refresh projects automatically", isOn: bind(\.automaticRefreshEnabled))

                Stepper(value: bind(\.refreshWhenDaysRemaining), in: 1...6) {
                    HStack {
                        Text("Refresh when signing has")
                        Text("\(preferences.refreshWhenDaysRemaining) day\(preferences.refreshWhenDaysRemaining == 1 ? "" : "s")")
                            .monospacedDigit()
                            .fontWeight(.medium)
                        Text("left")
                    }
                }
                .disabled(!preferences.automaticRefreshEnabled)

                Toggle("Only while the Mac is idle", isOn: bind(\.onlyWhenIdle))
                    .disabled(!preferences.automaticRefreshEnabled)

                Stepper(value: bind(\.idleMinutes), in: 1...60) {
                    HStack {
                        Text("Idle for at least")
                        Text("\(preferences.idleMinutes) min")
                            .monospacedDigit()
                            .fontWeight(.medium)
                    }
                }
                .disabled(!preferences.automaticRefreshEnabled || !preferences.onlyWhenIdle)
            } header: {
                Text("Schedule")
            } footer: {
                Text("""
                     A free Apple ID signs apps for 7 days. AirRefresh watches the real expiry date \
                     of each profile and re-signs before it runs out, picking a moment when you are \
                     away from the Mac and the phone is reachable. On the last day it stops waiting \
                     for a quiet moment and just does it.

                     A project is left alone until you have refreshed it by hand once — automation \
                     never runs something that has not been proven to work.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Right now") {
                ForEach(state.slots) { slot in
                    if slot.isConfigured {
                        LabeledContent(slot.displayName) {
                            Text(state.scheduler.explanation(for: slot))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if state.readySlots.isEmpty {
                    Text("No projects set up yet.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Preferences is a reference type outside the view's own state, so its
    /// toggles need bindings built by hand.
    private func bind<Value>(_ keyPath: ReferenceWritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { preferences[keyPath: keyPath] = $0 }
        )
    }
}
