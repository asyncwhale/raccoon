import Testing
import Foundation
@testable import RaccoonCore

// MARK: - Helpers

/// Creates a fresh temporary directory per test.
private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Remove the temp dir when done.
private func removeTempDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

private nonisolated(unsafe) let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
    return f
}()

/// Normalise a Date to second granularity by round-tripping through the ISO formatter.
private func normalise(_ date: Date) -> Date {
    isoFormatter.date(from: isoFormatter.string(from: date)) ?? date
}

/// A canonical sample record used across multiple tests.
private func makeSampleRecord() -> Record {
    Record(
        tool: .codex,
        sessionID: "0193-abcd-efgh-1234567890",
        project: "my-app",
        startedAt: Date(timeIntervalSince1970: 1_747_483_680), // 2025-05-17 14:08:00 UTC
        lastActiveAt: Date(timeIntervalSince1970: 1_747_485_600),
        starred: false,
        messages: [
            Message(speaker: .user,
                    text: "docker compose up 报错 \u{201C}port 5432 already allocated\u{201D}",
                    timestamp: nil),
            Message(speaker: .codex,
                    text: "这是 postgres 端口被占用。先 lsof -i :5432 ...",
                    timestamp: nil)
        ]
    )
}

// MARK: - MarkdownCodec: encode structure

@Test("encode produces correct frontmatter keys")
func encodeFrontmatter() {
    let r = makeSampleRecord()
    let md = MarkdownCodec.encode(r)
    #expect(md.contains("tool: codex"))
    #expect(md.contains("session_id: 0193-abcd-efgh-1234567890"))
    #expect(md.contains("project: my-app"))
    #expect(md.contains("started_at:"))
    #expect(md.contains("last_active_at:"))
    #expect(md.contains("starred: false"))
    // Must be wrapped in ---
    #expect(md.hasPrefix("---\n"))
    let secondFence = md.range(of: "---", range: md.index(md.startIndex, offsetBy: 4)..<md.endIndex)
    #expect(secondFence != nil)
}

@Test("encode produces correct speaker labels with fullwidth colon")
func encodeSpeakerLabels() {
    let r = makeSampleRecord()
    let md = MarkdownCodec.encode(r)
    #expect(md.contains("User：\n"))
    #expect(md.contains("Codex：\n"))
    // The legacy "你：" label must no longer be emitted by the encoder.
    #expect(!md.contains("你："))
}

// MARK: - User label rename ("你" -> "User") + legacy back-compat

/// New archives encode the human speaker as "User：", never the legacy "你：".
@Test("encode uses new User label, not legacy 你")
func encodeUserUsesNewLabel() {
    let r = Record(
        tool: .claudeCode,
        sessionID: "u-1",
        project: nil,
        startedAt: Date(timeIntervalSince1970: 0),
        lastActiveAt: Date(timeIntervalSince1970: 0),
        starred: false,
        messages: [Message(speaker: .user, text: "x", timestamp: nil)]
    )
    let md = MarkdownCodec.encode(r)
    #expect(md.contains("User："))
    #expect(!md.contains("你："))
}

/// Round-trip with the new label preserves the .user speaker and text.
@Test("user message round-trips with new label")
func userRoundTripPreservesSpeaker() throws {
    let r = Record(
        tool: .claudeCode,
        sessionID: "u-2",
        project: nil,
        startedAt: Date(timeIntervalSince1970: 0),
        lastActiveAt: Date(timeIntervalSince1970: 0),
        starred: false,
        messages: [Message(speaker: .user, text: "hi", timestamp: nil)]
    )
    let decoded = try MarkdownCodec.decode(MarkdownCodec.encode(r))
    #expect(decoded.messages.count == 1)
    #expect(decoded.messages[0].speaker == .user)
    #expect(decoded.messages[0].text == "hi")
}

/// BACKWARD COMPAT: an existing on-disk archive written with the legacy "你："
/// user delimiter must still decode to .user, so old archives keep working.
@Test("decode still parses legacy 你 user label")
func decodeLegacyUserLabel() throws {
    let legacyMD = """
    ---
    tool: claude-code
    session_id: legacy-1
    started_at: 2026-05-17T14:08:00+08:00
    last_active_at: 2026-05-17T14:40:00+08:00
    starred: false
    ---

    你：
    old human line

    Claude Code：
    ai reply

    """
    let decoded = try MarkdownCodec.decode(legacyMD)
    #expect(decoded.messages.count == 2)
    #expect(decoded.messages[0].speaker == .user)
    #expect(decoded.messages[0].text == "old human line")
    #expect(decoded.messages[1].speaker == .claudeCode)
    #expect(decoded.messages[1].text == "ai reply")
}

