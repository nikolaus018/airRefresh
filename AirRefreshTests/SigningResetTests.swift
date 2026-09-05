import Testing
import Foundation
@testable import AirRefresh

/// Archiving profiles is the one destructive thing AirRefresh does, so the rule
/// deciding *which* profiles get moved is worth pinning down precisely.
struct SigningResetTests {

    private func profile(bundleID: String, expiresInDays: Double) -> ProvisioningProfile {
        ProvisioningProfile(
            url: URL(fileURLWithPath: "/tmp/\(bundleID).mobileprovision"),
            uuid: UUID().uuidString,
            name: bundleID,
            teamName: "Test Team",
            applicationIdentifier: "ABCDE12345.\(bundleID)",
            creationDate: Date().addingTimeInterval(-86_400),
            expirationDate: Date().addingTimeInterval(expiresInDays * 86_400)
        )
    }

    @Test func targetedResetTakesTheProfileForThisApp() {
        let mine = profile(bundleID: "com.example.Notes", expiresInDays: 1)
        #expect(SigningReset.shouldArchive(mine, scope: .coveringBundleID("com.example.Notes")))
    }

    /// The bug this whole scope mechanism exists for: refreshing one project
    /// used to archive the profiles of every *other* project on the machine.
    @Test func targetedResetLeavesOtherProjectsAlone() {
        let theirs = profile(bundleID: "com.example.Timer", expiresInDays: 5)
        #expect(!SigningReset.shouldArchive(theirs, scope: .coveringBundleID("com.example.Notes")))
    }

    @Test func targetedResetStillSweepsUpDeadProfiles() {
        let stale = profile(bundleID: "com.someone.Else", expiresInDays: -1)
        #expect(SigningReset.shouldArchive(stale, scope: .coveringBundleID("com.example.Notes")))
    }

    @Test func wildcardProfilesCountAsCoverage() {
        let wildcard = profile(bundleID: "com.example.*", expiresInDays: 3)
        #expect(SigningReset.shouldArchive(wildcard, scope: .coveringBundleID("com.example.Notes")))
        #expect(!SigningReset.shouldArchive(wildcard, scope: .coveringBundleID("net.other.Notes")))
    }

    /// If we cannot read a profile we cannot claim it is ours, so we do not
    /// touch it — unless the user explicitly asked for the hammer.
    @Test func unreadableProfilesAreLeftAloneWhenTargeting() {
        #expect(!SigningReset.shouldArchive(nil, scope: .coveringBundleID("com.example.Notes")))
        #expect(SigningReset.shouldArchive(nil, scope: .everything))
    }

    @Test func theHammerTakesEverything() {
        let healthy = profile(bundleID: "com.someone.Else", expiresInDays: 300)
        #expect(SigningReset.shouldArchive(healthy, scope: .everything))
    }

    @Test func backupNamesNeverCollide() throws {
        let bucket = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "airrefresh-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bucket) }

        let source = URL(fileURLWithPath: "/tmp/Team.mobileprovision")

        let first = SigningReset.uniqueDestination(for: source, in: bucket)
        #expect(first.lastPathComponent == "Team.mobileprovision")
        try Data().write(to: first)

        let second = SigningReset.uniqueDestination(for: source, in: bucket)
        #expect(second.lastPathComponent == "Team-1.mobileprovision")
        try Data().write(to: second)

        #expect(SigningReset.uniqueDestination(for: source, in: bucket).lastPathComponent
                == "Team-2.mobileprovision")
    }

    @Test func perSlotBuildDirectoriesDoNotOverlap() {
        let a = SigningReset.derivedDataDirectory(for: UUID())
        let b = SigningReset.derivedDataDirectory(for: UUID())
        #expect(a != b)
        // Never anywhere near the user's own DerivedData.
        #expect(a.path.contains("Application Support/AirRefresh"))
    }
}

/// End-to-end coverage of the archiving itself, against a scratch directory
/// rather than the real `~/Library`. This is the only code in the app that
/// moves the user's files around, so "which files moved" is worth asserting
/// exactly rather than in spirit.
struct ProfileArchivingTests {

    private struct Scratch {
        let root: URL
        let profiles: URL
        let backups: URL
    }

