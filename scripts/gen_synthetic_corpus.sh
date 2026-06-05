#!/usr/bin/env bash
# Generates the synthetic golden corpus for CleanEngine.
#
# Why a script: the `*.in.txt` files must contain EXACT bytes that cannot be
# typed reliably by hand — real ESC (0x1B), BOM (EF BB BF), zero-width space
# (E2 80 8B / U+200B), NBSP (C2 A0 / U+00A0), box-drawing chars, etc. We use
# `printf` (which interprets \x.. and \u.. escapes under /bin/printf-compatible
# shells; we force bash's builtin which supports \x and \u) to emit them.
#
# `.expected.txt` files are plain UTF-8 (still emitted via printf for the few
# that need NBSP→space etc., but they contain no control bytes).
#
# Idempotent: rerunning regenerates every pair from scratch.
set -euo pipefail

CORPUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/RaccoonCore/Tests/RaccoonCoreTests/corpus"
mkdir -p "$CORPUS_DIR"

# Use printf %b so that backslash escapes in the format are expanded.
emit() {
    # $1 = filename, $2 = content (with \x.. / \u.. escapes)
    printf '%b' "$2" > "$CORPUS_DIR/$1"
}

# ---------------------------------------------------------------------------
# Layer 1.2 — ansi-basic
#   input: CSI-colored "ERROR", reset, " done", then a BOM, a line with a
#          zero-width space inside a word, and a NBSP between two words.
#   expected: ANSI gone, BOM gone, zero-width gone, NBSP -> normal space.
# ---------------------------------------------------------------------------
emit "ansi-basic.in.txt" '\x1b[31mERROR\x1b[0m done\n\xef\xbb\xbfhel\xe2\x80\x8blo wor\xc2\xa0ld\n'
emit "ansi-basic.expected.txt" 'ERROR done\nhello wor ld\n'

# ---------------------------------------------------------------------------
# Layer 1.3 — fenced-code
#   A fenced code block with ANSI inside one code line + prose around it with
#   trailing ANSI. CODE content (between fences, inclusive) is byte-identical
#   in .in and .expected EXCEPT the ANSI escape inside the code line is removed
#   (ANSI is pure terminal noise, allowed to strip even inside code). Indent,
#   newlines and visible chars are untouched.
# ---------------------------------------------------------------------------
emit "fenced-code.in.txt" 'Here is the \x1b[1mcode\x1b[0m:\n```python\ndef f(x):\n    return \x1b[32mx\x1b[0m + 1\n```\nDone.\n'
emit "fenced-code.expected.txt" 'Here is the code:\n```python\ndef f(x):\n    return x + 1\n```\nDone.\n'

# ---------------------------------------------------------------------------
# Layer 1.3 — indented-code
#   >=2 lines indented >=4 spaces => code. Surrounding prose has trailing ANSI.
#   The indented code keeps its 4-space indent and trailing content verbatim.
# ---------------------------------------------------------------------------
emit "indented-code.in.txt" 'Example:\x1b[0m\n\n    let x = 1\n    let y = 2\n    print(x + y)\n\nThat is all.\n'
emit "indented-code.expected.txt" 'Example:\n\n    let x = 1\n    let y = 2\n    print(x + y)\n\nThat is all.\n'

# ---------------------------------------------------------------------------
# Layer 1.3 — git-graph
#   git log --graph style: leading runs of * | / \ graph chars => code,
#   preformatted, never reflowed. ANSI colors stripped, layout identical.
# ---------------------------------------------------------------------------
emit "git-graph.in.txt" 'History:\n\x1b[33m* commit abc123\x1b[0m\n|\\\n| * commit def456\n* | commit 789abc\n|/\n* commit 000000\n'
emit "git-graph.expected.txt" 'History:\n* commit abc123\n|\\\n| * commit def456\n* | commit 789abc\n|/\n* commit 000000\n'

# ---------------------------------------------------------------------------
# Layer 1.4 — box-table
#   A Unicode box-drawing table; cells padded with trailing spaces. Expected:
#   border chars removed, inner cell text intact, trailing pad removed.
#   Box chars: ┌ ─ ┐ │ ├ ┤ └ ┘ ┬ ┴ ┼
# ---------------------------------------------------------------------------
emit "box-table.in.txt" '\xe2\x94\x8c\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x90\n\xe2\x94\x82 Name   \xe2\x94\x82\n\xe2\x94\x82 Alice  \xe2\x94\x82\n\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x98\n'
emit "box-table.expected.txt" 'Name\nAlice\n'

