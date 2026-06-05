import GRDB
import Foundation

// MARK: - SearchHit

/// A single result from a full-text search over archived records.
public struct SearchHit: Sendable, Equatable {
    /// The canonical path string of the indexed `.md` file.
    public let recordPath: String
    /// The tool that produced the session.
    public let tool: Tool
    /// The record title (first line of first user message, up to 80 chars).
    public let title: String
    /// A short excerpt from the body with matched terms wrapped in `«` / `»`.
    ///
    /// Example: `已知 docker «端口被占用»，请先 lsof -i :5432`
    public let snippet: String
    /// When the session was last active.
    public let lastActiveAt: Date
    /// Whether the underlying record is starred. Kept in sync by `RecordStore`.
    public let starred: Bool
}

// MARK: - SearchIndex

/// A full-text search index over archived `Record` values backed by SQLite FTS5 (trigram tokenizer).
///
/// ## Thread safety
/// `SearchIndex` is `Sendable`. All database access is serialised through `DatabaseQueue`,
/// which is itself `Sendable` and thread-safe.
///
/// ## Storage
/// Pass a file `URL` for a persistent on-disk index, or a `URL` pointing at a temp file for tests.
/// In-memory databases are NOT used — a temp-file database is simpler and avoids GRDB's
/// in-memory path divergence from `:memory:` strings.
///
/// ## FTS approach
/// Uses a **standalone** FTS5 trigram table (`records_fts`) alongside a `records` content table.
/// `index(_:path:)` upserts both tables atomically. See `Schema.swift` for the design rationale.
///
/// ## Snippet format
/// Matched terms are highlighted with «guillemets»:
/// `snippet(records_fts, 1, '«', '»', '…', 20)`
public final class SearchIndex: Sendable {

    // MARK: Storage

    let dbQueue: DatabaseQueue

    // MARK: Init

    /// Creates or opens a search index at `dbURL`.
    ///
    /// - Parameter dbURL: A file URL for the SQLite database. Use a temp-file URL in tests.
    public init(dbURL: URL) throws {
        let queue = try DatabaseQueue(path: dbURL.path)
        try SearchSchema.setup(in: queue)
        self.dbQueue = queue
    }

    // MARK: Indexing

