import Foundation

/// Per-segment cleanup rules for PROSE and TABLE segments. These rules must
/// NEVER be applied to `.code` segments (the RED LINE): code keeps its
/// indentation, newlines, trailing spaces, and every visible char verbatim.
enum Rules {

    // MARK: - Prose

    /// Clean prose lines:
    ///  - strip box-drawing border chars (terminal box output mixed into prose),
    ///  - remove a leading whitespace run only when it is left over after a
    ///    stripped leading border (box padding), not ordinary prose indentation,
    ///  - strip trailing whitespace.
    /// Blank lines are preserved (paragraph structure).
    static func cleanProseLines(_ lines: [String]) -> [String] {
        lines.map { line in
            let startedWithBorder = beginsWithBoxBorder(line)
            var s = removeBoxDrawing(line)
            // Only trim the leading run if the original line began with a box
            // border (so the leading spaces are box padding, not real indent).
            if startedWithBorder {
                s = trimLeadingSpaces(s)
            }
            return trimTrailing(s)
        }
    }

    // MARK: - Prose tidy (opt-in)

    /// Conservative opt-in tidy for PROSE segments (gated by
    /// `CleanOptions.tidyProse`). Two passes, both safe and idempotent:
    ///
    ///  1. De-indent: strip a leading run of 1–4 ASCII spaces OR full-width
    ///     spaces (`\u{3000}`) from each line — but ONLY when the line reads as
    ///     natural-language prose (see `isTidyableProseLine`). Lines that begin
    ///     a Markdown list / blockquote / heading / fence, or that look like
    ///     code (semantic indentation, symbol-bearing config/YAML/JS), are left
    ///     EXACTLY as-is so we never corrupt structure or misclassified code.
    ///  2. Collapse runs of ≥2 consecutive blank lines down to exactly one.
    ///
    /// Idempotent: re-running strips nothing further (indent already gone) and
    /// finds no ≥2 blank runs.
    static func tidyProseLines(_ lines: [String]) -> [String] {
        let deIndented = lines.map { line -> String in
            isTidyableProseLine(line) ? stripLeadingProseIndent(line) : line
        }
        return collapseBlankRuns(deIndented)
    }

    /// True if `line` is a plain natural-language prose line whose leading
    /// indent is safe to strip. Conservative — anything that could be a list
    /// item, blockquote, heading, fence, or code is rejected (left untouched).
    ///
    /// To strip the indent we require the line, after removing 1–4 leading
    /// ASCII/full-width spaces, to read UNAMBIGUOUSLY as natural-language prose.
    ///
    /// The decisive safety rule (per the RED LINE — 宁可漏洗绝不砸代码) is that
    /// ASCII-only indented lines are NEVER de-indented: an ASCII line like
    /// `other: thing` or `key = value` is indistinguishable from semantic
    /// indentation in YAML/Python/config that slipped into a prose segment
    /// (e.g. when a blank line broke an indented-code run). We therefore strip
    /// indent ONLY from lines that contain at least one CJK character (natural
    /// language that is unambiguously not code) AND are not symbol-dense and do
    /// not begin a Markdown block. This is enough for the owner's CJK prose use
    /// case while guaranteeing ASCII code/config is left byte-identical.
    private static func isTidyableProseLine(_ line: String) -> Bool {
        // Determine the leading indent (ASCII spaces or full-width spaces only).
        var indentCount = 0
        var afterIndex = line.startIndex
        for ch in line {
            if ch == " " || ch == "\u{3000}" {
                indentCount += 1
                afterIndex = line.index(after: afterIndex)
            } else {
                break
            }
        }
        // No strippable indent, or a tab (semantic for code) → not tidyable.
        guard indentCount >= 1, indentCount <= 4 else { return false }
        if line.first == "\t" { return false }

        let body = line[afterIndex...]
        // Blank after indent → leave to the blank-collapse pass.
        guard body.unicodeScalars.first != nil else { return false }

        // Markdown block starters: never de-indent (preserve structure).
        if beginsMarkdownBlock(body) { return false }

        // RED LINE: only de-indent lines that contain a CJK character — these
        // are unambiguously natural language, never code. ASCII-only indented
        // lines are always left as-is (could be semantic code indentation).
        guard body.unicodeScalars.contains(where: { isCJK($0) }) else { return false }

        // Even a CJK-bearing line is left alone if it is symbol-dense (a code
        // line that happens to contain a CJK string literal / comment).
        if isSymbolDenseLine(body) { return false }

        return true
    }

    /// Strip a leading run of 1–4 ASCII spaces or full-width spaces. Caller has
    /// already validated the line is tidyable.
    private static func stripLeadingProseIndent(_ line: String) -> String {
        var count = 0
        var idx = line.startIndex
        while idx < line.endIndex, count < 4 {
            let ch = line[idx]
            if ch == " " || ch == "\u{3000}" {
                count += 1
                idx = line.index(after: idx)
            } else {
                break
            }
        }
        return String(line[idx...])
    }

    /// Collapse runs of ≥2 consecutive blank lines down to exactly one blank.
    private static func collapseBlankRuns(_ lines: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var prevBlank = false
        for line in lines {
            let blank = line.allSatisfy { $0 == " " || $0 == "\t" }
            if blank {
                if prevBlank { continue }  // drop the extra blank
                out.append("")             // normalize blank to empty
            } else {
                out.append(line)
            }
            prevBlank = blank
        }
        return out
    }

