import SwiftUI
import RaccoonCore

/// A scrollable Markdown preview of a tab's text. v1 rendering uses `AttributedString`'s
/// built-in Markdown parser interpreting inline syntax while preserving whitespace, so
/// emphasis renders and code keeps its layout. Centered at a comfortable reading measure.
struct PreviewView: View {
    let text: String

    var body: some View {
        ScrollView {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(rendered)
                    .font(DS.Font.editorBody)
                    .foregroundStyle(DS.Color.textPrimary)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: DS.Content.maxMeasure, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Content.editorInset)
            .padding(.vertical, DS.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.bgWindow)
    }

    /// Parse the document as Markdown. Falls back to the raw text if parsing fails.
    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return attributed
        }
        return AttributedString(text)
    }
}

// MARK: - Record blocks (Warp-style, the hero screenshot surface)

/// Read-only render of an archived session (§9.5): a floating title + key-value metadata row
/// under a single hairline, then each turn as a discrete rounded "block" card (role label +
/// monospaced body), with a copy-on-hover button. Elevation is by luminance, never shadow.
struct RecordBlocksView: View {
    let record: Record

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                    .overlay(DS.Color.separator)
                    .padding(.top, DS.Spacing.lg)
                    .padding(.bottom, DS.Spacing.lg)

                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    ForEach(Array(record.messages.enumerated()), id: \.offset) { _, message in
                        RecordBlock(
                            role: roleLabel(for: message.speaker),
                            isAssistant: message.speaker != .user,
                            text: message.text
                        )
                    }
                }
            }
            .frame(maxWidth: DS.Content.maxMeasure, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, DS.Spacing.xl)
            .padding(.bottom, DS.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.bgWindow)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(record.title)
                .font(DS.Font.paneTitle)
                .foregroundStyle(DS.Color.textPrimary)
                .textSelection(.enabled)
            Text(metadataLine)
                .font(DS.Font.recordMeta)
                .foregroundStyle(DS.Color.textTertiary)
                .textSelection(.enabled)
        }
        .padding(.top, DS.Spacing.xl)
    }

    /// `source · date · project · turns` key-value metadata, mono, tertiary.
    private var metadataLine: String {
        var parts: [String] = [record.tool.label]
        parts.append(record.lastActiveAt.formatted(date: .abbreviated, time: .shortened))
        if let project = record.project, !project.isEmpty {
            parts.append(project)
        }
        parts.append("\(record.messages.count) turns")
        return parts.joined(separator: "  ·  ")
    }

    /// Role label shown above each block: user turns read "USER"; every other speaker uses its
    /// own display label (e.g. "Claude Code", "Codex"). Uppercasing is applied by the block view.
    private func roleLabel(for speaker: Speaker) -> String {
        speaker == .user ? "User" : speaker.label
    }
}

/// One Warp block: role label (uppercase tracked) + monospaced body, copy-on-hover top-right.
private struct RecordBlock: View {
    let role: String
    let isAssistant: Bool
    let text: String

    @Environment(ToastCenter.self) private var toast
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Text(role)
                    .font(DS.Font.roleLabel)
                    .tracking(DS.Tracking.roleLabel)
                    .textCase(.uppercase)
                    // Assistant turns get an accent-tinted-secondary label; user turns secondary.
                    .foregroundStyle(isAssistant ? DS.Color.accent.opacity(0.85) : DS.Color.textSecondary)
                Spacer()
                if isHovering {
                    Button {
                        // Route through the shared secret-safe writer so the block-copy path gets
                        // the SAME SecretScan + concealed/transient pasteboard hardening as the
                        // main Feed copy buttons — record bodies routinely contain API keys/tokens.
                        let hits = SecretSafePasteboard.write(text)
                        if hits.isEmpty {
                            toast.show(String(localized: "content.toast.copied"))
                        } else {
                            toast.show(String(localized: "toast.copied.secrets \(hits.count)"))
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(IconButtonStyle())
                    .transition(.opacity)
                    .help(Text("content.block.copy.help"))
                    .accessibilityLabel(Text("content.block.copy.help"))
                }
            }
            Text(bodyText)
                .font(DS.Font.recordBody)
                .foregroundStyle(DS.Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(DS.Color.bgCard)
        )
        // One subtle layer of depth: a 0.5pt warm hairline so the white card lifts off the
        // warm off-white window in light mode (it reads flat with the fill alone). In dark
        // mode `cardBorder` is barely-there since luminance already separates the surfaces.
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Color.cardBorder, lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    /// The block body with a paragraph `lineHeightMultiple` (~1.55) for comfortable code/log
    /// reading, replacing a flat `.lineSpacing` so wrapped lines breathe proportionally.
    private var bodyText: AttributedString {
        var attributed = AttributedString(text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.55
        attributed.paragraphStyle = paragraph
        return attributed
    }
}
