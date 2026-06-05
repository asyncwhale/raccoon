import SwiftUI
import AppKit
import RaccoonCore

/// The main app shell. LEFT: the archive sidebar + full-text search (§9.1, §9.4).
/// RIGHT: the editor (Phase 2B) with read-only record tabs (§9.5). Toolbar carries the
/// pin toggle (§9.6) and a manual-sync button — icon-only, right-aligned.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    /// The resolved hosting window, captured via `WindowAccessor`. Held so toggling the
    /// pin binding can re-apply pin state to the live window.
    @State private var window: NSWindow?

    /// Drives the sidebar collapse/expand toggle (§9.1). `.all` shows the session list;
    /// `.detailOnly` hides it so the editor uses the full width. This is column-visibility
    /// only — NOT window pinning.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// A transient confirmation toast ("已复制" …) shared down the environment so the
    /// record actions can flash success feedback.
    @State private var toast = ToastCenter()

    /// Flip the sidebar between visible (`.all`) and hidden (`.detailOnly`).
    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
        }
    }

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: DS.Sidebar.minWidth,
                    ideal: DS.Sidebar.idealWidth,
                    max: DS.Sidebar.maxWidth
                )
        } detail: {
            detail
        }
        .environment(toast)
        .toastOverlay(toast)
        .frame(minWidth: 860, minHeight: 560)
        // Capture the real NSWindow so the pin toggle can act on it, and so we can adopt a
        // unified transparent titlebar (content extends under the chrome).
        .background(
            WindowAccessor { resolved in
                if window !== resolved {
                    window = resolved
                    configureWindow(resolved)
                    // Re-apply current pin state when the window first resolves, and install
                    // the Space-change/activation re-assert observer (so pinning survives
                    // switching into another app's full-screen Space). Idempotent.
                    PinController.setPinned(model.isPinned, resolved)
                    model.attachPinReasserter(to: resolved)
                }
            }
        )
        // When isPinned flips (from the toolbar or menu), push it to the live window.
        .onChange(of: model.isPinned) { _, pinned in
            if let window {
                PinController.setPinned(pinned, window)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                sidebarToggle
            }
            ToolbarItemGroup(placement: .primaryAction) {
                pinToggle(model: $model)
                syncControl
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        // ⌘\ toggles the session list. The key equivalent now lives on the app-level
        // command menu (single binding, discoverable in the menu bar); it posts
        // `.toggleSidebar`, which we observe here to flip column visibility.
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            toggleSidebar()
        }
    }

    /// Leading sidebar collapse/expand toggle. Column-visibility only (never touches the
    /// window level / pinning, which another component owns).
    private var sidebarToggle: some View {
        Button(action: toggleSidebar) {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(IconButtonStyle(isActive: columnVisibility != .detailOnly))
        .help(Text("contentview.sidebar.help"))
        .accessibilityLabel(Text("contentview.sidebar.help"))
    }

    // MARK: Window chrome

    /// Adopt a transparent, full-size-content titlebar so the sidebar vibrancy and content
    /// pane read as one calm surface (one tone-shift, no hard divider).
    private func configureWindow(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
    }

    // MARK: Sidebar (§9.1, §9.4)

    private var sidebar: some View {
        SidebarView()
            .toolbar(removing: .sidebarToggle)
    }

    // MARK: Detail — the editor (Phase 2B)

    private var detail: some View {
        EditorView()
    }

    // MARK: Toolbar items

    /// Pin toggle (§9.6). Bound to `model.isPinned`; the `.onChange` above pushes the
    /// new value to the live `NSWindow`. Icon-only, no text label.
    private func pinToggle(model: Bindable<AppModel>) -> some View {
        Button {
            model.wrappedValue.isPinned.toggle()
        } label: {
            Image(systemName: model.wrappedValue.isPinned ? "pin.fill" : "pin")
        }
        .buttonStyle(IconButtonStyle(isActive: model.wrappedValue.isPinned))
        .help(model.wrappedValue.isPinned ? Text("contentview.pin.off.help") : Text("contentview.pin.on.help"))
        .accessibilityLabel(model.wrappedValue.isPinned ? Text("contentview.pin.off.help") : Text("contentview.pin.on.help"))
    }

    @ViewBuilder
    private var syncControl: some View {
        if model.isSyncing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
        } else {
            Button {
                model.syncNow()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(IconButtonStyle())
            .help(Text("contentview.sync.help"))
            .accessibilityLabel(Text("contentview.sync.help"))
        }
    }
}
