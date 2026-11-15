import Testing
import Foundation
@testable import AirRefresh

/// An `.ipa` slot cannot be rebuilt, so its pipeline is different all the way
/// through: unpack, mint a profile with a helper build, re-sign, install.
@MainActor
struct IPAPipelineTests {

    @MainActor final class Outcomes {
        var all: [RunOutcome] = []
        var bundleIDs: [String] = []
    }

    private func makeRunner(_ fake: FakePipeline) -> (SlotRunner, Outcomes) {
        let runner = SlotRunner(id: UUID(), environment: fake.environment)
        let outcomes = Outcomes()
        runner.onFinished = { outcome, bundleID in
            outcomes.all.append(outcome)
            outcomes.bundleIDs.append(bundleID)
        }
        return (runner, outcomes)
    }

    private func run(_ runner: SlotRunner, _ slot: ProjectSlot) async {
        await runner.resync(slot: slot)?.value
    }

    @Test func theHappyPathUnpacksMintsResignsAndInstalls() async {
        let fake = FakePipeline()
        let (runner, outcomes) = makeRunner(fake)
        let slot = FakePipeline.ipaSlot(in: fake)

        await run(runner, slot)

        // One nested framework, then the app itself.
        #expect(fake.kinds == [.unpack, .build, .identities, .codesign, .codesign, .install, .launch])
        #expect(runner.phase.isSuccess)
        #expect(outcomes.all == [.succeeded])
        #expect(outcomes.bundleIDs == ["com.example.Notes"])
        // Never the project path of an .ipa, never -showBuildSettings on it.
        #expect(!fake.issued(.settings))
    }

    @Test func theHelperBuildIsWhatAsksXcodeForTheProfile() async {
        let fake = FakePipeline()
        let (runner, _) = makeRunner(fake)
        let slot = FakePipeline.ipaSlot(in: fake)

        await run(runner, slot)

        let stub = try! #require(fake.stubProjects.first)
        #expect(stub.bundleID == "com.example.Notes")
        #expect(stub.teamID == "ABCDE12345")

        let build = try! #require(fake.command(.build))
        #expect(build.contains("-allowProvisioningUpdates"))
        #expect(build.contains(stub.projectURL.path))
        #expect(build.contains(IPASigning.stubName))
        #expect(build.contains("id=\(slot.deviceUDID)"))
    }