/// The new "User：" delimiter also decodes to .user.
@Test("decode parses new User user label")
func decodeNewUserLabel() throws {
    let md = """
    ---
    tool: claude-code
    session_id: new-1
    started_at: 2026-05-17T14:08:00+08:00
    last_active_at: 2026-05-17T14:40:00+08:00
    starred: false
    ---

    User：
    human line

    """
    let decoded = try MarkdownCodec.decode(md)
    #expect(decoded.messages.count == 1)
    #expect(decoded.messages[0].speaker == .user)
    #expect(decoded.messages[0].text == "human line")
}

/// Mixed speakers round-trip unaffected by the user label rename.
@Test("mixed speakers round-trip unaffected by user rename")
func mixedSpeakersRoundTripUnaffected() throws {
    let r = Record(
        tool: .claudeCode,
        sessionID: "mixed-1",
        project: nil,
        startedAt: Date(timeIntervalSince1970: 0),
        lastActiveAt: Date(timeIntervalSince1970: 0),
        starred: false,
        messages: [
            Message(speaker: .user, text: "q1", timestamp: nil),
            Message(speaker: .claudeCode, text: "a1", timestamp: nil),
            Message(speaker: .codex, text: "a2", timestamp: nil),
            Message(speaker: .gemini, text: "a3", timestamp: nil),
            Message(speaker: .cursor, text: "a4", timestamp: nil),
            Message(speaker: .system, text: "note", timestamp: nil),
        ]
    )
    let decoded = try MarkdownCodec.decode(MarkdownCodec.encode(r))
    #expect(decoded.messages.map(\.speaker)
            == [.user, .claudeCode, .codex, .gemini, .cursor, .system])
    #expect(decoded.messages.map(\.text)
            == ["q1", "a1", "a2", "a3", "a4", "note"])
}

@Test("encode omits project line when project is nil")
func encodeNilProject() {
    let r = Record(
        tool: .claudeCode,
        sessionID: "abc",
        project: nil,
        startedAt: Date(timeIntervalSince1970: 0),
        lastActiveAt: Date(timeIntervalSince1970: 0),
        starred: false,
        messages: []
    )
    let md = MarkdownCodec.encode(r)
    #expect(!md.contains("project:"))
}

// MARK: - MarkdownCodec: round-trip

@Test("decode(encode(r)) == r for simple record")
func roundTripSimple() throws {
    let r = makeSampleRecord()
    let decoded = try MarkdownCodec.decode(MarkdownCodec.encode(r))
    #expect(decoded.tool == r.tool)
    #expect(decoded.sessionID == r.sessionID)
    #expect(decoded.project == r.project)
    #expect(decoded.starred == r.starred)
    #expect(normalise(decoded.startedAt) == normalise(r.startedAt))
    #expect(normalise(decoded.lastActiveAt) == normalise(r.lastActiveAt))
    #expect(decoded.messages.count == r.messages.count)
    for (a, b) in zip(decoded.messages, r.messages) {
        #expect(a.speaker == b.speaker)
        #expect(a.text == b.text)
    }
}

@Test("round-trip preserves tricky text: colons, blank lines, CJK, URLs")
func roundTripTrickyText() throws {
    let trickyText = """
    这是一条包含 http://x/path?q=1 的消息
    Note: 这行也以冒号结尾
    下面是一个空行

    还有更多内容继续
    """
    let r = Record(
        tool: .claudeCode,
        sessionID: "tricky-session-99",
        project: "tricky-proj",
        startedAt: Date(timeIntervalSince1970: 1_000_000),
        lastActiveAt: Date(timeIntervalSince1970: 1_001_000),
        starred: true,
        messages: [
            Message(speaker: .user, text: trickyText, timestamp: nil),
            Message(speaker: .claudeCode, text: "Claude Code response: 好的", timestamp: nil)
        ]
    )
    let md = MarkdownCodec.encode(r)
    let decoded = try MarkdownCodec.decode(md)
    #expect(decoded.messages.count == 2)
    #expect(decoded.messages[0].text == trickyText)
    #expect(decoded.messages[1].text == "Claude Code response: 好的")
    #expect(decoded.messages[0].speaker == .user)
    #expect(decoded.messages[1].speaker == .claudeCode)
}

@Test("round-trip with nil project and no messages")
func roundTripNilProjectNoMessages() throws {
    let r = Record(
        tool: .gemini,
        sessionID: "no-msgs-session",
        project: nil,
        startedAt: Date(timeIntervalSince1970: 500_000),
        lastActiveAt: Date(timeIntervalSince1970: 600_000),
        starred: false,
        messages: []
    )
    let decoded = try MarkdownCodec.decode(MarkdownCodec.encode(r))
    #expect(decoded.project == nil)
    #expect(decoded.messages.isEmpty)
    #expect(decoded.tool == .gemini)
}

