import Testing
import Foundation
@testable import RaccoonCore

/// Tests for the opt-in `tidyProse` option: strips leading paragraph
/// indentation and collapses excess blank lines in PROSE segments only —
/// never touching code/table/fence/graph/box structure (the RED LINE).
///
/// Defaults must remain byte-identical to today (opt-in), and the tidy must
/// be idempotent and conservative enough to never corrupt code.
@Suite struct TidyProseTests {

    private func tidy(_ s: String) -> String {
        var o = CleanOptions()
        o.tidyProse = true
        return CleanEngine.clean(s, options: o).cleaned
    }

    // MARK: - Owner sample

    /// The exact owner sample: CJK prose with 4 leading spaces + a blank gap.
    @Test func ownerSampleIndentRemovedWhenTidyOn() {
        let raw = "    第一眼感觉怎么样？哪几条修好了、哪里还别扭？\n\n    都还没提交。"
        let cleaned = tidy(raw)
        #expect(cleaned == "第一眼感觉怎么样？哪几条修好了、哪里还别扭？\n\n都还没提交。")
    }

    /// With tidyProse defaulting OFF, the owner sample stays byte-identical
    /// (proves opt-in: today's behavior preserves the leading 4 spaces).
    @Test func ownerSampleUnchangedWhenTidyOff() {
        let raw = "    第一眼感觉怎么样？哪几条修好了、哪里还别扭？\n\n    都还没提交。"
        let cleaned = CleanEngine.clean(raw).cleaned // default options → tidyProse == false
        #expect(cleaned == raw)
    }

    // MARK: - Blank-line collapse

    @Test func collapsesMultipleBlankLinesToOne() {
        let raw = "第一段。\n\n\n\n第二段。"
        let cleaned = tidy(raw)
        #expect(cleaned == "第一段。\n\n第二段。")
    }

    @Test func fullWidthLeadingSpaceStripped() {
        let raw = "\u{3000}\u{3000}缩进的中文段落。"
        let cleaned = tidy(raw)
        #expect(cleaned == "缩进的中文段落。")
    }

    // MARK: - Idempotency

    @Test func tidyIsIdempotent() {
        let samples = [
            "    第一眼感觉怎么样？\n\n\n    都还没提交。",
            "\u{3000}缩进\n\n\n\n更多文字",
            "Plain English prose paragraph.\n\n\n  Second paragraph here.",
        ]
        for s in samples {
            let once = tidy(s)
            let twice = tidy(once)
            #expect(once == twice, "tidy not idempotent for \(s.debugDescription)")
        }
    }

    // MARK: - List / blockquote structure preserved

    /// Markdown list markers and blockquote markers stay intact; only any
    /// pure leading indent in front of plain prose lines is stripped.
    @Test func listAndBlockquoteMarkersPreserved() {
        let raw = "- item one\n- item two\n> a quote line"
        let cleaned = tidy(raw)
        #expect(cleaned == raw, "got: \(cleaned.debugDescription)")
    }

    // MARK: - RED LINE: code integrity under tidyProse == true

    /// A fenced code block with leading indentation INSIDE must be unchanged.
    @Test func fencedCodeWithIndentUnchangedUnderTidy() {
        let raw = "```python\n    if x:\n        y = 1\n\n        z = 2\n```\n"
        let cleaned = tidy(raw)
        #expect(cleaned == raw)
    }

    /// A real indented code run (≥2 consecutive 4-space lines) → unchanged.
    @Test func indentedCodeRunUnchangedUnderTidy() {
        let raw = "Snippet:\n\n    let a = 1\n    let b = 2\n\nDone.\n"
        let cleaned = tidy(raw)
        // The indented code lines keep their 4-space indent verbatim.
        #expect(cleaned == raw, "got: \(cleaned.debugDescription)")
    }

    /// Python/YAML semantic indentation that lands in a PROSE segment (two
    /// indented code-ish lines separated by a blank line, below the indented-
    /// code run threshold because the blank breaks the run) must NOT have its
    /// indentation corrupted. The tidy only strips indent from lines that read
    /// as natural-language prose (contain CJK or are clearly not code) — these
    /// symbol-bearing config lines are left alone.
    @Test func semanticIndentSeparatedByBlankLineNotCorrupted() {
        let raw = "config:\n    key: value\n\n    other: thing\n"
        let cleaned = tidy(raw)
        // The semantic 4-space indentation on both code-ish lines must survive
        // verbatim; assert the whole output is unchanged from input.
        #expect(cleaned == raw, "got: \(cleaned.debugDescription)")
    }

    /// A 2-space-indented JS/TS snippet that could land in prose keeps its
    /// indentation (symbol-bearing lines are never de-indented).
    @Test func twoSpaceCodeLikeLineNotDeIndented() {
        let raw = "Here:\n  const x = 1\n"
        let cleaned = tidy(raw)
        #expect(cleaned == raw, "got: \(cleaned.debugDescription)")
    }

    // MARK: - Mixed prose + code

    @Test func mixedProseTidiedCodeVerbatim() {
        let raw = "    一段缩进的中文说明。\n\n```\n    indented code line\n```\n"
        let cleaned = tidy(raw)
        // Prose de-indented (leading 4 spaces gone); the fenced code block is
        // verbatim (its inner 4-space indent preserved); paragraph break kept.
        let expected = "一段缩进的中文说明。\n\n```\n    indented code line\n```\n"
        #expect(cleaned == expected, "got: \(cleaned.debugDescription)")
    }

    // MARK: - All four CleanEngine option combos preserve restore losslessness

    @Test func restoreLosslessWithTidyOn() {
        let samples = [
            "    第一眼感觉怎么样？\n\n\n    都还没提交。",
            "```\n    code\n```\nprose\n",
        ]
        for s in samples {
            var o = CleanOptions()
            o.tidyProse = true
            #expect(CleanEngine.clean(s, options: o).original == s)
        }
    }
}

/// Settings persistence for the new opt-in `autoTidyProseOnPaste` flag.
@Suite struct TidyProseSettingsTests {
    @Test func defaultHasTidyOff() {
        #expect(Settings.default.autoTidyProseOnPaste == false)
    }

    @Test func tidyFlagRoundTripsThroughCodable() {
        let original = Settings(
            retentionDays: 30,
            recordsDir: URL(fileURLWithPath: "/tmp/records"),
            notesDir: URL(fileURLWithPath: "/tmp/notes"),
            autoCleanOnPaste: true,
            autoTidyProseOnPaste: true,
            enabledTools: [.claudeCode]
        )
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded == original)
        #expect(decoded.autoTidyProseOnPaste == true)
    }
}
