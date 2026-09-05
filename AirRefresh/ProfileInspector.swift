import Foundation

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

    /// The profile that expires soonest among those covering `bundleID`.
    /// An exact match always beats a wildcard.
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

    static func best(covering bundleID: String,
                     among profiles: [ProvisioningProfile]) -> ProvisioningProfile? {
        let matches = profiles.filter { $0.covers(bundleID: bundleID) }
        return matches.first { !$0.isWildcard } ?? matches.first
    }

    static func parse(_ url: URL) -> ProvisioningProfile? {
        guard let data = try? Data(contentsOf: url),
              let payload = embeddedPlist(in: data),
              let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any],
              let uuid = plist["UUID"] as? String,
              let expiration = plist["ExpirationDate"] as? Date
        else { return nil }

        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        return ProvisioningProfile(
            url: url,
            uuid: uuid,
            name: plist["Name"] as? String ?? url.lastPathComponent,
            teamName: plist["TeamName"] as? String ?? "",
            applicationIdentifier: entitlements["application-identifier"] as? String ?? "",
            creationDate: plist["CreationDate"] as? Date ?? .distantPast,
            expirationDate: expiration
        )
    }

    /// Carves the XML plist out of the CMS wrapper.
    private static func embeddedPlist(in data: Data) -> Data? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: .backwards)
        else { return nil }
        return data[start.lowerBound..<end.upperBound]
    }
}
