import SwiftUI
import AppKit
import RaccoonCore

/// A shared, main-actor handle to the live `NSTextView` for the active tab. `EditorView`
/// reads this to drive toolbar actions ("转纯文本", "还原本次粘贴") that operate on the current
/// selection. `MarkdownTextView` publishes its text view here on `makeNSView` and clears it
/// when the editor goes away.
@MainActor
@Observable
final class TextViewHandle {
    /// The live text view, or `nil` before the editor has appeared.
    weak var textView: NSTextView?
}

/// An `NSViewRepresentable` wrapping an `NSTextView` (inside an `NSScrollView`) configured
/// as a plain-text Markdown editor: monospaced, no smart substitutions, undo enabled. The
/// text view is a `CleanTextView` subclass that intercepts ⌘V to run the CleanEngine.
struct MarkdownTextView: NSViewRepresentable {

    /// Two-way binding to the active tab's text.
    @Binding var text: String

    /// When `false`, the view is non-editable (but still selectable).
    let isEditable: Bool

    /// Pulls the current auto-clean setting at paste time (so the toggle takes effect live).
    let isAutoCleanOn: () -> Bool

    /// Pulls the current "tidy prose" setting at paste time. Tidy only applies when
    /// auto-clean is ALSO on (it is a refinement of the clean pass).
    var isTidyProseOn: () -> Bool = { false }

    /// Reports a completed auto-cleaned paste: the range the cleaned text now occupies and
    /// the verbatim original, so the active tab can offer "还原本次粘贴".
    let onCleanPaste: (NSRange, String) -> Void

    /// Shared handle so `EditorView` can reach the live text view for selection-based actions.
    let handle: TextViewHandle

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isAutoCleanOn: isAutoCleanOn, onCleanPaste: onCleanPaste)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = CleanTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? CleanTextView else {
            return scrollView
        }

        // Plain-text editor configuration.
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.isSelectable = true
        textView.usesFindBar = true
        // Comfortable text-container inset within the centered reading measure.
        textView.textContainerInset = NSSize(width: DS.Content.editorInset, height: DS.Content.editorInset)
        // Line-height ~1.6 for the mono body.
        let lineStyle = NSMutableParagraphStyle()
        lineStyle.lineHeightMultiple = 1.6
        textView.defaultParagraphStyle = lineStyle
        textView.typingAttributes[.paragraphStyle] = lineStyle
        // Let the window/material background show through (no opaque white slab in dark mode).
        textView.drawsBackground = false
        textView.delegate = context.coordinator

        // Fill width; grow vertically.
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        // Wire the paste-clean closures into the subclass.
        textView.isAutoCleanOn = isAutoCleanOn
        textView.isTidyProseOn = isTidyProseOn
        textView.onCleanPaste = onCleanPaste

        textView.string = text
        textView.isEditable = isEditable

        handle.textView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CleanTextView else { return }

        // Keep the live closures current (they capture the latest tab / setting).
        textView.isAutoCleanOn = isAutoCleanOn
        textView.isTidyProseOn = isTidyProseOn
        textView.onCleanPaste = onCleanPaste
        context.coordinator.isAutoCleanOn = isAutoCleanOn
        context.coordinator.onCleanPaste = onCleanPaste

        // Push external text changes (e.g. tab switch, open file, restore) into the view
        // without clobbering the user's caret while they type. We only overwrite when the
        // bound value diverged from what the view holds.
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            // Clamp the previous selection into the new string bounds.
            let clamped = NSRange(
                location: min(selected.location, (text as NSString).length),
                length: 0
            )
            textView.setSelectedRange(clamped)
        }

        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }

        // Re-publish in case the view was recreated.
        handle.textView = textView
    }

    // MARK: Coordinator

    /// Bridges `NSTextViewDelegate` callbacks back to the SwiftUI binding.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        var isAutoCleanOn: () -> Bool
        var onCleanPaste: (NSRange, String) -> Void
        weak var textView: NSTextView?

        init(
            text: Binding<String>,
            isAutoCleanOn: @escaping () -> Bool,
            onCleanPaste: @escaping (NSRange, String) -> Void
        ) {
            self.text = text
            self.isAutoCleanOn = isAutoCleanOn
            self.onCleanPaste = onCleanPaste
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Push the edit back to the binding on the next runloop tick to avoid mutating
            // observable state during the text system's own update pass.
            let newValue = textView.string
            Task { @MainActor in
                if self.text.wrappedValue != newValue {
                    self.text.wrappedValue = newValue
                }
            }
        }
    }
}

/// `NSTextView` subclass implementing the signature paste-auto-clean (§9.2). On ⌘V, if
/// auto-clean is ON it reads the plain string from the pasteboard, runs
/// `CleanEngine.clean`, and inserts the CLEANED text as a single undoable edit — then
/// reports the inserted range + verbatim original so the UI can offer a lossless restore.
/// If auto-clean is OFF it falls through to the system paste.
final class CleanTextView: NSTextView {

    /// Pulls the current auto-clean setting at paste time. Set by `MarkdownTextView`.
    var isAutoCleanOn: (() -> Bool)?

    /// Pulls the current "tidy prose" setting at paste time. Set by `MarkdownTextView`.
    var isTidyProseOn: (() -> Bool)?

    /// Reports a completed auto-cleaned paste (range, verbatim original). Set by
    /// `MarkdownTextView`.
    var onCleanPaste: ((NSRange, String) -> Void)?

    override func paste(_ sender: Any?) {
        // Auto-clean OFF, or no plain string on the pasteboard → system paste.
        guard
            isAutoCleanOn?() == true,
            let raw = NSPasteboard.general.string(forType: .string)
        else {
            super.paste(sender)
            return
        }

        // Tidy is opt-in and only meaningful alongside auto-clean (guaranteed on here).
        var options = CleanOptions()
        options.tidyProse = isTidyProseOn?() == true
        let cleaned = CleanEngine.clean(raw, options: options).cleaned

        // Where the cleaned text will land. `shouldChangeText` registers the edit with the
        // undo manager so the whole paste is a single undoable action.
        let replacementRange = selectedRange()
        guard shouldChangeText(in: replacementRange, replacementString: cleaned) else {
            return
        }
        textStorage?.replaceCharacters(in: replacementRange, with: cleaned)
        didChangeText()

        // The cleaned text now occupies [start, start + len). Report it for "还原本次粘贴".
        let insertedRange = NSRange(
            location: replacementRange.location,
            length: (cleaned as NSString).length
        )
        onCleanPaste?(insertedRange, raw)
    }
}
