import Foundation

/// Conservative hard-wrap reflow for PROSE only. Never applied to code or
/// tables. Gated by `CleanOptions.reflowHardWraps`.
///
/// Philosophy: 宁可漏洗 (when uncertain, do NOT join). We only join a line to
/// the next when the current line is "full" (near the detected wrap width) and
/// the next line is a plain continuation (not a new block: list item, heading,
/// blockquote, or fence).
enum Reflow {

    /// Reflow a prose segment's lines, rejoining hard-wrapped lines.
    static func reflow(_ lines: [String]) -> [String] {
        // Split into paragraphs separated by blank lines; reflow each; preserve
        // the blank separators verbatim.
        var out: [String] = []
        var i = 0
        let n = lines.count

        while i < n {
            if isBlank(lines[i]) {
                out.append(lines[i])
                i += 1
                continue
            }
            // Gather a paragraph (consecutive non-blank lines).
            var j = i
            while j < n && !isBlank(lines[j]) {
                j += 1
            }
            let paragraph = Array(lines[i..<j])
            out.append(contentsOf: reflowParagraph(paragraph))
            i = j
        }

        return out
    }

    // MARK: - Paragraph reflow

    /// Minimum wrap width (in display columns) below which we assume the
    /// paragraph is NOT hard-wrapped terminal output and leave it untouched.
    /// Protects deliberately-short multi-line prose (e.g. two short lines) from
    /// being glued together. Terminal wrapping happens at far higher widths.
    private static let minWrapWidth = 24

    /// Slack (in display columns) subtracted from the detected wrap width to get
    /// the "this line is full" threshold. A hard-wrapped line is rarely filled
    /// to the exact column — the last word that didn't fit leaves a few columns
    /// empty — so a line counts as full when it reaches `wrapWidth - 3`. Larger
    /// slack would join more aggressively (riskier); 3 keeps us conservative.
    private static let wrapWidthSlack = 3

    private static func reflowParagraph(_ para: [String]) -> [String] {
        guard para.count > 1 else { return para }

        // Wrap width = max non-empty line DISPLAY width. Using max (rather than
        // a literal statistical mode, which is undefined when all line lengths
        // are distinct) is the conservative choice: it sets the highest
        // plausible wrap boundary, so we only join genuinely "full" lines and
        // otherwise under-reflow — never over-join. Honors 宁可漏洗.
        let wrapWidth = para.map { displayWidth($0) }.max() ?? 0
        let threshold = wrapWidth - wrapWidthSlack
        // If the block is too narrow to be hard-wrapped output, don't reflow
        // (but de-hyphenation, a strong explicit wrap signal, still applies).
        let widthQualifies = wrapWidth >= minWrapWidth

        var result: [String] = []
        var current = para[0]

        var k = 1
        while k < para.count {
            let next = para[k]

            if shouldJoin(current: current, next: next, threshold: threshold, widthQualifies: widthQualifies) {
                current = join(current, next)
            } else {
                result.append(current)
                current = next
            }
            k += 1
        }
        result.append(current)
        return result
    }

    // MARK: - Join decision

    private static func shouldJoin(current: String, next: String, threshold: Int, widthQualifies: Bool) -> Bool {
        // The next line must not begin a new block, in any case.
        if beginsNewBlock(next) { return false }
        if isBlank(next) { return false }

        // De-hyphenation is a strong explicit wrap signal: a trailing hyphen on
        // `current` followed by a lowercase-ASCII start on `next`. Join even if
        // the block is narrow / the current line is short.
        if endsWithDeHyphenJoin(current: current, next: next) { return true }

        // Defense in depth: even though reflow only runs on prose segments,
        // misclassification can happen — so refuse to glue lines that carry
        // code/command signals (trailing `\`, diff markers, code-punctuation
        // endings, operator endings, or symbol-dense lines). Bias to
        // UNDER-reflow: leaving two lines apart is safe; gluing code is not.
        if looksCodey(current) || looksCodey(next) { return false }

        // Only join when `next` reads as a plain prose continuation (begins with
        // a letter/digit/CJK word char, not punctuation or a symbol).
        if !beginsAsProseContinuation(next) { return false }

        // Otherwise only join "full" lines in a block wide enough to be wrapped.
        guard widthQualifies else { return false }
        return displayWidth(current) >= threshold
    }

