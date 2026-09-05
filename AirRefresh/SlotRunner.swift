import Foundation
import Observation

/// Drives one slot through the full inspect → reset → build → install → launch
/// pipeline and publishes a live log while it does.
@MainActor
@Observable
final class SlotRunner: Identifiable {
    let id: UUID
    private(set) var phase: SyncPhase = .idle
    private(set) var lines: [LogLine] = []
    private(set) var startedAt: Date?
    private(set) var trigger: RunTrigger = .manual
    /// Reports how a run settled, and the bundle identifier it learned.
    var onFinished: ((RunOutcome, String) -> Void)?
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var timedOut = false
    private var stoppedByUser = false

    /// Roughly a few thousand lines of xcodebuild output is plenty to debug with.
    private let maxLines = 4000

    /// Lines written but not yet handed to the UI.
    private var pending: [LogLine] = []
    private var flushTask: Task<Void, Never>?

    /// How often the console is allowed to change. `xcodebuild` emits lines
    /// faster than SwiftUI can lay them out, and publishing each one on its own
    /// spends the whole build re-rendering a list instead of reading a pipe.
    private static let flushInterval = Duration.milliseconds(80)

    /// A refresh that has not finished by now is not going to. Left alone, one
    /// wedged `xcodebuild` would sit there holding `isAnyRunning` true and
    /// block every future automatic refresh — which is the one failure an
    /// unattended tool cannot afford.
    static let runTimeout: TimeInterval = 30 * 60

    /// Everything outside this class that the pipeline touches. Injected so the
    /// whole sequence can be driven against a fake — see `PipelineTests`.
    private let env: RunEnvironment

    init(id: UUID, environment: RunEnvironment = .live) {
        self.id = id
        self.env = environment
    }

    var isRunning: Bool { phase.isRunning }

    var plainLog: String {
        (lines + pending).map(\.text).joined(separator: "\n")
    }

    // MARK: - Entry points