    @Test func theAppIsSignedInsideOutWithTheProfilesCertificate() async {
        let fake = FakePipeline()
        let (runner, _) = makeRunner(fake)

        await run(runner, FakePipeline.ipaSlot(in: fake))

        let signs = fake.commands.filter { FakePipeline.kind(of: Array($0.dropFirst())) == .codesign }
        #expect(signs.count == 2)
        #expect(signs.allSatisfy { $0.contains(FakePipeline.fingerprint) })
        #expect(signs[0].last?.hasSuffix("Kit.framework") == true)
        #expect(!signs[0].contains("--entitlements"))
        #expect(signs[1].contains("--entitlements"))
        #expect(signs[1].last == FakePipeline.ipaApp.path)

        #expect(fake.entitlementsWritten == [IPASigning.Entitlements(teamID: "ABCDE12345",
                                                                      bundleID: "com.example.Notes",
                                                                      getTaskAllow: true)])
        #expect(fake.command(.install)?.contains(FakePipeline.ipaApp.path) == true)
    }

    @Test func aBundleIDOverrideIsUsedEverywhere() async {
        let fake = FakePipeline()
        fake.embeddedProfile = FakePipeline.freshProfile(bundleID: "com.me.Notes")
        let (runner, outcomes) = makeRunner(fake)
        var slot = FakePipeline.ipaSlot(in: fake)
        slot.bundleIDOverride = " com.me.Notes "

        await run(runner, slot)

        #expect(fake.archiveScopes == [.coveringBundleID("com.me.Notes")])
        #expect(fake.stubProjects.first?.bundleID == "com.me.Notes")
        #expect(fake.preparedApps.first?.bundleID == "com.me.Notes")
        #expect(fake.entitlementsWritten.first?.bundleID == "com.me.Notes")
        #expect(fake.command(.launch)?.last == "com.me.Notes")
        #expect(outcomes.bundleIDs == ["com.me.Notes"])
    }

    @Test func anIPAThatHasMovedFailsBeforeTouchingAnything() async {
        let fake = FakePipeline()
        let (runner, outcomes) = makeRunner(fake)
        let slot = FakePipeline.ipaSlot(in: fake)
        fake.existingFiles.remove(slot.projectPath)

        await run(runner, slot)

        #expect(fake.commands.isEmpty)
        #expect(fake.archiveScopes.isEmpty)
        #expect(outcomes.all == [.failed])
        guard case .failed(let message) = runner.phase else { Issue.record("not failed"); return }
        #expect(message.contains("no longer at"))
    }

    @Test func anInvalidOverrideIsRefusedBeforeTheHelperIsWritten() async {
        let fake = FakePipeline()
        let (runner, outcomes) = makeRunner(fake)
        var slot = FakePipeline.ipaSlot(in: fake)
        slot.bundleIDOverride = "com.me.\"; DEVELOPMENT_TEAM = X"

        await run(runner, slot)

        #expect(fake.stubProjects.isEmpty)
        #expect(!fake.issued(.build))
        #expect(outcomes.all == [.failed])
    }

    @Test func aProfileForTheWrongAppIsNotUsed() async {
        let fake = FakePipeline()
        fake.embeddedProfile = FakePipeline.freshProfile(bundleID: "com.example.Other")
        let (runner, outcomes) = makeRunner(fake)

        await run(runner, FakePipeline.ipaSlot(in: fake))

        #expect(!fake.issued(.codesign))
        #expect(!fake.issued(.install))
        #expect(outcomes.all == [.failed])
    }

    @Test func noMatchingCertificateSaysSoAndInstallsNothing() async {
        let fake = FakePipeline()
        fake.identitiesOutput = "     0 valid identities found"
        let (runner, outcomes) = makeRunner(fake)

        await run(runner, FakePipeline.ipaSlot(in: fake))

        #expect(!fake.issued(.codesign))
        #expect(!fake.issued(.install))
        #expect(outcomes.all == [.failed])
        #expect(runner.hints.contains { $0.contains("Manage Certificates") })
    }

    @Test func aFailedHelperBuildNeverReachesThePhone() async {
        let fake = FakePipeline()
        fake.exitCodes[.build] = 65
        fake.output[.build] = ["error: The app identifier \"com.example.Notes\" cannot be registered to your development team because it is not available."]
        let (runner, outcomes) = makeRunner(fake)

        await run(runner, FakePipeline.ipaSlot(in: fake))

        #expect(runner.phase == .failed("Could not get a provisioning profile (exit code 65)"))
        #expect(!fake.issued(.install))
        #expect(outcomes.all == [.failed])
        #expect(runner.hints.contains { $0.contains("Bundle ID field") })
    }

    /// Stop hands the runner back at once, but the cancelled task is still
    /// unwinding. A Refresh pressed in that window must not have its phase,
    /// watchdog or outcome overwritten by the run it replaced.
    @Test func aStoppedRunCannotClobberTheRunThatReplacedIt() async {
        let fake = FakePipeline()
        fake.hangs = [.build]
        let (runner, outcomes) = makeRunner(fake)
        let slot = FakePipeline.slot()

        let first = runner.resync(slot: slot)
        let deadline = ContinuousClock.now + .seconds(3)
        while !fake.issued(.build) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        runner.stop()
        fake.hangs = []
        let second = runner.resync(slot: slot)
        #expect(second != nil)

        await second?.value
        await first?.value

        #expect(runner.phase.isSuccess)
        #expect(outcomes.all == [.succeeded])
        #expect(!runner.plainLog.contains("Stopped"))
    }
}

struct IPASigningTests {

