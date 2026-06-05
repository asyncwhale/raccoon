import GRDB
import Foundation

// MARK: - Database Schema

/// Sets up the SQLite schema for `SearchIndex` via `DatabaseMigrator`.
///
/// Schema overview:
/// - `records` — content table, one row per indexed `.md` file.
///   - `rowid INTEGER PRIMARY KEY`
///   - `path TEXT UNIQUE NOT NULL` — canonical file URL string (primary key in application logic)
///   - `tool TEXT` — raw value of `Tool`
///   - `session_id TEXT`
///   - `project TEXT` (nullable)
///   - `started_at DOUBLE` — `timeIntervalSince1970`
///   - `last_active_at DOUBLE`
///   - `starred INTEGER` — 0/1
///   - `title TEXT`
///   - `body TEXT` — all messages joined as `"<label>：\n<text>"`, separated by `"\n\n"`
///
/// - `records_fts` — **standalone** FTS5 virtual table with `tokenize='trigram'`.
///   Columns indexed: `title`, `body`, `project`.
///   Choice rationale: standalone FTS is simpler and fully correct for a rebuildable cache;
///   the external-content + trigger approach with trigram tokenizer requires extra care around
///   `content=` + trigger creation ordering that doesn't add value for a disposable index.
///   The `.md` files are the source of truth, so duplication is tolerable.
///
/// Snippet format: matched terms are wrapped with `«` and `»` markers.
/// Example snippet: `«端口被占用»，请先 lsof`

enum SearchSchema {

    static func setup(in dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_search_schema") { db in
            // Content table
            try db.create(table: "records", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("rowid")
                t.column("path",           .text).notNull().unique()
                t.column("tool",           .text)
                t.column("session_id",     .text)
                t.column("project",        .text)
                t.column("started_at",     .double)
                t.column("last_active_at", .double)
                t.column("starred",        .integer)
                t.column("title",          .text)
                t.column("body",           .text)
            }

            // Standalone FTS5 with trigram tokenizer (supports CJK substring search ≥3 codepoints)
            try db.create(virtualTable: "records_fts", ifNotExists: true, using: FTS5()) { t in
                t.tokenizer = FTS5TokenizerDescriptor(components: ["trigram"])
                t.column("title")
                t.column("body")
                t.column("project")
            }
        }

        try migrator.migrate(dbQueue)
    }
}

// MARK: - Body Builder

/// Converts a `Record`'s messages into a single searchable text blob.
///
/// Format per message: `"<speaker.label>：\n<text>"`, joined by `"\n\n"`.
func buildBody(from messages: [Message]) -> String {
    messages.map { msg in
        "\(msg.speaker.label)：\n\(msg.text)"
    }.joined(separator: "\n\n")
}
