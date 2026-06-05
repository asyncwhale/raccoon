import SwiftUI
import AppKit
import RaccoonCore

/// Raccoon's design system — the single foundation every view consumes (`DS.*`).
///
/// Philosophy (the "raccoon" metaphor): the UI is a near-monochrome graphite ramp (the
/// fur), the recessed sidebar/selection tone is the "mask," and the ONE rationed chromatic
/// color is a warm AMBER (the eye-shine), supplied via the asset-catalog `AccentColor` so
/// the system tint, focus rings, and selection inherit it for free.
///
/// Colors map to macOS SEMANTIC `NSColor`s wherever possible (not raw hex) so dark mode,
/// vibrancy, and desktop tinting work automatically; only the two brand colors
/// (`AccentColor`, `RaccoonMask`) and a couple of unavoidable status hues are literal.
enum DS {

    // MARK: - Color

    enum Color {
        // Brand — the only chromatic color in the chrome, from the asset catalog so the
        // whole system (focus rings, .tint) resolves to the same amber.
        static let accent = SwiftUI.Color.accentColor
        /// The recessed sidebar / "mask" base tone (light #EFEEEB / dark #161513).
        static let mask = SwiftUI.Color("RaccoonMask")

        // Surfaces — semantic so vibrancy + desktop tint apply.
        /// Content pane background (warm off-white / warm near-black).
        static let bgWindow = SwiftUI.Color(nsColor: .windowBackgroundColor)
        /// Recessed sidebar base — uses the mask tone (NSVisualEffectView .sidebar backs it).
        static let bgSidebar = mask
        /// Elevated card / record block. Light: pure white lift; dark: lighter-than-window.
        static let bgCard = SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(srgbRed: 0x26 / 255, green: 0x24 / 255, blue: 0x1F / 255, alpha: 1)
                              : NSColor.white
        })
        /// Hairline border for elevated cards (record/message blocks). In LIGHT mode the pure
        /// white card over warm off-white window reads flat with only a separator gap, so a
        /// faint warm-grey edge gives one subtle layer of depth (Things/Linear restraint). In
        /// DARK mode the card is already separated by luminance, so the border is barely-there
        /// (a hint of warm light) to avoid a hard outline. Use at 0.5pt.
        static let cardBorder = SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor.white.withAlphaComponent(0.05)
                              : NSColor.black.withAlphaComponent(0.07)
        })

        // Text tiers — semantic label colors (warm-tinted by the window material).
        //
        // WCAG note: the macOS `.tertiaryLabelColor` (~26% in light, ~25% in dark) is the
        // system's *disabled / decorative* tier and fails the 4.5:1 minimum for text that
        // carries information (tool badge, project name, dates in the sidebar row). Those
        // call sites consume `textTertiary`, so this token now maps to `.secondaryLabelColor`
        // — the system's *secondary information* tier, which Apple guarantees ≥ 4.5:1 against
        // the window material in both light and dark. Truly decorative, non-informational
        // text (the all-caps section header, mascot mark, shortcut chip) should use
        // `textDecorative` instead, which keeps the old faint tone.
        static let textPrimary = SwiftUI.Color(nsColor: .labelColor)
        static let textSecondary = SwiftUI.Color(nsColor: .secondaryLabelColor)
        /// Informational-but-quiet text (badge / project / date). Meets 4.5:1.
        static let textTertiary = SwiftUI.Color(nsColor: .secondaryLabelColor)
        /// Purely decorative / non-essential text where low contrast is acceptable by design
        /// (WCAG exempts incidental text). Maps to the system disabled-label tier.
        static let textDecorative = SwiftUI.Color(nsColor: .tertiaryLabelColor)

        // Lines & fills — hairline separators used sparingly; soft hover/selection fills.
        static let separator = SwiftUI.Color(nsColor: .separatorColor)
        /// Row hover wash (black 5% light / white 6% dark).
        static let hoverFill = SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor.white.withAlphaComponent(0.06)
                              : NSColor.black.withAlphaComponent(0.05)
        })
        /// Selected sidebar pill fill (accent @14% light / @18% dark).
        static let selectionFill = SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            NSColor.controlAccentColor.withAlphaComponent(appearance.isDark ? 0.18 : 0.14)
        })
        /// A subtle chip / badge fill (textTertiary @10%).
        static let chipFill = SwiftUI.Color(nsColor: NSColor.tertiaryLabelColor.withAlphaComponent(0.10))
        /// A soft drop-shadow tone for floating surfaces (e.g. the toast capsule).
        static let shadow = SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            NSColor.black.withAlphaComponent(appearance.isDark ? 0.45 : 0.18)
        })

        // Status — desaturated to fit the warm-grey palette; never decorative.
        static let success = SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(srgbRed: 0x6F / 255, green: 0xB0 / 255, blue: 0x7E / 255, alpha: 1)
                              : NSColor(srgbRed: 0x4E / 255, green: 0x8A / 255, blue: 0x5B / 255, alpha: 1)
        })
        /// Warning reuses the accent amber to avoid a second hue.
        static let warning = SwiftUI.Color.accentColor
        static let error = SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? NSColor(srgbRed: 0xD2 / 255, green: 0x7B / 255, blue: 0x72 / 255, alpha: 1)
                              : NSColor(srgbRed: 0xB5 / 255, green: 0x52 / 255, blue: 0x4A / 255, alpha: 1)
        })
    }

    // MARK: - Font

    /// Two families only: SF Pro (`.system`) for UI text, SF Mono (`.system(…, design: .monospaced)`)
    /// for record/code bodies, timestamps, paths, counts, chips. Strict 4-level hierarchy.
    enum Font {
        // Titles
        static let paneTitle = SwiftUI.Font.system(size: 22, weight: .semibold)

        // Sidebar
        static let sectionHeader = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let rowTitle = SwiftUI.Font.system(size: 13, weight: .regular)
        static let rowTitleSelected = SwiftUI.Font.system(size: 13, weight: .medium)
        static let rowSubtitle = SwiftUI.Font.system(size: 12, weight: .regular)
        static let rowDate = SwiftUI.Font.system(size: 11, weight: .regular, design: .monospaced)
        static let snippet = SwiftUI.Font.system(size: 12, weight: .regular)

        // Records (Warp blocks)
        static let recordBody = SwiftUI.Font.system(size: 13, weight: .regular, design: .monospaced)
        static let roleLabel = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let recordMeta = SwiftUI.Font.system(size: 11, weight: .regular, design: .monospaced)

        // Editor
        static let editorBody = SwiftUI.Font.system(size: 13.5, weight: .regular, design: .monospaced)

        // Tabs / controls
        static let tabTitle = SwiftUI.Font.system(size: 12, weight: .regular)
        static let tabTitleActive = SwiftUI.Font.system(size: 12, weight: .medium)
        static let controlLabel = SwiftUI.Font.system(size: 12, weight: .medium)

        // Search
        static let searchField = SwiftUI.Font.system(size: 13, weight: .regular)

        // Settings
        static let settingsHeader = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let settingsLabel = SwiftUI.Font.system(size: 13, weight: .regular)
        static let settingsPath = SwiftUI.Font.system(size: 11, weight: .regular, design: .monospaced)

        // Footer / chips / empty state
        static let footer = SwiftUI.Font.system(size: 11, weight: .regular, design: .monospaced)
        static let emptyHeadline = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let emptySubline = SwiftUI.Font.system(size: 12, weight: .regular)
        static let chip = SwiftUI.Font.system(size: 10.5, weight: .medium, design: .monospaced)
        static let badgeLabel = SwiftUI.Font.system(size: 11, weight: .medium)
        static let badgeGlyph = SwiftUI.Font.system(size: 9, weight: .medium)
    }

    /// Letter-spacing tokens for tracked uppercase headers (kerning is applied via `.tracking`).
    enum Tracking {
        static let header: CGFloat = 0.6
        static let roleLabel: CGFloat = 0.4
    }

    // MARK: - Spacing (strict 8pt grid; 4pt fine adjust)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Radius

    enum Radius {
        static let chip: CGFloat = 6      // chips / tabs / shortcut
        static let pill: CGFloat = 7      // selection pill / search field
        static let card: CGFloat = 8      // cards / record blocks / buttons
        static let surface: CGFloat = 10  // sheets / large surfaces
    }

    // MARK: - Sidebar metrics

    enum Sidebar {
        static let minWidth: CGFloat = 200
        static let idealWidth: CGFloat = 248
        static let maxWidth: CGFloat = 320
        static let gutter: CGFloat = 8           // inner horizontal inset for floating pills
        static let rowHeight: CGFloat = 44       // archive rows (title + subtitle)
        static let leading: CGFloat = 12         // content leading inset within a row
        static let pillInset: CGFloat = 6        // selection-pill inset from sidebar edges
        /// Top inset so the search field clears the transparent titlebar / traffic lights
        /// (one calm tone-shift, no seam under the chrome).
        static let titlebarInset: CGFloat = 28
    }

    // MARK: - Content / editor measure

    enum Content {
        /// Max reading measure (~70ch) for the editor body, centered in the pane.
        static let maxMeasure: CGFloat = 640
        static let editorInset: CGFloat = 16
    }
}