    /// True if `body` (a line with leading indent already removed) begins a
    /// Markdown block whose marker must be preserved: list item (`- `, `* `,
    /// `+ `, `N.`/`N)`), blockquote (`>`), heading (`#`), or fence (``` / ~~~).
    private static func beginsMarkdownBlock(_ body: Substring) -> Bool {
        guard let first = body.first else { return false }
        if first == ">" || first == "#" { return true }
        if first == "`" || first == "~" {
            let p = body.prefix(3)
            if p == "```" || p == "~~~" { return true }
        }
        if first == "-" || first == "*" || first == "+" {
            let after = body.dropFirst()
            if after.first == " " { return true }
        }
        if first.isNumber {
            var rest = body
            while let c = rest.first, c.isNumber { rest = rest.dropFirst() }
            if let c = rest.first, c == "." || c == ")" {
                let after = rest.dropFirst()
                if after.first == " " || after.isEmpty { return true }
            }
        }
        return false
    }

    /// Symbol-density gate to keep code/config out of the de-indent path. Above
    /// 0.10 (10%) of non-space chars being code symbols, treat the line as code.
    /// Natural-language prose sits well below this; YAML/JS/config exceeds it.
    private static func isSymbolDenseLine(_ body: Substring) -> Bool {
        var symbols = 0
        var nonSpace = 0
        for scalar in body.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\u{3000}" { continue }
            nonSpace += 1
            if isCodeSymbol(scalar) { symbols += 1 }
        }
        guard nonSpace > 0 else { return false }
        return Double(symbols) / Double(nonSpace) >= 0.10
    }

    private static func isCodeSymbol(_ s: UnicodeScalar) -> Bool {
        switch s {
        case "{", "}", "(", ")", "[", "]", ";", ":", "=", "<", ">",
             "&", "|", "!", "+", "*", "/", "%", "^", "~", "\\", "`":
            return true
        default:
            return false
        }
    }

    /// CJK ranges (mirrors Reflow.isCJK) so a de-indent decision treats CJK as
    /// natural language.
    private static func isCJK(_ s: UnicodeScalar) -> Bool {
        let v = s.value
        return (v >= 0x3040 && v <= 0x30FF)    // Hiragana + Katakana
            || (v >= 0x3400 && v <= 0x4DBF)    // CJK Ext A
            || (v >= 0x4E00 && v <= 0x9FFF)    // CJK Unified Ideographs
            || (v >= 0xF900 && v <= 0xFAFF)    // CJK Compatibility Ideographs
    }

    // MARK: - Table

    /// Clean table lines into cell text:
    ///  - drop Markdown separator rows (`|---|`),
    ///  - strip box-drawing borders and outer pipe delimiters,
    ///  - trim leading/trailing padding,
    ///  - drop lines that become empty (pure borders).
    /// One cell's text (or pipe-joined cells) per line is acceptable.
    static func cleanTableLines(_ lines: [String]) -> [String] {
        var out: [String] = []
        for line in lines {
            // Drop Markdown separator rows entirely.
            if isMarkdownSeparator(line) { continue }

            var s = removeBoxDrawing(line)
            s = stripOuterPipes(s)
            s = s.trimmingCharacters(in: .whitespaces)

            // Drop lines that are now empty (e.g. top/bottom borders).
            if s.isEmpty { continue }
            out.append(s)
        }
        return out
    }

    // MARK: - Helpers

    private static func isBoxDrawing(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0x2500 && scalar.value <= 0x257F
    }

    private static func beginsWithBoxBorder(_ line: String) -> Bool {
        // After optional leading spaces, the first non-space scalar is a box char.
        for scalar in line.unicodeScalars {
            if scalar == " " { continue }
            return isBoxDrawing(scalar)
        }
        return false
    }

    private static func removeBoxDrawing(_ line: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(line.unicodeScalars.count)
        for scalar in line.unicodeScalars where !isBoxDrawing(scalar) {
            out.append(scalar)
        }
        return String(out)
    }

    /// Remove a leading `|` (with surrounding spaces) and a trailing `|` (with
    /// surrounding spaces) — the outer delimiters of a Markdown/ASCII table row.
    private static func stripOuterPipes(_ line: String) -> String {
        var s = Substring(line)
        // Leading.
        let lead = s.drop { $0 == " " || $0 == "\t" }
        if lead.first == "|" {
            s = lead.dropFirst()
        }
        // Trailing.
        var trail = s
        while let last = trail.last, last == " " || last == "\t" {
            trail = trail.dropLast()
        }
        if trail.last == "|" {
            trail = trail.dropLast()
        }
        return String(trail)
    }

    private static func trimTrailing(_ s: String) -> String {
        var sub = Substring(s)
        while let last = sub.last, last == " " || last == "\t" {
            sub = sub.dropLast()
        }
        return String(sub)
    }

    private static func trimLeadingSpaces(_ s: String) -> String {
        String(s.drop { $0 == " " || $0 == "\t" })
    }

    private static func isMarkdownSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.contains("-") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }
}