    @Test func bundleIDsAreValidatedTheWayThePortalDoes() {
        #expect(IPASigning.isValidBundleID("com.example.Notes"))
        #expect(IPASigning.isValidBundleID("com.my-name.app2"))
        #expect(!IPASigning.isValidBundleID("Notes"))
        #expect(!IPASigning.isValidBundleID("com..Notes"))
        #expect(!IPASigning.isValidBundleID("com.example.Notes\";"))
        #expect(!IPASigning.isValidBundleID(""))
        #expect(IPASigning.isValidTeamID("ABCDE12345"))
        #expect(!IPASigning.isValidTeamID("c5msk2xbmk"))
        #expect(!IPASigning.isValidTeamID("C5MSK2XBM"))
    }

    @Test func identitiesAreReadOutOfSecuritysOutput() {
        let output = """
          1) A1B2C3D4E5F60718293A4B5C6D7E8F9012345678 "Apple Development: Someone (ABCDE12345)"
          2) 0123456789abcdef0123456789abcdef01234567 "Apple Development: Other (FGHIJ67890)"
             2 valid identities found
        """
        #expect(IPASigning.parseIdentities(output) == [
            "A1B2C3D4E5F60718293A4B5C6D7E8F9012345678",
            "0123456789ABCDEF0123456789ABCDEF01234567"
        ])
        #expect(IPASigning.parseIdentities("     0 valid identities found").isEmpty)
    }

    @Test func theAppsOwnInfoPlistIsFoundInAListing() {
        let listing = """
        Payload/
        Payload/Notes.app/
        Payload/Notes.app/Frameworks/Kit.framework/Info.plist
        Payload/Notes.app/PlugIns/Share.appex/Info.plist
        Payload/Notes.app/Info.plist
        """
        #expect(IPASigning.infoPlistEntry(in: listing) == "Payload/Notes.app/Info.plist")
        #expect(IPASigning.infoPlistEntry(in: "Payload/[Beta].app/Info.plist") == nil)
        #expect(IPASigning.infoPlistEntry(in: "") == nil)
    }

    @Test func entitlementsAreTheMinimumAFreeProfileGrants() {
        let plist = IPASigning.Entitlements(teamID: "ABCDE12345", bundleID: "com.me.Notes",
                                            getTaskAllow: true).plist
        #expect(plist["application-identifier"] as? String == "ABCDE12345.com.me.Notes")
        #expect(plist["com.apple.developer.team-identifier"] as? String == "ABCDE12345")
        #expect(plist["get-task-allow"] as? Bool == true)
        #expect(plist["keychain-access-groups"] as? [String] == ["ABCDE12345.com.me.Notes"])
        #expect(plist.count == 4)
    }

    @Test func theHelperProjectCarriesTheBundleIDAndTeam() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "airrefresh-stub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = IPASigning.StubProject(directory: root, bundleID: "com.me.Notes", teamID: "ABCDE12345")

        let project = try IPASigning.writeStubProject(stub)
        let pbxproj = try String(contentsOf: project.appending(path: "project.pbxproj"), encoding: .utf8)

        #expect(pbxproj.contains("PRODUCT_BUNDLE_IDENTIFIER = \"com.me.Notes\";"))
        #expect(pbxproj.contains("DEVELOPMENT_TEAM = \"ABCDE12345\";"))
        #expect(pbxproj.contains("CODE_SIGN_STYLE = Automatic;"))
        #expect(FileManager.default.fileExists(
            atPath: root.appending(path: "\(IPASigning.stubName)/main.c").path))

        // Rewriting replaces rather than piling up.
        try IPASigning.writeStubProject(IPASigning.StubProject(directory: root, bundleID: "com.me.Other",
                                                               teamID: "ABCDE12345"))
        let again = try String(contentsOf: project.appending(path: "project.pbxproj"), encoding: .utf8)
        #expect(again.contains("com.me.Other"))
        #expect(!again.contains("com.me.Notes"))
    }

    @Test func theHelperProjectRefusesAnythingThatCouldEscapeAQuote() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "airrefresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: PipelineError.self) {
            try IPASigning.writeStubProject(.init(directory: root, bundleID: "a.b\"; X = 1", teamID: "ABCDE12345"))
        }
        #expect(throws: PipelineError.self) {
            try IPASigning.writeStubProject(.init(directory: root, bundleID: "a.b", teamID: "ABC\"; X"))
        }
    }

    /// A fake unpacked app: a framework holding a dylib, an extension and a
    /// binary Info.plist, like a real one.
    private func makeApp() throws -> (root: URL, app: URL, profile: URL) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "airrefresh-app-\(UUID().uuidString)")
        let app = root.appending(path: "Payload/Notes.app")
        let framework = app.appending(path: "Frameworks/Kit.framework")
        try fm.createDirectory(at: framework.appending(path: "Frameworks"), withIntermediateDirectories: true)
        try Data().write(to: framework.appending(path: "Frameworks/libInner.dylib"))
        try Data().write(to: app.appending(path: "Frameworks/libSwiftCore.dylib"))
        try fm.createDirectory(at: app.appending(path: "PlugIns/Share.appex"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appending(path: "Watch/Notes Watch.app"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.Notes", "CFBundleExecutable": "Notes"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: app.appending(path: "Info.plist"))
        try Data("old".utf8).write(to: app.appending(path: "embedded.mobileprovision"))
        let profile = root.appending(path: "fresh.mobileprovision")
        try Data("fresh".utf8).write(to: profile)
        return (root, app, profile)
    }

    @Test func preparingStripsExtensionsEmbedsTheProfileAndRewritesTheID() throws {
        let (root, app, profile) = try makeApp()
        defer { try? FileManager.default.removeItem(at: root) }

        let prepared = try IPASigning.prepareForSigning(app: app, profile: profile, bundleID: "com.me.Notes")

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: app.appending(path: "PlugIns").path))
        #expect(!fm.fileExists(atPath: app.appending(path: "Watch").path))
        #expect(try Data(contentsOf: app.appending(path: "embedded.mobileprovision")) == Data("fresh".utf8))

        let data = try Data(contentsOf: app.appending(path: "Info.plist"))
        var format = PropertyListSerialization.PropertyListFormat.xml
        let info = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any]
        #expect(info?["CFBundleIdentifier"] as? String == "com.me.Notes")
        #expect(info?["CFBundleExecutable"] as? String == "Notes")
        #expect(format == .binary)    // left in the format it came in

        #expect(prepared.log.contains { $0.contains("PlugIns") })
        #expect(prepared.log.contains { $0.contains("com.example.Notes → com.me.Notes") })
        #expect(!prepared.looksEncrypted)
    }

    @Test func nestedCodeIsSignedDeepestFirst() throws {
        let (root, app, profile) = try makeApp()
        defer { try? FileManager.default.removeItem(at: root) }

        let prepared = try IPASigning.prepareForSigning(app: app, profile: profile, bundleID: "com.example.Notes")
        let names = prepared.nestedCode.map(\.lastPathComponent)

        #expect(names == ["libInner.dylib", "Kit.framework", "libSwiftCore.dylib"])
        // Extensions were stripped, so they are not in the list.
        #expect(!names.contains("Share.appex"))
        // The app itself is signed last, separately, with entitlements.
        #expect(!names.contains("Notes.app"))
    }

    @Test func anAppStoreEncryptedAppIsFlagged() throws {
        let (root, app, profile) = try makeApp()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: app.appending(path: "SC_Info"), withIntermediateDirectories: true)

        let prepared = try IPASigning.prepareForSigning(app: app, profile: profile, bundleID: "com.example.Notes")

        #expect(prepared.looksEncrypted)
        #expect(prepared.log.allSatisfy { !$0.contains("→") })   // same id, so no rewrite
    }
}