    /// Returns the running task so a caller can wait for this slot to settle
    /// before starting the next one.
    @discardableResult
    func resync(slot: ProjectSlot, trigger: RunTrigger = .manual) -> Task<Void, Never>? {
        guard !isRunning else { return task }
        self.trigger = trigger
        timedOut = false
        stoppedByUser = false

        // Claim the runner *synchronously*. A `Task { }` created on the main
        // actor does not begin until this turn of the run loop ends, so leaving
        // `phase` at `.idle` here would let a double-click — or ⌘1 held down —
        // past the guard twice and start two `xcodebuild`s over one build
        // directory, with only the second reachable by Stop.
        beginRun()

        let work = Task { [weak self] in
            guard let self else { return }
            await self.perform(slot: slot)
        }
        task = work

        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.runTimeout))
            guard let self, self.isRunning, !work.isCancelled else { return }
            self.timedOut = true
            work.cancel()
        }
        return work
    }

    /// The hammer: archive every profile on the machine, touching no project.
    func resetSigningOnly() {
        guard !isRunning else { return }
        beginRun()
        phase = .resettingSigning
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.flushLog() }
            do {
                let (outcome, archiveLog) = try await self.env.archiveProfiles(.everything)
                for line in archiveLog { self.log(.output, line) }
                // Stop can land while the archive is running; reporting success
                // over the top of a cancelled phase would be a lie.
                guard !Task.isCancelled else {
                    self.log(.info, "Stopped by user.")
                    return
                }
                self.log(.success, outcome.moved == 0
                         ? "Nothing to clear — provisioning profile folders are already empty."
                         : "Cleared \(outcome.moved) provisioning profile(s).")
                self.log(.info, "Xcode will fetch fresh profiles the next time you build.")
                self.phase = .succeeded(Date())
            } catch {
                self.log(.failure, error.localizedDescription)
                self.phase = .failed("Signing reset failed")
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        flushLog()
        stoppedByUser = true
        watchdog?.cancel()
        watchdog = nil
        task?.cancel()
        task = nil
        phase = .cancelled
    }

    /// Clears the transcript and nothing else. The card's status is a fact
    /// about the last run, not part of its log.
    func clearLog() {
        guard !isRunning else { return }
        pending.removeAll()
        lines.removeAll()
    }

    // MARK: - Pipeline

    private func perform(slot: ProjectSlot) async {
        defer {
            watchdog?.cancel()
            watchdog = nil
            // Nothing may be left sitting in the buffer once a run has settled:
            // the log is the only account of what happened.
            flushLog()
        }
        var builtBundleID = slot.bundleIdentifier
        log(.info, "▸ \(slot.displayName) → \(slot.deviceName.isEmpty ? slot.deviceUDID : slot.deviceName)"
                 + " (\(trigger == .automatic ? "automatic" : "manual"))")

        do {
            let derivedData = SigningReset.derivedDataDirectory(for: slot.id)

            // Step 1 — find out what we are about to build *before* touching
            // anything. Knowing the bundle id is what lets the signing reset be
            // surgical instead of taking out every profile on the Mac.
            phase = .preparing
            log(.info, "Step 1 · Reading build settings")
            let settings = await readBuildSettings(slot: slot, derivedData: derivedData)
            if let settings {
                builtBundleID = settings.bundleID
                log(.info, "· \(settings.bundleID)")
            } else if !builtBundleID.isEmpty {
                log(.info, "· could not read build settings — using the bundle id from the last run (\(builtBundleID))")
            } else {
                log(.info, "· could not read build settings and no bundle id is known yet")
            }

            try Task.checkCancellation()

            if slot.resetSigning {
                phase = .resettingSigning
                log(.info, "Step 2 · Resetting signing")
                let scope: SigningReset.Scope
                if builtBundleID.isEmpty {
                    scope = .everything
                    log(.info, "· falling back to clearing every profile, since we do not know which app this is")
                } else {
                    scope = .coveringBundleID(builtBundleID)
                }
                let (outcome, archiveLog) = try await env.archiveProfiles(scope)
                for line in archiveLog { log(.output, line) }
                log(.info, outcome.moved == 0
                    ? "· nothing needed clearing"
                    : "· cleared \(outcome.moved) profile(s), left \(outcome.kept) alone")
            } else {
                log(.info, "Step 2 · Signing reset skipped")
            }

            try Task.checkCancellation()

            if slot.cleanBuild {
                log(.info, "Step 3 · Cleaning previous build output")
                for line in try await env.cleanDerivedData(slot.id) { log(.output, line) }
            }

            try Task.checkCancellation()

            phase = .building
            log(.info, "Step 4 · Building")
            try await run("/usr/bin/xcrun", [
                "xcodebuild",
                slot.containerFlag, slot.projectPath,
                "-scheme", slot.scheme,
                "-configuration", slot.configuration,
                "-destination", "id=\(slot.deviceUDID)",
                "-derivedDataPath", derivedData.path,
                "-allowProvisioningUpdates",
                "build"
            ], failureMessage: "Build failed")

            try Task.checkCancellation()

            let product = try locateProduct(slot: slot, derivedData: derivedData, settings: settings)
            builtBundleID = product.bundleID
            log(.info, "· built \(product.appURL.lastPathComponent) (\(product.bundleID))")

            phase = .installing
            log(.info, "Step 5 · Installing on \(slot.deviceName.isEmpty ? "device" : slot.deviceName)")
            try await run("/usr/bin/xcrun", [
                "devicectl", "device", "install", "app",
                "--device", slot.deviceIdentifier,
                product.appURL.path
            ], failureMessage: "Install failed")

            try Task.checkCancellation()

            if slot.launchAfterInstall {
                phase = .launching
                log(.info, "Step 6 · Launching")
                try await run("/usr/bin/xcrun", [
                    "devicectl", "device", "process", "launch",
                    "--device", slot.deviceIdentifier,
                    "--terminate-existing",
                    product.bundleID
                ], failureMessage: "Launch failed")
            }

            let seconds = Int(Date().timeIntervalSince(startedAt ?? Date()))
            log(.success, "✓ Done in \(seconds)s — \(slot.displayName) is running on \(slot.deviceName).")
            if let profile = env.profileCovering(product.bundleID) {
                log(.info, "· new profile valid for \(profile.daysRemaining) more day(s), until "
                         + profile.expirationDate.formatted(date: .abbreviated, time: .shortened))
            }
            phase = .succeeded(Date())
            onFinished?(.succeeded, builtBundleID)

        } catch is CancellationError {
            finishAsStopped(builtBundleID)
        } catch let error as ShellError {
            if case .failed(_, let code) = error, code == 128 + 15 {
                finishAsStopped(builtBundleID)
                return
            }
            fail(error.localizedDescription)
            onFinished?(.failed, builtBundleID)
        } catch {
            fail(error.localizedDescription)
            onFinished?(.failed, builtBundleID)
        }
    }

    /// A run that ended early: either the user pressed Stop, or the watchdog
    /// decided it was never going to finish.
    ///
    /// Only the watchdog counts as a failure. Stop is the user making a
    /// decision, and scoring it against the slot would arm a two-hour backoff
    /// and, after three of them, pause automation on a project that is
    /// perfectly healthy.
    private func finishAsStopped(_ bundleID: String) {
        guard !timedOut else {
            fail("Gave up after \(Int(Self.runTimeout / 60)) minutes — the build never finished.")
            log(.info, "💡 Try the same build in Xcode once; something is waiting for input or wedged.")
            onFinished?(.failed, bundleID)
            return
        }
        log(.info, stoppedByUser ? "Stopped by user." : "Stopped.")
        phase = .cancelled
        onFinished?(.stopped, bundleID)
    }

    // MARK: - Steps

    private func run(_ tool: String, _ arguments: [String], failureMessage: String) async throws {
        log(.command, "$ " + Shell.describe(tool, arguments))
        // Kept alongside the log rather than sliced back out of it. Hints are
        // read from this command's own output only — scanning the whole
        // transcript would let a stray word in an earlier step, or in the
        // project path echoed above, put confident and wrong advice under an
        // unrelated failure.
        var output: [String] = []
        var exitCode: Int32 = -1
        for try await event in env.stream(tool, arguments) {
            switch event {
            case .line(let line):
                output.append(line)
                if output.count > maxLines { output.removeFirst() }
                log(Self.classify(line), line)
            case .finished(let code):
                exitCode = code
            }
        }
        try Task.checkCancellation()
        guard exitCode == 0 else {
            for hint in Hints.forLog(output) { log(.info, "💡 \(hint)") }
            throw ShellError.failed(summary: failureMessage, exitCode: exitCode)
        }
    }

    private struct Product {
        var appURL: URL
        var bundleID: String
    }

    /// What `xcodebuild -showBuildSettings` tells us about the product, read
    /// before the build so the signing reset knows what it is aiming at.
    nonisolated struct ResolvedSettings: Equatable {
        var bundleID: String
        var appURL: URL
    }

    private func readBuildSettings(slot: ProjectSlot, derivedData: URL) async -> ResolvedSettings? {
        let result = try? await env.capture("/usr/bin/xcrun", [
            "xcodebuild",
            slot.containerFlag, slot.projectPath,
            "-scheme", slot.scheme,
            "-configuration", slot.configuration,
            "-destination", "id=\(slot.deviceUDID)",
            // Step 1 runs before anything is touched, and it is the step most
            // likely to find the phone asleep. Bound the wait: falling back to
            // the bundle id learned on the last run beats standing here.
            "-destination-timeout", "20",
            "-derivedDataPath", derivedData.path,
            "-showBuildSettings", "-json"
        ])
        guard let output = result?.output else { return nil }
        return Self.parseBuildSettings(output)
    }

    /// Pulls the app product out of `-showBuildSettings -json` output.
    /// `xcodebuild` likes to print warnings before the JSON, so we start at the
    /// first `[`.
    nonisolated static func parseBuildSettings(_ output: String) -> ResolvedSettings? {
        guard let start = output.firstIndex(of: "["),
              let data = String(output[start...]).data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        for entry in entries {
            guard let build = entry["buildSettings"] as? [String: Any],
                  let directory = build["TARGET_BUILD_DIR"] as? String,
                  let productName = build["FULL_PRODUCT_NAME"] as? String,
                  productName.hasSuffix(".app"),
                  let bundleID = build["PRODUCT_BUNDLE_IDENTIFIER"] as? String,
                  !bundleID.isEmpty
            else { continue }
            return ResolvedSettings(bundleID: bundleID,
                                    appURL: URL(fileURLWithPath: directory).appending(path: productName))
        }
        return nil
    }

    /// Where the freshly built app actually landed. Prefers what the build
    /// settings promised, and scans the products directory if that is missing.
    private func locateProduct(slot: ProjectSlot,
                               derivedData: URL,
                               settings: ResolvedSettings?) throws -> Product {
        if let settings, env.fileExists(settings.appURL) {
            return Product(appURL: settings.appURL, bundleID: settings.bundleID)
        }

        let products = Self.productsDirectory(derivedData: derivedData, configuration: slot.configuration)
        guard let appURL = env.appBundles(products).first else {
            throw ShellError.launchFailed("Could not find the built .app under \(products.path)")
        }
        return Product(appURL: appURL, bundleID: try env.bundleIdentifier(appURL))
    }

    nonisolated static func productsDirectory(derivedData: URL, configuration: String) -> URL {
        derivedData.appending(path: "Build/Products/\(configuration)-iphoneos")
    }

    // MARK: - Logging

    /// Wipes the previous run's log and takes ownership of the runner.
    private func beginRun() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        lines.removeAll()
        startedAt = Date()
        phase = .preparing
    }

    private func fail(_ message: String) {
        log(.failure, "✗ \(message)")
        phase = .failed(message)
    }

    private func log(_ kind: LogLine.Kind, _ text: String) {
        pending.append(LogLine(kind: kind, text: text))
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            guard let self else { return }
            self.flushTask = nil
            self.flushLog()
        }
    }

    /// Publishes whatever has piled up. Called on the timer, and again at every
    /// point a caller might read `lines` — the end of a run, most of all.
    private func flushLog() {
        guard !pending.isEmpty else { return }
        lines.append(contentsOf: pending)
        pending.removeAll()
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    nonisolated static func classify(_ line: String) -> LogLine.Kind {
        let lowered = line.lowercased()
        if lowered.contains("error:") || lowered.contains("** build failed **")
            || lowered.contains("fatal error") || lowered.contains("** install failed **") {
            return .failure
        }
        if lowered.contains("** build succeeded **") || lowered.hasPrefix("app installed")
            || lowered.hasPrefix("launched application") {
            return .success
        }
        return .output
    }
}

