import Foundation
import Observation
import CoreGraphics
import AppKit

/// Decides when a slot should be refreshed without anyone asking.
///
/// The rule is simple: a free provisioning profile lasts 7 days, so once a
/// project is inside the warning window we look for an unobtrusive moment —
/// the Mac sitting idle, the phone reachable — and do the work then. If the
/// profile is about to die today we stop being polite and just run.
@MainActor
@Observable
final class Scheduler {

    /// Why a slot is or is not being refreshed right now.
    nonisolated enum Verdict: Equatable {
        case notConfigured
        case automaticDisabled
        case neverRunManually
        case healthy(daysRemaining: Int)
        /// Proven slot whose profile we cannot find on disk. We wait out the
        /// assumed 7-day lifetime rather than rebuilding on every tick.
        case signingUnknown(daysSinceLastRun: Int)
        case waitingForDevice
        case waitingForIdle
        case backingOff(until: Date)
        case tooManyFailures
        case running
        case dueNow

        var isDue: Bool { self == .dueNow }
    }

    /// Everything a verdict depends on, gathered in one place so the rules can
    /// be read — and tested — without an app around them.
    nonisolated struct Situation {
        var isConfigured = true
        var isRunning = false
        var automaticEnabled = true
        var slotAutoRefresh = true
        var hasProvenItself = true
        var consecutiveFailures = 0
        var daysUntilExpiry: Int?
        var lastSuccessAt: Date?
        var lastAttemptAt: Date?
        var deviceReachable = true
        var idleSeconds: TimeInterval = .infinity
        var now = Date()
    }

    nonisolated struct Rules {
        var threshold = 2
        var onlyWhenIdle = true
        var idleMinutes = 5
        var maxConsecutiveFailures = 3
        var backoffAfterFailure: TimeInterval = 2 * 3600
        /// What a free-Apple-ID profile is worth, in days, when we have to guess.
        var assumedProfileLifetimeDays = 7
    }

    private unowned let state: AppState
    private let preferences: Preferences

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var activity: NSObjectProtocol?
    private var deviceListRefreshedAt: Date?
    private var lastAttempt: [UUID: Date] = [:]
    private var consecutiveFailures: [UUID: Int] = [:]

    private(set) var lastEvaluation: Date?
    private(set) var verdicts: [UUID: Verdict] = [:]

    /// How often we wake up and look around.
    private let tickInterval: TimeInterval = 180
    /// Device polling is a subprocess, so keep it slower than the tick.
    private let deviceRefreshInterval: TimeInterval = 600

    private var rules: Rules {
        Rules(threshold: preferences.refreshWhenDaysRemaining,
              onlyWhenIdle: preferences.onlyWhenIdle,
              idleMinutes: preferences.idleMinutes)
    }

    init(state: AppState, preferences: Preferences) {
        self.state = state
        self.preferences = preferences
    }