struct TeamDirectoryTests {

    @Test func xcodesAccountListIsRead() {
        let value: [String: Any] = [
            "ACCOUNT-B": [["teamID": "TEAMB00002", "teamName": "Work", "isFreeProvisioningTeam": false]],
            "ACCOUNT-A": [["teamID": "ABCDE12345", "teamName": "Me (Personal Team)",
                           "isFreeProvisioningTeam": NSNumber(value: 1)],
                          ["teamName": "no id, ignored"]]
        ]
        let teams = TeamDirectory.parseXcodeTeams(value)
        #expect(teams.map(\.id) == ["ABCDE12345", "TEAMB00002"])
        #expect(teams[0].isFree)
        #expect(!teams[1].isFree)
        #expect(TeamDirectory.parseXcodeTeams(nil).isEmpty)
        #expect(TeamDirectory.parseXcodeTeams("garbage").isEmpty)
    }

    @Test func aTeamSeenTwiceIsListedOnce() {
        let teams = TeamDirectory.deduplicated([
            DevelopmentTeam(id: "ABCDE12345", name: "Me (Personal Team)", isFree: true),
            DevelopmentTeam(id: "ABCDE12345", name: "Me"),
            DevelopmentTeam(id: "TEAMB00002", name: "Work")
        ])
        #expect(teams.count == 2)
        #expect(teams[0].isFree)
    }

