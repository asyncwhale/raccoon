import Foundation
import os

/// Helpers for marking Raccoon's local data directories as excluded from
/// off-device backup (Time Machine and the iCloud-backed Application Support
/// drive that macOS replicates by default).
///
/// ## Why
/// The archive (`.md` session transcripts) and the search index (SQLite) hold
/// full session bodies, which may contain secrets a user pasted into a session.
/// For a privacy-first, local-only tool these must NOT be silently copied
/// off-device by a backup the user didn't opt into for this corpus. Setting
/// `URLResourceValues.isExcludedFromBackup` on the data directory tells macOS
/// to skip it (and everything physically inside it) during backup.
///
/// ## Scope note
/// `isExcludedFromBackup` is a PER-URL attribute that is inherited only by
/// children that physically live inside the marked directory. By default
/// `records/`, `notes/`, `index.sqlite`, and `sync-state.json` all live under
/// one `…/Application Support/Raccoon` directory, so marking that one parent
/// covers them all. If a user has relocated `records/` or `notes/` to a path
/// OUTSIDE that parent, those URLs must be marked individually — which is why
/// callers pass every top-level data directory they own.
public enum BackupExclusion {

    private static let log = Logger(subsystem: "com.raccoon.core", category: "BackupExclusion")

    /// Marks `directory` as excluded from Time Machine / iCloud backup.
    ///
    /// This does NOT create the directory and does NOT change where data is
    /// stored — it only flips the backup-exclusion resource flag on an existing
    /// path. It is:
    ///
    /// - **Idempotent**: setting the flag when it is already set is a harmless
    ///   no-op; safe to call on every launch.
    /// - **Failure-tolerant**: never throws and never crashes. If the path does
    ///   not exist or the flag can't be written, it logs and returns `false`.
    ///
    /// - Parameter directory: A file URL for an existing directory to exclude.
    /// - Returns: `true` if the flag was successfully set, `false` otherwise.
    @discardableResult
    public static func exclude(_ directory: URL) -> Bool {
        // Only attempt on a path that actually exists; setResourceValues on a
        // missing path throws, and we'd just be logging noise.
        guard FileManager.default.fileExists(atPath: directory.path) else {
            log.debug("Skip backup-exclusion; path does not exist: \(directory.path, privacy: .public)")
            return false
        }
        do {
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return true
        } catch {
            // Non-fatal: a backup-exclusion failure must never block app launch
            // or data writes. Worst case the dir is still backed up as before.
            log.error("Failed to set isExcludedFromBackup on \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Convenience: marks each directory in `directories` as excluded.
    ///
    /// De-duplicates by standardized path so passing overlapping URLs (e.g. the
    /// parent plus a child that lives inside it) doesn't do redundant work.
    /// Best-effort per directory — one failure does not stop the others.
    public static func exclude(_ directories: [URL]) {
        var seen = Set<String>()
        for dir in directories {
            let key = dir.standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }
            exclude(dir)
        }
    }
}
