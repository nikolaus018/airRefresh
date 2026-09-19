import Testing
import Foundation
@testable import AirRefresh

struct ProjectSlotTests {

    /// Swift's synthesized decoder throws on a missing key even when the
    /// property has a default. Without the hand-written `init(from:)` every
    /// upgrade would silently wipe the user's configured projects.
    @Test func slotsSavedByAnOlderVersionStillLoad() throws {
        let old = """
        [{
          "id": "11111111-2222-3333-4444-555555555555",
          "name": "Notes",
          "projectPath": "/Users/me/Notes/Notes.xcodeproj",
          "scheme": "Notes",
          "configuration": "Debug",
          "deviceUDID": "00008140-000A",
          "deviceIdentifier": "CORE-DEVICE-ID",
          "deviceName": "iPhone",
          "resetSigning": true,
          "cleanBuild": false,
          "launchAfterInstall": true
        }]
        """
        let slots = try JSONDecoder().decode([ProjectSlot].self, from: Data(old.utf8))
        let slot = try #require(slots.first)
        #expect(slot.name == "Notes")
        #expect(slot.isConfigured)
        // Fields added after that save fall back to their defaults.
        #expect(slot.autoRefresh)
        #expect(slot.bundleIdentifier.isEmpty)
        #expect(slot.profileExpiresAt == nil)
        #expect(!slot.hasProvenItself)
    }

    @Test func roundTripsThroughJSON() throws {
        var slot = ProjectSlot()
        slot.name = "EarRouter"
        slot.projectPath = "/Users/me/EarRouter/EarRouter.xcworkspace"
        slot.scheme = "EarRouter"
        slot.deviceIdentifier = "CORE-ID"
        slot.bundleIdentifier = "win.ringtwo.EarRouter"
        slot.profileExpiresAt = Date(timeIntervalSince1970: 1_800_000_000)

        let data = try JSONEncoder().encode([slot])
        let restored = try #require(try JSONDecoder().decode([ProjectSlot].self, from: data).first)
        #expect(restored == slot)
        #expect(restored.isWorkspace)
        #expect(restored.containerFlag == "-workspace")
    }

    @Test func aSlotKnowsWhatItIsStillMissing() {
        var slot = ProjectSlot()
        #expect(slot.configurationHint == "Choose an .xcodeproj or .xcworkspace")
        slot.projectPath = "/Users/me/Notes/Notes.xcodeproj"
        #expect(slot.configurationHint == "Pick a scheme")
        slot.scheme = "Notes"
        #expect(slot.configurationHint == "Pick a device")
        slot.deviceIdentifier = "CORE-ID"
        #expect(slot.configurationHint == nil)
        #expect(slot.isConfigured)
    }

    @Test func theDisplayNameFallsBackToTheProjectFile() {
        var slot = ProjectSlot()
        #expect(slot.displayName == "Empty slot")
        slot.projectPath = "/Users/me/Side Projects/EarRouter.xcodeproj"
        #expect(slot.displayName == "EarRouter")
        slot.name = "Ear Router"
        #expect(slot.displayName == "Ear Router")
    }

    /// A fixed clock and calendar: the wording counts calendar days, so a test
    /// reading `Date()` would pass or fail depending on the time of day it ran.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Vienna")!
        return calendar
    }()

    /// Saturday 19 September 2026, 14:00 in Vienna.
    private static let saturdayAfternoon = calendar.date(
        from: DateComponents(year: 2026, month: 9, day: 19, hour: 14))!

    private func describe(_ slot: ProjectSlot, hoursFromNow hours: Double) -> String {
        var slot = slot
        slot.profileExpiresAt = Self.saturdayAfternoon.addingTimeInterval(hours * 3600)
        return slot.expiryDescription(now: Self.saturdayAfternoon, calendar: Self.calendar)
    }

    @Test func expiryIsDescribedTheWayYouWouldSayIt() {
        var slot = ProjectSlot()
        #expect(slot.expiryDescription == "Not synced yet")

        slot.lastSuccessAt = Date()
        #expect(slot.expiryDescription == "Signing status unknown")

        #expect(describe(slot, hoursFromNow: 1) == "Expires today")
        #expect(describe(slot, hoursFromNow: 20) == "Expires tomorrow")     // Sunday 10:00
        #expect(describe(slot, hoursFromNow: 5 * 24 + 1) == "Expires in 5 days")
    }

    /// "Tomorrow" is a date, not "somewhere in the next 48 hours". Monday
    /// morning is under two days away on Saturday afternoon, which the old
    /// whole-period count called tomorrow.
    @Test func tomorrowMeansTheNextCalendarDay() {
        let slot = ProjectSlot()
        #expect(describe(slot, hoursFromNow: 43) == "Expires in 2 days")    // Monday 09:00
        #expect(describe(slot, hoursFromNow: 9) == "Expires today")         // Saturday 23:00
        #expect(describe(slot, hoursFromNow: 11) == "Expires tomorrow")     // Sunday 01:00
    }

    /// The day count is floored at zero so the scheduler never has to reason
    /// about negative time — but the *sentence* has to stay honest. An app that
    /// stopped working last week does not "expire today".
    @Test func aLapsedProfileSaysSoRatherThanClaimingToday() {
        var slot = ProjectSlot()
        slot.profileExpiresAt = Date().addingTimeInterval(-10 * 86_400)
        #expect(slot.daysUntilExpiry == 0)
        #expect(slot.hasExpired)
        #expect(slot.expiryDescription == "Expired")
    }

    @Test func aProfileWithHoursLeftHasNotExpiredYet() {
        var slot = ProjectSlot()
        slot.profileExpiresAt = Date().addingTimeInterval(3600)
        #expect(!slot.hasExpired)
        #expect(describe(slot, hoursFromNow: 1) == "Expires today")
    }

    @Test func anUnknownExpiryIsNotAnExpiredOne() {
        let slot = ProjectSlot()
        #expect(!slot.hasExpired)
        #expect(slot.daysUntilExpiry == nil)
    }
}