    @Test func theObviousTeamIsPickedAndAnAmbiguousOneIsNot() {
        let free = DevelopmentTeam(id: "ABCDE12345", name: "Me", isFree: true)
        let paid = DevelopmentTeam(id: "TEAMB00002", name: "Work")
        let otherFree = DevelopmentTeam(id: "TEAMC00003", name: "Other", isFree: true)
        #expect(AppState.obviousTeam([paid]) == paid)
        #expect(AppState.obviousTeam([free, paid]) == free)
        #expect(AppState.obviousTeam([free, otherFree]) == nil)
        #expect(AppState.obviousTeam([]) == nil)
    }

    @Test func aProfileNamesItsTeamAndCertificates() throws {
        let certificate = Data([0x30, 0x82, 0x01, 0x02, 0x03])
        let plist: [String: Any] = [
            "UUID": "u", "Name": "n", "TeamName": "Me (Personal Team)",
            "TeamIdentifier": ["ABCDE12345"],
            "ExpirationDate": Date().addingTimeInterval(86_400),
            "DeveloperCertificates": [certificate],
            "Entitlements": ["application-identifier": "ABCDE12345.com.me.Notes", "get-task-allow": true]
        ]
        var data = Data([0x30, 0x82])
        data.append(try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
        data.append(Data([0xDE, 0xAD]))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "airrefresh-\(UUID().uuidString).mobileprovision")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let profile = try #require(ProfileInspector.parse(url))
        #expect(profile.teamIdentifier == "ABCDE12345")
        #expect(profile.getTaskAllow)
        #expect(profile.certificateFingerprints == [ProfileInspector.fingerprint(certificate)])
        #expect(profile.certificateFingerprints[0].count == 40)
    }
}

struct IPASlotTests {

    @Test func anIPANeedsATeamInsteadOfAScheme() {
        var slot = ProjectSlot()
        slot.projectPath = "/Users/me/Downloads/Notes.ipa"
        #expect(slot.isIPA)
        #expect(slot.configurationHint == "Pick the team to sign with")
        slot.teamID = "ABCDE12345"
        #expect(slot.configurationHint == "Pick a device")
        slot.deviceIdentifier = "CORE-ID"
        #expect(slot.configurationHint == nil)
        #expect(slot.isConfigured)
        #expect(slot.displayName == "Notes")
    }

    @Test func theTargetBundleIDPrefersTheOverride() {
        var slot = ProjectSlot()
        slot.sourceBundleIdentifier = "com.someone.Notes"
        #expect(slot.ipaTargetBundleID == "com.someone.Notes")
        slot.bundleIDOverride = "  com.me.Notes "
        #expect(slot.ipaTargetBundleID == "com.me.Notes")
    }

