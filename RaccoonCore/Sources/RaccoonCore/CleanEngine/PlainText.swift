import Foundation

/// Markdown → plain text ("转纯文本"). Removes Markdown decoration but keeps
/// text and structure (line/paragraph breaks).
///
/// Block constructs (headings, list markers, blockquotes) are stripped per
/// line; fenced code fences are dropped while their inner code lines are kept
/// verbatim (no inline processing inside code). Inline constructs (images,
/// links, inline code, emphasis) are unwrapped to their visible text.
enum PlainText {

    static func toPlainText(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)

        var inFence = false
        var fenceLen = 0

        for line in lines {
            if inFence {
                if let len = fenceMarkerLength(line), len >= fenceLen {
                    // Closing fence — drop it, leave the fence.
                    inFence = false
                    fenceLen = 0
                } else {
                    // Code line inside a fence — keep verbatim.
                    out.append(line)
                }
                continue
            }

            if let len = fenceMarkerLength(line) {
                // Opening fence — drop it, enter fence.
                inFence = true
                fenceLen = len
                continue
            }

            out.append(transformProseLine(line))
        }

        return out.joined(separator: "\n")
    }

    // MARK: - Fence detection (info string may follow an opening backtick fence)

    /// Returns the fence length if the line is a fence marker (``` or ~~~,
    /// length ≥ 3, after optional leading whitespace); else nil. For a closing
    /// fence the caller checks length ≥ opening.
    private static func fenceMarkerLength(_ line: String) -> Int? {
        let t = line.drop { $0 == " " || $0 == "\t" }
        guard let first = t.first, first == "`" || first == "~" else { return nil }
        var count = 0
        var idx = t.startIndex
        while idx < t.endIndex && t[idx] == first {
            count += 1
            idx = t.index(after: idx)
        }
        guard count >= 3 else { return nil }
        if first == "`" && t[idx...].contains("`") { return nil }
        return count
    }

    // MARK: - Per-line prose transform

    private static func transformProseLine(_ line: String) -> String {
        var s = stripLeadingBlockMarkers(line)
        s = stripInlineImagesAndLinks(s)
        s = stripInlineCode(s)
        s = stripEmphasis(s)
        return s
    }

    /// Strip a leading ATX heading run, blockquote markers, and a single list
    /// marker (bullet or ordered). Repeats for nested blockquotes.
    private static func stripLeadingBlockMarkers(_ line: String) -> String {
        var s = Substring(line)

        // Blockquotes: possibly nested "> > ".
        while true {
            let afterSpaces = s.drop { $0 == " " || $0 == "\t" }
            if afterSpaces.first == ">" {
                s = afterSpaces.dropFirst()
                // Optional single space after '>'.
                if s.first == " " { s = s.dropFirst() }
            } else {
                break
            }
        }

        // ATX heading: leading run of '#'(after optional spaces) then a space.
        let afterSpaces = s.drop { $0 == " " || $0 == "\t" }
        if afterSpaces.first == "#" {
            var hashes = 0
            var rest = afterSpaces
            while rest.first == "#" { hashes += 1; rest = rest.dropFirst() }
            if rest.first == " " {
                // Drop the hashes + the one space.
                s = rest.dropFirst()
                return String(s)
            }
            // Not a valid heading (e.g. "#NoSpace") — leave as-is below.
        }

        // List markers: bullet ('-','*','+' followed by space) or ordered
        // ('N.' / 'N)' followed by space). Strip one marker, keep indentation
        // removed up to the content.
        let lead = s.drop { $0 == " " || $0 == "\t" }
        if let first = lead.first {
            if first == "-" || first == "*" || first == "+" {
                let after = lead.dropFirst()
                if after.first == " " {
                    return String(after.drop { $0 == " " })
                }
            }
            if first.isNumber {
                var rest = lead
                while let c = rest.first, c.isNumber { rest = rest.dropFirst() }
                if let c = rest.first, c == "." || c == ")" {
                    let after = rest.dropFirst()
                    if after.first == " " {
                        return String(after.drop { $0 == " " })
                    }
                }
            }
        }

        return String(s)
    }

    // MARK: - Inline transforms

    /// Images `![alt](url)` → `alt`; links `[text](url)` → `text (url)`.
    /// Images first so the `!` form isn't half-consumed by the link rule.
    private static func stripInlineImagesAndLinks(_ s: String) -> String {
        var result = s
        result = replace(result, pattern: "!\\[([^\\]]*)\\]\\(([^)]*)\\)", template: "$1")
        result = replace(result, pattern: "\\[([^\\]]*)\\]\\(([^)]*)\\)", template: "$1 ($2)")
        return result
    }

    /// Inline code: `` `text` `` → `text`. Handles single-backtick spans.
    private static func stripInlineCode(_ s: String) -> String {
        replace(s, pattern: "`([^`]*)`", template: "$1")
    }

    /// Emphasis: `**x**`, `__x__`, `*x*`, `_x_` → `x`. Longer markers first.
    private static func stripEmphasis(_ s: String) -> String {
        var result = s
        result = replace(result, pattern: "\\*\\*([^*]+)\\*\\*", template: "$1")
        result = replace(result, pattern: "__([^_]+)__", template: "$1")
        result = replace(result, pattern: "\\*([^*]+)\\*", template: "$1")
        result = replace(result, pattern: "_([^_]+)_", template: "$1")
        return result
    }

    // MARK: - Regex helper

    private static func replace(_ s: String, pattern: String, template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }
}
