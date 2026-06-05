import Foundation
import Testing
@testable import RaccoonCore

/// Tests for `BackupExclusion`, which marks Raccoon's local data dirs as excluded
/// from Time Machine / iCloud backup so the plaintext session corpus (which may
/// contain pasted secrets) is not silently copied off-device.
@Suite(.serialized)
struct BackupExclusionTests {

    // MARK: Fixtures

    /// A unique, already-created temp directory per call, cleaned up by the OS temp dir.
    private func uniqueTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupExclusionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Reads back the `.isExcludedFromBackupKey` resource value for `url`.
    private func isExcluded(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        return values.isExcludedFromBackup ?? false
    }

    // MARK: Tests

    @Test("exclude sets isExcludedFromBackup on an existing dir")
    func excludeSetsFlag() throws {
        let dir = try uniqueTempDir()
        #expect(try isExcluded(dir) == false)

        let ok = BackupExclusion.exclude(dir)
        #expect(ok == true)
        #expect(try isExcluded(dir) == true)
    }

    @Test("exclude is idempotent — re-running keeps the flag set and still succeeds")
    func excludeIsIdempotent() throws {
        let dir = try uniqueTempDir()

        #expect(BackupExclusion.exclude(dir) == true)
        #expect(BackupExclusion.exclude(dir) == true)
        #expect(BackupExclusion.exclude(dir) == true)
        #expect(try isExcluded(dir) == true)
    }

    @Test("exclude is failure-tolerant on a missing path — returns false, never throws")
    func excludeMissingPathIsTolerant() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupExclusionTests-missing-\(UUID().uuidString)", isDirectory: true)
        // Must not throw; just reports failure.
        #expect(BackupExclusion.exclude(missing) == false)
    }

    @Test("array overload excludes every distinct dir, de-duping overlaps")
    func excludeArrayCoversAllDirs() throws {
        let parent = try uniqueTempDir()
        let child = parent.appendingPathComponent("records", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        // Pass the parent twice (once standardized) to exercise de-dup, plus the child.
        BackupExclusion.exclude([parent, parent.standardizedFileURL, child])

        #expect(try isExcluded(parent) == true)
        #expect(try isExcluded(child) == true)
    }
}