@Test("round-trip with starred=true")
func roundTripStarred() throws {
    var r = makeSampleRecord()
    r.starred = true
    let decoded = try MarkdownCodec.decode(MarkdownCodec.encode(r))
    #expect(decoded.starred == true)
}

@Test("decode throws unknownTool for invalid tool value")
func decodeUnknownTool() {
    let md = """
    ---
    tool: unknown-tool
    session_id: abc
    started_at: 2026-01-01T00:00:00Z
    last_active_at: 2026-01-01T00:00:00Z
    starred: false
    ---

    """
    #expect(throws: StoreError.unknownTool) {
        try MarkdownCodec.decode(md)
    }
}

@Test("decode throws malformedFrontmatter when no opening fence")
func decodeMalformedNoFence() {
    let md = "tool: codex\nsession_id: abc\n"
    #expect(throws: StoreError.malformedFrontmatter) {
        try MarkdownCodec.decode(md)
    }
}

@Test("round-trip preserves all speaker types")
func roundTripAllSpeakers() throws {
    let messages: [Message] = Speaker.allCases.map {
        Message(speaker: $0, text: "Test message for \($0.label)", timestamp: nil)
    }
    let r = Record(
        tool: .cursor,
        sessionID: "all-speakers-test",
        project: nil,
        startedAt: Date(timeIntervalSince1970: 1_000_000),
        lastActiveAt: Date(timeIntervalSince1970: 1_001_000),
        starred: false,
        messages: messages
    )
    let decoded = try MarkdownCodec.decode(MarkdownCodec.encode(r))
    #expect(decoded.messages.count == messages.count)
    for (a, b) in zip(decoded.messages, messages) {
        #expect(a.speaker == b.speaker)
        #expect(a.text == b.text)
    }
}

// MARK: - RecordStore: save / load / all

@Test("save writes file with correct name pattern")
func storeFilenamePattern() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)
    let r = makeSampleRecord()
    let url = try await store.save(r)
    // Filename: codex-<yyyy-MM-dd>-<sanitizedSessionID>.md (FULL sessionID, not a prefix)
    let filename = url.lastPathComponent
    #expect(filename.hasPrefix("codex-"))
    #expect(filename.hasSuffix(".md"))
    // Full sessionID is embedded — sanitized but otherwise intact.
    #expect(filename.contains("0193-abcd-efgh-1234567890"))
    #expect(FileManager.default.fileExists(atPath: url.path))
}

/// FIX 1: two sessions sharing the same tool+date AND the same 8-char sessionID
/// prefix must NOT collide. Previously `filename(for:)` truncated to the first
/// 8 chars, so these two records overwrote the same `.md` (silent data loss).
@Test("FIX1: same tool+date+8-char-prefix sessions produce distinct files; both survive all()")
func storeFilenameNoCollisionOnSharedPrefix() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)

    let sharedDate = Date(timeIntervalSince1970: 1_747_483_680)

    var r1 = makeSampleRecord()
    r1.sessionID = "aaaaaaaa-1111-1111-1111-111111111111"
    r1.startedAt = sharedDate

    var r2 = makeSampleRecord()
    r2.sessionID = "aaaaaaaa-2222-2222-2222-222222222222"
    r2.startedAt = sharedDate

    let url1 = try await store.save(r1)
    let url2 = try await store.save(r2)

    // Distinct files — the 8-char shared prefix must not collapse them.
    #expect(url1.lastPathComponent != url2.lastPathComponent)

    // Both survive all(); neither overwrote the other.
    let all = try await store.all()
    #expect(all.count == 2)
    let ids = Set(all.map(\.sessionID))
    #expect(ids.contains("aaaaaaaa-1111-1111-1111-111111111111"))
    #expect(ids.contains("aaaaaaaa-2222-2222-2222-222222222222"))
}

/// FIX 1: filesystem-hostile characters in a sessionID (slash, colon, whitespace,
/// control chars) must be sanitized to `-` and collapsed, never escaping into a
/// path separator or breaking the write.
@Test("FIX1: hostile sessionID chars are sanitized into a safe single-component filename")
func storeFilenameSanitizesHostileChars() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)

    var r = makeSampleRecord()
    r.sessionID = "a/b:c  d\te\u{0007}f"   // slash, colon, spaces, tab, BEL control char

    let url = try await store.save(r)
    let filename = url.lastPathComponent

    // The .md lives directly in rootDir — no extra path component was introduced.
    #expect(url.deletingLastPathComponent().standardizedFileURL.path
            == dir.standardizedFileURL.path)
    // No path separators or hostile chars leaked into the name.
    #expect(!filename.contains("/"))
    #expect(!filename.contains(":"))
    #expect(!filename.contains(" "))
    #expect(!filename.contains("\t"))
    // Repeats collapse: no "--" runs from adjacent sanitized chars.
    #expect(!filename.contains("--"))
    #expect(FileManager.default.fileExists(atPath: url.path))

    // Round-trips: the saved file is loadable and the sessionID is intact in content.
    let loaded = try await store.load(url)
    #expect(loaded.sessionID == "a/b:c  d\te\u{0007}f")
}

