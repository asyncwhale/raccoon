import Testing
import Foundation
@testable import RaccoonCore

/// 🔴 RED LINE — code-block integrity must be 100%.
///
/// For every corpus case we extract all code segments (fenced + indented) from
/// BOTH the cleaned output and the expected output and assert they are
/// byte-identical. `codeIntegrity = matchingSegments / totalSegments` must be
/// exactly 1.0. We also assert lossless restore: `clean(raw).original == raw`.
///
/// If any rule leaks into code, FIX the rule (make it skip `.code`/`.table`),
/// never loosen this test.
enum CodeIntegrity {
    /// All code-segment line arrays, in order, for a block of text.
    static func codeSegments(_ text: String) -> [[String]] {
        let lines = text.components(separatedBy: "\n")
        return Segmenter.segment(lines)
            .filter { $0.kind == .code }
            .map { $0.lines }
    }
}

@Test func codeIntegrityIsOneHundredPercentAcrossCorpus() {
    var totalSegments = 0
    var matchingSegments = 0
    var failures: [String] = []

    for c in CorpusRunner.corpusCases() {
        let cleaned = CleanEngine.clean(c.input).cleaned
        let cleanedCode = CodeIntegrity.codeSegments(cleaned)
        let expectedCode = CodeIntegrity.codeSegments(c.expected)

        // Compare segment counts first.
        if cleanedCode.count != expectedCode.count {
            failures.append(
                "[\(c.name)] code-segment count mismatch: cleaned=\(cleanedCode.count) expected=\(expectedCode.count)"
            )
        }

        let pairCount = max(cleanedCode.count, expectedCode.count)
        for i in 0..<pairCount {
            totalSegments += 1
            let a = i < cleanedCode.count ? cleanedCode[i] : nil
            let b = i < expectedCode.count ? expectedCode[i] : nil
            if let a, let b, a == b {
                matchingSegments += 1
            } else {
                failures.append(
                    "[\(c.name)] code segment #\(i) differs:\n  cleaned=\(String(describing: a))\n  expected=\(String(describing: b))"
                )
            }
        }
    }

    let codeIntegrity: Double = totalSegments == 0 ? 1.0 : Double(matchingSegments) / Double(totalSegments)
    let report = "codeIntegrity = \(codeIntegrity) (\(matchingSegments)/\(totalSegments))\n"
        + failures.joined(separator: "\n")
    #expect(codeIntegrity == 1.0, "\(report)")
}

@Test func nestedCodeInnerContentSurvivesByteForByte() {
    guard let c = CorpusRunner.corpusCases().first(where: { $0.name == "nested-code" }) else {
        Issue.record("nested-code corpus case missing")
        return
    }
    let cleaned = CleanEngine.clean(c.input).cleaned
    #expect(cleaned == c.expected)
    // The inner 3-backtick fence lines and the inner code must survive.
    #expect(cleaned.contains("```js\nconst x = 42;\n```"))
    // The outer 4-backtick fences survive.
    #expect(cleaned.contains("````markdown"))
    #expect(cleaned.contains("That was an inner fence.\n````"))
}

@Test func restoreIsLosslessAcrossCorpus() {
    for c in CorpusRunner.corpusCases() {
        #expect(CleanEngine.clean(c.input).original == c.input, "original != raw for \(c.name)")
    }
}

