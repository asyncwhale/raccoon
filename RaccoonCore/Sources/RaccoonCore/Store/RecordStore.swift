import Foundation

// MARK: - RecordStore

/// An actor that persists `Record` values as human-readable `.md` files under a root directory.
///
/// Each record is stored as ONE `.md` file whose name is derived from:
///   `<tool.rawValue>-<yyyy-MM-dd of startedAt>-<first 8 chars of sessionID>.md`
///
/// The actor serializes all file-system access, guaranteeing no data races.
///
/// ## Index ownership
/// When a `SearchIndex` is injected, the store OWNS keeping it in sync: every
/// mutation (`save`, `delete`, `setStarred`, `runCleanup`) updates the index in
/// lock-step with the `.md` files, so the store and index can never desync.
/// When no index is injected (`index == nil`) the store behaves as a pure
/// file-system archive with no search side-effects.
public actor RecordStore {

    // MARK: Properties

    let rootDir: URL
    let fileManager: FileManager

    /// Optional search index kept in sync with the `.md` archive. When non-nil,
    /// every store mutation mirrors into the index. `SearchIndex` is `Sendable`
    /// (all DB access is serialised through a `Sendable` `DatabaseQueue`), so it
    /// is safe to hold and call from within this actor.
    let index: SearchIndex?

    /// Shared ISO-8601 date formatter for filename date components.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    // MARK: Init

    /// Creates a store rooted at `rootDir`.
    ///
    /// - Parameters:
    ///   - rootDir: Directory under which `.md` archives live (created lazily).
    ///   - index: Optional ``SearchIndex`` to keep in sync. Defaults to `nil`
    ///     (no search side-effects). Inject one to have the store own index sync.
    ///   - fileManager: Injected `FileManager`; defaults to `.default`.
    public init(rootDir: URL, index: SearchIndex? = nil, fileManager: FileManager = .default) {
        self.rootDir = rootDir
        self.index = index
        self.fileManager = fileManager
    }

    // MARK: Filename

    /// Characters that are safe to keep verbatim in a single filename component:
    /// ASCII letters, digits, `-`, `_`, and `.`. Everything else (path separators
    /// like `/` and `:`, whitespace, control chars, and any other non-safe scalar)
    /// is replaced with `-` and collapsed. CJK/Unicode letters are intentionally
    /// dropped to `-` so the name stays portable across filesystems.
    private static let safeFilenameScalars: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set = set.intersection(.init(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        set.insert(charactersIn: "-_.")
        return set
    }()

    /// Sanitizes a raw sessionID into a filesystem-safe single path component.
    ///
    /// Replaces every non-safe scalar (path separators, `:`, whitespace, control
    /// chars, etc.) with `-`, collapses runs of `-` into one, and trims leading/
    /// trailing `-`. The FULL sessionID is preserved (no truncation) so that two
    /// sessions sharing a short prefix never collide. UUIDs (36 chars) and Codex
    /// `rollout-…` stems stay well under the 255-char component limit.
    static func sanitize(sessionID: String) -> String {
        var out = ""
        out.reserveCapacity(sessionID.count)
        var lastWasDash = false
        for scalar in sessionID.unicodeScalars {
            if safeFilenameScalars.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        // Trim leading/trailing dashes; fall back to a placeholder if empty.
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "session" : out
    }

    /// Derives the canonical filename for a record:
    /// `<tool>-<yyyy-MM-dd>-<sanitizedSessionID>.md`.
    static func filename(for record: Record) -> String {
        let toolPart = record.tool.rawValue           // already safe ASCII
        let datePart = dateFormatter.string(from: record.startedAt)
        let idPart = sanitize(sessionID: record.sessionID)
        return "\(toolPart)-\(datePart)-\(idPart).md"
    }

    /// The canonical (standardized) `.md` URL a record would be saved to under `rootDir`.
    ///
    /// This is the single source of truth for record → path, used by `save(_:)` and by the
    /// UI to open an archive row at its saved file. Pure: it does NOT touch the filesystem,
    /// so it is safe to call synchronously off the actor.
    public static func fileURL(for record: Record, in rootDir: URL) -> URL {
        rootDir.appendingPathComponent(filename(for: record)).standardizedFileURL
    }

    // MARK: Directory helpers

    private func ensureRootDir() throws {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: rootDir.path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            // A file (not a dir) exists at that path — unusual but handle it.
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.createDirectory(at: rootDir, withIntermediateDirectories: true)
    }

    // MARK: Public API

    /// Encodes `r` and writes it atomically to `<rootDir>/<filename>.md`.
    /// Creates `rootDir` if it doesn't exist.
    ///
    /// When an index is injected, the record is also upserted into it (keyed by
    /// the written path). If indexing throws, this method rethrows AFTER the
    /// `.md` is on disk — so a caller (e.g. `SyncEngine`) does NOT mark the
    /// source file as done and will retry indexing on the next pass. This closes
    /// the "saved-but-unindexed, never retried" gap.
    ///
    /// - Returns: The URL of the written file.
    @discardableResult
    public func save(_ r: Record) throws -> URL {
        try ensureRootDir()
        let std = Self.fileURL(for: r, in: rootDir)
        let md = MarkdownCodec.encode(r)
        guard let data = md.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: std, options: .atomic)
        // Index AFTER the file is written. If this throws, the .md persists but
        // the error propagates so the caller can retry indexing later.
        try index?.index(r, path: std)
        return std
    }

    /// Loads and decodes the `.md` file at `url`.
    public func load(_ url: URL) throws -> Record {
        let data = try Data(contentsOf: url)
        guard let md = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return try MarkdownCodec.decode(md)
    }

    /// Returns lightweight ``RecordSummary`` values for every `.md` file directly
    /// inside `rootDir`, skipping `_trash/`, sorted by `lastActiveAt` DESCENDING.
    ///
    /// Full message bodies are decoded transiently during the scan and immediately
    /// discarded — only the summary fields are retained. This keeps resident memory
    /// low when the archive is large (§9.12 target: <80 MB).
    public func allSummaries() throws -> [RecordSummary] {
        try ensureRootDir()
        let trashPath = rootDir.appendingPathComponent("_trash", isDirectory: true).path

        let contents = try fileManager.contentsOfDirectory(
            at: rootDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var summaries: [RecordSummary] = []
        for url in contents {
            if url.path == trashPath { continue }
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue { continue }
            guard url.pathExtension == "md" else { continue }
            // Decode transiently; let the full Record be freed after extracting fields.
            guard let record = try? load(url) else { continue }
            let summary = RecordSummary(
                path: url.standardizedFileURL,
                tool: record.tool,
                sessionID: record.sessionID,
                project: record.project,
                startedAt: record.startedAt,
                lastActiveAt: record.lastActiveAt,
                starred: record.starred,
                title: record.title
            )
            summaries.append(summary)
        }
        return summaries.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    /// Returns all `Record` values found in `.md` files directly inside `rootDir`,
    /// skipping the `_trash/` subdirectory, sorted by `lastActiveAt` DESCENDING
    /// (most recently active first) for direct use in a list UI.
    public func all() throws -> [Record] {
        try ensureRootDir()
        let trashPath = rootDir.appendingPathComponent("_trash", isDirectory: true).path

        let contents = try fileManager.contentsOfDirectory(
            at: rootDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        var records: [Record] = []
        for url in contents {
            // Skip the _trash directory
            if url.path == trashPath { continue }
            // Skip directories and non-.md files
            var isDir: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue { continue }
            guard url.pathExtension == "md" else { continue }
            // Best-effort decode; skip unreadable files silently
            if let record = try? load(url) {
                records.append(record)
            }
        }
        // Most-recent-first; deterministic across filesystems regardless of
        // directory-enumeration order.
        return records.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    /// Flips `starred` on the record stored at `url` and persists the change atomically.
    ///
    /// When an index is injected, the record is re-synced into it so the index's
    /// `starred` column (and thus `SearchHit.starred`) reflects the new value.
    public func setStarred(_ url: URL, _ starred: Bool) throws {
        var record = try load(url)
        record.starred = starred
        let md = MarkdownCodec.encode(record)
        guard let data = md.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: url, options: .atomic)
        // Re-sync the updated record so the index's starred column tracks it.
        try index?.index(record, path: url.standardizedFileURL)
    }

    /// Permanently deletes the `.md` file at `url` and removes it from the index.
    ///
    /// Unlike `runCleanup` (which moves files to `_trash/` first), this is an
    /// immediate, irreversible delete. Both the file and its index entry are
    /// removed; if the file is already gone the index entry is still purged.
    public func delete(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try index?.remove(path: url.standardizedFileURL)
    }

    /// User-initiated "move this record to the trash".
    ///
    /// MOVES the `.md` at `recordPath` from `rootDir` into `<rootDir>/_trash/`
    /// (the same staging directory `runCleanup` uses), then removes it from the
    /// search index in lock-step. This is NOT a permanent delete: the file lives
    /// on under `_trash/` and is recoverable until the next `runCleanup` purges it
    /// past the trash grace period (default 7 days).
    ///
    /// Mirrors `runCleanup`'s move semantics via the shared
    /// ``moveToTrash(_:)`` helper: ensures `_trash/` exists, preserves the
    /// filename, and disambiguates name collisions with a short UUID suffix.
    ///
    /// - Parameter recordPath: The live `.md` URL under `rootDir` to trash.
    /// - Returns: The destination URL inside `_trash/`.
    /// - Throws: If the file is missing (`CocoaError(.fileNoSuchFile)`) or the
    ///   move/index update fails.
    @discardableResult
    public func trash(_ recordPath: URL) throws -> URL {
        let std = recordPath.standardizedFileURL
        guard fileManager.fileExists(atPath: std.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dest = try moveToTrash(std)
        // The record was indexed under its live path; once trashed it must no
        // longer be searchable. Drop that entry, lock-step with the file move.
        try index?.remove(path: std)
        return dest
    }

    /// Restores a previously trashed record back into the archive root.
    ///
    /// The inverse of ``trash(_:)``: MOVES the `.md` at `trashedURL` (expected to
    /// live under `<rootDir>/_trash/`) back into `rootDir`, then re-adds it to the
    /// search index in lock-step — exactly undoing the file move + de-index that
    /// `trash(_:)` performed. This backs the UI's single-level "Undo" affordance.
    ///
    /// On a name collision in `rootDir` (e.g. a fresh record was saved under the
    /// same canonical name after the original was trashed), the restored file is
    /// disambiguated with a short UUID suffix — mirroring ``moveToTrash(_:)``'s
    /// collision handling so no data is ever overwritten.
    ///
    /// - Parameter trashedURL: The `.md` URL inside `_trash/` to restore.
    /// - Returns: The destination URL inside `rootDir`.
    /// - Throws: `CocoaError(.fileNoSuchFile)` if the trashed file is missing, or
    ///   any error from the move / re-index.
    @discardableResult
    public func untrash(_ trashedURL: URL) throws -> URL {
        let src = trashedURL.standardizedFileURL
        guard fileManager.fileExists(atPath: src.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try ensureRootDir()

        // Reverse-of-trash destination: same filename, back in rootDir. Disambiguate
        // a collision with a short UUID suffix so restore never clobbers a file that
        // now occupies the original name.
        let destName = src.lastPathComponent
        var dest = rootDir.appendingPathComponent(destName)
        if fileManager.fileExists(atPath: dest.path) {
            let uuid = UUID().uuidString.prefix(8)
            let stem = (destName as NSString).deletingPathExtension
            let ext = src.pathExtension
            dest = rootDir.appendingPathComponent("\(stem)-\(uuid).\(ext)")
        }
        let std = dest.standardizedFileURL

        try fileManager.moveItem(at: src, to: std)
        // Re-index the restored record under its new live path, lock-step with the
        // move, so it becomes searchable again — undoing trash's de-index.
        if let record = try? load(std) {
            try index?.index(record, path: std)
        }
        return std
    }
}
