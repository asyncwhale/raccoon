# Raccoon 🦝

**Local memory layer for terminal-AI users.**

Raccoon is a pinnable, Sublime-style Markdown editor that gives your AI-assisted terminal workflow a persistent brain — **100% local, zero-network, free, and open-source.**

The mascot is a raccoon because raccoons wash things. That is exactly what Raccoon does to your messy terminal output.

> README is English-primary for now. A Simplified Chinese README is planned;
> the app UI itself is already bilingual (English / 简体中文).

---

## How it's different

Most tools in this space fall into two camps: **Claude-only session viewers**
(e.g. Claude Explorer) and **AI memory layers that auto-summarize**
(e.g. mem0 / OpenMemory). Raccoon is neither.

| | **Raccoon** | Claude-only session viewers | AI memory layers (auto-summarize) |
|---|---|---|---|
| **Tool coverage** | Cross-tool: Claude Code, Codex, Gemini, Cursor, … | Claude only | Varies; memory-API focused |
| **What it stores** | Your sessions, **verbatim** — no AI summarization | Verbatim view of Claude logs | Auto-summarized / rewritten by an LLM |
| **Network** | **Zero-network by construction** (no networking code) | Varies | Typically cloud / API-backed |
| **Source logs** | Opened **read-only**, never modified | Read access | Often ingested into a separate store |

These are public projects named only as fair, factual category examples — not as
criticism. They solve adjacent problems well; Raccoon's bet is cross-tool,
verbatim, and provably local.

---

## Features

### 1. Archive (记) — capture sessions, never lose context
Import Claude Code / Codex / any tool's JSONL transcript with one drag-and-drop. Sessions are stored as plain Markdown files on your disk — readable forever, no vendor lock-in.

### 2. Clean (洗) — strip terminal noise without touching code
Paste raw terminal output and Raccoon strips ANSI escape codes, box-drawing characters, and wrapping artifacts while leaving every code block, diff, and git graph byte-perfect.

### 3. Search (找) — full-text across all tools, all sessions
SQLite FTS5 full-text search across every archived session. Works offline, instant, no cloud index.

### 4. Feed (喂) — copy clean records back into any AI
One-click copy of a cleaned, formatted record. Paste directly into Claude, GPT, Gemini, or any AI's context window — no re-cleaning needed.

### 5. Pin — float the window, keep it always-on-top
Pin Raccoon above your terminal or IDE so your notes stay visible while you code. Configurable keyboard shortcut.

---

## Privacy

**Raccoon makes zero network connections. Always. By design.**

- **Zero networking code.** The app links no networking frameworks and makes no
  outbound connections. There is no `URLSession`, no `Network`/`CFNetwork` usage,
  no analytics or telemetry SDK, no update checker, and no CDN calls anywhere in
  the source. The entire app is open source — audit it yourself.
- **100% local.** Every file Raccoon writes stays under
  `~/Library/Application Support/Raccoon`. Your source logs (`~/.claude`,
  `~/.codex`, and other tools' transcripts) are opened **read-only** and never
  modified.
- App Sandbox is currently off, because the app needs to read your tools' log
  folders, which live outside a sandbox container. The network guarantee does
  **not** rely on sandbox entitlements — it comes from there being no networking
  code at all, which you can verify yourself with the commands below.

### Verify the privacy claim yourself

You don't have to trust us. The zero-network guarantee is verifiable in seconds:

```sh
# 1. Confirm the binary links no networking frameworks.
#    No URLSession / Network / CFNetwork means no outbound capability.
otool -L /Applications/Raccoon.app/Contents/MacOS/Raccoon | grep -Ei 'CFNetwork|Network|URLSession'
#    -> prints nothing

# 2. While Raccoon is running, watch for any network activity:
nettop -p "$(pgrep -x Raccoon)"      # shows no connections

# Alternative tools that also work:
# - Little Snitch: Raccoon will never appear in its connection log
# - LuLu: same result
# - Turn off Wi-Fi entirely — Raccoon keeps working without a hiccup
```

---

## Install

### Option A — Download (signed + notarized DMG)

1. Go to [Releases](https://github.com/asyncwhale/raccoon/releases).
2. Download `Raccoon-<version>.dmg`.
3. Open the DMG, drag `Raccoon.app` to Applications.

The DMG is signed with a Developer ID Application certificate and notarized by Apple. Gatekeeper will not block it.

### Option B — Homebrew Cask

```sh
brew install --cask asyncwhale/homebrew-tap/raccoon
```

---

## Build from Source

Requirements: macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/asyncwhale/raccoon.git
cd raccoon
xcodegen generate
open Raccoon.xcodeproj
```

Swift Package Manager resolves dependencies (`RaccoonCore`, `KeyboardShortcuts`) automatically when Xcode opens the project.

**Run the core library tests** (no Xcode needed):

```sh
cd RaccoonCore
swift test
```

---

## Screenshots

> All screenshots use **synthetic demo sessions** — no real transcripts.

![Raccoon — archive sidebar with cross-tool sessions and filters](docs/img/sidebar-dark.png)

A session opened — verbatim, who-said-what, code preserved exactly, ready to feed back to your AI:

![Raccoon — an archived session (dark)](docs/img/record-dark.png)

![Raccoon — an archived session (light)](docs/img/record-light.png)

---

## 关于

Raccoon 是我业余时间出于兴趣做的个人项目——想看看借助 AI 协作，一个开发者能把一个想法推到多完整：从需求到一个经过测试、完全本地、可用的 macOS 应用，独立完成。

比起产品本身，我更想分享的是它的开发过程。Raccoon 用一套「人主控 + 多 agent」的工作流构建：

- **并行 worker agent** 分工实现，各自负责不重叠的文件。
- **对抗式评审循环**——独立 agent 复核每一处改动，而不是轻信自报。
- **TDD 守护核心红线**：清洗引擎「绝不破坏代码」的保证由 236 个测试守住，含一套对抗式代码完整性语料。
- **隐私由构造保证**：零联网代码，源日志只读，可用 `otool` / `nettop` 自行验证。

---

## License

MIT — see [LICENSE](LICENSE). Requires macOS 14+.
