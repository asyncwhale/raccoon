# Changelog

All notable changes to Raccoon are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-06-05

First public release. A macOS-native, 100% local, zero-network tool that
archives, cleans, searches, and feeds back terminal-AI session logs from
Claude Code, Codex, Gemini, Cursor, and other tools.

### Added

- **Record (记)** — import session transcripts from supported terminal-AI tools;
  archives are stored as plain Markdown on disk with no vendor lock-in.
- **Clean (洗)** — strip ANSI escape codes, box-drawing characters, and wrapping
  artifacts from raw terminal output while leaving code blocks, diffs, and git
  graphs byte-perfect.
- **Search (找)** — SQLite FTS5 full-text search across every archived session,
  fully offline.
- **Feed (喂)** — one-click copy of a cleaned, formatted record to paste back
  into any AI's context window.
- **Pin on top** — float the window above your terminal or IDE, always-on-top,
  with a configurable keyboard shortcut.
- **Menu-bar mode** — secondary `MenuBarExtra` alongside the main window for
  quick access.
- **Onboarding** — first-run guidance for connecting source log folders.
- **Search filters** — narrow results by tool and other attributes.
- **Star** — mark records as starred for quick retrieval.
- **Delete with undo** — remove records with an undoable recycle-bin flow;
  archives are never deleted implicitly when a source log disappears.
- **Opt-in prose tidy** — optional, off-by-default cleanup of prose formatting;
  never alters code, and never summarizes.
- **Bilingual UI** — English and Simplified Chinese (en, zh-Hans).
- **Accessibility & keyboard** — full VoiceOver/a11y support and keyboard
  shortcuts throughout.

### Security / Privacy

- **Zero-network by construction** — the app links no networking frameworks and
  contains no `URLSession`, `Network`/`CFNetwork`, analytics, telemetry, update
  checker, or CDN code. The guarantee comes from the absence of networking code,
  not from sandbox entitlements, and is independently verifiable.
- **Read-only source logs** — source transcripts (e.g. `~/.claude`, `~/.codex`)
  are opened read-only and never modified; all writes stay under
  `~/Library/Application Support/Raccoon`.
- **Secret scanning on clipboard** — pasted content is scanned for likely
  secrets before it is stored.
- **Concealed pasteboard** — copied records are written to the pasteboard with a
  concealed/transient marker so they are not captured by clipboard-history tools.

[0.1.0]: https://github.com/asyncwhale/raccoon/releases/tag/v0.1.0
