import Foundation
import Observation

/// Drives one slot through its pipeline and publishes a live log while it does:
///
/// - a project: inspect → reset → build → install → launch
/// - an `.ipa`: unpack → reset → fetch a profile → re-sign → install → launch
@MainActor
@Observable
final class SlotRunner: Identifiable {
    let id: UUID
    private(set) var phase: SyncPhase = .idle
    private(set) var lines: [LogLine] = []
    private(set) var startedAt: Date?
    private(set) var trigger: RunTrigger = .manual
    /// Advice for the last failure, kept apart from the log so the card can
    /// put it next to the error instead of 4,000 lines further down.
    private(set) var hints: [String] = []
    /// Reports how a run settled, and the bundle identifier it learned.
    var onFinished: ((RunOutcome, String) -> Void)?
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var timedOut = false
    private var stoppedByUser = false

    /// Which run currently owns this runner's state.
    ///
    /// Stop returns the runner at once, but the task it cancelled is still
    /// unwinding — an archive in flight cannot be interrupted, and a cancelled
    /// command takes a turn or two to notice. Press Refresh in that window and
    /// two tasks share one runner: the old one used to write "Stopped" over the
    /// new run's phase, cancel the new run's watchdog, report `.stopped` for it
    /// and append its lines to the new log. Every write now checks the token
    /// its task was started with, and a run that no longer owns the runner
    /// goes quiet.
    private var activeRun = UUID()
    @TaskLocal private static var runToken: UUID?

    /// True inside a task whose run has since been superseded.
    private var isStale: Bool {
        guard let token = Self.runToken else { return false }
        return token != activeRun
    }

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
        let token = beginRun()