    /// Upserts `record` into the index, keyed by `path`.
    ///
    /// If a row with the same `path` already exists it is replaced atomically;
    /// `count()` remains stable across duplicate calls.
    public func index(_ record: Record, path: URL) throws {
        let pathStr = path.path
        let body    = buildBody(from: record.messages)
        let title   = record.title

        try dbQueue.write { db in
            // Upsert content row
            if let rowid = try Int64.fetchOne(
                db,
                sql: "SELECT rowid FROM records WHERE path = ?",
                arguments: [pathStr]
            ) {
                // Update existing row
                try db.execute(
                    sql: """
                    UPDATE records
                    SET tool = ?, session_id = ?, project = ?,
                        started_at = ?, last_active_at = ?,
                        starred = ?, title = ?, body = ?
                    WHERE path = ?
                    """,
                    arguments: [
                        record.tool.rawValue,
                        record.sessionID,
                        record.project,
                        record.startedAt.timeIntervalSince1970,
                        record.lastActiveAt.timeIntervalSince1970,
                        record.starred ? 1 : 0,
                        title,
                        body,
                        pathStr
                    ]
                )
                // Keep FTS in sync: delete old tokens by rowid, then re-insert
                // For standalone FTS5, DELETE FROM virtual table removes both the
                // shadow-table content row and its index tokens.
                try db.execute(
                    sql: "DELETE FROM records_fts WHERE rowid = ?",
                    arguments: [rowid]
                )
                try db.execute(
                    sql: "INSERT INTO records_fts(rowid, title, body, project) VALUES(?, ?, ?, ?)",
                    arguments: [rowid, title, body, record.project]
                )
            } else {
                // Insert new row
                try db.execute(
                    sql: """
                    INSERT INTO records(path, tool, session_id, project,
                                        started_at, last_active_at, starred, title, body)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        pathStr,
                        record.tool.rawValue,
                        record.sessionID,
                        record.project,
                        record.startedAt.timeIntervalSince1970,
                        record.lastActiveAt.timeIntervalSince1970,
                        record.starred ? 1 : 0,
                        title,
                        body
                    ]
                )
                let rowid = db.lastInsertedRowID
                try db.execute(
                    sql: "INSERT INTO records_fts(rowid, title, body, project) VALUES(?, ?, ?, ?)",
                    arguments: [rowid, title, body, record.project]
                )
            }
        }
    }

    /// Removes the record at `path` from both the content table and the FTS index.
    ///
    /// For standalone FTS5, `DELETE FROM records_fts WHERE rowid = ?` removes the
    /// index tokens as well as the shadow-table content row.
    public func remove(path: URL) throws {
        let pathStr = path.path
        try dbQueue.write { db in
            if let rowid = try Int64.fetchOne(
                db,
                sql: "SELECT rowid FROM records WHERE path = ?",
                arguments: [pathStr]
            ) {
                // Delete from standalone FTS5 — this removes index tokens for the row.
                try db.execute(sql: "DELETE FROM records_fts WHERE rowid = ?", arguments: [rowid])
                try db.execute(sql: "DELETE FROM records WHERE rowid = ?", arguments: [rowid])
            }
        }
    }

    // MARK: Search

    /// Searches the index for `query`, returning up to `limit` hits.
    ///
    /// Two code paths, chosen by query length:
    /// - **≥3 codepoints** → FTS5 trigram `MATCH`, ranked by `bm25`, snippet from
    ///   the FTS `snippet()` function. The query is wrapped as a quoted phrase so
    ///   FTS5 operators (`-`, `AND`, `OR`, `NOT`, `*`, …) are treated as literal.
    /// - **<3 codepoints** (e.g. 2-char CJK like `端口`) → trigram cannot match, so
    ///   we fall back to a `LIKE` scan over the `records` content table
    ///   (`title`/`body`/`project`), ordered by `last_active_at DESC`. LIKE
    ///   wildcards (`\`, `%`, `_`) in the user query are escaped so they are
    ///   literal; the snippet is synthesized in Swift to stay uniform with the
    ///   FTS path (a `±30`-char window around the first body match, wrapped in
    ///   `«»`).
    ///
    /// Results are cross-tool (no tool filter applied).
    public func search(_ query: String, limit: Int = 50) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Short queries (below the trigram minimum) use the LIKE fallback.
        if trimmed.unicodeScalars.count < 3 {
            return try shortQuerySearch(trimmed, limit: limit)
        }

        // Wrap as FTS5 quoted phrase so operator characters (-,+,AND,OR,*,etc.) are literal.
        // FTS5 escapes `"` inside quoted strings by doubling them.
        let ftsQuery = "\"" + trimmed.replacingOccurrences(of: "\"", with: "\"\"") + "\""

        return try dbQueue.read { db -> [SearchHit] in
            // Use FTS5 MATCH with snippet() and bm25() ranking
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT r.path,
                       r.tool,
                       r.title,
                       r.last_active_at,
                       r.starred,
                       snippet(records_fts, 1, '«', '»', '…', 20) AS snip
                FROM records_fts
                JOIN records r ON records_fts.rowid = r.rowid
                WHERE records_fts MATCH ?
                ORDER BY bm25(records_fts)
                LIMIT ?
                """,
                arguments: [ftsQuery, limit]
            )

            return rows.compactMap { row -> SearchHit? in
                let pathStr:       String = row["path"]
                let toolRaw:       String = row["tool"]
                let title:         String = row["title"]
                let lastActiveAt:  Double = row["last_active_at"]
                let starred:       Int    = row["starred"]
                let snippet:       String = row["snip"]

                guard let tool = Tool(rawValue: toolRaw) else { return nil }
                return SearchHit(
                    recordPath: pathStr,
                    tool: tool,
                    title: title,
                    snippet: snippet,
                    lastActiveAt: Date(timeIntervalSince1970: lastActiveAt),
                    starred: starred != 0
                )
            }
        }
    }

    // MARK: Short-query (LIKE) fallback

    /// Escape character used in `LIKE ? ESCAPE '\'` so `%`, `_`, and `\` are literal.
    private static let likeEscape = "\\"

    /// Escapes LIKE metacharacters in `raw` so the value matches literally.
    /// Order matters: escape the escape char first, then `%` and `_`.
    private static func escapeLike(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: likeEscape, with: likeEscape + likeEscape)
            .replacingOccurrences(of: "%", with: likeEscape + "%")
            .replacingOccurrences(of: "_", with: likeEscape + "_")
    }