/// 🔴 RED LINE (segmentation-independent guard).
///
/// `CodeIntegrityTests` above only inspects segments the CURRENT Segmenter
/// labels `.code`, so it cannot catch code that was MISCLASSIFIED as prose and
/// then damaged. This test feeds known code/command inputs straight to
/// `CleanEngine.clean` and asserts each input's significant code lines survive
/// VERBATIM (as a substring) in the cleaned output — no matter how the line was
/// segmented. These are exactly the review's confirmed-breakable inputs:
/// `tree` output, box-in-code, a lone box scalar, a backslash-continued shell
/// command, 2-space JS/TS, a unified diff, and NBSP inside a fence.
@Test func codeAndCommandsSurviveVerbatim() {
    // Each tuple: (input, [significant lines that MUST appear verbatim]).
    let cases: [(input: String, mustContain: [String])] = [
        // tree / eza --tree — box chars + indentation are the content.
        (
            "\u{251C}\u{2500}\u{2500} src\n\u{2502}\u{00A0}\u{00A0}\u{251C}\u{2500}\u{2500} main.swift\n\u{2514}\u{2500}\u{2500} README.md\n",
            [
                "\u{251C}\u{2500}\u{2500} src",
                "\u{2502}\u{00A0}\u{00A0}\u{251C}\u{2500}\u{2500} main.swift",
                "\u{2514}\u{2500}\u{2500} README.md",
            ]
        ),
        // Box chars as string literals inside 4-space-indented code.
        (
            "Snippet:\n\n    a = \"\u{2502}\"\n    b = \"\u{2500}\"\n\nDone.\n",
            ["    a = \"\u{2502}\"", "    b = \"\u{2500}\""]
        ),
        // A single code line with one box scalar in a literal.
        (
            "```swift\nlet box = \"\u{250C}\"\n```\n",
            ["let box = \"\u{250C}\""]
        ),
        // Backslash line-continued shell command.
        (
            "docker run --rm -it \\\n  --env FOO=bar \\\n  --volume /data:/data \\\n  myimage:latest\n",
            [
                "docker run --rm -it \\",
                "  --env FOO=bar \\",
                "  --volume /data:/data \\",
                "  myimage:latest",
            ]
        ),
        // 2-space-indented JS/TS without a fence.
        (
            "Here is the config:\n  const cfg = {\n    sep: \"\u{2502}\",\n    retries: 3,\n  };\n",
            ["  const cfg = {", "    sep: \"\u{2502}\",", "    retries: 3,", "  };"]
        ),
        // Unified git diff — markers must not glue together.
        (
            "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-let answer = 41\n+let answer = 42\n",
            ["--- a/x", "+++ b/x", "@@ -1,2 +1,2 @@", "-let answer = 41", "+let answer = 42"]
        ),
        // NBSP inside a fenced code block — preserved (not mapped to space).
        (
            "```\nx\u{00A0}=\u{00A0}1\n```\n",
            ["x\u{00A0}=\u{00A0}1"]
        ),
    ]

    for (input, mustContain) in cases {
        let cleaned = CleanEngine.clean(input).cleaned
        for line in mustContain {
            #expect(
                cleaned.contains(line),
                "code/command line not preserved verbatim:\n  expected substring: \(line.debugDescription)\n  in cleaned: \(cleaned.debugDescription)"
            )
        }
    }
}

/// FIX 4: NBSP / zero-width INSIDE code is semantic and must be preserved (we
/// strip only ANSI/OSC/ESC inside code). Prose still maps NBSP → space.
@Test func nbspAndZeroWidthPreservedInsideCode() {
    // NBSP inside a fence — kept verbatim; surrounding ANSI removed.
    let nbsp = CleanEngine.clean("```\nx\u{00A0}=\u{00A0}\u{1B}[32m1\u{1B}[0m\n```\n").cleaned
    #expect(nbsp == "```\nx\u{00A0}=\u{00A0}1\n```\n")

    // Zero-width space + BOM inside indented code — kept verbatim.
    let zw = CleanEngine.clean("text\n    a\u{200B}b\n    c\u{FEFF}d\n").cleaned
    #expect(zw.contains("    a\u{200B}b"))
    #expect(zw.contains("    c\u{FEFF}d"))

    // Contrast: in PROSE, NBSP → space and zero-width is removed (unchanged).
    let prose = CleanEngine.clean("a\u{00A0}b c\u{200B}d").cleaned
    #expect(prose == "a b cd")
}

/// Lossless restore must also hold under stripMarkdown and with reflow off.
@Test func restoreIsLosslessUnderAllOptions() {
    let samples = [
        "```\ncode  \n```\nprose   \n",
        "# heading\n- item\n",
        "\u{1B}[31mred\u{1B}[0m\n    indented\n    block\n",
        "中文 段落 测试\n换行 重排\n",
    ]
    var optionSets: [CleanOptions] = []
    for reflow in [true, false] {
        for strip in [true, false] {
            var o = CleanOptions()
            o.reflowHardWraps = reflow
            o.stripMarkdown = strip
            optionSets.append(o)
        }
    }
    for sample in samples {
        for opts in optionSets {
            #expect(CleanEngine.clean(sample, options: opts).original == sample)
        }
    }
}
