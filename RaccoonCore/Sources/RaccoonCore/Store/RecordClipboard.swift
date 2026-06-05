import Foundation

// MARK: - RecordClipboard

/// Pure, testable builders for the three clipboard payloads exposed by the read-only
/// record view (§9.5). Each is a deterministic function of a `Record` (or a path), so
/// the exact strings can be asserted headlessly in Core tests.
///
/// The three flavors map to the record toolbar buttons:
/// - **复制走** (`copyOut`) — bare message content, NO source labels. For pasting the
///   substance somewhere else (a doc, a chat) without the 你：/Codex： scaffolding.
/// - **喂·内容** (`feedContent`) — the verbatim §4 body WITH 来源标签 (你：/Codex：…), i.e.
///   exactly the `.md` body (no frontmatter, no summary/preamble). For pasting back into
///   an AI so it sees who said what.
/// - **喂·路径** (`feedPath`) — an editable guide phrase followed by the absolute `.md`
///   path, so an AI with filesystem access can read the record itself.
public enum RecordClipboard {

    /// 复制走 — the cleaned message texts joined by blank lines, with NO source labels.
    ///
    /// This is `r.messages.map(\.text).joined(separator: "\n\n")` — the bare substance,
    /// suitable for pasting into a document or chat without the speaker scaffolding.
    public static func copyOut(_ r: Record) -> String {
        r.messages.map(\.text).joined(separator: "\n\n")
    }

    /// 喂·内容 — the verbatim §4 body WITH 来源标签, exactly the `.md` body (no frontmatter).
    ///
    /// Per message: `"\(speaker.label)：\n\(text)"`, joined by `"\n\n"`. This mirrors the
    /// body that `MarkdownCodec.encode(_:)` writes after the `---` frontmatter, so feeding
    /// it back into an AI preserves who said what.
    public static func feedContent(_ r: Record) -> String {
        r.messages
            .map { "\($0.speaker.label)：\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    /// 喂·路径 — an agent-actionable directive + the absolute `.md` path.
    ///
    /// Returns `guide + mdPath.path`, e.g.
    /// `请读取这个文件了解之前的上下文（仅作参考，读完等我指示）：/abs/x.md`. The default `guide`
    /// frames the file as REFERENCE context — a CLI agent should read it for background, then
    /// WAIT for the user's instruction rather than autonomously "continuing" the old session.
    /// It stays a single line, the path stays 100% local & absolute, and `guide` is overridable.
    public static func feedPath(mdPath: URL, guide: String = "请读取这个文件了解之前的上下文（仅作参考，读完等我指示）：") -> String {
        guide + mdPath.path
    }
}
