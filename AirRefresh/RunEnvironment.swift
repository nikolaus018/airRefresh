import Foundation

/// Everything ``SlotRunner`` reaches outside itself for, gathered behind one
/// struct of closures.
///
/// The pipeline is the part of AirRefresh that spawns `xcodebuild`, moves
/// provisioning profiles out of `~/Library` and installs software on a phone —
/// which is exactly the part a test suite cannot be allowed near, and exactly
/// the part that most needs one. With the world behind this seam the whole
/// inspect → reset → build → install → launch sequence can be driven against a
/// fake: every branch, every failure, in milliseconds and with nothing on the
/// machine touched.
///
/// `MainActor`-isolated on purpose. `SlotRunner` is too, and keeping the
/// closures on the same actor is what lets them capture the runner's `log`
/// without any of them having to be `Sendable`.
@MainActor
struct RunEnvironment {

    /// Runs a command, streaming merged stdout/stderr.
    var stream: (String, [String]) -> AsyncThrowingStream<ShellEvent, Error>

    /// Runs a command to completion and hands back everything it printed.
    var capture: (String, [String]) async throws -> (exitCode: Int32, output: String)

    /// Moves the provisioning profiles `scope` selects into a backup folder,
    /// handing back what it would have logged along the way.
    ///
    /// Async, and the live version does the work off the main actor: scanning
    /// and parsing every profile on the Mac and then moving files is not much,
    /// but it is not nothing, and it has no business happening on the thread
    /// that is drawing the log it writes into.
    var archiveProfiles: (SigningReset.Scope) async throws -> (outcome: SigningReset.Outcome, log: [String])

    /// Throws away AirRefresh's own build output for one slot.
    var cleanDerivedData: (UUID) async throws -> [String]

    var fileExists: (URL) -> Bool

    /// The `.app` bundles sitting in a build products directory.
    var appBundles: (URL) -> [URL]

    /// Reads `CFBundleIdentifier` out of a built `.app`.
    var bundleIdentifier: (URL) throws -> String

    /// The profile now covering a bundle id, read back after a successful build.
    var profileCovering: (String) -> ProvisioningProfile?

    // MARK: .ipa slots

    /// Empties a scratch directory AirRefresh owns, creating it if needed.
    var resetDirectory: (URL) throws -> Void

    /// Writes the helper project whose build mints the profile, returning
    /// the `.xcodeproj`.
    var writeStubProject: (IPASigning.StubProject) throws -> URL

    /// Parses a single profile file — the one embedded in the helper app.
    var readProfile: (URL) -> ProvisioningProfile?

    /// Strips, re-provisions and re-identifies an unpacked `.app`.
    var prepareForSigning: (_ app: URL, _ profile: URL, _ bundleID: String) throws -> IPASigning.PreparedApp

    var writeEntitlements: (IPASigning.Entitlements, URL) throws -> Void

    static let live = RunEnvironment(
        stream: { Shell.stream($0, $1) },
        capture: { try await Shell.capture($0, $1) },
        archiveProfiles: { scope in
            try await Task.detached(priority: .userInitiated) {
                var log: [String] = []
                let outcome = try SigningReset.archiveProfiles(scope: scope) { log.append($0) }
                return (outcome, log)
            }.value
        },
        cleanDerivedData: { slotID in
            try await Task.detached(priority: .userInitiated) {
                var log: [String] = []
                try SigningReset.cleanDerivedData(for: slotID) { log.append($0) }
                return log
            }.value
        },
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        appBundles: { directory in
            ((try? FileManager.default.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "app" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        },
        bundleIdentifier: { appURL in
            let plistURL = appURL.appending(path: "Info.plist")
            let data = try Data(contentsOf: plistURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            guard let identifier = plist?["CFBundleIdentifier"] as? String else {
                throw PipelineError("No CFBundleIdentifier in \(plistURL.path)")
            }
            return identifier
        },
        profileCovering: { ProfileInspector.profile(covering: $0) },
        resetDirectory: { directory in
            let fm = FileManager.default
            if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        },
        writeStubProject: { try IPASigning.writeStubProject($0) },
        readProfile: { ProfileInspector.parse($0) },
        prepareForSigning: { try IPASigning.prepareForSigning(app: $0, profile: $1, bundleID: $2) },
        writeEntitlements: { try IPASigning.writeEntitlements($0, to: $1) }
    )
}
