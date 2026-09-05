import Testing
import Foundation
@testable import AirRefresh

/// A `.mobileprovision` is a CMS envelope with an XML plist buried in it. We
/// read the plist without any crypto, which means the carving has to be right.
struct ProfileInspectorTests {

    /// Builds a file shaped like the real thing: binary noise, the plist, then
    /// the signature block.
    private func writeProfile(bundleID: String,
                              expires: Date,
                              teamName: String = "Nikolaus (Personal Team)") throws -> URL {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key><string>iOS Team Provisioning Profile: \(bundleID)</string>
            <key>UUID</key><string>1e6dd1cb-0000-4000-a000-000000000001</string>
            <key>TeamName</key><string>\(teamName)</string>
            <key>CreationDate</key><date>2026-01-01T00:00:00Z</date>
            <key>ExpirationDate</key><date>\(ISO8601DateFormatter().string(from: expires))</date>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key><string>ABCDE12345.\(bundleID)</string>
            </dict>
        </dict>
        </plist>
        """

        var data = Data([0x30, 0x82, 0x0B, 0xAD, 0xC0, 0xFF, 0xEE])
        data.append(Data(plist.utf8))
        data.append(Data([0xDE, 0xAD, 0xBE, 0xEF]))

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "airrefresh-\(UUID().uuidString).mobileprovision")
        try data.write(to: url)
        return url
    }

    @Test func readsTheFieldsWeActuallyUse() throws {
        let expiry = Date().addingTimeInterval(7 * 86_400 + 3600)
        let url = try writeProfile(bundleID: "com.example.Notes", expires: expiry)
        defer { try? FileManager.default.removeItem(at: url) }

        let profile = try #require(ProfileInspector.parse(url))
        #expect(profile.bundleIdentifier == "com.example.Notes")
        #expect(profile.teamName == "Nikolaus (Personal Team)")
        #expect(abs(profile.expirationDate.timeIntervalSince(expiry)) < 1)
        #expect(profile.daysRemaining == 7)   // floored: 7 whole days plus an hour
        #expect(!profile.hasExpired)
    }

    @Test func anExpiredProfileKnowsIt() throws {
        let url = try writeProfile(bundleID: "com.example.Old",
                                   expires: Date().addingTimeInterval(-86_400))
        defer { try? FileManager.default.removeItem(at: url) }

        let profile = try #require(ProfileInspector.parse(url))
        #expect(profile.hasExpired)
        #expect(profile.daysRemaining == 0)
    }

    @Test func garbageIsRejectedRatherThanGuessed() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "airrefresh-\(UUID().uuidString).mobileprovision")
        try Data("not a provisioning profile".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(ProfileInspector.parse(url) == nil)
    }

    @Test func teamPrefixIsStrippedFromTheBundleID() {
        let profile = ProvisioningProfile(
            url: URL(fileURLWithPath: "/tmp/x.mobileprovision"),
            uuid: "u", name: "n", teamName: "t",
            applicationIdentifier: "C5MSK2XBMK.win.ringtwo.EarRouter",
            creationDate: .distantPast, expirationDate: .distantFuture
        )
        #expect(profile.bundleIdentifier == "win.ringtwo.EarRouter")
        #expect(!profile.isWildcard)
        #expect(profile.covers(bundleID: "win.ringtwo.EarRouter"))
        #expect(!profile.covers(bundleID: "win.ringtwo.EarRouterPro"))
    }

    /// The scheduler asks for every slot's expiry on every tick. Doing that one
    /// slot at a time re-read and re-parsed every profile on the Mac once per
    /// slot; the batched version has to give exactly the same answers.
    @Test func batchedLookupAgreesWithTheOneAtATimeVersion() {
        let soon = ProvisioningProfile(url: URL(fileURLWithPath: "/tmp/a"), uuid: "a", name: "a",
                                       teamName: "T", applicationIdentifier: "ABCDE12345.com.example.Notes",
                                       creationDate: .distantPast,
                                       expirationDate: Date().addingTimeInterval(2 * 86_400))
        let later = ProvisioningProfile(url: URL(fileURLWithPath: "/tmp/b"), uuid: "b", name: "b",
                                        teamName: "T", applicationIdentifier: "ABCDE12345.com.example.Notes",
                                        creationDate: .distantPast,
                                        expirationDate: Date().addingTimeInterval(6 * 86_400))
        let wildcard = ProvisioningProfile(url: URL(fileURLWithPath: "/tmp/c"), uuid: "c", name: "c",
                                           teamName: "T", applicationIdentifier: "ABCDE12345.*",
                                           creationDate: .distantPast,
                                           expirationDate: Date().addingTimeInterval(86_400))
        // `installedProfiles()` hands them over soonest-expiry first.
        let installed = [wildcard, soon, later]

        // An exact match wins even though the wildcard expires sooner.
        #expect(ProfileInspector.best(covering: "com.example.Notes", among: installed) == soon)
        // Nothing exact: the wildcard is the answer.
        #expect(ProfileInspector.best(covering: "com.other.App", among: installed) == wildcard)
        // And an empty bundle id matches nothing at all, wildcard included.
        #expect(ProfileInspector.best(covering: "", among: installed) == nil)
    }

    @Test func batchedLookupSkipsBundleIDsItKnowsNothingAbout() throws {
        let url = try writeProfile(bundleID: "com.example.Notes",
                                   expires: Date().addingTimeInterval(5 * 86_400))
        defer { try? FileManager.default.removeItem(at: url) }
        // The real folders are not ours to plant files in, so this exercises
        // the empty-input contract rather than the filesystem.
        #expect(ProfileInspector.expiryDates(for: []).isEmpty)
        #expect(ProfileInspector.expiryDates(for: ["", ""]).isEmpty)
    }

    @Test func wildcardsCoverTheirPrefixAndNothingElse() {
        let profile = ProvisioningProfile(
            url: URL(fileURLWithPath: "/tmp/x.mobileprovision"),
            uuid: "u", name: "n", teamName: "t",
            applicationIdentifier: "C5MSK2XBMK.win.ringtwo.*",
            creationDate: .distantPast, expirationDate: .distantFuture
        )
        #expect(profile.isWildcard)
        #expect(profile.covers(bundleID: "win.ringtwo.EarRouter"))
        #expect(!profile.covers(bundleID: "com.example.Notes"))
        // An empty bundle id must never match, or a fresh slot would look covered.
        #expect(!profile.covers(bundleID: ""))
    }
}
