# Architecture Decision Log

## 2026-05-24 — Phase 0 Locked Decisions

1. **Workspace location**: Standalone git repo (this repository); own public GitHub remote in Phase 4.

2. **Package architecture**: Core = local SPM package (`RaccoonCore`); app = XcodeGen target depending on it. Rationale: fast `swift test` TDD loop for the CleanEngine moat without booting Xcode.

3. **Claude archive content (v1)**: User text + assistant `text` blocks → clean transcript; skip `thinking`/`tool_use`/`tool_result` and meta line-types.

4. **Codex adapter**: Built defensively + synthetic fixtures (Codex CLI 0.133.0 installed but no real `~/.codex/sessions` data yet; validate on real rollout after first authed run).

5. **Menu bar**: Keep Dock + main window primary (no `LSUIElement`) + secondary `MenuBarExtra`.

6. **Editor**: `NSTextView`-backed via `NSViewRepresentable`; preview via `AttributedString(markdown:)` (no WebView).

7. **User notes vs archives**: `~/Library/Application Support/Raccoon/notes/` vs `.../records/` are separate; sync never writes into `notes/`.

8. **Resolved GRDB version**: 6.29.3 (via `https://github.com/groue/GRDB.swift`, from: "6.29.0").

9. **Toolchain**: global xcode-select points to CommandLineTools, which lacks the bundled Swift Testing module, so plain `swift test` fails with 'no such module Testing'. We run `swift test` and `xcodebuild` via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (Xcode 26.4, Swift Testing 1743). No swift-testing GitHub dependency. `scripts/dev.sh` exports DEVELOPER_DIR so all build/test commands are reproducible.

10. **SyncEngine ingest strategy (v1): whole-file re-parse on change, skip unchanged files.** Per-source-file we store `(size, mtime)`. On sync: if a source file is unchanged since last seen → SKIP (the key optimisation — no disk I/O, no parse). If new or changed → read the whole file, call `adapter.parse` → full `Record` → `RecordStore.save` (deterministic `.md` filename, so this upserts/overwrites). The store, when constructed with an injected `SearchIndex`, also upserts the record into the index inside `save` (see #11) — the engine no longer indexes records itself. Counts of `added` (path was never in state) and `updated` (path was in state) are returned. State is persisted as JSON at a caller-supplied `statePath` after every successful pass. A `byteOffset` field is reserved in `FileSyncState` for a future incremental-read optimisation but unused in v1. Rationale: the PRD mentions byte-offset incremental reads, but sessions sync every 3–5 min and grow by a few lines; whole-file re-parse of a changed file is sub-millisecond at realistic sizes, so true byte-offset incremental is unnecessary complexity for v1 (it would also require the adapter to parse partial files and merge). Whole-file-on-change naturally handles the "file shrank/mismatch → full re-read" case. Revisit only if session files become very large.

## 2026-05-24 — Phase 1 close-out hardening

11. **Raccoon archives are PERMANENT; they outlive their source logs.** The whole point of Raccoon is to preserve terminal-AI sessions that the tools themselves rotate/delete (会丢). Therefore, when a source `.jsonl` disappears, the `SyncEngine` does **NOT** delete the archived `.md` — the archive is the durable record of truth. To keep the in-memory/persisted sync `state` map (`[sourcePath: FileSyncState]`) from growing unbounded across the app's lifetime, each `syncOnce` pass prunes state keys whose source path no longer exists on disk (the `.md` stays; only the dead bookkeeping entry is dropped). Permanent deletion of an archive is an explicit user action via `RecordStore.delete(_:)` or the retention/recycle-bin flow (`runCleanup`), never an implicit consequence of a vanished source.

    **Corollary — RecordStore OWNS SearchIndex sync.** To make store↔index desync structurally impossible, the `SearchIndex` is injected into `RecordStore` (optional; `nil` = pure file archive). Every store mutation keeps the index in lock-step: `save` upserts (and rethrows on index failure *after* the `.md` is written, so `SyncEngine` retries rather than leaving a saved-but-unindexed file), `delete` removes from both, `setStarred` re-syncs so the index `starred` column tracks the flag, and `runCleanup` removes trashed/purged files from the index. `SyncEngine` constructs its `RecordStore` *with* the index and performs no direct indexing. `SyncEngine.syncOnce` also honors `Settings.enabledTools` (skips adapters for disabled tools), and `RecordStore.all()` returns records sorted by `lastActiveAt` descending for direct list-UI consumption.

## 2026-05-30 — Anti-goals / 反目标（永不做）

12. **以下方向永久排除，写死红线，代码一寸都不往这边挪。** 它们要么摧毁 Raccoon 的核心护城河（跨工具中立 / 逐字归档不总结 / 硬零联网 + 只读源日志），要么带来不可接受的合规与信任风险。判定规则：任何提案只要把代码推向"网络 / 团队 / 额度 / 常开捕获"四个方向，默认 NO。

    1. **Agent 网关 / 统一通道（CLI、Web、钉钉、桌宠、悬浮球）。** 这是基础设施巨头与基金会项目的地盘（LiteLLM、Bifrost、AgentGateway 已进 Linux Foundation、Docker MCP Gateway 已成形），小工具在此毫无护城河，且天然需要联网——与零联网身份正面冲突。

    2. **团队记忆与治理。** 企业销售方向，必然拖出后端 / 身份 / 权限 / 合规一整套，直接摧毁"单机、零联网、本地档案"的产品身份。

    3. **P2P 额度借还 / 共享 / 结算 —— 最高优先级红线。** 其本质是账号共享 + API 转售，违反 Anthropic / OpenAI / Google 使用条款，触发封号 + 法律 / 声誉风险，且**不存在合规版本**，没有任何裁剪空间。

    4. **常开截屏 / AX 注入屏幕上下文。** 与"可信、零联网、只读"的卖点自相矛盾，隐私与信任成本极高，一旦做了卖点即破产。

    5. **本地语音输入 / 手势审批 / 桌宠办公工具调用。** 纯噱头，低留存，稀释"可信工具"的定位，不值得占用任何范围。

    一句话原则：**代码一寸都不往"网络 / 团队 / 额度 / 常开捕获"方向挪。**

## 2026-05-30 — v0.2 候选（待定，不进 v0.1）

13. **基于 2026-05 调研记录两个不破坏 DNA 的 v0.2 候选方向，明确不进 v0.1，仅备忘。**

    1. **把本地档案库可选地暴露为一个只读 MCP server。** Agent 按需拉一条带标签的记录——是现有"喂"动作的升级版（Claude Explorer 已验证此路径可行）。前提：保持人主导、不总结、全本地，读侧只读不写。

    2. **把 OpenCode 接成一等公民数据源。** OpenCode（~150K star / 月活 ~6.5M）值得新增一个 `SessionAdapter`，与 Claude Code / Codex / Gemini / Cursor 并列，无需改动现有架构。

    另：把"多 agent 研发 OS / AgentOS"作为对外叙事的北极星——Raccoon = 第一个能落地、可信、可验证的器官（记忆层）。**仅用于 README / About 文案，不改任何代码范围。**
