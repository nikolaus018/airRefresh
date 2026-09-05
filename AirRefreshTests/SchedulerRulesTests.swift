import Testing
import Foundation
@testable import AirRefresh

/// The scheduler decides, unattended, whether to spend a few minutes of your
/// Mac's time. These are the rules that keep that from being annoying.
struct SchedulerRulesTests {

    private let rules = Scheduler.Rules()

    /// A fixed clock. Building the situation off `Date()` twice puts the two
    /// reads microseconds apart, which is enough to round a whole-day count
    /// down — the tests below would then pass or fail by luck.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func situation(_ edit: (inout Scheduler.Situation) -> Void = { _ in }) -> Scheduler.Situation {
        var s = Scheduler.Situation()
        s.now = now
        s.daysUntilExpiry = 5
        s.lastSuccessAt = now.addingTimeInterval(-2 * 86_400)
        edit(&s)
        return s
    }

    @Test func healthyProfilesAreLeftAlone() {
        #expect(Scheduler.verdict(for: situation(), rules: rules) == .healthy(daysRemaining: 5))
    }

    @Test func insideTheWindowAndIdleIsDue() {
        let s = situation { $0.daysUntilExpiry = 2 }
        #expect(Scheduler.verdict(for: s, rules: rules) == .dueNow)
    }

    @Test func aBusyMacIsNotInterrupted() {
        let s = situation {
            $0.daysUntilExpiry = 2
            $0.idleSeconds = 30
        }
        #expect(Scheduler.verdict(for: s, rules: rules) == .waitingForIdle)
    }

    /// On the last day, being polite loses to the app not launching tomorrow.
    @Test func theLastDayOverridesPoliteness() {
        let s = situation {
            $0.daysUntilExpiry = 1
            $0.idleSeconds = 0
        }
        #expect(Scheduler.verdict(for: s, rules: rules) == .dueNow)
    }

    @Test func anAbsentPhoneIsWaitedFor() {
        let s = situation {
            $0.daysUntilExpiry = 0
            $0.deviceReachable = false
        }
        #expect(Scheduler.verdict(for: s, rules: rules) == .waitingForDevice)
    }

    @Test func automationNeverGoesFirst() {
        let s = situation {
            $0.daysUntilExpiry = 0
            $0.hasProvenItself = false
        }
        #expect(Scheduler.verdict(for: s, rules: rules) == .neverRunManually)
    }

    @Test func repeatedFailuresPauseTheSlot() {
        let s = situation {
            $0.daysUntilExpiry = 0
            $0.consecutiveFailures = 3
        }
        #expect(Scheduler.verdict(for: s, rules: rules) == .tooManyFailures)
    }

    @Test func aRecentAttemptBacksOff() {
        let attempt = now.addingTimeInterval(-600)
        let s = situation {
            $0.daysUntilExpiry = 0
            $0.lastAttemptAt = attempt
        }
        #expect(Scheduler.verdict(for: s, rules: rules)
                == .backingOff(until: attempt.addingTimeInterval(rules.backoffAfterFailure)))
    }

    @Test func anOldAttemptDoesNotBlock() {
        let s = situation {
            $0.daysUntilExpiry = 0
            $0.lastAttemptAt = now.addingTimeInterval(-rules.backoffAfterFailure - 60)
        }
        #expect(Scheduler.verdict(for: s, rules: rules) == .dueNow)
    }

    // MARK: - Unknown expiry
    //
    // The regression that motivated all of this: with no profile on disk the
    // scheduler used to call the slot due on every single tick, so three slots
    // would rebuild each other in a loop forever.

    @Test func aMissingProfileDoesNotMeanRebuildImmediately() {
        let s = situation {
            $0.daysUntilExpiry = nil
            $0.lastSuccessAt = now.addingTimeInterval(-1 * 86_400)
        }
        #expect(Scheduler.verdict(for: s, rules: rules) == .signingUnknown(daysSinceLastRun: 1))
    }

    @Test func aMissingProfileEventuallyBecomesDue() {
        let s = situation {
            $0.daysUntilExpiry = nil
            $0.lastSuccessAt = now.addingTimeInterval(-6 * 86_400)
        }
        #expect(Scheduler.verdict(for: s, rules: rules) == .dueNow)
    }

    @Test func stateChecksComeBeforeEverythingElse() {
        #expect(Scheduler.verdict(for: situation { $0.isConfigured = false }, rules: rules) == .notConfigured)
        #expect(Scheduler.verdict(for: situation { $0.isRunning = true }, rules: rules) == .running)
        #expect(Scheduler.verdict(for: situation { $0.automaticEnabled = false }, rules: rules) == .automaticDisabled)
        #expect(Scheduler.verdict(for: situation { $0.slotAutoRefresh = false }, rules: rules) == .automaticDisabled)
    }

    @Test func everyVerdictHasSomethingToSay() {
        let verdicts: [Scheduler.Verdict] = [
            .notConfigured, .automaticDisabled, .neverRunManually, .healthy(daysRemaining: 4),
            .signingUnknown(daysSinceLastRun: 2), .waitingForDevice, .waitingForIdle,
            .backingOff(until: Date()), .tooManyFailures, .running, .dueNow
        ]
        for verdict in verdicts {
            #expect(!Scheduler.explanation(for: verdict, deviceName: "iPhone", rules: rules).isEmpty)
        }
    }
}
