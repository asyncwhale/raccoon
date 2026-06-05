import Testing
import Foundation
@testable import RaccoonCore

// MARK: - Fenced code

@Test func segmentsFencedBlockAsCode() {
    let lines = [
        "intro prose",
        "```swift",
        "let x = 1",
        "return x",
        "```",
        "outro prose",
    ]
    let segs = Segmenter.segment(lines)
    #expect(segs.count == 3)
    #expect(segs[0] == Segment(kind: .prose, lines: ["intro prose"]))
    #expect(segs[1] == Segment(kind: .code, lines: ["```swift", "let x = 1", "return x", "```"]))
    #expect(segs[2] == Segment(kind: .prose, lines: ["outro prose"]))
}

@Test func segmentsTildeFenceAsCode() {
    let lines = ["~~~", "code here", "~~~"]
    let segs = Segmenter.segment(lines)
    #expect(segs.count == 1)
    #expect(segs[0].kind == .code)
    #expect(segs[0].lines == lines)
}

@Test func closingFenceMustBeAtLeastOpeningLength() {
    // Open with 4 backticks; an inner 3-backtick line does NOT close it.
    let lines = [
        "````",
        "```",
        "still code",
        "````",
        "prose now",
    ]
    let segs = Segmenter.segment(lines)
    #expect(segs.count == 2)
    #expect(segs[0].kind == .code)
    #expect(segs[0].lines == ["````", "```", "still code", "````"])
    #expect(segs[1] == Segment(kind: .prose, lines: ["prose now"]))
}

@Test func unterminatedFenceRunsToEndAsCode() {
    let lines = ["```", "line a", "line b"]
    let segs = Segmenter.segment(lines)
    #expect(segs.count == 1)
    #expect(segs[0].kind == .code)
    #expect(segs[0].lines == lines)
}

@Test func fenceWithLeadingWhitespaceStillToggles() {
    let lines = ["  ```", "code", "  ```"]
    let segs = Segmenter.segment(lines)
    #expect(segs.count == 1)
    #expect(segs[0].kind == .code)
}

// MARK: - Indented code

@Test func segmentsIndentedBlockAsCode() {
    let lines = [
        "Example:",
        "",
        "    let x = 1",
        "    let y = 2",
        "    print(x + y)",
        "",
        "Done.",
    ]
    let segs = Segmenter.segment(lines)
    // Expect a code segment containing exactly the three indented lines.
    let codeSegs = segs.filter { $0.kind == .code }
    #expect(codeSegs.count == 1)
    #expect(codeSegs[0].lines == ["    let x = 1", "    let y = 2", "    print(x + y)"])
}

@Test func tabIndentedBlockIsCode() {
    let lines = ["text", "\tcode 1", "\tcode 2", "more text"]
    let segs = Segmenter.segment(lines)
    let codeSegs = segs.filter { $0.kind == .code }
    #expect(codeSegs.count == 1)
    #expect(codeSegs[0].lines == ["\tcode 1", "\tcode 2"])
}

@Test func singleIndentedLineIsNotCode() {
    // <2 consecutive indented lines => not an indented-code block.
    let lines = ["text", "    lonely indent", "more text"]
    let segs = Segmenter.segment(lines)
    #expect(segs.allSatisfy { $0.kind == .prose })
}

// MARK: - Tables

@Test func segmentsBoxDrawingBlockAsTable() {
    let lines = [
        "before",
        "\u{250C}\u{2500}\u{2500}\u{2510}",  // ┌──┐
        "\u{2502}ab\u{2502}",                 // │ab│
        "\u{2514}\u{2500}\u{2500}\u{2518}",  // └──┘
        "after",
    ]
    let segs = Segmenter.segment(lines)
    let tableSegs = segs.filter { $0.kind == .table }
    #expect(tableSegs.count == 1)
    #expect(tableSegs[0].lines.count == 3)
}

@Test func segmentsMarkdownTableAsTable() {
    let lines = [
        "| Name | Age |",
        "|------|-----|",
        "| Bob  | 30  |",
    ]
    let segs = Segmenter.segment(lines)
    #expect(segs.count == 1)
    #expect(segs[0].kind == .table)
}