@Test("load round-trips a saved record")
func storeLoadEquality() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)
    let r = makeSampleRecord()
    let url = try await store.save(r)
    let loaded = try await store.load(url)
    #expect(loaded.tool == r.tool)
    #expect(loaded.sessionID == r.sessionID)
    #expect(loaded.project == r.project)
    #expect(loaded.starred == r.starred)
    #expect(normalise(loaded.startedAt) == normalise(r.startedAt))
    #expect(normalise(loaded.lastActiveAt) == normalise(r.lastActiveAt))
    #expect(loaded.messages.count == r.messages.count)
    for (a, b) in zip(loaded.messages, r.messages) {
        #expect(a.speaker == b.speaker)
        #expect(a.text == b.text)
    }
}

@Test("all() returns saved records")
func storeAllReturnsSaved() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)

    var r1 = makeSampleRecord()
    r1.sessionID = "aaaa-bbbb"

    var r2 = makeSampleRecord()
    r2.sessionID = "cccc-dddd"
    r2.tool = .claudeCode

    try await store.save(r1)
    try await store.save(r2)

    let all = try await store.all()
    #expect(all.count == 2)
}

/// FIX 6: `all()` must return records sorted by `lastActiveAt` DESCENDING
/// (most recent first) regardless of save / directory-enumeration order.
@Test("FIX6: all() is sorted by lastActiveAt descending")
func storeAllSortedByLastActiveDesc() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)

    let base = Date(timeIntervalSince1970: 1_748_000_000)

    // Save in deliberately NON-sorted order: middle, oldest, newest.
    var mid = makeSampleRecord()
    mid.sessionID = "mid-session"
    mid.lastActiveAt = base.addingTimeInterval(1_000)

    var oldest = makeSampleRecord()
    oldest.sessionID = "oldest-session"
    oldest.lastActiveAt = base

    var newest = makeSampleRecord()
    newest.sessionID = "newest-session"
    newest.lastActiveAt = base.addingTimeInterval(2_000)

    try await store.save(mid)
    try await store.save(oldest)
    try await store.save(newest)

    let all = try await store.all()
    #expect(all.count == 3)
    #expect(all.map(\.sessionID) == ["newest-session", "mid-session", "oldest-session"])
    // Monotonically non-increasing lastActiveAt.
    for i in 1..<all.count {
        #expect(all[i - 1].lastActiveAt >= all[i].lastActiveAt)
    }
}

@Test("all() skips _trash subdirectory")
func storeAllSkipsTrash() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)

    var r = makeSampleRecord()
    r.sessionID = "live-record-1"
    try await store.save(r)

    // Manually write a .md into _trash/
    let trash = dir.appendingPathComponent("_trash", isDirectory: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let trashFile = trash.appendingPathComponent("codex-2025-01-01-trashed1.md")
    let trashData = MarkdownCodec.encode(r).data(using: .utf8)!
    try trashData.write(to: trashFile)

    let all = try await store.all()
    #expect(all.count == 1)
}

@Test("setStarred flips flag and persists")
func storeSetStarred() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)

    let r = makeSampleRecord()  // starred: false
    let url = try await store.save(r)

    try await store.setStarred(url, true)

    let loaded = try await store.load(url)
    #expect(loaded.starred == true)

    // Flip back
    try await store.setStarred(url, false)
    let loaded2 = try await store.load(url)
    #expect(loaded2.starred == false)
}

@Test("all() works when rootDir doesn't exist yet")
func storeAllCreatesRootDir() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    // Do NOT pre-create dir
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)
    let records = try await store.all()
    #expect(records.isEmpty)
    #expect(FileManager.default.fileExists(atPath: dir.path))
}

// MARK: - allSummaries