/// Turns the usual signing failures into something actionable.
enum Hints {
    static func forLog(_ lines: [String]) -> [String] {
        let text = lines.joined(separator: "\n").lowercased()
        var hints: [String] = []

        if text.contains("no signing certificate") || text.contains("requires a development team") {
            hints.append("Open the project in Xcode once, go to Signing & Capabilities, and pick your Apple ID team.")
        }
        if text.contains("unable to log in with account") || text.contains("your session has expired") {
            hints.append("Xcode's Apple ID session expired: Xcode ▸ Settings ▸ Accounts, then sign in again.")
        }
        if text.contains("maximum number of apps for free development profiles") {
            hints.append("A free Apple ID allows 3 apps at a time — delete one of the older dev builds from the iPhone.")
        }
        if text.contains("device is locked") || text.contains("passcode") {
            hints.append("Unlock the iPhone and keep it unlocked while installing.")
        }
        // `devicectl`'s own wording is "The specified device was not found." —
        // the phrasing this used to look for was a guess, and the one message a
        // user is most likely to hit produced no advice at all.
        if text.contains("could not find device") || text.contains("unable to find device")
            || text.contains("device was not found") || text.contains("no device found") {
            hints.append("The iPhone dropped off the network. Wake it, confirm the same Wi-Fi, then hit Refresh next to the device picker.")
        }
        if text.contains("application-identifier") || text.contains("mismatch") {
            hints.append("The bundle ID was signed by a different certificate before — delete the app from the iPhone and resync.")
        }
        if text.contains("untrusted developer") {
            hints.append("On the iPhone: Settings ▸ General ▸ VPN & Device Management, then trust your developer certificate.")
        }
        if text.contains("scheme") && text.contains("not currently configured") {
            hints.append("That scheme is not shared. In Xcode: Product ▸ Scheme ▸ Manage Schemes, tick Shared.")
        }
        return hints
    }
}
