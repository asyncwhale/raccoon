import Testing
import Foundation
@testable import RaccoonCore

// MARK: - ASCII reflow

@Test func reflow_joinsAsciiWrappedParagraphWithSingleSpace() {
    let lines = [
        "The quick brown fox jumps over the lazy dog and then continues running down",
        "the road past the old house until it finally reaches the river at the very",
        "end of the long winding path through the woods.",
    ]
    let out = Reflow.reflow(lines)
    #expect(out == [
        "The quick brown fox jumps over the lazy dog and then continues running down the road past the old house until it finally reaches the river at the very end of the long winding path through the woods."
    ])
}

@Test func reflow_doesNotJoinShortLines() {
    // Two short lines that look like deliberate breaks — must NOT join.
    let lines = ["short one", "short two"]
    let out = Reflow.reflow(lines)
    #expect(out == ["short one", "short two"])
}

@Test func reflow_doesNotJoinAcrossBlankLine() {
    let lines = [
        "This is a long enough line that meets the wrap-width threshold here ok yes",
        "",
        "A new paragraph starts after the blank separating line which is also long.",
    ]
    let out = Reflow.reflow(lines)
    #expect(out.count == 3)
    #expect(out[1] == "")
}

// MARK: - CJK reflow

@Test func reflow_joinsCJKWithoutSpace() {
    let lines = ["这是一个很长的中文段落用来", "测试换行重排的功能是否正确"]
    let out = Reflow.reflow(lines)
    #expect(out == ["这是一个很长的中文段落用来测试换行重排的功能是否正确"])
}

@Test func reflow_mixedCJKAsciiBoundaryUsesSpaceWhenAsciiWord() {
    // line i ends with CJK, line i+1 starts with CJK => no space at boundary.
    let lines = [
        "我们使用 docker compose 来启动服务，端口被",
        "占用了需要 release the port first",
    ]
    let out = Reflow.reflow(lines)
    #expect(out == ["我们使用 docker compose 来启动服务，端口被占用了需要 release the port first"])
}

// MARK: - List protection

@Test func reflow_doesNotMergeListItems() {
    let lines = [
        "- first item here",
        "- second item that is fairly long and wraps onto a continuation line below",
        "  because it exceeds the width of the block",
        "- third item",
    ]
    let out = Reflow.reflow(lines)
    #expect(out == [
        "- first item here",
        "- second item that is fairly long and wraps onto a continuation line below because it exceeds the width of the block",
        "- third item",
    ])
}

@Test func reflow_doesNotJoinIntoHeadingOrBlockquoteOrFence() {
    let lines = [
        "This is a long line that meets the wrap threshold and might want to join up",
        "# A heading must not be merged into the previous line",
    ]
    let out = Reflow.reflow(lines)
    #expect(out.count == 2)
    #expect(out[1].hasPrefix("#"))
}

@Test func reflow_deHyphenatesWhenLineEndsWithHyphenAndNextIsLowercase() {
    // i ends with '-' and i+1 starts lowercase ASCII => join without space.
    let lines = [
        "This sentence contains a hyphen-",
        "ated word split across the wrap boundary here padding padding padding ok",
    ]
    let out = Reflow.reflow(lines)
    #expect(out == [
        "This sentence contains a hyphenated word split across the wrap boundary here padding padding padding ok"
    ])
}

// MARK: - FIX 2 — code/command join refusal (defense in depth)

@Test func reflow_refusesBackslashContinuedShellCommand() {
    // Even passed straight to Reflow (as if misclassified prose), backslash
    // line-continuations and 2-space-indented continuations must NOT be glued.
    let lines = [
        "docker run --rm -it \\",
        "  --env FOO=bar \\",
        "  --volume /data:/data \\",
        "  myimage:latest",
    ]
    let out = Reflow.reflow(lines)
    #expect(out == lines)
}

@Test func reflow_refusesUnifiedDiffJoins() {
    let lines = [
        "diff --git a/x b/x",
        "--- a/x",
        "+++ b/x",
        "@@ -1,2 +1,2 @@",
        "-let answer = 41",
        "+let answer = 42",
    ]
    let out = Reflow.reflow(lines)
    #expect(out == lines)
}

@Test func reflow_refusesWhenLineEndsWithCodePunctuation() {
    // A "full" line ending in a brace/operator is a code signal → no join.
    let lines = [
        "function configureTheWidgetWithEverythingEnabledForReal(options) {",
        "  return options.value",
    ]
    let out = Reflow.reflow(lines)
    #expect(out == lines)
}

// MARK: - Gate

@Test func reflow_disabledByOption() {
    var opts = CleanOptions()
    opts.reflowHardWraps = false
    let raw = "The quick brown fox jumps over the lazy dog and then continues running down\nthe road past the old house until it finally reaches the river at the very\nend of the long winding path through the woods.\n"
    let cleaned = CleanEngine.clean(raw, options: opts).cleaned
    // With reflow off, the three lines remain separate.
    #expect(cleaned.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 3)
}
