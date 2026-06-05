import Foundation

// MARK: - StoreError

public enum StoreError: Error, Sendable, Equatable {
    case malformedFrontmatter
    case unknownTool
    case unknownSpeaker
}

// MARK: - MarkdownCodec

/// Encodes and decodes `Record` values to/from the Raccoon `.md` archive format.
///
/// ## Format
/// ```
/// ---
/// tool: codex
/// session_id: 0193-...
/// project: my-app          ← omitted when nil
/// started_at: 2026-05-17T14:08:00+08:00
/// last_active_at: 2026-05-17T14:40:00+08:00
/// starred: false
/// ---
///
/// 你：
/// <message text>
///
/// Claude Code：
/// <message text>
///
/// ```
enum MarkdownCodec {

    // MARK: Shared ISO formatter

    // nonisolated(unsafe) is required in Swift 6 strict-concurrency mode because
    // ISO8601DateFormatter is not Sendable. We initialise it once and treat it as
    // read-only after that, so the access is safe in practice.
    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return f
    }()

    // MARK: Speaker label lookup

    /// Legacy on-disk speaker labels that must keep decoding for backward
    /// compatibility with archives written before a label was renamed. Keys are
    /// the OLD labels (without the trailing colon); values are the speaker they
    /// map to. These are merged into the decode lookup so existing `.md` files
    /// keep round-tripping. Current labels always win on any collision.
    ///
    /// The user label was renamed from "你" to "User"; old archives wrote "你：".
    private static let legacyLabels: [(label: String, speaker: Speaker)] = [
        ("你", .user),
    ]

    /// All known `"Label："` prefixes (current labels + legacy aliases), longest
    /// first to avoid prefix collisions.
    private static let speakerByLabel: [(label: String, speaker: Speaker)] = {
        // Build a prefix→speaker map. Insert legacy aliases first, then current
        // labels so a current label always overrides any legacy alias that maps
        // to the same prefix. Sort by prefix length descending so "Claude Code："
        // is matched before any shorter label that might share a prefix.
        var byPrefix: [String: Speaker] = [:]
        for (label, speaker) in legacyLabels {
            byPrefix[label + "："] = speaker
        }
        for speaker in Speaker.allCases {
            byPrefix[speaker.label + "："] = speaker   // current label wins
        }
        return byPrefix
            .map { (label: $0.key, speaker: $0.value) }
            .sorted { $0.label.count > $1.label.count }
    }()

    // MARK: Encode

    static func encode(_ r: Record) -> String {
        var out = ""

        // Frontmatter
        out += "---\n"
        out += "tool: \(r.tool.rawValue)\n"
        out += "session_id: \(r.sessionID)\n"
        if let project = r.project {
            out += "project: \(project)\n"
        }
        out += "started_at: \(isoFormatter.string(from: r.startedAt))\n"
        out += "last_active_at: \(isoFormatter.string(from: r.lastActiveAt))\n"
        out += "starred: \(r.starred ? "true" : "false")\n"
        out += "---\n"

        // Body
        out += "\n"
        for message in r.messages {
            out += "\(message.speaker.label)：\n"
            out += message.text
            out += "\n\n"
        }

        return out
    }

    // MARK: Decode

    static func decode(_ md: String) throws(StoreError) -> Record {
        // Split on the two `---` fence lines.
        // The format is: "---\n<frontmatter>\n---\n\n<body>"
        let lines = md.components(separatedBy: "\n")

        guard lines.first == "---" else { throw .malformedFrontmatter }

        // Find the closing `---`
        guard let closeIdx = lines.dropFirst().firstIndex(of: "---") else {
            throw .malformedFrontmatter
        }

        let frontmatterLines = Array(lines[1..<closeIdx])
        let bodyLines = Array(lines[(closeIdx + 1)...])

        // Parse frontmatter into a key→value dictionary
        var fm: [String: String] = [:]
        for line in frontmatterLines {
            let colonIdx = line.firstIndex(of: ":")
            guard let colonIdx else { continue }
            let key = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            fm[key] = value
        }

        // tool
        guard let toolRaw = fm["tool"] else { throw .malformedFrontmatter }
        guard let tool = Tool(rawValue: toolRaw) else { throw .unknownTool }

        // session_id
        guard let sessionID = fm["session_id"] else { throw .malformedFrontmatter }

        // project (optional)
        let project: String? = fm["project"]

        // dates
        guard
            let startedAtStr = fm["started_at"],
            let startedAt = isoFormatter.date(from: startedAtStr)
        else { throw .malformedFrontmatter }

        guard
            let lastActiveAtStr = fm["last_active_at"],
            let lastActiveAt = isoFormatter.date(from: lastActiveAtStr)
        else { throw .malformedFrontmatter }

        // starred
        guard let starredStr = fm["starred"] else { throw .malformedFrontmatter }
        let starred = starredStr == "true"

        // Parse body into messages
        // Body starts after the closing `---` and the blank line that follows.
        // Each message is:
        //   <speaker label>：
        //   <text lines...>
        //   <blank line>
        //
        // We scan line by line; when we encounter a "Label：" line we start a
        // new message and accumulate text until the next label line (or EOF).

        let messages = try parseMessages(from: bodyLines)

        return Record(
            tool: tool,
            sessionID: sessionID,
            project: project,
            startedAt: startedAt,
            lastActiveAt: lastActiveAt,
            starred: starred,
            messages: messages
        )
    }

    // MARK: Body parser

    private static func parseMessages(from lines: [String]) throws(StoreError) -> [Message] {
        var messages: [Message] = []

        var currentSpeaker: Speaker?
        // Collect lines that belong to the current message's text.
        var textLines: [String] = []

        func flush() {
            guard let speaker = currentSpeaker else { return }
            // Strip all trailing blank lines. The encoder always writes `text + "\n\n"`,
            // producing one (or two, at EOF) trailing empty lines in the split array.
            // Inner blank lines are preserved because they are followed by non-empty content
            // before the next speaker label terminates the block.
            var lines = textLines
            while lines.last == "" { lines.removeLast() }
            messages.append(Message(speaker: speaker, text: lines.joined(separator: "\n"), timestamp: nil))
        }

        for line in lines {
            if let (speaker, _) = matchSpeakerLine(line) {
                flush()
                currentSpeaker = speaker
                textLines = []
            } else {
                if currentSpeaker != nil {
                    textLines.append(line)
                }
                // Lines before any speaker label (e.g. the blank line after `---`) are ignored.
            }
        }
        flush()

        return messages
    }

    /// If `line` is exactly `"<Label>："` (fullwidth colon, no trailing space), returns the
    /// matching `Speaker` and the full matched prefix string.
    private static func matchSpeakerLine(_ line: String) -> (Speaker, String)? {
        for (label, speaker) in speakerByLabel {
            if line == label {
                return (speaker, label)
            }
        }
        return nil
    }
}