@Test("allSummaries() returns correct count, sorted desc, with title/tool/starred/path")
func storeAllSummaries() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)

    let base = Date(timeIntervalSince1970: 1_748_000_000)

    var oldest = makeSampleRecord()
    oldest.sessionID = "oldest-sum"
    oldest.tool = .claudeCode
    oldest.starred = false
    oldest.lastActiveAt = base
    oldest.messages = [Message(speaker: .user, text: "oldest title line", timestamp: nil)]

    var mid = makeSampleRecord()
    mid.sessionID = "mid-sum"
    mid.tool = .codex
    mid.starred = true
    mid.lastActiveAt = base.addingTimeInterval(1_000)
    mid.messages = [Message(speaker: .user, text: "mid title line", timestamp: nil)]

    var newest = makeSampleRecord()
    newest.sessionID = "newest-sum"
    newest.tool = .gemini
    newest.starred = false
    newest.lastActiveAt = base.addingTimeInterval(2_000)
    newest.messages = [Message(speaker: .user, text: "newest title line", timestamp: nil)]

    // Save in non-sorted order to verify sort is applied.
    try await store.save(mid)
    try await store.save(oldest)
    try await store.save(newest)

    let summaries = try await store.allSummaries()

    // Count
    #expect(summaries.count == 3)

    // Sorted descending by lastActiveAt
    for i in 1..<summaries.count {
        #expect(summaries[i - 1].lastActiveAt >= summaries[i].lastActiveAt)
    }
    #expect(summaries.map(\.sessionID) == ["newest-sum", "mid-sum", "oldest-sum"])

    // Correct title / tool / starred per record
    let newestSummary = summaries[0]
    #expect(newestSummary.tool == .gemini)
    #expect(newestSummary.starred == false)
    #expect(newestSummary.title == "newest title line")

    let midSummary = summaries[1]
    #expect(midSummary.tool == .codex)
    #expect(midSummary.starred == true)
    #expect(midSummary.title == "mid title line")

    let oldestSummary = summaries[2]
    #expect(oldestSummary.tool == .claudeCode)
    #expect(oldestSummary.starred == false)
    #expect(oldestSummary.title == "oldest title line")

    // Path is an absolute URL pointing to a real .md file
    for summary in summaries {
        #expect(summary.path.pathExtension == "md")
        #expect(FileManager.default.fileExists(atPath: summary.path.path))
    }

    // Sanity: type carries no messages field
    // (RecordSummary has no `messages` property — this is a compile-time guarantee,
    //  but we also verify the file is loadable on demand via store.load)
    let loadedFromPath = try await store.load(summaries[0].path)
    #expect(loadedFromPath.sessionID == "newest-sum")
}

// MARK: - FIX 2: RecordStore owns SearchIndex sync (delete / starred / cleanup)

/// A fresh temp SQLite URL for an index-backed store test.
private func makeStoreTestDBURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("raccoon-store-index-\(UUID().uuidString).sqlite")
}

/// FIX 2: `save` mirrors the record into the injected index so it becomes searchable
/// without any separate `index(...)` call.
@Test("FIX2: save with injected index makes the record searchable immediately")
func storeSaveSyncsIndex() async throws {
    let dir   = try makeTempDir()
    let dbURL = makeStoreTestDBURL()
    defer { removeTempDir(dir); try? FileManager.default.removeItem(at: dbURL) }

    let index = try SearchIndex(dbURL: dbURL)
    let store = RecordStore(rootDir: dir, index: index)

    var r = makeSampleRecord()
    r.sessionID = "save-syncs-index"
    r.messages = [Message(speaker: .user, text: "unique flibberjabber term", timestamp: nil)]
    try await store.save(r)

    #expect(try index.count() == 1)
    let hits = try index.search("flibberjabber")
    #expect(hits.count == 1)
}

/// FIX 2: `delete` removes from BOTH the store and the index — no orphan rows.
@Test("FIX2: delete removes from store AND index (search miss, count drops, all() drops)")
func storeDeleteSyncsIndex() async throws {
    let dir   = try makeTempDir()
    let dbURL = makeStoreTestDBURL()
    defer { removeTempDir(dir); try? FileManager.default.removeItem(at: dbURL) }

    let index = try SearchIndex(dbURL: dbURL)
    let store = RecordStore(rootDir: dir, index: index)

    var keep = makeSampleRecord()
    keep.sessionID = "keep-me"
    keep.messages = [Message(speaker: .user, text: "keeper kumquat content", timestamp: nil)]

    var doomed = makeSampleRecord()
    doomed.sessionID = "delete-me"
    doomed.messages = [Message(speaker: .user, text: "doomed zucchini content", timestamp: nil)]

    try await store.save(keep)
    let doomedURL = try await store.save(doomed)

    #expect(try index.count() == 2)
    #expect(try await store.all().count == 2)

    try await store.delete(doomedURL)

    // Gone from the index.
    #expect(try index.count() == 1)
    #expect(try index.search("zucchini").isEmpty, "deleted record must not be searchable")
    // Gone from the store.
    let remaining = try await store.all()
    #expect(remaining.count == 1)
    #expect(remaining[0].sessionID == "keep-me")
    // The .md file itself is gone.
    #expect(!FileManager.default.fileExists(atPath: doomedURL.path))
}

