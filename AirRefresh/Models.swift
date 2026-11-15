import Foundation

/// One of the (at most three) apps AirRefresh can push to a device — built
/// from an Xcode project, or re-signed from a ready-made `.ipa`.
struct ProjectSlot: Identifiable, Codable, Hashable {

    var id: UUID = UUID()
    var name: String = ""
    /// Absolute path to an `.xcodeproj`, `.xcworkspace` or `.ipa`.
    var projectPath: String = ""
    var scheme: String = ""
    var configuration: String = "Debug"
    /// Hardware UDID — what `xcodebuild -destination id=…` expects.
    var deviceUDID: String = ""
    /// CoreDevice identifier — what `devicectl --device` expects.
    var deviceIdentifier: String = ""
    var deviceName: String = ""

    var resetSigning: Bool = true
    var cleanBuild: Bool = false
    var launchAfterInstall: Bool = true

    /// Let the scheduler keep this project alive on its own.
    var autoRefresh: Bool = true
    /// Learned from the build, so we can find the matching profile afterwards.
    var bundleIdentifier: String = ""
    /// Expiry of the profile covering `bundleIdentifier`, when we know it.
    var profileExpiresAt: Date?
    var lastSuccessAt: Date?

    // MARK: .ipa slots

    /// The development team an `.ipa` is re-signed for. A project carries its
    /// own team in its build settings; an `.ipa` has nothing we could use.
    var teamID: String = ""
    /// Signs the `.ipa` under a different bundle id. A free Apple ID cannot
    /// register an id another team already owns — which is every id of an app
    /// somebody else published — so this is usually needed.
    var bundleIDOverride: String = ""
    /// `CFBundleIdentifier` as it ships inside the `.ipa`, read when it is picked.
    var sourceBundleIdentifier: String = ""

    var isIPA: Bool { projectPath.lowercased().hasSuffix(".ipa") }

    /// The bundle id an `.ipa` slot will be signed as, when it can be known
    /// without unpacking it.
    var ipaTargetBundleID: String {
        let override = bundleIDOverride.trimmingCharacters(in: .whitespaces)
        return override.isEmpty ? sourceBundleIdentifier : override
    }

    var isConfigured: Bool {
        guard !projectPath.isEmpty, !deviceIdentifier.isEmpty else { return false }
        return isIPA ? !teamID.isEmpty : !scheme.isEmpty
    }

    var displayName: String {
        if !name.isEmpty { return name }
        guard !projectPath.isEmpty else { return "Empty slot" }
        return URL(fileURLWithPath: projectPath).deletingPathExtension().lastPathComponent
    }

    var isWorkspace: Bool { projectPath.hasSuffix(".xcworkspace") }

    init() {}

