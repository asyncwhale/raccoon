import Foundation
import Observation
import AppKit
import KeyboardShortcuts
import RaccoonCore

/// The app-wide model. Owns the Core stack (`SearchIndex` + `RecordStore` + `SyncEngine`)
/// and exposes UI-facing state. All UI reads main-actor-isolated state here; Core actors
/// are reached with `await` inside structured `Task`s.
@MainActor
@Observable
final class AppModel {

    // MARK: UI-facing state

    /// User configuration. Loaded from `~/Library/Application Support/Raccoon/settings.json`
    /// on launch (falling back to `Settings.default` when absent/corrupt) and re-saved on
    /// every change via `saveSettings()` (called by `SettingsView`).
    var settings: Settings

    /// The editor stack: open tabs + active selection + reopen-restore (Phase 2B).
    let editor = EditorModel()

    /// Lightweight summaries of all archived records, sorted most-recently-active first.
    /// The sidebar reads this; full message bodies are NOT retained in RAM here.
    /// Open a full record with `openRecord(path:)` which calls `store.load(_:)` on demand.
    var records: [RecordSummary] = []

    /// `true` while a sync pass is in flight (drives the toolbar spinner).
    var isSyncing = false

    /// Whether the main window is pinned to float above other apps' full-screen spaces.
    /// The toolbar pin toggle binds to this; the actual `NSWindow` mutation happens in
    /// `ContentView` via `WindowAccessor`/`PinController`.
    var isPinned = false

    /// Re-asserts pinning on Space/activation changes for the resolved main window. Retained
    /// here (lifecycle-safe) so there's exactly one registration; set up once via
    /// `attachPinReasserter(to:)` when `ContentView` resolves the window.
    @ObservationIgnored private var pinReasserter: PinReasserter?

    /// Install the Space-change/activation re-assert observer for `window` (once), or, if
    /// already installed, retarget it at a freshly-resolved `NSWindow` (SwiftUI's
    /// `WindowGroup` can recreate the underlying window). The reasserter reads `isPinned`
    /// lazily and holds a weak window ref, so there's no retain cycle and no leaked
    /// observers on retarget.
    func attachPinReasserter(to window: NSWindow) {
        if let pinReasserter {
            pinReasserter.updateWindow(window)
            return
        }
        pinReasserter = PinReasserter(window: window) { [weak self] in
            self?.isPinned ?? false
        }
    }

    /// Human-readable summary of the last sync, e.g. `"added 3, updated 1"`.
    var lastSyncSummary: String = ""

    /// Non-nil when the Core stack failed to initialize (e.g. the search DB couldn't open).
    /// The UI can surface this instead of crashing.
    var initError: String?

    // MARK: Core stack

    /// Application Support root: `~/Library/Application Support/Raccoon`.
    private let appSupport: URL

    /// Search index. `nil` only if Core init failed.
    private let index: SearchIndex?
    /// Record archive actor. `nil` only if Core init failed.
    /// Exposed (module-internal) so the record toolbar can toggle `starred` on the actor
    /// before `AppModel` reloads `records`.
    private(set) var store: RecordStore?
    /// Incremental sync engine. `nil` only if Core init failed.
    private let sync: SyncEngine?

    /// Handle to the periodic background-sync loop so it can be cancelled.
    private var backgroundSyncTask: Task<Void, Never>?

    /// Handle to the daily retention-cleanup loop so it can be cancelled. Independent of
    /// the sync loop (§3, §9.7).
    private var retentionCleanupTask: Task<Void, Never>?

    /// Interval between automatic background syncs.
    private static let backgroundSyncInterval: Duration = .seconds(240)

    /// Interval between automatic retention-cleanup passes (§9.7). A plain 24h cadence is
    /// sufficient — cleanup is idempotent and date-driven, so exact wall-clock midnight
    /// alignment isn't required.
    private static let retentionCleanupInterval: Duration = .seconds(24 * 60 * 60)

    // MARK: Init