/// FIX 2: `setStarred(true)` re-syncs the record so a later `search` returns
/// `SearchHit.starred == true`.
@Test("FIX2: setStarred(true) is reflected in SearchHit.starred")
func storeSetStarredSyncsIndex() async throws {
    let dir   = try makeTempDir()
    let dbURL = makeStoreTestDBURL()
    defer { removeTempDir(dir); try? FileManager.default.removeItem(at: dbURL) }

    let index = try SearchIndex(dbURL: dbURL)
    let store = RecordStore(rootDir: dir, index: index)

    var r = makeSampleRecord()           // starred: false
    r.sessionID = "starrable"
    r.messages = [Message(speaker: .user, text: "starrable wombat content", timestamp: nil)]
    let url = try await store.save(r)

    // Before starring, the indexed hit is not starred.
    let before = try index.search("wombat")
    #expect(before.count == 1)
    #expect(before[0].starred == false)

    try await store.setStarred(url, true)

    // After starring, the indexed hit reflects the new value.
    let after = try index.search("wombat")
    #expect(after.count == 1)
    #expect(after[0].starred == true, "index starred column must track setStarred")
}

/// FIX 2: `runCleanup` trashing a record drops it from the index (no longer searchable),
/// even though the `.md` survives in `_trash/`.
@Test("FIX2: runCleanup trashing a record removes it from the search index")
func storeCleanupSyncsIndex() async throws {
    let dir   = try makeTempDir()
    let dbURL = makeStoreTestDBURL()
    defer { removeTempDir(dir); try? FileManager.default.removeItem(at: dbURL) }

    let index = try SearchIndex(dbURL: dbURL)
    let store = RecordStore(rootDir: dir, index: index)

    let anchorDate = Date(timeIntervalSince1970: 1_748_000_000)
    let oldDate = anchorDate.addingTimeInterval(-9 * 86_400)

    var r = Record(
        tool: .codex,
        sessionID: "old-trashable",
        project: nil,
        startedAt: oldDate.addingTimeInterval(-3600),
        lastActiveAt: oldDate,
        starred: false,
        messages: [Message(speaker: .user, text: "trashable aubergine content", timestamp: nil)]
    )
    r.starred = false
    try await store.save(r)

    #expect(try index.search("aubergine").count == 1)

    let result = try await store.runCleanup(retentionDays: 7, now: anchorDate)
    #expect(result.trashed.count == 1)

    // No longer searchable — the index entry for the live path was removed.
    #expect(try index.search("aubergine").isEmpty,
            "trashed record must not remain searchable")
    #expect(try index.count() == 0)
}

/// FIX 2: if indexing throws inside `save`, the error propagates AFTER the `.md`
/// is on disk — so a caller (SyncEngine) does NOT mark the source done and will
/// retry indexing next pass. We force an index failure by removing the index's
/// database directory out from under it.
@Test("FIX2: save rethrows on index failure but the .md is still written")
func storeSaveRethrowsOnIndexFailureButFileSurvives() async throws {
    let dir   = try makeTempDir()
    let dbDir = try makeTempDir()
    defer { removeTempDir(dir); removeTempDir(dbDir) }

    let dbURL = dbDir.appendingPathComponent("idx.sqlite")
    let index = try SearchIndex(dbURL: dbURL)
    let store = RecordStore(rootDir: dir, index: index)

    // Break the index: remove its DB directory so any write throws.
    removeTempDir(dbDir)

    var r = makeSampleRecord()
    r.sessionID = "rethrow-record"

    // save must throw (index failure propagates).
    await #expect(throws: (any Error).self) {
        _ = try await store.save(r)
    }

    // …but the .md was written before indexing was attempted, so it persists
    // and is loadable on disk (the data is not lost).
    let mdFiles = try FileManager.default
        .contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasSuffix(".md") }
    #expect(mdFiles.count == 1, "the .md must be written even when indexing fails")
}

/// FIX 2: a store WITHOUT an injected index behaves exactly as before — pure
/// file archive, no search side-effects, no crashes.
@Test("FIX2: store with no index still saves/loads/deletes as a pure archive")
func storeNoIndexStillWorks() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)   // no index

    var r = makeSampleRecord()
    r.sessionID = "no-index-record"
    let url = try await store.save(r)
    #expect(try await store.all().count == 1)

    // delete still works (just no index side-effect).
    try await store.delete(url)
    #expect(try await store.all().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

// MARK: - Retention cleanup

