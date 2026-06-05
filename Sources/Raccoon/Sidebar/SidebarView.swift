import SwiftUI
import RaccoonCore

// MARK: - Compact relative timestamp

private extension Date {
    /// A terse, fixed-width-ish relative label that never truncates in the row's date column
    /// ("28s", "4h", "1d", "yesterday", "3w", "2mo"). Falls back to the named relative format
    /// only for "now"/future edge cases.
    var compactRelative: String {
        let seconds = Date().timeIntervalSince(self)
        guard seconds >= 0 else { return "now" }
        let minute = 60.0, hour = 3600.0, day = 86_400.0, week = 604_800.0, month = 2_592_000.0, year = 31_536_000.0
        switch seconds {
        case ..<minute:  return "\(Int(seconds))s"
        case ..<hour:    return "\(Int(seconds / minute))m"
        case ..<day:     return "\(Int(seconds / hour))h"
        case ..<(2 * day): return "yesterday"
        case ..<week:    return "\(Int(seconds / day))d"
        case ..<month:   return "\(Int(seconds / week))w"
        case ..<year:    return "\(Int(seconds / month))mo"
        default:         return "\(Int(seconds / year))y"
        }
    }
}

// MARK: - RecordSummary + selection key

private extension RecordSummary {
    /// A stable, parameter-free identity for `List`/selection derived from the same fields
    /// that form the canonical filename (tool + startedAt + sessionID), so it is unique per
    /// archived session and survives `records` reloads (e.g. after a star toggle).
    var recordKey: String {
        "\(tool.rawValue)|\(startedAt.timeIntervalSince1970)|\(sessionID)"
    }
}

// MARK: - Tool → SF Symbol badge glyph

extension Tool {
    /// One consistent monochrome SF Symbol per source (rendered in the ToolBadge capsule).
    var badgeGlyph: String {
        switch self {
        case .claudeCode: return "terminal"
        case .codex:      return "chevron.left.forwardslash.chevron.right"
        case .gemini:     return "sparkle"
        case .cursor:     return "cursorarrow.rays"
        }
    }
}