    func start() {
        guard timer == nil else { return }
        updateAppNapAssertion()
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Timers do not fire while the Mac is asleep, and the device list we
        // cached before the lid closed is worthless. Look again on wake.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.deviceListRefreshedAt = nil
                self?.evaluateNow()
            }
        }

        Task { await tickAsync() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    func evaluateNow() {
        updateAppNapAssertion()
        Task { await tickAsync() }
    }

    /// macOS puts App Nap on apps with no visible window and throttles their
    /// timers — which for an app whose entire job is to act while nobody is
    /// looking means the 3am refresh simply never happens. The assertion opts
    /// out of that and nothing else: the `AllowingIdleSystemSleep` variant is
    /// deliberate, because keeping someone's laptop awake to watch a date go by
    /// would be a far worse bargain than a late refresh.
    private func updateAppNapAssertion() {
        let wanted = preferences.automaticRefreshEnabled
        if wanted, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .automaticTerminationDisabled],
                reason: "Watching provisioning profiles for expiry"
            )
        } else if !wanted, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    // MARK: - The tick

    private func tick() {
        Task { await tickAsync() }
    }

    /// Whether any slot could actually be refreshed unattended right now. When
    /// nothing can, the tick skips its subprocess entirely — this app sits in a
    /// laptop's menu bar all day and has no business waking the disk for a
    /// device scan nobody asked for.
    private var automationCouldRun: Bool {
        preferences.automaticRefreshEnabled
            && state.slots.contains { $0.isConfigured && $0.autoRefresh && $0.hasProvenItself }
    }

    private func tickAsync() async {
        updateAppNapAssertion()

        // Keep the device list warm enough that "is the phone there?" is honest.
        let deviceListIsStale = deviceListRefreshedAt.map {
            Date().timeIntervalSince($0) > deviceRefreshInterval
        } ?? true
        if automationCouldRun, deviceListIsStale {
            await state.devices.refresh()
            deviceListRefreshedAt = Date()
        }

        // Signing health can change behind our back (Xcode builds, manual resets).
        await state.refreshExpiryFromDisk()

        lastEvaluation = Date()
        var due: [ProjectSlot] = []
        for slot in state.slots {
            let verdict = evaluate(slot)
            verdicts[slot.id] = verdict
            if verdict.isDue { due.append(slot) }
        }

        // One at a time — parallel xcodebuilds fighting over the same signing
        // assets is exactly how you get flaky failures.
        if let next = due.first, !state.isAnyRunning {
            lastAttempt[next.id] = Date()
            state.resync(next, trigger: .automatic)
        }
    }

    // MARK: - Rules

    func evaluate(_ slot: ProjectSlot) -> Verdict {
        Self.verdict(for: situation(for: slot), rules: rules)
    }

    private func situation(for slot: ProjectSlot) -> Situation {
        Situation(
            isConfigured: slot.isConfigured,
            isRunning: state.runner(for: slot.id).isRunning,
            automaticEnabled: preferences.automaticRefreshEnabled,
            slotAutoRefresh: slot.autoRefresh,
            hasProvenItself: slot.hasProvenItself,
            consecutiveFailures: consecutiveFailures[slot.id] ?? 0,
            daysUntilExpiry: slot.daysUntilExpiry,
            lastSuccessAt: slot.lastSuccessAt,
            lastAttemptAt: lastAttempt[slot.id],
            deviceReachable: state.devices.device(withIdentifier: slot.deviceIdentifier) != nil,
            idleSeconds: Self.systemIdleSeconds,
            now: Date()
        )
    }

    /// The whole decision, as a pure function of the situation.
    nonisolated static func verdict(for s: Situation, rules: Rules) -> Verdict {
        guard s.isConfigured else { return .notConfigured }
        if s.isRunning { return .running }
        guard s.automaticEnabled, s.slotAutoRefresh else { return .automaticDisabled }

        // Don't let automation be the first thing that ever runs a slot: a
        // never-verified project would fail unattended, over and over.
        guard s.hasProvenItself else { return .neverRunManually }

        if s.consecutiveFailures >= rules.maxConsecutiveFailures { return .tooManyFailures }

        let daysLeft: Int
        if let known = s.daysUntilExpiry {
            daysLeft = known
        } else {
            // No profile on disk covers this app any more. Someone else cleared
            // it, or it was never found. Rather than rebuild on every tick,
            // assume the usual 7-day life and count from the last good run.
            let age = s.lastSuccessAt.map { Int(s.now.timeIntervalSince($0) / 86_400) } ?? .max
            daysLeft = age == .max ? 0 : max(0, rules.assumedProfileLifetimeDays - age)
            if daysLeft > rules.threshold { return .signingUnknown(daysSinceLastRun: age) }
        }

        guard daysLeft <= rules.threshold else { return .healthy(daysRemaining: daysLeft) }

        if let previous = s.lastAttemptAt,
           s.now.timeIntervalSince(previous) < rules.backoffAfterFailure {
            return .backingOff(until: previous.addingTimeInterval(rules.backoffAfterFailure))
        }

        guard s.deviceReachable else { return .waitingForDevice }

        // Politeness is dropped on the last day.
        let urgent = daysLeft <= 1
        if !urgent, rules.onlyWhenIdle, s.idleSeconds < Double(rules.idleMinutes) * 60 {
            return .waitingForIdle
        }

        return .dueNow
    }

    /// Seconds since the last keyboard or mouse event. No permissions needed.
    static var systemIdleSeconds: TimeInterval {
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyEvent)
    }

    // MARK: - Feedback from runs

    /// Note what is *not* cleared: `lastAttempt`. It reads like a failure
    /// backoff, and it is, but it is also the only thing standing between a
    /// build that reports success without actually renewing the profile and an
    /// automatic refresh every three minutes forever.
    func recordSuccess(_ slotID: UUID) {
        consecutiveFailures[slotID] = 0
    }

    func recordFailure(_ slotID: UUID) {
        consecutiveFailures[slotID, default: 0] += 1
        lastAttempt[slotID] = Date()
    }

    /// Clears a backoff so the user's own button press is never ignored.
    func clearBackoff(_ slotID: UUID) {
        consecutiveFailures[slotID] = 0
        lastAttempt[slotID] = nil
    }

    /// Worked out live rather than read back from `verdicts`.
    ///
    /// The cached verdict is only three minutes old at worst, but three minutes
    /// is long enough for the settings pane to sit there describing what would
    /// happen under the threshold the user just changed.
    func explanation(for slot: ProjectSlot) -> String {
        // Touching `lastEvaluation` is what re-renders callers when the tick
        // re-reads the world: the idle timer and the clock are not observable,
        // so nothing else here would notice a tick going by.
        _ = lastEvaluation
        return Self.explanation(for: evaluate(slot),
                                deviceName: slot.deviceName,
                                rules: rules)
    }

    nonisolated static func explanation(for verdict: Verdict, deviceName: String, rules: Rules) -> String {
        /// "in about 3 days" rather than "at 2 days left (5 now)": the question
        /// being answered is when, not the arithmetic behind it.
        func inAbout(_ days: Int) -> String {
            days <= 1 ? "in about a day" : "in about \(days) days"
        }
        switch verdict {
        case .notConfigured:      return "Finish setting this slot up"
        case .automaticDisabled:  return "Automatic refresh is off"
        case .neverRunManually:   return "Run it once yourself, then it keeps itself alive"
        case .healthy(let left):  return "Healthy · refreshes itself \(inAbout(left - rules.threshold))"
        case .signingUnknown(let age):
            let wait = rules.assumedProfileLifetimeDays - rules.threshold - age
            return "No matching profile found · rebuilds \(inAbout(wait))"
        case .waitingForDevice:   return "Waiting for \(deviceName.isEmpty ? "the device" : deviceName) to come back"
        case .waitingForIdle:     return "Due — waiting for the Mac to be idle"
        case .backingOff(let until): return "Retrying after \(until.formatted(date: .omitted, time: .shortened))"
        case .tooManyFailures:    return "Paused after \(rules.maxConsecutiveFailures) failures — refresh manually to resume"
        case .running:            return "Refreshing now"
        case .dueNow:             return "Due now"
        }
    }
}