    /// LIKE-scan fallback for queries below the trigram minimum (e.g. 2-char CJK).
    ///
    /// Matches `title`/`body`/`project` against `%<escaped>%`, ordered by
    /// `last_active_at DESC`, and synthesizes the snippet in Swift so it stays
    /// uniform with the FTS path.
    private func shortQuerySearch(_ trimmed: String, limit: Int) throws -> [SearchHit] {
        let pattern = "%" + Self.escapeLike(trimmed) + "%"

        return try dbQueue.read { db -> [SearchHit] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT path, tool, title, last_active_at, starred, body
                FROM records
                WHERE title   LIKE ? ESCAPE '\\'
                   OR body    LIKE ? ESCAPE '\\'
                   OR project LIKE ? ESCAPE '\\'
                ORDER BY last_active_at DESC
                LIMIT ?
                """,
                arguments: [pattern, pattern, pattern, limit]
            )

            return rows.compactMap { row -> SearchHit? in
                let pathStr:      String = row["path"]
                let toolRaw:      String = row["tool"]
                let title:        String = row["title"]
                let lastActiveAt: Double = row["last_active_at"]
                let starred:      Int    = row["starred"]
                let body:         String = row["body"]

                guard let tool = Tool(rawValue: toolRaw) else { return nil }
                return SearchHit(
                    recordPath: pathStr,
                    tool: tool,
                    title: title,
                    snippet: Self.synthesizeSnippet(body: body, match: trimmed),
                    lastActiveAt: Date(timeIntervalSince1970: lastActiveAt),
                    starred: starred != 0
                )
            }
        }
    }

    /// Builds an FTS-style snippet for the LIKE path: a window of ~30 characters
    /// on each side of the first case-insensitive occurrence of `match` in `body`,
    /// with the matched run wrapped in `«»` and `…` ellipses where truncated.
    ///
    /// Falls back to a leading slice of `body` (or the match itself) when no
    /// occurrence is found — `SearchHit.snippet` is always non-empty for a hit.
    static func synthesizeSnippet(body: String, match: String, window: Int = 30) -> String {
        let pad = "…"
        // Case-insensitive search; operate on Characters so indices align with `body`.
        guard let range = body.range(of: match, options: [.caseInsensitive]) else {
            // Match was in title/project, not body. Show a head slice of the body,
            // or the raw match if the body is empty.
            if body.isEmpty { return "«\(match)»" }
            let head = String(body.prefix(window * 2))
            return head.count < body.count ? head + pad : head
        }

        let lower = body.index(range.lowerBound,
                               offsetBy: -window,
                               limitedBy: body.startIndex) ?? body.startIndex
        let upper = body.index(range.upperBound,
                               offsetBy: window,
                               limitedBy: body.endIndex) ?? body.endIndex

        let prefixEllipsis = lower > body.startIndex ? pad : ""
        let suffixEllipsis = upper < body.endIndex ? pad : ""

        let before = String(body[lower..<range.lowerBound])
        let matched = String(body[range])
        let after = String(body[range.upperBound..<upper])

        return prefixEllipsis + before + "«" + matched + "»" + after + suffixEllipsis
    }

    // MARK: Bulk Operations

    /// Clears the entire index and reindexes from scratch with the given records.
    ///
    /// Useful for a full rebuild after manual `.md` file edits outside of the index.
    /// For standalone FTS5, `DELETE FROM records_fts` removes all tokens and shadow rows.
    public func rebuild(from records: [(record: Record, path: URL)]) throws {
        try dbQueue.write { db in
            // Wipe both tables — DELETE without WHERE clears all rows from standalone FTS5
            try db.execute(sql: "DELETE FROM records")
            try db.execute(sql: "DELETE FROM records_fts")
        }
        for item in records {
            try index(item.record, path: item.path)
        }
    }

    /// Runs the FTS5 `optimize` command, merging index segments for faster queries.
    public func optimize() throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO records_fts(records_fts) VALUES('optimize')")
        }
    }

    // MARK: Diagnostics

    /// Returns the number of records currently in the content table.
    ///
    /// This matches the number of indexed `.md` files (not FTS rows).
    public func count() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM records") ?? 0
        }
    }
}
