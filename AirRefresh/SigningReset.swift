import Foundation

/// Clears out local provisioning profiles so Xcode is forced to mint fresh ones
/// on the next build. This is the standard cure for the 7-day expiry you get
/// with a free (personal team) Apple ID.
///
/// Nothing is ever deleted outright: profiles are *moved* into a timestamped
/// folder under Application Support, so a bad day is always recoverable.
enum SigningReset {

    /// Which profiles a reset is allowed to touch.
    enum Scope: Equatable {
        /// Only what is actually in the way of one app: profiles that cover
        /// `bundleID`, plus anything that has already expired. This is the
        /// default, and it is what keeps AirRefresh from disturbing the rest of
        /// your signing setup — other slots, other teams, other machines' work.
        case coveringBundleID(String)
        /// Every profile on the machine. The explicit "Reset Signing Only…"
        /// hammer, and the fallback when we could not work out a bundle id.
        case everything

        var summary: String {
            switch self {
            case .coveringBundleID(let id): return "profiles for \(id), plus expired ones"
            case .everything: return "every installed profile"
            }
        }
    }

    /// Both locations Xcode has used for provisioning profiles.
    /// Xcode 16 and later use the first one; older versions used the second.
    static var profileDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "Library/Developer/Xcode/UserData/Provisioning Profiles"),
            home.appending(path: "Library/MobileDevice/Provisioning Profiles")
        ]
    }

    static let profileExtensions: Set<String> = ["mobileprovision", "provisionprofile"]

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/AirRefresh")
    }

    static var backupRoot: URL {
        supportDirectory.appending(path: "ProfileBackups")
    }

    /// How many profiles are sitting on disk right now.
    static func profileCount() -> Int {
        profileDirectories.reduce(0) { $0 + profileURLs(in: $1).count }
    }

    private static func profileURLs(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { profileExtensions.contains($0.pathExtension.lowercased()) }
    }

    struct Outcome {
        var moved: Int
        var kept: Int
        var backup: URL?
    }

    /// Decides whether one profile is in the way of the app we are about to build.
    ///
    /// Split out from the file shuffling so the rule itself is testable.
    static func shouldArchive(_ profile: ProvisioningProfile?, scope: Scope, now: Date = Date()) -> Bool {
        switch scope {
        case .everything:
            return true
        case .coveringBundleID(let bundleID):
            // A profile we cannot read is a profile we leave alone: it belongs
            // to someone else's workflow as far as we can tell.
            guard let profile else { return false }
            if profile.expirationDate <= now { return true }
            return profile.covers(bundleID: bundleID)
        }
    }

    /// Moves the profiles `scope` selects into a fresh backup folder.
    ///
    /// The directories are parameters rather than constants so this — the one
    /// destructive thing the app does — can be exercised against a scratch
    /// directory in the tests instead of the real `~/Library`.
    @discardableResult
    static func archiveProfiles(scope: Scope,
                                in directories: [URL]? = nil,
                                backingUpTo backupDirectory: URL? = nil,
                                log: (String) -> Void) throws -> Outcome {
        let fm = FileManager.default
        let stamp = DateFormatter.backupStamp.string(from: Date())
        let destinationRoot = (backupDirectory ?? backupRoot).appending(path: stamp)
        let profileDirectories = directories ?? Self.profileDirectories
        var moved = 0
        var kept = 0
        /// Every move made so far, so a failure part-way can be undone.
        var journal: [(from: URL, to: URL)] = []

        log("· scope: \(scope.summary)")

        for directory in profileDirectories {
            guard fm.fileExists(atPath: directory.path) else {
                log("· skipped (not present): \(directory.path)")
                continue
            }
            let present = profileURLs(in: directory)
            if present.isEmpty {
                log("· already empty: \(directory.lastPathComponent)")
                continue
            }

            let doomed = present.filter { shouldArchive(ProfileInspector.parse($0), scope: scope) }
            kept += present.count - doomed.count
            guard !doomed.isEmpty else {
                log("· nothing to clear in \(directory.lastPathComponent) (\(present.count) profile(s) left alone)")
                continue
            }

            let bucket = destinationRoot.appending(path: directory.lastPathComponent)
            do {
                try fm.createDirectory(at: bucket, withIntermediateDirectories: true)
            } catch {
                // The second folder failing must not strand what was already
                // moved out of the first.
                log("✗ \(error.localizedDescription)")
                log("· rolling back \(journal.count) profile(s) already moved")
                rollBack(journal, log: log)
                throw error
            }

            for profile in doomed {
                let destination = uniqueDestination(for: profile, in: bucket)
                do {
                    try fm.moveItem(at: profile, to: destination)
                } catch {
                    // A half-finished archive is the worst outcome available:
                    // some apps re-signed, others left holding a profile that
                    // is now missing its siblings, and nothing on screen to say
                    // which is which. Put everything back and fail cleanly.
                    log("✗ \(error.localizedDescription)")
                    log("· rolling back \(journal.count) profile(s) already moved")
                    rollBack(journal, log: log)
                    throw error
                }
                journal.append((from: profile, to: destination))
                moved += 1
            }
            log("· moved \(doomed.count) of \(present.count) profile(s) out of \(directory.lastPathComponent)")
        }

        if moved == 0 {
            log("Nothing needed clearing — no profiles were touched.")
            return Outcome(moved: 0, kept: kept, backup: nil)
        }
        log("Backed up to \(destinationRoot.path)")
        return Outcome(moved: moved, kept: kept, backup: destinationRoot)
    }

    /// Undoes a partial archive, moving each profile back where it came from.
    ///
    /// Best-effort by design: this runs while another error is already on its
    /// way up, and throwing a second one over the top of it would only hide the
    /// first. Anything that cannot be put back is named in the log, where the
    /// user can act on it.
    private static func rollBack(_ journal: [(from: URL, to: URL)], log: (String) -> Void) {
        for entry in journal.reversed() {
            do {
                try FileManager.default.moveItem(at: entry.to, to: entry.from)
            } catch {
                log("· could not restore \(entry.from.lastPathComponent) — it is at \(entry.to.path)")
            }
        }
    }

    /// `foo.mobileprovision`, then `foo-1.mobileprovision`, and so on.
    static func uniqueDestination(for profile: URL, in bucket: URL) -> URL {
        var target = bucket.appending(path: profile.lastPathComponent)
        var attempt = 1
        while FileManager.default.fileExists(atPath: target.path) {
            let base = profile.deletingPathExtension().lastPathComponent
            target = bucket.appending(path: "\(base)-\(attempt).\(profile.pathExtension)")
            attempt += 1
        }
        return target
    }

    /// Per-slot build directory, kept out of the user's own DerivedData.
    static func derivedDataDirectory(for slotID: UUID) -> URL {
        supportDirectory.appending(path: "DerivedData/\(slotID.uuidString)")
    }

    /// Throws away only AirRefresh's own build output for one slot.
    static func cleanDerivedData(for slotID: UUID, log: (String) -> Void) throws {
        let directory = derivedDataDirectory(for: slotID)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            log("· no previous build output to clean")
            return
        }
        try FileManager.default.removeItem(at: directory)
        log("· removed \(directory.path)")
    }
}

extension DateFormatter {
    /// Sortable, filename-safe stamp such as `2026-09-05-104112`.
    static let backupStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}
