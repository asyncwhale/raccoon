import Foundation
import Observation
import AppKit
import RaccoonCore

/// Owns the set of open editor tabs and the active selection, plus reopen-restore
/// persistence to `UserDefaults`. Owned by `AppModel`; the editor UI binds to it.
///
/// Persistence model (§9.11): we snapshot the open-tab list to `UserDefaults` as JSON
/// whenever it changes. File-backed tabs persist only their `fileURL` (re-read on launch);
/// untitled tabs persist their `title` + `text` verbatim so unsaved scratch survives a
/// relaunch. The active tab's id is recorded so we can restore focus.
@MainActor
@Observable
final class EditorModel {

    /// The open tabs, left-to-right. Never empty after `restoreOrSeed()` runs.
    var tabs: [EditorTab] = []

    /// The currently selected tab's id, or `nil` if there are no tabs.
    var activeTabID: EditorTab.ID?

    /// The active tab, or `nil` if none is selected.
    var activeTab: EditorTab? {
        guard let activeTabID else { return nil }
        return tabs.first { $0.id == activeTabID }
    }

    /// `UserDefaults` key under which the tab snapshot lives.
    private static let persistenceKey = "editor.openTabs.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Tab lifecycle

    /// Create a fresh untitled tab, append it, and make it active. Returns the new tab.
    @discardableResult
    func newTab() -> EditorTab {
        let tab = EditorTab()
        tabs.append(tab)
        activeTabID = tab.id
        persist()
        return tab
    }

    /// Append an already-built tab (e.g. an opened file) and make it active.
    @discardableResult
    func addTab(_ tab: EditorTab) -> EditorTab {
        // If a file-backed tab for the same URL is already open, just focus it.
        if let url = tab.fileURL, let existing = tabs.first(where: { $0.fileURL == url }) {
            activeTabID = existing.id
            return existing
        }
        tabs.append(tab)
        activeTabID = tab.id
        persist()
        return tab
    }

    /// Open an archived `record` (loaded from `path`) as a READ-ONLY tab (§9.5).
    ///
    /// De-dupes by `recordPath`: if a record tab for that path is already open it is
    /// re-selected (and its `record` refreshed in case star/content changed). The tab's
    /// text is a readable transcript — the §4 body with 来源标签 — and it is non-editable.
    @discardableResult
    func addRecordTab(record: Record, path: URL) -> EditorTab {
        // Re-focus an already-open record tab for this path; refresh its snapshot.
        if let existing = tabs.first(where: { $0.recordPath == path }) {
            existing.record = record
            existing.text = RecordClipboard.feedContent(record)
            existing.title = record.title
            activeTabID = existing.id
            return existing
        }

        let tab = EditorTab(
            title: record.title,
            text: RecordClipboard.feedContent(record),
            fileURL: nil,
            isReadOnly: true
        )
        tab.recordPath = path
        tab.record = record
        tabs.append(tab)
        activeTabID = tab.id
        // Record tabs are reconstructed from the archive on demand, so they are not part
        // of the note reopen-restore snapshot — no persist() here.
        return tab
    }

    /// Close the given tab. Keeps the selection sensible (selects a neighbor). Seeds a new
    /// empty tab if the last one was closed so the editor is never empty.
    func closeTab(_ tab: EditorTab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: idx)
        if activeTabID == tab.id {
            // Prefer the tab that shifted into this slot, else the previous one.
            if idx < tabs.count {
                activeTabID = tabs[idx].id
            } else if let last = tabs.last {
                activeTabID = last.id
            } else {
                activeTabID = nil
            }
        }
        if tabs.isEmpty {
            newTab()
        } else {
            persist()
        }
    }

    /// Make the given tab active.
    func select(_ tab: EditorTab) {
        activeTabID = tab.id
    }

    // MARK: Persistence (reopen-restore, §9.11)

    /// Snapshot the current tabs to `UserDefaults`. Call after any structural change
    /// (open/close/new) and after a save (so a freshly file-backed tab persists its URL).
    func persist() {
        // Record tabs (archived sessions) are reconstructed from the archive on demand,
        // not from this note snapshot — exclude them so a relaunch doesn't resurrect them
        // as orphaned read-only note stubs that have lost their record context.
        let noteTabs = tabs.filter { !$0.isRecordTab }
        let snapshot = PersistedState(
            tabs: noteTabs.map { tab in
                PersistedTab(
                    fileBookmarkPath: tab.fileURL?.path,
                    title: tab.title,
                    // Only persist text for untitled tabs; file-backed tabs re-read on launch.
                    text: tab.fileURL == nil ? tab.text : nil,
                    isReadOnly: tab.isReadOnly
                )
            },
            activeIndex: noteTabs.firstIndex { $0.id == activeTabID }
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.persistenceKey)
    }

    /// Restore tabs from `UserDefaults` on launch. File-backed tabs are re-read from disk
    /// (skipped if the file no longer exists); untitled tabs are restored from saved text.
    /// If nothing restores, seeds a single empty tab so the editor is never empty.
    func restoreOrSeed() {
        defer {
            if tabs.isEmpty { newTab() }
        }

        guard
            let data = defaults.data(forKey: Self.persistenceKey),
            let snapshot = try? JSONDecoder().decode(PersistedState.self, from: data)
        else {
            return
        }

        var restored: [EditorTab] = []
        for persisted in snapshot.tabs {
            if let path = persisted.fileBookmarkPath {
                let url = URL(fileURLWithPath: path)
                // Skip files that no longer exist.
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if let tab = try? EditorTab.opening(url, isReadOnly: persisted.isReadOnly) {
                    restored.append(tab)
                }
            } else {
                restored.append(
                    EditorTab(
                        title: persisted.title,
                        text: persisted.text ?? "",
                        fileURL: nil,
                        isReadOnly: persisted.isReadOnly
                    )
                )
            }
        }

        guard !restored.isEmpty else { return }
        tabs = restored

        // Restore active selection by index (clamped), since ids are regenerated.
        if let idx = snapshot.activeIndex, restored.indices.contains(idx) {
            activeTabID = restored[idx].id
        } else {
            activeTabID = restored.first?.id
        }
    }

    // MARK: Persisted shapes

    private struct PersistedState: Codable {
        var tabs: [PersistedTab]
        var activeIndex: Int?
    }

    private struct PersistedTab: Codable {
        /// Absolute path of the backing file, or `nil` for untitled tabs.
        var fileBookmarkPath: String?
        var title: String
        /// Verbatim text for untitled tabs; `nil` for file-backed (re-read on launch).
        var text: String?
        var isReadOnly: Bool
    }
}