    /// Hand-written so slots saved by an older build still load: Swift's
    /// synthesized decoder throws on a missing key even when the property has a
    /// default, which would quietly wipe everyone's configuration on upgrade.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        id = value(.id, UUID())
        name = value(.name, "")
        projectPath = value(.projectPath, "")
        scheme = value(.scheme, "")
        configuration = value(.configuration, "Debug")
        deviceUDID = value(.deviceUDID, "")
        deviceIdentifier = value(.deviceIdentifier, "")
        deviceName = value(.deviceName, "")
        resetSigning = value(.resetSigning, true)
        cleanBuild = value(.cleanBuild, false)
        launchAfterInstall = value(.launchAfterInstall, true)
        autoRefresh = value(.autoRefresh, true)
        bundleIdentifier = value(.bundleIdentifier, "")
        profileExpiresAt = try? container.decodeIfPresent(Date.self, forKey: .profileExpiresAt)
        lastSuccessAt = try? container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
        teamID = value(.teamID, "")
        bundleIDOverride = value(.bundleIDOverride, "")
        sourceBundleIdentifier = value(.sourceBundleIdentifier, "")
    }

    var containerFlag: String { isWorkspace ? "-workspace" : "-project" }

    /// Whole days until the signing profile dies, floored at zero so the
    /// scheduler never has to reason about negative time. `nil` while unknown.
    /// A profile that has already lapsed reads as `0` — ask ``hasExpired`` to
    /// tell the two apart.
    var daysUntilExpiry: Int? {
        guard let expiry = profileExpiresAt else { return nil }
        return max(0, Int(expiry.timeIntervalSinceNow / 86_400))
    }

    /// The profile is gone, not merely close. Kept separate from
    /// `daysUntilExpiry == 0` so the UI can say "Expired" instead of claiming
    /// an app that stopped working last week expires later today.
    var hasExpired: Bool {
        guard let expiry = profileExpiresAt else { return false }
        return expiry <= Date()
    }

    /// Automation only takes over once a manual run has proved the slot works.
    var hasProvenItself: Bool { lastSuccessAt != nil }

    /// A short human sentence about signing health, for the UI.
    var expiryDescription: String { expiryDescription(now: Date()) }

    /// Counts calendar days, not 24-hour periods, because that is what
    /// "tomorrow" means to a person. `daysUntilExpiry` counts whole periods —
    /// right for the scheduler's threshold, wrong for a sentence: on a Saturday
    /// afternoon, a profile dying Monday morning is 1.8 periods away and used
    /// to be described as expiring "tomorrow".
    func expiryDescription(now: Date, calendar: Calendar = .current) -> String {
        guard let expiry = profileExpiresAt else {
            return hasProvenItself ? "Signing status unknown" : "Not synced yet"
        }
        if expiry <= now { return "Expired" }
        let days = calendarDaysUntilExpiry(now: now, calendar: calendar) ?? 0
        switch days {
        case ...0: return "Expires today"
        case 1: return "Expires tomorrow"
        default: return "Expires in \(days) days"
        }
    }

    /// Midnights between now and expiry: 0 is today, 1 is tomorrow.
    func calendarDaysUntilExpiry(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let expiry = profileExpiresAt else { return nil }
        return calendar.dateComponents([.day],
                                       from: calendar.startOfDay(for: now),
                                       to: calendar.startOfDay(for: expiry)).day
    }

    /// The exact moment, for a tooltip under the rounded sentence.
    var expiryDetail: String? {
        profileExpiresAt.map {
            ($0 <= Date() ? "Expired " : "Expires ") + $0.formatted(date: .complete, time: .shortened)
        }
    }

    /// What is still missing before this slot can run.
    var configurationHint: String? {
        if projectPath.isEmpty { return "Choose an .xcodeproj, .xcworkspace or .ipa" }
        if isIPA {
            if teamID.isEmpty { return "Pick the team to sign with" }
        } else if scheme.isEmpty {
            return "Pick a scheme"
        }
        if deviceIdentifier.isEmpty { return "Pick a device" }
        return nil
    }
}

/// A physical device reported by `devicectl`.
struct Device: Identifiable, Hashable, Codable {
    var id: String { identifier }
    var identifier: String
    var udid: String
    var name: String
    var model: String
    var osVersion: String
    var isPaired: Bool
    var transport: String

    var subtitle: String {
        var parts = [model]
        if !osVersion.isEmpty { parts.append("iOS \(osVersion)") }
        if !transport.isEmpty { parts.append(transport == "localNetwork" ? "Wi-Fi" : "USB") }
        return parts.joined(separator: " · ")
    }
}

enum SyncPhase: Equatable {
    case idle
    case preparing
    case resettingSigning
    case building
    /// `.ipa` slots: having Xcode mint a profile for the bundle id.
    case fetchingProfile
    /// `.ipa` slots: signing the unpacked app with that profile.
    case resigning
    case installing
    case launching
    case succeeded(Date)
    case failed(String)
    case cancelled

    var isRunning: Bool {
        switch self {
        case .preparing, .resettingSigning, .building, .fetchingProfile, .resigning,
             .installing, .launching: return true
        default: return false
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .preparing: return "Preparing…"
        case .resettingSigning: return "Resetting signing…"
        case .building: return "Building…"
        case .fetchingProfile: return "Fetching profile…"
        case .resigning: return "Re-signing…"
        case .installing: return "Installing…"
        case .launching: return "Launching…"
        case .succeeded: return "On device"
        case .failed(let why): return why
        case .cancelled: return "Stopped"
        }
    }
}

struct LogLine: Identifiable {
    enum Kind { case info, command, output, success, failure }
    let id = UUID()
    let kind: Kind
    let text: String
}

/// Who asked for a run — shown in the log and used to decide how loudly to report.
enum RunTrigger: String, Codable {
    case manual
    case automatic
}

/// How a run ended. "Stopped" is deliberately not "failed": pressing Stop is
/// the user making a decision, and holding it against the slot — a failure
/// count, a two-hour backoff, a notification — would punish them for it.
enum RunOutcome: Equatable {
    case succeeded
    case failed
    case stopped
}
