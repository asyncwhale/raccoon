import Foundation

/// Removes terminal escape noise from a single line of text.
///
/// Two modes:
///  • `strip` (PROSE/TABLE) — removes ANSI escape sequences (CSI / OSC / other
///    ESC-prefixed) AND single-scalar invisible noise: C0 controls (except
///    newline/tab), DEL, zero-width chars and BOM, and maps NBSP → space.
///  • `stripEscapesOnly` (CODE — the RED LINE) — removes ONLY the ANSI / OSC /
///    ESC escape sequences (unambiguous terminal coloring). It PRESERVES every
///    other byte: NBSP, zero-width, BOM, and all visible/semantic chars. Code
///    may legitimately contain those bytes, so altering them would damage code.
///
/// Implemented as an explicit scan rather than regex because OSC terminators
/// (BEL `\u{07}` or ST `ESC \`) and the variety of ESC sequences are cleaner to
/// handle with a small state machine than with multiple regex passes.
enum AnsiStripper {

    /// PROSE/TABLE strip: escape sequences + invisible single-scalar noise,
    /// NBSP → space. See type doc.
    static func strip(_ line: String) -> String {
        scan(line, escapesOnly: false)
    }

    /// CODE strip (RED LINE): ONLY escape sequences are removed; NBSP, zero-
    /// width, BOM, and every visible char are preserved verbatim. See type doc.
    static func stripEscapesOnly(_ line: String) -> String {
        scan(line, escapesOnly: true)
    }

    /// Shared scan. When `escapesOnly` is true, only CSI/OSC/ESC sequences are
    /// removed and all other scalars pass through untouched (the code path).
    private static func scan(_ line: String, escapesOnly: Bool) -> String {
        // Operate on the input string's view directly. Lines passed in never
        // contain "\n" (the caller splits on it), but may contain "\t".
        let scalars = Array(line.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)

        var i = 0
        let n = scalars.count
        while i < n {
            let s = scalars[i]

            if s == esc {
                // An escape sequence. Look at the next scalar to classify.
                let next = i + 1 < n ? scalars[i + 1] : nil
                if next == leftBracket {
                    // CSI: ESC [ <0-9;?>* <intermediate ' '..'/'>* <final '@'..'~'>
                    i = skipCSI(scalars, from: i + 2)
                } else if next == rightBracket {
                    // OSC: ESC ] ... (BEL | ESC \)
                    i = skipOSC(scalars, from: i + 2)
                } else if next != nil {
                    // Other escape: ESC <one char>. Drop both.
                    i += 2
                } else {
                    // Lone trailing ESC. Drop it.
                    i += 1
                }
                continue
            }

            // Code path: only escape sequences are stripped — pass everything
            // else (NBSP, zero-width, BOM, visible chars) through untouched.
            if escapesOnly {
                out.append(s)
                i += 1
                continue
            }

            if shouldDrop(s) {
                i += 1
                continue
            }

            if s == nbsp {
                out.append(space)
                i += 1
                continue
            }

            out.append(s)
            i += 1
        }

        return String(out)
    }

    // MARK: - Escape-sequence skippers (return index just past the sequence)

    /// CSI body: parameter bytes `[0-9;?]`, intermediate bytes `[ -/]`
    /// (0x20–0x2F), then a final byte `[@-~]` (0x40–0x7E). We drop the final
    /// byte too. If we run off the end without a final byte, drop to end.
    private static func skipCSI(_ scalars: [UnicodeScalar], from start: Int) -> Int {
        var i = start
        let n = scalars.count
        // Parameter + intermediate bytes.
        while i < n {
            let v = scalars[i].value
            let isParam = (v >= 0x30 && v <= 0x3F)        // 0-9 : ; < = > ?
            let isIntermediate = (v >= 0x20 && v <= 0x2F)  // space ! " # $ % & ' ( ) * + , - . /
            if isParam || isIntermediate {
                i += 1
                continue
            }
            break
        }
        // Final byte.
        if i < n {
            let v = scalars[i].value
            if v >= 0x40 && v <= 0x7E {
                return i + 1
            }
            // Malformed (no proper final byte). Drop the one terminating char to
            // make progress.
            return i + 1
        }
        return i
    }

    /// OSC body: anything up to a terminator, which is BEL (`\u{07}`) or
    /// ST (`ESC \`). Drop the terminator too.
    private static func skipOSC(_ scalars: [UnicodeScalar], from start: Int) -> Int {
        var i = start
        let n = scalars.count
        while i < n {
            let s = scalars[i]
            if s == bel {
                return i + 1
            }
            if s == esc {
                // ST is ESC \. Consume both if the backslash follows.
                if i + 1 < n && scalars[i + 1] == backslash {
                    return i + 2
                }
                // A bare ESC inside OSC: treat as terminator boundary, stop
                // here so the ESC can be reclassified by the outer loop.
                return i
            }
            i += 1
        }
        return i
    }

    // MARK: - Single-scalar drop test

    /// True for invisible noise we strip: C0 controls except `\n`/`\t`, the
    /// DEL char, BOM/zero-width family, and the word-joiner U+2060.
    private static func shouldDrop(_ s: UnicodeScalar) -> Bool {
        let v = s.value
        // C0 controls 0x00..0x1F except TAB (0x09) and LF (0x0A). (ESC 0x1B is
        // handled before this is reached, but guard anyway.)
        if v < 0x20 {
            if v == 0x09 || v == 0x0A { return false }
            return true
        }
        // DEL.
        if v == 0x7F { return true }
        // BOM / zero-width space / ZWNJ / ZWJ.
        if v == 0xFEFF { return true }
        if v >= 0x200B && v <= 0x200D { return true }
        // Word joiner.
        if v == 0x2060 { return true }
        return false
    }

    // MARK: - Named scalars

    private static let esc: UnicodeScalar = "\u{1B}"
    private static let leftBracket: UnicodeScalar = "["
    private static let rightBracket: UnicodeScalar = "]"
    private static let backslash: UnicodeScalar = "\\"
    private static let bel: UnicodeScalar = "\u{07}"
    private static let nbsp: UnicodeScalar = "\u{00A0}"
    private static let space: UnicodeScalar = " "
}
