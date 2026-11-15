import Testing
import Foundation
@testable import AirRefresh

/// The pipeline is the part of AirRefresh that actually spends your time and
/// moves your provisioning profiles around. Everything else in this suite tests
/// a decision; this tests the sequence of consequences that follows from it.
@MainActor
struct PipelineTests {

    // MARK: - Harness

    private func makeRunner(_ fake: FakePipeline) -> (SlotRunner, Box) {
        let runner = SlotRunner(id: UUID(), environment: fake.environment)
        let box = Box()
        runner.onFinished = { outcome, bundleID in
            box.outcome = outcome
            box.bundleID = bundleID
        }
        return (runner, box)
    }

    /// Somewhere to catch the completion callback.
    @MainActor final class Box {
        var outcome: RunOutcome?
        var bundleID: String?
    }

    @discardableResult
    private func run(_ runner: SlotRunner,
                     _ slot: ProjectSlot,
                     trigger: RunTrigger = .manual) async -> SlotRunner {
        await runner.resync(slot: slot, trigger: trigger)?.value
        return runner
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - The whole sequence

    @Test func theHappyPathRunsEveryStepInOrder() async {
        let fake = FakePipeline()
        let (runner, box) = makeRunner(fake)

        await run(runner, FakePipeline.slot())

        #expect(fake.kinds == [.settings, .build, .install, .launch])
        #expect(runner.phase.isSuccess)
        #expect(box.outcome == .succeeded)
        #expect(box.bundleID == "com.example.Notes")
    }

    @Test func theBuildIsTheOneThatMintsAFreshProfile() async {
        let fake = FakePipeline()
        let (runner, _) = makeRunner(fake)
        var slot = FakePipeline.slot()
        slot.configuration = "Debug"

        await run(runner, slot)

        let build = try! #require(fake.command(.build))
        // Without this flag Xcode reuses the dead profile and the whole app is
        // an elaborate way to rebuild something that still does not run.
        #expect(build.contains("-allowProvisioningUpdates"))
        #expect(build.contains("-destination"))
        #expect(build.contains("id=\(slot.deviceUDID)"))
        #expect(build.contains("-project"))
        #expect(build.contains(slot.projectPath))
        #expect(build.contains("-scheme"))
        #expect(build.contains("Notes"))
        #expect(build.last == "build")
    }

    @Test func aWorkspaceIsPassedAsAWorkspace() async {
        let fake = FakePipeline()
        let (runner, _) = makeRunner(fake)
        var slot = FakePipeline.slot()
        slot.projectPath = "/Users/someone/Projects/Notes.xcworkspace"

        await run(runner, slot)

        #expect(fake.command(.build)?.contains("-workspace") == true)
        #expect(fake.command(.build)?.contains("-project") == false)
    }

    @Test func theInstallAndLaunchGoToTheChosenDevice() async {
        let fake = FakePipeline()
        let (runner, _) = makeRunner(fake)
        let slot = FakePipeline.slot()

        await run(runner, slot)

        let install = try! #require(fake.command(.install))
        #expect(install.contains("--device"))
        #expect(install.contains(slot.deviceIdentifier))
        #expect(install.contains("/build/Products/Debug-iphoneos/Notes.app"))

        let launch = try! #require(fake.command(.launch))
        #expect(launch.contains("--terminate-existing"))
        #expect(launch.contains("com.example.Notes"))
    }

    // MARK: - What the signing reset is aimed at

    @Test func theResetIsAimedAtTheAppAboutToBeBuilt() async {
        let fake = FakePipeline()
        let (runner, _) = makeRunner(fake)

        await run(runner, FakePipeline.slot())

        // Not `.everything`: that is what used to make two automated slots take
        // turns destroying each other's signing.
        #expect(fake.archiveScopes == [.coveringBundleID("com.example.Notes")])
    }

    @Test func withNoIdeaWhatIsBeingBuiltTheResetFallsBackToTheHammer() async {
        let fake = FakePipeline()
        fake.buildSettingsJSON = nil
        let (runner, _) = makeRunner(fake)

        await run(runner, FakePipeline.slot())

        #expect(fake.archiveScopes == [.everything])
    }

    @Test func aBundleIDLearnedLastTimeBeatsTheHammer() async {
        let fake = FakePipeline()
        fake.buildSettingsJSON = nil
        let (runner, _) = makeRunner(fake)
        var slot = FakePipeline.slot()
        slot.bundleIdentifier = "com.example.Remembered"

        await run(runner, slot)

        #expect(fake.archiveScopes == [.coveringBundleID("com.example.Remembered")])
    }

    @Test func signingResetCanBeTurnedOff() async {
        let fake = FakePipeline()
        let (runner, _) = makeRunner(fake)
        var slot = FakePipeline.slot()
        slot.resetSigning = false

        await run(runner, slot)

        #expect(fake.archiveScopes.isEmpty)
        #expect(fake.kinds == [.settings, .build, .install, .launch])
    }

    @Test func cleaningIsOffByDefaultAndOnlyEverTouchesThisSlot() async {
        let fake = FakePipeline()
        let (runner, _) = makeRunner(fake)
        var slot = FakePipeline.slot()

        await run(runner, slot)
        #expect(fake.cleanedSlots.isEmpty)

        slot.cleanBuild = true
        let (second, _) = makeRunner(fake)
        await run(second, slot)
        #expect(fake.cleanedSlots == [slot.id])
    }

    @Test func launchingAfterInstallIsOptional() async {
        let fake = FakePipeline()
        let (runner, _) = makeRunner(fake)
        var slot = FakePipeline.slot()
        slot.launchAfterInstall = false

        await run(runner, slot)

        #expect(fake.kinds == [.settings, .build, .install])
        #expect(runner.phase.isSuccess)
    }

    // MARK: - Failure

    @Test func aFailedBuildNeverReachesThePhone() async {
        let fake = FakePipeline()
        fake.exitCodes[.build] = 65
        fake.output[.build] = ["** BUILD FAILED **"]
        let (runner, box) = makeRunner(fake)

        await run(runner, FakePipeline.slot())

        #expect(fake.kinds == [.settings, .build])
        #expect(runner.phase == .failed("Build failed (exit code 65)"))
        #expect(box.outcome == .failed)
    }

    @Test func aFailedInstallNeverLaunches() async {
        let fake = FakePipeline()
        fake.exitCodes[.install] = 1
        let (runner, box) = makeRunner(fake)

        await run(runner, FakePipeline.slot())

        #expect(fake.kinds == [.settings, .build, .install])
        #expect(runner.phase == .failed("Install failed (exit code 1)"))
        #expect(box.outcome == .failed)
    }

    @Test func aFailureThatCannotBeExplainedStillFails() async {
        let fake = FakePipeline()
        fake.archiveError = ShellError.launchFailed("disk is full")
        let (runner, box) = makeRunner(fake)

        await run(runner, FakePipeline.slot())

        #expect(runner.phase.isFailure)
        #expect(box.outcome == .failed)
        #expect(!fake.issued(.build))
    }

    /// Hints used to be matched against the entire log, so a word in one step's
    /// output could put confident, wrong advice under a later failure.
    @Test func adviceComesOnlyFromTheCommandThatActuallyFailed() async {
        let fake = FakePipeline()
        fake.output[.build] = ["note: application-identifier mismatch in an old warning"]
        fake.exitCodes[.install] = 1
        fake.output[.install] = ["error: could not find device"]
        let (runner, _) = makeRunner(fake)

        await run(runner, FakePipeline.slot())

        let advice = runner.lines.map(\.text).filter { $0.hasPrefix("💡") }
        #expect(advice.contains { $0.contains("dropped off the network") })
        #expect(!advice.contains { $0.contains("different certificate") })
    }

    // MARK: - Stopping

    @Test func stopEndsTheRunWithoutBlamingTheProject() async {
        let fake = FakePipeline()
        fake.hangs = [.build]
        let (runner, box) = makeRunner(fake)

        let task = runner.resync(slot: FakePipeline.slot())
        await waitUntil { runner.phase == .building }
        runner.stop()
        await task?.value

        #expect(runner.phase == .cancelled)
        // Not `.failed`: a two-hour backoff and, after three of them, paused
        // automation is a heavy price for pressing a button.
        #expect(box.outcome == .stopped)
        #expect(runner.plainLog.contains("Stopped by user."))
        #expect(!fake.issued(.install))
    }

    /// The guard against a second run used to read state that only the async
    /// task set, so two clicks in one turn of the main actor both passed it.
    @Test func twoRefreshesInOneTurnStartOneRun() async {
        let fake = FakePipeline()
        fake.hangs = [.build]
        let (runner, _) = makeRunner(fake)
        let slot = FakePipeline.slot()

        let first = runner.resync(slot: slot)
        let second = runner.resync(slot: slot)
        await waitUntil { runner.phase == .building }
        runner.stop()
        await first?.value
        await second?.value

        #expect(fake.kinds.filter { $0 == .build }.count == 1)
    }

    // MARK: - Finding the built app

    /// `-showBuildSettings` promises a path; the build is free to put the app
    /// somewhere else. When the promise does not hold up, scan for it.
    @Test func theProductIsFoundByScanningWhenTheSettingsPathIsWrong() async {
        let slot = FakePipeline.slot()
        let products = SlotRunner.productsDirectory(
            derivedData: SigningReset.derivedDataDirectory(for: slot.id),
            configuration: slot.configuration
        )
        let found = products.appending(path: "Notes.app")

        let fake = FakePipeline()
        fake.existingFiles = []                       // the promised path is a lie
        fake.appBundles = [products.path: [found]]
        fake.bundleIDs = [found.path: "com.example.Scanned"]
        let (runner, box) = makeRunner(fake)

        await run(runner, slot)

        #expect(box.outcome == .succeeded)
        #expect(box.bundleID == "com.example.Scanned")
        #expect(fake.command(.install)?.contains(found.path) == true)
    }

    @Test func aMissingProductIsReportedRatherThanCrashed() async {
        let fake = FakePipeline()
        fake.existingFiles = []
        let (runner, box) = makeRunner(fake)

        await run(runner, FakePipeline.slot())

        #expect(box.outcome == .failed)
        #expect(runner.phase.isFailure)
        #expect(!fake.issued(.install))
    }

    // MARK: - What the run reports back

    @Test func theFreshProfilesLifetimeIsReadBackIntoTheLog() async {
        let fake = FakePipeline()
        fake.profile = ProvisioningProfile(
            url: URL(fileURLWithPath: "/tmp/new.mobileprovision"),
            uuid: "u", name: "n", teamName: "t",
            applicationIdentifier: "ABCDE12345.com.example.Notes",
            creationDate: Date(),
            expirationDate: Date().addingTimeInterval(7 * 86_400 + 3600)
        )
        let (runner, _) = makeRunner(fake)

        await run(runner, FakePipeline.slot())

        #expect(fake.bundleIDsLookedUp == ["com.example.Notes"])
        #expect(runner.plainLog.contains("new profile valid for 7 more day(s)"))
    }

    @Test func theLogSaysWhoAskedForTheRun() async {
        let fake = FakePipeline()
        let (manual, _) = makeRunner(fake)
        await run(manual, FakePipeline.slot(), trigger: .manual)
        #expect(manual.plainLog.contains("(manual)"))

        let (automatic, _) = makeRunner(fake)
        await run(automatic, FakePipeline.slot(), trigger: .automatic)
        #expect(automatic.plainLog.contains("(automatic)"))
    }

    @Test func clearingTheLogKeepsTheOutcome() async {
        let fake = FakePipeline()
        fake.exitCodes[.build] = 65
        let (runner, _) = makeRunner(fake)

        await run(runner, FakePipeline.slot())
        #expect(!runner.lines.isEmpty)

        runner.clearLog()
        #expect(runner.lines.isEmpty)
        // The card's status is a fact about the last run, not part of its log.
        #expect(runner.phase == .failed("Build failed (exit code 65)"))
    }

    // MARK: - The standalone hammer

    @Test func resetSigningOnlyTakesEverythingAndBuildsNothing() async {
        let fake = FakePipeline()
        let runner = SlotRunner(id: UUID(), environment: fake.environment)

        runner.resetSigningOnly()
        await waitUntil { !runner.isRunning }

        #expect(fake.archiveScopes == [.everything])
        #expect(fake.commands.isEmpty)
        #expect(!runner.phase.isFailure)
    }

    @Test func aFailedResetSaysSoRatherThanClaimingSuccess() async {
        let fake = FakePipeline()
        fake.archiveError = ShellError.launchFailed("permission denied")
        let runner = SlotRunner(id: UUID(), environment: fake.environment)

        runner.resetSigningOnly()
        await waitUntil { !runner.isRunning }

        #expect(runner.phase == .failed("Signing reset failed"))
    }
}

