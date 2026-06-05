import Testing
import Foundation
@testable import RaccoonCore

// MARK: - Helpers

/// Creates a fresh temporary file URL for a test database.
/// Using a temp file (not `:memory:`) so the public `init(dbURL:)` works directly.
private func makeTempDBURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("raccoon-search-test-\(UUID().uuidString).sqlite")
}

/// Removes a temp file after a test.
private func removeTempDB(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// A fake file URL (path need not exist on disk — only used as a unique key).
private func fakeURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp/test-records/\(name).md")
}

/// Builds a minimal `Record` with the supplied messages.
private func makeRecord(
    tool: Tool = .claudeCode,
    sessionID: String = UUID().uuidString,
    project: String? = nil,
    messages: [Message]
) -> Record {
    Record(
        tool: tool,
        sessionID: sessionID,
        project: project,
        startedAt: Date(timeIntervalSince1970: 1_000_000),
        lastActiveAt: Date(timeIntervalSince1970: 1_001_000),
        starred: false,
        messages: messages
    )
}

// MARK: - CJK Trigram (make-or-break test)

/// This test proves that the FTS5 trigram tokenizer can match a ≥3-codepoint CJK substring.
///
/// Body contains: `docker 端口被占用，请先 lsof`
/// Query: `端口被` (3 CJK codepoints — trigram minimum)
///
/// If this test fails with an empty result set, the bundled SQLite lacks trigram support
/// or the tokenizer name is wrong — ESCALATE, do not fall back silently.
@Test("CJK trigram: '端口被' matches body containing '端口被占用'")
func searchCJKTrigram() throws {
    let dbURL = makeTempDBURL()
    defer { removeTempDB(dbURL) }

    let index = try SearchIndex(dbURL: dbURL)

    let dockerRecord = makeRecord(
        tool: .claudeCode,
        messages: [
            Message(speaker: .user,  text: "docker compose 报错", timestamp: nil),
            Message(speaker: .claudeCode, text: "docker 端口被占用，请先 lsof -i :5432", timestamp: nil)
        ]
    )
    try index.index(dockerRecord, path: fakeURL("docker-session"))

    let hits = try index.search("端口被")

    #expect(!hits.isEmpty, "trigram CJK search should return at least one hit")
    let hit = try #require(hits.first)
    #expect(hit.recordPath == fakeURL("docker-session").path)
    #expect(!hit.snippet.isEmpty, "snippet must be non-empty")
    // Snippet should contain the highlighted term
    #expect(hit.snippet.contains("«") && hit.snippet.contains("»"),
            "snippet must contain «»-highlighted match")
}

// MARK: - FIX 3: Short-query (< 3 codepoints) LIKE fallback

/// FIX 3: a 2-character CJK query (below the trigram minimum of 3) must still
/// match via the LIKE fallback, and produce a synthesized non-empty snippet.
@Test("FIX3: 2-char CJK query '端口' matches via LIKE fallback with a non-empty snippet")
func searchShortQueryCJK() throws {
    let dbURL = makeTempDBURL()
    defer { removeTempDB(dbURL) }

    let index = try SearchIndex(dbURL: dbURL)
    let record = makeRecord(
        tool: .claudeCode,
        messages: [
            Message(speaker: .user, text: "docker compose 报错", timestamp: nil),
            Message(speaker: .claudeCode, text: "这是 docker 端口被占用，请先 lsof -i :5432", timestamp: nil)
        ]
    )
    try index.index(record, path: fakeURL("short-cjk"))

    let hits = try index.search("端口")
    #expect(hits.count == 1, "2-char CJK must hit via LIKE fallback (trigram needs >=3)")
    let hit = try #require(hits.first)
    #expect(hit.recordPath == fakeURL("short-cjk").path)
    #expect(!hit.snippet.isEmpty, "synthesized snippet must be non-empty")
    #expect(hit.snippet.contains("«") && hit.snippet.contains("»"),
            "synthesized snippet wraps the match with «»")
    #expect(hit.snippet.contains("端口"))
}

/// FIX 3: a 2-char ASCII query also uses the LIKE fallback (still < 3 codepoints).
@Test("FIX3: 2-char ASCII query 'do' matches a body containing 'docker'")
func searchShortQueryASCII() throws {
    let dbURL = makeTempDBURL()
    defer { removeTempDB(dbURL) }

    let index = try SearchIndex(dbURL: dbURL)
    let record = makeRecord(
        tool: .codex,
        messages: [Message(speaker: .user, text: "please run docker build now", timestamp: nil)]
    )
    try index.index(record, path: fakeURL("short-ascii"))

    let hits = try index.search("do")
    #expect(hits.count == 1)
    #expect(hits[0].tool == .codex)
    #expect(!hits[0].snippet.isEmpty)
}

