import Testing
import Foundation
@testable import RaccoonCore

// MARK: - Golden corpus

/// Every corpus pair must clean to its expected output.
@Test func corpusCleansToExpected() {
    for c in CorpusRunner.corpusCases() {
        let actual = CleanEngine.clean(c.input).cleaned
        #expect(
            actual == c.expected,
            "\(CorpusRunner.diff(name: c.name, expected: c.expected, actual: actual))"
        )
    }
}

// MARK: - Lossless restore (RED LINE prerequisite)

/// `clean(raw).original` must equal `raw` for every corpus input.
@Test func originalIsLosslessForCorpus() {
    for c in CorpusRunner.corpusCases() {
        #expect(CleanEngine.clean(c.input).original == c.input, "original != raw for \(c.name)")
    }
}

/// `clean(raw).original == raw` for assorted tricky inputs.
@Test func originalIsLosslessForAssortedInputs() {
    let inputs = [
        "",
        "\n",
        "\n\n\n",
        "no trailing newline",
        "trailing newline\n",
        "tab\tseparated\tvalues",
        "\u{1B}[31mred\u{1B}[0m",
        "mixed 中文 and english",
        "   leading and trailing   \n",
        "```\ncode\n```\n",
    ]
    for input in inputs {
        #expect(CleanEngine.clean(input).original == input)
    }
}

// MARK: - Layer 1.2 — ANSI / control / zero-width stripping

@Test func stripsCSIColorAndResetSequences() {
    let raw = "\u{1B}[31mERROR\u{1B}[0m done"
    #expect(CleanEngine.clean(raw).cleaned == "ERROR done")
}

@Test func stripsBOMandZeroWidthAndMapsNBSP() {
    // BOM + zero-width space inside a word; NBSP between two words.
    let raw = "\u{FEFF}hel\u{200B}lo wor\u{00A0}ld"
    #expect(CleanEngine.clean(raw).cleaned == "hello wor ld")
}

@Test func stripsOSCSequenceTerminatedByBEL() {
    // OSC 0; title \a  — a window-title set; pure noise.
    let raw = "before\u{1B}]0;my title\u{07}after"
    #expect(CleanEngine.clean(raw).cleaned == "beforeafter")
}

@Test func stripsOSCSequenceTerminatedByST() {
    // OSC terminated by ST (ESC backslash).
    let raw = "before\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\after"
    #expect(CleanEngine.clean(raw).cleaned == "beforelinkafter")
}

@Test func preservesTabsAndNewlines() {
    let raw = "a\tb\nc\td"
    let cleaned = CleanEngine.clean(raw).cleaned
    #expect(cleaned == "a\tb\nc\td")
}

@Test func dropsLoneC0ControlsButKeepsTabNewline() {
    // Backspace (0x08), vertical tab (0x0B), form feed (0x0C), DEL (0x7F) are
    // dropped. CR is NOT included here — it is a line terminator and is
    // normalized to a newline up front (see `normalizesCRAndCRLFToNewline`).
    let raw = "a\u{08}b\u{0B}c\u{0C}d\u{7F}e"
    #expect(CleanEngine.clean(raw).cleaned == "abcde")
}

/// FIX 4: CRLF (`\r\n`) and lone CR (`\r`, old-Mac) normalize to LF up front,
/// so cleaned output uses LF only. Lossless restore still holds because
/// `original` stores the raw bytes verbatim (asserted in CodeIntegrityTests).
@Test func normalizesCRAndCRLFToNewline() {
    // CRLF → LF.
    #expect(CleanEngine.clean("a\r\nb\r\n").cleaned == "a\nb\n")
    // Lone CR → LF (becomes a line break, not dropped).
    #expect(CleanEngine.clean("a\rb").cleaned == "a\nb")
    // Restore stays lossless for CRLF input.
    let raw = "x\r\ny\r\n"
    #expect(CleanEngine.clean(raw).original == raw)
}

@Test func cleanIsIdempotentOnAlreadyCleanText() {
    let clean = "ERROR done\nhello world"
    #expect(CleanEngine.clean(clean).cleaned == clean)
}