# ---------------------------------------------------------------------------
# Layer 1.4 — trailing-pad
#   Prose lines right-padded with spaces (to ~ a fixed col) PLUS a fenced code
#   block whose lines have intentional trailing spaces. Expected: prose trailing
#   trimmed; CODE trailing spaces PRESERVED.
#   Each prose line below is padded with trailing spaces; the code lines end in
#   two trailing spaces that MUST survive.
# ---------------------------------------------------------------------------
emit "trailing-pad.in.txt" 'First prose line      \nSecond prose line     \n```\ncode_a = 1  \ncode_b = 2  \n```\nLast prose line       \n'
emit "trailing-pad.expected.txt" 'First prose line\nSecond prose line\n```\ncode_a = 1  \ncode_b = 2  \n```\nLast prose line\n'

# ---------------------------------------------------------------------------
# Layer 1.4 — aligned-cols
#   Box-padded aligned content: a leading box border + space padding on each
#   line. Expected: leading alignment indent removed only where it is box
#   padding (left over after the stripped border).
# ---------------------------------------------------------------------------
emit "aligned-cols.in.txt" '\xe2\x94\x82 apple    \xe2\x94\x82\n\xe2\x94\x82 banana   \xe2\x94\x82\n\xe2\x94\x82 cherry   \xe2\x94\x82\n'
emit "aligned-cols.expected.txt" 'apple\nbanana\ncherry\n'

# ---------------------------------------------------------------------------
# Layer 1.5 — wrap-ascii-80
#   An English paragraph hard-wrapped near 80 cols => one line.
# ---------------------------------------------------------------------------
emit "wrap-ascii-80.in.txt" 'The quick brown fox jumps over the lazy dog and then continues running down\nthe road past the old house until it finally reaches the river at the very\nend of the long winding path through the woods.\n'
emit "wrap-ascii-80.expected.txt" 'The quick brown fox jumps over the lazy dog and then continues running down the road past the old house until it finally reaches the river at the very end of the long winding path through the woods.\n'

# ---------------------------------------------------------------------------
# Layer 1.5 — wrap-cjk
#   A CJK paragraph wrapped => joined with NO spaces at CJK-CJK boundaries.
#   Each line is long (CJK chars). They join seamlessly.
# ---------------------------------------------------------------------------
emit "wrap-cjk.in.txt" '\xe8\xbf\x99\xe6\x98\xaf\xe4\xb8\x80\xe4\xb8\xaa\xe5\xbe\x88\xe9\x95\xbf\xe7\x9a\x84\xe4\xb8\xad\xe6\x96\x87\xe6\xae\xb5\xe8\x90\xbd\xe7\x94\xa8\xe6\x9d\xa5\n\xe6\xb5\x8b\xe8\xaf\x95\xe6\x8d\xa2\xe8\xa1\x8c\xe9\x87\x8d\xe6\x8e\x92\xe7\x9a\x84\xe5\x8a\x9f\xe8\x83\xbd\xe6\x98\xaf\xe5\x90\xa6\xe6\xad\xa3\xe7\xa1\xae\n'
emit "wrap-cjk.expected.txt" '\xe8\xbf\x99\xe6\x98\xaf\xe4\xb8\x80\xe4\xb8\xaa\xe5\xbe\x88\xe9\x95\xbf\xe7\x9a\x84\xe4\xb8\xad\xe6\x96\x87\xe6\xae\xb5\xe8\x90\xbd\xe7\x94\xa8\xe6\x9d\xa5\xe6\xb5\x8b\xe8\xaf\x95\xe6\x8d\xa2\xe8\xa1\x8c\xe9\x87\x8d\xe6\x8e\x92\xe7\x9a\x84\xe5\x8a\x9f\xe8\x83\xbd\xe6\x98\xaf\xe5\x90\xa6\xe6\xad\xa3\xe7\xa1\xae\n'