        let work = Task { [weak self] in
            await Self.$runToken.withValue(token) {
                guard let self else { return }
                await self.perform(slot: slot)
            }
        }
        task = work

        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.runTimeout))
            guard let self, self.activeRun == token, self.isRunning, !work.isCancelled else { return }
            self.timedOut = true
            work.cancel()
        }
        return work
    }

    /// The hammer: archive every profile on the machine, touching no project.
    func resetSigningOnly() {
        guard !isRunning else { return }
        let token = beginRun()
        phase = .resettingSigning
        task = Task { [weak self] in
            await Self.$runToken.withValue(token) {
                guard let self else { return }
                defer { self.flushLog() }
                do {
                    let (outcome, archiveLog) = try await self.env.archiveProfiles(.everything)
                    for line in archiveLog { self.log(.output, line) }
                    let summary = outcome.moved == 0
                        ? "Nothing to clear — provisioning profile folders are already empty."
                        : "Cleared \(outcome.moved) provisioning profile(s)."
                    // Moving files cannot be interrupted half-way, so a Stop
                    // pressed meanwhile arrives after the work is done. Saying
                    // only "Stopped" would hide that the profiles did move.
                    guard !Task.isCancelled else {
                        self.log(.info, "Stopped by user — the archive had already finished. \(summary)")
                        return
                    }
                    self.log(.success, summary)
                    self.log(.info, "Xcode will fetch fresh profiles the next time you build.")
                    self.setPhase(.succeeded(Date()))
                } catch {
                    self.log(.failure, error.localizedDescription)
                    self.setPhase(.failed("Signing reset failed"))
                }
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

    private struct Product {
        var appURL: URL
        var bundleID: String
    }

    private func perform(slot: ProjectSlot) async {
        defer {
            if !isStale {
                watchdog?.cancel()
                watchdog = nil
                // Nothing may be left sitting in the buffer once a run has
                // settled: the log is the only account of what happened.
                flushLog()
            }
        }
        var learnedBundleID = slot.bundleIdentifier
        log(.info, "▸ \(slot.displayName) → \(slot.deviceName.isEmpty ? slot.deviceUDID : slot.deviceName)"
                 + " (\(trigger == .automatic ? "automatic" : "manual"))")

        do {
            let product = slot.isIPA
                ? try await resignIPA(slot: slot, learnedBundleID: &learnedBundleID)
                : try await buildProject(slot: slot, learnedBundleID: &learnedBundleID)
            learnedBundleID = product.bundleID

            setPhase(.installing)
            log(.info, "Installing on \(slot.deviceName.isEmpty ? "device" : slot.deviceName)")
            try await run("/usr/bin/xcrun", [
                "devicectl", "device", "install", "app",
                "--device", slot.deviceIdentifier,
                product.appURL.path
            ], failureMessage: "Install failed")

            try Task.checkCancellation()

            if slot.launchAfterInstall {
                setPhase(.launching)
                log(.info, "Launching")
                try await run("/usr/bin/xcrun", [
                    "devicectl", "device", "process", "launch",
                    "--device", slot.deviceIdentifier,
                    "--terminate-existing",
                    product.bundleID
                ], failureMessage: "Launch failed")
            }

            let seconds = Int(Date().timeIntervalSince(startedAt ?? Date()))
            let device = slot.deviceName.isEmpty ? "the device" : slot.deviceName
            log(.success, "✓ Done in \(seconds)s — \(slot.displayName) is "
                        + (slot.launchAfterInstall ? "running" : "installed") + " on \(device).")
            if let profile = env.profileCovering(product.bundleID) {
                log(.info, "· new profile valid for \(profile.daysRemaining) more day(s), until "
                         + profile.expirationDate.formatted(date: .abbreviated, time: .shortened))
            }
            setPhase(.succeeded(Date()))
            finish(.succeeded, learnedBundleID)

        } catch is CancellationError {
            finishAsStopped(learnedBundleID)
        } catch let error as ShellError {
            if case .failed(_, let code) = error, code == 128 + 15 {
                finishAsStopped(learnedBundleID)
                return
            }
            fail(error.localizedDescription)
            finish(.failed, learnedBundleID)
        } catch {
            fail(error.localizedDescription)
            finish(.failed, learnedBundleID)
        }
    }

    // MARK: Project slots

    private func buildProject(slot: ProjectSlot, learnedBundleID: inout String) async throws -> Product {
        let derivedData = SigningReset.derivedDataDirectory(for: slot.id)

        // Find out what we are about to build *before* touching anything.
        // Knowing the bundle id is what lets the signing reset be surgical
        // instead of taking out every profile on the Mac.
        setPhase(.preparing)
        log(.info, "Step 1 · Reading build settings")
        let settings = await readBuildSettings(slot: slot, derivedData: derivedData)
        if let settings {
            learnedBundleID = settings.bundleID
            log(.info, "· \(settings.bundleID)")
        } else if !learnedBundleID.isEmpty {
            log(.info, "· could not read build settings — using the bundle id from the last run (\(learnedBundleID))")
        } else {
            log(.info, "· could not read build settings and no bundle id is known yet")
        }

        try Task.checkCancellation()
        try await resetSigning(slot: slot, bundleID: learnedBundleID, step: 2)
        try Task.checkCancellation()
        try await cleanIfAsked(slot: slot, step: 3)
        try Task.checkCancellation()

        setPhase(.building)
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
        log(.info, "· built \(product.appURL.lastPathComponent) (\(product.bundleID))")
        return product
    }

    // MARK: .ipa slots

    private func resignIPA(slot: ProjectSlot, learnedBundleID: inout String) async throws -> Product {
        let ipa = URL(fileURLWithPath: slot.projectPath)
        let work = IPASigning.workDirectory(for: slot.id)
        let derivedData = SigningReset.derivedDataDirectory(for: slot.id)

        setPhase(.preparing)
        log(.info, "Step 1 · Unpacking \(ipa.lastPathComponent)")
        guard env.fileExists(ipa) else {
            throw PipelineError("The .ipa is no longer at \(ipa.path). Pick it again with Change….")
        }
        let extracted = work.appending(path: "Unpacked")
        try env.resetDirectory(extracted)
        try await run("/usr/bin/ditto", ["-x", "-k", ipa.path, extracted.path],
                      failureMessage: "Could not unpack the .ipa")
        let payload = extracted.appending(path: "Payload")
        guard let app = env.appBundles(payload).first else {
            throw PipelineError("\(ipa.lastPathComponent) has no app inside Payload/ — is it really an .ipa?")
        }
        let sourceID = try env.bundleIdentifier(app)
        let override = slot.bundleIDOverride.trimmingCharacters(in: .whitespaces)
        let bundleID = override.isEmpty ? sourceID : override
        guard IPASigning.isValidBundleID(bundleID) else {
            throw PipelineError("“\(bundleID)” is not a valid bundle id.")
        }
        learnedBundleID = bundleID
        log(.info, "· \(app.lastPathComponent) (\(sourceID))"
                 + (bundleID == sourceID ? "" : " — signing as \(bundleID)"))

        try Task.checkCancellation()
        try await resetSigning(slot: slot, bundleID: bundleID, step: 2)
        try Task.checkCancellation()
        try await cleanIfAsked(slot: slot, step: 3)
        try Task.checkCancellation()

        // Xcode only hands a free account a profile as a side effect of
        // building something. So build something: a one-file app with this
        // bundle id, whose only purpose is the profile it leaves embedded.
        setPhase(.fetchingProfile)
        log(.info, "Step 4 · Getting a fresh profile from Xcode")
        let stub = try env.writeStubProject(IPASigning.StubProject(
            directory: work.appending(path: "Helper"), bundleID: bundleID, teamID: slot.teamID))
        try await run("/usr/bin/xcrun", [
            "xcodebuild",
            "-project", stub.path,
            "-scheme", IPASigning.stubName,
            "-configuration", "Debug",
            "-destination", "id=\(slot.deviceUDID)",
            "-derivedDataPath", derivedData.path,
            "-allowProvisioningUpdates",
            "build"
        ], failureMessage: "Could not get a provisioning profile")

        try Task.checkCancellation()

        let profileURL = Self.productsDirectory(derivedData: derivedData, configuration: "Debug")
            .appending(path: "\(IPASigning.stubName).app/embedded.mobileprovision")
        guard let profile = env.readProfile(profileURL), profile.covers(bundleID: bundleID) else {
            throw PipelineError("Xcode finished, but left no provisioning profile for \(bundleID).")
        }
        log(.info, "· \(profile.name), valid until "
                 + profile.expirationDate.formatted(date: .abbreviated, time: .shortened))

        setPhase(.resigning)
        log(.info, "Step 5 · Re-signing \(app.lastPathComponent)")
        let identities = IPASigning.parseIdentities(
            (try await env.capture("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])).output)
        guard let identity = profile.certificateFingerprints.first(where: identities.contains) else {
            guard !isStale else { throw CancellationError() }
            hints = ["Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates… and make sure an Apple Development certificate is listed."]
            log(.info, "💡 \(hints[0])")
            throw PipelineError("No signing certificate in your keychain matches the new profile.")
        }

        let prepared = try env.prepareForSigning(app, profileURL, bundleID)
        for line in prepared.log { log(.output, line) }
        if prepared.looksEncrypted {
            log(.failure, "⚠︎ This .ipa looks App Store–encrypted (it carries SC_Info). It will install, "
                        + "but it will not open — re-signing only works on a decrypted .ipa.")
        }

        let entitlementsURL = work.appending(path: "entitlements.plist")
        let team = profile.teamIdentifier.isEmpty ? slot.teamID : profile.teamIdentifier
        try env.writeEntitlements(IPASigning.Entitlements(teamID: team, bundleID: bundleID,
                                                          getTaskAllow: profile.getTaskAllow),
                                  entitlementsURL)

        // Inside out: a bundle's seal covers the signatures of what it holds.
        for code in prepared.nestedCode {
            try Task.checkCancellation()
            try await run("/usr/bin/codesign",
                          ["--force", "--sign", identity, "--timestamp=none", code.path],
                          failureMessage: "Re-signing failed")
        }
        try await run("/usr/bin/codesign",
                      ["--force", "--sign", identity, "--timestamp=none",
                       "--entitlements", entitlementsURL.path, app.path],
                      failureMessage: "Re-signing failed")

        try Task.checkCancellation()
        return Product(appURL: app, bundleID: bundleID)
    }

    // MARK: Shared steps

    private func resetSigning(slot: ProjectSlot, bundleID: String, step: Int) async throws {
        guard slot.resetSigning else {
            log(.info, "Step \(step) · Signing reset skipped")
            return
        }
        setPhase(.resettingSigning)
        log(.info, "Step \(step) · Resetting signing")
        let scope: SigningReset.Scope
        if bundleID.isEmpty {
            scope = .everything
            log(.info, "· falling back to clearing every profile, since we do not know which app this is")
        } else {
            scope = .coveringBundleID(bundleID)
        }
        let (outcome, archiveLog) = try await env.archiveProfiles(scope)
        for line in archiveLog { log(.output, line) }
        log(.info, outcome.moved == 0
            ? "· nothing needed clearing"
            : "· cleared \(outcome.moved) profile(s), left \(outcome.kept) alone")
    }

    private func cleanIfAsked(slot: ProjectSlot, step: Int) async throws {
        guard slot.cleanBuild else { return }
        log(.info, "Step \(step) · Cleaning previous build output")
        for line in try await env.cleanDerivedData(slot.id) { log(.output, line) }
    }

    /// A run that ended early: either the user pressed Stop, or the watchdog
    /// decided it was never going to finish.
    ///
    /// Only the watchdog counts as a failure. Stop is the user making a
    /// decision, and scoring it against the slot would arm a two-hour backoff
    /// and, after three of them, pause automation on a project that is
    /// perfectly healthy.
    private func finishAsStopped(_ bundleID: String) {
        guard !isStale else { return }
        guard !timedOut else {
            fail("Gave up after \(Int(Self.runTimeout / 60)) minutes — the build never finished.")
            hints = ["Try the same build in Xcode once; something is waiting for input or wedged."]
            log(.info, "💡 \(hints[0])")
            finish(.failed, bundleID)
            return
        }
        log(.info, stoppedByUser ? "Stopped by user." : "Stopped.")
        phase = .cancelled
        finish(.stopped, bundleID)
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
            if !isStale {
                hints = Hints.forLog(output)
                for hint in hints { log(.info, "💡 \(hint)") }
            }
            throw ShellError.failed(summary: failureMessage, exitCode: exitCode)
        }
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
            throw PipelineError("Could not find the built .app under \(products.path)")
        }
        return Product(appURL: appURL, bundleID: try env.bundleIdentifier(appURL))
    }

    nonisolated static func productsDirectory(derivedData: URL, configuration: String) -> URL {
        derivedData.appending(path: "Build/Products/\(configuration)-iphoneos")
    }

    // MARK: - Logging

    /// Wipes the previous run's log and takes ownership of the runner.
    private func beginRun() -> UUID {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        lines.removeAll()
        hints.removeAll()
        startedAt = Date()
        phase = .preparing
        activeRun = UUID()
        return activeRun
    }

    private func setPhase(_ next: SyncPhase) {
        guard !isStale else { return }
        phase = next
    }

    private func finish(_ outcome: RunOutcome, _ bundleID: String) {
        guard !isStale else { return }
        onFinished?(outcome, bundleID)
    }

    private func fail(_ message: String) {
        guard !isStale else { return }
        log(.failure, "✗ \(message)")
        phase = .failed(message)
    }

    private func log(_ kind: LogLine.Kind, _ text: String) {
        guard !isStale else { return }
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
        // Registering a bundle id someone else owns — every published app's id.
        if text.contains("cannot be registered to your development team")
            || (text.contains("app identifier") && text.contains("is not available")) {
            hints.append("That bundle ID already belongs to another developer. Give this app a bundle ID of your own — for an .ipa, in the Bundle ID field on its card.")
        }
        if text.contains("maximum app id limit") || text.contains("create up to 10 app ids") {
            hints.append("A free Apple ID can register 10 new bundle IDs every 7 days. Wait, or reuse a bundle ID you already registered.")
        }
        if text.contains("device is locked") || text.contains("passcode") {
            hints.append("Unlock the iPhone and keep it unlocked while installing.")
        }
        // `devicectl`'s own wording is "The specified device was not found." —
        // the phrasing this used to look for was a guess, and the one message a
        // user is most likely to hit produced no advice at all.
        //
        // xcodebuild words the same situation differently again, and it is the
        // one you meet most: the phone asleep or off Wi-Fi when the build step
        // starts.
        if text.contains("could not find device") || text.contains("unable to find device")
            || text.contains("device was not found") || text.contains("no device found")
            || text.contains("unable to find a device matching")
            || text.contains("unable to find a destination matching") {
            hints.append("The iPhone dropped off the network. Wake and unlock it, confirm it is on the same Wi-Fi, then click Scan Again.")
        }
        // Specific on purpose. This used to fire on any "mismatch" at all —
        // an architecture mismatch, a profile/team mismatch — and told the
        // user to delete their app from the phone for problems that had
        // nothing to do with it.
        if text.contains("application-identifier") || text.contains("mismatchedapplicationidentifierentitlement") {
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
