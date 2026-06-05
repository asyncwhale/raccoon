import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RaccoonCore

/// The editor pane (Phase 2B): a custom tab bar, a control row (paste auto-clean toggle,
/// convert/restore, preview, save), an optional record action row (for archived records),
/// and the active tab's `MarkdownTextView` or preview. Handles ⌘N / ⌘S / ⌘O and
/// reopen-restore via `EditorModel`.
struct EditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(ToastCenter.self) private var toast

    /// Live handle to the active tab's `NSTextView`, for selection-based toolbar actions.
    @State private var handle = TextViewHandle()

    private var editor: EditorModel { model.editor }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            tabBar
            controlRow(model: $model)
            // §9.5 — archived records get an extra action row (复制走 / 喂 / 星标).
            if let tab = activeTab, tab.isRecordTab {
                recordToolbar(tab: tab)
            }
            Divider().overlay(DS.Color.separator)
            editingArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.bgWindow)
        // Hidden buttons provide the ⌘N/⌘S/⌘O key equivalents for this scene.
        .background(commandShortcuts)
        // ⌘E (app command menu) — toggle the active tab's Markdown preview, the same flip
        // the eye button performs. No-op for read-only record tabs (preview doesn't apply).
        .onReceive(NotificationCenter.default.publisher(for: .toggleEditorPreview)) { _ in
            if let tab = activeTab, !tab.isRecordTab {
                tab.isPreviewing.toggle()
            }
        }
        // ⌘⇧K (app command menu) — clean the current selection / note to plain text, the
        // same action the convert button performs. Guards live inside the function.
        .onReceive(NotificationCenter.default.publisher(for: .cleanEditorContent)) { _ in
            convertSelectionToPlainText()
        }
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Spacing.sm - 2) {
                    ForEach(editor.tabs) { tab in
                        tabChip(tab, isOnlyTab: editor.tabs.count == 1)
                    }
                }
                .padding(.horizontal, DS.Spacing.sm)
            }
            Button {
                editor.newTab()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(IconButtonStyle())
            .help(Text("editor.newNote.help"))
            .accessibilityLabel(Text("editor.newNote.help"))
            .padding(.trailing, DS.Spacing.sm)
        }
        .frame(height: 38)
        .padding(.top, DS.Spacing.sm)
    }

    private func tabChip(_ tab: EditorTab, isOnlyTab: Bool) -> some View {
        TabChip(
            tab: tab,
            isActive: tab.id == editor.activeTabID,
            // The empty scratch/untitled tab auto-recreates when closed, so its ✕ is a
            // confusing no-op when it is the only tab — hide it then. With other tabs open it
            // closes normally; a dirty (non-empty) untitled tab always keeps its ✕.
            canClose: !(isOnlyTab && tab.recordPath == nil && tab.fileURL == nil && tab.text.isEmpty),
            onSelect: { editor.select(tab) },
            onClose: { editor.closeTab(tab) }
        )
    }

    // MARK: Control row

    @ViewBuilder
    private func controlRow(model: Bindable<AppModel>) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            autoCleanButton(model: model)
            groupDivider
            convertButton
            restoreButton
            Spacer()
            previewButton
            saveButton
        }
        .frame(height: 36)
        .padding(.horizontal, DS.Spacing.md)
    }

    /// True when the active tab can't accept in-place text edits (read-only or previewing).
    private var editingDisabled: Bool {
        (activeTab?.isReadOnly ?? true) || (activeTab?.isPreviewing ?? false)
    }

    /// §9.2 — auto-clean toggle as an icon button (amber when ON). Default ON.
    private func autoCleanButton(model: Bindable<AppModel>) -> some View {
        let isOn = model.wrappedValue.settings.autoCleanOnPaste
        return Button {
            model.wrappedValue.settings.autoCleanOnPaste.toggle()
            model.wrappedValue.saveSettings()
        } label: {
            Image(systemName: "wand.and.sparkles")
        }
        .buttonStyle(IconButtonStyle(isActive: isOn))
        .help(isOn ? Text("editor.autoclean.on.help") : Text("editor.autoclean.off.help"))
        .accessibilityLabel(isOn ? Text("editor.autoclean.on.help") : Text("editor.autoclean.off.help"))
    }

    private var convertButton: some View {
        Button {
            convertSelectionToPlainText()
        } label: {
            Image(systemName: "sparkles")
        }
        .buttonStyle(IconButtonStyle())
        .help(Text("editor.convert.help"))
        .accessibilityLabel(Text("editor.convert.help"))
        .disabled(editingDisabled)
    }

    private var restoreButton: some View {
        let hasPaste = activeTab?.lastPaste != nil
        return Button {
            restoreLastPaste()
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .buttonStyle(IconButtonStyle())
        .help(Text("editor.restorePaste.help"))
        .accessibilityLabel(Text("editor.restorePaste.help"))
        .disabled(!hasPaste || editingDisabled)
    }

    @ViewBuilder
    private var previewButton: some View {
        if let tab = activeTab {
            @Bindable var tab = tab
            Button {
                tab.isPreviewing.toggle()
            } label: {
                Image(systemName: tab.isPreviewing ? "eye.fill" : "eye")
            }
            .buttonStyle(IconButtonStyle(isActive: tab.isPreviewing))
            .help(tab.isPreviewing ? Text("editor.preview.back.help") : Text("editor.preview.show.help"))
            .accessibilityLabel(tab.isPreviewing ? Text("editor.preview.back.help") : Text("editor.preview.show.help"))
        }
    }

    /// The dirty-dot is shown for an unsaved (no `fileURL`) tab that has any content.
    private var showsDirtyDot: Bool {
        guard let tab = activeTab else { return false }
        return tab.fileURL == nil && !tab.text.isEmpty
    }

    private var saveButton: some View {
        Button {
            save()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "square.and.arrow.down")
                if showsDirtyDot {
                    Circle()
                        .fill(DS.Color.accent)
                        .frame(width: 5, height: 5)
                }
            }
        }
        .buttonStyle(IconButtonStyle())
        .help(Text("editor.save.help"))
        .accessibilityLabel(Text("editor.save.help"))
        .disabled(activeTab?.isReadOnly ?? true)
    }

    /// A short hairline used to separate unrelated button groups in the control row.
    private var groupDivider: some View {
        Rectangle()
            .fill(DS.Color.separator)
            .frame(width: 1, height: 16)
    }

    // MARK: Record toolbar (§9.5)

    /// Action row for an archived (read-only) record tab. De-densified into deliberate
    /// CLUSTERS separated by real gutters + hairline dividers so it reads as calm as the
    /// empty state, instead of one undifferentiated strip of glyphs:
    ///
    ///   [ back ]  [ archived label ] │ [ 复制走 ]  │  ( 喂·路径 · 喂·内容 )   …spacer…   [ ★ ]
    ///
    /// The three clipboard outputs are no longer three near-identical pills: 复制走 (plain
    /// clipboard) sits alone, and the two AI-FEED actions (喂·路径 / 喂·内容) share one subtly
    /// recessed container so they read pre-attentively as a related pair distinct from a plain
    /// copy. Each 喂 button also carries a tiny always-visible caption naming its target AI.
    @ViewBuilder
    private func recordToolbar(tab: EditorTab) -> some View {
        if let record = tab.record, let path = tab.recordPath {
            HStack(spacing: DS.Spacing.md) {
                // Cluster 1 — navigation + context label.
                HStack(spacing: DS.Spacing.sm) {
                    // Explicit BACK control — closes the archived record tab and returns to the
                    // editor / blank note. The owner's #1 confusion was not finding the way back.
                    Button {
                        editor.closeTab(tab)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(Text("editor.record.back.help"))
                    .accessibilityLabel(Text("editor.record.back.help"))

                    HStack(spacing: DS.Spacing.xs + 2) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.Color.textTertiary)
                            .accessibilityHidden(true)
                        Text("editor.banner.archived")
                            .font(DS.Font.sectionHeader)
                            .tracking(DS.Tracking.header)
                            .foregroundStyle(DS.Color.textTertiary)
                    }
                }

                groupDivider

                // Cluster 2 — plain clipboard copy (no source labels). Distinct glyph
                // `doc.on.doc` = a literal copy. Stands alone: it is NOT a "feed to AI" action.
                Button {
                    copyToPasteboard(RecordClipboard.copyOut(record), successToast: String(localized: "toast.copied.clipboard"))
                } label: {
                    Label("editor.feed.copy", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(LabeledToolbarButtonStyle())
                .help(Text("editor.feed.copy.help"))
                .accessibilityLabel(Text("editor.feed.copy.help"))

                groupDivider

                // Cluster 3 — the AI-FEED pair, in one shared recessed container so they read
                // as a conceptual group, set apart from the plain copy above. Distinct glyphs:
                //   喂·路径   = `arrow.up.forward.app` — hand a file REFERENCE to a CLI agent.
                //   喂·内容   = `text.quote`           — hand the labeled VERBATIM content over.
                // Each carries a tiny caption naming the target AI so the choice is legible
                // without hovering.
                HStack(spacing: DS.Spacing.xs) {
                    feedButton(
                        titleKey: "editor.feed.path",
                        symbol: "arrow.up.forward.app",
                        captionKey: "editor.feed.path.caption",
                        helpKey: "editor.feed.path.help"
                    ) {
                        copyToPasteboard(RecordClipboard.feedPath(mdPath: path), successToast: String(localized: "toast.copied.path"))
                    }
                    feedButton(
                        titleKey: "editor.feed.content",
                        symbol: "text.quote",
                        captionKey: "editor.feed.content.caption",
                        helpKey: "editor.feed.content.help"
                    ) {
                        copyToPasteboard(RecordClipboard.feedContent(record), successToast: String(localized: "toast.copied.content"))
                    }
                }
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .fill(DS.Color.hoverFill.opacity(0.6))
                )

                Spacer()

                // Cluster 4 — star toggle.
                Button {
                    // `record.starred` is the pre-toggle value captured at render time, so the
                    // toast reflects the NEW state after the flip.
                    toast.show(record.starred ? String(localized: "toast.star.off") : String(localized: "toast.star.on"))
                    toggleStar(tab: tab, path: path, record: record)
                } label: {
                    Image(systemName: record.starred ? "star.fill" : "star")
                }
                .buttonStyle(IconButtonStyle(isActive: record.starred))
                .help(record.starred ? Text("editor.star.on.help") : Text("editor.star.off.help"))
                .accessibilityLabel(record.starred ? Text("editor.star.on.help") : Text("editor.star.off.help"))
            }
            .frame(height: 44)
            .padding(.horizontal, DS.Spacing.md)
            .background(DS.Color.bgSidebar.opacity(0.5))
        }
    }

    /// One 喂 (feed-to-AI) button: an icon+title pill with a tiny always-visible caption beneath
    /// naming the target AI (e.g. "给命令行 AI"), so the path-vs-content choice is legible without
    /// hovering. The caption is sized down and tertiary so it stays tasteful, not noisy.
    private func feedButton(
        titleKey: LocalizedStringKey,
        symbol: String,
        captionKey: LocalizedStringKey,
        helpKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Label(titleKey, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
                    .font(DS.Font.controlLabel)
                    .imageScale(.small)
                Text(captionKey)
                    .font(DS.Font.badgeGlyph)
                    .foregroundStyle(DS.Color.textTertiary)
            }
        }
        .buttonStyle(LabeledToolbarButtonStyle())
        .help(Text(helpKey))
        .accessibilityLabel(Text(helpKey))
    }

    /// Replace the general pasteboard with a single plain-text payload (§9.5 pattern).
    ///
    /// Secret-leak hardening: the payload is the verbatim record body, which can contain
    /// API keys / tokens / private keys a user pasted into a session. To keep those from
    /// persisting in clipboard managers and being synced over Universal Clipboard, the
    /// pasteboard item is additionally tagged with the de-facto "concealed/transient"
    /// pasteboard hints (`org.nspasteboard.ConcealedType` / `…TransientType`) that
    /// password-manager-style tools honor by skipping the entry. We still write the plain
    /// string normally so a manual ⌘V works everywhere.
    ///
    /// Returns the secret hits found in `payload` (value-free; never logs the secrets) so the
    /// caller can warn the user that secrets are about to hit the clipboard.
    @discardableResult
    private func setPasteboard(_ payload: String) -> [SecretScan.SecretHit] {
        // Delegates to the shared secret-safe writer so the concealment + scan logic lives in
        // exactly ONE place (`SecretSafePasteboard`), shared with PreviewView's block-copy button.
        SecretSafePasteboard.write(payload)
    }

    /// Copy `payload` to the (concealed) pasteboard and show a toast. If the payload trips the
    /// secret scanner, surface a WARNING toast naming the count instead of the plain success
    /// one, so the user knows secrets just hit the clipboard. The copy still happens (the user
    /// explicitly pressed a FEED button); the warning is the safety signal the spec requires.
    private func copyToPasteboard(_ payload: String, successToast: String) {
        let hits = setPasteboard(payload)
        if hits.isEmpty {
            toast.show(successToast)
        } else {
            toast.show(String(localized: "toast.copied.secrets \(hits.count)"))
        }
    }

    /// Flip the record's `starred` flag: persist via the store actor (then refresh `records`),
    /// and update the tab's in-memory `record` immediately for snappy UI feedback.
    private func toggleStar(tab: EditorTab, path: URL, record: Record) {
        let newValue = !record.starred
        // Immediate optimistic UI update on the tab's snapshot.
        tab.record?.starred = newValue
        // Persist + refresh the sidebar list through the store actor.
        model.setStarred(path: path, newValue)
    }

    // MARK: Editing area

    @ViewBuilder
    private var editingArea: some View {
        if let tab = activeTab {
            @Bindable var tab = tab
            if tab.isRecordTab, let record = tab.record {
                // Hero surface: Warp-style read-only record blocks.
                RecordBlocksView(record: record)
            } else if tab.isPreviewing {
                PreviewView(text: tab.text)
            } else {
                // Center the editor at a comfortable reading measure.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    MarkdownTextView(
                        text: $tab.text,
                        isEditable: !tab.isReadOnly,
                        isAutoCleanOn: { [weak model] in model?.settings.autoCleanOnPaste ?? true },
                        isTidyProseOn: { [weak model] in model?.settings.autoTidyProseOnPaste ?? false },
                        onCleanPaste: { [weak tab] range, original in
                            tab?.lastPaste = (range: range, original: original)
                        },
                        handle: handle
                    )
                    .frame(maxWidth: DS.Content.maxMeasure)
                    // Recreate the representable when the active tab changes so the binding and
                    // the live text view track the right document.
                    .id(tab.id)
                    Spacer(minLength: 0)
                }
                // A subtle centered hint over a brand-new empty note, so the editor pane is
                // never a blank white void. Non-interactive so it never blocks typing/paste.
                .overlay {
                    if tab.text.isEmpty && !tab.isReadOnly {
                        EmptyStateView(
                            headline: String(localized: "editor.empty.title"),
                            subline: String(localized: "editor.empty.subline.note"),
                            hint: "⌘N"
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
        } else {
            EmptyStateView(
                headline: String(localized: "editor.empty.title"),
                subline: String(localized: "editor.empty.subline.none"),
                hint: "⌘N"
            )
        }
    }

    private var activeTab: EditorTab? { editor.activeTab }

    // MARK: Command shortcuts (⌘N / ⌘S / ⌘O)

    private var commandShortcuts: some View {
        ZStack {
            Button("") { editor.newTab() }
                .keyboardShortcut("n", modifiers: .command)
            Button("") { save() }
                .keyboardShortcut("s", modifiers: .command)
            Button("") { open() }
                .keyboardShortcut("o", modifiers: .command)
            // Esc closes an open archived-record tab and returns to the editor (the owner's
            // "怎么回去" pain). Only acts when the active tab is a read-only record.
            Button("") {
                if let tab = activeTab, tab.isRecordTab {
                    editor.closeTab(tab)
                }
            }
            .keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Actions — convert to plain text (§9.3)

    /// Run `CleanEngine.toPlainText` on the current selection (or whole doc if no selection)
    /// and replace it as a single undoable edit, then sync the binding.
    private func convertSelectionToPlainText() {
        guard let tab = activeTab, !tab.isReadOnly, let tv = handle.textView else { return }
        let full: NSString = tv.string as NSString
        var range: NSRange = tv.selectedRange()
        if range.length == 0 {
            range = NSRange(location: 0, length: full.length)
        }
        let source: String = full.substring(with: range)
        let converted: String = CleanEngine.toPlainText(source)
        guard converted != source else { return }

        guard tv.shouldChangeText(in: range, replacementString: converted) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: converted)
        tv.didChangeText()
        // Select the converted span so the user sees what changed.
        let convertedLength: Int = (converted as NSString).length
        tv.setSelectedRange(NSRange(location: range.location, length: convertedLength))
        tab.text = tv.string
        // A structural edit invalidates any prior paste-range; clear it.
        tab.lastPaste = nil
        toast.show(String(localized: "toast.converted"))
    }

    // MARK: Actions — restore this paste

    /// Replace the recorded cleaned range with the verbatim original (single undoable edit),
    /// then clear `lastPaste`.
    private func restoreLastPaste() {
        guard let tab = activeTab, !tab.isReadOnly, let paste = tab.lastPaste,
              let tv = handle.textView else { return }
        let length = (tv.string as NSString).length
        // Guard against a stale range (document edited since the paste).
        guard paste.range.location + paste.range.length <= length else {
            tab.lastPaste = nil
            return
        }
        guard tv.shouldChangeText(in: paste.range, replacementString: paste.original) else { return }
        tv.textStorage?.replaceCharacters(in: paste.range, with: paste.original)
        tv.didChangeText()
        tv.setSelectedRange(
            NSRange(location: paste.range.location, length: (paste.original as NSString).length)
        )
        tab.text = tv.string
        tab.lastPaste = nil
        toast.show(String(localized: "toast.restoredPaste"))
    }

    // MARK: Actions — Save / Open (§9.11)

    /// ⌘S. New (untitled) tabs prompt an `NSSavePanel` defaulting to `notesDir`; saved tabs
    /// overwrite in place. Writes to the NOTES dir — never the records/archive dir.
    private func save() {
        guard let tab = activeTab, !tab.isReadOnly else { return }

        // `textDidChange` pushes the binding on the next runloop tick, so the binding
        // can lag behind by one character. Prefer the live text view's string when
        // available so we never write a stale snapshot.
        if let tv = handle.textView {
            tab.text = tv.string
        }

        if let url = tab.fileURL {
            writeText(tab.text, to: url, tab: tab)
            return
        }

        // Ensure notesDir exists (it's created at init, but be defensive).
        let notesDir = model.settings.notesDir
        try? FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        let panel = NSSavePanel()
        panel.directoryURL = notesDir
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = defaultFileName(for: tab)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, var url = panel.url else { return }
        // Force a `.md` extension if the user dropped it.
        if url.pathExtension.lowercased() != "md" {
            url.deletePathExtension()
            url.appendPathExtension("md")
        }
        writeText(tab.text, to: url, tab: tab)
    }

    /// Suggest a file name from the tab title or first non-empty line, falling back to a date.
    private func defaultFileName(for tab: EditorTab) -> String {
        let untitledPlaceholder = String(localized: "editor.untitled")
        if !tab.title.isEmpty, tab.title != "未命名", tab.title != "Untitled", tab.title != untitledPlaceholder {
            return tab.title.hasSuffix(".md") ? tab.title : tab.title + ".md"
        }
        let firstLine = tab.text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let stem = firstLine.isEmpty ? String(localized: "editor.untitledNote.filename") : String(firstLine.prefix(40))
        // Strip path separators that would break the file name.
        let safe = stem.replacingOccurrences(of: "/", with: "-")
        return safe + ".md"
    }

    private func writeText(_ text: String, to url: URL, tab: EditorTab) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            tab.fileURL = url
            tab.title = url.lastPathComponent
            editor.persist()
        } catch {
            presentError(String(localized: "editor.error.save.title"), error)
        }
    }

    /// ⌘O. Open one or more `.md` files into new tabs.
    private func open() {
        let panel = NSOpenPanel()
        panel.directoryURL = model.settings.notesDir
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let tab = try EditorTab.opening(url)
                editor.addTab(tab)
            } catch {
                presentError(String(localized: "editor.error.open.title"), error)
            }
        }
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - TabChip

