import Foundation
import CryptoKit

/// A provisioning profile as it sits on disk.
///
/// The file is a CMS envelope, but the payload we care about is a plain XML
/// plist embedded in it, so we can read it without any crypto.
struct ProvisioningProfile: Identifiable, Hashable {
    var id: String { uuid }
    var url: URL
    var uuid: String
    var name: String
    var teamName: String
    var applicationIdentifier: String
    var creationDate: Date
    var expirationDate: Date
    /// `TeamIdentifier`, e.g. `ABCDE12345`.
    var teamIdentifier: String = ""
    /// SHA-1 of each certificate the profile allows to sign, upper-case hex —
    /// the same form `security find-identity` prints.
    var certificateFingerprints: [String] = []
    var getTaskAllow: Bool = false

    /// `C5MSK2XBMK.win.ringtwo.EarRouter` → `win.ringtwo.EarRouter`
    var bundleIdentifier: String {
        guard let dot = applicationIdentifier.firstIndex(of: ".") else { return applicationIdentifier }
        return String(applicationIdentifier[applicationIdentifier.index(after: dot)...])
    }

    var isWildcard: Bool { bundleIdentifier.hasSuffix("*") }

    /// Whole days left, floored, and never negative.
    var daysRemaining: Int {
        max(0, Int(expirationDate.timeIntervalSinceNow / 86_400))
    }

    var hasExpired: Bool { expirationDate <= Date() }

    /// True when this profile covers the given bundle id, wildcards included.
    func covers(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if isWildcard {
            let prefix = String(bundleIdentifier.dropLast())   // trailing "*"
            return bundleID.hasPrefix(prefix)
        }
        return bundleIdentifier == bundleID
    }
}

enum ProfileInspector {

    /// Every profile currently installed, newest expiry last.
    static func installedProfiles() -> [ProvisioningProfile] {
        SigningReset.profileDirectories
            .flatMap { directory -> [URL] in
                (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            }
            .filter { SigningReset.profileExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap(parse)
            .sorted { $0.expirationDate < $1.expirationDate }
    }

    /// The profile governing `bundleID`: an exact match always beats a
    /// wildcard, and among equals the one that lives longest wins.
    static func profile(covering bundleID: String) -> ProvisioningProfile? {
        best(covering: bundleID, among: installedProfiles())
    }

    /// Expiry of the governing profile for each of `bundleIDs`, from a *single*
    /// pass over the profile folders.
    ///
    /// The scheduler asks this on every tick. Calling `profile(covering:)` once
    /// per slot instead re-read and re-parsed every profile on the Mac three
    /// times over, synchronously, every three minutes.
    static func expiryDates(for bundleIDs: [String]) -> [String: Date] {
        let ids = Set(bundleIDs.filter { !$0.isEmpty })
        guard !ids.isEmpty else { return [:] }
        let profiles = installedProfiles()
        return ids.reduce(into: [:]) { result, id in
            result[id] = best(covering: id, among: profiles)?.expirationDate
        }
    }

    ///
    /// Longest, not soonest: a fresh build is signed with the newest profile
    /// Xcode has, so that is what the phone is running. Reading the oldest
    /// instead — which happens whenever "Reset signing" is off and last week's
    /// profile is still on disk — made a slot that had just been refreshed look
    /// due again, and the scheduler rebuilt it every two hours.
    static func best(covering bundleID: String,
                     among profiles: [ProvisioningProfile]) -> ProvisioningProfile? {
        let matches = profiles.filter { $0.covers(bundleID: bundleID) }
        let exact = matches.filter { !$0.isWildcard }
        return (exact.isEmpty ? matches : exact).max { $0.expirationDate < $1.expirationDate }
    }

    static func parse(_ url: URL) -> ProvisioningProfile? {
        guard let data = try? Data(contentsOf: url),
              let payload = embeddedPlist(in: data),
              let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any],
              let uuid = plist["UUID"] as? String,
              let expiration = plist["ExpirationDate"] as? Date
        else { return nil }

        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let team = (plist["TeamIdentifier"] as? [String])?.first
            ?? entitlements["com.apple.developer.team-identifier"] as? String
            ?? ""
        let fingerprints = (plist["DeveloperCertificates"] as? [Data] ?? []).map(fingerprint)
        return ProvisioningProfile(
            url: url,
            uuid: uuid,
            name: plist["Name"] as? String ?? url.lastPathComponent,
            teamName: plist["TeamName"] as? String ?? "",
            applicationIdentifier: entitlements["application-identifier"] as? String ?? "",
            creationDate: plist["CreationDate"] as? Date ?? .distantPast,
            expirationDate: expiration,
            teamIdentifier: team,
            certificateFingerprints: fingerprints,
            getTaskAllow: entitlements["get-task-allow"] as? Bool ?? false
        )
    }

    /// SHA-1 of a DER certificate, as `security find-identity` prints it.
    static func fingerprint(_ certificate: Data) -> String {
        Insecure.SHA1.hash(data: certificate).map { String(format: "%02X", $0) }.joined()
    }

    /// Carves the XML plist out of the CMS wrapper.
    private static func embeddedPlist(in data: Data) -> Data? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: .backwards)
        else { return nil }
        return data[start.lowerBound..<end.upperBound]
    }
}