    private func makeScratch() throws -> Scratch {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "airrefresh-archive-\(UUID().uuidString)")
        let profiles = root.appending(path: "Provisioning Profiles")
        let backups = root.appending(path: "Backups")
        try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
        return Scratch(root: root, profiles: profiles, backups: backups)
    }

    /// Writes a file shaped enough like a profile for `ProfileInspector` to read.
    @discardableResult
    private func plant(_ name: String,
                       bundleID: String,
                       expiresInDays: Double,
                       into directory: URL) throws -> URL {
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(expiresInDays * 86_400))
        let payload = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
            <key>UUID</key><string>\(UUID().uuidString)</string>
            <key>Name</key><string>\(name)</string>
            <key>ExpirationDate</key><date>\(expiry)</date>
            <key>Entitlements</key><dict>
                <key>application-identifier</key><string>ABCDE12345.\(bundleID)</string>
            </dict>
        </dict></plist>
        """
        let url = directory.appending(path: "\(name).mobileprovision")
        var data = Data([0x30, 0x82])
        data.append(Data(payload.utf8))
        try data.write(to: url)
        return url
    }

    private func names(in directory: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent))
    }

    @Test func aTargetedResetMovesOnlyWhatItHasTo() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }

        try plant("mine", bundleID: "com.example.Notes", expiresInDays: 1, into: scratch.profiles)
        try plant("someone-elses", bundleID: "com.other.Timer", expiresInDays: 200, into: scratch.profiles)
        try plant("long-dead", bundleID: "com.other.Old", expiresInDays: -3, into: scratch.profiles)
        try plant("wildcard", bundleID: "com.example.*", expiresInDays: 4, into: scratch.profiles)

        let outcome = try SigningReset.archiveProfiles(
            scope: .coveringBundleID("com.example.Notes"),
            in: [scratch.profiles],
            backingUpTo: scratch.backups
        ) { _ in }

        #expect(outcome.moved == 3)   // mine + the expired one + the wildcard
        #expect(outcome.kept == 1)
        #expect(names(in: scratch.profiles) == ["someone-elses.mobileprovision"])
    }

    /// Losing a profile to a bad reset would mean re-signing from scratch, so
    /// everything archived has to still be on disk afterwards.
    @Test func archivedProfilesAreMovedNotDestroyed() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }

        let original = try plant("mine", bundleID: "com.example.Notes",
                                 expiresInDays: 1, into: scratch.profiles)
        let contents = try Data(contentsOf: original)

        let outcome = try SigningReset.archiveProfiles(
            scope: .coveringBundleID("com.example.Notes"),
            in: [scratch.profiles],
            backingUpTo: scratch.backups
        ) { _ in }

        let backup = try #require(outcome.backup)
        let recovered = backup.appending(path: "Provisioning Profiles/mine.mobileprovision")
        #expect(FileManager.default.fileExists(atPath: recovered.path))
        #expect(try Data(contentsOf: recovered) == contents)
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func theHammerEmptiesTheFolder() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }

        try plant("a", bundleID: "com.a.One", expiresInDays: 300, into: scratch.profiles)
        try plant("b", bundleID: "com.b.Two", expiresInDays: 300, into: scratch.profiles)

        let outcome = try SigningReset.archiveProfiles(
            scope: .everything, in: [scratch.profiles], backingUpTo: scratch.backups
        ) { _ in }

        #expect(outcome.moved == 2)
        #expect(names(in: scratch.profiles).isEmpty)
    }

    /// Files that are not profiles share these folders. Touching them would be
    /// meddling with something that is none of our business.
    @Test func nonProfileFilesAreNeverTouched() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }

        try Data("notes".utf8).write(to: scratch.profiles.appending(path: "README.txt"))
        try plant("mine", bundleID: "com.example.Notes", expiresInDays: 1, into: scratch.profiles)

        _ = try SigningReset.archiveProfiles(
            scope: .everything, in: [scratch.profiles], backingUpTo: scratch.backups
        ) { _ in }

        #expect(names(in: scratch.profiles) == ["README.txt"])
    }

    @Test func aMissingFolderIsNotAnError() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }

        let outcome = try SigningReset.archiveProfiles(
            scope: .everything,
            in: [scratch.root.appending(path: "does-not-exist")],
            backingUpTo: scratch.backups
        ) { _ in }

        #expect(outcome.moved == 0)
        #expect(outcome.backup == nil)
    }

    /// Nothing to do means nothing on disk — no empty timestamped folders
    /// piling up in Application Support every time the scheduler ticks.
    /// The one outcome worse than "the reset failed" is "the reset half
    /// worked": some apps re-signed, others left with their profile gone and
    /// nothing on screen saying which is which.
    @Test func aResetThatFailsPartWayPutsEverythingBack() throws {
        let scratch = try makeScratch()
        defer {
            // Make sure the read-only directory cannot outlive the test.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: scratch.root.appending(path: "Locked").path)
            try? FileManager.default.removeItem(at: scratch.root)
        }

        let locked = scratch.root.appending(path: "Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)

        try plant("First", bundleID: "com.example.Notes", expiresInDays: 3, into: scratch.profiles)
        try plant("Second", bundleID: "com.example.Notes", expiresInDays: 3, into: locked)

        // A source directory nothing can be moved out of.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        var log: [String] = []
        #expect(throws: (any Error).self) {
            try SigningReset.archiveProfiles(scope: .everything,
                                             in: [scratch.profiles, locked],
                                             backingUpTo: scratch.backups) { log.append($0) }
        }

        // The profile from the first, perfectly writable directory is back.
        #expect(names(in: scratch.profiles) == ["First.mobileprovision"])
        #expect(log.contains { $0.contains("rolling back") })
    }

    @Test func aNoOpResetLeavesNoBackupFolderBehind() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }

        try plant("someone-elses", bundleID: "com.other.Timer",
                  expiresInDays: 200, into: scratch.profiles)

        let outcome = try SigningReset.archiveProfiles(
            scope: .coveringBundleID("com.example.Notes"),
            in: [scratch.profiles],
            backingUpTo: scratch.backups
        ) { _ in }

        #expect(outcome.moved == 0)
        #expect(!FileManager.default.fileExists(atPath: scratch.backups.path))
    }
}
