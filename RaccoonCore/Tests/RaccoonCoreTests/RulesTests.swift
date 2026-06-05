import Testing
import Foundation
@testable import RaccoonCore

// MARK: - Prose trailing whitespace

@Test func prose_trimsTrailingWhitespace() {
    let lines = ["hello world   ", "second line\t", "no trailing"]
    let out = Rules.cleanProseLines(lines)
    #expect(out == ["hello world", "second line", "no trailing"])
}

@Test func prose_keepsBlankLines() {
    let lines = ["para one", "", "para two"]
    let out = Rules.cleanProseLines(lines)
    #expect(out == ["para one", "", "para two"])
}

@Test func prose_stripsLeadingBoxBorderThenLeftoverIndent() {
    // A prose line that starts with a box border + padding.
    let lines = ["\u{2502} some text"]
    let out = Rules.cleanProseLines(lines)
    #expect(out == ["some text"])
}

@Test func prose_doesNotStripOrdinaryLeadingIndent() {
    // No box border: a normal (non-box) leading indent in prose is preserved
    // (we only remove indent that's left over after a stripped border).
    let lines = ["   indented prose stays"]
    let out = Rules.cleanProseLines(lines)
    #expect(out == ["   indented prose stays"])
}

// MARK: - Table cells

@Test func table_extractsCellTextDroppingBorders() {
    let lines = [
        "\u{250C}\u{2500}\u{2500}\u{2510}",  // ┌──┐  (border only)
        "\u{2502} Name   \u{2502}",            // │ Name   │
        "\u{2502} Alice  \u{2502}",            // │ Alice  │
        "\u{2514}\u{2500}\u{2500}\u{2518}",  // └──┘  (border only)
    ]
    let out = Rules.cleanTableLines(lines)
    #expect(out == ["Name", "Alice"])
}

@Test func table_alignedColumnsLoseBorderAndPad() {
    let lines = [
        "\u{2502} apple    \u{2502}",
        "\u{2502} banana   \u{2502}",
        "\u{2502} cherry   \u{2502}",
    ]
    let out = Rules.cleanTableLines(lines)
    #expect(out == ["apple", "banana", "cherry"])
}

@Test func table_markdownTableKeepsCellsDropsSeparator() {
    let lines = [
        "| Name | Age |",
        "|------|-----|",
        "| Bob  | 30  |",
    ]
    let out = Rules.cleanTableLines(lines)
    // Separator row dropped; cell rows keep text (single-line-per-row is fine).
    #expect(out.contains { $0.contains("Name") && $0.contains("Age") })
    #expect(out.contains { $0.contains("Bob") && $0.contains("30") })
    #expect(!out.contains { $0.contains("---") })
}

// MARK: - Corpus integration: code trailing spaces preserved

@Test func trailingPad_preservesCodeTrailingSpaces() {
    // Pull the trailing-pad corpus case and assert the code lines KEEP their
    // intentional trailing spaces while prose lines are trimmed.
    guard let c = CorpusRunner.corpusCases().first(where: { $0.name == "trailing-pad" }) else {
        Issue.record("trailing-pad corpus case missing")
        return
    }
    let cleaned = CleanEngine.clean(c.input).cleaned
    #expect(cleaned == c.expected)
    // Explicit: the code lines retain two trailing spaces.
    #expect(cleaned.contains("code_a = 1  \n"))
    #expect(cleaned.contains("code_b = 2  \n"))
    // Explicit: prose trailing spaces are gone.
    #expect(cleaned.contains("First prose line\n"))
    #expect(!cleaned.contains("First prose line  "))
}
