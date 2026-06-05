import Foundation

/// The kind of a contiguous run of lines.
enum SegmentKind: Equatable {
    case code
    case prose
    case table
}

/// A contiguous run of lines of one kind.
struct Segment: Equatable {
    let kind: SegmentKind
    let lines: [String]
}

/// Splits lines into code / prose / table segments.
///
/// Conservative by design — biased toward `.code` when unsure, because the RED
/// LINE is that code is never damaged. `.code` and `.table` segments are never
/// reflowed; only `.prose` is subject to box/pad/reflow rules in later layers.
///
/// Precedence:
///  1. Fenced code (``` / ~~~) — a stateful scan; the closing fence must be at
///     least as long as the opening one. Everything inside (inclusive) is code.
///  2. Within non-fenced runs, contiguous blocks are classified in this order
///     (CODE protection wins over table stripping — the RED LINE):
///       ASCII graph (git log --graph) → indented code (≥4-space/tab) →
///       symbol-dense code (≥2-space sub-CommonMark code) → table (a CONFIDENT
///       drawn table only: a closed Unicode box or a column-framed box run, or
///       a Markdown `|---|` table) → box-drawing run that is NOT a confident
///       table (preserved verbatim as code — e.g. `tree` output) → prose.
enum Segmenter {

    static func segment(_ lines: [String]) -> [Segment] {
        // Pass 1: carve out fenced code regions; classify the rest recursively.
        var segments: [Segment] = []
        var i = 0
        let n = lines.count

        while i < n {
            if let fenceLen = openingFenceLength(lines[i]) {
                // Start of a fenced block. Find its close.
                var j = i + 1
                while j < n {
                    if isClosingFence(lines[j], openLength: fenceLen) {
                        break
                    }
                    j += 1
                }
                // Include the closing fence line if found; otherwise run to end.
                let end = j < n ? j : n - 1
                let block = Array(lines[i...end])
                segments.append(Segment(kind: .code, lines: block))
                i = end + 1
            } else {
                // Collect a run of non-fence lines, then sub-classify it.
                var j = i
                while j < n && openingFenceLength(lines[j]) == nil {
                    j += 1
                }
                let run = Array(lines[i..<j])
                segments.append(contentsOf: classifyNonFenced(run))
                i = j
            }
        }

        // Merge adjacent segments of the same kind. classifyNonFenced can emit
        // adjacent same-kind blocks (e.g. a box run preserved as code directly
        // followed by an indented-code run, or two prose runs separated only by
        // a now-absent boundary), so this coalescing is load-bearing.
        return mergeAdjacent(segments)
    }

    // MARK: - Fence detection

