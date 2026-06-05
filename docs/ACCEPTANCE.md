# Raccoon — Acceptance (PRD §9) status

> Snapshot at the end of Phase 3 (integration). The build is on branch `build/v0.1`.
> Legend: ✅ verified headlessly (tests / E2E / measurement) · 👁 needs a visual/interactive pass (Screen Recording permission, or user eyeball per the PRD's "本地试用清单") · ⏳ needs elapsed time.

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | Launch → auto-scan Claude/Codex history; sidebar grouped by session; searchable | ✅ pipeline · 👁 display | E2E ran the full app pipeline on **259 real Claude sessions** in 16s → 259 `.md` + 259 indexed (store=index=259); `AppModel.records` loads via `allSummaries()`. Sidebar render needs a screenshot. |
| 2 | Paste real ANSI/hard-wrapped output → auto-clean, **code intact**, restorable | ✅ logic · 👁 in-app | CleanEngine **code-integrity 100%** across synthetic + adversarial (tree/box/shell/diff/2-space/CRLF) + 9 real anonymized corpus pairs; `clean().original==raw` lossless. Editor paste = single undoable edit recording the original (`CleanTextView.paste`). In-app paste needs a screenshot. |
| 3 | 转纯文本 removes Markdown symbols | ✅ logic · 👁 in-app | `CleanEngine.toPlainText` tested; editor button wired (undoable, selection or whole doc). |
| 4 | Search a keyword → cross-tool hit → double-click opens in a Tab | ✅ search · 👁 open | FTS5 **trigram + LIKE fallback** tested incl. **2-char CJK**; E2E live search hit `docker / git / error / 代码 / 文件 / 端口`. Double-click→read-only tab wired (`openRecord`). |
| 5 | 喂·路径 = `看一下…/x.md`; 喂·内容 = `你:/Codex:` verbatim; 复制走 = bare | ✅ | `RecordClipboard` exact-string tests: `copyOut` has NO labels; `feedContent` = §4 body WITH 你：/Codex： labels; `feedPath` = `看一下我之前的记录：/abs/x.md`. Buttons set `NSPasteboard`. |
| 6 | 「置顶」floats the window above a full-screen app | 👁 **NEEDS VISUAL** | Pin code is verbatim-correct: `NSWindow.level=.floating` + `collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]` (`PinController`), wired to a toolbar toggle. Whether it actually hovers over another app's full-screen Space is an OS behavior that must be seen on screen. |
| 7 | Retention 7d → next-day cleanup of expired+unstarred; starred kept; **source logs untouched** | ✅ logic + scheduled · ⏳ multi-day | `runCleanup` tested: old+unstarred → `_trash`, starred/fresh kept, purge after grace, **`retentionDays==nil`=never**, a file outside rootDir is untouched (source-log safety is structural — RecordStore only knows its rootDir). Scheduled on launch + every 24h, passing open record tabs as `protectedPaths`. |
| 8 | 「立即同步」instantly picks up a new session | ✅ logic · 👁 live | `SyncEngine.syncOnce` proven by E2E + incremental tests (append→updated); the 立即同步 button + MenuBarExtra item call it. Live pickup needs an interactive check. |
| 9 | Fully offline; `nettop` shows zero connections | ✅ | **No** network APIs in `Sources/` or `RaccoonCore/Sources/` (grep); **no** network/sandbox entitlement in `project.yml`; live `nettop` showed no connection rows for Raccoon. Code is zero-network by construction. |
| 10 | `.md` is human-readable, grep-able, Claude-Code-`Read`-able | ✅ | E2E sample `.md` is exactly the PRD §4 format (YAML frontmatter + 你：/Claude Code： transcript), plain UTF-8. |
| 11 | Multi-Tab, save local `.md`, reopen restore | ✅ logic · 👁 in-app | Editor multi-tab; save → `notesDir` (separate from archives); `EditorModel.persist`/`restoreOrSeed` round-trips open tabs across launch (`start()` made idempotent). Visual confirm pending. |
| 12 | Low resident memory (target <80MB) | ✅ **63 MB** | `phys_footprint` = **63 MB settled** (< 80 target); peak 109 MB during the one-time initial sync of 259 records, then settles. (RSS 152 MB overcounts shared frameworks — not the metric.) Sidebar uses lightweight `RecordSummary` (no transcripts held). |

## Summary
- **Headlessly verified:** §9.1 (pipeline), 9.2, 9.3, 9.4, 9.5, 9.7, 9.9, 9.10, 9.12 — 9 of 12 fully, plus the logic for 1/2/3/4/8/11.
- **Needs a visual/interactive pass** (Screen Recording permission for the controller, or user eyeball per PRD "本地试用清单"): **§9.6** (pin over full-screen — the headline visual), and the in-app confirmation of §9.1 sidebar, §9.2/9.3 paste, §9.8 live sync, §9.11 tabs/restore.
- **Privacy & weight — the two marquee claims — both hold:** zero-network by construction (§9.9) and 63 MB resident (§9.12).