    init() {
        // Compute Application Support dir and ensure the directory tree exists.
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let appSupport = base.appendingPathComponent("Raccoon", isDirectory: true)
        self.appSupport = appSupport

        // Load persisted settings (records/notes dirs included). Falls back to
        // Settings.default on a missing/corrupt file. Both point records/notes under
        // ~/Library/Application Support/Raccoon by default.
        let settings = SettingsStore.load()
        self.settings = settings

        // Create the directory tree up front so the index DB and record/notes dirs exist.
        do {
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            try fm.createDirectory(at: settings.recordsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: settings.notesDir, withIntermediateDirectories: true)
        } catch {
            // Non-fatal: the index init below will surface the real problem if dirs are bad.
        }

        // Privacy (P2): the archive (.md transcripts) + SearchIndex SQLite hold full
        // session bodies that may contain secrets the user pasted. Mark Raccoon's data
        // dirs as excluded from Time Machine / iCloud backup so the plaintext corpus is
        // not silently copied off-device. `isExcludedFromBackup` is per-URL and inherited
        // only by physical children, so we mark the top-level `appSupport` dir (which by
        // default holds records/, notes/, index.sqlite, sync-state.json) AND the configured
        // records/notes dirs in case the user relocated them outside appSupport. This only
        // sets a flag — it does NOT change where data is stored. Best-effort + idempotent:
        // BackupExclusion never throws and is safe to run on every launch.
        BackupExclusion.exclude([appSupport, settings.recordsDir, settings.notesDir])

        // Construct the Core stack. SearchIndex can throw; if it does, run in a degraded
        // state (no store/sync) and surface an error rather than crashing.
        do {
            let index = try SearchIndex(dbURL: appSupport.appendingPathComponent("index.sqlite"))
            let store = RecordStore(rootDir: settings.recordsDir, index: index)
            let sync = SyncEngine(
                adapters: [ClaudeCodeAdapter(), CodexAdapter()],
                store: store,
                statePath: appSupport.appendingPathComponent("sync-state.json")
            )
            self.index = index
            self.store = store
            self.sync = sync
            self.initError = nil
        } catch {
            self.index = nil
            self.store = nil
            self.sync = nil
            self.initError = String(localized: "model.error.indexOpen \(error.localizedDescription)")
        }
    }

    // MARK: Lifecycle

    /// Guards `start()` from re-running when the window is re-opened via the menu.
    private var hasStarted = false