    // MARK: - Code/command signal detection (reflow refusal)

    /// True if `line` shows a code or shell-command signal that makes joining it
    /// to a neighbour unsafe. Conservative — biased toward detecting code.
    private static func looksCodey(_ line: String) -> Bool {
        let trimmed = trimTrailingSpaces(trimLeadingSpaces(line))
        guard !trimmed.isEmpty else { return false }

        // Trailing backslash: shell line-continuation.
        if trimmed.hasSuffix("\\") { return true }

        // Leading diff markers.
        if beginsWithDiffMarker(trimmed) { return true }

        // Code-punctuation / operator ENDING (block opener, separator, operator
        // dangling at the wrapped boundary — none of which prose lines end on).
        if let last = trimmed.unicodeScalars.last, isCodeLineEnding(last) { return true }

        // Symbol-dense line (braces/brackets/operators/punctuation heavy).
        if symbolDensity(trimmed) >= maxProseSymbolDensity { return true }

        return false
    }

    /// Above this broad-symbol density a line is treated as code, not prose.
    /// English prose sits far below this (≈0); code/diff/shell lines exceed it.
    private static let maxProseSymbolDensity = 0.30

    /// Leading unified-diff markers: `@@`, `diff `, `--- `, `+++ `, or a `-`/`+`
    /// body marker (dash/plus immediately followed by NON-space content — `- `
    /// with a space is a bullet list item, handled by `beginsNewBlock`).
    private static func beginsWithDiffMarker(_ trimmed: String) -> Bool {
        if trimmed.hasPrefix("@@") { return true }
        if trimmed.hasPrefix("diff ") { return true }
        if trimmed.hasPrefix("--- ") || trimmed.hasPrefix("+++ ") { return true }
        if trimmed == "---" || trimmed == "+++" { return true }
        if let first = trimmed.first, first == "-" || first == "+" {
            let after = trimmed.dropFirst()
            if let a = after.first, a != " " && a != "\t" { return true }
        }
        return false
    }

    /// Code-line endings that prose never uses: block openers / containers
    /// (`{ ( [`), separators (`, ; :`), and dangling operators (`= < > & | + * /`).
    private static func isCodeLineEnding(_ s: UnicodeScalar) -> Bool {
        switch s {
        case "{", "(", "[", ",", ";", ":",
             "=", "<", ">", "&", "|", "+", "*", "/":
            return true
        default:
            return false
        }
    }