    @Test func ipaFieldsSurviveARoundTripAndOldSavesStillLoad() throws {
        var slot = ProjectSlot()
        slot.projectPath = "/x/Notes.IPA"
        slot.teamID = "ABCDE12345"
        slot.bundleIDOverride = "com.me.Notes"
        slot.sourceBundleIdentifier = "com.someone.Notes"
        let restored = try JSONDecoder().decode([ProjectSlot].self,
                                                from: JSONEncoder().encode([slot])).first
        #expect(restored == slot)
        #expect(restored?.isIPA == true)

        let old = Data(#"[{"projectPath":"/x/Notes.xcodeproj","scheme":"Notes"}]"#.utf8)
        let loaded = try #require(try JSONDecoder().decode([ProjectSlot].self, from: old).first)
        #expect(loaded.teamID.isEmpty && loaded.bundleIDOverride.isEmpty && !loaded.isIPA)
    }

    /// "Change…" used to carry the old project's bundle id, expiry and last
    /// success over to the new one — showing someone else's signing health,
    /// and letting automation run a project that had never been proven.
    @Test func changingTheProjectForgetsWhatTheOldOneTaught() {
        var slot = ProjectSlot()
        slot.projectPath = "/x/Notes.xcodeproj"
        slot.name = "Notes"
        slot.scheme = "Notes"
        slot.bundleIdentifier = "com.example.Notes"
        slot.profileExpiresAt = Date()
        slot.lastSuccessAt = Date()
        slot.deviceIdentifier = "CORE-ID"
        slot.teamID = "ABCDE12345"

        AppState.forgetLearnedState(&slot, previousPath: "/x/Notes.xcodeproj")

        #expect(slot.scheme.isEmpty)
        #expect(slot.bundleIdentifier.isEmpty)
        #expect(slot.profileExpiresAt == nil)
        #expect(!slot.hasProvenItself)
        #expect(slot.name.isEmpty)               // was only ever the file name
        #expect(slot.deviceIdentifier == "CORE-ID")   // the phone did not change
        #expect(slot.teamID == "ABCDE12345")

        var renamed = ProjectSlot()
        renamed.name = "My Budget"
        AppState.forgetLearnedState(&renamed, previousPath: "/x/Budget.xcodeproj")
        #expect(renamed.name == "My Budget")     // a name the user typed stays
    }
}

struct HintPrecisionTests {

    /// "mismatch" alone used to trigger "delete the app from the iPhone" —
    /// for architecture mismatches and anything else with the word in it.
    @Test func aGenericMismatchDoesNotBlameTheInstalledApp() {
        let hints = Hints.forLog(["ld: warning: architecture mismatch in libFoo.a"])
        #expect(!hints.contains { $0.contains("different certificate") })
        let real = Hints.forLog(["ERROR: MismatchedApplicationIdentifierEntitlement"])
        #expect(real.contains { $0.contains("different certificate") })
    }

    @Test func aTakenBundleIDAndTheWeeklyLimitAreExplained() {
        #expect(Hints.forLog(["error: The app identifier \"com.x\" cannot be registered to your development team because it is not available."])
            .contains { $0.contains("belongs to another developer") })
        #expect(Hints.forLog(["Your maximum App ID limit has been reached. You may create up to 10 App IDs every 7 days."])
            .contains { $0.contains("10 new bundle IDs") })
    }
}

struct ArchiveRollbackTests {

    /// The second folder's backup bucket failing to appear used to throw
    /// straight out, leaving the first folder's profiles archived.
    @Test func aBucketThatCannotBeCreatedStillRollsBack() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "airrefresh-bucket-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let first = root.appending(path: "First")
        let second = root.appending(path: "Second")
        let backups = root.appending(path: "Backups")
        for directory in [first, second] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("not a profile".utf8).write(to: directory.appending(path: "p.mobileprovision"))
        }
        // Squat on the second bucket's path with a plain file, for every
        // stamp the archive could pick in the next few seconds.
        for offset in 0..<5 {
            let stamp = DateFormatter.backupStamp.string(from: Date().addingTimeInterval(Double(offset)))
            let bucketParent = backups.appending(path: stamp)
            try fm.createDirectory(at: bucketParent, withIntermediateDirectories: true)
            try Data().write(to: bucketParent.appending(path: "Second"))
        }

        var log: [String] = []
        #expect(throws: (any Error).self) {
            try SigningReset.archiveProfiles(scope: .everything, in: [first, second],
                                             backingUpTo: backups) { log.append($0) }
        }
        #expect(fm.fileExists(atPath: first.appending(path: "p.mobileprovision").path))
        #expect(fm.fileExists(atPath: second.appending(path: "p.mobileprovision").path))
        #expect(log.contains { $0.contains("rolling back 1") })
    }
}