@Test func pipeLinesWithoutSeparatorAreNotTable() {
    // A single piped line with no |---| separator should not be a table.
    let lines = ["a | b | c is just prose with pipes"]
    let segs = Segmenter.segment(lines)
    #expect(segs[0].kind == .prose)
}

// MARK: - FIX 1 — box-drawing must not destroy code

@Test func treeOutputIsNotTable_preservedAsCode() {
    // `tree`/`eza --tree`: box chars + indentation ARE the content. NOT a
    // closed table (rows end in text, no top/bottom frame) → preserved as code.
    let lines = [
        "\u{251C}\u{2500}\u{2500} src",
        "\u{2502}  \u{251C}\u{2500}\u{2500} main.swift",
        "\u{2514}\u{2500}\u{2500} README.md",
    ]
    let segs = Segmenter.segment(lines)
    #expect(segs.count == 1)
    #expect(segs[0].kind == .code)
    #expect(segs[0].lines == lines)
    #expect(!segs.contains { $0.kind == .table })
}

@Test func singleBoxScalarLineIsNotTable() {
    // A lone box scalar in a code-ish line must NEVER trigger box deletion.
    let lines = ["let box = \"\u{250C}\""]
    let segs = Segmenter.segment(lines)
    #expect(!segs.contains { $0.kind == .table })
}

@Test func boxCharsInIndentedCodeStayCode() {
    // 4-space-indented code whose string literals contain box chars → code,
    // not table (indented-code detection wins over box detection).
    let lines = ["    a = \"\u{2502}\"", "    b = \"\u{2500}\""]
    let segs = Segmenter.segment(lines)
    #expect(segs.count == 1)
    #expect(segs[0].kind == .code)
    #expect(segs[0].lines == lines)
}

@Test func columnFramedBoxIsStillTable() {
    // Side-framed aligned columns (│ … │) with no drawn top/bottom remain a
    // confident table (every row both starts and ends with a vertical box).
    let lines = ["\u{2502} apple  \u{2502}", "\u{2502} banana \u{2502}"]
    let segs = Segmenter.segment(lines)
    #expect(segs.count == 1)
    #expect(segs[0].kind == .table)
}

// MARK: - FIX 3 — sub-4-space code by symbol density

@Test func twoSpaceSymbolDenseCodeIsCode() {
    let lines = [
        "  const cfg = {",
        "    sep: \"x\",",
        "    retries: 3,",
        "  };",
    ]
    let segs = Segmenter.segment(lines)
    #expect(segs.count == 1)
    #expect(segs[0].kind == .code)
    #expect(segs[0].lines == lines)
}

@Test func twoSpaceIndentedProseStaysProse() {
    // Indented wrapped prose (no braces/semicolons/equals; sparse punctuation)
    // must NOT be misclassified as symbol-dense code.
    let lines = [
        "  this is a wrapped, indented sentence that continues",
        "  onto a second line without any code symbols at all",
    ]
    let segs = Segmenter.segment(lines)
    #expect(segs.allSatisfy { $0.kind == .prose })
}

// MARK: - ASCII graph

@Test func segmentsGitGraphAsCode() {
    let lines = [
        "History:",
        "* commit abc123",
        "|\\",
        "| * commit def456",
        "* | commit 789abc",
        "|/",
        "* commit 000000",
    ]
    let segs = Segmenter.segment(lines)
    let codeSegs = segs.filter { $0.kind == .code }
    #expect(codeSegs.count == 1)
    // The contiguous graph block (lines after "History:") is preformatted code.
    #expect(codeSegs[0].lines.first == "* commit abc123")
    #expect(codeSegs[0].lines.last == "* commit 000000")
}

// MARK: - Prose

@Test func plainParagraphIsProse() {
    let lines = ["This is a normal", "paragraph of prose", "with several lines."]
    let segs = Segmenter.segment(lines)
    #expect(segs.count == 1)
    #expect(segs[0] == Segment(kind: .prose, lines: lines))
}

@Test func emptyInputProducesNoSegmentsOrEmptyProse() {
    // A single empty-string line (from splitting "") is prose.
    let segs = Segmenter.segment([""])
    #expect(segs == [Segment(kind: .prose, lines: [""])])
}