    /// Broad code-symbol density of a line: symbol chars ÷ non-space chars.
    private static func symbolDensity(_ s: String) -> Double {
        var symbols = 0
        var nonSpace = 0
        for scalar in s.unicodeScalars {
            if scalar == " " || scalar == "\t" { continue }
            nonSpace += 1
            if isCodeSymbol(scalar) { symbols += 1 }
        }
        guard nonSpace > 0 else { return 0 }
        return Double(symbols) / Double(nonSpace)
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

    /// True if `next` begins as a plain prose continuation: after optional
    /// leading spaces, the first scalar is a letter, digit, or CJK char — not a
    /// symbol/punctuation that would signal structured (code-like) content.
    private static func beginsAsProseContinuation(_ next: String) -> Bool {
        let t = trimLeadingSpaces(next)
        guard let first = t.unicodeScalars.first else { return false }
        if isCJK(first) { return true }
        // ASCII letter or digit.
        let v = first.value
        if (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) {
            return true
        }
        // Common sentence-start punctuation that is still prose (quotes, paren
        // for an aside). Conservative: treat opening quotes/paren as prose.
        switch first {
        case "\"", "'", "(", "“", "‘", "（":
            return true
        default:
            return false
        }
    }

    private static func endsWithDeHyphenJoin(current: String, next: String) -> Bool {
        let l = trimTrailingSpaces(current)
        let r = trimLeadingSpaces(next)
        guard l.hasSuffix("-"), let rf = r.unicodeScalars.first else { return false }
        return isLowercaseASCII(rf)
    }

    /// True if `line` begins a new Markdown block that must not be merged into
    /// the previous line: list item (`-`, `*`, `+`, or `N.`), ATX heading (`#`),
    /// blockquote (`>`), or a fence (``` / ~~~).
    private static func beginsNewBlock(_ line: String) -> Bool {
        let t = line.drop { $0 == " " || $0 == "\t" }
        guard let first = t.first else { return false }

        // Heading.
        if first == "#" { return true }
        // Blockquote.
        if first == ">" { return true }
        // Fence.
        if first == "`" || first == "~" {
            let prefix = t.prefix(3)
            if prefix == "```" || prefix == "~~~" { return true }
        }
        // Bullet list: marker char followed by a space.
        if first == "-" || first == "*" || first == "+" {
            let after = t.dropFirst()
            if after.first == " " { return true }
        }
        // Ordered list: digits then '.' or ')' then space.
        if first.isNumber {
            var rest = t
            while let c = rest.first, c.isNumber { rest = rest.dropFirst() }
            if let c = rest.first, c == "." || c == ")" {
                let after = rest.dropFirst()
                if after.first == " " || after.isEmpty { return true }
            }
        }
        return false
    }

    // MARK: - Joining two lines

    private static func join(_ left: String, _ right: String) -> String {
        let l = trimTrailingSpaces(left)
        let r = trimLeadingSpaces(right)

        // De-hyphenation: left ends with '-' and right starts lowercase ASCII.
        if l.hasSuffix("-"), let rf = r.unicodeScalars.first, isLowercaseASCII(rf) {
            return String(l.dropLast()) + r
        }

        // CJK–CJK boundary: no space.
        if let lastL = l.unicodeScalars.last, let firstR = r.unicodeScalars.first,
            isCJK(lastL), isCJK(firstR)
        {
            return l + r
        }

        // Default: single space.
        return l + " " + r
    }

    // MARK: - Character helpers

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Approximate terminal display width: CJK/fullwidth scalars count as 2
    /// columns, everything else as 1. Used so CJK paragraphs (short in
    /// character count but wide on screen) are recognized as wrapped.
    private static func displayWidth(_ s: String) -> Int {
        var w = 0
        for scalar in s.unicodeScalars {
            w += isCJK(scalar) ? 2 : 1
        }
        return w
    }

    private static func trimTrailingSpaces(_ s: String) -> String {
        var sub = Substring(s)
        while let last = sub.last, last == " " || last == "\t" { sub = sub.dropLast() }
        return String(sub)
    }

    private static func trimLeadingSpaces(_ s: String) -> String {
        String(s.drop { $0 == " " || $0 == "\t" })
    }

    private static func isLowercaseASCII(_ s: UnicodeScalar) -> Bool {
        s.value >= 0x61 && s.value <= 0x7A
    }

    /// CJK test covering the common ranges so a CJK–CJK wrap boundary joins
    /// with no space: CJK Unified Ideographs (+Ext A), Hiragana, Katakana,
    /// Hangul syllables, and CJK symbols/punctuation (fullwidth comma etc.).
    private static func isCJK(_ s: UnicodeScalar) -> Bool {
        let v = s.value
        return (v >= 0x3000 && v <= 0x303F)    // CJK symbols & punctuation
            || (v >= 0x3040 && v <= 0x30FF)    // Hiragana + Katakana
            || (v >= 0x3400 && v <= 0x4DBF)    // CJK Ext A
            || (v >= 0x4E00 && v <= 0x9FFF)    // CJK Unified Ideographs
            || (v >= 0xF900 && v <= 0xFAFF)    // CJK Compatibility Ideographs
            || (v >= 0xFF00 && v <= 0xFFEF)    // Halfwidth & Fullwidth Forms
    }
}
