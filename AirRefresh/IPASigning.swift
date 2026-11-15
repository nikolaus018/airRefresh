import Foundation

/// Everything needed to keep a ready-made `.ipa` alive on a free Apple ID.
///
/// An `.ipa` cannot be rebuilt, so the profile cannot come from its own build.
/// Instead AirRefresh writes a tiny helper project with the same bundle id and
/// builds *that* with `-allowProvisioningUpdates` — which is the only way a free
/// account gets a profile at all — then signs the unpacked app with the profile
/// Xcode just embedded in the helper, and installs the result.
///
/// The parts here are either pure or touch only AirRefresh's own work folder,
/// so they can be tested without a keychain, a device or an Apple ID.
enum IPASigning {

    /// The helper app's target, scheme and product name.
    static let stubName = "AirRefreshStub"

    /// Per-slot scratch space: the unpacked `.ipa`, the helper project and the
    /// entitlements file. Rebuilt on every run.
    static func workDirectory(for slotID: UUID) -> URL {
        SigningReset.supportDirectory.appending(path: "IPA/\(slotID.uuidString)")
    }

    /// Bundle-relative folders holding code that would need provisioning
    /// profiles of its own — app extensions, watch apps. A free Apple ID gets
    /// three apps and ten bundle ids a week; spending them on a share extension
    /// nobody asked for would be a poor trade, so these are removed instead.
    static let strippedFolders = ["PlugIns", "Extensions", "Watch", "com.apple.WatchPlaceholder"]

    // MARK: - Validation

    /// Reverse-DNS, letters, digits and hyphens: what the developer portal accepts.
    static func isValidBundleID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    static func isValidTeamID(_ value: String) -> Bool {
        value.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil
    }

    // MARK: - The helper project

    struct StubProject: Equatable {
        var directory: URL
        var bundleID: String
        var teamID: String

        var projectURL: URL { directory.appending(path: "\(IPASigning.stubName).xcodeproj") }
    }

    /// Writes the helper project, replacing whatever an earlier run left.
    @discardableResult
    static func writeStubProject(_ stub: StubProject) throws -> URL {
        // Both end up inside a pbxproj; refuse anything that could break out
        // of the quoted value rather than trying to escape it.
        guard isValidBundleID(stub.bundleID) else {
            throw PipelineError("“\(stub.bundleID)” is not a valid bundle id.")
        }
        guard isValidTeamID(stub.teamID) else {
            throw PipelineError("“\(stub.teamID)” is not a valid team id.")
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: stub.directory.path) {
            try fm.removeItem(at: stub.directory)
        }
        let sources = stub.directory.appending(path: stubName)
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        try fm.createDirectory(at: stub.projectURL, withIntermediateDirectories: true)
        try Data("int main(void) { return 0; }\n".utf8).write(to: sources.appending(path: "main.c"))
        try Data(pbxproj(bundleID: stub.bundleID, teamID: stub.teamID).utf8)
            .write(to: stub.projectURL.appending(path: "project.pbxproj"))
        return stub.projectURL
    }

    /// One C file, one iOS app target, automatic signing. Nothing it builds is
    /// ever installed; the build exists for the profile it leaves behind.
    static func pbxproj(bundleID: String, teamID: String) -> String {
        let name = stubName
        return """
        // !$*UTF8*$!
        {
        \tarchiveVersion = 1;
        \tclasses = {
        \t};
        \tobjectVersion = 56;
        \tobjects = {
        \t\tA10000000000000000000001 = {isa = PBXBuildFile; fileRef = A10000000000000000000002; };
        \t\tA10000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = main.c; sourceTree = "<group>"; };
        \t\tA10000000000000000000003 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = \(name).app; sourceTree = BUILT_PRODUCTS_DIR; };
        \t\tA10000000000000000000004 = {isa = PBXGroup; children = (A10000000000000000000005, A10000000000000000000006); sourceTree = "<group>"; };
        \t\tA10000000000000000000005 = {isa = PBXGroup; children = (A10000000000000000000002); path = \(name); sourceTree = "<group>"; };
        \t\tA10000000000000000000006 = {isa = PBXGroup; children = (A10000000000000000000003); name = Products; sourceTree = "<group>"; };
        \t\tA10000000000000000000007 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A10000000000000000000001); runOnlyForDeploymentPostprocessing = 0; };
        \t\tA10000000000000000000008 = {isa = PBXNativeTarget; buildConfigurationList = A1000000000000000000000B; buildPhases = (A10000000000000000000007); buildRules = (); dependencies = (); name = \(name); productName = \(name); productReference = A10000000000000000000003; productType = "com.apple.product-type.application"; };
        \t\tA10000000000000000000009 = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 1600; TargetAttributes = {A10000000000000000000008 = {ProvisioningStyle = Automatic; }; }; }; buildConfigurationList = A1000000000000000000000C; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = A10000000000000000000004; productRefGroup = A10000000000000000000006; projectDirPath = ""; projectRoot = ""; targets = (A10000000000000000000008); };
        \t\tA1000000000000000000000A = {isa = XCBuildConfiguration; buildSettings = {
        \t\t\tCODE_SIGN_STYLE = Automatic;
        \t\t\tDEVELOPMENT_TEAM = "\(teamID)";
        \t\t\tGENERATE_INFOPLIST_FILE = YES;
        \t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;
        \t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.0;
        \t\t\tPRODUCT_BUNDLE_IDENTIFIER = "\(bundleID)";
        \t\t\tPRODUCT_NAME = \(name);
        \t\t\tSDKROOT = iphoneos;
        \t\t\tTARGETED_DEVICE_FAMILY = "1,2";
        \t\t}; name = Debug; };
        \t\tA1000000000000000000000D = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = iphoneos; }; name = Debug; };
        \t\tA1000000000000000000000B = {isa = XCConfigurationList; buildConfigurations = (A1000000000000000000000A); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
        \t\tA1000000000000000000000C = {isa = XCConfigurationList; buildConfigurations = (A1000000000000000000000D); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
        \t};
        \trootObject = A10000000000000000000009;
        }

        """
    }