# ---------------------------------------------------------------------------
# Layer 1.5 — wrap-mixed
#   CJK + EN. A line ending in CJK joined to a next line starting CJK => no
#   space; an ASCII word boundary => single space. Here line 1 ends with ASCII
#   word and line 2 starts with ASCII => join with single space; the CJK run
#   within stays contiguous.
# ---------------------------------------------------------------------------
emit "wrap-mixed.in.txt" '\xe6\x88\x91\xe4\xbb\xac\xe4\xbd\xbf\xe7\x94\xa8 docker compose \xe6\x9d\xa5\xe5\x90\xaf\xe5\x8a\xa8\xe6\x9c\x8d\xe5\x8a\xa1\xef\xbc\x8c\xe7\xab\xaf\xe5\x8f\xa3\xe8\xa2\xab\n\xe5\x8d\xa0\xe7\x94\xa8\xe4\xba\x86\xe9\x9c\x80\xe8\xa6\x81 release the port first\n'
emit "wrap-mixed.expected.txt" '\xe6\x88\x91\xe4\xbb\xac\xe4\xbd\xbf\xe7\x94\xa8 docker compose \xe6\x9d\xa5\xe5\x90\xaf\xe5\x8a\xa8\xe6\x9c\x8d\xe5\x8a\xa1\xef\xbc\x8c\xe7\xab\xaf\xe5\x8f\xa3\xe8\xa2\xab\xe5\x8d\xa0\xe7\x94\xa8\xe4\xba\x86\xe9\x9c\x80\xe8\xa6\x81 release the port first\n'

# ---------------------------------------------------------------------------
# Layer 1.5 — list-no-merge
#   A bulleted list: items NOT merged. A wrapped continuation inside one item
#   MAY join, but distinct "- " items stay separate lines.
# ---------------------------------------------------------------------------
emit "list-no-merge.in.txt" '- first item here\n- second item that is fairly long and wraps onto a continuation line below\n  because it exceeds the width of the block\n- third item\n'
emit "list-no-merge.expected.txt" '- first item here\n- second item that is fairly long and wraps onto a continuation line below because it exceeds the width of the block\n- third item\n'

# ---------------------------------------------------------------------------
# Layer 1.7 — nested-code
#   A fenced block (4 backticks) containing what looks like another 3-backtick
#   fence and ANSI inside. The inner content must survive byte-for-byte (only
#   ANSI stripped). The OUTER fence is 4 backticks so the inner 3-backtick line
#   does NOT close it.
# ---------------------------------------------------------------------------
emit "nested-code.in.txt" 'See the markdown sample below:\x1b[0m\n````markdown\nHere is how to write code:\n```js\nconst x = \x1b[36m42\x1b[0m;\n```\nThat was an inner fence.\n````\nEnd.\n'
emit "nested-code.expected.txt" 'See the markdown sample below:\n````markdown\nHere is how to write code:\n```js\nconst x = 42;\n```\nThat was an inner fence.\n````\nEnd.\n'

# ===========================================================================
# Hardening corpus — adversarial cases for the code-integrity RED LINE.
# Box-drawing UTF-8 reference:
#   ┌ \xe2\x94\x8c   ┐ \xe2\x94\x90   └ \xe2\x94\x94   ┘ \xe2\x94\x98
#   ─ \xe2\x94\x80   │ \xe2\x94\x82   ├ \xe2\x94\x9c   ┤ \xe2\x94\xa4
#   ┬ \xe2\x94\xac   ┴ \xe2\x94\xb4   ┼ \xe2\x94\xbc
# ===========================================================================

# ---------------------------------------------------------------------------
# FIX 1 — tree-output
#   `tree` / `eza --tree` output. The box chars + indentation ARE the content;
#   this is NOT a closed table (no top/bottom border framing rows), so box
#   stripping must NEVER fire. Expected: byte-identical to input.
# ---------------------------------------------------------------------------
emit "tree-output.in.txt" '\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 src\n\xe2\x94\x82\xc2\xa0\xc2\xa0\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 main.swift\n\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 README.md\n'
emit "tree-output.expected.txt" '\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 src\n\xe2\x94\x82\xc2\xa0\xc2\xa0\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 main.swift\n\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 README.md\n'

# ---------------------------------------------------------------------------
# FIX 1 — box-in-code
#   Box-drawing scalars used as STRING LITERALS inside a 4-space-indented code
#   block. Indented-code detection must win over table detection; the box chars
#   must stay verbatim (no stripping). ANSI on the surrounding prose is removed.
# ---------------------------------------------------------------------------
emit "box-in-code.in.txt" 'Snippet:\x1b[0m\n\n    a = "\xe2\x94\x82"\n    b = "\xe2\x94\x80"\n\nDone.\n'
emit "box-in-code.expected.txt" 'Snippet:\n\n    a = "\xe2\x94\x82"\n    b = "\xe2\x94\x80"\n\nDone.\n'