/// One editor tab pill. The close `✕` is revealed on hover (~120ms) instead of always-on,
/// and routed through `IconButtonStyle` for consistent hover/press/hit-area with the rest
/// of the chrome. Active tabs get a calm 2pt amber underline (not a full accent fill).
private struct TabChip: View {
    let tab: EditorTab
    let isActive: Bool
    /// `false` for the lone empty scratch tab, whose ✕ would be a no-op (it auto-recreates).
    var canClose: Bool = true
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Spacing.xs + 2) {
            if tab.isReadOnly {
                Image(systemName: "lock.fill")
                    .font(DS.Font.badgeGlyph)
                    .foregroundStyle(DS.Color.textTertiary)
                    .help(Text("editor.tab.readonly.help"))
            }
            Text(tab.title.isEmpty ? String(localized: "editor.untitled") : tab.title)
                .font(isActive ? DS.Font.tabTitleActive : DS.Font.tabTitle)
                .foregroundStyle(isActive ? DS.Color.textPrimary : DS.Color.textSecondary)
                .lineLimit(1)
            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle())
                .frame(width: 16, height: 16)
                .help(Text("editor.tab.close.help"))
                .accessibilityLabel(Text("editor.tab.close.help"))
                // Reveal on hover (active tab keeps it visible so you can always close it).
                .opacity(isHovering || isActive ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: isHovering)
            }
        }
        .padding(.horizontal, DS.Spacing.sm + 2)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .fill(isActive ? DS.Color.bgCard : SwiftUI.Color.clear)
        )
        .overlay(alignment: .bottom) {
            if isActive {
                RoundedRectangle(cornerRadius: 1)
                    .fill(DS.Color.accent)
                    .frame(height: 2)
                    .padding(.horizontal, DS.Spacing.sm)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}

// MARK: - LabeledToolbarButtonStyle

/// A labeled (icon + short text) sibling of `IconButtonStyle` for the record toolbar's
/// 复制走 / 喂·路径 / 喂·内容 actions — the choice must be legible without hovering, so it
/// shows the text inline. Keeps the same hover-wash / press-dim / accent-on-active feel and
/// pill geometry as `IconButtonStyle`, just sized to its content instead of a fixed square.
struct LabeledToolbarButtonStyle: ButtonStyle {
    /// When `true`, renders in the accent (amber) color to signal an ON/active state.
    var isActive: Bool = false

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Note: callers that need a multi-line (title + caption) layout supply their own
            // `Label`/`VStack`; the style no longer forces `.titleAndIcon` so those compose.
            .font(DS.Font.controlLabel)
            .imageScale(.small)
            .foregroundStyle(isActive ? DS.Color.accent : DS.Color.textSecondary)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(isHovering ? DS.Color.hoverFill : SwiftUI.Color.clear)
                    .opacity(configuration.isPressed ? 0.55 : 1)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }
}
