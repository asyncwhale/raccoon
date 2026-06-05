import Testing
import Foundation
@testable import RaccoonCore

// MARK: - Fixture helper

private func fixtureContents(_ name: String) throws -> (contents: String, url: URL) {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "fixtures")!
    let contents = try String(contentsOf: url, encoding: .utf8)
    return (contents, url)
}

// MARK: - CodexAdapter — tool identity

@Test func codexAdapter_toolIsCodex() {
    let adapter = CodexAdapter()
    #expect(adapter.tool == .codex)
}

// MARK: - CodexAdapter — item-shape fixture ({"timestamp":…,"item":{…}})

@Test func codexAdapter_itemShape_parsesSessionIDAndProject() throws {
    let adapter = CodexAdapter()
    let (contents, url) = try fixtureContents("codex-item-shape.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    #expect(record.sessionID == "codex-sess-abc123")
    #expect(record.project == "my-app")
    #expect(record.tool == .codex)
    #expect(record.starred == false)
}

@Test func codexAdapter_itemShape_messageCount() throws {
    let adapter = CodexAdapter()
    let (contents, url) = try fixtureContents("codex-item-shape.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    // 1 user + 1 assistant; event_msg is skipped
    #expect(record.messages.count == 2)
}

@Test func codexAdapter_itemShape_messageOrder() throws {
    let adapter = CodexAdapter()
    let (contents, url) = try fixtureContents("codex-item-shape.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    #expect(record.messages[0].speaker == .user)
    #expect(record.messages[1].speaker == .codex)
}

@Test func codexAdapter_itemShape_userMessageText() throws {
    let adapter = CodexAdapter()
    let (contents, url) = try fixtureContents("codex-item-shape.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    #expect(record.messages[0].text.contains("port 5432"))
}

@Test func codexAdapter_itemShape_assistantMessageText() throws {
    let adapter = CodexAdapter()
    let (contents, url) = try fixtureContents("codex-item-shape.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    #expect(record.messages[1].text.contains("5432"))
}

@Test func codexAdapter_itemShape_timestamps() throws {
    let adapter = CodexAdapter()
    let (contents, url) = try fixtureContents("codex-item-shape.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    // startedAt = 09:00:00.000Z (first line), lastActiveAt = 09:00:08.456Z (last line)
    #expect(record.startedAt < record.lastActiveAt)
    #expect(record.messages[0].timestamp != nil)
    #expect(record.messages[1].timestamp != nil)
}

// MARK: - CodexAdapter — payload-shape fixture ({"timestamp":…,"type":…,"payload":{…}})

@Test func codexAdapter_payloadShape_parsesSessionIDAndProject() throws {
    let adapter = CodexAdapter()
    let (contents, url) = try fixtureContents("codex-payload-shape.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    #expect(record.sessionID == "codex-sess-abc123")
    #expect(record.project == "my-app")
    #expect(record.tool == .codex)
    #expect(record.starred == false)
}

@Test func codexAdapter_payloadShape_messageCount() throws {
    let adapter = CodexAdapter()
    let (contents, url) = try fixtureContents("codex-payload-shape.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    // 1 user + 1 assistant; TurnContext is skipped
    #expect(record.messages.count == 2)
}

@Test func codexAdapter_payloadShape_messageOrder() throws {
    let adapter = CodexAdapter()
    let (contents, url) = try fixtureContents("codex-payload-shape.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    #expect(record.messages[0].speaker == .user)
    #expect(record.messages[1].speaker == .codex)
}

// MARK: - Equivalence: both shapes produce logically identical Records

@Test func codexAdapter_bothShapes_equivalentRecords() throws {
    let adapter = CodexAdapter()
    let (itemContents, itemURL) = try fixtureContents("codex-item-shape.jsonl")
    let (payloadContents, payloadURL) = try fixtureContents("codex-payload-shape.jsonl")

    let itemRecord = try adapter.parse(contents: itemContents, fileURL: itemURL)
    let payloadRecord = try adapter.parse(contents: payloadContents, fileURL: payloadURL)

    // Same core metadata
    #expect(itemRecord.sessionID == payloadRecord.sessionID)
    #expect(itemRecord.project == payloadRecord.project)
    #expect(itemRecord.tool == payloadRecord.tool)
    #expect(itemRecord.starred == payloadRecord.starred)

    // Same message structure
    #expect(itemRecord.messages.count == payloadRecord.messages.count)
    for (a, b) in zip(itemRecord.messages, payloadRecord.messages) {
        #expect(a.speaker == b.speaker)
        #expect(a.text == b.text)
    }

    // Same timestamps (same lines)
    #expect(itemRecord.startedAt == payloadRecord.startedAt)
    #expect(itemRecord.lastActiveAt == payloadRecord.lastActiveAt)
}

// MARK: - AdapterError cases

@Test func codexAdapter_throwsEmptySession_onEmptyString() {
    let adapter = CodexAdapter()
    let url = URL(fileURLWithPath: "/fake/rollout-0000-abc.jsonl")
    #expect(throws: AdapterError.emptySession) {
        try adapter.parse(contents: "", fileURL: url)
    }
}

@Test func codexAdapter_throwsEmptySession_onWhitespaceOnly() {
    let adapter = CodexAdapter()
    let url = URL(fileURLWithPath: "/fake/rollout-0000-abc.jsonl")
    #expect(throws: AdapterError.emptySession) {
        try adapter.parse(contents: "   \n\n\t\n", fileURL: url)
    }
}

@Test func codexAdapter_throwsNoMessages_whenAllLinesSkipped() throws {
    let adapter = CodexAdapter()
    let url = URL(fileURLWithPath: "/fake/rollout-0000-abc.jsonl")
    // Only skip-worthy lines (TurnContext + event_msg)
    let onlySkipped = """
    {"timestamp":"2026-01-01T00:00:00.000Z","item":{"type":"TurnContext","context":"init"}}
    {"timestamp":"2026-01-01T00:00:01.000Z","type":"event_msg","payload":{"event":"tool_done"}}
    """
    #expect(throws: AdapterError.noMessages) {
        try adapter.parse(contents: onlySkipped, fileURL: url)
    }
}

// MARK: - Malformed line skipped gracefully

@Test func codexAdapter_skipsJunkLines_gracefully() throws {
    let adapter = CodexAdapter()
    let url = URL(fileURLWithPath: "/fake/rollout-0000-abc.jsonl")
    let mixed = """
    THIS IS NOT JSON AT ALL !!!
    {broken json
    {"timestamp":"2026-02-01T10:00:00.000Z","item":{"type":"session_meta","id":"s1","cwd":"/a/myproj"}}
    {"timestamp":"2026-02-01T10:00:01.000Z","item":{"type":"message","role":"user","content":[{"type":"input_text","text":"hello world"}]}}
    null
    {"timestamp":"2026-02-01T10:00:05.000Z","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi there!"}]}}
    """
    let record = try adapter.parse(contents: mixed, fileURL: url)
    #expect(record.messages.count == 2)
    #expect(record.messages[0].speaker == .user)
    #expect(record.messages[0].text.contains("hello world"))
    #expect(record.messages[1].speaker == .codex)
    #expect(record.messages[1].text.contains("Hi there"))
}

// MARK: - Content as plain string (not an array)

@Test func codexAdapter_contentAsPlainString_tolerated() throws {
    let adapter = CodexAdapter()
    let url = URL(fileURLWithPath: "/fake/rollout-0000-abc.jsonl")
    let contents = """
    {"timestamp":"2026-02-01T10:00:00.000Z","item":{"type":"session_meta","id":"str-test","cwd":"/a/proj"}}
    {"timestamp":"2026-02-01T10:00:01.000Z","item":{"type":"message","role":"user","content":"plain string user message"}}
    {"timestamp":"2026-02-01T10:00:05.000Z","item":{"type":"message","role":"assistant","content":"plain string assistant reply"}}
    """
    let record = try adapter.parse(contents: contents, fileURL: url)
    #expect(record.messages.count == 2)
    #expect(record.messages[0].text.contains("plain string user message"))
    #expect(record.messages[1].text.contains("plain string assistant reply"))
}

// MARK: - Fallback sessionID from filename stem

@Test func codexAdapter_fallbackSessionID_stripsRolloutPrefix() throws {
    let adapter = CodexAdapter()
    let url = URL(fileURLWithPath: "/fake/rollout-1234567890-my-uuid.jsonl")
    // No session_meta line → falls back to file stem (strip "rollout-" prefix)
    let contents = """
    {"timestamp":"2026-02-01T10:00:00.000Z","item":{"type":"message","role":"user","content":"no meta line"}}
    """
    let record = try adapter.parse(contents: contents, fileURL: url)
    // Stem is "rollout-1234567890-my-uuid"; strip "rollout-" prefix → "1234567890-my-uuid"
    #expect(record.sessionID == "1234567890-my-uuid")
}

@Test func codexAdapter_fallbackSessionID_nonRolloutFilename() throws {
    let adapter = CodexAdapter()
    let url = URL(fileURLWithPath: "/fake/other-session-name.jsonl")
    let contents = """
    {"timestamp":"2026-02-01T10:00:00.000Z","item":{"type":"message","role":"user","content":"no meta"}}
    """
    let record = try adapter.parse(contents: contents, fileURL: url)
    // No "rollout-" prefix → full stem used as-is
    #expect(record.sessionID == "other-session-name")
}

// MARK: - Fallback dates when no timestamps

@Test func codexAdapter_fallbackDates_whenNoTimestamps() throws {
    let adapter = CodexAdapter()
    let url = URL(fileURLWithPath: "/fake/rollout-0000-abc.jsonl")
    let contents = """
    {"item":{"type":"message","role":"user","content":"no timestamp field"}}
    """
    let record = try adapter.parse(contents: contents, fileURL: url)
    let epoch = Date(timeIntervalSince1970: 0)
    #expect(record.startedAt == epoch)
    #expect(record.lastActiveAt == epoch)
}

// MARK: - Case-insensitive type matching

@Test func codexAdapter_caseInsensitiveTypes_PascalCase() throws {
    let adapter = CodexAdapter()
    let url = URL(fileURLWithPath: "/fake/rollout-0000-abc.jsonl")
    let contents = """
    {"timestamp":"2026-02-01T10:00:00.000Z","item":{"type":"SessionMeta","id":"pascal-sess","cwd":"/x/pascal-proj"}}
    {"timestamp":"2026-02-01T10:00:01.000Z","item":{"type":"ResponseItem","role":"user","content":[{"type":"input_text","text":"pascal test"}]}}
    {"timestamp":"2026-02-01T10:00:02.000Z","item":{"type":"Compacted","summary":"skipped"}}
    """
    let record = try adapter.parse(contents: contents, fileURL: url)
    #expect(record.sessionID == "pascal-sess")
    #expect(record.project == "pascal-proj")
    #expect(record.messages.count == 1)
    #expect(record.messages[0].speaker == .user)
}

// MARK: - sessionFiles — recursive enumeration

@Test func codexAdapter_sessionFiles_findsRolloutJsonlRecursively() throws {
    let adapter = CodexAdapter()
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("RaccoonCodexTest-\(UUID())")
    defer { try? fm.removeItem(at: tmp) }

    // Simulate: tmp/2026/03/12/rollout-1234-uuid.jsonl
    let dateDir = tmp
        .appendingPathComponent("2026")
        .appendingPathComponent("03")
        .appendingPathComponent("12")
    try fm.createDirectory(at: dateDir, withIntermediateDirectories: true)

    let rollout = dateDir.appendingPathComponent("rollout-1234-uuid.jsonl")
    let nonRollout = dateDir.appendingPathComponent("other.jsonl")
    let notJsonl = dateDir.appendingPathComponent("rollout-9999-abc.txt")

    try "{}".write(to: rollout, atomically: true, encoding: .utf8)
    try "{}".write(to: nonRollout, atomically: true, encoding: .utf8)
    try "{}".write(to: notJsonl, atomically: true, encoding: .utf8)

    let found = adapter.sessionFiles(in: tmp, fileManager: fm)
    // Only rollout-*.jsonl files should be returned
    #expect(found.count == 1)
    #expect(found[0].lastPathComponent == "rollout-1234-uuid.jsonl")
}

@Test func codexAdapter_sessionFiles_emptyRootReturnsEmpty() {
    let adapter = CodexAdapter()
    let nonexistent = URL(fileURLWithPath: "/this/path/does/not/exist")
    let found = adapter.sessionFiles(in: nonexistent, fileManager: FileManager.default)
    #expect(found.isEmpty)
}

// MARK: - Bare item (no wrapper) tolerated

@Test func codexAdapter_bareItem_noWrapperTolerated() throws {
    let adapter = CodexAdapter()
    let url = URL(fileURLWithPath: "/fake/rollout-0000-abc.jsonl")
    // Bare objects without "item" or "payload" wrapper — just a flat dict with "type"
    let contents = """
    {"type":"session_meta","id":"bare-sess","cwd":"/a/bare-proj","timestamp":"2026-02-01T10:00:00.000Z"}
    {"type":"message","role":"user","content":"bare user message","timestamp":"2026-02-01T10:00:01.000Z"}
    {"type":"message","role":"assistant","content":"bare assistant reply","timestamp":"2026-02-01T10:00:05.000Z"}
    """
    let record = try adapter.parse(contents: contents, fileURL: url)
    #expect(record.sessionID == "bare-sess")
    #expect(record.project == "bare-proj")
    #expect(record.messages.count == 2)
    #expect(record.messages[0].speaker == .user)
    #expect(record.messages[0].text.contains("bare user message"))
}
