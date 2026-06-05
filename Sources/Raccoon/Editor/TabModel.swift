import Foundation
import Observation
import AppKit
import RaccoonCore

/// A single open editor document. Backed by a file on disk (`fileURL != nil`) or an
/// untitled in-memory buffer. All state is main-actor-isolated; the UI binds to `text`,
/// `title`, and `isPreviewing` directly.
@MainActor
@Observable
final class EditorTab: Identifiable {

    let id = UUID()

    /// Display title shown in the tab chip. For file-backed tabs this is the file name;
    /// untitled tabs use an empty title and the chip shows a localized placeholder.
    var title: String

    /// The full document text. Two-way bound to the `NSTextView`.
    var text: String

    /// Backing file on disk, or `nil` for an untitled (never-saved) tab.
    var fileURL: URL?

    /// Read-only tabs reject edits (the text view is non-editable but still selectable).
    var isReadOnly: Bool

    /// Whether this tab is showing the rendered Markdown preview instead of the editor.
    var isPreviewing: Bool = false

    /// The most recent auto-cleaned paste, if any: the range the cleaned text occupies and
    /// the verbatim original. Powers "还原本次粘贴". Cleared once restored or after another edit
    /// that would invalidate the range.
    var lastPaste: (range: NSRange, original: String)?

    // MARK: Archived-record context (§9.5)

    /// For tabs that show an archived session: the absolute path of the backing `.md`
    /// file. `nil` for ordinary note tabs. When non-nil, the editor shows the record
    /// action toolbar (复制走 / 喂·路径 / 喂·内容 / 星标).
    var recordPath: URL?

    /// The decoded archived session backing this tab, kept so the toolbar can build the
    /// §9.5 payloads and reflect star toggles without re-reading from disk. `nil` for
    /// ordinary note tabs.
    var record: Record?

    /// `true` when this tab represents an archived session (i.e. `recordPath != nil`).
    var isRecordTab: Bool { recordPath != nil }

    /// New untitled tabs default to an EMPTY title so the UI renders a localized
    /// "Untitled" placeholder (see `TabChip`) instead of a hardcoded language.
    init(
        title: String = "",
        text: String = "",
        fileURL: URL? = nil,
        isReadOnly: Bool = false
    ) {
        self.title = title
        self.text = text
        self.fileURL = fileURL
        self.isReadOnly = isReadOnly
    }

    /// Convenience: build a tab from a file on disk, reading its contents. Throws if the
    /// file can't be read.
    static func opening(_ url: URL, isReadOnly: Bool = false) throws -> EditorTab {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return EditorTab(
            title: url.lastPathComponent,
            text: contents,
            fileURL: url,
            isReadOnly: isReadOnly
        )
    }
}