/// FIX 3: LIKE wildcards in the user query must be ESCAPED so `%` and `_` are
/// treated literally, not as SQL wildcards.
@Test("FIX3: literal '%' / '_' in a short query do not behave as LIKE wildcards")
func searchShortQueryEscapesWildcards() throws {
    let dbURL = makeTempDBURL()
    defer { removeTempDB(dbURL) }

    let index = try SearchIndex(dbURL: dbURL)

    // Record A contains the LITERAL substring "a%b"; record B contains "axb"
    // which an UNescaped "a%b" LIKE pattern would wrongly match.
    let literal = makeRecord(
        tool: .claudeCode,
        messages: [Message(speaker: .user, text: "the token a%b appears here", timestamp: nil)]
    )
    let decoy = makeRecord(
        tool: .claudeCode,
        messages: [Message(speaker: .user, text: "unrelated axb wildcard decoy", timestamp: nil)]
    )
    try index.index(literal, path: fakeURL("literal-pct"))
    try index.index(decoy,   path: fakeURL("decoy-axb"))

    // "a%b" is 3 codepoints, so to exercise the short path use a 2-char query
    // with a wildcard: "%b" should match the literal "%b" in "a%b", NOT every row.
    let hits = try index.search("%b")
    let paths = Set(hits.map(\.recordPath))
    #expect(paths.contains(fakeURL("literal-pct").path),
            "literal '%b' substring must match")
    #expect(!paths.contains(fakeURL("decoy-axb").path),
            "unescaped '%' would wrongly match 'axb'; escaping must prevent that")

    // And an underscore is literal too: "_x" must not match "ax"/"bx" via wildcard.
    let underscore = makeRecord(
        tool: .codex,
        messages: [Message(speaker: .user, text: "config key a_x set", timestamp: nil)]
    )
    try index.index(underscore, path: fakeURL("underscore"))
    let uHits = try index.search("_x")
    let uPaths = Set(uHits.map(\.recordPath))
    #expect(uPaths.contains(fakeURL("underscore").path), "literal '_x' must match 'a_x'")
    #expect(!uPaths.contains(fakeURL("decoy-axb").path),
            "unescaped '_' would wrongly match 'axb'; escaping must prevent that")
}

// MARK: - ASCII Substring Search

@Test("ASCII: 'kubernetes' (exact) returns matching record")
func searchASCIIExact() throws {
    let dbURL = makeTempDBURL()
    defer { removeTempDB(dbURL) }

    let index = try SearchIndex(dbURL: dbURL)

    let k8sRecord = makeRecord(
        tool: .codex,
        messages: [
            Message(speaker: .user,  text: "kubernetes pods crash loop", timestamp: nil),
            Message(speaker: .codex, text: "Check logs with kubectl", timestamp: nil)
        ]
    )
    try index.index(k8sRecord, path: fakeURL("k8s-session"))

    let hits = try index.search("kubernetes")
    #expect(hits.count == 1)
    #expect(hits[0].tool == .codex)
}

@Test("ASCII: 'kuber' (substring prefix) returns matching record")
func searchASCIISubstring() throws {
    let dbURL = makeTempDBURL()
    defer { removeTempDB(dbURL) }

    let index = try SearchIndex(dbURL: dbURL)

    let k8sRecord = makeRecord(
        tool: .codex,
        messages: [
            Message(speaker: .user, text: "kubernetes pods crash loop", timestamp: nil)
        ]
    )
    try index.index(k8sRecord, path: fakeURL("k8s-sub-session"))

    let hits = try index.search("kuber")
    #expect(!hits.isEmpty)
    #expect(hits[0].tool == .codex)
}

// MARK: - Cross-tool Search

@Test("cross-tool: shared term hits both claudeCode and codex records")
func searchCrossTool() throws {
    let dbURL = makeTempDBURL()
    defer { removeTempDB(dbURL) }

    let index = try SearchIndex(dbURL: dbURL)

    let ccRecord = makeRecord(
        tool: .claudeCode,
        messages: [Message(speaker: .user, text: "container restart loop", timestamp: nil)]
    )
    let codexRecord = makeRecord(
        tool: .codex,
        messages: [Message(speaker: .user, text: "container memory limit", timestamp: nil)]
    )
    try index.index(ccRecord,    path: fakeURL("cc-container"))
    try index.index(codexRecord, path: fakeURL("codex-container"))

    let hits = try index.search("container")
    #expect(hits.count == 2)

    let tools = Set(hits.map(\.tool))
    #expect(tools.contains(.claudeCode))
    #expect(tools.contains(.codex))
}

// MARK: - remove(path:)

@Test("remove: deleted record no longer appears in search or count")
func removeRecord() throws {
    let dbURL = makeTempDBURL()
    defer { removeTempDB(dbURL) }

    let index = try SearchIndex(dbURL: dbURL)

    let path1 = fakeURL("removable-a")
    let path2 = fakeURL("keeper-b")

    let r1 = makeRecord(messages: [Message(speaker: .user, text: "unique banana text xyz", timestamp: nil)])
    let r2 = makeRecord(messages: [Message(speaker: .user, text: "keeper content abc", timestamp: nil)])

    try index.index(r1, path: path1)
    try index.index(r2, path: path2)

    #expect(try index.count() == 2)

    try index.remove(path: path1)

    #expect(try index.count() == 1)

    let hits = try index.search("banana")
    #expect(hits.isEmpty, "removed record must not appear in search")
}