/// The left pane (§9.1, §9.4): a full-text search field over the top, then either the full
/// archive list (when the query is empty) or the search results (when it isn't). Activating a
/// row opens the record as a read-only tab in the editor.
///
/// Selection model: a single click selects (highlights with the amber pill) AND opens the row
/// (Mail.app style). We use a `ScrollView` + `LazyVStack` (NOT `List(selection:)`) because
/// `List(.sidebar)` on macOS always paints its own SYSTEM BLUE selection bar that `.tint(...)`
/// can't suppress, stacking over our amber pill. So each row's `.onTapGesture` sets
/// `selectedPath`, whose `.onChange` fires `openSelectedKey` — the single, authoritative open
/// path. Return from the search field also opens the current selection. Selection is drawn
/// purely from `isSelected` (the amber pill), so there is no blue bar at all.
/// Tradeoff vs. List: keyboard arrow-key row navigation is not available.
/// The selected row's stable key is the archive `recordKey` (or, in search mode, the absolute
/// `.md` path string) — so selection survives the switch between the two list modes.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// Bottom-center toast (injected at the split-view root in `ContentView`).
    /// Used to surface the "Moved to Trash · Undo" affordance after a trash.
    @Environment(ToastCenter.self) private var toast

    /// The live query text. Empty → archive list; non-empty → search results.
    @State private var query: String = ""

    /// Debounced search results for the current `query`. Recomputed ~250ms after typing stops.
    @State private var hits: [SearchHit] = []

    /// The selected row, keyed by absolute `.md` path. Drives single-click highlight and the
    /// Return-to-open shortcut.
    @State private var selectedPath: String?

    /// The record pending a "move to trash" confirmation. Non-nil drives the
    /// confirmation dialog; cleared on confirm/cancel.
    @State private var pendingTrash: RecordSummary?

    /// Active scope filter (tool chip + starred toggle). Applied to BOTH the archive list
    /// (`model.records`) and the search hits, so at 200+ cross-tool sessions the list can be
    /// narrowed to one tool and/or only starred records.
    @State private var filter = SidebarFilter()

    /// Drives ⌘F "Find in Archive": the app-level command posts `.focusSidebarSearch`, and
    /// the observer below flips this to move keyboard focus into the search field.
    @FocusState private var searchFieldFocused: Bool

    /// Keyboard navigation focus for the row list (↑/↓). When focused, arrow keys move
    /// `selectedPath` among the currently-visible rows and Return opens it.
    @FocusState private var listFocused: Bool

    /// The records after applying the scope `filter` — the archive-mode list source.
    private var filteredRecords: [RecordSummary] {
        filter.apply(to: model.records)
    }

    /// The hits after applying the scope `filter` — the search-mode list source.
    private var filteredHits: [SearchHit] {
        filter.apply(to: hits)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            filterChips
            content
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            Text("trash.confirm.title"),
            isPresented: Binding(
                get: { pendingTrash != nil },
                set: { if !$0 { pendingTrash = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingTrash
        ) { summary in
            Button("trash.move", role: .destructive) {
                model.trashRecord(path: summary.path)
                pendingTrash = nil
                // Surface a native macOS-style undo: the trash toast carries an
                // "Undo" button that restores the record from _trash and confirms.
                toast.show(
                    String(localized: "sidebar.trash.toast"),
                    actionTitle: String(localized: "sidebar.trash.undo")
                ) {
                    model.undoLastTrash()
                    toast.show(String(localized: "sidebar.trash.restored"))
                }
            }
            Button("trash.cancel", role: .cancel) { pendingTrash = nil }
        } message: { _ in
            Text("trash.confirm.message")
        }
        // NOTE: do NOT paint our own VisualEffectBackground(material: .sidebar) here —
        // NavigationSplitView already supplies the leading column's `.sidebar` vibrancy,
        // so applying it twice stacks the material and produces a visible seam at the
        // transparent-titlebar / chrome boundary (the "one calm tone-shift" goal).
        // Clear the transparent titlebar / traffic lights so the search field never tucks
        // under them.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: DS.Sidebar.titlebarInset)
        }
        // Debounced search: re-run whenever the query changes, cancelling the in-flight wait.
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                hits = []
                return
            }
            // Debounce ~250ms; if `query` changes again this task is cancelled and the sleep
            // throws, so we skip the stale search.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            hits = model.search(trimmed)
        }
        // Single click selects AND opens (Mail.app style): the List updates `selectedPath`,
        // and this is the ONLY place that turns a selection into an open record. No competing
        // row tap gestures. Guards against re-opening the already-active record.
        .onChange(of: selectedPath) { _, newKey in
            openSelectedKey(newKey)
        }
        // ⌘F (Find in Archive) — the app-level CommandMenu posts this; move focus into the
        // search field. NotificationCenter keeps the command decoupled from this view's state.
        .onReceive(NotificationCenter.default.publisher(for: .focusSidebarSearch)) { _ in
            searchFieldFocused = true
        }
    }

    /// Open the record identified by the newly-selected list key. In archive mode the key is
    /// the `recordKey`; in search mode it is the absolute `.md` path. No-ops on nil or when the
    /// active editor tab is already showing that record (so arrow-key navigation that lands back
    /// on the open record doesn't needlessly re-open it).
    private func openSelectedKey(_ key: String?) {
        guard let key else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard let summary = model.records.first(where: { $0.recordKey == key }) else { return }
            guard model.editor.activeTab?.recordPath != summary.path else { return }
            model.openRecord(path: summary.path)
        } else {
            let url = URL(fileURLWithPath: key)
            guard model.editor.activeTab?.recordPath != url else { return }
            model.openRecord(path: url)
        }
    }

    // MARK: Search field

    private var searchField: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Color.textTertiary)
                .accessibilityHidden(true)
            TextField(text: $query, prompt: Text("sidebar.search.prompt")) { EmptyView() }
                .textFieldStyle(.plain)
                .font(DS.Font.searchField)
                .foregroundStyle(DS.Color.textPrimary)
                .onSubmit(openSelected)
                .focused($searchFieldFocused)
                .accessibilityLabel(Text("sidebar.search.prompt"))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(IconButtonStyle())
                .help(Text("sidebar.search.clear.help"))
                .accessibilityLabel(Text("sidebar.search.clear.help"))
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                .fill(DS.Color.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                .strokeBorder(DS.Color.separator, lineWidth: 1)
        )
        .padding(.horizontal, DS.Sidebar.gutter)
        .padding(.top, DS.Spacing.xs)
        .padding(.bottom, DS.Spacing.sm)
    }

    // MARK: Filter chips (scope: tool + starred)

    /// A single horizontal row of scope chips above the list: one per tool (Claude Code /
    /// Codex / Gemini / Cursor) plus a "starred" toggle. Tapping a tool chip narrows the list
    /// to that tool (tap again to clear); the star chip toggles starred-only. Applies in BOTH
    /// archive-list and search modes via `filteredRecords` / `filteredHits`.
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(Tool.allCases, id: \.self) { tool in
                    FilterChip(
                        glyph: tool.badgeGlyph,
                        label: tool.label,
                        isOn: filter.tool == tool
                    ) {
                        filter.tool = (filter.tool == tool) ? nil : tool
                    }
                    .accessibilityLabel(Text("sidebar.filter.tool.a11y \(tool.label)"))
                }
                FilterChip(
                    glyph: filter.starredOnly ? "star.fill" : "star",
                    label: String(localized: "sidebar.filter.starred"),
                    isOn: filter.starredOnly
                ) {
                    filter.starredOnly.toggle()
                }
                .accessibilityLabel(Text("sidebar.filter.starred.a11y"))
            }
            .padding(.horizontal, DS.Sidebar.gutter)
            .padding(.bottom, DS.Spacing.sm)
        }
    }

    // MARK: Content (archive list vs. search results)

    @ViewBuilder
    private var content: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            archiveList
        } else if filteredHits.isEmpty {
            EmptyStateView(
                headline: String(localized: "sidebar.empty.nomatch.headline"),
                subline: String(localized: "sidebar.empty.nomatch.subline \(trimmed)"),
                markSize: 40
            )
        } else {
            searchList
        }
    }

    /// All archived sessions (post-`filter`), most-recent-first (records are pre-sorted by
    /// `lastActiveAt`).
    private var archiveList: some View {
        Group {
            if model.records.isEmpty {
                EmptyStateView(
                    headline: model.isSyncing
                        ? String(localized: "sidebar.empty.syncing.headline")
                        : String(localized: "sidebar.empty.none.headline"),
                    subline: model.isSyncing
                        ? String(localized: "sidebar.empty.syncing.subline")
                        : String(localized: "sidebar.empty.none.subline"),
                    hint: model.isSyncing ? nil : String(localized: "sidebar.empty.none.hint")
                )
            } else if filteredRecords.isEmpty {
                // The archive is non-empty, but the active scope filter excludes everything.
                EmptyStateView(
                    headline: String(localized: "sidebar.empty.filtered.headline"),
                    subline: String(localized: "sidebar.empty.filtered.subline"),
                    markSize: 40
                )
            } else {
                // NOTE: We deliberately do NOT use `List(selection:)` here. On macOS
                // `List(.sidebar)` always paints its own full-bleed SYSTEM BLUE selection bar
                // (confirmed live), which `.tint(...)` does NOT suppress — it stacked on top of
                // our amber pill. So selection is drawn ENTIRELY by us: the amber `.selectionPill`
                // keyed off `isSelected`, with NO system highlight in sight.
                // Single-click still both selects AND opens: the row's `.onTapGesture` sets
                // `selectedPath`, whose `.onChange` fires `openSelectedKey` (same open path as
                // before). Keyboard ↑/↓ navigation is restored WITHOUT `List` via a focusable
                // scroll container + `.onKeyPress` (see `keyboardNavigable`).
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                ForEach(filteredRecords, id: \.recordKey) { summary in
                                    let isSelected = selectedPath == summary.recordKey
                                    RecordRow(
                                        summary: summary,
                                        isSelected: isSelected,
                                        onToggleStar: { model.setStarred(path: summary.path, $0) }
                                    )
                                        .padding(.horizontal, DS.Sidebar.pillInset)
                                        .padding(.vertical, 1)
                                        .background(rowSelectionPill(isSelected))
                                        .contentShape(Rectangle())
                                        .id(summary.recordKey)
                                        .onTapGesture { selectRow(summary.recordKey) }
                                        // Right-click → move this archived record to the trash.
                                        // A confirmation dialog (driven by `pendingTrash`) gates the
                                        // destructive move; the file stays recoverable in `_trash/`.
                                        .contextMenu {
                                            Button("trash.move", role: .destructive) {
                                                pendingTrash = summary
                                            }
                                        }
                                }
                            } header: {
                                sectionHeader(String(localized: "sidebar.section.archive"))
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .modifier(keyboardNavigable(keys: filteredRecords.map(\.recordKey), proxy: proxy))
                }
            }
        }
    }

    /// Full-text search hits with highlighted snippets.
    ///
    /// Same custom-selection model as `archiveList` (see its note): a ScrollView+LazyVStack with
    /// a tap-driven amber pill, NOT `List(selection:)` — so no macOS system-blue selection bar.
    private var searchList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(filteredHits, id: \.recordPath) { hit in
                            let isSelected = selectedPath == hit.recordPath
                            SearchRow(hit: hit, isSelected: isSelected)
                                .padding(.horizontal, DS.Sidebar.pillInset)
                                .padding(.vertical, 1)
                                .background(rowSelectionPill(isSelected))
                                .contentShape(Rectangle())
                                .id(hit.recordPath)
                                .onTapGesture { selectRow(hit.recordPath) }
                        }
                    } header: {
                        sectionHeader(String(localized: "sidebar.section.searchResults"))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .modifier(keyboardNavigable(keys: filteredHits.map(\.recordPath), proxy: proxy))
        }
    }

    /// Set the selected key, firing `.onChange(of: selectedPath)` → `openSelectedKey` so a single
    /// click both selects (amber pill) and opens the record. Tapping the already-selected row
    /// re-asserts the value (a no-op for `onChange`, which only fires on change) — the record is
    /// already open, so that's correct.
    private func selectRow(_ key: String) {
        selectedPath = key
    }

    // MARK: Keyboard arrow-key navigation (no `List`)

    /// Makes the row scroll container focusable and wires ↑/↓ to move `selectedPath` among the
    /// currently-visible row `keys` (in display order), scrolling the focused row into view via
    /// the enclosing `ScrollViewReader` `proxy`. Return/Enter opens the selection (`openSelected`).
    /// This restores the row navigation that the `List` → `ScrollView`+`LazyVStack` swap lost,
    /// WITHOUT bringing back `List`'s system-blue selection bar — selection stays the amber pill.
    private func keyboardNavigable(keys: [String], proxy: ScrollViewProxy) -> some ViewModifier {
        KeyboardNavigable(
            keys: keys,
            isFocused: $listFocused,
            move: { direction in moveSelection(direction, in: keys, proxy: proxy) },
            open: openSelected
        )
    }

    /// Advance `selectedPath` by one row in `direction` (+1 down / -1 up) within `keys`, clamping
    /// at the ends. With no current selection, ↓ selects the first row and ↑ the last. Scrolls the
    /// newly-selected row into view. Setting `selectedPath` also opens it (the `.onChange` path),
    /// matching single-click-opens behaviour.
    private func moveSelection(_ direction: Int, in keys: [String], proxy: ScrollViewProxy) {
        guard !keys.isEmpty else { return }
        let nextIndex: Int
        if let current = selectedPath, let idx = keys.firstIndex(of: current) {
            nextIndex = min(max(idx + direction, 0), keys.count - 1)
        } else {
            nextIndex = direction > 0 ? 0 : keys.count - 1
        }
        let key = keys[nextIndex]
        selectedPath = key
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(key, anchor: .center)
        }
    }

    /// The inset amber selection pill drawn behind a row when selected — the ONLY selection
    /// affordance (no system bar). Matches the geometry the old `.selectionPill` used.
    @ViewBuilder
    private func rowSelectionPill(_ isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
            .fill(isSelected ? DS.Color.selectionFill : SwiftUI.Color.clear)
            .padding(.horizontal, DS.Sidebar.pillInset)
    }

    /// A pinned section header styled like the prior List section headers, with a sidebar-tinted
    /// backdrop so pinned rows don't show content scrolling through behind the title.
    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title).dsSectionHeader()
            Spacer()
        }
        .padding(.leading, DS.Spacing.xs + DS.Sidebar.pillInset)
        .padding(.trailing, DS.Spacing.md)
        .padding(.top, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.xs)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DS.Spacing.sm) {
            if let initError = model.initError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.Color.error)
                Text(initError)
                    .font(DS.Font.footer)
                    .foregroundStyle(DS.Color.error)
                    .lineLimit(2)
            } else {
                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    // Archive mode: show the filtered count, and the total when filtering narrows it.
                    if filter.isActive {
                        Text("\(filteredRecords.count) / \(model.records.count) sessions")
                            .font(DS.Font.footer)
                            .foregroundStyle(DS.Color.textTertiary)
                    } else {
                        Text("\(model.records.count) sessions")
                            .font(DS.Font.footer)
                            .foregroundStyle(DS.Color.textTertiary)
                    }
                } else {
                    Text("\(filteredHits.count) / \(model.records.count) sessions")
                        .font(DS.Font.footer)
                        .foregroundStyle(DS.Color.textTertiary)
                }
            }
            Spacer()
            if model.isSyncing {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 28)
        .padding(.horizontal, DS.Spacing.md)
    }

    // MARK: Row activation

    /// Open an archived record by the path embedded in its summary.
    private func open(_ summary: RecordSummary) {
        selectedPath = summary.recordKey
        model.openRecord(path: summary.path)
    }

    /// Open whatever row is currently selected (Return key / field submit).
    private func openSelected() {
        guard let key = selectedPath else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let summary = model.records.first(where: { $0.recordKey == key }) {
                open(summary)
            }
        } else {
            // In search mode the key IS the absolute path.
            model.openRecord(path: URL(fileURLWithPath: key))
        }
    }
}