# ---------------------------------------------------------------------------
# FIX 1 — box-single-line
#   A single fenced code line containing one box scalar in a string literal. A
#   lone box scalar must NEVER trigger box deletion. Expected: unchanged.
# ---------------------------------------------------------------------------
emit "box-single-line.in.txt" '```swift\nlet box = "\xe2\x94\x8c"\n```\n'
emit "box-single-line.expected.txt" '```swift\nlet box = "\xe2\x94\x8c"\n```\n'

# ---------------------------------------------------------------------------
# FIX 2 — shell-continuation
#   A backslash line-continued shell command (multi-line). Even if prose-
#   classified, reflow must refuse to glue lines joined by trailing `\` or
#   2-space-indented continuations. Expected: NOT joined (lines preserved).
# ---------------------------------------------------------------------------
emit "shell-continuation.in.txt" 'docker run --rm -it \\\n  --env FOO=bar \\\n  --volume /data:/data \\\n  myimage:latest\n'
emit "shell-continuation.expected.txt" 'docker run --rm -it \\\n  --env FOO=bar \\\n  --volume /data:/data \\\n  myimage:latest\n'

# ---------------------------------------------------------------------------
# FIX 2 — unified-diff
#   A unified `git diff` block. The ---/+++/@@ headers and +/- body lines must
#   NOT be reflowed into one another. Expected: NOT joined (lines preserved).
# ---------------------------------------------------------------------------
emit "unified-diff.in.txt" 'diff --git a/main.swift b/main.swift\n--- a/main.swift\n+++ b/main.swift\n@@ -1,3 +1,3 @@\n-let answer = 41\n+let answer = 42\n print(answer)\n'
emit "unified-diff.expected.txt" 'diff --git a/main.swift b/main.swift\n--- a/main.swift\n+++ b/main.swift\n@@ -1,3 +1,3 @@\n-let answer = 41\n+let answer = 42\n print(answer)\n'

# ---------------------------------------------------------------------------
# FIX 3 — two-space-code
#   A 2-space-indented JS/TS snippet pasted WITHOUT a fence, whose first line
#   would (under reflow) glue onto the next. High code-symbol density must
#   classify the run as .code so it is preserved verbatim. A box scalar appears
#   in a string literal to also exercise FIX 1's "no strip in code" guarantee.
# ---------------------------------------------------------------------------
emit "two-space-code.in.txt" 'Here is the config:\n  const cfg = {\n    sep: "\xe2\x94\x82",\n    retries: 3,\n    nested: { enabled: true },\n  };\n'
emit "two-space-code.expected.txt" 'Here is the config:\n  const cfg = {\n    sep: "\xe2\x94\x82",\n    retries: 3,\n    nested: { enabled: true },\n  };\n'

# ---------------------------------------------------------------------------
# FIX 4 — crlf
#   Windows CRLF line endings. The pipeline normalizes \r\n and lone \r to \n;
#   cleaned output uses LF only. (Lossless restore still holds because
#   `original` stores the raw CRLF input verbatim — asserted in tests.)
# ---------------------------------------------------------------------------
emit "crlf.in.txt" 'line one\r\nline two\r\nline three\r\n'
emit "crlf.expected.txt" 'line one\nline two\nline three\n'

# ---------------------------------------------------------------------------
# FIX 4 — nbsp-in-code
#   NBSP (U+00A0) used as alignment INSIDE a fenced code block. Inside code we
#   strip ONLY ANSI/OSC/ESC; NBSP / zero-width / BOM are semantic bytes and are
#   PRESERVED. (Prose still maps NBSP→space — covered by ansi-basic.) ANSI on
#   the code line IS removed.
# ---------------------------------------------------------------------------
emit "nbsp-in-code.in.txt" '```\nx\xc2\xa0=\xc2\xa0\x1b[32m1\x1b[0m\n```\n'
emit "nbsp-in-code.expected.txt" '```\nx\xc2\xa0=\xc2\xa01\n```\n'

