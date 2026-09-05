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

    /// The offsets carry an extra hour so a whole-day count cannot round down
    /// between the two calls to `Date()`.
    @Test func expiryIsDescribedTheWayYouWouldSayIt() {
        var slot = ProjectSlot()
        #expect(slot.expiryDescription == "Not synced yet")

        slot.lastSuccessAt = Date()
        #expect(slot.expiryDescription == "Signing status unknown")

        slot.profileExpiresAt = Date().addingTimeInterval(3600)
        #expect(slot.expiryDescription == "Expires today")
        #expect(slot.daysUntilExpiry == 0)

        slot.profileExpiresAt = Date().addingTimeInterval(36 * 3600)
        #expect(slot.expiryDescription == "Expires tomorrow")

        slot.profileExpiresAt = Date().addingTimeInterval(5 * 86_400 + 3600)
        #expect(slot.expiryDescription == "Expires in 5 days")
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
        #expect(slot.expiryDescription == "Expires today")
    }

    @Test func anUnknownExpiryIsNotAnExpiredOne() {
        let slot = ProjectSlot()
        #expect(!slot.hasExpired)
        #expect(slot.daysUntilExpiry == nil)
    }
}