// MARK: - NSAppearance helper

private extension NSAppearance {
    /// Whether this appearance resolves to a dark variant.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - View modifiers

extension View {
    /// A tracked, all-caps section header (Linear-style): tertiary tone, tiny tracked caps.
    func dsSectionHeader() -> some View {
        self
            .font(DS.Font.sectionHeader)
            .tracking(DS.Tracking.header)
            .textCase(.uppercase)
            .foregroundStyle(DS.Color.textTertiary)
    }
}

// MARK: - Hover background modifier

/// A 120ms-animated hover wash inside a rounded rect — the native row/button hover (no
/// `cursor: pointer`, a critical native tell). Applied behind row content.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = DS.Radius.pill
    var inset: CGFloat = 0
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering ? DS.Color.hoverFill : SwiftUI.Color.clear)
                    .padding(inset)
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = DS.Radius.pill, inset: CGFloat = 0) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, inset: inset))
    }
}

// MARK: - Button styles

/// Primary call-to-action: amber fill, near-white label, distinct pressed state.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.controlLabel)
            .foregroundStyle(isEnabled ? SwiftUI.Color.white : DS.Color.textTertiary)
            .padding(.horizontal, DS.Spacing.md)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(isEnabled ? DS.Color.accent : DS.Color.chipFill)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