# ---------------------------------------------------------------------------
# SYNTHETIC REPLACEMENT — cjk-prose-md
#   CJK Markdown prose about caching strategies: ## heading, > blockquote,
#   - bullets.  CleanEngine must preserve this verbatim — no reflow.
#   (Replaces the removed real-cjk-prose pair.)
# ---------------------------------------------------------------------------
emit "cjk-prose-md.in.txt" '## \xe7\xbc\x93\xe5\xad\x98\xe7\xad\x96\xe7\x95\xa5\xe5\xaf\xb9\xe6\xaf\x94\n\n> **\xe5\x86\x99\xe7\x9b\xb4\xe8\xbe\xbe\xef\xbc\x88write-through\xef\xbc\x89**\xef\xbc\x9a\xe6\x95\xb0\xe6\x8d\xae\xe5\x90\x8c\xe6\x97\xb6\xe5\x86\x99\xe5\x85\xa5\xe7\xbc\x93\xe5\xad\x98\xe5\x92\x8c\xe5\x90\x8e\xe7\xab\xaf\xe3\x80\x82\n>\n> **\xe5\x9b\x9e\xe5\x86\x99\xef\xbc\x88write-back\xef\xbc\x89**\xef\xbc\x9a\xe5\x8f\xaa\xe5\x86\x99\xe7\xbc\x93\xe5\xad\x98\xef\xbc\x8c\xe5\xbb\xb6\xe8\xbf\x9f\xe5\x88\xb7\xe7\x9b\x98\xe3\x80\x82\n\n**\xe4\xb8\xa4\xe7\xa7\x8d\xe6\x96\xb9\xe6\xa1\x88\xe5\x9d\x87\xe9\x80\x82\xe7\x94\xa8\xe4\xba\x8e**\xef\xbc\x9a\n- \xe8\xaf\xbb\xe5\xa4\x9a\xe5\x86\x99\xe5\xb0\x91\xe7\x9a\x84\xe5\x9c\xba\xe6\x99\xaf\n- \xe9\xab\x98\xe5\xb9\xb6\xe5\x8f\x91\xe8\xaf\xb7\xe6\xb1\x82\xe5\x85\xa5\xe5\x8f\xa3\n- \xe5\xaf\xb9\xe4\xb8\x80\xe8\x87\xb4\xe6\x80\xa7\xe8\xa6\x81\xe6\xb1\x82\xe4\xb8\x8d\xe9\xab\x98\xe7\x9a\x84\xe6\x9c\x8d\xe5\x8a\xa1\n'
emit "cjk-prose-md.expected.txt" '## \xe7\xbc\x93\xe5\xad\x98\xe7\xad\x96\xe7\x95\xa5\xe5\xaf\xb9\xe6\xaf\x94\n\n> **\xe5\x86\x99\xe7\x9b\xb4\xe8\xbe\xbe\xef\xbc\x88write-through\xef\xbc\x89**\xef\xbc\x9a\xe6\x95\xb0\xe6\x8d\xae\xe5\x90\x8c\xe6\x97\xb6\xe5\x86\x99\xe5\x85\xa5\xe7\xbc\x93\xe5\xad\x98\xe5\x92\x8c\xe5\x90\x8e\xe7\xab\xaf\xe3\x80\x82\n>\n> **\xe5\x9b\x9e\xe5\x86\x99\xef\xbc\x88write-back\xef\xbc\x89**\xef\xbc\x9a\xe5\x8f\xaa\xe5\x86\x99\xe7\xbc\x93\xe5\xad\x98\xef\xbc\x8c\xe5\xbb\xb6\xe8\xbf\x9f\xe5\x88\xb7\xe7\x9b\x98\xe3\x80\x82\n\n**\xe4\xb8\xa4\xe7\xa7\x8d\xe6\x96\xb9\xe6\xa1\x88\xe5\x9d\x87\xe9\x80\x82\xe7\x94\xa8\xe4\xba\x8e**\xef\xbc\x9a\n- \xe8\xaf\xbb\xe5\xa4\x9a\xe5\x86\x99\xe5\xb0\x91\xe7\x9a\x84\xe5\x9c\xba\xe6\x99\xaf\n- \xe9\xab\x98\xe5\xb9\xb6\xe5\x8f\x91\xe8\xaf\xb7\xe6\xb1\x82\xe5\x85\xa5\xe5\x8f\xa3\n- \xe5\xaf\xb9\xe4\xb8\x80\xe8\x87\xb4\xe6\x80\xa7\xe8\xa6\x81\xe6\xb1\x82\xe4\xb8\x8d\xe9\xab\x98\xe7\x9a\x84\xe6\x9c\x8d\xe5\x8a\xa1\n'