    /// Called once when the main window appears. Restores the editor tabs (§9.11), registers
    /// the global summon shortcut, runs an initial sync, loads records, and starts the
    /// periodic background-sync + daily retention-cleanup loops.
    ///
    /// Idempotent: subsequent calls (e.g. window re-opened via "唤出窗口") are no-ops,
    /// so `KeyboardShortcuts.onKeyUp` is registered exactly once and `restoreOrSeed()`
    /// never reverts unsaved scratch text.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        // Apply the persisted menu-bar-mode activation policy at launch (before the
        // window settles) so a user who enabled menu-bar mode last session comes up
        // as a Dock-less accessory app.
        applyActivationPolicy()
        editor.restoreOrSeed()
        registerSummonShortcut()
        syncNow()
        startBackgroundSync()
        startRetentionCleanup()
    }

    /// Persist the current `settings` to JSON. Called by `SettingsView` after any change.
    func saveSettings() {
        SettingsStore.save(settings)
    }

    // MARK: Activation policy (menu-bar mode)

    /// Apply the macOS activation policy implied by `settings.menuBarMode`:
    ///
    /// - `menuBarMode == true`  → `.accessory`: no Dock icon, no app menu; the app
    ///   lives in the menu bar (via `MenuBarExtra`) and is summoned from the
    ///   status-item menu or the global hotkey. A `.accessory` window can float
    ///   reliably above other apps' native full-screen spaces.
    /// - `menuBarMode == false` → `.regular`: normal app with a Dock icon.
    ///
    /// Safe to call repeatedly. Called once on launch (reads the persisted value)
    /// and again whenever the Settings toggle flips. `setActivationPolicy` switches
    /// live in BOTH directions; when returning to `.regular` we additionally
    /// `activate(ignoringOtherApps:)` so the Dock icon + app menu come back to the
    /// foreground immediately instead of on the next user click.
    func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = settings.menuBarMode ? .accessory : .regular
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            // Restore foreground presence (Dock icon / menu bar) right away. Then
            // bring the main window forward so the app doesn't end up policy-regular
            // but visually backgrounded.
            NSApp.activate(ignoringOtherApps: true)
            summonWindow()
        }
    }

    /// Triggers an immediate sync pass, then reloads `records`. No-op if a sync is already
    /// running or the Core stack failed to init.
    func syncNow() {
        guard !isSyncing else { return }
        guard let sync, let store else { return }
        isSyncing = true
        let enabledTools = settings.enabledTools
        Task {
            defer { isSyncing = false }
            do {
                let result = try await sync.syncOnce(enabledTools: enabledTools)
                let all = try await store.allSummaries()
                self.records = all
                self.lastSyncSummary = "added \(result.added), updated \(result.updated)"
            } catch {
                self.lastSyncSummary = String(localized: "model.error.syncFailed \(error.localizedDescription)")
            }
        }
    }

    /// Reloads `records` from the store without running a sync.
    func reloadRecords() {
        guard let store else { return }
        Task {
            if let all = try? await store.allSummaries() {
                self.records = all
            }
        }
    }

    /// Full-text search over the index. Synchronous wrapper; returns `[]` on any error
    /// (or when the Core stack failed to init).
    func search(_ query: String) -> [SearchHit] {
        guard let index else { return [] }
        return (try? index.search(query)) ?? []
    }

    // MARK: Records (§9.5)

    /// Open the archived record at `path` as a READ-ONLY editor tab (§9.5).
    ///
    /// Loads + decodes the `.md` on the store actor, then hands the decoded `Record` to the
    /// editor on the main actor. `addRecordTab` de-dupes by path (re-focuses an open tab).
    /// Silently no-ops if the Core stack failed to init or the file can't be decoded.
    func openRecord(path: URL) {
        guard let store else { return }
        Task {
            do {
                let rec = try await store.load(path)
                editor.addRecordTab(record: rec, path: path)
            } catch {
                lastSyncSummary = String(localized: "model.error.openRecord \(error.localizedDescription)")
            }
        }
    }

    /// Toggle `starred` on the archived record at `path`, then reload `records` so the
    /// sidebar reflects the change. Returns the new value via the optional callback so the
    /// caller (the record toolbar) can update its tab's `record.starred` immediately.
    func setStarred(path: URL, _ starred: Bool) {
        guard let store else { return }
        Task {
            do {
                try await store.setStarred(path, starred)
                self.records = try await store.allSummaries()
            } catch {
                lastSyncSummary = String(localized: "model.error.starFailed \(error.localizedDescription)")
            }
        }
    }

    /// Move the archived record at `path` to `_trash/` (user-initiated DELETE).
    ///
    /// Calls `store.trash(_:)` on the store actor (which moves the `.md` into
    /// `<recordsDir>/_trash/` and drops it from the search index), then refreshes
    /// `records` so the sidebar row disappears. If the trashed record is currently
    /// open in a read-only editor tab, that tab is closed so the user isn't left
    /// viewing a record that no longer lives in the archive.
    ///
    /// The file is recoverable from `_trash/` for the trash grace period (7 days)
    /// until `runCleanup` purges it — this is a move, not a permanent delete.
    func trashRecord(path: URL) {
        guard let store else { return }
        let std = path.standardizedFileURL
        // Close an open tab pointing at this record (if any) before the file moves.
        if let tab = editor.tabs.first(where: { $0.recordPath?.standardizedFileURL == std }) {
            editor.closeTab(tab)
        }
        Task {
            do {
                // Remember the trash destination so the UI's "Undo" affordance can
                // restore it (single-level: only the most recent trash is kept).
                let dest = try await store.trash(std)
                self.lastTrashed = dest
                self.records = try await store.allSummaries()
            } catch {
                self.lastSyncSummary = String(localized: "model.error.trashFailed \(error.localizedDescription)")
            }
        }
    }

    /// The destination (inside `_trash/`) of the most recently trashed record,
    /// retained so `undoLastTrash()` can restore it. Single-level undo: only the
    /// latest trash is remembered; a subsequent trash overwrites it.
    private var lastTrashed: URL?

    /// Restore the most recently trashed record from `_trash/` back into the
    /// archive (the inverse of `trashRecord(path:)`), then refresh `records` so
    /// the restored row reappears in the sidebar. No-op when there is nothing to
    /// undo or the Core stack failed to init. The remembered value is cleared once
    /// consumed so the same trash can't be "undone" twice.
    func undoLastTrash() {
        guard let store, let trashed = lastTrashed else { return }
        lastTrashed = nil
        Task {
            do {
                try await store.untrash(trashed)
                self.records = try await store.allSummaries()
            } catch {
                self.lastSyncSummary = String(localized: "model.error.untrashFailed \(error.localizedDescription)")
            }
        }
    }

    // MARK: Retention cleanup (§3, §9.7)

    /// Run one retention pass: trash expired-unstarred records past `retentionDays` and
    /// purge stale trash. The record(s) the user is currently viewing (open record tabs)
    /// are passed as `protectedPaths` so an actively-open archive is never recycled.
    ///
    /// No-op when the Core stack failed to init. The Core logic + tests already exist; this
    /// just invokes them on the store actor.
    func runCleanupNow() {
        guard let store else { return }
        let retentionDays = settings.retentionDays
        let protectedPaths = openRecordPaths()
        Task {
            do {
                let result = try await store.runCleanup(
                    retentionDays: retentionDays,
                    now: Date(),
                    protectedPaths: protectedPaths
                )
                // If anything was recycled, the sidebar's `records` is now stale — refresh it.
                if !result.trashed.isEmpty || !result.purged.isEmpty {
                    self.records = try await store.allSummaries()
                }
            } catch {
                self.lastSyncSummary = String(localized: "model.error.cleanupFailed \(error.localizedDescription)")
            }
        }
    }

    /// Paths of currently-open archived-record tabs, to be protected from cleanup so a
    /// record the user is reading right now isn't trashed out from under them.
    private func openRecordPaths() -> Set<URL> {
        Set(editor.tabs.compactMap { $0.recordPath })
    }

    /// Starts (or restarts) the cancellable daily retention-cleanup loop. Runs an immediate
    /// pass, then once every ~24h. Independent of the sync timer.
    private func startRetentionCleanup() {
        retentionCleanupTask?.cancel()
        retentionCleanupTask = Task { [weak self] in
            // Initial pass on launch.
            self?.runCleanupNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.retentionCleanupInterval)
                if Task.isCancelled { return }
                guard let self else { return }
                self.runCleanupNow()
            }
        }
    }

    // MARK: Global summon shortcut

    /// Register the global "唤出 Raccoon" hotkey handler. The user assigns the actual key
    /// combo in Settings (no default ships); until then the handler is dormant.
    private func registerSummonShortcut() {
        // Ship a sensible default global summon combo (⌃⌘R) the first time, without ever
        // overwriting a combo the user has already chosen.
        KeyboardShortcuts.Name.installDefaultsIfNeeded()
        KeyboardShortcuts.onKeyUp(for: .summonRaccoon) { [weak self] in
            // The Carbon hotkey callback is delivered on the main thread; hop onto the
            // main actor explicitly so the call is safe under strict concurrency.
            MainActor.assumeIsolated {
                self?.summonWindow()
            }
        }
    }

    /// Bring Raccoon to the front: activate the app and raise its main window. The
    /// MenuBarExtra "唤出窗口" item drives the same path (it additionally re-creates the
    /// window via `openWindow` if it was fully closed, which only the App layer can do).
    func summonWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Find the primary content window (not the MenuBarExtra's status-item window) and
        // bring it forward. Status-bar windows aren't `titled`, so this filter targets the
        // real document window.
        let mainWindow = NSApp.windows.first { window in
            window.styleMask.contains(.titled) && window.canBecomeMain
        }
        // In `.accessory` mode the app has no normal activation, so `makeKeyAndOrderFront`
        // alone can fail to raise the window above the foreground app. `orderFrontRegardless`
        // forces it to the front even when Raccoon isn't the active app, which keeps both the
        // MenuBarExtra "Show window" path and the global hotkey working in menu-bar mode.
        mainWindow?.makeKeyAndOrderFront(nil)
        mainWindow?.orderFrontRegardless()
    }

    // MARK: Background sync

    /// Starts (or restarts) the cancellable periodic background-sync loop.
    private func startBackgroundSync() {
        backgroundSyncTask?.cancel()
        backgroundSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.backgroundSyncInterval)
                if Task.isCancelled { return }
                // Stop the loop if the model has been deallocated (avoids a
                // spinning task without relying on a main-actor-isolated deinit).
                guard let self else { return }
                self.syncNow()
            }
        }
    }
}