/// Secondary: card fill + hairline, primary-tone label.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.controlLabel)
            .foregroundStyle(isEnabled ? DS.Color.textPrimary : DS.Color.textTertiary)
            .padding(.horizontal, DS.Spacing.md)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(DS.Color.bgCard)
                    .brightness(configuration.isPressed ? -0.05 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Color.separator, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

/// Borderless icon button (toolbar / control / record rows): 28×28 hit area, hover wash,
/// amber tint when `isActive`, tertiary when disabled (never plain opacity). No pointer cursor.
struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isActive: Bool = false
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: 28, height: 28)
            .foregroundStyle(
                !isEnabled ? DS.Color.textTertiary
                : isActive ? DS.Color.accent
                : DS.Color.textSecondary
            )
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(isHovering && isEnabled ? DS.Color.hoverFill : SwiftUI.Color.clear)
                    .brightness(configuration.isPressed ? -0.06 : 0)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
    }
}

// MARK: - Mascot mark + shortcut chip + empty state

/// A self-drawn raccoon "bandit mask" silhouette — the brand glyph (zero legal risk, on
/// theme: a raccoon washes/cleans). A soft, horizontally-rounded mask band sits across where
/// the eyes are, with two circular eye cut-outs as negative space (the even-odd fill rule
/// punches them out). Proportions mirror the dock-icon master (`scripts/make_appicon.py`):
/// mask half-width ~0.62, half-height ~0.20 of the bounding box, eyes inset ~0.215 with
/// radius ~0.085. The shape is monochrome, so it reads as a template at small sizes too.
struct RaccoonMaskShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        // Nudge the band a touch above center, matching the icon master (`mask_cy`).
        let cy = rect.midY - 0.02 * h

        // Mask band: a rounded "lozenge" — a wide rect with fully-rounded short ends.
        let halfW = 0.62 * w
        let halfH = 0.20 * h
        let bandRect = CGRect(
            x: cx - halfW,
            y: cy - halfH,
            width: halfW * 2,
            height: halfH * 2
        )
        // Corner radius = the half-height gives semicircular caps (a clean bandit-mask band).
        path.addRoundedRect(
            in: bandRect,
            cornerSize: CGSize(width: halfH, height: halfH),
            style: .continuous
        )

        // Two eye holes punched out via the even-odd rule (negative space).
        let eyeDX = 0.215 * w
        let eyeR = 0.085 * w
        // Eyes sit just below the band's vertical center, matching the master (`eye_cy`).
        let eyeCY = cy + 0.005 * h
        for sign in [-1.0, 1.0] {
            let ex = cx + CGFloat(sign) * eyeDX
            path.addEllipse(in: CGRect(
                x: ex - eyeR,
                y: eyeCY - eyeR,
                width: eyeR * 2,
                height: eyeR * 2
            ))
        }

        return path
    }
}

