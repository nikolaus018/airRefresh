import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class AppState {
    /// Shared so the menu bar, the settings window and the app delegate all
    /// talk to the same state without threading it through every scene.
    static let shared = AppState()

    static let maxSlots = 3

    var slots: [ProjectSlot] = [] {
        didSet {
            save()
            ensureRunners()
        }
    }

    let devices = DeviceManager()
    let maintenance = SlotRunner(id: UUID())
    let preferences = Preferences()
    private(set) var scheduler: Scheduler!

    /// Schemes discovered per slot, keyed by slot id.
    private(set) var schemes: [UUID: [String]] = [:]
    private(set) var loadingSchemes: Set<UUID> = []
    /// Why scheme discovery failed, per slot. Without this the UI just shows an
    /// empty dropdown and the user has no idea what went wrong.
    private(set) var schemeErrors: [UUID: String] = [:]

    private var runners: [UUID: SlotRunner] = [:]
    private var batchTask: Task<Void, Never>?
    private let storageKey = "AirRefresh.slots.v1"

    init() {
        load()
        if slots.isEmpty { slots = [ProjectSlot()] }
        ensureRunners()
        scheduler = Scheduler(state: self, preferences: preferences)
        Task { await refreshExpiryFromDisk() }
    }

    /// Called once the app is up, so background work never races the UI.
    func startBackgroundWork() {
        preferences.applyActivationPolicy()
        preferences.refreshLoginItemStatus()
        requestNotificationPermissionIfNeeded()
        scheduler.start()
    }

    // MARK: - Slots

    var canAddSlot: Bool { slots.count < Self.maxSlots }

    /// Somewhere a newly picked project can go: an empty slot, or room for one.
    var canAddProject: Bool { canAddSlot || slots.contains { $0.projectPath.isEmpty } }

    /// Picks a project and puts it in the first empty slot, or a new one.
    ///
    /// "Add Project" used to append a blank card and leave you to find its
    /// Choose… button. The picker is the only thing anyone does next, so it
    /// opens straight away, and cancelling it leaves nothing behind.
    func chooseAndAddProject() async {
        guard canAddProject, let path = ProjectPicker.choose() else { return }
        await addProject(at: path)
    }

    func addProject(at path: String) async {
        if let empty = slots.first(where: { $0.projectPath.isEmpty }) {
            await setProjectPath(path, for: empty)
        } else if canAddSlot {
            let slot = ProjectSlot()
            slots.append(slot)
            await setProjectPath(path, for: slot)
        }
    }

    func removeSlot(_ slot: ProjectSlot) {
        runner(for: slot.id).stop()
        runners[slot.id] = nil
        schemes[slot.id] = nil
        schemeErrors[slot.id] = nil
        slots.removeAll { $0.id == slot.id }
        if slots.isEmpty { slots = [ProjectSlot()] }
    }

    func binding(for slot: ProjectSlot) -> Int? {
        slots.firstIndex { $0.id == slot.id }
    }

    /// Runners are created when the slot list changes, never lazily from a view
    /// body: `menuBarSymbol` and the menu both ask for one while SwiftUI is
    /// rendering, and creating it there would mutate observable state in the
    /// middle of an update.
    private func ensureRunners() {
        for slot in slots where runners[slot.id] == nil {
            _ = runner(for: slot.id)
        }
    }

    func runner(for id: UUID) -> SlotRunner {
        if let existing = runners[id] { return existing }
        let created = SlotRunner(id: id)
        created.onFinished = { [weak self] outcome, bundleID in
            self?.runDidFinish(slotID: id, outcome: outcome, bundleID: bundleID)
        }
        runners[id] = created
        return created
    }

    /// Records what a finished run taught us: the bundle id, the fresh expiry
    /// date, and whether the scheduler should back off.
    private func runDidFinish(slotID: UUID, outcome: RunOutcome, bundleID: String) {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else { return }
        if !bundleID.isEmpty { slots[index].bundleIdentifier = bundleID }

        switch outcome {
        case .succeeded:
            slots[index].lastSuccessAt = Date()
            slots[index].profileExpiresAt = ProfileInspector
                .profile(covering: slots[index].bundleIdentifier)?.expirationDate
            scheduler.recordSuccess(slotID)
        case .failed:
            scheduler.recordFailure(slotID)
        case .stopped:
            // Deliberately neither. Stop is a decision, not a fault.
            break
        }

        // The verdict on screen is derived live, but the scheduler's own
        // bookkeeping just moved — give the next tick a reason to happen now.
        scheduler.evaluateNow()

        if outcome != .stopped {
            notifyIfWanted(slot: slots[index],
                           succeeded: outcome == .succeeded,
                           wasAutomatic: runner(for: slotID).trigger == .automatic)
        }
    }

    /// Re-reads profile expiry for every slot from what is actually on disk.
    ///
    /// The scheduler calls this on every tick, so: one pass over the profile
    /// folders for all slots, off the main actor, and only write back when a
    /// value really moved — otherwise each tick would re-save and re-render an
    /// idle app for nothing.
    func refreshExpiryFromDisk() async {
        let identifiers = slots.map(\.bundleIdentifier).filter { !$0.isEmpty }
        guard !identifiers.isEmpty else { return }
        let expiries = await Task.detached(priority: .utility) {
            ProfileInspector.expiryDates(for: identifiers)
        }.value

        for index in slots.indices where !slots[index].bundleIdentifier.isEmpty {
            let expiry = expiries[slots[index].bundleIdentifier]
            if slots[index].profileExpiresAt != expiry {
                slots[index].profileExpiresAt = expiry
            }
        }
    }

    var isAnyRunning: Bool {
        batchTask != nil || runners.values.contains { $0.isRunning } || maintenance.isRunning
    }

    var readySlots: [ProjectSlot] { slots.filter(\.isConfigured) }

    // MARK: - Actions

    /// Starts a refresh, unless anything else is already running.
    ///
    /// The one-at-a-time rule lives here rather than in the buttons. It used to
    /// be a `.disabled` on each control, and a control that forgot — the ⌘R
    /// and ⇧⌘R menu commands both did — could still start a second run over
    /// the same provisioning-profile folders.
    @discardableResult
    func resync(_ slot: ProjectSlot, trigger: RunTrigger = .manual) -> Task<Void, Never>? {
        guard !isAnyRunning else { return nil }
        return startRun(slot, trigger: trigger)
    }

    private func startRun(_ slot: ProjectSlot, trigger: RunTrigger) -> Task<Void, Never>? {
        if trigger == .manual { scheduler.clearBackoff(slot.id) }
        return runner(for: slot.id).resync(slot: slot, trigger: trigger)
    }

    /// One project at a time, on purpose. Parallel `xcodebuild`s racing each
    /// other through the same provisioning-profile folder is exactly how you
    /// get signing failures that do not reproduce.
    func resyncAll(trigger: RunTrigger = .manual) {
        guard !isAnyRunning else { return }
        batchTask = Task { [weak self] in
            guard let self else { return }
            for slot in self.readySlots {
                if Task.isCancelled { break }
                await self.startRun(slot, trigger: trigger)?.value
            }
            self.batchTask = nil
        }
    }

    /// Slots whose signing is inside the warning window.
    var slotsNeedingAttention: [ProjectSlot] {
        slots.filter { slot in
            guard let days = slot.daysUntilExpiry else { return false }
            return days <= preferences.refreshWhenDaysRemaining
        }
    }

    private var hasFailure: Bool {
        slots.contains { runner(for: $0.id).phase.isFailure }
    }

    /// SF Symbol for the menu bar, reflecting the worst current state.
    ///
    /// Every state gets its own glyph. Running and healthy used to share one,
    /// which meant the icon never actually told you anything.
    var menuBarSymbol: String {
        if isAnyRunning { return "arrow.triangle.2.circlepath.circle.fill" }
        if hasFailure { return "exclamationmark.triangle.fill" }
        if !slotsNeedingAttention.isEmpty { return "exclamationmark.arrow.triangle.2.circlepath" }
        return "arrow.triangle.2.circlepath"
    }

    /// What VoiceOver reads for the menu bar icon.
    var menuBarAccessibilityLabel: String {
        "AirRefresh — " + healthSummary
    }

    /// One line for the menu bar tooltip and header.
    ///
    /// Names the project whenever there is something to do. "Signing expires
    /// tomorrow" left you reading every card to find out whose.
    var healthSummary: String {
        let ready = readySlots
        guard !ready.isEmpty else { return "No projects set up yet" }

        let expired = ready.filter(\.hasExpired)
        if expired.count == 1 { return "\(expired[0].displayName) has expired" }
        if expired.count > 1 { return "\(expired.count) projects have expired" }

        guard let soonest = ready
                .filter({ $0.profileExpiresAt != nil })
                .min(by: { $0.profileExpiresAt! < $1.profileExpiresAt! }),
              let days = soonest.calendarDaysUntilExpiry()
        else { return "\(ready.count) project\(ready.count == 1 ? "" : "s") ready" }

        let needsAttention = slotsNeedingAttention.contains { $0.id == soonest.id }
        switch days {
        case ...0: return "\(soonest.displayName) expires today"
        case 1: return "\(soonest.displayName) expires tomorrow"
        default:
            return needsAttention ? "\(soonest.displayName) expires in \(days) days"
                                  : "Signing good for \(days) more days"
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermissionIfNeeded() {
        guard preferences.notifyOnCompletion else { return }
        preferences.requestNotificationAuthorization()
        preferences.refreshNotificationAuthorization()
    }

    /// Automatic runs speak up; manual ones are already visible on screen.
    private func notifyIfWanted(slot: ProjectSlot, succeeded: Bool, wasAutomatic: Bool) {
        guard preferences.notifyOnCompletion, wasAutomatic else { return }
        let content = UNMutableNotificationContent()
        content.title = succeeded ? "\(slot.displayName) refreshed" : "\(slot.displayName) failed to refresh"
        content.body = succeeded
            ? "Re-signed and reinstalled on \(slot.deviceName)."
            : "Open AirRefresh to see the log."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    func stopAll() {
        batchTask?.cancel()
        batchTask = nil
        for runner in runners.values { runner.stop() }
        maintenance.stop()
    }

    /// Whether the log sheet for "Reset Signing Only" is up. Lives here, not in
    /// the window, so the menu command can open it as well as the ⋯ menu —
    /// before, ⇧⌘R archived every profile on the Mac with nothing on screen.
    var isShowingSigningResetLog = false

    /// The hammer. Callers confirm with the user first; see `SigningResetPrompt`.
    func resetSigningOnly() {
        guard !isAnyRunning else { return }
        maintenance.resetSigningOnly()
        isShowingSigningResetLog = true
    }

    // MARK: - Schemes

    /// Reads the scheme list straight out of the project with `xcodebuild -list`.
    func loadSchemes(for slot: ProjectSlot) async {
        guard !slot.projectPath.isEmpty, !loadingSchemes.contains(slot.id) else { return }
        loadingSchemes.insert(slot.id)
        defer { loadingSchemes.remove(slot.id) }

        let result = try? await Shell.capture("/usr/bin/xcrun", [
            "xcodebuild", "-list", "-json",
            slot.containerFlag, slot.projectPath
        ])
        guard let output = result?.output,
              let start = output.firstIndex(of: "{"),
              let data = String(output[start...]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            schemes[slot.id] = []
            schemeErrors[slot.id] = Self.schemeFailureMessage(result?.output)
            return
        }
        let container = (root["project"] ?? root["workspace"]) as? [String: Any]
        let found = (container?["schemes"] as? [String]) ?? []
        schemes[slot.id] = found
        schemeErrors[slot.id] = found.isEmpty
            ? "That project has no shared schemes. In Xcode: Product ▸ Scheme ▸ Manage Schemes, tick Shared."
            : nil

        // Pre-select the obvious choice so the common case needs zero clicks.
        if let index = binding(for: slot), slots[index].scheme.isEmpty {
            let projectName = URL(fileURLWithPath: slot.projectPath)
                .deletingPathExtension().lastPathComponent
            slots[index].scheme = found.first { $0 == projectName } ?? found.first ?? ""
        }
    }

    func schemes(for slot: ProjectSlot) -> [String] { schemes[slot.id] ?? [] }
    /// Whether the scheme list has been read at all — until it has, a saved
    /// scheme missing from it proves nothing.
    func hasLoadedSchemes(_ slot: ProjectSlot) -> Bool { schemes[slot.id] != nil }
    func isLoadingSchemes(_ slot: ProjectSlot) -> Bool { loadingSchemes.contains(slot.id) }
    func schemeError(for slot: ProjectSlot) -> String? { schemeErrors[slot.id] }

    /// Boils xcodebuild's complaint down to the one line worth putting on screen.
    nonisolated static func schemeFailureMessage(_ output: String?) -> String {
        let fallback = "Could not read the schemes out of that project."
        guard let output, !output.isEmpty else { return fallback }
        guard let line = output
            .split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.lowercased().contains("error:") })
        else { return fallback }
        // Drop xcodebuild's own prefix; the message after it is the useful part.
        if let range = line.range(of: "error:") {
            let detail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !detail.isEmpty { return detail }
        }
        return line
    }

    /// Applies a newly chosen project path and refreshes everything derived from it.
    func setProjectPath(_ path: String, for slot: ProjectSlot) async {
        guard let index = binding(for: slot) else { return }
        slots[index].projectPath = path
        slots[index].scheme = ""
        schemeErrors[slot.id] = nil
        if slots[index].name.isEmpty {
            slots[index].name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        // Default to the only device if there is exactly one.
        if slots[index].deviceIdentifier.isEmpty, devices.devices.count == 1, let only = devices.devices.first {
            apply(device: only, toSlotAt: index)
        }
        await loadSchemes(for: slots[index])
    }

    /// With a single paired iPhone there is nothing to choose, so fill it in.
    func autoAssignSingleDevice() {
        guard devices.devices.count == 1, let only = devices.devices.first else { return }
        for index in slots.indices where slots[index].deviceIdentifier.isEmpty {
            apply(device: only, toSlotAt: index)
        }
    }

    func apply(device: Device, toSlotWithID id: UUID) {
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        apply(device: device, toSlotAt: index)
    }

    func apply(device: Device, toSlotAt index: Int) {
        slots[index].deviceIdentifier = device.identifier
        slots[index].deviceUDID = device.udid
        slots[index].deviceName = device.name
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(slots) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ProjectSlot].self, from: data) else { return }
        slots = Array(decoded.prefix(Self.maxSlots))
    }
}
