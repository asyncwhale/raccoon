import Foundation
import os

// MARK: - SyncEngine

/// An actor that incrementally ingests session files from all registered adapters into the
/// ``RecordStore`` (which in turn keeps its injected ``SearchIndex`` in sync).
///
/// ## Algorithm (v1 — whole-file re-parse on change)
/// For each adapter source file:
/// - **Unchanged** (`size` + `mtime` match persisted state): skip — no disk I/O, no parse.
/// - **New or changed**: read the whole file, parse via the adapter, save to `RecordStore`.
///   The store writes the `.md` and updates its `SearchIndex` atomically; its filename is
///   deterministic so saves are upserts. The engine no longer touches the index directly.
/// - **Debounce**: files modified within `debounceInterval` seconds of `now` are skipped
///   (the tool may still be writing to them).
///
/// State is persisted as JSON at `statePath` after every successful pass. Dead state keys
/// (source files that no longer exist) are pruned each pass so the map cannot grow unbounded;
/// the archived `.md` outlives its source log (see `DECISIONS.md` #11).
///
/// See `DECISIONS.md` #10 for the rationale behind whole-file re-parse vs. byte-offset reads.
public actor SyncEngine {

    // MARK: Limits

    /// Maximum source-file size (bytes) that will be read into memory and parsed.
    /// Files larger than this are skipped (not loaded) to avoid unbounded memory use
    /// from a pathological/corrupt session log. 50 MB is far above any realistic
    /// terminal-AI session transcript, so a normal file never trips this cap.
    public static let maxSourceFileBytes = 50 * 1024 * 1024

    /// Pure size-decision helper: returns `true` if a source file of `fileSize` bytes
    /// is too large to ingest and should be skipped. Factored out so the size policy
    /// is unit-testable without wiring a real multi-megabyte fixture.
    public static func shouldSkipBySize(_ fileSize: Int, limit: Int = maxSourceFileBytes) -> Bool {
        fileSize > limit
    }

    /// Logger for sync-engine operations (oversized-file skips, etc.).
    private static let log = Logger(subsystem: "com.raccoon.core", category: "SyncEngine")

    // MARK: Dependencies

    private let adapters: [any SessionAdapter]
    private let store: RecordStore
    private let statePath: URL
    private let fileManager: FileManager

    // MARK: In-memory state

    /// Source file path → last-seen `FileSyncState`. Loaded from `statePath` on first sync.
    private var state: [String: FileSyncState] = [:]
    private var stateLoaded = false

    // MARK: Init

    /// Creates a `SyncEngine` that ties together adapters and the store.
    ///
    /// - Parameters:
    ///   - adapters: One adapter per AI tool to scan. Pass all adapters whose source roots
    ///     should be ingested on each `syncOnce()` call.
    ///   - store: The ``RecordStore`` actor that persists parsed records as `.md` files AND
    ///     keeps its injected ``SearchIndex`` in sync. Construct it WITH the index
    ///     (`RecordStore(rootDir:index:)`) so search stays consistent — the engine no longer
    ///     indexes records itself.
    ///   - statePath: A JSON file URL where sync state (`[path: FileSyncState]`) is persisted
    ///     between process launches. The parent directory must exist or be creatable.
    ///   - fileManager: Injected `FileManager`; defaults to `.default` for production use.
    public init(
        adapters: [any SessionAdapter],
        store: RecordStore,
        statePath: URL,
        fileManager: FileManager = .default
    ) {
        self.adapters = adapters
        self.store = store
        self.statePath = statePath
        self.fileManager = fileManager
    }

    // MARK: Public API

    /// Performs one incremental sync pass over all adapter source roots.
    ///
    /// - Parameters:
    ///   - now: The reference time used for debounce comparison. Defaults to `Date()`.
    ///     Pass a controlled value in tests.
    ///   - debounceInterval: Source files whose `mtime > now - debounceInterval` are skipped
    ///     this pass to avoid reading files that are still being written. Default: 0.5 s.
    ///   - enabledTools: Only adapters whose `.tool` is in this set are scanned. Defaults to
    ///     all `Tool` cases (every adapter runs). Pass `Settings.enabledTools` to honor the
    ///     user's per-tool ingest preference.
    /// - Returns: `(added, updated)` counts of newly-ingested and re-parsed records.
    /// - Throws: Any error from state persistence (I/O errors reading/writing `statePath`).
    ///   Parse failures and unreadable source files are handled gracefully — they update
    ///   state and are counted, but do not propagate as thrown errors.
    @discardableResult
    public func syncOnce(
        now: Date = Date(),
        debounceInterval: TimeInterval = 0.5,
        enabledTools: Set<Tool> = Set(Tool.allCases)
    ) async throws -> (added: Int, updated: Int) {
        try loadStateIfNeeded()

        var added = 0
        var updated = 0

        for adapter in adapters {
            // FIX 5: honor enabledTools — skip adapters the user has disabled.
            guard enabledTools.contains(adapter.tool) else { continue }
            for root in adapter.sourceRoots {
                let files = adapter.sessionFiles(in: root, fileManager: fileManager)
                for fileURL in files {
                    let key = fileURL.standardizedFileURL.path

                    // Stat the source file.
                    guard let attrs = try? fileManager.attributesOfItem(atPath: fileURL.path),
                          let fileSize = attrs[.size] as? Int,
                          let modDate = attrs[.modificationDate] as? Date
                    else {
                        // Unreadable stat — skip without updating state.
                        continue
                    }

                    let mtime = modDate.timeIntervalSince1970

                    // Debounce: skip files modified too recently (tool may still be writing).
                    if now.timeIntervalSince1970 - mtime < debounceInterval {
                        continue
                    }

                    // Skip if file is identical to last-seen state.
                    if let existing = state[key],
                       existing.size == fileSize,
                       existing.mtimeEpoch == mtime {
                        continue
                    }

                    let wasKnown = state[key] != nil

                    // Size cap: never load a pathologically large source file into memory.
                    // We record (size, mtime) so we don't re-stat-and-skip-read on every pass,
                    // but because state is keyed on (size, mtime) the file is naturally
                    // re-evaluated if it later shrinks below the cap (size change → re-trigger).
                    // The source file is left untouched; no record is created/counted.
                    if Self.shouldSkipBySize(fileSize) {
                        Self.log.notice(
                            "Skipping oversized session file (\(fileSize, privacy: .public) bytes > \(Self.maxSourceFileBytes, privacy: .public) byte cap): not loaded into memory"
                        )
                        state[key] = FileSyncState(size: fileSize, mtimeEpoch: mtime)
                        continue
                    }

                    // Read whole file (UTF-8).
                    guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                        // Unreadable content — update state so we don't retry on every pass.
                        state[key] = FileSyncState(size: fileSize, mtimeEpoch: mtime)
                        continue
                    }

                    // Parse — gracefully handle empty/no-message sessions.
                    let record: Record
                    do {
                        record = try adapter.parse(contents: contents, fileURL: fileURL)
                    } catch AdapterError.emptySession, AdapterError.noMessages {
                        // Update state so we don't retry on every pass, but don't create a record.
                        state[key] = FileSyncState(size: fileSize, mtimeEpoch: mtime)
                        continue
                    } catch {
                        // Unexpected parse error — skip without updating state so next pass retries.
                        continue
                    }

                    // Persist to RecordStore (deterministic filename → upsert). The store
                    // also upserts the record into its SearchIndex; if indexing fails it
                    // rethrows AFTER the .md is written, so we skip updating state here and
                    // retry on the next pass (closing the saved-but-unindexed gap).
                    do {
                        _ = try await store.save(record)
                    } catch {
                        // Store write OR index failure — skip without updating state so the
                        // next pass retries.
                        continue
                    }

                    // Update state.
                    state[key] = FileSyncState(size: fileSize, mtimeEpoch: mtime)

                    if wasKnown {
                        updated += 1
                    } else {
                        added += 1
                    }
                }
            }
        }

        // FIX 4: prune dead state. Raccoon archives OUTLIVE their source logs
        // (sessions that 会丢 — see DECISIONS.md #11), so we DO NOT delete the
        // archived .md when its source .jsonl disappears. But we must drop the
        // now-dead entry from `state` so the map can't grow unbounded across the
        // lifetime of the app. A key is dead iff its source path no longer exists
        // on disk (checked directly, independent of which adapters ran this pass).
        let deadKeys = state.keys.filter { !fileManager.fileExists(atPath: $0) }
        for key in deadKeys {
            state.removeValue(forKey: key)
        }

        // Persist state atomically.
        try persistState()

        return (added: added, updated: updated)
    }

    // MARK: State I/O

    private func loadStateIfNeeded() throws {
        guard !stateLoaded else { return }
        stateLoaded = true

        guard fileManager.fileExists(atPath: statePath.path) else {
            // Missing state file is normal on first run — start empty.
            state = [:]
            return
        }

        let data = try Data(contentsOf: statePath)
        state = (try? JSONDecoder().decode([String: FileSyncState].self, from: data)) ?? [:]
    }

    private func persistState() throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: statePath, options: .atomic)
    }
}