/// The v1 raccoon brand glyph — a self-drawn monochrome bandit mask rendered in a tertiary
/// tone (see `RaccoonMaskShape`). Used ONLY in empty states, the About box, and the menu-bar
/// template icon (never in chrome). Replaces the former SF Symbol mark (legal risk).
struct RaccoonMark: View {
    var size: CGFloat = 48
    var body: some View {
        RaccoonMaskShape()
            .fill(DS.Color.textTertiary, style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A small monospaced keyboard-hint chip (e.g. `⌘R`).
struct ShortcutChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(DS.Font.chip)
            .foregroundStyle(DS.Color.textTertiary)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(DS.Color.chipFill)
            )
    }
}

/// A terse, centered empty state: mascot mark + one headline + one subline + optional hint chip.
/// The highest-leverage screenshot surface — lots of surrounding air, never over-explained.
struct EmptyStateView: View {
    let headline: String
    let subline: String
    var hint: String? = nil
    var markSize: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            RaccoonMark(size: markSize)
            Spacer().frame(height: DS.Spacing.lg)
            Text(headline)
                .font(DS.Font.emptyHeadline)
                .foregroundStyle(DS.Color.textSecondary)
            Spacer().frame(height: DS.Spacing.xs + 2)
            Text(subline)
                .font(DS.Font.emptySubline)
                .foregroundStyle(DS.Color.textTertiary)
                .multilineTextAlignment(.center)
            if let hint {
                Spacer().frame(height: DS.Spacing.lg)
                ShortcutChip(text: hint)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Transient confirmation toast

/// A lightweight, observable toast model shared via the SwiftUI environment. Call `show(_:)`
/// to flash a short confirmation ("已复制") that auto-dismisses after ~1.5s. One toast at a
/// time — a new `show` replaces the current message and resets the timer.
@MainActor
@Observable
final class ToastCenter {
    /// The currently visible message, or `nil` when nothing is shown.
    private(set) var message: String?
    /// Optional title for an inline action button rendered in the toast (e.g.
    /// "Undo"). `nil` when the current toast carries no action.
    private(set) var actionTitle: String?
    /// Closure invoked when the action button is tapped. Held privately; run and
    /// cleared via `performAction()`.
    @ObservationIgnored private var action: (() -> Void)?

    /// Cancels any in-flight auto-dismiss so a rapid second toast doesn't get cut short.
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// Flash `text` for ~1.5s, replacing any current toast.
    func show(_ text: String) {
        present(text, actionTitle: nil, action: nil)
    }

    /// Flash `text` with an inline action button (e.g. "Moved to Trash · Undo").
    /// Tapping the button runs `action` and dismisses the toast. The toast still
    /// auto-dismisses after the usual delay if the button is never tapped — so an
    /// action toast gets a slightly longer window (~4s) to be actionable.
    func show(_ text: String, actionTitle: String, action: @escaping () -> Void) {
        present(text, actionTitle: actionTitle, action: action, duration: .seconds(4))
    }

    private func present(
        _ text: String,
        actionTitle: String?,
        action: (() -> Void)?,
        duration: Duration = .milliseconds(1500)
    ) {
        message = text
        self.actionTitle = actionTitle
        self.action = action
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Run the pending action (if any) and dismiss the toast. Bound to the inline
    /// action button.
    func performAction() {
        let pending = action
        dismiss()
        pending?()
    }

    /// Immediately clear any shown toast.
    func dismiss() {
        message = nil
        actionTitle = nil
        action = nil
        dismissTask?.cancel()
    }
}

/// The small bottom-center capsule that renders the active toast message: regular material,
/// hairline stroke, soft shadow — subtle and on-brand (DS tokens only).
private struct ToastCapsule: View {
    let message: String
    /// Optional inline action ("Undo"). When non-nil a trailing button is shown.
    var actionTitle: String? = nil
    /// Invoked when the action button is tapped.
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(message)
                .font(DS.Font.controlLabel)
                .foregroundStyle(DS.Color.textPrimary)
            if let actionTitle, let onAction {
                Divider()
                    .frame(height: 14)
                Button(action: onAction) {
                    Text(actionTitle)
                        .font(DS.Font.controlLabel.weight(.semibold))
                        .foregroundStyle(DS.Color.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(DS.Color.separator, lineWidth: 1)
        )
        .shadow(color: DS.Color.shadow, radius: 12, y: 4)
    }
}

/// Overlays the active toast at the bottom-center of the host view. Respects Reduce Motion
/// (fades only) and otherwise slides up with a fade.
///
/// IMPORTANT (observation): the `ToastCenter` is held via `@Bindable` so SwiftUI tracks its
/// `@Observable` `message` property and re-renders the overlay when it changes. A plain
/// `let center` stored on the modifier does NOT reliably register dependency tracking when its
/// property is read only inside `animation(value:)`/conditionals, so the capsule could fail to
/// animate in. `@Bindable` guarantees the dependency is registered during body evaluation.
struct ToastOverlay: ViewModifier {
    @Bindable var center: ToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Read the observable property up front so the dependency is always registered.
        let message = center.message
        let actionTitle = center.actionTitle
        return content.overlay(alignment: .bottom) {
            if let message {
                ToastCapsule(
                    message: message,
                    actionTitle: actionTitle,
                    onAction: actionTitle == nil ? nil : { center.performAction() }
                )
                    .padding(.bottom, DS.Spacing.xl)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom).combined(with: .opacity)
                    )
                    // Only an action toast (with an "Undo" button) needs hit-testing;
                    // a plain confirmation toast stays click-through as before.
                    .allowsHitTesting(actionTitle != nil)
            }
        }
        .animation(
            reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.85),
            value: message
        )
        // VoiceOver: speak the toast text when it appears (e.g. "Copied"), so non-sighted
        // users get the same confirmation the capsule gives sighted ones.
        .onChange(of: message) { _, newMessage in
            if let newMessage {
                AccessibilityNotification.Announcement(newMessage).post()
            }
        }
    }
}