# ---------------------------------------------------------------------------
# SYNTHETIC REPLACEMENT — ls-columns
#   `ls -la` listing with generic dev project files (main.swift, README.md,
#   Package.swift, src/), owner `dev staff`.  Aligned columns must be
#   preserved verbatim — CleanEngine must not reflow or strip.
#   (Replaces the removed real-ls-output pair.)
# ---------------------------------------------------------------------------
emit "ls-columns.in.txt" 'total 48\ndrwxr-xr-x@  6 dev  staff    192  5\xe6\x9c\x88 10 14:22 .\ndrwxr-xr-x@ 12 dev  staff    384  5\xe6\x9c\x88  9 09:01 ..\n-rw-r--r--@  1 dev  staff   1234  5\xe6\x9c\x88 10 14:20 Package.swift\n-rw-r--r--@  1 dev  staff   2048  5\xe6\x9c\x88 10 11:05 README.md\n-rw-r--r--@  1 dev  staff    512  5\xe6\x9c\x88 10 13:47 main.swift\ndrwxr-xr-x@  3 dev  staff     96  5\xe6\x9c\x88 10 10:30 src\n'
emit "ls-columns.expected.txt" 'total 48\ndrwxr-xr-x@  6 dev  staff    192  5\xe6\x9c\x88 10 14:22 .\ndrwxr-xr-x@ 12 dev  staff    384  5\xe6\x9c\x88  9 09:01 ..\n-rw-r--r--@  1 dev  staff   1234  5\xe6\x9c\x88 10 14:20 Package.swift\n-rw-r--r--@  1 dev  staff   2048  5\xe6\x9c\x88 10 11:05 README.md\n-rw-r--r--@  1 dev  staff    512  5\xe6\x9c\x88 10 13:47 main.swift\ndrwxr-xr-x@  3 dev  staff     96  5\xe6\x9c\x88 10 10:30 src\n'

# ---------------------------------------------------------------------------
# SYNTHETIC REPLACEMENT — md-table-cjk
#   CJK Markdown pipe table comparing generic CLI tools across dimensions.
#   The `|---|---|---|` separator row is stripped by CleanEngine; the leading
#   `| ` of the header row is also removed — leaving the bare pipe-delimited
#   rows.  (Replaces the removed real-md-table-cjk pair.)
# ---------------------------------------------------------------------------
emit "md-table-cjk.in.txt" '## \xe5\xb7\xa5\xe5\x85\xb7\xe5\xaf\xb9\xe6\xaf\x94\n\n| \xe5\xb7\xa5\xe5\x85\xb7 | \xe8\xaf\xad\xe8\xa8\x80 | \xe6\x8e\xa5\xe5\x8f\xa3\xe9\xa3\x8e\xe6\xa0\xbc | \xe9\x80\x82\xe7\x94\xa8\xe5\xb9\xb3\xe5\x8f\xb0 |\n|---|---|---|---|\n| ripgrep | Rust | CLI | \xe8\xb7\xa8\xe5\xb9\xb3\xe5\x8f\xb0 |\n| fd | Rust | CLI | \xe8\xb7\xa8\xe5\xb9\xb3\xe5\x8f\xb0 |\n| bat | Rust | CLI | \xe8\xb7\xa8\xe5\xb9\xb3\xe5\x8f\xb0 |\n\n\xe4\xb8\x89\xe4\xb8\xaa\xe5\xb7\xa5\xe5\x85\xb7\xe5\x9d\x87\xe7\x94\xa8 Rust \xe7\xbc\x96\xe5\x86\x99\xe3\x80\x82\n'
emit "md-table-cjk.expected.txt" '## \xe5\xb7\xa5\xe5\x85\xb7\xe5\xaf\xb9\xe6\xaf\x94\n\n\xe5\xb7\xa5\xe5\x85\xb7 | \xe8\xaf\xad\xe8\xa8\x80 | \xe6\x8e\xa5\xe5\x8f\xa3\xe9\xa3\x8e\xe6\xa0\xbc | \xe9\x80\x82\xe7\x94\xa8\xe5\xb9\xb3\xe5\x8f\xb0\nripgrep | Rust | CLI | \xe8\xb7\xa8\xe5\xb9\xb3\xe5\x8f\xb0\nfd | Rust | CLI | \xe8\xb7\xa8\xe5\xb9\xb3\xe5\x8f\xb0\nbat | Rust | CLI | \xe8\xb7\xa8\xe5\xb9\xb3\xe5\x8f\xb0\n\n\xe4\xb8\x89\xe4\xb8\xaa\xe5\xb7\xa5\xe5\x85\xb7\xe5\x9d\x87\xe7\x94\xa8 Rust \xe7\xbc\x96\xe5\x86\x99\xe3\x80\x82\n'

