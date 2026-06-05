import Testing
import Foundation
@testable import RaccoonCore

// MARK: - Helpers

/// Creates a fresh temporary directory unique to this test invocation.
private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("RaccoonSyncTest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Removes a temp dir (best effort; ignore errors so failing tests don't mask real failures).
private func removeTempDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Creates a temp SQLite URL for a fresh SearchIndex.
private func makeTempDBURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("raccoon-sync-search-\(UUID().uuidString).sqlite")
}

// MARK: - FakeAdapter

/// A test-only `SessionAdapter` whose `sourceRoots` is a single injected directory.
/// `sessionFiles` returns all `*.jsonl` files directly inside that directory.
/// `parse` delegates to `ClaudeCodeAdapter` — tests write minimal claude-schema JSONL fixtures.
private struct FakeAdapter: SessionAdapter {
    let tool: Tool = .claudeCode
    let sourceRoots: [URL]

    init(sourceRoot: URL) {
        self.sourceRoots = [sourceRoot]
    }

    func sessionFiles(in root: URL, fileManager: FileManager) -> [URL] {
        guard let items = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.filter { $0.pathExtension == "jsonl" }
    }

    func parse(contents: String, fileURL: URL) throws -> Record {
        try ClaudeCodeAdapter().parse(contents: contents, fileURL: fileURL)
    }
}

/// A test-only adapter like `FakeAdapter` but with a CONFIGURABLE `tool`, used to
/// exercise `enabledTools` filtering (FIX 5). It still parses claude-schema JSONL
/// via `ClaudeCodeAdapter` but reports whatever `tool` it was constructed with.
private struct ToolFakeAdapter: SessionAdapter {
    let tool: Tool
    let sourceRoots: [URL]

    init(tool: Tool, sourceRoot: URL) {
        self.tool = tool
        self.sourceRoots = [sourceRoot]
    }

    func sessionFiles(in root: URL, fileManager: FileManager) -> [URL] {
        guard let items = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.filter { $0.pathExtension == "jsonl" }
    }

    func parse(contents: String, fileURL: URL) throws -> Record {
        try ClaudeCodeAdapter().parse(contents: contents, fileURL: fileURL)
    }
}

// MARK: - Fixture builders

/// Returns a minimal two-message claude JSONL pair.
///
/// Both messages share the same `sessionId`; the cwd is set so `project` is deterministic.
/// The `timestamp` values are ISO-8601 strings a second apart.
private func makeExchange(
    sessionID: String,
    userText: String,
    assistantText: String,
    startEpoch: TimeInterval = 1_748_000_000
) -> String {
    let t0 = formatISO(epoch: startEpoch)
    let t1 = formatISO(epoch: startEpoch + 1)
    return """
    {"type":"user","sessionId":"\(sessionID)","cwd":"/home/user/fake-project","timestamp":"\(t0)","message":{"role":"user","content":"\(userText)"}}
    {"type":"assistant","sessionId":"\(sessionID)","cwd":"/home/user/fake-project","timestamp":"\(t1)","message":{"role":"assistant","content":[{"type":"text","text":"\(assistantText)"}]}}
    """
}

private func formatISO(epoch: TimeInterval) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date(timeIntervalSince1970: epoch))
}

/// Writes a string to `url`, then backdates its mtime to `epoch` so tests control debounce.
private func write(_ contents: String, to url: URL, mtime mtimeEpoch: TimeInterval) throws {
    try contents.data(using: .utf8)!.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: mtimeEpoch)],
        ofItemAtPath: url.path
    )
}

// MARK: - Tests

/// The SyncEngine test suite.
///
/// Each test gets its own temp directories so tests are fully isolated.
/// `now` is always set well in the future relative to backdated mtimes to defeat debounce.
struct SyncEngineTests {

    // MARK: - Happy path: new file → added:1

