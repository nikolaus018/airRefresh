import Foundation
@testable import AirRefresh

/// A stand-in for everything ``SlotRunner`` does to the machine.
///
/// Nothing here spawns a process, moves a provisioning profile or touches the
/// filesystem, so the pipeline tests can exercise the one code path in
/// AirRefresh that is genuinely destructive without being destructive.
@MainActor
final class FakePipeline {

    // MARK: - What the runner asked for

    /// Every command, as `[tool] + arguments`, in the order it was issued.
    private(set) var commands: [[String]] = []
    private(set) var archiveScopes: [SigningReset.Scope] = []
    private(set) var cleanedSlots: [UUID] = []
    private(set) var bundleIDsLookedUp: [String] = []

    // MARK: - What it gets back

    /// Exit code per command kind. Anything unlisted succeeds.
    var exitCodes: [Kind: Int32] = [:]
    /// Output lines per command kind.
    var output: [Kind: [String]] = [:]
    /// Commands of these kinds never finish until the run is cancelled.
    var hangs: Set<Kind> = []

    var buildSettingsJSON: String? = FakePipeline.settingsJSON(
        bundleID: "com.example.Notes",
        appPath: "/build/Products/Debug-iphoneos/Notes.app"
    )
    var buildSettingsExitCode: Int32 = 0

    var archiveOutcome = SigningReset.Outcome(moved: 2, kept: 5, backup: URL(fileURLWithPath: "/backups/x"))
    var archiveError: Error?
    var cleanError: Error?

    var existingFiles: Set<String> = ["/build/Products/Debug-iphoneos/Notes.app"]
    var appBundles: [String: [URL]] = [:]
    var bundleIDs: [String: String] = [:]
    var bundleIDError: Error?
    var profile: ProvisioningProfile?

    /// Which step a command belongs to. Keyed on the arguments rather than the
    /// whole string so a test can say "make the install fail" without repeating
    /// the argument list the runner happens to build.
    enum Kind: Hashable { case settings, build, install, launch, other }

    static func kind(of arguments: [String]) -> Kind {
        if arguments.contains("-showBuildSettings") { return .settings }
        if arguments.contains("xcodebuild") { return .build }
        if arguments.contains("install") { return .install }
        if arguments.contains("launch") { return .launch }
        return .other
    }

    // MARK: - Convenience for assertions

    func command(_ kind: Kind) -> [String]? {
        commands.first { Self.kind(of: $0) == kind }
    }

    func issued(_ kind: Kind) -> Bool { command(kind) != nil }

    var kinds: [Kind] { commands.map { Self.kind(of: $0) } }

    // MARK: - The environment itself

    var environment: RunEnvironment {
        RunEnvironment(
            stream: { [weak self] tool, arguments in
                guard let self else { return AsyncThrowingStream { $0.finish() } }
                self.commands.append([tool] + arguments)
                let kind = Self.kind(of: arguments)
                let lines = self.output[kind] ?? []
                let code = self.exitCodes[kind] ?? 0
                let hangs = self.hangs.contains(kind)
                return AsyncThrowingStream { continuation in
                    for line in lines { continuation.yield(.line(line)) }
                    // A hanging command finishes only when the consumer's task
                    // is cancelled, which is exactly what Stop does.
                    guard !hangs else { return }
                    continuation.yield(.finished(exitCode: code))
                    continuation.finish()
                }
            },
            capture: { [weak self] tool, arguments in
                guard let self else { return (0, "") }
                self.commands.append([tool] + arguments)
                return (self.buildSettingsExitCode, self.buildSettingsJSON ?? "")
            },
            archiveProfiles: { [weak self] scope in
                guard let self else { return (SigningReset.Outcome(moved: 0, kept: 0, backup: nil), []) }
                self.archiveScopes.append(scope)
                if let error = self.archiveError { throw error }
                return (self.archiveOutcome, ["· scope: \(scope.summary)"])
            },
            cleanDerivedData: { [weak self] slotID in
                guard let self else { return [] }
                self.cleanedSlots.append(slotID)
                if let error = self.cleanError { throw error }
                return ["· removed build output"]
            },
            fileExists: { [weak self] url in
                self?.existingFiles.contains(url.path) ?? false
            },
            appBundles: { [weak self] directory in
                self?.appBundles[directory.path] ?? []
            },
            bundleIdentifier: { [weak self] appURL in
                guard let self else { return "" }
                if let error = self.bundleIDError { throw error }
                return self.bundleIDs[appURL.path] ?? "com.example.Fallback"
            },
            profileCovering: { [weak self] bundleID in
                self?.bundleIDsLookedUp.append(bundleID)
                return self?.profile
            }
        )
    }

    // MARK: - Fixtures

    static func settingsJSON(bundleID: String, appPath: String) -> String {
        let url = URL(fileURLWithPath: appPath)
        return """
        [{"target":"Notes","buildSettings":{
            "TARGET_BUILD_DIR":"\(url.deletingLastPathComponent().path)",
            "FULL_PRODUCT_NAME":"\(url.lastPathComponent)",
            "PRODUCT_BUNDLE_IDENTIFIER":"\(bundleID)"}}]
        """
    }

    static func slot(configured: Bool = true) -> ProjectSlot {
        var slot = ProjectSlot()
        slot.name = "Notes"
        slot.projectPath = "/Users/someone/Projects/Notes.xcodeproj"
        slot.scheme = "Notes"
        slot.deviceUDID = "00008120-000A1B2C3D4E5F60"
        slot.deviceIdentifier = "A1B2C3D4-0000-1111-2222-333344445555"
        slot.deviceName = "iPhone"
        if !configured { slot.scheme = "" }
        return slot
    }
}