/// Seeds a record with a controlled lastActiveAt into the store.
private func seed(
    in store: RecordStore,
    sessionID: String,
    lastActiveAt: Date,
    starred: Bool = false
) async throws -> URL {
    let r = Record(
        tool: .codex,
        sessionID: sessionID,
        project: nil,
        startedAt: lastActiveAt.addingTimeInterval(-3600),
        lastActiveAt: lastActiveAt,
        starred: starred,
        messages: [Message(speaker: .user, text: "Test \(sessionID)", timestamp: nil)]
    )
    return try await store.save(r)
}

@Test("cleanup moves old+unstarred, keeps starred and fresh")
func cleanupBasic() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)

    let anchorDate = Date(timeIntervalSince1970: 1_748_000_000)
    let oldDate = anchorDate.addingTimeInterval(-9 * 86_400)   // 9 days ago
    let freshDate = anchorDate.addingTimeInterval(-1 * 86_400)  // 1 day ago

    let _ = try await seed(in: store, sessionID: "old-unstarred", lastActiveAt: oldDate, starred: false)
    let _ = try await seed(in: store, sessionID: "old-starred",   lastActiveAt: oldDate, starred: true)
    let _ = try await seed(in: store, sessionID: "fresh",         lastActiveAt: freshDate, starred: false)

    let result = try await store.runCleanup(
        retentionDays: 7,
        now: anchorDate,
        trashGraceDays: 7
    )

    #expect(result.trashed.count == 1)
    #expect(result.purged.count == 0)

    let remaining = try await store.all()
    #expect(remaining.count == 2)
    let sessionIDs = Set(remaining.map(\.sessionID))
    #expect(sessionIDs.contains("old-starred"))
    #expect(sessionIDs.contains("fresh"))
    #expect(!sessionIDs.contains("old-unstarred"))
}

@Test("cleanup respects protectedPaths")
func cleanupProtectedPaths() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)

    let anchorDate = Date(timeIntervalSince1970: 1_748_000_000)
    let oldDate = anchorDate.addingTimeInterval(-9 * 86_400)

    let protectedURL = try await seed(in: store, sessionID: "protected-old", lastActiveAt: oldDate)
    let _ = try await seed(in: store, sessionID: "unprotected-old", lastActiveAt: oldDate)

    let result = try await store.runCleanup(
        retentionDays: 7,
        now: anchorDate,
        trashGraceDays: 7,
        protectedPaths: [protectedURL]
    )

    // Only the unprotected one is trashed
    #expect(result.trashed.count == 1)

    let remaining = try await store.all()
    #expect(remaining.count == 1)
    #expect(remaining[0].sessionID == "protected-old")
}

@Test("cleanup purges trash after grace period elapses")
func cleanupPurgesStaleTrash() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)

    let anchorDate = Date(timeIntervalSince1970: 1_748_000_000)
    let oldDate = anchorDate.addingTimeInterval(-9 * 86_400)

    let _ = try await seed(in: store, sessionID: "old-to-trash", lastActiveAt: oldDate)

    // First cleanup: moves to trash. moveToTrash now stamps the destination's
    // mtime to `now` (the trash-arrival time), so the file is NOT purged in this
    // same pass (trashAge ≈ 0 < grace) — see cleanupFreshlyTrashedSurvives... below.
    let step1 = try await store.runCleanup(
        retentionDays: 7,
        now: anchorDate,
        trashGraceDays: 7
    )
    #expect(step1.trashed.count == 1)
    #expect(step1.purged.count == 0)

    // To exercise the genuine purge-after-grace path, backdate the trashed file's
    // ARRIVAL time (its now-stamped mtime) to 8 days ago, simulating a file that
    // has actually sat in _trash past the 7-day grace window.
    let trashDir = dir.appendingPathComponent("_trash")
    let trashContents = try FileManager.default.contentsOfDirectory(
        at: trashDir,
        includingPropertiesForKeys: nil,
        options: []
    )
    #expect(trashContents.count == 1)
    let trashFile = trashContents[0]
    let backdatedDate = anchorDate.addingTimeInterval(-8 * 86_400)
    try FileManager.default.setAttributes(
        [.modificationDate: backdatedDate],
        ofItemAtPath: trashFile.path
    )

    // Second cleanup: grace period of 7 days has elapsed → purge
    let laterDate = anchorDate // same now, but modDate was backdated
    let step2 = try await store.runCleanup(
        retentionDays: 7,
        now: laterDate,
        trashGraceDays: 7
    )
    #expect(step2.purged.count == 1)
    #expect(!FileManager.default.fileExists(atPath: trashFile.path))
}