    @Test("syncOnce: new JSONL file → added:1, .md exists, index count 1, search finds term")
    func syncNewFile() async throws {
        let srcDir   = try makeTempDir()
        let storeDir = try makeTempDir()
        let dbURL    = makeTempDBURL()
        let statePath = try makeTempDir().appendingPathComponent("state.json")
        defer {
            removeTempDir(srcDir)
            removeTempDir(storeDir)
            try? FileManager.default.removeItem(at: statePath.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: dbURL)
        }

        let s1 = srcDir.appendingPathComponent("s1.jsonl")
        // Backdate mtime to 100 s ago so debounce doesn't bite.
        let fileMtime: TimeInterval = 1_748_000_000
        let nowEpoch:  TimeInterval = fileMtime + 100

        try write(
            makeExchange(
                sessionID: "sess-001",
                userText:  "hello syncengine test",
                assistantText: "hello back from assistant"
            ),
            to: s1, mtime: fileMtime
        )

        let index   = try SearchIndex(dbURL: dbURL)
        let store   = RecordStore(rootDir: storeDir, index: index)
        let adapter = FakeAdapter(sourceRoot: srcDir)
        let engine  = SyncEngine(
            adapters: [adapter],
            store: store,
            statePath: statePath
        )

        let result = try await engine.syncOnce(now: Date(timeIntervalSince1970: nowEpoch))
        #expect(result.added == 1)
        #expect(result.updated == 0)

        // A .md file must exist in the store.
        let allRecords = try await store.all()
        #expect(allRecords.count == 1)
        #expect(allRecords[0].messages.count == 2)

        // Index must contain 1 record.
        #expect(try index.count() == 1)

        // Search must find a term from the user message.
        let hits = try index.search("syncengine")
        #expect(!hits.isEmpty)
    }

    // MARK: - Updated file → updated:1

