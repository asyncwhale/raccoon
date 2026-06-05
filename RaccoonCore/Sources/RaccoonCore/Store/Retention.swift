import Foundation
import os

// MARK: - Retention extension

extension RecordStore {

    /// Logger for retention/trash operations.
    private static let retentionLog = Logger(subsystem: "com.raccoon.core", category: "Retention")

    /// The `_trash/` staging directory under `rootDir`.
    var trashDir: URL {
        rootDir.appendingPathComponent("_trash", isDirectory: true)
    }

    /// Moves the `.md` at `sourceURL` into `<rootDir>/_trash/`, creating the trash
    /// directory if needed and disambiguating filename collisions with a short
    /// UUID suffix. Shared by `runCleanup` (automatic retention) and `trash(_:)`
    /// (explicit user action) so both stage files identically.
    ///
    /// Does NOT touch the search index — callers own index sync so they can do it
    /// in lock-step with the move.
    ///
    /// After the move, stamps the destination's modification date to `now` so it
    /// records the *trash-arrival* time, NOT the file's last-written time.
    /// `FileManager.moveItem` preserves the source mtime, which for an old inactive
    /// session reflects when Raccoon last re-parsed it — possibly weeks ago. Phase 2
    /// of ``runCleanup(retentionDays:now:trashGraceDays:protectedPaths:)`` uses this
    /// mtime as the trash-arrival time to decide whether the grace period elapsed;
    /// without the stamp an old record would be moved AND permanently purged in the
    /// same pass, silently destroying the recovery window. (DATA-LOSS P0 fix.)
    ///
    /// - Parameters:
    ///   - sourceURL: The live `.md` URL to move (should be standardized).
    ///   - now: The trash-arrival timestamp to stamp on the destination. Defaults to
    ///     `Date()` for user-initiated ``trash(_:)``; `runCleanup` threads its own
    ///     reference `now` so cleanup is deterministic/testable.
    /// - Returns: The destination URL inside `_trash/`.
    func moveToTrash(_ sourceURL: URL, now: Date = Date()) throws -> URL {
        // Ensure _trash exists.
        var isDir: ObjCBool = false
        if !fileManager.fileExists(atPath: trashDir.path, isDirectory: &isDir) || !isDir.boolValue {
            try fileManager.createDirectory(at: trashDir, withIntermediateDirectories: true)
        }

        // Preserve the filename; avoid collisions by appending a short UUID.
        let destName = sourceURL.lastPathComponent
        var dest = trashDir.appendingPathComponent(destName)
        if fileManager.fileExists(atPath: dest.path) {
            let uuid = UUID().uuidString.prefix(8)
            let stem = (destName as NSString).deletingPathExtension
            let ext = sourceURL.pathExtension
            dest = trashDir.appendingPathComponent("\(stem)-\(uuid).\(ext)")
        }

        try fileManager.moveItem(at: sourceURL, to: dest)

        // Stamp the destination's mtime to the arrival time. `moveItem` preserves
        // the source mtime (which may be old), so without this Phase 2 could treat
        // a just-arrived file as already past its grace period. If the stamp fails
        // the file is still safely moved (recoverable) — it may just be eligible for
        // purge earlier than ideal, so we log it rather than fail the move.
        do {
            try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: dest.path)
        } catch {
            Self.retentionLog.error(
                "Failed to stamp trash-arrival mtime on \(dest.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }

        return dest
    }

    /// Moves live records whose `lastActiveAt` is older than `retentionDays` (and are not starred
    /// and not in `protectedPaths`) into `<rootDir>/_trash/`, then permanently deletes trashed
    /// files whose trash-arrival age exceeds `trashGraceDays`.
    ///
    /// - Parameters:
    ///   - retentionDays: Age threshold in days. `nil` means keep forever (no-op).
    ///   - now: The reference point for all age calculations (injectable for testing).
    ///   - trashGraceDays: How many days a file lives in `_trash/` before permanent deletion.
    ///   - protectedPaths: Paths that must never be moved or deleted.
    /// - Returns: Tuple of trashed URLs and purged URLs.
    @discardableResult
    public func runCleanup(
        retentionDays: Int?,
        now: Date,
        trashGraceDays: Int = 7,
        protectedPaths: Set<URL> = []
    ) throws -> (trashed: [URL], purged: [URL]) {
        guard let retentionDays else { return ([], []) }

        let trashDir = self.trashDir

        // Ensure _trash exists
        var isDir: ObjCBool = false
        if !fileManager.fileExists(atPath: trashDir.path, isDirectory: &isDir) || !isDir.boolValue {
            try fileManager.createDirectory(at: trashDir, withIntermediateDirectories: true)
        }

        let retentionInterval = TimeInterval(retentionDays * 86_400)
        let graceInterval = TimeInterval(trashGraceDays * 86_400)

        // MARK: Phase 1 — Move expired live records to trash

        var trashed: [URL] = []

        // Standardize protected paths once for reliable comparison against
        // the resolved (symlink-expanded) URLs returned by contentsOfDirectory.
        let standardizedProtected = Set(protectedPaths.map { $0.standardizedFileURL })

        let liveContents = try fileManager.contentsOfDirectory(
            at: rootDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for url in liveContents {
            // Standardize to resolve /var → /private/var on macOS
            let stdURL = url.standardizedFileURL

            // Never touch _trash dir itself
            if stdURL.path == trashDir.standardizedFileURL.path { continue }

            // Only process .md files
            guard stdURL.pathExtension == "md" else { continue }

            // Skip protected paths
            if standardizedProtected.contains(stdURL) { continue }

            // Decode to check lastActiveAt and starred
            guard let record = try? load(stdURL) else { continue }
            guard !record.starred else { continue }

            let age = now.timeIntervalSince(record.lastActiveAt)
            guard age > retentionInterval else { continue }

            // Move to _trash via the shared helper (preserves filename, handles
            // collisions). Pass `now` so the destination's mtime records the
            // trash-arrival time — NOT the file's stale last-written time — so
            // Phase 2 below cannot purge it in this same pass.
            let dest = try moveToTrash(stdURL, now: now)
            // The record was indexed under its original live path; once trashed it
            // must no longer be searchable. Remove that entry from the index.
            try index?.remove(path: stdURL)
            trashed.append(dest)
        }

        // MARK: Phase 2 — Purge stale trash

        var purged: [URL] = []

        let trashContents = (try? fileManager.contentsOfDirectory(
            at: trashDir,
            includingPropertiesForKeys: [URLResourceKey.contentModificationDateKey],
            options: [FileManager.DirectoryEnumerationOptions.skipsHiddenFiles]
        )) ?? []

        for url in trashContents {
            guard url.pathExtension == "md" else { continue }

            // Use modification date as trash-arrival time
            let attrs = try fileManager.attributesOfItem(atPath: url.path)
            guard let modDate = attrs[FileAttributeKey.modificationDate] as? Date else { continue }

            let trashAge = now.timeIntervalSince(modDate)
            guard trashAge > graceInterval else { continue }

            try fileManager.removeItem(at: url)
            // Defensive: ensure no index entry survives for a purged file. The
            // entry was already dropped at trash time (keyed by the live path),
            // so this is normally a no-op, but it guarantees the index is clean.
            try index?.remove(path: url)
            purged.append(url)
        }

        return (trashed, purged)
    }
}
