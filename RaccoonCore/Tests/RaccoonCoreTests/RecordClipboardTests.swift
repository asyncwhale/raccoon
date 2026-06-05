import Testing
import Foundation
@testable import RaccoonCore

// MARK: - RecordClipboard (§9.5 payloads)

/// A sample 2-message record (你 + Codex) used across the assertions below.
private func sampleRecord() -> Record {
    Record(
        tool: .codex,
        sessionID: "0193-abc",
        project: "demo",
        startedAt: Date(timeIntervalSince1970: 0),
        lastActiveAt: Date(timeIntervalSince1970: 600),
        starred: false,
        messages: [
            .init(speaker: .user, text: "docker 端口被占用怎么办", timestamp: nil),
            .init(speaker: .codex, text: "先用 lsof -i :5432 找到进程，再 kill 掉。", timestamp: nil)
        ]
    )
}

// MARK: copyOut — bare content, NO source labels

@Test("copyOut joins message texts with blank lines and has NO User：/Codex： labels")
func recordClipboardCopyOutHasNoLabels() {
    let r = sampleRecord()
    let out = RecordClipboard.copyOut(r)

    // EXACT payload: the two texts joined by a blank line, no labels.
    #expect(out == "docker 端口被占用怎么办\n\n先用 lsof -i :5432 找到进程，再 kill 掉。")

    // Explicitly: no source labels leak in.
    #expect(!out.contains("User："))
    #expect(!out.contains("Codex："))
}

// MARK: feedContent — verbatim §4 body WITH 来源标签

@Test("feedContent is the §4 body WITH User：/Codex： labels, no frontmatter")
func recordClipboardFeedContentHasLabels() {
    let r = sampleRecord()
    let out = RecordClipboard.feedContent(r)

    // EXACT payload: each message as "<label>：\n<text>", joined by a blank line.
    #expect(out == "User：\ndocker 端口被占用怎么办\n\nCodex：\n先用 lsof -i :5432 找到进程，再 kill 掉。")

    // It HAS the source labels...
    #expect(out.contains("User："))
    #expect(out.contains("Codex："))
    // ...and is body-only: no `---` frontmatter fence.
    #expect(!out.contains("---"))
    #expect(!out.contains("session_id"))
}

// MARK: feedContent equals MarkdownCodec body (frontmatter stripped)

@Test("feedContent matches the MarkdownCodec body after the frontmatter")
func recordClipboardFeedContentMatchesCodecBody() {
    let r = sampleRecord()
    let encoded = MarkdownCodec.encode(r)

    // The codec writes: "---\n<fm>\n---\n\n<body>\n\n" (trailing blank lines per message).
    // Strip the frontmatter block and the trailing whitespace to isolate the body.
    let parts = encoded.components(separatedBy: "---\n")
    // parts[0] == "" (before first fence), parts[1] == frontmatter, parts[2...] == body.
    let bodyRegion = parts.dropFirst(2).joined(separator: "---\n")
    let codecBody = bodyRegion.trimmingCharacters(in: .whitespacesAndNewlines)

    #expect(RecordClipboard.feedContent(r) == codecBody)
}

// MARK: feedPath — guide phrase + absolute path

@Test("feedPath uses the default AGENT-READY directive + absolute .md path")
func recordClipboardFeedPathDefaultGuide() {
    let url = URL(fileURLWithPath: "/abs/x.md")
    let out = RecordClipboard.feedPath(mdPath: url)
    // The default guide is an agent-actionable directive (read the file, then continue),
    // followed immediately by the absolute local path, on a single line.
    #expect(out == "请读取这个文件了解之前的上下文（仅作参考，读完等我指示）：/abs/x.md")
    #expect(out.hasPrefix("请读取这个文件了解之前的上下文（仅作参考，读完等我指示）："))
    #expect(out.hasSuffix("/abs/x.md"))
    #expect(!out.contains("\n"))
}

@Test("feedPath honors a custom guide phrase")
func recordClipboardFeedPathCustomGuide() {
    let url = URL(fileURLWithPath: "/Users/me/Library/Application Support/Raccoon/records/codex-2026-05-17-0193.md")
    let out = RecordClipboard.feedPath(mdPath: url, guide: "参考这个：")
    #expect(out == "参考这个：/Users/me/Library/Application Support/Raccoon/records/codex-2026-05-17-0193.md")
}

// MARK: Edge cases

@Test("copyOut and feedContent on an empty record are empty strings")
func recordClipboardEmptyRecord() {
    let r = Record(
        tool: .claudeCode,
        sessionID: "empty",
        project: nil,
        startedAt: Date(timeIntervalSince1970: 0),
        lastActiveAt: Date(timeIntervalSince1970: 0),
        starred: false,
        messages: []
    )
    #expect(RecordClipboard.copyOut(r) == "")
    #expect(RecordClipboard.feedContent(r) == "")
}
