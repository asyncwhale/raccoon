import Foundation
import Testing
@testable import RaccoonCore

/// Tests for the user-initiated `RecordStore.trash(_:)` action: it must MOVE the
/// `.md` into `_trash/` (not permanently delete it), drop it from `all()` and the
/// search index, and leave the physical file recoverable under `_trash/`.
@Suite(.serialized)
struct TrashRecordTests {

    // MARK: Fixtures

    /// Unique, already-created temp dir per call so each test is isolated and never
    /// touches real data. The directory must exist before `SearchIndex` opens its
    /// sqlite file underneath it.
    private func uniqueTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrashRecordTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A `Record` with a stable, searchable body.
    private func makeRecord(session: String) -> Record {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return Record(
            tool: .claudeCode,
            sessionID: session,
            project: "/tmp/proj",
            startedAt: now,
            lastActiveAt: now,
            starred: false,
            messages: [Message(speaker: .user, text: "uniquetoken hello world", timestamp: now)]
        )
    }

    /// A store bound to an on-disk `SearchIndex` under `root`.
    private func makeIndexedStore(root: URL) throws -> (RecordStore, SearchIndex) {
        let index = try SearchIndex(dbURL: root.appendingPathComponent("index.sqlite"))
        let store = RecordStore(rootDir: root, index: index)
        return (store, index)
    }

    // MARK: Tests

    @Test("trash moves the record into _trash and removes it from store + index, keeping the file recoverable")
    func trashMovesToTrashAndDeindexes() async throws {
        let root = try uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, index) = try makeIndexedStore(root: root)
        let record = makeRecord(session: "to-be-trashed")

        // Save → file on disk, listed by all(), indexed.
        let savedURL = try await store.save(record)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: savedURL.path))

        let allBefore = try await store.all()
        #expect(allBefore.contains { $0.sessionID == "to-be-trashed" })

        let indexCountBefore = try index.count()
        #expect(indexCountBefore == 1)
        #expect(!(try index.search("uniquetoken")).isEmpty)

        // Trash it.
        let dest = try await store.trash(savedURL)

        // The original live file is gone from rootDir...
        #expect(!fm.fileExists(atPath: savedURL.path))

        // ...but the file physically survives under _trash/ (NOT permanently deleted).
        let trashDir = root.appendingPathComponent("_trash", isDirectory: true)
        #expect(dest.deletingLastPathComponent().standardizedFileURL.path
            == trashDir.standardizedFileURL.path)
        #expect(fm.fileExists(atPath: dest.path))

        // No longer surfaced by all() (which skips _trash/).
        let allAfter = try await store.all()
        #expect(!allAfter.contains { $0.sessionID == "to-be-trashed" })

        // Removed from the search index in lock-step.
        #expect(try index.count() == indexCountBefore - 1)
        #expect((try index.search("uniquetoken")).isEmpty)
    }

    @Test("trash on a missing path throws and does not affect the index")
    func trashMissingPathThrows() async throws {
        let root = try uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, index) = try makeIndexedStore(root: root)
        _ = try await store.save(makeRecord(session: "survivor"))
        let countBefore = try index.count()

        let ghost = root.appendingPathComponent("does-not-exist.md")
        await #expect(throws: (any Error).self) {
            try await store.trash(ghost)
        }

        // The unrelated record's index entry is untouched.
        #expect(try index.count() == countBefore)
    }

    /// trash → untrash round-trips (the UNDO path): the `.md` returns to rootDir,
    /// is back in `all()` and the SearchIndex, and is gone from `_trash/`.
    @Test("trash then untrash round-trips: file back in rootDir + index, gone from _trash")
    func trashThenUntrashRoundTrips() async throws {
        let root = try uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, index) = try makeIndexedStore(root: root)
        let fm = FileManager.default

        // Save → file in rootDir, present in all() and the index.
        let saved = try await store.save(makeRecord(session: "round-trip"))
        #expect(fm.fileExists(atPath: saved.path))
        #expect(try await store.all().count == 1)
        #expect(try index.count() == 1)
        #expect(!(try index.search("uniquetoken")).isEmpty)

        // Trash → file moves to _trash, gone from rootDir / all() / index.
        let trashed = try await store.trash(saved)
        #expect(trashed.path.contains("_trash"))
        #expect(fm.fileExists(atPath: trashed.path))
        #expect(!fm.fileExists(atPath: saved.path))
        #expect(try await store.all().count == 0)
        #expect(try index.count() == 0)

        // Untrash → file returns to rootDir, back in all() + index, gone from _trash.
        let restored = try await store.untrash(trashed)
        #expect(!restored.path.contains("_trash"))
        #expect(restored.deletingLastPathComponent().standardizedFileURL
            == root.standardizedFileURL)
        #expect(fm.fileExists(atPath: restored.path))
        #expect(!fm.fileExists(atPath: trashed.path))
        #expect(try await store.all().count == 1)
        #expect(try index.count() == 1)
        // Searchable again — re-indexed in lock-step with the restore.
        #expect(!(try index.search("uniquetoken")).isEmpty)
    }

    /// DATA-LOSS P0 support: user-initiated `trash(_:)` must stamp the trashed
    /// file's mtime to ~now (its arrival time), even when the source .md had a
    /// stale mtime. This is what makes the 7-day grace window real.
    @Test("trash stamps arrival mtime to now even when the source file mtime is stale")
    func trashStampsArrivalMtime() async throws {
        let root = try uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _) = try makeIndexedStore(root: root)
        let fm = FileManager.default

        let saved = try await store.save(makeRecord(session: "stale-mtime"))

        // Force the live file's mtime far into the past, as an old inactive
        // session's .md would have. moveItem would preserve this absent the fix.
        let staleDate = Date(timeIntervalSince1970: 1_500_000_000) // ~2017
        try fm.setAttributes([.modificationDate: staleDate], ofItemAtPath: saved.path)

        let before = Date()
        let trashed = try await store.trash(saved)
        let after = Date()

        let attrs = try fm.attributesOfItem(atPath: trashed.path)
        let mtime = try #require(attrs[.modificationDate] as? Date)

        // Arrival mtime must be ~now, NOT the stale 2017 source mtime.
        #expect(mtime >= before.addingTimeInterval(-1))
        #expect(mtime <= after.addingTimeInterval(1))
        #expect(mtime.timeIntervalSince(staleDate) > 86_400, "mtime must not be the preserved stale source time")
    }

    /// Confirms the Undo path (untrash) is unaffected by the mtime stamping: it
    /// restores by parsing file content, never reading mtime — so a trashed file
    /// with any mtime round-trips back into rootDir.
    @Test("untrash restores regardless of the trashed file's mtime (Undo path unaffected)")
    func untrashIgnoresMtime() async throws {
        let root = try uniqueTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, index) = try makeIndexedStore(root: root)
        let fm = FileManager.default

        let saved = try await store.save(makeRecord(session: "undo-mtime"))
        let trashed = try await store.trash(saved)

        // Mangle the trashed file's mtime to an extreme value; untrash must not care.
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: trashed.path)

        let restored = try await store.untrash(trashed)
        #expect(!restored.path.contains("_trash"))
        #expect(fm.fileExists(atPath: restored.path))
        #expect(!fm.fileExists(atPath: trashed.path))
        #expect(try await store.all().count == 1)
        #expect(try index.count() == 1)
        #expect(!(try index.search("uniquetoken")).isEmpty)
    }
}
