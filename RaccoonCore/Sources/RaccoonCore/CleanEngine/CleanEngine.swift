import Foundation

/// Options controlling how `CleanEngine.clean` transforms pasted terminal output.
public struct CleanOptions: Sendable, Equatable {
    /// Conservatively rejoin hard-wrapped prose lines (prose segments only;
    /// never code/table). Default on.
    public var reflowHardWraps: Bool = true
    /// Strip Markdown decoration as a final pass ("转纯文本").
    public var stripMarkdown: Bool = false
    /// Opt-in "prose tidy": for PROSE segments only, strip a small leading
    /// paragraph indent (1–4 ASCII spaces or full-width spaces) from
    /// natural-language lines and collapse runs of ≥2 blank lines to one.
    /// NEVER touches code/table/fence/graph/box structure. Default OFF so the
    /// default pipeline is byte-identical to before this option existed.
    public var tidyProse: Bool = false
    public init() {}
}

/// The result of cleaning. `original` is the verbatim input so callers can
/// offer a lossless one-click "restore original".
public struct CleanResult: Sendable, Equatable {
    /// Verbatim input — `clean(raw).original == raw` for ALL inputs.
    public let original: String
    /// The cleaned output.
    public let cleaned: String
}

/// The core "moat": cleans pasted terminal output without ever damaging code.
///
/// 🔴 RED LINE — code-block integrity must be 100%. Inside a code segment we
/// remove ONLY ANSI/OSC/ESC escape sequences (the unambiguous terminal coloring
/// noise); we PRESERVE everything else verbatim — indentation, newlines,
/// trailing spaces, ordering, every visible character, and semantic bytes such
/// as NBSP, zero-width chars and BOM (which can be meaningful inside code). We
/// never reflow code and never strip box-drawing chars from it. When unsure
/// whether something is code, we treat it as code (bias to preserve). PRD:
/// "宁可漏洗绝不砸代码".
public enum CleanEngine {

    /// Clean `raw` according to `options`.
    ///
    /// Pipeline:
    /// 1. Keep `original = raw` verbatim (restore must be lossless — even for
    ///    CRLF input, since `original` stores the raw bytes before any
    ///    normalization).
    /// 2. Normalize line endings (`\r\n` and lone `\r` → `\n`) for processing.
    /// 3. Segment into code / prose / table segments.
    /// 4. Apply rules per segment kind. Code: ANSI/OSC/ESC escapes ONLY (NBSP /
    ///    zero-width / BOM preserved). Prose/table: full invisible-noise removal
    ///    incl. NBSP → space.
    /// 5. If `options.stripMarkdown`, apply `toPlainText` to the result.
    public static func clean(_ raw: String, options: CleanOptions = .init()) -> CleanResult {
        // Normalize line endings up front so stray `\r` never survives into a
        // code segment (where we otherwise preserve every byte). `original`
        // keeps the raw input verbatim, so a one-click restore is still
        // lossless even for CRLF/CR sources.
        let normalized = normalizeLineEndings(raw)
        let lines = normalized.components(separatedBy: "\n")
        let segments = Segmenter.segment(lines)

        var outLines: [String] = []
        outLines.reserveCapacity(lines.count)

        for segment in segments {
            switch segment.kind {
            case .code:
                // RED LINE: strip ONLY ANSI/OSC/ESC escapes; preserve every
                // other byte — indentation, newlines, trailing spaces, visible
                // chars, and NBSP / zero-width / BOM (semantic inside code).
                for line in segment.lines {
                    outLines.append(AnsiStripper.stripEscapesOnly(line))
                }
            case .table:
                // ANSI/zero-width strip, then box-border + pad cleanup. Never
                // reflowed.
                let stripped = segment.lines.map { AnsiStripper.strip($0) }
                outLines.append(contentsOf: Rules.cleanTableLines(stripped))
            case .prose:
                // ANSI/zero-width strip, box/pad/indent cleanup, then
                // conservative hard-wrap reflow (gated).
                let stripped = segment.lines.map { AnsiStripper.strip($0) }
                var prose = Rules.cleanProseLines(stripped)
                // Opt-in conservative tidy: de-indent natural-language lines and
                // collapse excess blank lines. PROSE segments only — code/table
                // are handled in their own branches and never reach here.
                if options.tidyProse {
                    prose = Rules.tidyProseLines(prose)
                }
                if options.reflowHardWraps {
                    prose = Reflow.reflow(prose)
                }
                outLines.append(contentsOf: prose)
            }
        }

        var cleaned = outLines.joined(separator: "\n")

        if options.stripMarkdown {
            cleaned = toPlainText(cleaned)
        }

        return CleanResult(original: raw, cleaned: cleaned)
    }

    /// Remove Markdown decoration but keep text + structure.
    public static func toPlainText(_ markdown: String) -> String {
        PlainText.toPlainText(markdown)
    }

    /// Normalize line endings to LF: `\r\n` → `\n`, then any remaining lone
    /// `\r` (old Mac style) → `\n`. Pure character substitution that never
    /// adds/removes a line, so it cannot reorder or merge content.
    private static func normalizeLineEndings(_ s: String) -> String {
        guard s.contains("\r") else { return s }
        return s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