extension View {
    /// Attach a bottom-center transient toast driven by `center`.
    func toastOverlay(_ center: ToastCenter) -> some View {
        modifier(ToastOverlay(center: center))
    }
}

// MARK: - NSVisualEffectView wrapper

/// A thin SwiftUI wrapper over `NSVisualEffectView` so surfaces pick up macOS vibrancy and
/// desktop tint. Use `.sidebar` for the recessed left pane, `.windowBackground` for content.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// The ONE place any content-copy path writes user record text to the clipboard (§9.5 pattern).
///
/// Secret-leak hardening: record bodies routinely contain API keys / tokens / private keys a
/// user pasted into a session. To keep those from persisting in clipboard managers and being
/// synced over Universal Clipboard, the pasteboard item is tagged with the de-facto
/// "concealed/transient" pasteboard hints (`org.nspasteboard.ConcealedType` / `…TransientType`
/// / `…AutoGeneratedType`) that password-manager-style tools honor by skipping the entry. We
/// still write the plain string normally so a manual ⌘V works everywhere.
///
/// Returns the secret hits found in `payload` (value-free; never logs the secrets) so the caller
/// can warn the user that secrets are about to hit the clipboard. Both the main Feed copy buttons
/// (`EditorView`) and the per-block copy-on-hover button (`PreviewView`) route through here so the
/// scan + concealment is impossible to bypass from any content-copy UI.
enum SecretSafePasteboard {
    @discardableResult
    static func write(_ payload: String) -> [SecretScan.SecretHit] {
        let pb = NSPasteboard.general
        pb.clearContents()
        // Concealed/transient hints used by clipboard managers (Maccy, Paste, etc.) and the
        // 1Password convention. Declaring them alongside .string marks the item as sensitive
        // so well-behaved clipboard history / Universal Clipboard tooling skips persisting it.
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let autogenerated = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        pb.declareTypes([.string, concealed, transient, autogenerated], owner: nil)
        pb.setString(payload, forType: .string)
        // The marker types carry an empty value — their *presence* is the signal.
        pb.setString("", forType: concealed)
        pb.setString("", forType: transient)
        pb.setString("", forType: autogenerated)
        return SecretScan.scan(payload)
    }
}