    /// If `line` is a fence opener/closer, the number of fence chars; else nil.
    /// A fence line's trimmed text starts with 3+ backticks or 3+ tildes, and
    /// (for backticks) any info string must not itself contain a backtick.
    private static func openingFenceLength(_ line: String) -> Int? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let fenceChar = first
        var count = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex && trimmed[idx] == fenceChar {
            count += 1
            idx = trimmed.index(after: idx)
        }
        guard count >= 3 else { return nil }
        // For backtick fences, the info string (rest of line) must not contain a
        // backtick (CommonMark rule). Tilde fences allow anything.
        if fenceChar == "`" {
            let info = trimmed[idx...]
            if info.contains("`") { return nil }
        }
        return count
    }

    /// A closing fence: same fence char, length ≥ opening, and nothing but the
    /// fence chars + trailing whitespace after it.
    private static func isClosingFence(_ line: String, openLength: Int) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmed.first, first == "`" || first == "~" else { return false }
        let fenceChar = first
        var count = 0
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex && trimmed[idx] == fenceChar {
            count += 1
            idx = trimmed.index(after: idx)
        }
        guard count >= openLength else { return false }
        // Only trailing whitespace may follow a closing fence.
        let rest = trimmed[idx...]
        return rest.allSatisfy { $0 == " " || $0 == "\t" }
    }

    // MARK: - Non-fenced classification

    /// Classify a run that contains no fence lines into table / code / prose
    /// sub-segments, scanning greedily.
    ///
    /// CODE detection runs BEFORE table detection so the RED LINE wins: a real
    /// drawn table only loses its borders when it is CONFIDENTLY a table, and
    /// box chars sitting in code-looking content are preserved. Order:
    ///   graph → indented code (≥4sp/tab) → symbol-dense code (≥2sp) →
    ///   confident drawn table → non-table box run (preserved as code) → prose.
    private static func classifyNonFenced(_ lines: [String]) -> [Segment] {
        var out: [Segment] = []
        var i = 0
        let n = lines.count

        while i < n {
            // A Markdown `|---|` table is an unambiguous, confident table; check
            // it before code so a pipe header row is not mistaken for a git
            // graph (whose connectors are also pipes).
            if let len = markdownTableRunLength(lines, from: i) {
                out.append(Segment(kind: .table, lines: Array(lines[i..<(i + len)])))
                i += len
                continue
            }
            if let len = codeRunLength(lines, from: i) {
                out.append(Segment(kind: .code, lines: Array(lines[i..<(i + len)])))
                i += len
                continue
            }
            if let len = drawnTableRunLength(lines, from: i) {
                out.append(Segment(kind: .table, lines: Array(lines[i..<(i + len)])))
                i += len
                continue
            }
            // A box-drawing run that is NOT a confident table (e.g. `tree`
            // output, a lone box scalar): preserve it verbatim as code — never
            // strip its box chars. Bias to preserve (宁可漏洗绝不砸代码).
            if let len = boxRunLength(lines, from: i) {
                out.append(Segment(kind: .code, lines: Array(lines[i..<(i + len)])))
                i += len
                continue
            }
            // Prose: accumulate until the next special block begins.
            var j = i
            while j < n
                && markdownTableRunLength(lines, from: j) == nil
                && codeRunLength(lines, from: j) == nil
                && drawnTableRunLength(lines, from: j) == nil
                && boxRunLength(lines, from: j) == nil
            {
                j += 1
            }
            // Guarantee progress.
            if j == i { j = i + 1 }
            out.append(Segment(kind: .prose, lines: Array(lines[i..<j])))
            i = j
        }

        return out
    }

    /// Length of a CODE run starting at `start`, or nil. Combines all the
    /// code-detection signals (graph, ≥4-space/tab indent, symbol-dense ≥2-space
    /// indent) so the caller can short-circuit table detection when any fires.
    private static func codeRunLength(_ lines: [String], from start: Int) -> Int? {
        if let len = graphRunLength(lines, from: start) { return len }
        if let len = indentedCodeRunLength(lines, from: start) { return len }
        if let len = symbolDenseCodeRunLength(lines, from: start) { return len }
        return nil
    }

    // MARK: - Table detection (confident drawn tables only)

    /// Length of a CONFIDENT drawn-table run starting at `start`, or nil.
    ///
    /// A run is a confident table only when it is unambiguously a real drawn
    /// table — never a single box scalar, never `tree`/`eza --tree` output:
    ///   • a Markdown table: a pipe row followed by a `|---|` separator row, or
    ///   • a Unicode box that is CLOSED (a top border line AND a bottom border
    ///     line — pure box-drawing borders — framing ≥2 border lines), or
    ///   • a column-framed box: every line in the box run, after trimming
    ///     spaces, both starts and ends with a vertical box char (`│`-family).
    /// Otherwise nil (the caller keeps such box runs verbatim as code).
    /// (Markdown `|---|` tables are detected separately, earlier — see
    /// `markdownTableRunLength`.)
    private static func drawnTableRunLength(_ lines: [String], from start: Int) -> Int? {
        // Unicode box run: only a confident (closed or column-framed) box wins.
        if let len = boxRunLength(lines, from: start) {
            let run = Array(lines[start..<(start + len)])
            if isClosedBox(run) || isColumnFramedBox(run) {
                return len
            }
        }
        return nil
    }

    /// Length of a Markdown `|---|` table run starting at `start`, or nil: a
    /// pipe row immediately followed by a separator row (`|---|`), then any
    /// further pipe/separator rows. This pattern is unambiguous, so it is
    /// detected before code (a pipe header would otherwise look graph-like).
    private static func markdownTableRunLength(_ lines: [String], from start: Int) -> Int? {
        guard start + 1 < lines.count,
            isPipeRow(lines[start]),
            isSeparatorRow(lines[start + 1])
        else { return nil }
        var j = start
        while j < lines.count && (isPipeRow(lines[j]) || isSeparatorRow(lines[j])) {
            j += 1
        }
        return j - start
    }

    /// Length of a contiguous run of lines each containing ≥1 box-drawing
    /// scalar, or nil if `lines[start]` has none. This is purely structural —
    /// it makes NO table judgement (see `drawnTableRunLength` for that).
    private static func boxRunLength(_ lines: [String], from start: Int) -> Int? {
        guard containsBoxDrawing(lines[start]) else { return nil }
        var j = start
        while j < lines.count && containsBoxDrawing(lines[j]) {
            j += 1
        }
        return j - start
    }

    /// A closed box: the run contains at least one pure top/bottom BORDER line
    /// near each end. We require ≥2 border lines total and that the FIRST and
    /// LAST lines of the run are both border lines (top frame + bottom frame).
    private static func isClosedBox(_ run: [String]) -> Bool {
        guard run.count >= 2 else { return false }
        let borderCount = run.filter { isPureBoxBorder($0) }.count
        guard borderCount >= 2 else { return false }
        return isPureBoxBorder(run.first!) && isPureBoxBorder(run.last!)
    }

    /// A column-framed box: every non-empty line in the run, after trimming
    /// surrounding spaces, both begins and ends with a vertical box char
    /// (`│`-family). Matches aligned-column output framed by side borders even
    /// without a drawn top/bottom (e.g. `│ apple   │`). Excludes `tree` output,
    /// whose rows end in ordinary text, not a box char.
    private static func isColumnFramedBox(_ run: [String]) -> Bool {
        var sawRow = false
        for line in run {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            guard let first = t.unicodeScalars.first, let last = t.unicodeScalars.last else {
                return false
            }
            guard isVerticalBox(first) && isVerticalBox(last) else { return false }
            sawRow = true
        }
        return sawRow
    }

    /// A line consisting only of box-drawing scalars and spaces (a pure drawn
    /// border, e.g. `┌────┐` or `├────┤` or `└────┘`), with ≥1 box scalar.
    private static func isPureBoxBorder(_ line: String) -> Bool {
        var sawBox = false
        for scalar in line.unicodeScalars {
            if scalar == " " || scalar == "\t" { continue }
            if scalar.value >= 0x2500 && scalar.value <= 0x257F {
                sawBox = true
            } else {
                return false
            }
        }
        return sawBox
    }

    /// Vertical box-drawing chars used as left/right table borders.
    private static func isVerticalBox(_ s: UnicodeScalar) -> Bool {
        // │ ┃ (light/heavy vertical) and ║ (double vertical).
        s == "\u{2502}" || s == "\u{2503}" || s == "\u{2551}"
    }

    private static func containsBoxDrawing(_ line: String) -> Bool {
        for scalar in line.unicodeScalars where scalar.value >= 0x2500 && scalar.value <= 0x257F {
            return true
        }
        return false
    }

    private static func isPipeRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        // At least one pipe and some non-pipe, non-space content.
        return t.contains("|") && t.contains { $0 != "|" && $0 != " " }
    }

    /// A Markdown table separator row: pipes, dashes, colons, spaces only, with
    /// at least one dash.
    private static func isSeparatorRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        return t.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    // MARK: - ASCII graph (git log --graph)

    /// Length of a contiguous git-graph run starting at `start`, or nil.
    ///
    /// To avoid mistaking a bullet list (`* item`) for a graph, we require the
    /// run to contain at least one line whose *leading graph run* includes a
    /// connector character (`|`, `/`, `\`). Lines belong to the run if they
    /// begin with a graph char and have a leading graph run of graph chars.
    private static func graphRunLength(_ lines: [String], from start: Int) -> Int? {
        var j = start
        var sawConnector = false
        while j < lines.count, let leading = graphLeadingRun(lines[j]) {
            if leading.contains(where: { $0 == "|" || $0 == "/" || $0 == "\\" }) {
                sawConnector = true
            }
            j += 1
        }
        let len = j - start
        guard len >= 1, sawConnector else { return nil }
        return len
    }

    /// The leading run of graph characters of a line, if the line begins with a
    /// graph char (`* | / \ _ +` or space-separated graph chars). Returns nil if
    /// the line does not begin with a graph char.
    ///
    /// We treat a line as graph-like if it starts (after optional spaces) with
    /// one of `* | / \ _ +`, and its leading portion up to the first "word"
    /// consists only of graph chars and spaces.
    private static func graphLeadingRun(_ line: String) -> String? {
        let graphChars: Set<Character> = ["*", "|", "/", "\\", "_", "+", " "]
        // Must contain a non-space graph char in the leading region.
        var leading = ""
        for ch in line {
            if graphChars.contains(ch) {
                leading.append(ch)
            } else {
                break
            }
        }
        // The leading run must contain at least one structural graph char and
        // the line must start with one (not a plain indented line of spaces).
        guard let firstNonSpace = leading.first(where: { $0 != " " }) else { return nil }
        let structural: Set<Character> = ["*", "|", "/", "\\"]
        // Require the first non-space char to be a structural graph char so we
        // don't grab e.g. "  + something" prose; "+" alone is too weak.
        guard structural.contains(firstNonSpace) else { return nil }
        return leading
    }

    // MARK: - Indented code

    /// Length of an indented-code run starting at `start`, or nil. Requires ≥2
    /// consecutive lines each indented ≥4 spaces or a leading tab. Blank lines
    /// do not extend the block by themselves and are not included unless
    /// surrounded by indented lines… for simplicity we only group the contiguous
    /// indented lines (blank lines break the run).
    private static func indentedCodeRunLength(_ lines: [String], from start: Int) -> Int? {
        var j = start
        while j < lines.count && isIndentedCodeLine(lines[j]) {
            j += 1
        }
        let len = j - start
        return len >= 2 ? len : nil
    }

    private static func isIndentedCodeLine(_ line: String) -> Bool {
        if line.hasPrefix("\t") { return true }
        if line.hasPrefix("    ") { return true }
        return false
    }

    // MARK: - Symbol-dense code (sub-CommonMark, ≥2-space indent)

    /// Length of a symbol-dense code run starting at `start`, or nil.
    ///
    /// Implements the PRD's second code signal — "continuous indentation +
    /// symbol density" — to protect code pasted without a fence and indented
    /// only 2–3 spaces (JS/TS/JSON/YAML), below CommonMark's 4-space bar.
    ///
    /// A run qualifies when ALL of:
    ///   • ≥2 consecutive lines, each indented ≥2 leading spaces or a tab
    ///     (blank lines break the run);
    ///   • the run carries ≥`minStrongSymbols` STRONG structural symbols
    ///     (`{ } ; =`), which are rare in indented prose / block quotes; and
    ///   • the broad code-symbol density (symbols ÷ non-space chars) is
    ///     ≥`minSymbolDensity`.
    /// The strong-symbol + density gate keeps indented prose (wrapped sentences,
    /// block quotes) classified as prose. Bias to protect when code-ish.
    private static func symbolDenseCodeRunLength(_ lines: [String], from start: Int) -> Int? {
        var j = start
        while j < lines.count && isSubIndentedLine(lines[j]) {
            j += 1
        }
        let len = j - start
        guard len >= 2 else { return nil }

        let run = lines[start..<j]
        var strong = 0
        var symbols = 0
        var nonSpace = 0
        for line in run {
            for scalar in line.unicodeScalars {
                if scalar == " " || scalar == "\t" { continue }
                nonSpace += 1
                if isStrongCodeSymbol(scalar) { strong += 1 }
                if isCodeSymbol(scalar) { symbols += 1 }
            }
        }
        guard nonSpace > 0 else { return nil }
        guard strong >= minStrongSymbols else { return nil }
        let density = Double(symbols) / Double(nonSpace)
        guard density >= minSymbolDensity else { return nil }
        return len
    }

    /// Minimum count of strong structural symbols (`{ } ; =`) in a symbol-dense
    /// run. Two keeps a single stray `=` in an indented prose line from tripping
    /// detection while catching real multi-line code.
    private static let minStrongSymbols = 2

    /// Minimum broad-symbol density for a symbol-dense run. 0.10 (10%) is well
    /// above the symbol density of indented prose (a comma/period here or there)
    /// yet easily met by braces/operators/brackets-laden code.
    private static let minSymbolDensity = 0.10

    /// A line indented by ≥2 leading spaces or a leading tab (sub-CommonMark).
    private static func isSubIndentedLine(_ line: String) -> Bool {
        if line.hasPrefix("\t") { return true }
        return line.hasPrefix("  ")
    }

    /// Strong structural symbols that are rare in prose: braces, semicolon,
    /// equals. Their presence is a high-signal code indicator.
    private static func isStrongCodeSymbol(_ s: UnicodeScalar) -> Bool {
        s == "{" || s == "}" || s == ";" || s == "="
    }

    /// Broad code-symbol set (braces/brackets/parens/operators/punctuation) used
    /// for the density measure.
    private static func isCodeSymbol(_ s: UnicodeScalar) -> Bool {
        switch s {
        case "{", "}", "(", ")", "[", "]", ";", ":", "=", "<", ">",
             "&", "|", "!", "+", "*", "/", "%", "^", "~", ",", "\"", "'", "`":
            return true
        default:
            return false
        }
    }

    // MARK: - Merge

    private static func mergeAdjacent(_ segments: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for seg in segments {
            if let last = out.last, last.kind == seg.kind {
                out[out.count - 1] = Segment(kind: last.kind, lines: last.lines + seg.lines)
            } else {
                out.append(seg)
            }
        }
        return out
    }
}