    // MARK: - Signing

    /// What the re-signed app is entitled to. Deliberately the minimum a free
    /// profile grants: anything the original app asked for beyond this — app
    /// groups, iCloud, push — a personal team could not sign for anyway.
    struct Entitlements: Equatable {
        var teamID: String
        var bundleID: String
        var getTaskAllow: Bool

        var plist: [String: Any] {
            let appID = "\(teamID).\(bundleID)"
            return [
                "application-identifier": appID,
                "com.apple.developer.team-identifier": teamID,
                "get-task-allow": getTaskAllow,
                "keychain-access-groups": [appID]
            ]
        }
    }

    static func writeEntitlements(_ entitlements: Entitlements, to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: entitlements.plist,
                                                      format: .xml, options: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// The SHA-1s of every valid code-signing identity, from
    /// `security find-identity -v -p codesigning`:
    ///
    ///     1) A1B2C3D4E5F60718293A4B5C6D7E8F9012345678 "Apple Development: …"
    static func parseIdentities(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
            guard parts.count >= 2, parts[0].hasSuffix(")"),
                  parts[1].count == 40, parts[1].allSatisfy(\.isHexDigit)
            else { return nil }
            return parts[1].uppercased()
        }
    }

    struct PreparedApp: Equatable {
        var log: [String]
        /// Frameworks and dylibs, deepest first — the order `codesign` needs.
        var nestedCode: [URL]
        /// Carries App Store FairPlay data. Re-signing works; launching will not.
        var looksEncrypted: Bool
    }

