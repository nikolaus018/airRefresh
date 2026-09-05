import Testing
import Foundation
@testable import AirRefresh

/// Reading the bundle id out of `xcodebuild -showBuildSettings` is what makes
/// the signing reset targeted, so it has to survive xcodebuild's habit of
/// printing notes and warnings before the JSON it was asked for.
@MainActor
struct BuildSettingsParsingTests {

    private let json = """
    [
      {
        "action": "build",
        "target": "AirRefresh",
        "buildSettings": {
          "PRODUCT_BUNDLE_IDENTIFIER": "com.example.Notes",
          "FULL_PRODUCT_NAME": "Notes.app",
          "TARGET_BUILD_DIR": "/tmp/dd/Build/Products/Debug-iphoneos"
        }
      }
    ]
    """

    @Test func findsTheAppProduct() throws {
        let settings = try #require(SlotRunner.parseBuildSettings(json))
        #expect(settings.bundleID == "com.example.Notes")
        #expect(settings.appURL.path == "/tmp/dd/Build/Products/Debug-iphoneos/Notes.app")
    }

    @Test func skipsThePreambleXcodebuildPrints() throws {
        let noisy = """
        Command line invocation:
            /usr/bin/xcodebuild -showBuildSettings

        note: Using codesigning identity override
        warning: Skipping duplicate build file

        \(json)
        """
        let settings = try #require(SlotRunner.parseBuildSettings(noisy))
        #expect(settings.bundleID == "com.example.Notes")
    }

    /// Test bundles and app extensions show up in the same dump. Only the
    /// `.app` is something we can hand to `devicectl`.
    @Test func ignoresTargetsThatAreNotApps() throws {
        let mixed = """
        [
          { "target": "NotesTests",
            "buildSettings": {
              "PRODUCT_BUNDLE_IDENTIFIER": "com.example.NotesTests",
              "FULL_PRODUCT_NAME": "NotesTests.xctest",
              "TARGET_BUILD_DIR": "/tmp/dd" } },
          { "target": "Notes",
            "buildSettings": {
              "PRODUCT_BUNDLE_IDENTIFIER": "com.example.Notes",
              "FULL_PRODUCT_NAME": "Notes.app",
              "TARGET_BUILD_DIR": "/tmp/dd" } }
        ]
        """
        #expect(SlotRunner.parseBuildSettings(mixed)?.bundleID == "com.example.Notes")
    }

    @Test func failsQuietlyRatherThanGuessing() {
        #expect(SlotRunner.parseBuildSettings("") == nil)
        #expect(SlotRunner.parseBuildSettings("xcodebuild: error: no such scheme") == nil)
        #expect(SlotRunner.parseBuildSettings("[]") == nil)
        // An entry with no bundle id is not good enough to reset signing with.
        #expect(SlotRunner.parseBuildSettings("""
        [{ "buildSettings": { "FULL_PRODUCT_NAME": "Notes.app", "TARGET_BUILD_DIR": "/tmp" } }]
        """) == nil)
    }
}

@MainActor
struct LogClassificationTests {

    @Test func failuresAreCalledOut() {
        #expect(SlotRunner.classify("/Users/me/App.swift:12:5: error: cannot find 'foo'") == .failure)
        #expect(SlotRunner.classify("** BUILD FAILED **") == .failure)
        #expect(SlotRunner.classify("Swift runtime failure: fatal error") == .failure)
    }

    @Test func successesAreCalledOut() {
        #expect(SlotRunner.classify("** BUILD SUCCEEDED **") == .success)
    }

    /// The old rule matched any line containing "succeeded", which lit up
    /// ordinary chatter in green.
    @Test func ordinaryOutputStaysOrdinary() {
        #expect(SlotRunner.classify("CompileSwift normal arm64 App.swift") == .output)
        #expect(SlotRunner.classify("Signing Identity: Apple Development: me@example.com") == .output)
        #expect(SlotRunner.classify("note: Run script build phase succeeded for target") == .output)
    }
}

struct HintTests {

    @Test func theThreeAppLimitIsExplained() {
        let hints = Hints.forLog(["error: maximum number of apps for free development profiles has been reached"])
        #expect(hints.contains { $0.contains("free Apple ID allows 3 apps") })
    }

    @Test func aMissingTeamPointsAtXcodeSettings() {
        let hints = Hints.forLog(["error: Signing for \"Notes\" requires a development team."])
        #expect(hints.contains { $0.contains("Signing & Capabilities") })
    }

    @Test func anUnsharedSchemeIsDiagnosed() {
        let hints = Hints.forLog(["xcodebuild: error: The scheme \"Notes\" is not currently configured for the build action."])
        #expect(hints.contains { $0.contains("Manage Schemes") })
    }

    /// Taken verbatim from a real failed run rather than from memory: the
    /// previous patterns were a guess, and missed it.
    @Test func devicectlsOwnWordingIsRecognised() {
        let hints = Hints.forLog([
            "ERROR: The specified device was not found. (Name: not-a-real-device) (com.apple.dt.CoreDeviceError error 1000)",
            "        DeviceName = not-a-real-device"
        ])
        #expect(hints.contains { $0.contains("dropped off the network") })
    }

    @Test func aCleanBuildProducesNoAdvice() {
        #expect(Hints.forLog(["** BUILD SUCCEEDED **", "Touching Notes.app"]).isEmpty)
    }
}