    @Test("syncOnce: appended JSONL → updated:1, record has 4 messages, search finds new term")
    func syncUpdatedFile() async throws {
        let srcDir    = try makeTempDir()
        let storeDir  = try makeTempDir()
        let dbURL     = makeTempDBURL()
        let stateDir  = try makeTempDir()
        let statePath = stateDir.appendingPathComponent("state.json")
        defer {
            removeTempDir(srcDir); removeTempDir(storeDir)
            removeTempDir(stateDir)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let s1 = srcDir.appendingPathComponent("s1.jsonl")
        let baseMtime: TimeInterval = 1_748_000_000
        let nowEpoch:  TimeInterval = baseMtime + 100

        let exchange1 = makeExchange(
            sessionID: "sess-002",
            userText:  "first user question",
            assistantText: "first assistant answer",
            startEpoch: baseMtime
        )
        try write(exchange1, to: s1, mtime: baseMtime)

        let index   = try SearchIndex(dbURL: dbURL)
        let store   = RecordStore(rootDir: storeDir, index: index)
        let adapter = FakeAdapter(sourceRoot: srcDir)
        let engine  = SyncEngine(adapters: [adapter], store: store, statePath: statePath)

        let r1 = try await engine.syncOnce(now: Date(timeIntervalSince1970: nowEpoch))
        #expect(r1.added == 1, "first pass must add 1")

        // Append a second exchange with a different mtime.
        let growMtime: TimeInterval = baseMtime + 10
        let exchange2 = makeExchange(
            sessionID: "sess-002",
            userText:  "second user question withUniqueWord",
            assistantText: "second assistant answer anotherUniqueWord",
            startEpoch: baseMtime + 5
        )
        let combined = exchange1 + "\n" + exchange2
        try write(combined, to: s1, mtime: growMtime)

        let r2 = try await engine.syncOnce(now: Date(timeIntervalSince1970: nowEpoch + 100))
        #expect(r2.added == 0)
        #expect(r2.updated == 1, "second pass must update 1")

        // Record must now have 4 messages.
        let allRecords = try await store.all()
        #expect(allRecords.count == 1, "still 1 .md (upserted, not duplicated)")
        #expect(allRecords[0].messages.count == 4)

        // Search must find a term from the new exchange.
        let hits = try index.search("withUniqueWord")
        #expect(!hits.isEmpty, "new term must be searchable after update")
    }

    // MARK: - Unchanged file → (0,0)

    @Test("syncOnce: no changes between passes → (0, 0)")
    func syncUnchangedFile() async throws {
        let srcDir    = try makeTempDir()
        let storeDir  = try makeTempDir()
        let dbURL     = makeTempDBURL()
        let stateDir  = try makeTempDir()
        let statePath = stateDir.appendingPathComponent("state.json")
        defer {
            removeTempDir(srcDir); removeTempDir(storeDir)
            removeTempDir(stateDir)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let s1 = srcDir.appendingPathComponent("s1.jsonl")
        let fileMtime: TimeInterval = 1_748_000_000
        try write(
            makeExchange(sessionID: "sess-003", userText: "unchanged file test", assistantText: "reply"),
            to: s1, mtime: fileMtime
        )

        let index   = try SearchIndex(dbURL: dbURL)
        let store   = RecordStore(rootDir: storeDir, index: index)
        let engine  = SyncEngine(
            adapters: [FakeAdapter(sourceRoot: srcDir)],
            store: store, statePath: statePath
        )

        let now = Date(timeIntervalSince1970: fileMtime + 100)
        let r1 = try await engine.syncOnce(now: now)
        #expect(r1.added == 1)

        // Second pass with identical file.
        let r2 = try await engine.syncOnce(now: now)
        #expect(r2.added == 0)
        #expect(r2.updated == 0, "unchanged file must be skipped entirely")
    }

    // MARK: - Debounce: file too recent → skipped this pass, picked up later

    @Test("syncOnce: file modified within debounce window → skipped; later pass ingests it")
    func syncDebounce() async throws {
        let srcDir    = try makeTempDir()
        let storeDir  = try makeTempDir()
        let dbURL     = makeTempDBURL()
        let stateDir  = try makeTempDir()
        let statePath = stateDir.appendingPathComponent("state.json")
        defer {
            removeTempDir(srcDir); removeTempDir(storeDir)
            removeTempDir(stateDir)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let s1 = srcDir.appendingPathComponent("s1.jsonl")
        let fileMtime: TimeInterval = 1_748_000_000

        try write(
            makeExchange(sessionID: "sess-004", userText: "debounce test file", assistantText: "answer"),
            to: s1, mtime: fileMtime
        )

        let index  = try SearchIndex(dbURL: dbURL)
        let store  = RecordStore(rootDir: storeDir, index: index)
        let engine = SyncEngine(
            adapters: [FakeAdapter(sourceRoot: srcDir)],
            store: store, statePath: statePath
        )

        // Pass 1: `now` == file mtime → 0 s elapsed, within the 0.5 s debounce window.
        let nowAtMtime = Date(timeIntervalSince1970: fileMtime)
        let r1 = try await engine.syncOnce(now: nowAtMtime, debounceInterval: 0.5)
        #expect(r1.added == 0, "file within debounce window must be skipped")
        #expect(try index.count() == 0)

        // Pass 2: `now` is well after debounce window — file should be ingested.
        let nowLater = Date(timeIntervalSince1970: fileMtime + 100)
        let r2 = try await engine.syncOnce(now: nowLater, debounceInterval: 0.5)
        #expect(r2.added == 1, "file must be ingested on later pass after debounce expires")
        #expect(try index.count() == 1)
    }

    // MARK: - Shrink handled: truncated file → updated:1, fewer messages

    @Test("syncOnce: truncated JSONL → updated:1, record shrinks back to 2 messages")
    func syncShrinkHandled() async throws {
        let srcDir    = try makeTempDir()
        let storeDir  = try makeTempDir()
        let dbURL     = makeTempDBURL()
        let stateDir  = try makeTempDir()
        let statePath = stateDir.appendingPathComponent("state.json")
        defer {
            removeTempDir(srcDir); removeTempDir(storeDir)
            removeTempDir(stateDir)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let s1 = srcDir.appendingPathComponent("s1.jsonl")
        let baseMtime: TimeInterval = 1_748_000_000

        let exchange1 = makeExchange(
            sessionID: "sess-005",
            userText:  "first question shrink",
            assistantText: "first answer shrink",
            startEpoch: baseMtime
        )
        let exchange2 = makeExchange(
            sessionID: "sess-005",
            userText:  "second question shrink",
            assistantText: "second answer shrink",
            startEpoch: baseMtime + 5
        )

        // Start with 2 exchanges (4 messages).
        try write(exchange1 + "\n" + exchange2, to: s1, mtime: baseMtime)

        let index  = try SearchIndex(dbURL: dbURL)
        let store  = RecordStore(rootDir: storeDir, index: index)
        let engine = SyncEngine(
            adapters: [FakeAdapter(sourceRoot: srcDir)],
            store: store, statePath: statePath
        )

        let now1 = Date(timeIntervalSince1970: baseMtime + 100)
        let r1 = try await engine.syncOnce(now: now1)
        #expect(r1.added == 1)
        let before = try await store.all()
        #expect(before[0].messages.count == 4)

        // Truncate back to 1 exchange (2 messages) with a new mtime.
        let shrinkMtime: TimeInterval = baseMtime + 20
        try write(exchange1, to: s1, mtime: shrinkMtime)

        let now2 = Date(timeIntervalSince1970: shrinkMtime + 100)
        let r2 = try await engine.syncOnce(now: now2)
        #expect(r2.added == 0)
        #expect(r2.updated == 1, "shrunk file must be counted as updated")

        let after = try await store.all()
        #expect(after.count == 1)
        #expect(after[0].messages.count == 2, "whole-file re-read must reflect shrink")
    }

    // MARK: - State persistence: new SyncEngine with same statePath → (0,0)

    @Test("syncOnce: new SyncEngine instance re-loads persisted state → unchanged files skipped")
    func syncStatePersistence() async throws {
        let srcDir    = try makeTempDir()
        let storeDir  = try makeTempDir()
        let dbURL     = makeTempDBURL()
        let stateDir  = try makeTempDir()
        let statePath = stateDir.appendingPathComponent("state.json")
        defer {
            removeTempDir(srcDir); removeTempDir(storeDir)
            removeTempDir(stateDir)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let s1 = srcDir.appendingPathComponent("s1.jsonl")
        let fileMtime: TimeInterval = 1_748_000_000
        try write(
            makeExchange(sessionID: "sess-006", userText: "persistence check", assistantText: "answer"),
            to: s1, mtime: fileMtime
        )

        let index  = try SearchIndex(dbURL: dbURL)
        let store  = RecordStore(rootDir: storeDir, index: index)

        // First engine — syncs and persists state.
        let engine1 = SyncEngine(
            adapters: [FakeAdapter(sourceRoot: srcDir)],
            store: store, statePath: statePath
        )
        let r1 = try await engine1.syncOnce(now: Date(timeIntervalSince1970: fileMtime + 100))
        #expect(r1.added == 1)
        #expect(FileManager.default.fileExists(atPath: statePath.path), "state.json must be written")

        // Second engine — same statePath, unchanged file → must skip.
        let engine2 = SyncEngine(
            adapters: [FakeAdapter(sourceRoot: srcDir)],
            store: store, statePath: statePath
        )
        let r2 = try await engine2.syncOnce(now: Date(timeIntervalSince1970: fileMtime + 200))
        #expect(r2.added == 0)
        #expect(r2.updated == 0, "second engine must reload state and skip unchanged file")
    }

    // MARK: - Empty / no-messages parse → skipped gracefully, no .md created

    @Test("syncOnce: source file whose parse yields noMessages → skipped, no .md, no throw")
    func syncSkipsNoMessagesFile() async throws {
        let srcDir    = try makeTempDir()
        let storeDir  = try makeTempDir()
        let dbURL     = makeTempDBURL()
        let stateDir  = try makeTempDir()
        let statePath = stateDir.appendingPathComponent("state.json")
        defer {
            removeTempDir(srcDir); removeTempDir(storeDir)
            removeTempDir(stateDir)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let empty = srcDir.appendingPathComponent("empty.jsonl")
        let fileMtime: TimeInterval = 1_748_000_000

        // A permission-mode-only line produces AdapterError.noMessages when parsed.
        let noMsgContents = """
        {"type":"permission-mode","sessionId":"x","cwd":"/a/b","timestamp":"2026-01-01T00:00:00.000Z","permissionMode":"acceptEdits"}
        """
        try write(noMsgContents, to: empty, mtime: fileMtime)

        let index  = try SearchIndex(dbURL: dbURL)
        let store  = RecordStore(rootDir: storeDir, index: index)
        let engine = SyncEngine(
            adapters: [FakeAdapter(sourceRoot: srcDir)],
            store: store, statePath: statePath
        )

        // Must not throw; counts must be (0,0).
        let result = try await engine.syncOnce(now: Date(timeIntervalSince1970: fileMtime + 100))
        #expect(result.added == 0)
        #expect(result.updated == 0)

        // No .md must have been created.
        let allRecords = try await store.all()
        #expect(allRecords.isEmpty, "no-messages file must not produce a record")
        #expect(try index.count() == 0)
    }

    // MARK: - SyncEngine never writes to source roots

    @Test("syncOnce: source root is untouched (only reads from it)")
    func syncNeverWritesToSourceRoot() async throws {
        let srcDir    = try makeTempDir()
        let storeDir  = try makeTempDir()
        let dbURL     = makeTempDBURL()
        let stateDir  = try makeTempDir()
        let statePath = stateDir.appendingPathComponent("state.json")
        defer {
            removeTempDir(srcDir); removeTempDir(storeDir)
            removeTempDir(stateDir)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let s1 = srcDir.appendingPathComponent("s1.jsonl")
        let fileMtime: TimeInterval = 1_748_000_000
        try write(
            makeExchange(sessionID: "sess-008", userText: "source root safety", assistantText: "ok"),
            to: s1, mtime: fileMtime
        )

        let itemsBefore = try FileManager.default.contentsOfDirectory(
            at: srcDir, includingPropertiesForKeys: nil, options: []
        )

        let index  = try SearchIndex(dbURL: dbURL)
        let store  = RecordStore(rootDir: storeDir, index: index)
        let engine = SyncEngine(
            adapters: [FakeAdapter(sourceRoot: srcDir)],
            store: store, statePath: statePath
        )
        _ = try await engine.syncOnce(now: Date(timeIntervalSince1970: fileMtime + 100))

        let itemsAfter = try FileManager.default.contentsOfDirectory(
            at: srcDir, includingPropertiesForKeys: nil, options: []
        )
        #expect(
            Set(itemsBefore.map(\.path)) == Set(itemsAfter.map(\.path)),
            "SyncEngine must never create or delete files in the source root"
        )
    }

    // MARK: - Multiple adapters and files

    @Test("syncOnce: two files → added:2 on first pass, (0,0) on second unchanged pass")
    func syncMultipleFiles() async throws {
        let srcDir    = try makeTempDir()
        let storeDir  = try makeTempDir()
        let dbURL     = makeTempDBURL()
        let stateDir  = try makeTempDir()
        let statePath = stateDir.appendingPathComponent("state.json")
        defer {
            removeTempDir(srcDir); removeTempDir(storeDir)
            removeTempDir(stateDir)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let fileMtime: TimeInterval = 1_748_000_000
        // Session IDs must differ in the first 8 chars (the prefix used in .md filenames).
        let sessionIDs = ["aaa-first-multi", "bbb-secnd-multi"]
        for (i, sid) in sessionIDs.enumerated() {
            let f = srcDir.appendingPathComponent("session-\(i + 1).jsonl")
            try write(
                makeExchange(
                    sessionID: sid,
                    userText:  "multi file test \(i + 1)",
                    assistantText: "answer \(i + 1)",
                    startEpoch: fileMtime + Double(i)
                ),
                to: f, mtime: fileMtime + Double(i + 1)
            )
        }

        let index  = try SearchIndex(dbURL: dbURL)
        let store  = RecordStore(rootDir: storeDir, index: index)
        let engine = SyncEngine(
            adapters: [FakeAdapter(sourceRoot: srcDir)],
            store: store, statePath: statePath
        )

        let now = Date(timeIntervalSince1970: fileMtime + 200)
        let r1 = try await engine.syncOnce(now: now)
        #expect(r1.added == 2)
        #expect(r1.updated == 0)
        #expect(try index.count() == 2)

        let r2 = try await engine.syncOnce(now: now)
        #expect(r2.added == 0)
        #expect(r2.updated == 0)
    }

    // MARK: - FIX 4: dead source → archive survives, state pruned

    /// Reads the persisted state.json and returns its key set (the tracked source paths).
    private func persistedStateKeys(at statePath: URL) throws -> Set<String> {
        let data = try Data(contentsOf: statePath)
        let map = try JSONDecoder().decode([String: FileSyncState].self, from: data)
        return Set(map.keys)
    }

    @Test("FIX4: deleting a source file prunes its state key but keeps the archived .md")
    func syncPrunesDeadStateButKeepsArchive() async throws {
        let srcDir    = try makeTempDir()
        let storeDir  = try makeTempDir()
        let dbURL     = makeTempDBURL()
        let stateDir  = try makeTempDir()
        let statePath = stateDir.appendingPathComponent("state.json")
        defer {
            removeTempDir(srcDir); removeTempDir(storeDir)
            removeTempDir(stateDir)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let s1 = srcDir.appendingPathComponent("s1.jsonl")
        let fileMtime: TimeInterval = 1_748_000_000
        try write(
            makeExchange(sessionID: "sess-dead", userText: "doomed source log", assistantText: "ok"),
            to: s1, mtime: fileMtime
        )

        let index  = try SearchIndex(dbURL: dbURL)
        let store  = RecordStore(rootDir: storeDir, index: index)
        let engine = SyncEngine(
            adapters: [FakeAdapter(sourceRoot: srcDir)],
            store: store, statePath: statePath
        )

        // Pass 1: ingest → state has exactly 1 key, archive exists.
        let r1 = try await engine.syncOnce(now: Date(timeIntervalSince1970: fileMtime + 100))
        #expect(r1.added == 1)
        let keys1 = try persistedStateKeys(at: statePath)
        #expect(keys1.count == 1)
        #expect(keys1.contains(s1.standardizedFileURL.path))

        let archivedBefore = try await store.all()
        #expect(archivedBefore.count == 1)

        // Delete the SOURCE log (simulating a tool that rotated/cleaned its session).
        try FileManager.default.removeItem(at: s1)

        // Pass 2: archive .md must survive; the dead state key must be pruned.
        let r2 = try await engine.syncOnce(now: Date(timeIntervalSince1970: fileMtime + 200))
        #expect(r2.added == 0)
        #expect(r2.updated == 0)

        // Archive is permanent (DECISIONS.md #11).
        let archivedAfter = try await store.all()
        #expect(archivedAfter.count == 1, "archived .md must outlive its source log")

        // Dead state key pruned → map no longer grows unbounded.
        let keys2 = try persistedStateKeys(at: statePath)
        #expect(!keys2.contains(s1.standardizedFileURL.path), "dead source key must be pruned")
        #expect(keys2.isEmpty)
    }

    // MARK: - FIX 5: honor enabledTools

    @Test("FIX5: syncOnce(enabledTools:) ingests only adapters whose tool is enabled")
    func syncHonorsEnabledTools() async throws {
        let ccDir     = try makeTempDir()
        let codexDir  = try makeTempDir()
        let storeDir  = try makeTempDir()
        let dbURL     = makeTempDBURL()
        let stateDir  = try makeTempDir()
        let statePath = stateDir.appendingPathComponent("state.json")
        defer {
            removeTempDir(ccDir); removeTempDir(codexDir); removeTempDir(storeDir)
            removeTempDir(stateDir)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let fileMtime: TimeInterval = 1_748_000_000

        // One claudeCode source, one (fake) codex source.
        let ccFile = ccDir.appendingPathComponent("cc.jsonl")
        try write(
            makeExchange(sessionID: "cc-enabled", userText: "claude enabled tool test", assistantText: "ok"),
            to: ccFile, mtime: fileMtime
        )
        let codexFile = codexDir.appendingPathComponent("codex.jsonl")
        try write(
            makeExchange(sessionID: "codex-disabled", userText: "codex disabled tool test", assistantText: "ok"),
            to: codexFile, mtime: fileMtime
        )

        let index  = try SearchIndex(dbURL: dbURL)
        let store  = RecordStore(rootDir: storeDir, index: index)
        let engine = SyncEngine(
            adapters: [
                ToolFakeAdapter(tool: .claudeCode, sourceRoot: ccDir),
                ToolFakeAdapter(tool: .codex,      sourceRoot: codexDir)
            ],
            store: store, statePath: statePath
        )

        // Only claudeCode is enabled → only the claudeCode source is ingested.
        let result = try await engine.syncOnce(
            now: Date(timeIntervalSince1970: fileMtime + 100),
            enabledTools: [.claudeCode]
        )
        #expect(result.added == 1, "only the enabled tool's source should be ingested")

        let all = try await store.all()
        #expect(all.count == 1)
        #expect(all[0].tool == .claudeCode)
        #expect(all[0].sessionID == "cc-enabled")

        // The disabled codex source must not be searchable.
        #expect(try index.search("disabled").isEmpty,
                "disabled tool's content must not be indexed")
        #expect(try index.search("enabled").count == 1)
    }

    // MARK: - Size cap: oversized source file is skipped (not loaded), no crash

    @Test("size cap: shouldSkipBySize is a pure boundary check")
    func sizeCapPureHelper() {
        let cap = SyncEngine.maxSourceFileBytes
        #expect(SyncEngine.shouldSkipBySize(0) == false)
        #expect(SyncEngine.shouldSkipBySize(cap) == false, "exactly at the cap is allowed")
        #expect(SyncEngine.shouldSkipBySize(cap + 1) == true, "one byte over the cap is skipped")
        // Custom limit overload (used so the policy is testable without a giant fixture).
        #expect(SyncEngine.shouldSkipBySize(100, limit: 100) == false)
        #expect(SyncEngine.shouldSkipBySize(101, limit: 100) == true)
        #expect(SyncEngine.maxSourceFileBytes == 50 * 1024 * 1024)
    }

    @Test("size cap: an oversized source file is skipped without ingesting and without crashing")
    func sizeCapSkipsOversizedFile() async throws {
        let srcDir    = try makeTempDir()
        let storeDir  = try makeTempDir()
        let dbURL     = makeTempDBURL()
        let stateDir  = try makeTempDir()
        let statePath = stateDir.appendingPathComponent("state.json")
        defer {
            removeTempDir(srcDir); removeTempDir(storeDir)
            removeTempDir(stateDir)
            try? FileManager.default.removeItem(at: dbURL)
        }

        // Write a file whose size exceeds maxSourceFileBytes WITHOUT building the whole
        // payload in memory: truncate to (cap + 1 KB) on disk, then write valid JSONL at
        // the front so the bytes are real but parsing is never reached (we skip first).
        let big = srcDir.appendingPathComponent("huge.jsonl")
        let fileMtime: TimeInterval = 1_748_000_000
        let oversize = Int64(SyncEngine.maxSourceFileBytes) + 1024
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        // A valid exchange at the head — proves we skip BEFORE parsing (it would parse fine).
        let head = makeExchange(sessionID: "huge-skip", userText: "should not be ingested", assistantText: "x")
        try handle.write(contentsOf: Data(head.utf8))
        // Grow the file to the target size cheaply via truncation.
        try handle.truncate(atOffset: UInt64(oversize))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: fileMtime)],
            ofItemAtPath: big.path
        )

        let index  = try SearchIndex(dbURL: dbURL)
        let store  = RecordStore(rootDir: storeDir, index: index)
        let engine = SyncEngine(
            adapters: [FakeAdapter(sourceRoot: srcDir)],
            store: store, statePath: statePath
        )

        // Must not throw, must not crash, and must ingest nothing.
        let result = try await engine.syncOnce(now: Date(timeIntervalSince1970: fileMtime + 100))
        #expect(result.added == 0, "oversized file must not be counted as added")
        #expect(result.updated == 0)

        let all = try await store.all()
        #expect(all.isEmpty, "oversized file must not produce a record")
        #expect(try index.count() == 0, "oversized file must not be indexed")

        // The source file is left untouched.
        #expect(FileManager.default.fileExists(atPath: big.path), "source must not be deleted")

        // State records the (size, mtime) so we don't re-read it every pass, but because
        // state is keyed on size, a later shrink below the cap naturally re-triggers it.
        let keys = try persistedStateKeys(at: statePath)
        #expect(keys.contains(big.standardizedFileURL.path),
                "oversized file should be tracked so it isn't re-read each pass")

        // Second pass: still skipped, still (0,0).
        let result2 = try await engine.syncOnce(now: Date(timeIntervalSince1970: fileMtime + 200))
        #expect(result2.added == 0)
        #expect(result2.updated == 0)
    }

    @Test("size cap: a file shrinking below the cap is re-evaluated and ingested")
    func sizeCapReTriggersWhenFileShrinks() async throws {
        let srcDir    = try makeTempDir()
        let storeDir  = try makeTempDir()
        let dbURL     = makeTempDBURL()
        let stateDir  = try makeTempDir()
        let statePath = stateDir.appendingPathComponent("state.json")
        defer {
            removeTempDir(srcDir); removeTempDir(storeDir)
            removeTempDir(stateDir)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let f = srcDir.appendingPathComponent("grew-then-shrank.jsonl")
        let baseMtime: TimeInterval = 1_748_000_000

        // Start oversized → skipped.
        let exchange = makeExchange(sessionID: "shrink-cap", userText: "now small enough", assistantText: "ok")
        FileManager.default.createFile(atPath: f.path, contents: nil)
        let handle = try FileHandle(forWritingTo: f)
        try handle.write(contentsOf: Data(exchange.utf8))
        try handle.truncate(atOffset: UInt64(Int64(SyncEngine.maxSourceFileBytes) + 1024))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: baseMtime)],
            ofItemAtPath: f.path
        )

        let index  = try SearchIndex(dbURL: dbURL)
        let store  = RecordStore(rootDir: storeDir, index: index)
        let engine = SyncEngine(
            adapters: [FakeAdapter(sourceRoot: srcDir)],
            store: store, statePath: statePath
        )

        let r1 = try await engine.syncOnce(now: Date(timeIntervalSince1970: baseMtime + 100))
        #expect(r1.added == 0, "oversized file skipped on first pass")

        // Rewrite the file under the cap with a new mtime → must now be ingested.
        try write(exchange, to: f, mtime: baseMtime + 50)
        let r2 = try await engine.syncOnce(now: Date(timeIntervalSince1970: baseMtime + 200))
        // The path was already tracked (the oversized first pass recorded its state), so
        // re-ingesting it after the shrink counts as `updated`, not `added`. The key point
        // is that it IS re-evaluated and ingested rather than staying hidden forever.
        #expect(r2.added == 0)
        #expect(r2.updated == 1, "file that shrank below the cap must be re-evaluated and ingested")

        let all = try await store.all()
        #expect(all.count == 1)
        #expect(try index.search("small").count == 1)
    }

    @Test("FIX5: default enabledTools (all) ingests every adapter")
    func syncDefaultEnabledToolsIngestsAll() async throws {
        let ccDir     = try makeTempDir()
        let codexDir  = try makeTempDir()
        let storeDir  = try makeTempDir()
        let dbURL     = makeTempDBURL()
        let stateDir  = try makeTempDir()
        let statePath = stateDir.appendingPathComponent("state.json")
        defer {
            removeTempDir(ccDir); removeTempDir(codexDir); removeTempDir(storeDir)
            removeTempDir(stateDir)
            try? FileManager.default.removeItem(at: dbURL)
        }

        let fileMtime: TimeInterval = 1_748_000_000
        let ccFile = ccDir.appendingPathComponent("cc.jsonl")
        try write(
            makeExchange(sessionID: "cc-2", userText: "default all cc", assistantText: "ok"),
            to: ccFile, mtime: fileMtime
        )
        let codexFile = codexDir.appendingPathComponent("codex.jsonl")
        try write(
            makeExchange(sessionID: "codex-2", userText: "default all codex", assistantText: "ok"),
            to: codexFile, mtime: fileMtime
        )

        let index  = try SearchIndex(dbURL: dbURL)
        let store  = RecordStore(rootDir: storeDir, index: index)
        let engine = SyncEngine(
            adapters: [
                ToolFakeAdapter(tool: .claudeCode, sourceRoot: ccDir),
                ToolFakeAdapter(tool: .codex,      sourceRoot: codexDir)
            ],
            store: store, statePath: statePath
        )

        // No enabledTools argument → defaults to all tools.
        let result = try await engine.syncOnce(now: Date(timeIntervalSince1970: fileMtime + 100))
        #expect(result.added == 2, "default (all tools) must ingest both adapters")
    }
}