    /// Gets an unpacked `.app` ready for `codesign`: drops the code a free
    /// profile cannot cover, embeds the fresh profile and rewrites the bundle
    /// id if it is being changed.
    static func prepareForSigning(app: URL, profile: URL, bundleID: String) throws -> PreparedApp {
        let fm = FileManager.default
        var log: [String] = []

        for folder in strippedFolders {
            let url = app.appending(path: folder)
            guard fm.fileExists(atPath: url.path) else { continue }
            try fm.removeItem(at: url)
            log.append("· removed \(folder)/ — extensions need profiles of their own, which a free Apple ID cannot spare")
        }

        let embedded = app.appending(path: "embedded.mobileprovision")
        if fm.fileExists(atPath: embedded.path) { try fm.removeItem(at: embedded) }
        try fm.copyItem(at: profile, to: embedded)

        let infoURL = app.appending(path: "Info.plist")
        let data = try Data(contentsOf: infoURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var info = try PropertyListSerialization.propertyList(from: data, format: &format)
                as? [String: Any] else {
            throw PipelineError("\(app.lastPathComponent) has an unreadable Info.plist.")
        }
        if let original = info["CFBundleIdentifier"] as? String, original != bundleID {
            info["CFBundleIdentifier"] = bundleID
            try PropertyListSerialization.data(fromPropertyList: info, format: format, options: 0)
                .write(to: infoURL)
            log.append("· bundle id \(original) → \(bundleID)")
        }

        return PreparedApp(log: log,
                           nestedCode: nestedCode(in: app),
                           looksEncrypted: fm.fileExists(atPath: app.appending(path: "SC_Info").path))
    }

    static let nestedCodeExtensions: Set<String> = ["framework", "dylib", "appex", "app", "xpc"]

    /// Every separately signed piece inside `app`, deepest first, so nothing is
    /// sealed before what it contains has been signed.
    static func nestedCode(in app: URL) -> [URL] {
        let root = app.standardizedFileURL.pathComponents.count
        guard let walker = FileManager.default.enumerator(at: app,
                                                          includingPropertiesForKeys: [.isSymbolicLinkKey])
        else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            if nestedCodeExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url.standardizedFileURL)
            }
        }
        return found
            .filter { $0.pathComponents.count > root }
            .sorted {
                $0.pathComponents.count != $1.pathComponents.count
                    ? $0.pathComponents.count > $1.pathComponents.count
                    : $0.path < $1.path
            }
    }

    // MARK: - Reading an .ipa without unpacking it

    /// `CFBundleIdentifier` of the app inside an `.ipa`, read by pulling out
    /// just its Info.plist. Used to fill the bundle id field's placeholder the
    /// moment an `.ipa` is picked; the run itself reads the unpacked copy.
    static func sourceBundleIdentifier(ofIPA ipa: URL) async -> String? {
        guard let listing = try? await Shell.capture("/usr/bin/unzip", ["-Z1", ipa.path]),
              listing.exitCode == 0,
              let entry = infoPlistEntry(in: listing.output)
        else { return nil }

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "airrefresh-ipa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard let result = try? await Shell.capture("/usr/bin/unzip",
                                                    ["-q", "-o", ipa.path, entry, "-d", scratch.path]),
              result.exitCode == 0,
              let data = try? Data(contentsOf: scratch.appending(path: entry)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    /// `Payload/Name.app/Info.plist` out of an `unzip -Z1` listing — the app's
    /// own, not one belonging to a framework or extension inside it.
    static func infoPlistEntry(in listing: String) -> String? {
        listing.split(separator: "\n").map(String.init).first { entry in
            let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 3 && parts[0] == "Payload"
                && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
                // unzip treats these as wildcards; such a name would match
                // other files, or nothing.
                && !entry.contains(where: { "*?[]\\".contains($0) })
        }
    }
}

/// A development team an `.ipa` can be signed for.
struct DevelopmentTeam: Identifiable, Hashable {
    var id: String
    var name: String
    var isFree: Bool = false

    var label: String { name.isEmpty || name == id ? id : "\(name) — \(id)" }
}

/// Finds the teams this Mac can sign for, without asking anyone.
enum TeamDirectory {

    /// Teams of the Apple IDs signed in to Xcode, then any team that has left a
    /// profile on disk.
    static func discover() -> [DevelopmentTeam] {
        var teams = parseXcodeTeams(
            CFPreferencesCopyAppValue("IDEProvisioningTeamByIdentifier" as CFString,
                                      "com.apple.dt.Xcode" as CFString)
        )
        teams += ProfileInspector.installedProfiles().compactMap { profile in
            profile.teamIdentifier.isEmpty ? nil
                : DevelopmentTeam(id: profile.teamIdentifier, name: profile.teamName)
        }
        return deduplicated(teams)
    }

    /// Xcode keeps them as `{ accountID: [{teamID, teamName, isFreeProvisioningTeam}] }`.
    static func parseXcodeTeams(_ value: Any?) -> [DevelopmentTeam] {
        guard let accounts = value as? [String: Any] else { return [] }
        return accounts.keys.sorted().flatMap { key -> [DevelopmentTeam] in
            (accounts[key] as? [[String: Any]] ?? []).compactMap { entry in
                guard let id = entry["teamID"] as? String, !id.isEmpty else { return nil }
                let free = (entry["isFreeProvisioningTeam"] as? Bool)
                    ?? ((entry["isFreeProvisioningTeam"] as? NSNumber)?.boolValue ?? false)
                return DevelopmentTeam(id: id, name: entry["teamName"] as? String ?? "", isFree: free)
            }
        }
    }

    /// First sighting wins — Xcode's entries come first and know more.
    static func deduplicated(_ teams: [DevelopmentTeam]) -> [DevelopmentTeam] {
        var seen: Set<String> = []
        return teams.filter { seen.insert($0.id).inserted }
    }
}

/// A failure with a sentence of its own, for steps that are not a process
/// exiting non-zero. `ShellError.launchFailed` used to stand in, which put
/// "Could not launch process:" in front of things like a missing `.app`.
struct PipelineError: LocalizedError, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
