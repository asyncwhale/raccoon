import Testing
import Foundation
@testable import RaccoonCore

/// Load a fixture file from the `fixtures` resource directory.
private func fixture(_ name: String) -> String? {
    guard
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: nil),
        let data = try? Data(contentsOf: url),
        let s = String(data: data, encoding: .utf8)
    else { return nil }
    return s
}

// MARK: - Fixture-driven full document

@Test func plaintext_fixtureMatchesExpected() {
    guard let input = fixture("plaintext.in.md"),
        let expected = fixture("plaintext.expected.md")
    else {
        Issue.record("plaintext fixtures missing")
        return
    }
    #expect(CleanEngine.toPlainText(input) == expected)
}

/// Applied via the stripMarkdown option after terminal cleaning.
@Test func plaintext_viaStripMarkdownOption() {
    guard let input = fixture("plaintext.in.md"),
        let expected = fixture("plaintext.expected.md")
    else {
        Issue.record("plaintext fixtures missing")
        return
    }
    var opts = CleanOptions()
    opts.stripMarkdown = true
    // The fixture's code block has no terminal noise, so terminal cleaning is a
    // no-op and the result equals toPlainText of the input.
    #expect(CleanEngine.clean(input, options: opts).cleaned == expected)
}

// MARK: - Unit rules

@Test func plaintext_stripsATXHeadings() {
    #expect(CleanEngine.toPlainText("# Title") == "Title")
    #expect(CleanEngine.toPlainText("### Deep heading") == "Deep heading")
    #expect(CleanEngine.toPlainText("#NotAHeading") == "#NotAHeading")  // needs a space
}

@Test func plaintext_stripsEmphasis() {
    #expect(CleanEngine.toPlainText("a **bold** b") == "a bold b")
    #expect(CleanEngine.toPlainText("a *italic* b") == "a italic b")
    #expect(CleanEngine.toPlainText("a _under_ b") == "a under b")
    #expect(CleanEngine.toPlainText("a __strong__ b") == "a strong b")
}

@Test func plaintext_keepsInlineCodeInnerText() {
    #expect(CleanEngine.toPlainText("run `git status` now") == "run git status now")
}

@Test func plaintext_dropsFenceLinesKeepsCode() {
    let md = "```swift\nlet x = 1\n```"
    #expect(CleanEngine.toPlainText(md) == "let x = 1")
}

@Test func plaintext_stripsListMarkers() {
    #expect(CleanEngine.toPlainText("- item") == "item")
    #expect(CleanEngine.toPlainText("* item") == "item")
    #expect(CleanEngine.toPlainText("1. item") == "item")
    #expect(CleanEngine.toPlainText("2) item") == "item")
}

@Test func plaintext_stripsBlockquote() {
    #expect(CleanEngine.toPlainText("> quoted") == "quoted")
    #expect(CleanEngine.toPlainText("> > nested") == "nested")
}

@Test func plaintext_linksBecomeTextThenURL() {
    #expect(CleanEngine.toPlainText("[the docs](https://x.com)") == "the docs (https://x.com)")
}

@Test func plaintext_imagesBecomeAlt() {
    #expect(CleanEngine.toPlainText("![a cat](https://x.com/c.png)") == "a cat")
}

@Test func plaintext_preservesParagraphBreaks() {
    let md = "para one\n\npara two"
    #expect(CleanEngine.toPlainText(md) == "para one\n\npara two")
}

@Test func plaintext_plainTextUnchanged() {
    #expect(CleanEngine.toPlainText("just plain words here") == "just plain words here")
}