// MARK: - Upsert Stability

@Test("upsert: indexing the same path twice keeps count at 1, updates body")
func upsertStability() throws {
    let dbURL = makeTempDBURL()
    defer { removeTempDB(dbURL) }

    let index = try SearchIndex(dbURL: dbURL)

    let path = fakeURL("upsert-session")

    let v1 = makeRecord(messages: [Message(speaker: .user, text: "initial text alpha", timestamp: nil)])
    try index.index(v1, path: path)

    #expect(try index.count() == 1)

    let v2 = makeRecord(messages: [Message(speaker: .user, text: "updated text beta gamma", timestamp: nil)])
    try index.index(v2, path: path)

    #expect(try index.count() == 1, "count must stay at 1 after upsert")

    // Old term gone, new term searchable
    let hitsOld = try index.search("alpha")
    #expect(hitsOld.isEmpty, "old body content must not be found after upsert")

    let hitsNew = try index.search("gamma")
    #expect(!hitsNew.isEmpty, "new body content must be searchable after upsert")
}

// MARK: - rebuild(from:)

@Test("rebuild: wipes and repopulates; count matches input")
func rebuildFromRecords() throws {
    let dbURL = makeTempDBURL()
    defer { removeTempDB(dbURL) }

    let index = try SearchIndex(dbURL: dbURL)

    // Seed with 3 records first
    for i in 0..<3 {
        let r = makeRecord(messages: [Message(speaker: .user, text: "old-record-\(i)", timestamp: nil)])
        try index.index(r, path: fakeURL("old-\(i)"))
    }
    #expect(try index.count() == 3)

    // Rebuild with 2 new records
    // search() wraps queries in FTS5 quoted phrases, so hyphens are treated as literals.
    let newPairs: [(record: Record, path: URL)] = (0..<2).map { i in
        let r = makeRecord(messages: [Message(speaker: .user, text: "fresh-record-\(i)", timestamp: nil)])
        return (record: r, path: fakeURL("fresh-\(i)"))
    }
    try index.rebuild(from: newPairs)

    #expect(try index.count() == 2, "count must equal the number of records passed to rebuild")

    let hitsOld = try index.search("old-record")
    #expect(hitsOld.isEmpty, "rebuild must wipe old records")

    let hitsFresh = try index.search("fresh-record")
    #expect(hitsFresh.count == 2)
}

// MARK: - optimize()

@Test("optimize: runs without error after indexing")
func optimizeNoError() throws {
    let dbURL = makeTempDBURL()
    defer { removeTempDB(dbURL) }

    let index = try SearchIndex(dbURL: dbURL)

    let r = makeRecord(messages: [Message(speaker: .user, text: "optimize test content", timestamp: nil)])
    try index.index(r, path: fakeURL("optimize-session"))

    // Must not throw
    try index.optimize()

    #expect(try index.count() == 1)
}

// MARK: - SearchHit Fields

@Test("SearchHit: tool, title, lastActiveAt, snippet are correctly populated")
func searchHitFields() throws {
    let dbURL = makeTempDBURL()
    defer { removeTempDB(dbURL) }

    let index = try SearchIndex(dbURL: dbURL)

    let date = Date(timeIntervalSince1970: 1_750_000_000)
    let record = Record(
        tool: .codex,
        sessionID: "fields-test-1",
        project: "my-proj",
        startedAt: date,
        lastActiveAt: date,
        starred: true,
        messages: [
            Message(speaker: .user,  text: "How do I fix the flibbertigibbet error?", timestamp: nil),
            Message(speaker: .codex, text: "The flibbertigibbet requires a patch", timestamp: nil)
        ]
    )
    try index.index(record, path: fakeURL("fields-session"))

    let hits = try index.search("flibbertigibbet")
    #expect(hits.count == 1)

    let hit = hits[0]
    #expect(hit.tool == .codex)
    #expect(hit.title == "How do I fix the flibbertigibbet error?")
    // lastActiveAt round-tripped through Double — within 1 second
    #expect(abs(hit.lastActiveAt.timeIntervalSince1970 - date.timeIntervalSince1970) < 1.0)
    #expect(!hit.snippet.isEmpty)
    // FIX 2: starred column is selected and mapped into the hit.
    #expect(hit.starred == true)
}

// MARK: - Empty DB

@Test("empty index: count is 0 and search returns nothing")
func emptyIndex() throws {
    let dbURL = makeTempDBURL()
    defer { removeTempDB(dbURL) }

    let index = try SearchIndex(dbURL: dbURL)

    #expect(try index.count() == 0)
    let hits = try index.search("anything")
    #expect(hits.isEmpty)
}

// MARK: - remove non-existent path (no-op)

@Test("remove: removing a non-existent path is a no-op")
func removeNonExistent() throws {
    let dbURL = makeTempDBURL()
    defer { removeTempDB(dbURL) }

    let index = try SearchIndex(dbURL: dbURL)

    // Must not throw
    try index.remove(path: fakeURL("does-not-exist"))
    #expect(try index.count() == 0)
}
