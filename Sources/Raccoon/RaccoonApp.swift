import SwiftUI
import AppKit

@main
struct RaccoonApp: App {
    @State private var model = AppModel()

    /// Stable identity for the main window so "Show window" can reopen it after it's closed.
    private static let mainWindowID = "main"

    /// The named-image key under which the self-drawn raccoon-mask template glyph is
    /// registered (see `registerMenuBarIcon()`). `MenuBarExtra(_:image:)` resolves images
    /// by name through `NSImage(named:)`, so registering a template `NSImage` under this
    /// name lets the status item tint natively like an SF Symbol — no asset catalog needed.
    private static let menuBarIconName = "RaccoonMaskTemplate"

    init() {
        Self.registerMenuBarIcon()
    }

    /// Rasterize `RaccoonMaskShape` into a small monochrome template `NSImage` and register
    /// it in the shared `NSImage` named-image cache. `isTemplate = true` makes AppKit tint it
    /// for the menu bar (black on light, white on dark). Idempotent: re-registering replaces
    /// the prior entry. The drawing is pure CoreGraphics (even-odd fill punches the eyes out),
    /// so it doesn't depend on SwiftUI rendering at status-item-creation time.
    private static func registerMenuBarIcon() {
        // 18pt is the conventional menu-bar glyph size; AppKit scales for Retina.
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let mask = RaccoonMaskShape().path(in: rect)
            let cg = mask.cgPath
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(cg)
            // Template images are tinted by AppKit; the fill color here is just the alpha mask.
            NSColor.black.setFill()
            ctx.fillPath(using: .evenOdd)
            return true
        }
        image.isTemplate = true
        image.setName(menuBarIconName)
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            // `RootView` wraps ContentView so the first-run onboarding sheet can be presented
            // as an overlay on the main window's root WITHOUT disturbing the scene structure,
            // the menu-bar extra, the Settings scene, or the pin/window logic (all untouched).
            RootView()
                .environment(model)
                .task { model.start() }
                // The single app-root accent tint (amber from AccentColor). Every control's
                // focus ring / .accentColor inherits this; views never re-declare `.tint`.
                .tint(DS.Color.accent)
        }
        .defaultSize(width: 1000, height: 680)
        .commands {
            RaccoonCommands(model: model)
        }

        // Secondary menu-bar presence. The Dock icon + main window stay primary
        // (no LSUIElement); this keeps the app alive when the window is closed and
        // offers quick actions. The status icon is a monochrome template glyph
        // (Mac convention) — the self-drawn raccoon bandit mask, rasterized to a
        // template `NSImage` so it tints natively (light/dark menu bar) like an SF Symbol.
        MenuBarExtra("Raccoon", image: Self.menuBarIconName) {
            MenuBarContent(model: model, mainWindowID: Self.mainWindowID)
        }
        .menuBarExtraStyle(.menu)

        // Standard Settings scene (⌘,). Shares the same AppModel so edits persist via
        // AppModel.saveSettings() and feed the next sync/cleanup.
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Raccoon's app-level command menu: localized items with key equivalents that drive the
/// SAME actions the in-app buttons do. New-note and pin act on the shared `AppModel`
/// directly; the editor/sidebar-bound actions post notifications the owning views observe
/// (so command wiring stays out of those views' private state).
///
/// Shortcut map (none collide; ⌃⌘R is reserved for the global summon hotkey, not here):
///   ⌘N  New Note        ⌘F  Find in Archive   ⌘E  Toggle Preview
///   ⌘⇧K Clean to Plain  ⌘⌥P Toggle Pin        ⌘\  Toggle Sidebar
private struct RaccoonCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu(Text("menu.commands.title")) {
            Button {
                model.editor.newTab()
            } label: {
                Text("menu.newNote")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button {
                NotificationCenter.default.post(name: .focusSidebarSearch, object: nil)
            } label: {
                Text("menu.findInArchive")
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider()

            Button {
                NotificationCenter.default.post(name: .toggleEditorPreview, object: nil)
            } label: {
                Text("menu.togglePreview")
            }
            .keyboardShortcut("e", modifiers: .command)

            Button {
                NotificationCenter.default.post(name: .cleanEditorContent, object: nil)
            } label: {
                Text("menu.cleanContent")
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])

            Divider()

            Button {
                model.isPinned.toggle()
            } label: {
                Text("menu.togglePin")
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Button {
                NotificationCenter.default.post(name: .toggleSidebar, object: nil)
            } label: {
                Text("menu.toggleSidebar")
            }
            .keyboardShortcut("\\", modifiers: .command)
        }
    }
}

/// The main window's root: `ContentView` plus a one-time first-run onboarding sheet.
///
/// The sheet is gated by `@AppStorage("hasSeenOnboarding_v1")` so it appears only on the
/// very first launch and never again; tapping "开始使用" sets the flag to `true`. Presenting
/// it as a `.sheet` here keeps the existing scene/menu-bar/Settings/pin/window logic fully
/// intact — this wrapper only adds an overlay on the content root.
private struct RootView: View {
    /// First-run flag. Defaults to `false` (sheet shows once), flips to `true` on dismiss.
    @AppStorage("hasSeenOnboarding_v1") private var hasSeenOnboarding = false

    var body: some View {
        ContentView()
            .sheet(isPresented: showOnboarding) {
                OnboardingView { hasSeenOnboarding = true }
            }
    }

    /// `.sheet` needs a `Binding<Bool>`; present while onboarding is unseen, and treat any
    /// dismissal (button or otherwise) as "seen" so it can never re-appear.
    private var showOnboarding: Binding<Bool> {
        Binding(
            get: { !hasSeenOnboarding },
            set: { stillShowing in if !stillShowing { hasSeenOnboarding = true } }
        )
    }
}

/// Contents of the menu-bar dropdown. Split into its own view so it can pull the
/// environment actions (`openWindow`) that a `Scene` builder can't access directly.
private struct MenuBarContent: View {
    let model: AppModel
    let mainWindowID: String

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Header row (app name + version), non-interactive.
        Text("Raccoon \(appVersion)")

        Divider()

        Button {
            model.syncNow()
        } label: {
            Label("menubar.syncNow", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(model.isSyncing)

        Button {
            summonMainWindow()
        } label: {
            Label("menubar.showWindow", systemImage: "macwindow")
        }

        // Opens the standard Settings scene (⌘,). Requires the `Settings { … }` scene
        // declared above; macOS 14+ exposes `SettingsLink` for menu/menu-bar use.
        SettingsLink {
            Label("menubar.settings", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("menubar.quit", systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    /// Reopen/raise the main window and bring the app forward, even if the window was
    /// closed (the app stays alive via MenuBarExtra). `openWindow` re-creates the window
    /// if it was fully closed; `summonWindow` fronts it.
    private func summonMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: mainWindowID)
        model.summonWindow()
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }
}