// MARK: - StarButton

/// A small star toggle for a sidebar row's leading slot: filled amber when starred, a quiet
/// hollow outline when offered on hover. Borderless, sized to the 13×18 leading slot so titles
/// stay aligned. The localized tooltip / a11y label flips with state.
private struct StarButton: View {
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: filled ? "star.fill" : "star")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(filled ? DS.Color.accent : DS.Color.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(filled ? "sidebar.row.unstar.help" : "sidebar.row.star.help"))
        .accessibilityLabel(Text(filled ? "sidebar.row.unstar.help" : "sidebar.row.star.help"))
    }
}

// MARK: - RecordRow

/// One row in the archive list (Raycast anatomy): leading star (when starred) → title →
/// project · tool badge subtitle → right-aligned mono date. The inset amber selection pill is
/// drawn behind the row by the parent (keyed off `isSelected`); this view bolds the title
/// when selected.
private struct RecordRow: View {
    let summary: RecordSummary
    /// `true` when this row is the selected one — drives the amber pill (supplied via
    /// `.selectionPill`), the Medium title weight, and the accent title/star tint.
    var isSelected: Bool = false
    /// Toggle the record's `starred` flag from the sidebar (hover star button). Receives the
    /// NEW value.
    var onToggleStar: (Bool) -> Void = { _ in }
    /// Whether the pointer is over this row — reveals the star button when the record isn't
    /// already starred (a starred record always shows its filled star).
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            // Leading star slot (fixed width so titles align whether starred or not).
            // - Starred: always shows the filled amber star; clicking unstars.
            // - Not starred: shows a hollow star ONLY on hover; clicking stars.
            ZStack {
                if summary.starred {
                    StarButton(filled: true) { onToggleStar(false) }
                } else if isHovering {
                    StarButton(filled: false) { onToggleStar(true) }
                }
            }
            .frame(width: 13, height: 18)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(summary.title)
                    .font(isSelected ? DS.Font.rowTitleSelected : DS.Font.rowTitle)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 18, alignment: .leading)
                HStack(spacing: DS.Spacing.xs) {
                    // The tool name is a small KNOWN enum — it must NEVER mid-truncate, so it
                    // takes intrinsic width and layout priority; the project name takes the
                    // remaining space and tail-truncates.
                    ToolBadge(tool: summary.tool)
                        .fixedSize()
                        .layoutPriority(1)
                    if let project = summary.project, !project.isEmpty {
                        Text(project)
                            .font(DS.Font.rowSubtitle)
                            .foregroundStyle(DS.Color.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Spacer(minLength: DS.Spacing.xs)

            // Top-aligned to line 1 (the title), compact relative format so it never truncates.
            Text(summary.lastActiveAt.compactRelative)
                .font(DS.Font.rowDate)
                .foregroundStyle(DS.Color.textTertiary)
                .lineLimit(1)
                .fixedSize()
                .frame(height: 18, alignment: .center)
        }
        // Small leading inset so rows use the full sidebar width (Raycast/Linear density)
        // instead of the wide empty left gutter the default sidebar style leaves.
        .padding(.leading, DS.Spacing.xs + 2)
        .padding(.trailing, DS.Spacing.xs)
        .padding(.vertical, DS.Spacing.xs + 1)
        // Hover wash only on non-selected rows (the pill owns the selected look).
        .modifier(RowHover(active: !isSelected))
        .onHover { isHovering = $0 }
        // One VoiceOver element per row: a button reading "title, tool, relative date",
        // marked selected when this is the active row. The inner labels/glyphs are merged.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("a11y.row.label \(summary.title) \(summary.tool.label) \(summary.lastActiveAt.compactRelative)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - SearchRow

/// One row in the search results: title, 2-line snippet, tool badge + date.
private struct SearchRow: View {
    let hit: SearchHit
    /// `true` when this row is the selected one — drives the amber pill (supplied via
    /// `.selectionPill`), the Medium title weight, and the accent title tint.
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            ZStack {
                if hit.starred {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Color.accent)
                }
            }
            .frame(width: 13)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DS.Spacing.sm) {
                    Text(hit.title)
                        .font(isSelected ? DS.Font.rowTitleSelected : DS.Font.rowTitle)
                        .foregroundStyle(DS.Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: DS.Spacing.xs)
                    Text(hit.lastActiveAt.compactRelative)
                        .font(DS.Font.rowDate)
                        .foregroundStyle(DS.Color.textTertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                highlightedSnippet
                    .font(DS.Font.snippet)
                    .foregroundStyle(DS.Color.textSecondary)
                    .lineSpacing(3)
                    .lineLimit(2)
                ToolBadge(tool: hit.tool)
            }
        }
        .padding(.leading, DS.Spacing.xs)
        .padding(.trailing, DS.Spacing.xs)
        .padding(.vertical, DS.Spacing.sm)
        // Hover wash only on non-selected rows (the pill owns the selected look).
        .modifier(RowHover(active: !isSelected))
        // One VoiceOver element per search hit: a button reading "title, tool, relative date".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("a11y.row.label \(hit.title) \(hit.tool.label) \(hit.lastActiveAt.compactRelative)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Renders the snippet, bolding the matched runs the index wrapped in `«` … `»`.
    private var highlightedSnippet: Text {
        var result = Text("")
        var rest = Substring(hit.snippet)
        while let open = rest.firstIndex(of: "«") {
            // Text before the marker is plain.
            result = result + Text(rest[rest.startIndex..<open])
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "»") {
                let matched = rest[afterOpen..<close]
                result = result + Text(matched).bold().foregroundColor(DS.Color.textPrimary)
                rest = rest[rest.index(after: close)...]
            } else {
                // Unbalanced marker; emit the remainder verbatim and stop.
                rest = rest[afterOpen...]
                break
            }
        }
        return result + Text(rest)
    }
}

