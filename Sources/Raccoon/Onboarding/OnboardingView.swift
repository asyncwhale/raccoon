import SwiftUI

/// First-run welcome sheet. A single, calm screen that introduces Raccoon's four
/// pillars (记 / 洗 / 找 / 喂) in one plain sentence each, plus the trust promise.
///
/// On-brand and restrained (Linear/Things-like): the near-monochrome graphite ramp,
/// the self-drawn `RaccoonMark` mascot, and the lone amber accent rationed to the single
/// primary "开始使用" button. DS tokens only — no bespoke colors/metrics.
///
/// Gating + presentation live in `RaccoonApp` via `@AppStorage("hasSeenOnboarding_v1")`;
/// this view just renders content and calls `onDismiss` when the user taps Get Started.
/// It never touches the network and is fully dismissible (it doesn't block the app).
struct OnboardingView: View {
    /// Invoked when the user dismisses the sheet (taps the primary button). The host flips
    /// the AppStorage flag so the sheet never shows again.
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The four pillars, each one plain sentence. Glyph is the Chinese verb (记/洗/找/喂),
    /// title pairs it with its action, and the body is the one-line explanation.
    private static let pillars: [Pillar] = [
        Pillar(
            glyph: "记",
            title: String(localized: "onboarding.pillar.record.title"),
            detail: String(localized: "onboarding.pillar.record.detail")
        ),
        Pillar(
            glyph: "洗",
            title: String(localized: "onboarding.pillar.clean.title"),
            detail: String(localized: "onboarding.pillar.clean.detail")
        ),
        Pillar(
            glyph: "找",
            title: String(localized: "onboarding.pillar.search.title"),
            detail: String(localized: "onboarding.pillar.search.detail")
        ),
        Pillar(
            glyph: "喂",
            title: String(localized: "onboarding.pillar.feed.title"),
            detail: String(localized: "onboarding.pillar.feed.detail")
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer().frame(height: DS.Spacing.xl)

            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                ForEach(Self.pillars) { pillar in
                    PillarRow(pillar: pillar)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer().frame(height: DS.Spacing.xl)

            trustPromise

            Spacer().frame(height: DS.Spacing.xl)

            Button(action: onDismiss) {
                Text("onboarding.start")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(DS.Spacing.xxl)
        .frame(width: 460)
        .background(DS.Color.bgWindow)
        // Reduced-motion: skip the gentle fade-in entirely.
        .modifier(AppearTransition(enabled: !reduceMotion))
    }

    // MARK: Header (mascot + welcome)

    private var header: some View {
        VStack(spacing: DS.Spacing.md) {
            RaccoonMark(size: 56)
            VStack(spacing: DS.Spacing.xs) {
                Text("onboarding.title")
                    .font(DS.Font.paneTitle)
                    .foregroundStyle(DS.Color.textPrimary)
                Text("onboarding.subtitle")
                    .font(DS.Font.emptySubline)
                    .foregroundStyle(DS.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Trust promise

    private var trustPromise: some View {
        Text("onboarding.trust")
            .font(DS.Font.footer)
            .foregroundStyle(DS.Color.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .fill(DS.Color.chipFill)
            )
    }
}

// MARK: - Pillar model + row

/// One of the four pillars (记/洗/找/喂): a glyph + title + one-sentence detail.
private struct Pillar: Identifiable {
    let glyph: String
    let title: String
    let detail: String
    var id: String { glyph }
}

/// A single pillar row: the Chinese verb glyph in a recessed mask-tone tile, then the
/// title + one-line explanation. Monochrome throughout — no accent here (the amber is
/// rationed to the primary button only).
private struct PillarRow: View {
    let pillar: Pillar

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            Text(pillar.glyph)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .fill(DS.Color.mask)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .strokeBorder(DS.Color.separator, lineWidth: 1)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(pillar.title)
                    .font(DS.Font.emptyHeadline)
                    .foregroundStyle(DS.Color.textPrimary)
                Text(pillar.detail)
                    .font(DS.Font.rowSubtitle)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pillar.title)：\(pillar.detail)")
    }
}

// MARK: - Appear transition (reduced-motion aware)

/// A gentle one-shot fade/scale-in on first appear, skipped entirely under Reduce Motion
/// (when `enabled == false` the view renders fully opaque from the start, no animation).
private struct AppearTransition: ViewModifier {
    let enabled: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        // When disabled (Reduce Motion), `shown` is forced true so there's no fade.
        let visible = enabled ? shown : true
        content
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.98)
            .onAppear {
                guard enabled else { return }
                withAnimation(.easeOut(duration: 0.28)) { shown = true }
            }
    }
}

#Preview {
    OnboardingView(onDismiss: {})
}
