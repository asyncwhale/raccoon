import AppKit

/// Applies "pin over full-screen" behavior to an `NSWindow`.
///
/// When pinned, the window is raised ABOVE other apps' full-screen windows and joins all
/// Spaces as a full-screen auxiliary, so it hovers over another app's full-screen Space
/// (§9.6). When unpinned, it returns to normal level and managed behavior.
///
/// macOS only applies level + collectionBehavior at the moment they're set; switching to
/// another app's full-screen Space can drop the window behind. `PinReasserter` (below)
/// re-applies pinning on Space/activation/app-switch changes so the window keeps floating.
@MainActor
enum PinController {
    /// The window level used while pinned. Single named constant so it's trivial to tune.
    ///
    /// Tradeoff notes for whoever tunes this:
    ///   - `.popUpMenuWindow` (previous value): well above `.floating`, but in practice it
    ///     can still sink behind another app's full-screen window in some macOS releases.
    ///   - `.screenSaver`: too aggressive — paints over the menu bar and other system UI.
    ///   - `.statusBar` (chosen): sits at the status-bar/menu-bar band. This is the level
    ///     used by many reliable over-fullscreen overlays. It floats above a foreground
    ///     app's full-screen window. The only cosmetic cost is that the window can overlap
    ///     the menu-bar region when positioned at the very top of the screen — acceptable
    ///     for a deliberately-pinned utility window, and far less intrusive than
    ///     `.screenSaver` / `.maximumWindow`.
    ///
    /// If on-device testing shows the menu-bar overlap is objectionable, drop back to
    /// `.popUpMenuWindow`; if it shows the window still sinks behind full-screen apps, try
    /// `NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))`.
    static let pinnedLevel: NSWindow.Level = .statusBar

    /// Collection behavior while pinned.
    ///
    /// `.stationary` was intentionally REMOVED. `.stationary` pins the window to a fixed
    /// screen position during Space transitions and, in combination with `.canJoinAllSpaces`,
    /// can actually fight the window's ability to ride onto another app's full-screen Space
    /// (the compositor treats it as "do not move with the Space switch"). The
    /// well-tested recipe for an overlay that must appear on top of *other* apps'
    /// full-screen Spaces is just `[.canJoinAllSpaces, .fullScreenAuxiliary]`:
    ///   - `.canJoinAllSpaces`  — the window shows on every Space, including full-screen ones.
    ///   - `.fullScreenAuxiliary` — lets the window coexist as an auxiliary over a
    ///     full-screen Space instead of being shoved to its own Space.
    static let pinnedCollectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .fullScreenAuxiliary]

    static func setPinned(_ pinned: Bool, _ window: NSWindow) {
        if pinned {
            window.level = pinnedLevel
            window.collectionBehavior = pinnedCollectionBehavior
            // Bring the window forward onto the current (possibly another app's full-screen)
            // Space without stealing key focus. `orderFrontRegardless` works even when the
            // app isn't active, which is exactly the case when a different app is full-screen.
            window.orderFrontRegardless()
        } else {
            window.level = .normal
            window.collectionBehavior = [.managed]
        }
    }
}

/// Re-asserts pin state on a window whenever the active Space changes, the frontmost app
/// changes, or this app's activation changes — because macOS only honors
/// `level`/`collectionBehavior` at the instant they're set, and the active-Space
/// notification does NOT reliably fire when *another* app enters or leaves its own
/// full-screen Space. The app-(de)activation notifications cover that gap.
///
/// Leak-safety: the observer blocks capture `[weak self]` and a single instance is retained
/// by `AppModel` for the app's lifetime, so there's no retain cycle and no duplicate
/// registration. The window target is a weak ref that can be swapped (see `updateWindow`)
/// if SwiftUI recreates the underlying `NSWindow`. We deliberately do NOT remove the
/// observers in `deinit` — that would require touching main-actor state from a nonisolated
/// deinit; the trade-off is harmless because this object lives as long as the app does.
@MainActor
final class PinReasserter {
    private weak var window: NSWindow?
    private let isPinned: () -> Bool
    private var observers: [any NSObjectProtocol] = []

    init(window: NSWindow, isPinned: @escaping () -> Bool) {
        self.window = window
        self.isPinned = isPinned

        let ws = NSWorkspace.shared.notificationCenter
        let dc = NotificationCenter.default

        // 1. Active-Space changes — primary trigger when WE switch into a full-screen Space.
        addWorkspace(ws, NSWorkspace.activeSpaceDidChangeNotification)
        // 2 & 3. Frontmost-app changes — the core fix. When the user switches to/from another
        // app that is full-screen, the active-Space notification often does NOT fire, but
        // these do, letting us re-raise above the now-frontmost full-screen window.
        addWorkspace(ws, NSWorkspace.didActivateApplicationNotification)
        addWorkspace(ws, NSWorkspace.didDeactivateApplicationNotification)
        // 4. This app becoming active (e.g. summoned back to front).
        addDefault(dc, NSApplication.didBecomeActiveNotification)
        // 5. This app resigning active (user clicked into the full-screen app) — reassert so
        // the pinned window stays on top as it loses focus.
        addDefault(dc, NSApplication.didResignActiveNotification)
        // 6. The window moving to a different screen — re-apply level/behavior there.
        let screenObs = dc.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassert() }
        }
        screenObserver = screenObs
        observers.append(screenObs)
    }

    /// Point the reasserter at a new live window (e.g. SwiftUI recreated the `NSWindow`).
    /// The `didChangeScreen` observer is bound to a specific window object, so it's
    /// rebuilt; the workspace/app observers are window-agnostic and left in place.
    func updateWindow(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // Rebuild the window-specific screen observer so it tracks the new window.
        if let last = screenObserver {
            NotificationCenter.default.removeObserver(last)
            observers.removeAll { ($0 as AnyObject) === (last as AnyObject) }
        }
        let obs = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassert() }
        }
        screenObserver = obs
        observers.append(obs)
    }

    /// Tracks the window-specific screen observer so `updateWindow` can replace just it.
    private var screenObserver: (any NSObjectProtocol)?

    private func addWorkspace(_ center: NotificationCenter, _ name: Notification.Name) {
        observers.append(
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reassert() }
            }
        )
    }

    private func addDefault(_ center: NotificationCenter, _ name: Notification.Name) {
        observers.append(
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reassert() }
            }
        )
    }

    /// Re-apply pinning to the live window — only when still pinned and the window is alive.
    /// `setPinned(true,)` calls `orderFrontRegardless()`, raising it onto the current Space.
    private func reassert() {
        guard isPinned(), let window else { return }
        PinController.setPinned(true, window)
    }
}