// MARK: - Hover

/// A 120ms hover wash for non-selected rows (the selection pill owns the selected look).
/// Wraps the already-defined `HoverHighlight`, insetting to match the pill geometry so the
/// wash floats Raycast-style rather than filling the row edge-to-edge.
private struct RowHover: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.hoverHighlight(cornerRadius: DS.Radius.pill, inset: DS.Sidebar.pillInset)
        } else {
            content
        }
    }
}

// MARK: - ToolBadge

/// A small monochrome capsule: tool glyph + label, single consistent weight across all badges.
struct ToolBadge: View {
    let tool: Tool

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: tool.badgeGlyph)
                .font(DS.Font.badgeGlyph)
            Text(tool.label)
                .font(DS.Font.badgeLabel)
                .lineLimit(1)
                // Known small enum — never allow the tool name to be mid-truncated.
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(DS.Color.textSecondary)
        .padding(.horizontal, DS.Spacing.xs + 2)
        .frame(height: 18)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                .fill(DS.Color.chipFill)
        )
    }
}

// MARK: - SidebarFilter

/// The sidebar's scope filter: an optional tool constraint plus a starred-only toggle. Pure
/// value type with `apply(to:)` overloads that narrow the archive `RecordSummary` list and the
/// `SearchHit` list identically, so the same chips drive both list modes.
private struct SidebarFilter: Equatable {
    /// When non-nil, only rows from this tool are shown.
    var tool: Tool?
    /// When true, only starred rows are shown.
    var starredOnly = false

