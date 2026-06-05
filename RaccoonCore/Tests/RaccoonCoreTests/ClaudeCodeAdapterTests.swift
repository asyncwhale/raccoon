import Testing
import Foundation
@testable import RaccoonCore

// MARK: - Fixture helper

private func fixtureContents(_ name: String) throws -> (contents: String, url: URL) {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "fixtures")!
    let contents = try String(contentsOf: url, encoding: .utf8)
    return (contents, url)
}

// MARK: - ClaudeCodeAdapter — fixture-based tests

@Test func claudeCodeAdapter_toolIsClaudeCode() throws {
    let adapter = ClaudeCodeAdapter()
    #expect(adapter.tool == .claudeCode)
}

@Test func claudeCodeAdapter_parsesFixture_sessionIDAndProject() throws {
    let adapter = ClaudeCodeAdapter()
    let (contents, url) = try fixtureContents("claude-port-forward.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    #expect(record.sessionID == "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
    #expect(record.project == "my-app")
    #expect(record.tool == .claudeCode)
    #expect(record.starred == false)
}

@Test func claudeCodeAdapter_parsesFixture_exactMessageCount() throws {
    let adapter = ClaudeCodeAdapter()
    let (contents, url) = try fixtureContents("claude-port-forward.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    // Expected: 3 messages
    //   1. user "docker compose up fails…"  (string content)
    //   2. assistant text block (tool_use block skipped)
    //   3. user "Got it, killed…"            (string content)
    //   Skipped: permission-mode line
    //   Skipped: user tool_result array line
    #expect(record.messages.count == 3)
}

@Test func claudeCodeAdapter_parsesFixture_messageOrder() throws {
    let adapter = ClaudeCodeAdapter()
    let (contents, url) = try fixtureContents("claude-port-forward.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    #expect(record.messages[0].speaker == .user)
    #expect(record.messages[1].speaker == .claudeCode)
    #expect(record.messages[2].speaker == .user)
}

@Test func claudeCodeAdapter_parsesFixture_userMessageText() throws {
    let adapter = ClaudeCodeAdapter()
    let (contents, url) = try fixtureContents("claude-port-forward.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    #expect(record.messages[0].text.contains("port 5432"))
    #expect(record.messages[2].text.contains("Got it"))
}

@Test func claudeCodeAdapter_parsesFixture_assistantMessageHasNoToolUseContent() throws {
    let adapter = ClaudeCodeAdapter()
    let (contents, url) = try fixtureContents("claude-port-forward.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    let assistantMsg = record.messages[1]
    // Tool-use block names must not appear in text.
    #expect(!assistantMsg.text.contains("toolu_01"))
    #expect(!assistantMsg.text.contains("\"type\":\"tool_use\""))
    // The actual prose text from the text block must be present.
    #expect(assistantMsg.text.contains("5432"))
}

@Test func claudeCodeAdapter_parsesFixture_noPermissionModeLeaked() throws {
    let adapter = ClaudeCodeAdapter()
    let (contents, url) = try fixtureContents("claude-port-forward.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    let allText = record.messages.map(\.text).joined()
    #expect(!allText.contains("acceptEdits"))
    #expect(!allText.contains("permission"))
}

@Test func claudeCodeAdapter_parsesFixture_noToolResultLeaked() throws {
    let adapter = ClaudeCodeAdapter()
    let (contents, url) = try fixtureContents("claude-port-forward.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    let allText = record.messages.map(\.text).joined()
    // tool_result content (the lsof output) must not appear as a message.
    #expect(!allText.contains("COMMAND    PID"))
    #expect(!allText.contains("tool_result"))
}

@Test func claudeCodeAdapter_parsesFixture_timestamps() throws {
    let adapter = ClaudeCodeAdapter()
    let (contents, url) = try fixtureContents("claude-port-forward.jsonl")
    let record = try adapter.parse(contents: contents, fileURL: url)

    // startedAt should be the min timestamp across all lines (09:00:00.000Z)
    // lastActiveAt should be the max timestamp (09:00:20.789Z)
    #expect(record.startedAt < record.lastActiveAt)

    // Verify the first message's timestamp matches the first user line.
    let t0 = record.messages[0].timestamp
    #expect(t0 != nil)
    #expect(t0! == record.startedAt)

    // Verify the last message's timestamp matches the last user line.
    let tLast = record.messages[2].timestamp
    #expect(tLast != nil)
    #expect(tLast! == record.lastActiveAt)
}

// MARK: - AdapterError cases

@Test func claudeCodeAdapter_throwsEmptySession_onEmptyContents() {
    let adapter = ClaudeCodeAdapter()
    let url = URL(fileURLWithPath: "/fake/session.jsonl")
    #expect(throws: AdapterError.emptySession) {
        try adapter.parse(contents: "", fileURL: url)
    }
}

@Test func claudeCodeAdapter_throwsEmptySession_onWhitespaceOnly() {
    let adapter = ClaudeCodeAdapter()
    let url = URL(fileURLWithPath: "/fake/session.jsonl")
    #expect(throws: AdapterError.emptySession) {
        try adapter.parse(contents: "   \n\n\t\n", fileURL: url)
    }
}

@Test func claudeCodeAdapter_throwsNoMessages_whenAllLinesSkipped() throws {
    let adapter = ClaudeCodeAdapter()
    let url = URL(fileURLWithPath: "/fake/session.jsonl")
    // Only a permission-mode line — no conversational content.
    let onlyMeta = """
    {"type":"permission-mode","sessionId":"x","cwd":"/a/b","timestamp":"2026-01-01T00:00:00.000Z","permissionMode":"acceptEdits"}
    """
    #expect(throws: AdapterError.noMessages) {
        try adapter.parse(contents: onlyMeta, fileURL: url)
    }
}

@Test func claudeCodeAdapter_skipsJunkLines_gracefully() throws {
    let adapter = ClaudeCodeAdapter()
    let url = URL(fileURLWithPath: "/fake/session.jsonl")
    let mixed = """
    THIS IS NOT JSON AT ALL !!!
    {"type":"user","sessionId":"abc","cwd":"/x/y","timestamp":"2026-02-01T10:00:00.000Z","message":{"role":"user","content":"hello world"}}
    {broken json
    null
    {"type":"assistant","sessionId":"abc","cwd":"/x/y","timestamp":"2026-02-01T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Hi there!"}]}}
    """
    let record = try adapter.parse(contents: mixed, fileURL: url)
    // Only the two valid conversational lines should survive.
    #expect(record.messages.count == 2)
    #expect(record.messages[0].speaker == .user)
    #expect(record.messages[0].text.contains("hello world"))
    #expect(record.messages[1].speaker == .claudeCode)
    #expect(record.messages[1].text.contains("Hi there"))
}

@Test func claudeCodeAdapter_assistantOnlyToolUse_producesNoMessage() throws {
    let adapter = ClaudeCodeAdapter()
    let url = URL(fileURLWithPath: "/fake/session.jsonl")
    // Assistant turn with ONLY a tool_use block — must yield no message.
    let contents = """
    {"type":"user","sessionId":"s","cwd":"/a/b","timestamp":"2026-02-01T10:00:00.000Z","message":{"role":"user","content":"run the tests"}}
    {"type":"assistant","sessionId":"s","cwd":"/a/b","timestamp":"2026-02-01T10:00:01.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}
    """
    let record = try adapter.parse(contents: contents, fileURL: url)
    // Only the user message should exist; the assistant tool-only turn is dropped.
    #expect(record.messages.count == 1)
    #expect(record.messages[0].speaker == .user)
}

@Test func claudeCodeAdapter_fallbackSessionID_fromFilename() throws {
    let adapter = ClaudeCodeAdapter()
    let url = URL(fileURLWithPath: "/fake/my-fallback-session-id.jsonl")
    // Line has no sessionId field.
    let contents = """
    {"type":"user","cwd":"/a/b","timestamp":"2026-02-01T10:00:00.000Z","message":{"role":"user","content":"no session id here"}}
    """
    let record = try adapter.parse(contents: contents, fileURL: url)
    #expect(record.sessionID == "my-fallback-session-id")
}

@Test func claudeCodeAdapter_fallbackDates_whenNoTimestamps() throws {
    let adapter = ClaudeCodeAdapter()
    let url = URL(fileURLWithPath: "/fake/session.jsonl")
    // No timestamp fields.
    let contents = """
    {"type":"user","sessionId":"s","cwd":"/a/b","message":{"role":"user","content":"no timestamps here"}}
    """
    let record = try adapter.parse(contents: contents, fileURL: url)
    let epoch = Date(timeIntervalSince1970: 0)
    #expect(record.startedAt == epoch)
    #expect(record.lastActiveAt == epoch)
}

// MARK: - sessionFiles filtering

@Test func claudeCodeAdapter_sessionFiles_excludesSubagents() throws {
    let adapter = ClaudeCodeAdapter()
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("RaccoonAdapterTest-\(UUID())")
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    // Create a realistic layout:
    //  tmp/my-project/main-session.jsonl            ← INCLUDE
    //  tmp/my-project/a1b2c3d4-uuid-dir/            ← skip (directory, not .jsonl)
    //  tmp/my-project/a1b2c3d4-uuid-dir/subagents/sub.jsonl  ← EXCLUDE (subagents)

    let projectDir = tmp.appendingPathComponent("my-project")
    let uuidDir = projectDir.appendingPathComponent("a1b2c3d4-uuid-dir")
    let subagentsDir = uuidDir.appendingPathComponent("subagents")
    try fm.createDirectory(at: subagentsDir, withIntermediateDirectories: true)

    let mainSession = projectDir.appendingPathComponent("main-session.jsonl")
    let subSession = subagentsDir.appendingPathComponent("sub.jsonl")
    try "{}".write(to: mainSession, atomically: true, encoding: .utf8)
    try "{}".write(to: subSession, atomically: true, encoding: .utf8)

    let found = adapter.sessionFiles(in: tmp, fileManager: fm)
    #expect(found.count == 1)
    #expect(found[0].lastPathComponent == "main-session.jsonl")
}

@Test func claudeCodeAdapter_sessionFiles_emptyRootReturnsEmpty() {
    let adapter = ClaudeCodeAdapter()
    let fm = FileManager.default
    let nonexistent = URL(fileURLWithPath: "/this/path/does/not/exist")
    let found = adapter.sessionFiles(in: nonexistent, fileManager: fm)
    #expect(found.isEmpty)
}
