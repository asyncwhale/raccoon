import Foundation
import KeyboardShortcuts

/// Strongly-typed names for Raccoon's global keyboard shortcuts.
///
/// The summon hotkey is user-assignable in Settings. It now ships with a sensible DEFAULT
/// (⌃⌘R) applied on first launch only — see `installDefaultsIfNeeded()` — so the feature
/// works out of the box without clobbering a combo the user has already chosen.
extension KeyboardShortcuts.Name {
    /// Global hotkey that brings the Raccoon main window to the front (§9, summon).
    static let summonRaccoon = Self("summonRaccoon")

    /// Apply Raccoon's default global-shortcut bindings, but ONLY for shortcuts the user has
    /// not already assigned. Idempotent and safe to call on every launch: `getShortcut(for:)`
    /// returns the user's stored combo (or nil if unbound), so we never overwrite a deliberate
    /// choice. The default summon combo is ⌃⌘R (Control-Command-R).
    ///
    /// Why ⌃⌘R: it is free of conflicts with Raccoon's in-app menu shortcuts (⌘N, ⌘F, ⌘E,
    /// ⌘⇧K, ⌘⌥P, ⌘\, ⌘S, ⌘O, ⌘,) — none use the Control modifier — and ⌃⌘R is not a
    /// system-reserved global combo on macOS, while staying mnemonic ("R" for Raccoon).
    static func installDefaultsIfNeeded() {
        if KeyboardShortcuts.getShortcut(for: .summonRaccoon) == nil {
            KeyboardShortcuts.setShortcut(.init(.r, modifiers: [.control, .command]), for: .summonRaccoon)
        }
    }
}

// MARK: - In-app command notifications

/// App-level command-menu items (the ⌘-shortcut menu) are decoupled from the views that
/// perform the work via these notifications: the menu `post`s, the owning view/model observes.
/// This keeps command wiring out of the views' state ownership and avoids duplicating the
/// button actions — each notification drives the SAME function the corresponding button calls.
extension Notification.Name {
    /// ⌘F — move keyboard focus into the sidebar search field. Observed by `SidebarView`.
    static let focusSidebarSearch = Notification.Name("raccoon.focusSidebarSearch")
    /// ⌘E — toggle the active tab's Markdown preview. Observed by `EditorView`.
    static let toggleEditorPreview = Notification.Name("raccoon.toggleEditorPreview")
    /// ⌘⇧K — clean the current selection / note to plain text. Observed by `EditorView`.
    static let cleanEditorContent = Notification.Name("raccoon.cleanEditorContent")
    /// ⌘\ — show/hide the session-list sidebar. Observed by `ContentView`.
    static let toggleSidebar = Notification.Name("raccoon.toggleSidebar")
}