    /// Whether any constraint is active (used to vary the "nothing matches" empty state).
    var isActive: Bool { tool != nil || starredOnly }

    func apply(to records: [RecordSummary]) -> [RecordSummary] {
        records.filter { summary in
            (tool == nil || summary.tool == tool) && (!starredOnly || summary.starred)
        }
    }

    func apply(to hits: [SearchHit]) -> [SearchHit] {
        hits.filter { hit in
            (tool == nil || hit.tool == tool) && (!starredOnly || hit.starred)
        }
    }
}

// MARK: - FilterChip

/// A small toggleable scope chip (glyph + label) for the filter bar. Amber-tinted fill + text
/// when on; quiet chip fill when off. Single consistent height with the tool badges.
private struct FilterChip: View {
    let glyph: String
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: glyph)
                    .font(DS.Font.badgeGlyph)
                Text(label)
                    .font(DS.Font.badgeLabel)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isOn ? DS.Color.accent : DS.Color.textSecondary)
            .padding(.horizontal, DS.Spacing.xs + 2)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(isOn ? DS.Color.selectionFill : DS.Color.chipFill)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - KeyboardNavigable

/// A `ViewModifier` that makes a scroll container focusable and maps ↑/↓ to row navigation and
/// Return to "open", without `List`. Focus is gained on appear (and reasserted when the visible
/// `keys` change) so the arrow keys work as soon as the list shows. The amber-pill selection is
/// untouched — this only moves `selectedPath` (via the `move` closure) and scrolls.
private struct KeyboardNavigable: ViewModifier {
    let keys: [String]
    @FocusState.Binding var isFocused: Bool
    let move: (Int) -> Void
    let open: () -> Void

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.return) { open(); return .handled }
            .onAppear { isFocused = true }
    }
}