/// DATA-LOSS P0 regression: an OLD inactive session's `.md` carries a stale file
/// mtime (Raccoon last wrote it when it last re-parsed, possibly weeks ago).
/// `FileManager.moveItem` PRESERVES that mtime, so before the fix Phase 1 trashed
/// the record and Phase 2 — reading the preserved-stale mtime as the trash-arrival
/// time — found trashAge > grace and PERMANENTLY DELETED it in the SAME pass,
/// silently erasing the advertised 7-day recovery window. This test does NOT
/// backdate any arrival time; it relies on moveToTrash stamping arrival = now so
/// a freshly-trashed record survives both the same pass AND an immediate next pass.
@Test("FIX P0: old record trashed by cleanup survives same-pass and immediate next-pass purge")
func cleanupFreshlyTrashedSurvivesImmediateRepurge() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)

    let anchorDate = Date(timeIntervalSince1970: 1_748_000_000)
    // Old session, inactive 40 days — comfortably past both retention (7d) AND
    // grace (7d), exactly the case the buggy code purged same-pass.
    let oldDate = anchorDate.addingTimeInterval(-40 * 86_400)

    let savedURL = try await seed(in: store, sessionID: "old-inactive", lastActiveAt: oldDate)

    // Simulate the real-world stale mtime: the live .md was last written long ago.
    // This is what `moveItem` would preserve into _trash absent the fix. We do NOT
    // touch the trashed file's mtime afterward — the fix must stamp it itself.
    try FileManager.default.setAttributes(
        [.modificationDate: oldDate],
        ofItemAtPath: savedURL.path
    )

    // PASS 1: must trash but NOT purge (arrival ≈ now, trashAge ≈ 0 < grace).
    let pass1 = try await store.runCleanup(
        retentionDays: 7,
        now: anchorDate,
        trashGraceDays: 7
    )
    #expect(pass1.trashed.count == 1)
    #expect(pass1.purged.count == 0, "freshly-trashed old record must NOT be purged in the same pass")

    // The record must still be recoverable in _trash.
    let trashDir = dir.appendingPathComponent("_trash")
    let afterPass1 = try FileManager.default.contentsOfDirectory(at: trashDir, includingPropertiesForKeys: nil, options: [])
        .filter { $0.pathExtension == "md" }
    #expect(afterPass1.count == 1, "record must remain recoverable in _trash after pass 1")

    // PASS 2: run cleanup AGAIN immediately. Grace has NOT elapsed, so it must
    // still survive. This is the launch-on-launch scenario.
    let pass2 = try await store.runCleanup(
        retentionDays: 7,
        now: anchorDate,
        trashGraceDays: 7
    )
    #expect(pass2.trashed.count == 0)
    #expect(pass2.purged.count == 0, "record still within grace must NOT be purged on the next pass")

    let afterPass2 = try FileManager.default.contentsOfDirectory(at: trashDir, includingPropertiesForKeys: nil, options: [])
        .filter { $0.pathExtension == "md" }
    #expect(afterPass2.count == 1, "record must remain recoverable in _trash after pass 2")
}

@Test("cleanup with retentionDays nil is a no-op")
func cleanupNilRetention() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }
    let store = RecordStore(rootDir: dir)

    let anchorDate = Date(timeIntervalSince1970: 1_748_000_000)
    let oldDate = anchorDate.addingTimeInterval(-100 * 86_400)

    let _ = try await seed(in: store, sessionID: "very-old", lastActiveAt: oldDate)

    let result = try await store.runCleanup(
        retentionDays: nil,
        now: anchorDate
    )
    #expect(result.trashed.isEmpty)
    #expect(result.purged.isEmpty)

    let remaining = try await store.all()
    #expect(remaining.count == 1)
}

@Test("cleanup never touches files outside rootDir (source-log safety)")
func cleanupDoesNotTouchOutsideRootDir() async throws {
    let dir = try makeTempDir()
    defer { removeTempDir(dir) }

    // Create a sentinel file in a SIBLING directory (not under rootDir)
    let siblingDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
    defer { removeTempDir(siblingDir) }

    let sentinelURL = siblingDir.appendingPathComponent("sentinel.md")
    try "should not be touched".data(using: .utf8)!.write(to: sentinelURL)

    let store = RecordStore(rootDir: dir)
    let anchorDate = Date(timeIntervalSince1970: 1_748_000_000)
    let oldDate = anchorDate.addingTimeInterval(-100 * 86_400)
    let _ = try await seed(in: store, sessionID: "old-record", lastActiveAt: oldDate)

    _ = try await store.runCleanup(retentionDays: 7, now: anchorDate)

    // Sentinel must still exist
    #expect(FileManager.default.fileExists(atPath: sentinelURL.path))

    // And its content is unchanged
    let content = try String(contentsOf: sentinelURL, encoding: .utf8)
    #expect(content == "should not be touched")
}