# ---------------------------------------------------------------------------
# SYNTHETIC REPLACEMENT — fenced-tree-cjk
#   CJK prose followed by a fenced code block containing a tree-style directory
#   listing. The fenced block must be preserved verbatim; prose preserved too.
#   (Replaces the removed real-fenced-tree pair.)
# ---------------------------------------------------------------------------
emit "fenced-tree-cjk.in.txt" '\xe9\xa1\xb9\xe7\x9b\xae\xe7\xbb\x93\xe6\x9e\x84\xe5\xa6\x82\xe4\xb8\x8b\xef\xbc\x9a\n\n```\nmy-app/\n\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 Package.swift\n\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 Sources/\n\xe2\x94\x82   \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 main.swift\n\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 Tests/\n    \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 AppTests.swift\n```\n\n\xe5\x85\xb1\xe4\xb8\xa4\xe4\xb8\xaa\xe9\xa1\xb6\xe7\xba\xa7\xe7\x9b\xae\xe5\xbd\x95\xe3\x80\x82\n'
emit "fenced-tree-cjk.expected.txt" '\xe9\xa1\xb9\xe7\x9b\xae\xe7\xbb\x93\xe6\x9e\x84\xe5\xa6\x82\xe4\xb8\x8b\xef\xbc\x9a\n\n```\nmy-app/\n\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 Package.swift\n\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 Sources/\n\xe2\x94\x82   \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 main.swift\n\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 Tests/\n    \xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 AppTests.swift\n```\n\n\xe5\x85\xb1\xe4\xb8\xa4\xe4\xb8\xaa\xe9\xa1\xb6\xe7\xba\xa7\xe7\x9b\xae\xe5\xbd\x95\xe3\x80\x82\n'

# ---------------------------------------------------------------------------
# SYNTHETIC REPLACEMENT — mixed-prose-code
#   CJK prose with a trailing ANSI reset (\x1b[0m) immediately after the colon,
#   followed by a fenced code block. CleanEngine strips ANSI from prose; the
#   fenced block is preserved verbatim.
#   (Replaces the removed real-mixed-prose-code pair.)
# ---------------------------------------------------------------------------
emit "mixed-prose-code.in.txt" '\xe8\xaf\xa5\xe5\x91\xbd\xe4\xbb\xa4\xe7\x9a\x84\xe5\x8f\x82\xe6\x95\xb0\xe7\xbb\x93\xe6\x9e\x84\xe5\xa6\x82\xe4\xb8\x8b\xef\xbc\x9a\x1b[0m\n\n```\nbuild --target release \\\n    --output ./dist\n```\n\n\xe4\xb8\x8a\xe9\x9d\xa2\xe5\xb0\xb1\xe6\x98\xaf\xe5\x85\xa8\xe9\x83\xa8\xe5\x8f\x82\xe6\x95\xb0\xe3\x80\x82\n'
emit "mixed-prose-code.expected.txt" '\xe8\xaf\xa5\xe5\x91\xbd\xe4\xbb\xa4\xe7\x9a\x84\xe5\x8f\x82\xe6\x95\xb0\xe7\xbb\x93\xe6\x9e\x84\xe5\xa6\x82\xe4\xb8\x8b\xef\xbc\x9a\n\n```\nbuild --target release \\\n    --output ./dist\n```\n\n\xe4\xb8\x8a\xe9\x9d\xa2\xe5\xb0\xb1\xe6\x98\xaf\xe5\x85\xa8\xe9\x83\xa8\xe5\x8f\x82\xe6\x95\xb0\xe3\x80\x82\n'

echo "Generated corpus pairs in: $CORPUS_DIR"
ls -1 "$CORPUS_DIR" | grep -E '\.(in|expected)\.txt$' | sort
